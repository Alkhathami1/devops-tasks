#!/usr/bin/env node
'use strict';

/**
 * Prints the part plan the engine would choose for a range of object sizes.
 *
 * This is the evidence for the "raise the upload size limit to the maximum"
 * requirement: the default part size is the S3 maximum of 5 GiB, and the
 * planner raises it further only when the 10 000 part ceiling forces it to.
 */

const { planParts, S3_LIMITS, UNITS: { MIB, GIB, TIB } } = require('../lib/s3-multipart-copy.js');

const human = (bytes) => {
  if (bytes >= TIB) return `${(bytes / TIB).toFixed(2)} TiB`;
  if (bytes >= GIB) return `${(bytes / GIB).toFixed(2)} GiB`;
  if (bytes >= MIB) return `${(bytes / MIB).toFixed(2)} MiB`;
  return `${bytes} B`;
};

console.log('S3 multipart limits enforced by the planner');
console.log('------------------------------------------');
console.log(`  minimum part size : ${S3_LIMITS.MIN_PART_SIZE.toLocaleString()} bytes (${human(S3_LIMITS.MIN_PART_SIZE)})`);
console.log(`  maximum part size : ${S3_LIMITS.MAX_PART_SIZE.toLocaleString()} bytes (${human(S3_LIMITS.MAX_PART_SIZE)})  <-- default`);
console.log(`  maximum parts     : ${S3_LIMITS.MAX_PARTS.toLocaleString()}`);
console.log(`  maximum object    : ${S3_LIMITS.MAX_OBJECT_SIZE.toLocaleString()} bytes (${human(S3_LIMITS.MAX_OBJECT_SIZE)})`);
console.log('');

const scenarios = [
  { size: 23 * MIB, requested: 5 * MIB, note: 'integration fixture, forces multiple parts' },
  { size: 23 * MIB, requested: undefined, note: 'same object at the default 5 GiB part size' },
  { size: 100 * GIB, requested: undefined, note: 'large object, default part size' },
  { size: 1 * TIB, requested: undefined, note: '1 TiB at the maximum part size' },
  { size: 1 * TIB, requested: 5 * MIB, note: '1 TiB at the minimum part size -> must auto-raise' },
  { size: 5 * TIB, requested: undefined, note: 'maximum legal object at the default part size' },
  { size: 5 * TIB, requested: 5 * MIB, note: 'maximum legal object at the minimum -> must auto-raise' },
];

const header = ['object size', 'requested part', 'chosen part', 'parts', 'auto-raised'];
const rows = scenarios.map(({ size, requested }) => {
  const plan = planParts(size, requested === undefined ? undefined : requested);
  return [
    human(size),
    requested === undefined ? 'default (5 GiB)' : human(requested),
    human(plan.partSize),
    String(plan.partCount),
    plan.autoRaised ? 'YES' : 'no',
  ];
});

const widths = header.map((h, i) => Math.max(h.length, ...rows.map((r) => r[i].length)));
const line = (cells) => cells.map((c, i) => c.padEnd(widths[i])).join('  ');

console.log('Part plans by object size');
console.log('-------------------------');
console.log(line(header));
console.log(widths.map((w) => '-'.repeat(w)).join('  '));
rows.forEach((r, i) => {
  console.log(line(r) + `   # ${scenarios[i].note}`);
});

console.log('');
console.log('Rejected inputs');
console.log('---------------');
for (const [label, size] of [
  ['zero-byte object', 0],
  ['object larger than 5 TiB', S3_LIMITS.MAX_OBJECT_SIZE + 1],
]) {
  try {
    planParts(size);
    console.log(`  ${label}: NOT REJECTED  <-- unexpected`);
  } catch (error) {
    console.log(`  ${label}: rejected with ${error.code} - ${error.message}`);
  }
}
try {
  planParts(10 * GIB, 6 * GIB);
  console.log('  part size above 5 GiB: NOT REJECTED  <-- unexpected');
} catch (error) {
  console.log(`  part size above 5 GiB: rejected with ${error.code} - ${error.message}`);
}
