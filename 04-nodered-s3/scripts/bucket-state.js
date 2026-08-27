#!/usr/bin/env node
'use strict';

/**
 * Prints the state of the source and destination buckets: every object with
 * its ETag (annotated as multipart or single-PUT) and the count of in-progress
 * multipart uploads.
 *
 * The orphan count is the number that matters operationally. An abandoned
 * multipart upload keeps its already-uploaded parts in S3, billed as storage,
 * and they do not appear in a normal object listing. Anything above zero here
 * after a completed run means the abort path failed.
 */

const {
  S3Client,
  ListObjectsV2Command,
  ListMultipartUploadsCommand,
  HeadObjectCommand,
} = require('@aws-sdk/client-s3');

const { createS3Client } = require('../lib/s3-target.js');

const buckets = process.argv.slice(2);
if (buckets.length === 0) buckets.push('task04-source', 'task04-destination');

// Defaults to the local endpoint. Real AWS requires S3_ENDPOINT=aws.
const { client: s3, target } = createS3Client(S3Client);

async function main() {
  console.log(`S3 target: ${target.label}`);
  let totalOrphans = 0;

  for (const bucket of buckets) {
    console.log('');
    console.log(`=== bucket: ${bucket} ===`);

    const listed = await s3.send(new ListObjectsV2Command({ Bucket: bucket }));
    const contents = listed.Contents || [];
    console.log(`objects: ${contents.length}`);

    for (const object of contents) {
      const head = await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: object.Key }));
      const etag = head.ETag.replace(/"/g, '');
      const multipart = /-(\d+)$/.exec(etag);
      const annotation = multipart ? `[multipart: ${multipart[1]} part(s)]` : '[single PUT]';
      console.log(`  ${String(object.Size).padStart(9)} B  ETag=${etag}  ${annotation}  ${object.Key}`);
    }

    const mpu = await s3.send(new ListMultipartUploadsCommand({ Bucket: bucket }));
    const uploads = mpu.Uploads || [];
    totalOrphans += uploads.length;
    console.log(`in-progress (orphaned) multipart uploads: ${uploads.length}`);
    for (const upload of uploads) {
      console.log(`  ORPHAN: key=${upload.Key} uploadId=${upload.UploadId} initiated=${upload.Initiated}`);
    }
  }

  console.log('');
  console.log('----------------------------------------------------------------');
  console.log(`TOTAL ORPHANED MULTIPART UPLOADS: ${totalOrphans}`);
  console.log(
    totalOrphans === 0
      ? 'Zero orphans: every upload either completed or was explicitly aborted.'
      : 'NON-ZERO: abandoned parts are accruing storage charges and are invisible to a normal object listing.',
  );
  console.log('----------------------------------------------------------------');

  process.exitCode = totalOrphans === 0 ? 0 : 1;
  s3.destroy();
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
  s3.destroy();
});
