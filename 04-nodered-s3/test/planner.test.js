'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  planParts,
  buildCopySource,
  backoffDelay,
  runBounded,
  withRetry,
  createLogger,
  S3_LIMITS,
  UNITS: { MIB, GIB, TIB },
} = require('../lib/s3-multipart-copy.js');

/**
 * Walk a plan and assert the parts tile the object exactly: first byte at 0,
 * last byte at size-1, every part contiguous with its predecessor, no gaps and
 * no overlaps. This is the property that actually matters: a gap silently
 * corrupts the copy and S3 will not catch it for you.
 */
function assertExactCoverage(plan, size) {
  assert.equal(plan.parts.length, plan.partCount, 'parts array length matches partCount');
  assert.ok(plan.partCount >= 1, 'at least one part');
  assert.ok(plan.partCount <= S3_LIMITS.MAX_PARTS, `partCount ${plan.partCount} within 10000 ceiling`);

  assert.equal(plan.parts[0].start, 0, 'first part starts at byte 0');
  assert.equal(plan.parts[plan.parts.length - 1].end, size - 1, 'last part ends at size-1');

  let covered = 0;
  for (let i = 0; i < plan.parts.length; i += 1) {
    const part = plan.parts[i];
    assert.equal(part.partNumber, i + 1, 'part numbers are 1-based and sequential');
    assert.ok(part.start <= part.end, `part ${part.partNumber} has a non-empty range`);
    assert.equal(part.length, part.end - part.start + 1, 'length matches the range');
    assert.equal(part.range, `bytes=${part.start}-${part.end}`, 'range header is well formed');

    if (i > 0) {
      assert.equal(
        part.start,
        plan.parts[i - 1].end + 1,
        `part ${part.partNumber} starts exactly where part ${i} ended (no gap, no overlap)`,
      );
    }

    // Every part except the last must respect the 5 MiB floor, unless the whole
    // object is smaller than one part (the single-part case).
    if (i < plan.parts.length - 1) {
      assert.equal(part.length, plan.partSize, 'non-final parts are exactly one partSize');
      assert.ok(part.length >= S3_LIMITS.MIN_PART_SIZE, 'non-final part respects the 5 MiB floor');
    }
    assert.ok(part.length <= S3_LIMITS.MAX_PART_SIZE, 'no part exceeds the 5 GiB ceiling');

    covered += part.length;
  }

  assert.equal(covered, size, 'summed part lengths equal the object size exactly');
}

test('exact range coverage with no gaps or overlaps (uneven size)', () => {
  const size = 23 * MIB; // the integration fixture size
  const plan = planParts(size, 5 * MIB);
  assertExactCoverage(plan, size);
  assert.equal(plan.partCount, 5, '23 MiB at 5 MiB parts is 4 full parts plus a remainder');
});

test('even division leaves no remainder tail', () => {
  const size = 50 * MIB;
  const plan = planParts(size, 10 * MIB);
  assertExactCoverage(plan, size);
  assert.equal(plan.partCount, 5);
  for (const part of plan.parts) {
    assert.equal(part.length, 10 * MIB, 'every part is full sized when division is even');
  }
});

test('remainder tail is a short final part', () => {
  const size = 23 * MIB;
  const plan = planParts(size, 5 * MIB);
  assertExactCoverage(plan, size);
  const last = plan.parts[plan.parts.length - 1];
  assert.equal(last.length, 3 * MIB, 'tail carries the remainder');
  assert.ok(last.length < S3_LIMITS.MIN_PART_SIZE, 'final part is allowed below the 5 MiB floor');
});

test('part size is capped at the 5 GiB S3 maximum', () => {
  assert.throws(
    () => planParts(10 * GIB, 6 * GIB),
    (err) => err.code === 'PART_SIZE_TOO_LARGE',
    'requesting a part larger than 5 GiB is rejected',
  );

  // The default is exactly the maximum.
  const plan = planParts(12 * GIB);
  assert.equal(plan.requestedPartSize, S3_LIMITS.MAX_PART_SIZE, 'default part size is the 5 GiB maximum');
  assert.equal(plan.partSize, 5 * GIB);
  assert.equal(plan.partCount, 3, '12 GiB at 5 GiB parts is 3 parts');
  assertExactCoverage(plan, 12 * GIB);
});

test('a part size below the 5 MiB floor is lifted to the floor', () => {
  const size = 40 * MIB;
  const plan = planParts(size, 1 * MIB);
  assert.equal(plan.partSize, S3_LIMITS.MIN_PART_SIZE, '1 MiB request lifted to the 5 MiB minimum');
  assertExactCoverage(plan, size);
});

test('1 TB at the maximum part size stays well inside the part ceiling', () => {
  const size = 1 * TIB;
  const plan = planParts(size, S3_LIMITS.MAX_PART_SIZE);
  assertExactCoverage(plan, size);
  assert.equal(plan.autoRaised, false, 'no auto-raise needed at 5 GiB parts');
  assert.equal(plan.partSize, 5 * GIB);
  assert.equal(plan.partCount, 205, '1 TiB / 5 GiB = 204.8, so 205 parts');
});

test('1 TB at 5 MiB auto-raises the part size to stay under 10000 parts', () => {
  const size = 1 * TIB;
  const naiveParts = Math.ceil(size / (5 * MIB));
  assert.ok(naiveParts > S3_LIMITS.MAX_PARTS, `precondition: ${naiveParts} parts would be illegal`);

  const plan = planParts(size, 5 * MIB);
  assert.equal(plan.autoRaised, true, 'planner raised the part size on its own');
  assert.ok(plan.partCount <= S3_LIMITS.MAX_PARTS, `partCount ${plan.partCount} is legal`);
  assert.equal(plan.partSize % MIB, 0, 'raised part size is a whole number of MiB');
  assert.ok(plan.partSize > 5 * MIB, 'raised above the requested size');
  assert.ok(plan.partSize <= S3_LIMITS.MAX_PART_SIZE, 'still within the 5 GiB ceiling');
  assertExactCoverage(plan, size);
});

test('5 TiB maximum object is copyable at the default part size', () => {
  const size = S3_LIMITS.MAX_OBJECT_SIZE;
  const plan = planParts(size);
  assertExactCoverage(plan, size);
  assert.equal(plan.partSize, 5 * GIB);
  assert.equal(plan.partCount, 1024, '5 TiB / 5 GiB divides evenly into 1024 parts');
  assert.equal(plan.autoRaised, false);
});

test('5 TiB at 5 MiB still resolves by auto-raising', () => {
  const size = S3_LIMITS.MAX_OBJECT_SIZE;
  const plan = planParts(size, 5 * MIB);
  assert.equal(plan.autoRaised, true);
  assert.ok(plan.partCount <= S3_LIMITS.MAX_PARTS);
  assertExactCoverage(plan, size);
});

test('an object larger than 5 TiB is rejected', () => {
  assert.throws(
    () => planParts(S3_LIMITS.MAX_OBJECT_SIZE + 1),
    (err) => err.code === 'OBJECT_TOO_LARGE' && /5 TiB/.test(err.message),
    'over-size object rejected with a clear code',
  );
});

test('a zero-byte object is rejected', () => {
  assert.throws(
    () => planParts(0),
    (err) => err.code === 'EMPTY_OBJECT',
    'zero bytes cannot be expressed as a multipart copy',
  );
  assert.throws(() => planParts(-1), (err) => err.code === 'EMPTY_OBJECT');
});

test('non-integer sizes are rejected', () => {
  assert.throws(() => planParts(1.5), (err) => err.code === 'INVALID_SIZE');
  assert.throws(() => planParts('100'), (err) => err.code === 'INVALID_SIZE');
  assert.throws(() => planParts(NaN), (err) => err.code === 'INVALID_SIZE');
});

test('a single-byte object produces exactly one part', () => {
  const plan = planParts(1);
  assert.equal(plan.partCount, 1);
  assert.equal(plan.parts[0].range, 'bytes=0-0');
  assertExactCoverage(plan, 1);
});

test('an object exactly one part long produces one part', () => {
  const size = 5 * MIB;
  const plan = planParts(size, 5 * MIB);
  assert.equal(plan.partCount, 1);
  assertExactCoverage(plan, size);
});

test('CopySource percent-encodes the key but preserves slashes', () => {
  assert.equal(buildCopySource('src', 'plain.bin'), 'src/plain.bin');
  assert.equal(
    buildCopySource('src', 'folder/with space/file (1).bin'),
    'src/folder/with%20space/file%20(1).bin',
    'spaces encoded, directory slashes intact',
  );
  assert.equal(buildCopySource('src', 'a+b/c#d.bin'), 'src/a%2Bb/c%23d.bin', 'plus and hash encoded');
  assert.equal(buildCopySource('src', 'unicode/ملف.bin'), 'src/unicode/%D9%85%D9%84%D9%81.bin');
});

test('backoff grows exponentially and stays within the ceiling', () => {
  // random() pinned to 1 yields the upper bound of the full-jitter window.
  const max = (attempt) => backoffDelay(attempt, { random: () => 0.999999 });
  assert.ok(max(0) <= 100);
  assert.ok(max(1) <= 200);
  assert.ok(max(2) <= 400);
  assert.ok(max(10) <= 20000, 'capped at the 20s ceiling');
  assert.equal(backoffDelay(5, { random: () => 0 }), 0, 'full jitter can return zero');
});

test('runBounded honours the concurrency ceiling and preserves order', async () => {
  const items = Array.from({ length: 20 }, (_, i) => i);
  let inFlight = 0;
  let peak = 0;

  const results = await runBounded(items, 4, async (item) => {
    inFlight += 1;
    peak = Math.max(peak, inFlight);
    await new Promise((r) => setTimeout(r, 5));
    inFlight -= 1;
    return item * 2;
  });

  assert.ok(peak <= 4, `peak concurrency ${peak} never exceeded the limit of 4`);
  assert.ok(peak > 1, 'work actually ran in parallel');
  assert.deepEqual(results, items.map((i) => i * 2), 'results returned in input order');
});

test('withRetry retries retryable errors and gives up on permanent ones', async () => {
  let calls = 0;
  const value = await withRetry(
    async () => {
      calls += 1;
      if (calls < 3) {
        const err = new Error('throttled');
        err.$metadata = { httpStatusCode: 503 };
        throw err;
      }
      return 'ok';
    },
    { maxRetries: 5, random: () => 0 },
  );
  assert.equal(value, 'ok');
  assert.equal(calls, 3, 'retried twice then succeeded');

  let permanentCalls = 0;
  await assert.rejects(
    () =>
      withRetry(
        async () => {
          permanentCalls += 1;
          const err = new Error('no such key');
          err.name = 'NoSuchKey';
          err.$metadata = { httpStatusCode: 404 };
          throw err;
        },
        { maxRetries: 5, random: () => 0 },
      ),
    /no such key/,
  );
  assert.equal(permanentCalls, 1, 'a 404 is not retried');
});

test('logger emits one JSON line per event carrying the correlationId', () => {
  const lines = [];
  const log = createLogger({ correlationId: 'test-correlation', sink: (l) => lines.push(l) });

  log('copy.start', { sizeBytes: 10 });
  log('copy.failed', { error: 'boom', level: 'error' });

  assert.equal(lines.length, 2);
  const first = JSON.parse(lines[0]);
  assert.equal(first.event, 'copy.start');
  assert.equal(first.correlationId, 'test-correlation');
  assert.equal(first.level, 'info');
  assert.equal(first.sizeBytes, 10);
  assert.ok(Date.parse(first.ts), 'ts is a parseable ISO timestamp');

  const second = JSON.parse(lines[1]);
  assert.equal(second.level, 'error');
  assert.equal(second.correlationId, 'test-correlation', 'same correlationId across the copy');
});
