#!/usr/bin/env node
'use strict';

/**
 * Command line front end for the copy engine.
 *
 * Emits the structured JSON log stream on stdout, one object per line, which
 * is the same stream the Node-RED flow collects. Useful for demonstrating the
 * logging requirement without the Node-RED runtime in the way.
 *
 *   node scripts/copy-cli.js \
 *     --source-bucket src --source-key path/obj \
 *     --dest-bucket dst  --dest-key path/copy \
 *     [--part-size 5242880] [--concurrency 4]
 */

const {
  S3Client,
  HeadObjectCommand,
  CreateMultipartUploadCommand,
  UploadPartCopyCommand,
  CompleteMultipartUploadCommand,
  AbortMultipartUploadCommand,
} = require('@aws-sdk/client-s3');

const { copyObject } = require('../lib/s3-multipart-copy.js');
const { createS3Client } = require('../lib/s3-target.js');

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 2) {
    const key = argv[i].replace(/^--/, '');
    args[key] = argv[i + 1];
  }
  return args;
}

const args = parseArgs(process.argv);

const required = ['source-bucket', 'source-key', 'dest-bucket', 'dest-key'];
const missing = required.filter((k) => !args[k]);
if (missing.length) {
  console.error(`missing required argument(s): ${missing.map((m) => `--${m}`).join(', ')}`);
  process.exit(2);
}

// Defaults to the local endpoint. Real AWS requires S3_ENDPOINT=aws.
const { client: s3, target } = createS3Client(S3Client);
console.error(`S3 target: ${target.label}`); // stderr, so stdout stays pure JSON log lines

const commands = {
  HeadObjectCommand,
  CreateMultipartUploadCommand,
  UploadPartCopyCommand,
  CompleteMultipartUploadCommand,
  AbortMultipartUploadCommand,
};

copyObject({
  s3,
  commands,
  source: { bucket: args['source-bucket'], key: args['source-key'] },
  destination: { bucket: args['dest-bucket'], key: args['dest-key'] },
  ...(args['part-size'] ? { partSize: Number(args['part-size']) } : {}),
  ...(args.concurrency ? { concurrency: Number(args.concurrency) } : {}),
})
  .then(() => {
    process.exitCode = 0;
    s3.destroy();
  })
  .catch(() => {
    // The engine already logged copy.failed with the detail; exit non-zero so
    // a shell caller sees the failure.
    process.exitCode = 1;
    s3.destroy();
  });
