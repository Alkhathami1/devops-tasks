#!/usr/bin/env node
'use strict';

/**
 * End-to-end verification of the Node-RED flow.
 *
 * Drives the running flow over HTTP exactly as a client would, then verifies
 * the result independently through the S3 API. Requires:
 *   - moto      on S3_ENDPOINT       (default http://127.0.0.1:5000)
 *   - Node-RED  on NODE_RED_URL      (default http://127.0.0.1:1880)
 */

const crypto = require('node:crypto');
const {
  S3Client,
  GetObjectCommand,
  HeadObjectCommand,
  ListMultipartUploadsCommand,
} = require('@aws-sdk/client-s3');

const { createS3Client } = require('../lib/s3-target.js');

const NODE_RED_URL = process.env.NODE_RED_URL || 'http://127.0.0.1:1880';
const SOURCE_BUCKET = 'task04-source';
const DEST_BUCKET = 'task04-destination';
const SOURCE_KEY = 'fixtures/large file (23MiB).bin';

// Defaults to the local endpoint. Real AWS requires S3_ENDPOINT=aws.
const { client: s3, target } = createS3Client(S3Client);

let failures = 0;
function check(label, condition, detail = '') {
  const status = condition ? 'PASS' : 'FAIL';
  if (!condition) failures += 1;
  console.log(`[${status}] ${label}${detail ? ` -- ${detail}` : ''}`);
}

async function streamToBuffer(body) {
  const chunks = [];
  for await (const chunk of body) chunks.push(chunk);
  return Buffer.concat(chunks);
}

const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');

async function post(body) {
  const response = await fetch(`${NODE_RED_URL}/copy`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { status: response.status, json: await response.json() };
}

async function main() {
  console.log('=== Node-RED end-to-end verification ===');
  console.log(`Node-RED : ${NODE_RED_URL}`);
  console.log(`S3       : ${target.label}`);
  console.log('');

  // ---- 1. Happy path through the flow ------------------------------------
  console.log('--- 1. successful copy through POST /copy ---');
  const destKey = 'copied/e2e-verified.bin';
  const ok = await post({
    source: { bucket: SOURCE_BUCKET, key: SOURCE_KEY },
    destination: { bucket: DEST_BUCKET, key: destKey },
    partSize: 5 * 1024 * 1024,
    concurrency: 3,
  });

  check('HTTP 200 returned', ok.status === 200, `got ${ok.status}`);
  check('payload.ok is true', ok.json.ok === true);
  check('more than one part used', ok.json.result.partCount > 1, `partCount=${ok.json.result.partCount}`);
  check('part count is 5', ok.json.result.partCount === 5);
  check('part size is 5 MiB', ok.json.result.partSize === 5 * 1024 * 1024);

  const events = (ok.json.logs || []).map((l) => l.event);
  for (const required of ['copy.start', 'source.inspected', 'plan.computed', 'upload.created', 'copy.complete']) {
    check(`log contains ${required}`, events.includes(required));
  }
  check('one part.copied per part', events.filter((e) => e === 'part.copied').length === 5);
  const ids = new Set((ok.json.logs || []).map((l) => l.correlationId));
  check('single correlationId across all log lines', ids.size === 1, `${ids.size} distinct id(s)`);

  // ---- 2. Verify the bytes independently ---------------------------------
  console.log('');
  console.log('--- 2. independent verification via the S3 API ---');
  const [srcObj, dstObj] = await Promise.all([
    s3.send(new GetObjectCommand({ Bucket: SOURCE_BUCKET, Key: SOURCE_KEY })),
    s3.send(new GetObjectCommand({ Bucket: DEST_BUCKET, Key: destKey })),
  ]);
  const srcBuf = await streamToBuffer(srcObj.Body);
  const dstBuf = await streamToBuffer(dstObj.Body);
  const srcHash = sha256(srcBuf);
  const dstHash = sha256(dstBuf);

  console.log(`  source sha256      : ${srcHash}`);
  console.log(`  destination sha256 : ${dstHash}`);
  check('byte lengths match', srcBuf.length === dstBuf.length, `${srcBuf.length} vs ${dstBuf.length}`);
  check('sha256 digests match', srcHash === dstHash);

  const head = await s3.send(new HeadObjectCommand({ Bucket: DEST_BUCKET, Key: destKey }));
  const etag = head.ETag.replace(/"/g, '');
  console.log(`  destination ETag   : ${etag}`);
  check('ETag carries multipart suffix', /-\d+$/.test(etag));
  check('ETag suffix matches part count', etag.endsWith('-5'), etag);

  // ---- 3. Validation rejection -------------------------------------------
  console.log('');
  console.log('--- 3. invalid request is rejected with 400 ---');
  const bad = await post({ source: { bucket: SOURCE_BUCKET }, destination: {} });
  check('HTTP 400 returned', bad.status === 400, `got ${bad.status}`);
  check('ok is false', bad.json.ok === false);
  check('validation details listed', Array.isArray(bad.json.details) && bad.json.details.length >= 3,
    JSON.stringify(bad.json.details));

  // ---- 4. Failure path leaves no orphans ---------------------------------
  console.log('');
  console.log('--- 4. failing copy aborts cleanly, no orphaned uploads ---');
  const missing = await post({
    source: { bucket: SOURCE_BUCKET, key: 'fixtures/definitely-not-here.bin' },
    destination: { bucket: DEST_BUCKET, key: 'copied/never.bin' },
    partSize: 5 * 1024 * 1024,
  });
  check('non-200 returned for missing source', missing.status >= 400, `got ${missing.status}`);
  check('ok is false', missing.json.ok === false);

  const uploads = await s3.send(new ListMultipartUploadsCommand({ Bucket: DEST_BUCKET }));
  const orphans = uploads.Uploads || [];
  check('zero orphaned multipart uploads', orphans.length === 0,
    orphans.length ? JSON.stringify(orphans) : 'none');

  console.log('');
  console.log('=========================================');
  console.log(failures === 0 ? 'RESULT: ALL CHECKS PASSED' : `RESULT: ${failures} CHECK(S) FAILED`);
  console.log('=========================================');

  // Set the code and let the loop drain naturally. Calling process.exit() here
  // trips a libuv assertion on Windows (UV_HANDLE_CLOSING in async.c) because
  // the SDK's keep-alive sockets are still closing, which turns a passing run
  // into exit code 127.
  process.exitCode = failures === 0 ? 0 : 1;
  s3.destroy();
}

main().catch((error) => {
  console.error('verification crashed:', error);
  process.exitCode = 1;
  s3.destroy();
});
