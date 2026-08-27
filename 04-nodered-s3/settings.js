'use strict';

/**
 * Node-RED settings for Task 04.
 *
 * The multipart copy engine is a plain Node module. It is handed to the
 * runtime through functionGlobalContext so function nodes can reach it with
 * global.get('s3copy') without any Node-RED specific code living in the
 * engine itself. That separation is what makes `node --test` possible.
 *
 * Credentials come from the environment, never from this file:
 *   S3_ENDPOINT           http://127.0.0.1:5000 for moto; unset for real AWS
 *   AWS_REGION            defaults to us-east-1
 *   AWS_ACCESS_KEY_ID     required
 *   AWS_SECRET_ACCESS_KEY required
 */

const path = require('node:path');

const {
  S3Client,
  HeadObjectCommand,
  CreateMultipartUploadCommand,
  UploadPartCopyCommand,
  CompleteMultipartUploadCommand,
  AbortMultipartUploadCommand,
  ListMultipartUploadsCommand,
} = require('@aws-sdk/client-s3');

const s3copy = require('./lib/s3-multipart-copy.js');
const { createS3Client } = require('./lib/s3-target.js');

// The runtime, unlike the developer scripts, is allowed to target real AWS with
// S3_ENDPOINT unset — that is its production configuration. It does NOT fall
// back to "test"/"test" credentials there: against a real account those only
// yield a confusing InvalidAccessKeyId, so the SDK's default credential chain
// is used instead.
const { client: s3Client, target: s3Target } = createS3Client(S3Client, { allowRealAws: true });

// Printed at startup so the operator can see which account the flow will touch.
console.log(`[task04] S3 target: ${s3Target.label}`);

module.exports = {
  uiPort: process.env.NODE_RED_PORT || 1880,
  flowFile: path.join(__dirname, 'flows', 'flows.json'),
  userDir: path.join(__dirname, '.node-red'),

  // Keep the generated flow file readable in git.
  flowFilePretty: true,

  logging: {
    console: {
      level: process.env.NODE_RED_LOG_LEVEL || 'info',
      metrics: false,
      audit: false,
    },
  },

  functionGlobalContext: {
    s3copy,
    s3Client,
    s3Commands: {
      HeadObjectCommand,
      CreateMultipartUploadCommand,
      UploadPartCopyCommand,
      CompleteMultipartUploadCommand,
      AbortMultipartUploadCommand,
      ListMultipartUploadsCommand,
    },
  },

  // Function nodes get a real `require` for these only.
  functionExternalModules: true,

  exportGlobalContextKeys: false,

  editorTheme: {
    projects: { enabled: false },
    tours: false,
  },
};
