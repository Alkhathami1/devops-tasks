'use strict';

/**
 * Server-side S3 -> S3 multipart copy.
 *
 * The object bytes are moved by S3 itself via UploadPartCopy (a server-side
 * range copy). Nothing downloads through this process: we only ever send
 * control-plane API calls. See README.md for the justification versus a
 * GetObject -> PutObject pipe.
 *
 * This module deliberately contains NO Node-RED APIs so it can be unit tested
 * with plain `node --test`. Node-RED reaches it through functionGlobalContext
 * (see ../settings.js).
 */

const crypto = require('node:crypto');

const KIB = 1024;
const MIB = 1024 * KIB;
const GIB = 1024 * MIB;
const TIB = 1024 * GIB;

/**
 * Hard limits imposed by the S3 multipart upload API.
 * https://docs.aws.amazon.com/AmazonS3/latest/userguide/qfacts.html
 */
const S3_LIMITS = Object.freeze({
  /** Minimum size of any part except the last one. */
  MIN_PART_SIZE: 5 * MIB, //             5 242 880
  /** Maximum size of a single part. This is the "maximum upload size". */
  MAX_PART_SIZE: 5 * GIB, //         5 368 709 120
  /** Maximum number of parts in one multipart upload. */
  MAX_PARTS: 10000,
  /** Maximum size of a single object. */
  MAX_OBJECT_SIZE: 5 * TIB, //   5 497 558 138 880
});

/** Errors thrown by the planner carry this name so callers can map them to 4xx. */
class MultipartCopyError extends Error {
  constructor(message, { code, retryable = false, cause } = {}) {
    super(message);
    this.name = 'MultipartCopyError';
    this.code = code || 'MULTIPART_COPY_ERROR';
    this.retryable = retryable;
    if (cause) this.cause = cause;
  }
}

const roundUpToMiB = (bytes) => Math.ceil(bytes / MIB) * MIB;

/**
 * Work out the part boundaries for an object of `size` bytes.
 *
 * `requestedPartSize` defaults to the S3 maximum (5 GiB) because the assignment
 * asks for the upload size limit to be raised to its maximum. The requested
 * size is then adjusted upwards when it cannot express the object within the
 * 10 000 part ceiling, so any legal object copies without operator input.
 *
 * @returns {{partSize:number, partCount:number, autoRaised:boolean,
 *            requestedPartSize:number, parts:Array<{partNumber:number,
 *            start:number, end:number, length:number, range:string}>}}
 */
function planParts(size, requestedPartSize = S3_LIMITS.MAX_PART_SIZE) {
  if (!Number.isInteger(size)) {
    throw new MultipartCopyError(`Object size must be an integer, received ${size}`, {
      code: 'INVALID_SIZE',
    });
  }
  if (size <= 0) {
    // A zero-byte object has no ranges to copy. UploadPartCopy would reject the
    // empty range, so refuse here with a clear message instead.
    throw new MultipartCopyError(
      `Object size must be greater than 0 bytes; multipart copy cannot express a ${size}-byte object`,
      { code: 'EMPTY_OBJECT' },
    );
  }
  if (size > S3_LIMITS.MAX_OBJECT_SIZE) {
    throw new MultipartCopyError(
      `Object size ${size} exceeds the S3 maximum object size of ${S3_LIMITS.MAX_OBJECT_SIZE} bytes (5 TiB)`,
      { code: 'OBJECT_TOO_LARGE' },
    );
  }
  if (!Number.isInteger(requestedPartSize) || requestedPartSize <= 0) {
    throw new MultipartCopyError(
      `Requested part size must be a positive integer, received ${requestedPartSize}`,
      { code: 'INVALID_PART_SIZE' },
    );
  }
  if (requestedPartSize > S3_LIMITS.MAX_PART_SIZE) {
    throw new MultipartCopyError(
      `Requested part size ${requestedPartSize} exceeds the S3 maximum part size of ${S3_LIMITS.MAX_PART_SIZE} bytes (5 GiB)`,
      { code: 'PART_SIZE_TOO_LARGE' },
    );
  }

  // A part below the 5 MiB floor is illegal for every part but the last, so
  // lift the request to the floor rather than failing a copy over a detail the
  // caller almost certainly did not mean.
  let partSize = Math.max(requestedPartSize, S3_LIMITS.MIN_PART_SIZE);

  // The 10 000 part ceiling sets a floor on part size for large objects.
  // Round to a whole MiB so the resulting number stays legible in logs.
  const sizeImpliedMinimum = Math.ceil(size / S3_LIMITS.MAX_PARTS);
  let autoRaised = false;
  if (sizeImpliedMinimum > partSize) {
    partSize = Math.min(roundUpToMiB(sizeImpliedMinimum), S3_LIMITS.MAX_PART_SIZE);
    autoRaised = true;
  }

  const partCount = Math.ceil(size / partSize);
  if (partCount > S3_LIMITS.MAX_PARTS) {
    // Unreachable for legal object sizes (5 TiB / 10 000 is ~524 MiB, far below
    // the 5 GiB part ceiling) but asserted so a future limits edit cannot
    // silently produce an illegal plan.
    throw new MultipartCopyError(
      `Computed ${partCount} parts at ${partSize} bytes, exceeding the S3 maximum of ${S3_LIMITS.MAX_PARTS}`,
      { code: 'TOO_MANY_PARTS' },
    );
  }

  const parts = [];
  for (let index = 0; index < partCount; index += 1) {
    const start = index * partSize;
    const end = Math.min(start + partSize, size) - 1; // inclusive, HTTP range semantics
    parts.push({
      partNumber: index + 1, // S3 part numbers are 1-based
      start,
      end,
      length: end - start + 1,
      range: `bytes=${start}-${end}`,
    });
  }

  return {
    partSize,
    partCount,
    autoRaised,
    requestedPartSize,
    parts,
  };
}

/**
 * Build the CopySource header value.
 *
 * The key is percent-encoded because keys may legitimately contain spaces,
 * '+', '#' or non-ASCII characters, any of which would otherwise corrupt the
 * header. Slashes are preserved so the key hierarchy survives encoding.
 */
function buildCopySource(bucket, key) {
  const encodedKey = String(key)
    .split('/')
    .map((segment) => encodeURIComponent(segment))
    .join('/');
  return `${bucket}/${encodedKey}`;
}

/** Structured JSON logger. One line per event, all sharing a correlationId. */
function createLogger({ correlationId, sink = console.log, base = {} } = {}) {
  return function emit(event, fields = {}) {
    const { level = 'info', ...rest } = fields;
    const record = {
      ts: new Date().toISOString(),
      level,
      event,
      correlationId,
      ...base,
      ...rest,
    };
    sink(JSON.stringify(record));
    return record;
  };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Transient conditions worth another attempt. */
function isRetryable(error) {
  if (!error) return false;
  if (error.$retryable && error.$retryable.throttling) return true;
  const status = error.$metadata && error.$metadata.httpStatusCode;
  if (status && (status === 429 || status >= 500)) return true;
  const retryableNames = new Set([
    'RequestTimeout',
    'RequestTimeTooSkewed',
    'SlowDown',
    'ThrottlingException',
    'InternalError',
    'ServiceUnavailable',
    'ECONNRESET',
    'ETIMEDOUT',
    'EPIPE',
    'ENOTFOUND',
    'EAI_AGAIN',
  ]);
  return retryableNames.has(error.name) || retryableNames.has(error.code);
}

/**
 * Exponential backoff with full jitter, which spreads a retry storm instead of
 * synchronising every worker onto the same retry instant.
 */
function backoffDelay(attempt, { baseMs = 100, maxMs = 20000, random = Math.random } = {}) {
  const ceiling = Math.min(maxMs, baseMs * 2 ** attempt);
  return Math.floor(random() * ceiling);
}

async function withRetry(operation, { maxRetries, onRetry, random } = {}) {
  let attempt = 0;
  for (;;) {
    try {
      return await operation(attempt);
    } catch (error) {
      if (attempt >= maxRetries || !isRetryable(error)) throw error;
      const delay = backoffDelay(attempt, { random });
      if (onRetry) onRetry({ attempt: attempt + 1, delayMs: delay, error });
      await sleep(delay);
      attempt += 1;
    }
  }
}

/**
 * Run `worker` over `items` with at most `concurrency` in flight.
 * Results are returned in the original item order.
 */
async function runBounded(items, concurrency, worker) {
  const results = new Array(items.length);
  let cursor = 0;
  const lanes = new Array(Math.max(1, Math.min(concurrency, items.length)));

  for (let lane = 0; lane < lanes.length; lane += 1) {
    lanes[lane] = (async () => {
      for (;;) {
        const index = cursor;
        cursor += 1;
        if (index >= items.length) return;
        results[index] = await worker(items[index], index);
      }
    })();
  }

  await Promise.all(lanes);
  return results;
}

/**
 * Copy an object between buckets using a server-side multipart copy.
 *
 * @param {object} options
 * @param {object} options.s3 An @aws-sdk/client-s3 S3Client instance.
 * @param {object} options.commands The SDK command constructors (injected so
 *        this module stays testable without importing the SDK itself).
 * @param {{bucket:string,key:string}} options.source
 * @param {{bucket:string,key:string}} options.destination
 * @param {number} [options.partSize] Defaults to the 5 GiB S3 maximum.
 * @param {number} [options.concurrency] Parts copied in parallel.
 * @param {number} [options.maxRetries] Retries per part.
 */
async function copyObject(options) {
  const {
    s3,
    commands,
    source,
    destination,
    partSize: requestedPartSize = S3_LIMITS.MAX_PART_SIZE,
    concurrency = 4,
    maxRetries = 5,
    correlationId = crypto.randomUUID(),
    logSink,
    random,
  } = options;

  const {
    HeadObjectCommand,
    CreateMultipartUploadCommand,
    UploadPartCopyCommand,
    CompleteMultipartUploadCommand,
    AbortMultipartUploadCommand,
  } = commands;

  const log = createLogger({ correlationId, sink: logSink });
  const startedAt = Date.now();

  log('copy.start', {
    source: { bucket: source.bucket, key: source.key },
    destination: { bucket: destination.bucket, key: destination.key },
    requestedPartSize,
    concurrency,
    maxRetries,
  });

  let uploadId = null;

  try {
    // ---- 1. Inspect the source -------------------------------------------
    // A HEAD request that 404s carries no response body, so the SDK surfaces it
    // as a bare "UnknownError". Translate it into something a log reader can
    // act on without having to go and look up the correlationId in S3.
    const head = await withRetry(
      () => s3.send(new HeadObjectCommand({ Bucket: source.bucket, Key: source.key })),
      { maxRetries, random, onRetry: (r) => log('source.inspect.retry', { ...r, error: r.error.message, level: 'warn' }) },
    ).catch((error) => {
      const status = error.$metadata && error.$metadata.httpStatusCode;
      if (status === 404 || error.name === 'NotFound' || error.name === 'NoSuchKey') {
        throw new MultipartCopyError(
          `Source object not found: s3://${source.bucket}/${source.key}`,
          { code: 'SOURCE_NOT_FOUND', cause: error },
        );
      }
      if (status === 403) {
        throw new MultipartCopyError(
          `Access denied reading source: s3://${source.bucket}/${source.key}`,
          { code: 'SOURCE_ACCESS_DENIED', cause: error },
        );
      }
      throw error;
    });

    const size = Number(head.ContentLength);
    log('source.inspected', {
      sizeBytes: size,
      contentType: head.ContentType || null,
      sourceETag: head.ETag || null,
      lastModified: head.LastModified ? new Date(head.LastModified).toISOString() : null,
    });

    // ---- 2. Plan the parts ------------------------------------------------
    const plan = planParts(size, requestedPartSize);
    log('plan.computed', {
      sizeBytes: size,
      partSize: plan.partSize,
      partSizeMiB: plan.partSize / MIB,
      partCount: plan.partCount,
      autoRaised: plan.autoRaised,
      requestedPartSize: plan.requestedPartSize,
      reason: plan.autoRaised
        ? `requested part size would need ${Math.ceil(size / plan.requestedPartSize)} parts, above the ${S3_LIMITS.MAX_PARTS} part ceiling`
        : 'requested part size satisfies the part-count ceiling',
    });

    // ---- 3. Open the multipart upload -------------------------------------
    const created = await withRetry(
      () =>
        s3.send(
          new CreateMultipartUploadCommand({
            Bucket: destination.bucket,
            Key: destination.key,
            ...(head.ContentType ? { ContentType: head.ContentType } : {}),
          }),
        ),
      { maxRetries, random, onRetry: (r) => log('upload.create.retry', { ...r, error: r.error.message, level: 'warn' }) },
    );
    uploadId = created.UploadId;
    log('upload.created', { uploadId, destination: { bucket: destination.bucket, key: destination.key } });

    // ---- 4. Copy every part, server side ----------------------------------
    const copySource = buildCopySource(source.bucket, source.key);
    let bytesCopied = 0;
    let partsDone = 0;

    const copied = await runBounded(plan.parts, concurrency, async (part) => {
      const partStartedAt = Date.now();
      const response = await withRetry(
        () =>
          s3.send(
            new UploadPartCopyCommand({
              Bucket: destination.bucket,
              Key: destination.key,
              UploadId: uploadId,
              PartNumber: part.partNumber,
              CopySource: copySource,
              CopySourceRange: part.range,
            }),
          ),
        {
          maxRetries,
          random,
          onRetry: (r) =>
            log('part.retry', {
              partNumber: part.partNumber,
              attempt: r.attempt,
              delayMs: r.delayMs,
              error: r.error.message,
              level: 'warn',
            }),
        },
      );

      bytesCopied += part.length;
      partsDone += 1;
      const durationMs = Date.now() - partStartedAt;

      log('part.copied', {
        partNumber: part.partNumber,
        range: part.range,
        bytes: part.length,
        durationMs,
        eTag: response.CopyPartResult && response.CopyPartResult.ETag,
        progress: {
          partsDone,
          partCount: plan.partCount,
          bytesCopied,
          totalBytes: size,
          percent: Number(((bytesCopied / size) * 100).toFixed(2)),
        },
      });

      return {
        PartNumber: part.partNumber,
        ETag: response.CopyPartResult && response.CopyPartResult.ETag,
      };
    });

    // ---- 5. Complete -------------------------------------------------------
    // S3 rejects a parts list that is not ascending by PartNumber.
    const parts = [...copied].sort((a, b) => a.PartNumber - b.PartNumber);

    const completed = await withRetry(
      () =>
        s3.send(
          new CompleteMultipartUploadCommand({
            Bucket: destination.bucket,
            Key: destination.key,
            UploadId: uploadId,
            MultipartUpload: { Parts: parts },
          }),
        ),
      { maxRetries, random, onRetry: (r) => log('upload.complete.retry', { ...r, error: r.error.message, level: 'warn' }) },
    );

    const durationMs = Date.now() - startedAt;
    const result = {
      ok: true,
      correlationId,
      source: { bucket: source.bucket, key: source.key },
      destination: { bucket: destination.bucket, key: destination.key },
      sizeBytes: size,
      partSize: plan.partSize,
      partCount: plan.partCount,
      autoRaised: plan.autoRaised,
      eTag: completed.ETag,
      location: completed.Location,
      durationMs,
      throughputMBps: durationMs > 0 ? Number(((size / (1024 * 1024)) / (durationMs / 1000)).toFixed(2)) : null,
    };

    log('copy.complete', result);
    return result;
  } catch (error) {
    // ---- Failure path: never leave parts behind ---------------------------
    // Orphaned parts are billed as storage until a lifecycle rule reaps them,
    // and they are invisible in a normal object listing.
    if (uploadId) {
      try {
        await s3.send(
          new AbortMultipartUploadCommand({
            Bucket: destination.bucket,
            Key: destination.key,
            UploadId: uploadId,
          }),
        );
        log('upload.aborted', { uploadId, reason: error.message, level: 'warn' });
      } catch (abortError) {
        log('upload.abort.failed', {
          uploadId,
          error: abortError.message,
          level: 'error',
          note: 'Orphaned parts may remain and will accrue storage charges until reaped',
        });
      }
    }

    log('copy.failed', {
      error: error.message,
      code: error.code || error.name,
      durationMs: Date.now() - startedAt,
      level: 'error',
    });
    throw error;
  }
}

module.exports = {
  copyObject,
  planParts,
  buildCopySource,
  createLogger,
  backoffDelay,
  isRetryable,
  runBounded,
  withRetry,
  MultipartCopyError,
  S3_LIMITS,
  UNITS: { KIB, MIB, GIB, TIB },
};
