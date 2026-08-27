'use strict';

/**
 * Resolves which S3 endpoint a tool should talk to, and builds the client.
 *
 * WHY THIS EXISTS
 * ---------------
 * The developer scripts originally used the pattern:
 *
 *     ...(process.env.S3_ENDPOINT ? { endpoint: process.env.S3_ENDPOINT } : {})
 *
 * which means "if the variable is not set, talk to real AWS S3". Forgetting to
 * export one environment variable silently pointed a debug script at
 * production. That is the wrong default for a tool whose whole purpose is
 * poking at test buckets, so the default here is the local moto endpoint and
 * reaching real AWS requires saying so explicitly.
 *
 * Every caller prints the resolved target before doing any work, so which
 * account is being touched is never a guess.
 */

const DEFAULT_LOCAL_ENDPOINT = 'http://127.0.0.1:5000';

/**
 * @param {object} [options]
 * @param {boolean} [options.allowRealAws] When false (the default, and correct
 *        for developer tooling), an unset S3_ENDPOINT resolves to the local
 *        endpoint instead of real AWS. Real AWS then requires S3_ENDPOINT=aws.
 *        The Node-RED runtime passes true, because targeting real AWS is its
 *        actual job.
 */
function resolveS3Target({ allowRealAws = false } = {}) {
  const raw = (process.env.S3_ENDPOINT || '').trim();

  if (raw === '') {
    if (allowRealAws) {
      return { endpoint: undefined, label: 'REAL AWS S3 (S3_ENDPOINT unset)', isRealAws: true };
    }
    return {
      endpoint: DEFAULT_LOCAL_ENDPOINT,
      label: `${DEFAULT_LOCAL_ENDPOINT} (local default; set S3_ENDPOINT=aws for real AWS)`,
      isRealAws: false,
    };
  }

  if (raw.toLowerCase() === 'aws') {
    return { endpoint: undefined, label: 'REAL AWS S3 (explicitly requested)', isRealAws: true };
  }

  return { endpoint: raw, label: raw, isRealAws: false };
}

/**
 * Build an S3Client for the resolved target.
 *
 * Against a local endpoint we supply the throwaway test credentials moto
 * expects. Against real AWS we supply nothing and let the SDK's default
 * credential chain apply — fabricating "test"/"test" for a real account only
 * produces a confusing InvalidAccessKeyId.
 */
function createS3Client(S3Client, options = {}) {
  const target = resolveS3Target(options);

  const config = {
    region: process.env.AWS_REGION || 'us-east-1',
  };

  if (target.endpoint) {
    config.endpoint = target.endpoint;
    config.forcePathStyle = true; // moto and most S3-compatible servers
  }

  if (!target.isRealAws) {
    config.credentials = {
      accessKeyId: process.env.AWS_ACCESS_KEY_ID || 'test',
      secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY || 'test',
    };
  }

  return { client: new S3Client(config), target };
}

module.exports = { resolveS3Target, createS3Client, DEFAULT_LOCAL_ENDPOINT };
