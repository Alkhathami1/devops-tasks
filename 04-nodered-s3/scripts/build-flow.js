#!/usr/bin/env node
'use strict';

/**
 * Generates flows/flows.json.
 *
 * The flow is generated rather than hand-written because Node-RED stores
 * function bodies as JSON string literals with escaped newlines, which are
 * miserable to edit and easy to corrupt by hand. Edit the function sources
 * below, re-run this script, and commit the regenerated flows.json.
 */

const fs = require('node:fs');
const path = require('node:path');

const TAB = 'task04-s3-multipart';

// --------------------------------------------------------------------------
// Function node bodies
// --------------------------------------------------------------------------

const VALIDATE = `
// Normalise and validate the copy request.
// Output 1 -> valid, forwarded to the copy engine.
// Output 2 -> invalid, short-circuited straight to the HTTP response.

const body = msg.payload || {};

const errors = [];
const pick = (obj, name) => (obj && typeof obj === 'object' ? obj : {})[name];

const sourceBucket = pick(body.source, 'bucket');
const sourceKey = pick(body.source, 'key');
const destBucket = pick(body.destination, 'bucket');
const destKey = pick(body.destination, 'key');

if (!sourceBucket) errors.push('source.bucket is required');
if (!sourceKey) errors.push('source.key is required');
if (!destBucket) errors.push('destination.bucket is required');
if (!destKey) errors.push('destination.key is required');

if (body.partSize !== undefined) {
    const n = Number(body.partSize);
    if (!Number.isInteger(n) || n <= 0) errors.push('partSize must be a positive integer number of bytes');
}
if (body.concurrency !== undefined) {
    const n = Number(body.concurrency);
    if (!Number.isInteger(n) || n < 1) errors.push('concurrency must be a positive integer');
}

if (errors.length > 0) {
    msg.statusCode = 400;
    msg.payload = { ok: false, error: 'invalid request', details: errors };
    node.status({ fill: 'red', shape: 'ring', text: 'invalid request' });
    return [null, msg];
}

msg.copyRequest = {
    source: { bucket: sourceBucket, key: sourceKey },
    destination: { bucket: destBucket, key: destKey },
};
if (body.partSize !== undefined) msg.copyRequest.partSize = Number(body.partSize);
if (body.concurrency !== undefined) msg.copyRequest.concurrency = Number(body.concurrency);

node.status({ fill: 'blue', shape: 'dot', text: 'validated' });
return [msg, null];
`.trim();

const RUN_COPY = `
// Execute the server-side multipart copy.
//
// The engine is a plain Node module injected through functionGlobalContext
// (see settings.js), so it carries no Node-RED coupling and is unit tested
// independently.

const engine = global.get('s3copy');
const s3 = global.get('s3Client');
const commands = global.get('s3Commands');

if (!engine || !s3 || !commands) {
    node.error('s3copy/s3Client/s3Commands missing from functionGlobalContext - check settings.js', msg);
    return null;
}

const request = msg.copyRequest;
const logs = [];

node.status({ fill: 'blue', shape: 'dot', text: 'copying...' });

// Node-RED function nodes are most portable when async work is done in an
// IIFE with explicit node.send/node.done rather than a returned promise.
(async () => {
    try {
        const result = await engine.copyObject({
            s3,
            commands,
            source: request.source,
            destination: request.destination,
            partSize: request.partSize,
            concurrency: request.concurrency,
            logSink: (line) => {
                logs.push(JSON.parse(line));
                node.warn(line); // surfaces the structured line in the Node-RED log
            },
        });

        msg.statusCode = 200;
        msg.payload = { ok: true, result, logs };
        node.status({ fill: 'green', shape: 'dot', text: result.partCount + ' parts, ' + result.sizeBytes + ' B' });
        node.send(msg);
        node.done();
    } catch (error) {
        msg.statusCode = 500;
        msg.payload = {
            ok: false,
            error: error.message,
            code: error.code || error.name,
            logs,
        };
        node.status({ fill: 'red', shape: 'dot', text: 'failed: ' + (error.code || error.name) });
        // node.error with msg routes into the Catch node while still allowing
        // the HTTP request to be answered.
        node.error(error, msg);
        node.done();
    }
})();

return null;
`.trim();

const RESPOND_IF_HTTP = `
// Inject-triggered runs have no msg.res. Only forward to the HTTP Response
// node when this message actually came from an HTTP request, otherwise the
// response node logs "No response object".

if (msg.res) return msg;
node.status({ fill: 'grey', shape: 'ring', text: 'non-HTTP run, not responding' });
return null;
`.trim();

const FORMAT_ERROR = `
// Catch node handler: shape any uncaught error into the same JSON envelope
// the happy path uses, so API consumers see one consistent contract.

const err = msg.error || {};

msg.statusCode = msg.statusCode || 500;
msg.payload = {
    ok: false,
    error: err.message || 'unknown error',
    source: err.source ? { id: err.source.id, type: err.source.type } : undefined,
    logs: (msg.payload && msg.payload.logs) || [],
};

node.status({ fill: 'red', shape: 'dot', text: 'error caught' });
return msg;
`.trim();

// --------------------------------------------------------------------------
// Flow definition
// --------------------------------------------------------------------------

const flows = [
  {
    id: TAB,
    type: 'tab',
    label: 'Task 04 - S3 multipart copy',
    disabled: false,
    info:
      'Server-side S3 to S3 copy using UploadPartCopy.\n\n' +
      'POST /copy with a JSON body:\n' +
      '{\n' +
      '  "source":      { "bucket": "src",  "key": "path/to/object" },\n' +
      '  "destination": { "bucket": "dst",  "key": "path/to/copy" },\n' +
      '  "partSize":    5242880,\n' +
      '  "concurrency": 4\n' +
      '}\n\n' +
      'partSize defaults to the S3 maximum of 5 GiB and is raised automatically\n' +
      'when the object would otherwise need more than 10000 parts.',
    env: [],
  },

  {
    id: 'http-copy-in',
    type: 'http in',
    z: TAB,
    name: 'POST /copy',
    url: '/copy',
    method: 'post',
    upload: false,
    swaggerDoc: '',
    x: 140,
    y: 120,
    wires: [['validate-request']],
  },

  {
    id: 'manual-inject',
    type: 'inject',
    z: TAB,
    name: 'manual run (edit payload)',
    props: [{ p: 'payload' }],
    repeat: '',
    crontab: '',
    once: false,
    onceDelay: 0.1,
    topic: '',
    payload:
      '{"source":{"bucket":"task04-source","key":"fixtures/large file (23MiB).bin"},' +
      '"destination":{"bucket":"task04-destination","key":"copied/from-inject.bin"},' +
      '"partSize":5242880,"concurrency":3}',
    payloadType: 'json',
    x: 180,
    y: 200,
    wires: [['validate-request']],
  },

  {
    id: 'validate-request',
    type: 'function',
    z: TAB,
    name: 'validate request',
    func: VALIDATE,
    outputs: 2,
    noerr: 0,
    initialize: '',
    finalize: '',
    libs: [],
    x: 410,
    y: 140,
    wires: [['run-copy'], ['respond-if-http', 'debug-rejected']],
  },

  {
    id: 'run-copy',
    type: 'function',
    z: TAB,
    name: 'run multipart copy',
    func: RUN_COPY,
    outputs: 1,
    noerr: 0,
    initialize: '',
    finalize: '',
    libs: [],
    x: 640,
    y: 120,
    wires: [['respond-if-http', 'debug-result']],
  },

  {
    id: 'respond-if-http',
    type: 'function',
    z: TAB,
    name: 'respond if HTTP',
    func: RESPOND_IF_HTTP,
    outputs: 1,
    noerr: 0,
    initialize: '',
    finalize: '',
    libs: [],
    x: 870,
    y: 140,
    wires: [['http-copy-out']],
  },

  {
    id: 'http-copy-out',
    type: 'http response',
    z: TAB,
    name: 'respond',
    statusCode: '',
    headers: {},
    x: 1080,
    y: 140,
    wires: [],
  },

  {
    id: 'catch-copy-errors',
    type: 'catch',
    z: TAB,
    name: 'catch copy errors',
    scope: null,
    uncaught: false,
    x: 410,
    y: 300,
    wires: [['format-error']],
  },

  {
    id: 'format-error',
    type: 'function',
    z: TAB,
    name: 'format error',
    func: FORMAT_ERROR,
    outputs: 1,
    noerr: 0,
    initialize: '',
    finalize: '',
    libs: [],
    x: 640,
    y: 300,
    wires: [['respond-if-http', 'debug-error']],
  },

  {
    id: 'debug-result',
    type: 'debug',
    z: TAB,
    name: 'copy result',
    active: true,
    tosidebar: true,
    console: false,
    tostatus: false,
    complete: 'payload',
    targetType: 'msg',
    statusVal: '',
    statusType: 'auto',
    x: 880,
    y: 60,
    wires: [],
  },

  {
    id: 'debug-error',
    type: 'debug',
    z: TAB,
    name: 'copy error',
    active: true,
    tosidebar: true,
    console: true,
    tostatus: false,
    complete: 'payload',
    targetType: 'msg',
    statusVal: '',
    statusType: 'auto',
    x: 880,
    y: 360,
    wires: [],
  },

  {
    id: 'debug-rejected',
    type: 'debug',
    z: TAB,
    name: 'rejected request',
    active: true,
    tosidebar: true,
    console: false,
    tostatus: false,
    complete: 'payload',
    targetType: 'msg',
    statusVal: '',
    statusType: 'auto',
    x: 890,
    y: 220,
    wires: [],
  },
];

const outPath = path.join(__dirname, '..', 'flows', 'flows.json');
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, JSON.stringify(flows, null, 2) + '\n', 'utf8');

// Fail loudly if the generated file is not valid JSON or not importable shape.
const reparsed = JSON.parse(fs.readFileSync(outPath, 'utf8'));
if (!Array.isArray(reparsed)) throw new Error('flows.json must be a JSON array');
const ids = reparsed.map((n) => n.id);
if (new Set(ids).size !== ids.length) throw new Error('duplicate node ids in flows.json');

console.log(`wrote ${outPath} (${reparsed.length} nodes)`);
