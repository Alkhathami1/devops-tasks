# Task 04 — Node-RED S3 → S3 multipart copy

Copies an object between S3 buckets using a **server-side multipart copy**
(`UploadPartCopy`). The object bytes never pass through Node-RED: only
control-plane API calls are made, so copy time and memory use are independent
of object size.

## Layout

| Path | What it is |
|---|---|
| `lib/s3-multipart-copy.js` | The engine. Plain Node module, no Node-RED APIs, unit testable. |
| `settings.js` | Node-RED settings; injects the engine via `functionGlobalContext`. |
| `flows/flows.json` | Importable Node-RED flow. **Generated** — edit `scripts/build-flow.js`. |
| `scripts/build-flow.js` | Regenerates `flows/flows.json`. |
| `scripts/copy-cli.js` | Runs a copy from the command line; prints the JSON log stream. |
| `scripts/verify-e2e.js` | Drives the running flow over HTTP and verifies the result via the S3 API. |
| `scripts/bucket-state.js` | Lists objects, ETags and orphaned multipart uploads. |
| `test/planner.test.js` | Unit tests for the part planner and helpers. |
| `test/integration/moto-copy.test.js` | Integration tests against moto. |

## S3 limits enforced

| Limit | Value |
|---|---|
| Minimum part size | 5 MiB (last part exempt) |
| **Maximum part size** | **5 GiB — the default used here** |
| Maximum parts | 10,000 |
| Maximum object | 5 TiB |

The part size defaults to the 5 GiB maximum. When `ceil(size / 10000)` exceeds
the requested part size, the planner raises the part size to that value rounded
up to a whole MiB, so any legal object copies without operator input.

> **Note:** at a 5 GiB part size most test files are a *single* part. To prove
> multipart genuinely works you must request a smaller part size — the
> integration test uses 5 MiB against a 23 MiB fixture to get 5 parts.

## Reproducing

```bash
npm install

# 1. Unit tests (no dependencies)
#    Note: `node --test test/` fails on Node 22+; glob the files explicitly.
node --test test/*.test.js

# 2. Start a local S3-compatible server
docker run -d --name moto -p 5000:5000 motoserver/moto

# 3. Integration tests
export S3_ENDPOINT=http://127.0.0.1:5000
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
node --test test/integration/*.test.js

# 4. Node-RED end to end
node node_modules/node-red/red.js --settings ./settings.js &
curl -X POST http://127.0.0.1:1880/copy \
  -H 'Content-Type: application/json' \
  -d '{"source":{"bucket":"task04-source","key":"fixtures/large file (23MiB).bin"},
       "destination":{"bucket":"task04-destination","key":"copied/out.bin"},
       "partSize":5242880,"concurrency":3}'

node scripts/verify-e2e.js     # independent verification
node scripts/bucket-state.js   # objects, ETags, orphan count
```

Editor: <http://127.0.0.1:1880/> — the flow loads from `flows/flows.json`.

## Configuration

Credentials come from the environment, never from the repository.

| Variable | Default | Purpose |
|---|---|---|
| `S3_ENDPOINT` | `http://127.0.0.1:5000` for scripts/tests; real AWS for the Node-RED runtime | A URL targets that endpoint; the literal `aws` targets real AWS |
| `AWS_REGION` | `us-east-1` | |
| `AWS_ACCESS_KEY_ID` | `test` (local targets only) | Ignored for real AWS — the SDK credential chain is used |
| `AWS_SECRET_ACCESS_KEY` | `test` (local targets only) | Ignored for real AWS |
| `NODE_RED_PORT` | `1880` | |

> **Endpoint safety.** The scripts in `scripts/` default to the **local** endpoint, never real
> AWS. An earlier version used `S3_ENDPOINT ? … : {}`, which meant an unset variable silently
> pointed a debug script at production — a live request did reach AWS during review. Endpoint
> resolution now lives in `lib/s3-target.js`: tooling stays local unless you pass
> `S3_ENDPOINT=aws`, every script prints the target it resolved, and the integration suite
> refuses to run against real AWS because it creates buckets and writes objects.

## API

`POST /copy`

```json
{
  "source":      { "bucket": "src", "key": "path/to/object" },
  "destination": { "bucket": "dst", "key": "path/to/copy" },
  "partSize":    5242880,
  "concurrency": 4
}
```

- `200` — `{ ok: true, result: {...}, logs: [...] }`
- `400` — validation failure, with a `details` array
- `500` — copy failure; the multipart upload has been aborted

## Verifying multipart was actually used

Check the destination ETag. A single-`PUT` object has a plain MD5 ETag; a
multipart object's ETag is a digest-of-digests with the part count appended:

```
source:      50a9562aa87bb7828a854ac3a5d95643      single PUT
destination: 66252e6c35e6a9b5920dd03b36cc164e-5    multipart, 5 parts
```

## Failure handling

Every failure path calls `AbortMultipartUpload`. An abandoned upload keeps its
uploaded parts in S3 — billed as storage, and invisible to a normal object
listing. `scripts/bucket-state.js` reports the orphan count and exits non-zero
if it is not zero.
