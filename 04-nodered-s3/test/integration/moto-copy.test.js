'use strict';

/**
 * Integration test against a real S3 API implementation (moto, in Docker).
 *
 * Start the server first:
 *   docker run -d --name moto -p 5000:5000 motoserver/moto
 *
 * What this proves, beyond "it did not throw":
 *   - the destination bytes are identical to the source (sha256 round trip)
 *   - more than one part was genuinely used (a single-part upload would not
 *     satisfy the assignment)
 *   - the destination ETag carries S3's "-<partCount>" multipart signature
 *   - no multipart upload is left dangling after success OR after a failure
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const {
  S3Client,
  CreateBucketCommand,
  PutObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  ListMultipartUploadsCommand,
  CreateMultipartUploadCommand,
  UploadPartCopyCommand,
  CompleteMultipartUploadCommand,
  AbortMultipartUploadCommand,
} = require('@aws-sdk/client-s3');

const { copyObject, UNITS: { MIB } } = require('../../lib/s3-multipart-copy.js');
const { createS3Client, resolveS3Target } = require('../../lib/s3-target.js');

const SOURCE_BUCKET = 'task04-source';
const DEST_BUCKET = 'task04-destination';

// This suite CREATES buckets and WRITES objects, so it must never be allowed to
// wander onto a real account by way of an unset environment variable.
const TARGET = resolveS3Target();
if (TARGET.isRealAws) {
  throw new Error('Refusing to run destructive integration tests against real AWS S3');
}

const commands = {
  HeadObjectCommand,
  CreateMultipartUploadCommand,
  UploadPartCopyCommand,
  CompleteMultipartUploadCommand,
  AbortMultipartUploadCommand,
};

function makeClient() {
  return createS3Client(S3Client).client;
}

const sha256 = (buffer) => crypto.createHash('sha256').update(buffer).digest('hex');

async function streamToBuffer(body) {
  const chunks = [];
  for await (const chunk of body) chunks.push(chunk);
  return Buffer.concat(chunks);
}

async function ensureBucket(s3, name) {
  try {
    await s3.send(new CreateBucketCommand({ Bucket: name }));
  } catch (error) {
    // Re-running the suite must not fail on an existing bucket.
    if (!['BucketAlreadyOwnedByYou', 'BucketAlreadyExists'].includes(error.name)) throw error;
  }
}

async function listOrphanedUploads(s3, bucket) {
  const response = await s3.send(new ListMultipartUploadsCommand({ Bucket: bucket }));
  return response.Uploads || [];
}

/**
 * A deterministic, incompressible-ish fixture. 23 MiB at a 5 MiB part size is
 * 4 full parts plus a 3 MiB remainder, which exercises the tail path.
 */
function makeFixture(sizeBytes) {
  const buffer = Buffer.alloc(sizeBytes);
  // Fill with a repeating pattern derived from the offset so any part that is
  // copied from the wrong range shows up as a hash mismatch.
  for (let i = 0; i < sizeBytes; i += 4) {
    buffer.writeUInt32BE(i >>> 0, i);
  }
  return buffer;
}

test('S3 to S3 multipart copy against moto', async (t) => {
  const s3 = makeClient();
  const logLines = [];
  const capture = (line) => logLines.push(line);

  await ensureBucket(s3, SOURCE_BUCKET);
  await ensureBucket(s3, DEST_BUCKET);

  // A key with a space and a subdirectory, to exercise CopySource encoding.
  const sourceKey = 'fixtures/large file (23MiB).bin';
  const destKey = 'copied/large file (23MiB).bin';
  const fixtureSize = 23 * MIB;
  const fixture = makeFixture(fixtureSize);
  const sourceHash = sha256(fixture);

  await s3.send(
    new PutObjectCommand({
      Bucket: SOURCE_BUCKET,
      Key: sourceKey,
      Body: fixture,
      ContentType: 'application/octet-stream',
    }),
  );

  await t.test('copies the object using multiple parts', async () => {
    const result = await copyObject({
      s3,
      commands,
      source: { bucket: SOURCE_BUCKET, key: sourceKey },
      destination: { bucket: DEST_BUCKET, key: destKey },
      partSize: 5 * MIB, // force multiple parts; the default 5 GiB would be one part
      concurrency: 3,
      logSink: capture,
    });

    assert.equal(result.ok, true);
    assert.equal(result.sizeBytes, fixtureSize);
    assert.equal(result.partCount, 5, '23 MiB / 5 MiB = 4 full parts + 1 remainder');
    assert.ok(result.partCount > 1, 'MULTIPLE parts were used, not a single-part upload');
    assert.equal(result.partSize, 5 * MIB);
  });

  await t.test('destination bytes are identical to the source', async () => {
    const response = await s3.send(new GetObjectCommand({ Bucket: DEST_BUCKET, Key: destKey }));
    const copied = await streamToBuffer(response.Body);

    assert.equal(copied.length, fixtureSize, 'byte length matches');
    assert.equal(sha256(copied), sourceHash, 'sha256 of destination equals sha256 of source');
  });

  await t.test('destination ETag carries the multipart signature', async () => {
    const head = await s3.send(new HeadObjectCommand({ Bucket: DEST_BUCKET, Key: destKey }));
    const etag = head.ETag.replace(/"/g, '');

    // A single-PUT object has a plain MD5 ETag. A multipart object's ETag is
    // a digest-of-digests suffixed with "-<number of parts>". That suffix is
    // S3's own record that the object was assembled from parts.
    assert.match(etag, /-\d+$/, `ETag ${etag} carries a multipart suffix`);
    assert.ok(etag.endsWith('-5'), `ETag ${etag} ends with -5, matching the 5 parts copied`);
  });

  await t.test('structured logs cover the full lifecycle with one correlationId', async () => {
    const records = logLines.map((line) => JSON.parse(line));
    const events = records.map((r) => r.event);

    for (const required of ['copy.start', 'source.inspected', 'plan.computed', 'upload.created', 'copy.complete']) {
      assert.ok(events.includes(required), `emitted ${required}`);
    }

    const partEvents = records.filter((r) => r.event === 'part.copied');
    assert.equal(partEvents.length, 5, 'one part.copied event per part');

    for (const part of partEvents) {
      assert.ok(part.range.startsWith('bytes='), 'part log records its byte range');
      assert.ok(part.bytes > 0, 'part log records bytes copied');
      assert.ok(typeof part.durationMs === 'number', 'part log records duration');
      assert.ok(part.progress.percent > 0, 'part log records progress');
    }

    const ids = new Set(records.map((r) => r.correlationId));
    assert.equal(ids.size, 1, 'every log line shares a single correlationId');

    const finalProgress = partEvents.map((p) => p.progress.bytesCopied).sort((a, b) => b - a)[0];
    assert.equal(finalProgress, fixtureSize, 'progress accounting sums to the whole object');
  });

  await t.test('no orphaned multipart uploads remain after success', async () => {
    const orphans = await listOrphanedUploads(s3, DEST_BUCKET);
    assert.equal(orphans.length, 0, `expected zero dangling uploads, found ${JSON.stringify(orphans)}`);
  });

  await t.test('a failed copy aborts its upload and leaves no orphans', async () => {
    const before = await listOrphanedUploads(s3, DEST_BUCKET);
    assert.equal(before.length, 0, 'clean slate before the failure drill');

    const failureLogs = [];
    await assert.rejects(
      () =>
        copyObject({
          s3,
          commands,
          source: { bucket: SOURCE_BUCKET, key: 'fixtures/this-key-does-not-exist.bin' },
          destination: { bucket: DEST_BUCKET, key: 'copied/should-never-appear.bin' },
          partSize: 5 * MIB,
          maxRetries: 0,
          logSink: (line) => failureLogs.push(line),
        }),
      (error) =>
        error.code === 'SOURCE_NOT_FOUND' &&
        /this-key-does-not-exist/.test(error.message),
      'a missing source key fails with an actionable message, not a bare UnknownError',
    );

    const after = await listOrphanedUploads(s3, DEST_BUCKET);
    assert.equal(after.length, 0, `failure path left ${after.length} orphaned upload(s)`);

    const events = failureLogs.map((l) => JSON.parse(l).event);
    assert.ok(events.includes('copy.failed'), 'failure was logged');
  });

  await t.test('an upload interrupted after creation is aborted, not left dangling', async () => {
    // Fail at the part-copy stage rather than the HeadObject stage, so the
    // multipart upload genuinely exists before the failure hits.
    const failureLogs = [];
    const sabotaged = {
      ...commands,
      UploadPartCopyCommand: class {
        constructor() {
          const error = new Error('injected part failure');
          error.name = 'InjectedFailure';
          error.$metadata = { httpStatusCode: 400 };
          throw error;
        }
      },
    };

    await assert.rejects(
      () =>
        copyObject({
          s3,
          commands: sabotaged,
          source: { bucket: SOURCE_BUCKET, key: sourceKey },
          destination: { bucket: DEST_BUCKET, key: 'copied/interrupted.bin' },
          partSize: 5 * MIB,
          maxRetries: 0,
          logSink: (line) => failureLogs.push(line),
        }),
      /injected part failure/,
    );

    const events = failureLogs.map((l) => JSON.parse(l).event);
    assert.ok(events.includes('upload.created'), 'the upload really was created');
    assert.ok(events.includes('upload.aborted'), 'and then explicitly aborted');

    const after = await listOrphanedUploads(s3, DEST_BUCKET);
    assert.equal(after.length, 0, `interrupted upload left ${after.length} orphan(s)`);
  });

  await t.test('default part size is the 5 GiB maximum', async () => {
    // Same fixture, no explicit partSize: it must fit in a single 5 GiB part.
    const result = await copyObject({
      s3,
      commands,
      source: { bucket: SOURCE_BUCKET, key: sourceKey },
      destination: { bucket: DEST_BUCKET, key: 'copied/default-partsize.bin' },
      logSink: () => {},
    });

    assert.equal(result.partSize, 5 * 1024 * MIB, 'default part size is 5 GiB');
    assert.equal(result.partCount, 1, '23 MiB fits in one 5 GiB part');

    const head = await s3.send(new HeadObjectCommand({ Bucket: DEST_BUCKET, Key: 'copied/default-partsize.bin' }));
    assert.ok(head.ETag.replace(/"/g, '').endsWith('-1'), 'still a multipart upload, with one part');
  });
});
