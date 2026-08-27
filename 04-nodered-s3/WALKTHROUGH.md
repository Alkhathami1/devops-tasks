# Task 4 — Node-RED: S3 to S3 copy by multipart upload

This is the long form of Task 4. Section 6 of `docs/REPORT.md` carries the
two-page summary; everything below is the reasoning, the full build, and the
findings that came out of running it.

Every figure names the evidence file it came from. The evidence lives in
`docs/evidence/04-*.log`.

---

## 1. What this task required, and how I read it

The requester's words:

> copy a file from one S3 bucket to another using Multi-Part Upload, raise the
> upload size limit to the maximum, and add appropriate logging

Three clauses. Two of them are ambiguous, and I resolved both explicitly rather
than picking one quietly.

**"Raise the upload size limit to the maximum" — which limit?** An S3 client
controls exactly one upload size: the part size. The object size is a property of
the object, and the number of parts follows from the other two. So the clause is
read as *part size*, and the default part size in the engine is **5 GiB**, the
largest part S3 accepts.

That reading has a consequence I did not expect when I made it, and it turns out
to be the most interesting thing in the task. At a 5 GiB part size, essentially
every file anyone would test with becomes a **single part**. Raising the limit to
the maximum and demonstrating that multipart works are both satisfiable, and they
are not satisfiable in the same run. Section 6.1 works through it, and it is why
the integration fixture explicitly asks for 5 MiB parts.

**"Copy" — through the runtime, or inside S3?** Implemented as a **server-side
copy**. `UploadPartCopy` tells S3 to copy a byte range directly from the source
object into a part of a new multipart upload. The object bytes never enter the
Node-RED process. Section 2.1 makes the case.

**"Appropriate logging"** is read as machine-readable structured logging, not
free text. One JSON object per line, every line in a copy carrying the same
correlation id, covering the whole lifecycle including the byte range and
duration of each individual part. A human can read it; more to the point, so can
a log aggregator, which is the situation "appropriate" actually describes.

---

## 2. Design decisions

### 2.1 `UploadPartCopy`, over `GetObject` → `PutObject`, over `CopyObject`

The decisive property: **`UploadPartCopy` moves the bytes inside S3, so copy time
and memory use are independent of the object size and of the link between the
Node-RED host and S3.** Node-RED sends control-plane calls and nothing else.

| Approach | Object bytes through Node-RED | Multipart upload | Object size ceiling |
|---|---|---|---|
| **`UploadPartCopy`** (chosen) | none | yes | 5 TiB |
| `GetObject` → `PutObject` | every byte, twice | optional | limited by host memory or disk |
| `CopyObject` (single call) | none | **no** | 5 GiB |

**`GetObject` → `PutObject` is rejected on scale.** A 1 TiB object would travel
down to the Node-RED host and back up again. Over a 100 Mbit link that is roughly
24 hours in each direction, and the copy's duration becomes a property of the
operator's connection rather than of S3. The memory shape is the second problem:
buffering a part locally puts up to a 5 GiB buffer in the heap of a runtime whose
function nodes were not designed to hold one. Streaming reduces the peak but does
not change the fact that every byte crosses the process.

**`CopyObject` is rejected on two specific counts.** It caps at 5 GiB, so it
cannot express the large-object case at all. And it is not a multipart upload —
it is a single server-side call — so it cannot satisfy an assignment whose
subject is multipart upload. For a small object and a different assignment it
would be the right answer, and it is worth saying so.

### 2.2 The engine is a plain Node module with no Node-RED APIs

`lib/s3-multipart-copy.js` contains no `node.send`, no `msg`, no `global.get` —
nothing from the Node-RED runtime. Node-RED reaches it through
`functionGlobalContext` in `settings.js`, and function nodes pick it up with
`global.get('s3copy')`.

The property that decided it: **the copy logic is testable under `node --test`
without starting a runtime.** 19 planner unit tests run in 214.7 ms
(`04-unit-tests.log`) because there is no flow to boot, no HTTP listener to bind,
and no editor to load. A function node containing the same logic would be a JSON
string literal inside `flows.json`, reachable only by starting Node-RED and
sending it a message.

The SDK command constructors are injected as an argument rather than imported by
the engine. That is what makes the fault-injection test in section 5.4 possible:
the test hands in a `UploadPartCopyCommand` whose constructor throws, and the
engine's abort path runs for real against real moto state.

### 2.3 `flows.json` is generated, not hand-edited

Node-RED stores function bodies as JSON string literals with escaped newlines.
Editing those by hand is error-prone in a way that produces a flow which loads
and misbehaves rather than one that fails to parse.

`scripts/build-flow.js` holds each function body as a readable template literal,
assembles the node graph as ordinary JavaScript objects, writes the file, and
then validates what it wrote — reparses it, asserts the top level is an array,
and asserts there are no duplicate node ids. The generated file stays committed
and importable as-is, and `settings.js` sets `flowFilePretty` so the diff of a
regeneration is readable.

### 2.4 The part-size planner auto-raises

The default part size is the 5 GiB maximum, as the requirement asks. A *fixed*
part size cannot copy every legal object, and the arithmetic is unforgiving:

- 10,000 parts is S3's ceiling.
- At the 5 MiB minimum part size, 10,000 parts spans 48.83 GiB. A 1 TiB object at
  that part size is not expressible.

So `planParts()` computes `ceil(size / 10000)` and, when that value is larger than
the requested part size, lifts the part size to it, rounded up to a whole MiB:

```js
const sizeImpliedMinimum = Math.ceil(size / S3_LIMITS.MAX_PARTS);
if (sizeImpliedMinimum > partSize) {
  partSize = Math.min(roundUpToMiB(sizeImpliedMinimum), S3_LIMITS.MAX_PART_SIZE);
  autoRaised = true;
}
```

Any legal object then copies without operator input, and the `autoRaised` flag
plus a `reason` string go into the `plan.computed` log line so the decision is
visible rather than silent.

A part size *below* the 5 MiB floor is lifted to the floor rather than rejected —
that is a detail the caller almost certainly did not mean, and failing a copy over
it helps nobody. A part size *above* 5 GiB is rejected, because that one is a
request S3 cannot honor.

### 2.5 Abort on every failure path

Every failure route through `copyObject()` calls `AbortMultipartUpload`, in a
`catch` that runs whenever `uploadId` is set:

```js
} catch (error) {
  if (uploadId) {
    try {
      await s3.send(new AbortMultipartUploadCommand({ ... }));
      log('upload.aborted', { uploadId, reason: error.message, level: 'warn' });
    } catch (abortError) {
      log('upload.abort.failed', { ... });
    }
  }
  log('copy.failed', { ... });
  throw error;
}
```

The property that makes this non-optional: **an abandoned multipart upload keeps
its already-uploaded parts in S3, and those parts do not appear in a normal
object listing.** `ListObjectsV2` shows nothing. Only
`ListMultipartUploads` sees them. An abort path that silently does not run leaves
state that is invisible to the tool most people would use to look for it.

An abort that itself fails is logged at `error` level with its own event name,
because that is the one case where something is genuinely left behind and someone
needs to know which upload id to go and clean up.

### 2.6 Bounded concurrency, and full jitter on the backoff

`runBounded()` starts `min(concurrency, items.length)` lanes over a shared cursor
and returns results **in the original item order**, not in completion order. The
ordering matters: `CompleteMultipartUpload` is given the parts sorted ascending by
`PartNumber`, and S3 rejects any other order. Concurrent workers finish out of
order as a matter of course — section 5.3 shows a captured run where they did —
so the sort before completing is required, not defensive.

Retries use exponential backoff with **full jitter**:

```js
const ceiling = Math.min(maxMs, baseMs * 2 ** attempt);
return Math.floor(random() * ceiling);
```

Plain exponential backoff was rejected for a specific reason: identical backoff
across workers re-synchronizes them onto the same retry instant. Several parts
that fail together then retry together, which is precisely the burst that caused
the throttling in the first place. Full jitter spreads them across the whole
interval.

`isRetryable()` is explicit about what earns another attempt — HTTP 429, any 5xx,
the SDK's throttling flag, and a named set including `SlowDown`,
`RequestTimeout`, `ECONNRESET` and `ETIMEDOUT`. Everything else fails
immediately, because retrying a permanent error is just a slower failure.

### 2.7 Endpoint resolution defaults to local; real AWS is an explicit opt-in

`lib/s3-target.js` resolves which endpoint a tool talks to. With `S3_ENDPOINT`
unset, developer tooling resolves to `http://127.0.0.1:5000` — the local moto
server. Reaching real AWS requires passing `S3_ENDPOINT=aws`.

The idiom this replaces is common and reads innocently:

```js
...(process.env.S3_ENDPOINT ? { endpoint: process.env.S3_ENDPOINT } : {})
```

Read it again with the question "what happens when the variable is unset?" It
means *talk to real AWS*. A debug script whose entire purpose is poking at
disposable test buckets, run in a shell that had not exported one environment
variable, points itself at a production account.

**A default is a decision about what happens when someone forgets.** For a tool
that lists buckets and counts uploads, the safe answer to forgetting is the
disposable local target, so that is what the default is now. Three properties
follow from the module:

1. Every script prints its resolved target before doing any work. Both
   `04-structured-logs.log` and `04-orphan-check.log` open with
   `S3 target: http://127.0.0.1:5000`.
2. The integration suite, which creates buckets and writes objects, refuses to
   run against real AWS outright — `resolveS3Target()` is called at module load
   and throws if `isRealAws`.
3. Against a local endpoint the module supplies throwaway `test`/`test`
   credentials; against real AWS it supplies none and defers to the SDK
   credential chain. Fabricating `test`/`test` for a real account produces a
   confusing `InvalidAccessKeyId` instead of a clear credential error.

The Node-RED runtime is the one component that *is* allowed to target real AWS
with the variable unset, because that is its production configuration —
`settings.js` passes `allowRealAws: true` and logs the resolved label at startup.
`04-nodered-e2e.log` records that line: `[task04] S3 target: http://127.0.0.1:5000`.

### 2.8 moto as the S3 API under test

No AWS account is available for this project, so the S3 API under test is
**moto**, running in Docker and speaking the real S3 wire protocol on port 5000
(`04-moto-server.log`: `motoserver/moto`, `0.0.0.0:5000->5000/tcp`).

What moto implements faithfully enough for these assertions: `UploadPartCopy`
with range semantics, `ListMultipartUploads`, and multipart ETag construction
including the `-N` suffix. Every claim in section 5 rests on one of those three.

What it is not: moto is in-memory, so restarting the container discards every
bucket and object, and its timing characteristics are those of a Python process
on this laptop. Section 6.4 says exactly which measurements that affects and
which it does not.

---

## 3. How it is built

### 3.1 The pieces

| Path | What it is |
|---|---|
| `lib/s3-multipart-copy.js` | The engine. 496 lines, no Node-RED APIs, unit testable. |
| `lib/s3-target.js` | Endpoint resolution and S3 client construction. |
| `settings.js` | Node-RED settings; injects the engine via `functionGlobalContext`. |
| `flows/flows.json` | The importable flow. Generated. |
| `scripts/build-flow.js` | Regenerates `flows/flows.json` and validates it. |
| `scripts/copy-cli.js` | Runs one copy from the command line, printing the JSON log stream. |
| `scripts/plan-table.js` | Prints the part-size plan for a range of object sizes. |
| `scripts/verify-e2e.js` | Drives the running flow over HTTP, then verifies via the S3 API. |
| `scripts/bucket-state.js` | Lists objects with ETags and counts in-progress uploads. |
| `test/planner.test.js` | 19 unit tests for the planner and helpers. |
| `test/integration/moto-copy.test.js` | 9 integration tests against moto. |

### 3.2 The flow

```
  HTTP In  POST /copy ─┐
                       ├─▶ validate request ─┬─▶ run multipart copy ─┬─▶ respond if HTTP ─▶ HTTP Response
  Inject (manual run) ─┘         │  (invalid) │                      │        ▲
                                 └────────────┼──────────────────────┘        │
                                              │                               │
  Catch node ─▶ format error ─────────────────┴───────────────────────────────┘

  Debug nodes hang off each of the three branches: copy result, copy error,
  rejected request.
```

`validate request` has two outputs. A valid request goes to the engine; an
invalid one is short-circuited straight to the response with HTTP 400 and a
`details` array naming every missing field, so a caller gets all the problems at
once rather than one per round trip.

`respond if HTTP` exists because Inject-triggered runs carry no `msg.res`.
Without it, the HTTP Response node logs "No response object" on every manual run
from the editor.

The `Catch` node feeds `format error`, which shapes any uncaught error into the
same JSON envelope the happy path uses. One response contract, whichever way the
message arrived.

`run multipart copy` does its async work in an IIFE with explicit
`node.send`/`node.done` rather than returning a promise — the most portable shape
for a Node-RED function node — and its `logSink` both collects each structured
line into the response payload and emits it through `node.warn` so it appears in
the Node-RED log.

### 3.3 The engine, phase by phase

`copyObject()` runs five phases, each of which emits at least one log line.

**1. Inspect the source.** `HeadObject`, wrapped in the retry helper. A 404 here
is translated before it propagates:

```js
throw new MultipartCopyError(
  `Source object not found: s3://${source.bucket}/${source.key}`,
  { code: 'SOURCE_NOT_FOUND', cause: error },
);
```

A HEAD response carries no body, so the SDK has nothing to build a message from
and surfaces the failure as a bare `UnknownError` with code `NotFound`. Section
6.5 covers what that looked like in a log before the translation existed.

**2. Plan the parts.** `planParts(size, requestedPartSize)` returns the part size,
the part count, the auto-raise flag, and the full list of parts with 1-based
part numbers and inclusive HTTP byte ranges. The plan is logged in full.

**3. Create the upload.** `CreateMultipartUpload`, carrying the source's
`ContentType` forward so the copy is not silently retyped. The returned
`UploadId` is captured into a variable the failure path can see.

**4. Copy every part.** `runBounded` over the plan, each part a single
`UploadPartCopy` with `CopySource` and `CopySourceRange`, each wrapped in
`withRetry`. Every completed part logs its number, range, byte count, duration,
returned ETag, and cumulative progress.

**5. Complete.** Parts sorted ascending by number, `CompleteMultipartUpload`, and
a final `copy.complete` line carrying the result object the HTTP caller receives.

`CopySource` is built by percent-encoding each key segment and rejoining on `/`:

```js
String(key).split('/').map(encodeURIComponent).join('/')
```

Keys legitimately contain spaces, `+`, `#` and non-ASCII characters, any of which
corrupt the header unencoded, while slashes have to survive so the key hierarchy
is preserved. The test fixture key is deliberately
`fixtures/large file (23MiB).bin` — a space, parentheses, and a prefix — so this
path is exercised on every run rather than only in a unit test.

### 3.4 The structured log

One JSON object per line. Fields common to every line: `ts` (ISO 8601), `level`,
`event`, `correlationId` (a UUID v4 generated per copy).

| Event | When | Notable fields |
|---|---|---|
| `copy.start` | first line of every copy | source, destination, requestedPartSize, concurrency, maxRetries |
| `source.inspected` | after HeadObject | sizeBytes, contentType, sourceETag, lastModified |
| `plan.computed` | after planning | partSize, partSizeMiB, partCount, autoRaised, reason |
| `upload.created` | after CreateMultipartUpload | uploadId |
| `part.copied` | once per part | partNumber, range, bytes, durationMs, eTag, progress |
| `copy.complete` | on success | eTag, durationMs, throughputMBps, partCount |
| `part.retry` | a retryable part failure | partNumber, attempt, delayMs, error |
| `upload.aborted` | any failure after the upload exists | uploadId, reason |
| `copy.failed` | last line of a failed copy | error, code, durationMs |

The correlation id is the field that makes the rest usable. Five parts copying
concurrently interleave their lines; without a shared id there is no way to
reconstruct which copy a given `part.copied` belongs to when two copies overlap.

---

## 4. The steps, as a narrative

**Step 1 — install and start the S3 API.**

```bash
npm install
docker run -d --name moto -p 5000:5000 motoserver/moto
```

`04-moto-server.log` captures the container: `motoserver/moto`, `Up 16 hours`,
`0.0.0.0:5000->5000/tcp`.

**Step 2 — unit tests, with no server involved.** `node --test test/*.test.js`.
These cover the planner arithmetic and the helpers, and they are where the large
object sizes live — a 5 TiB plan is asserted here because moving 5 TiB of bytes
to assert the same thing is not feasible on this hardware. 19 tests, 19 passing,
214.7 ms (`04-unit-tests.log`).

The range-coverage test is property-style rather than example-based: for every
planner case it asserts the first byte is 0, the last byte is `size - 1`, each
part starts exactly where the previous one ended, and the summed part lengths
equal the object size. Any byte left uncovered silently corrupts the copy, and
S3 will not notice — it assembles whatever parts it is given.

**Step 3 — the part-size table.** `node scripts/plan-table.js` prints the limits
the planner enforces and the plan it produces for seven object-size and
part-size combinations, then the three rejection cases. Captured as
`04-part-sizing.log`; the table is section 5.1.

**Step 4 — integration against moto.** The suite creates both buckets, writes a
23 MiB fixture whose every 4-byte word encodes its own offset — so a part copied
from the wrong range shows up as a hash mismatch rather than as plausible bytes —
and then runs eight assertions across the copy, the ETag, the log stream, the
orphan count, and two failure drills. 9 tests, 9 passing (`04-integration-moto.log`).

**Step 5 — the copy engine from the command line.** `scripts/copy-cli.js` runs
one copy and prints the raw log stream, which is the cleanest way to see the
logging requirement without the runtime in the way. Both a successful run and a
missing-source run are captured in `04-structured-logs.log`.

**Step 6 — Node-RED end to end.** Start the runtime against `settings.js`, then
POST to `/copy`:

```bash
node node_modules/node-red/red.js --settings ./settings.js &
curl -X POST http://127.0.0.1:1880/copy -H 'Content-Type: application/json' -d '{...}'
```

`04-nodered-e2e.log` carries the startup lines (Node-RED v5.0.4, Node.js
v24.13.0, the settings and flows paths, `Server now running at
http://127.0.0.1:1880/`, `Started flows`), the full JSON response body, and
`HTTP_STATUS:200`.

**Step 7 — independent verification.** `scripts/verify-e2e.js` drives the running
flow over HTTP and then checks the result through the S3 API rather than
believing the response. It downloads both objects, hashes them, reads the
destination ETag, sends a deliberately invalid request to confirm the 400 path,
sends a copy for a missing key to confirm the failure path, and counts orphaned
uploads. All checks pass (`04-nodered-e2e.log`).

**Step 8 — bucket state and orphan count.** `scripts/bucket-state.js` lists every
object with its ETag annotated as multipart or single-PUT, and counts in-progress
multipart uploads per bucket. Captured as `04-orphan-check.log`.

---

## 5. Measured results

### 5.1 Part-size planning

The limits the planner enforces, printed from `S3_LIMITS` (`04-part-sizing.log`):

| Limit | Value |
|---|---|
| Minimum part size | 5,242,880 B (5.00 MiB) — the last part is exempt |
| **Maximum part size** | **5,368,709,120 B (5.00 GiB) — the default used here** |
| Maximum parts | 10,000 |
| Maximum object | 5,497,558,138,880 B (5.00 TiB) |

Plans produced, all from `04-part-sizing.log`:

| Object size | Requested part | Chosen part | Parts | Auto-raised |
|---|---|---|---|---|
| 23.00 MiB | 5.00 MiB | 5.00 MiB | 5 | no |
| 23.00 MiB | default (5 GiB) | 5.00 GiB | **1** | no |
| 100.00 GiB | default (5 GiB) | 5.00 GiB | 20 | no |
| 1.00 TiB | default (5 GiB) | 5.00 GiB | 205 | no |
| 1.00 TiB | 5.00 MiB | 105.00 MiB | 9,987 | **YES** |
| 5.00 TiB | default (5 GiB) | 5.00 GiB | 1,024 | no |
| 5.00 TiB | 5.00 MiB | 525.00 MiB | 9,987 | **YES** |

Rejections, with the codes the planner raises (`04-part-sizing.log`):

| Input | Code | Reason |
|---|---|---|
| zero-byte object | `EMPTY_OBJECT` | multipart copy cannot express a 0-byte object — there is no range to copy |
| object above 5 TiB | `OBJECT_TOO_LARGE` | 5,497,558,138,881 B against the 5 TiB maximum |
| part size above 5 GiB | `PART_SIZE_TOO_LARGE` | 6,442,450,944 B against the 5 GiB maximum |

### 5.2 Test suites

| Suite | Result | Duration | Evidence |
|---|---|---|---|
| Planner unit tests | 19 pass, 0 fail | 214.6776 ms | `04-unit-tests.log` |
| Integration against moto | 9 pass, 0 fail | 2082.3627 ms | `04-integration-moto.log` |
| Node-RED end to end | all checks pass | — | `04-nodered-e2e.log` |

The nine integration tests, by name (`04-integration-moto.log`):

```
✔ copies the object using multiple parts (500.5054ms)
✔ destination bytes are identical to the source (255.5875ms)
✔ destination ETag carries the multipart signature (12.3847ms)
✔ structured logs cover the full lifecycle with one correlationId (0.3764ms)
✔ no orphaned multipart uploads remain after success (8.1628ms)
✔ a failed copy aborts its upload and leaves no orphans (34.9883ms)
✔ an upload interrupted after creation is aborted, not left dangling (32.5065ms)
✔ default part size is the 5 GiB maximum (417.2376ms)
```

### 5.3 One copy, measured

The command-line run in `04-structured-logs.log`: a 23 MiB source at a 5 MiB part
size with concurrency 3.

| Part | Range | Bytes | Duration | Cumulative |
|---|---|---|---|---|
| 1 | `bytes=0-5242879` | 5,242,880 | 100 ms | 21.74 % |
| 2 | `bytes=5242880-10485759` | 5,242,880 | 137 ms | 43.48 % |
| 3 | `bytes=10485760-15728639` | 5,242,880 | 175 ms | 65.22 % |
| 4 | `bytes=15728640-20971519` | 5,242,880 | 111 ms | 86.96 % |
| 5 | `bytes=20971520-24117247` | 3,145,728 | 78 ms | 100 % |

Total object 24,117,248 bytes; four full parts and a 3 MiB remainder. The ranges
tile the object exactly: part 1 starts at byte 0, each part starts where the
previous ended, and part 5 ends at `size - 1`.

| Measurement | Value | Evidence |
|---|---|---|
| Copy duration | 543 ms | `04-structured-logs.log` |
| `throughputMBps` field | 42.36 | `04-structured-logs.log` |
| Destination ETag | `66252e6c35e6a9b5920dd03b36cc164e-5` | `04-structured-logs.log` |
| Correlation id, all 10 lines | `1f2ec7c9-71ac-4238-b954-3a01fb20affb` | `04-structured-logs.log` |

The same copy through the Node-RED HTTP endpoint (`04-nodered-e2e.log`): 602 ms,
`throughputMBps` 38.21, same destination ETag, correlation id
`979e2630-7a0b-4042-b131-958d9d5d5c6b`, HTTP 200.

**That run also shows the concurrency working.** The `part.copied` lines appear in
completion order 2, 3, 1, 4, 5, with part 1 taking 231 ms while parts 2 and 3 took
147 ms and 187 ms. Three lanes were in flight, part 1 finished third, and the
progress counter reads 21.74 % on the line reporting part 2 — because progress
counts parts completed, not part numbers. This is the concrete reason
`CompleteMultipartUpload` gets a sorted list: the natural order out of the
workers is not ascending.

**Naming the layer the throughput describes.** `throughputMBps` is computed as
`(bytes / 1024²) / (ms / 1000)`, which is **MiB per second**, not MB per second —
the printed number sits 4.6 % below the same rate expressed in MB/s. More
important than the unit is what the number measures. `UploadPartCopy` is a server-side copy: the client
sends a range header and moto moves the bytes between two of its own in-memory
buckets. **The 23 MiB never crosses a socket in either direction.** Only the
control requests do, over loopback to `127.0.0.1:5000`. So 42.36 is a measurement
of this laptop driving an in-process S3 stub, and it carries no information about
what the same flow would do against real S3, where the copy runs inside AWS and
the limiting factor is S3's own object-copy path.

### 5.4 Proof that multipart was genuinely used

The destination ETag. A single-`PUT` object carries a plain MD5 ETag. A multipart
object's ETag is a **digest of the concatenated part digests, suffixed with the
part count** — so the suffix is S3's own record of how many parts assembled the
object, and no client can fake it into existence.

From `04-orphan-check.log`, the source and one destination side by side:

```
source:      ETag=50a9562aa87bb7828a854ac3a5d95643      [single PUT]
destination: ETag=66252e6c35e6a9b5920dd03b36cc164e-5    [multipart: 5 part(s)]
```

Independently verified through the S3 API rather than from the copy's own return
value (`04-nodered-e2e.log`):

| Check | Value |
|---|---|
| Source sha256 | `64fc4bc384a8e9524f29302dd82b380a512a9c3e94d9494a2b46dc7984ed5276` |
| Destination sha256 | `64fc4bc384a8e9524f29302dd82b380a512a9c3e94d9494a2b46dc7984ed5276` |
| Byte lengths | 24,117,248 vs 24,117,248 |
| ETag multipart suffix | present |
| Suffix matches part count | `-5` against `partCount` 5 |

### 5.5 The failure paths

| Drill | Outcome | Evidence |
|---|---|---|
| Missing source key, CLI | `copy.failed` with `"code":"SOURCE_NOT_FOUND"` in 27 ms, exit code 1 | `04-structured-logs.log` |
| Missing source key, HTTP | non-200 returned (500), `ok` false, zero orphaned uploads | `04-nodered-e2e.log` |
| Invalid request body | HTTP 400 with `["source.key is required","destination.bucket is required","destination.key is required"]` | `04-nodered-e2e.log` |
| Failure after the upload exists | `upload.created` then `upload.aborted`, zero orphans | `04-integration-moto.log` |

The missing-source case fails at `HeadObject`, before any multipart upload is
created, so there is nothing to abort — visible in the log as `copy.start`
followed directly by `copy.failed` with no `upload.created` between them:

```json
{"ts":"2026-08-25T14:39:34.744Z","level":"info","event":"copy.start","correlationId":"4f756a2a-…","source":{"bucket":"task04-source","key":"fixtures/does-not-exist.bin"},…}
{"ts":"2026-08-25T14:39:34.771Z","level":"error","event":"copy.failed","correlationId":"4f756a2a-…","error":"Source object not found: s3://task04-source/fixtures/does-not-exist.bin","code":"SOURCE_NOT_FOUND","durationMs":27}
```

The harder case is a failure *after* the upload exists, and the integration suite
constructs it deliberately by injecting a `UploadPartCopyCommand` whose
constructor throws. The upload is genuinely created against moto, the part copy
fails, and the assertions are that `upload.created` and `upload.aborted` both
appear and that `ListMultipartUploads` comes back empty.

### 5.6 Bucket state and the orphan count

From `04-orphan-check.log`:

| Bucket | Objects | In-progress (orphaned) uploads |
|---|---|---|
| `task04-source` | 1 | **0** |
| `task04-destination` | 6 | **0** |
| | | **TOTAL 0** |

The destination listing, which is more interesting than the count:

| Key | Size | ETag |
|---|---|---|
| `copied/cli-demo.bin` | 24,117,248 | `66252e6c…-5` |
| `copied/default-partsize.bin` | 24,117,248 | `e4acc93e…-1` |
| `copied/e2e-verified.bin` | 24,117,248 | `66252e6c…-5` |
| `copied/evidence-run.bin` | 24,117,248 | `66252e6c…-5` |
| `copied/large file (23MiB).bin` | 24,117,248 | `66252e6c…-5` |
| `copied/via-node-red.bin` | 24,117,248 | `66252e6c…-5` |

**How to read that log.** The moto container ran continuously for the whole
session, so the destination bucket accumulated state across every run rather than
being reset between them. Those six objects are the products of six *different*
invocations — the integration suite, the CLI demo, the Node-RED HTTP run, the
end-to-end verifier, and so on — not six objects from one copy. Since moto holds
everything in memory, restarting the container starts from an empty bucket, and a
fresh run reproduces the same ETags with fewer objects.

The accumulation turns out to be the most useful single artifact in the task, and
section 6.1 explains why.

---

## 6. What the measurements revealed

### 6.1 The maximum part size hides multipart, and the bucket listing proves it

Two rows of the destination listing are the same 23 MiB source object, copied
twice by the same engine:

```
copied/large file (23MiB).bin   ETag=66252e6c35e6a9b5920dd03b36cc164e-5   [multipart: 5 part(s)]
copied/default-partsize.bin     ETag=e4acc93e16f317c330b661a13573d006-1   [multipart: 1 part(s)]
```

Same bytes, same source, same code path. The first was copied at a 5 MiB part
size; the second at the **default** 5 GiB part size. S3's own ETag records the
difference in the suffix.

Both are legitimate multipart uploads. Only one exercises multiple parts.

This is the consequence of the requirement as written, and it is worth stating
carefully because it looks like a contradiction and is not one. "Raise the upload
size limit to the maximum" and "prove multipart works" are both satisfiable. They
are not satisfiable **in the same run**, for any test object smaller than 5 GiB —
which is every test object anyone would reasonably keep in a repository. At the
maximum part size, an object under 5 GiB is one part, and a one-part multipart
upload demonstrates the API call without demonstrating the mechanism.

A test suite that only ran the default would pass, be entirely honest, and prove
nothing about part tiling, concurrency, ordering, or range coverage. So the
integration fixture asks for 5 MiB parts explicitly:

```js
partSize: 5 * MIB, // force multiple parts; the default 5 GiB would be one part
```

and a separate test asserts the default really is 5 GiB and really does produce
one part with a `-1` ETag. Both facts get proven, in two runs, and the bucket
listing carries both results side by side.

The generalizable version: **when a configuration value is raised to a boundary,
check what the boundary does to your test coverage.** Raising a limit can silence
the code path you were trying to exercise, and the test still passes.

### 6.2 Auto-raise lands on 9,987 parts, not 10,000

Both auto-raised plans in `04-part-sizing.log` come out at 9,987 parts — 1 TiB at
105 MiB, and 5 TiB at 525 MiB. Neither reaches the 10,000 ceiling, because
rounding the computed minimum up to a whole MiB overshoots slightly and each part
then carries a little more than it strictly needs.

That is deliberate. `ceil(1 TiB / 10000)` is 109,951,163 bytes — a number that is
useless to a human reading a log line at 3 a.m. `105.00 MiB` is not. The 13 parts
of headroom change nothing, and the log stays legible:

```json
{"event":"plan.computed","partSize":5242880,"partSizeMiB":5,"partCount":5,"autoRaised":false,…}
```

Exact-fit arithmetic would have been the more clever choice and the worse one.

### 6.3 A server-side copy makes the interesting metric disappear

The engine emits `throughputMBps` on every completed copy, and against moto that
field measures the harness rather than any data path. Section 5.3 gives the
reason: the object bytes never cross a socket, so there is no transfer to time.

What remains measurable, and what does not, separates cleanly:

| Genuinely measured here | Not observable in this setup |
|---|---|
| Part tiling, range arithmetic, tail handling | Real S3 inter-object copy throughput |
| Concurrency, ordering, sorted completion | Real S3 throttling and `SlowDown` responses |
| ETag multipart semantics | Multi-GiB part timings |
| Abort and orphan behavior | Cross-region copy latency |
| Structured log completeness | |

The retry and backoff code is exercised by unit tests with injected errors —
`withRetry retries retryable errors and gives up on permanent ones` and `backoff
grows exponentially and stays within the ceiling` both pass in
`04-unit-tests.log` — rather than by a server that actually throttled.

Naming which layer a number describes is the whole point. "42.36 MiB/s" published
without that context would read as a claim about S3, and it is a claim about a
Python process on a laptop.

### 6.4 moto is a good stand-in, and the places it differs are knowable

Three moto behaviors carried the assertions in this task, and all three matched
S3's documented semantics: `UploadPartCopy` honored `CopySourceRange` exactly
(the offset-encoded fixture would have produced a hash mismatch otherwise),
`ListMultipartUploads` reported in-progress uploads and reported them gone after
an abort, and the multipart ETag came back as a digest-of-digests with the `-N`
suffix that the tests match against.

One property worth planning around rather than discovering: **moto is in-memory.**
Restarting the container discards every bucket and object. Nothing in this task
depends on persistence, but it means `04-orphan-check.log` is a snapshot of an
accumulated session, not a fixed reproducible state — which is exactly what
section 5.6 says about it, and exactly why saying so matters.

### 6.5 A 404 on `HeadObject` produces an error with nothing in it

The first failure run logged this:

```
"error":"UnknownError","code":"NotFound"
```

Two words, neither of which identifies the bucket, the key, or the operation. The
cause is protocol-level: a HEAD response carries no body, so there is no error
document for the SDK to build a message from, and it falls back to the status
line.

The engine now catches the 404 and 403 cases at the point where it still knows
what it was asking for:

```
"error":"Source object not found: s3://task04-source/fixtures/does-not-exist.bin","code":"SOURCE_NOT_FOUND"
```

That line is in `04-structured-logs.log`, and the integration suite asserts on
both the code and the key appearing in the message, so the translation cannot
quietly regress.

This was caught by reading a failure log rather than by a test. The test would
have passed either way — it was asserting that the copy rejected, which it did.
**An assertion that a failure occurred is not an assertion that the failure is
actionable**, and the difference only shows up when someone reads the output.

### 6.6 `process.exit()` turned an all-pass run into exit code 127

`verify-e2e.js` originally ended with `process.exit()`. On Windows that tripped a
libuv assertion — `UV_HANDLE_CLOSING`, `async.c:76` — while the SDK's keep-alive
sockets were still closing. Every check printed PASS and the process exited 127.

The fix sets `process.exitCode` and calls `s3.destroy()`, letting the event loop
drain naturally:

```js
// Calling process.exit() here trips a libuv assertion on Windows
// (UV_HANDLE_CLOSING in async.c) because the SDK's keep-alive sockets are
// still closing, which turns a passing run into exit code 127.
process.exitCode = failures === 0 ? 0 : 1;
s3.destroy();
```

The captured run now ends `RESULT: ALL CHECKS PASSED` with `EXIT CODE : 0`
(`04-nodered-e2e.log`).

The lesson is about how CI reads a run. A job that keys off the exit code would
have reported this as a failure with no failing assertion anywhere in the output
— the worst diagnostic shape there is, because the log says everything is fine
and the pipeline says it is not. Any process holding SDK connections should let
the loop drain rather than shooting itself.

### 6.7 A default that is convenient in development is a hazard when the fallback is production

Section 2.7 has the design. The finding behind it is worth its own paragraph.

The idiom `...(process.env.S3_ENDPOINT ? { endpoint: … } : {})` appeared in every
developer script. It is the shape most SDK examples use, it reads as "use the
override if there is one", and what it actually says is *if this variable is not
set, talk to real AWS*. The scripts it appeared in are the ones whose entire
purpose is inspecting throwaway test buckets.

No test would have caught it, because every test and every capture script
exported `S3_ENDPOINT` first and therefore never exercised the default. It
surfaced when a script was run in a clean shell.

Three properties in `lib/s3-target.js` close it, and they are worth reusing
anywhere the same shape appears:

1. **Invert the default.** Unset resolves to the disposable local target. Real
   AWS requires `S3_ENDPOINT=aws` — a value someone has to type on purpose.
2. **Print the resolved target before doing work.** Both capture logs open with
   `S3 target: http://127.0.0.1:5000`, so which account was touched is a matter
   of record rather than of inference.
3. **Refuse where refusing is correct.** The integration suite creates buckets
   and writes objects, so it throws at module load if the resolved target is real
   AWS, rather than trusting the operator.

The Node-RED runtime keeps the opposite default because targeting real AWS is its
production job — and it no longer fabricates `test`/`test` credentials there,
deferring to the SDK credential chain, because fake credentials against a real
account produce a credential error that hides the actual mistake.

### 6.8 Evidence logs need a byte-order mark on Windows

The capture script wrote correct UTF-8 with no BOM. Node's test reporter emits
U+25B6 (`▶`) and U+2714 (`✔`), and PowerShell 5.1's `Get-Content` decodes a
BOM-less file using the ANSI code page — so those bytes rendered as `â–¶ âœ"`.
The logs were also carrying raw ANSI color escape sequences, which are noise in a
file meant to be read as text and quoted in a report.

`scripts/run-with-evidence.sh` now writes a UTF-8 BOM at file creation, strips
ANSI escapes, and exports `NO_COLOR` so most tools never emit them. The check was
done by dumping bytes rather than by eye: `ef bb bf` present at the head of every
`04-*.log`, and no ESC bytes remaining. The `✔` marks quoted in section 5.2 read
correctly because of it.

Evidence that cannot be read on the machine it will be read on is not evidence
yet.

---

## 7. Running it yourself

Prerequisites: Node.js (the captured runs used v24.13.0) and Docker.

```bash
cd 04-nodered-s3
npm install

# 1. Unit tests — no server needed.
#    `node --test test/` fails on Node 22+; glob the files explicitly.
node --test test/*.test.js

# 2. A local S3-compatible server.
docker run -d --name moto -p 5000:5000 motoserver/moto

# 3. Integration tests against it.
export S3_ENDPOINT=http://127.0.0.1:5000
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
node --test test/integration/*.test.js

# 4. The part-size table.
node scripts/plan-table.js
```

One copy from the command line, printing the log stream:

```bash
node scripts/copy-cli.js \
  --source-bucket task04-source --source-key 'fixtures/large file (23MiB).bin' \
  --dest-bucket task04-destination --dest-key copied/demo.bin \
  --part-size 5242880 --concurrency 3
```

Drop `--part-size` to see the default 5 GiB behavior — the same object comes out
as one part with a `-1` ETag.

Through Node-RED:

```bash
node node_modules/node-red/red.js --settings ./settings.js &

curl -X POST http://127.0.0.1:1880/copy \
  -H 'Content-Type: application/json' \
  -d '{"source":{"bucket":"task04-source","key":"fixtures/large file (23MiB).bin"},
       "destination":{"bucket":"task04-destination","key":"copied/out.bin"},
       "partSize":5242880,"concurrency":3}'
```

The editor is at <http://127.0.0.1:1880/> and loads `flows/flows.json`. The Inject
node labeled `manual run (edit payload)` runs a copy from the editor with no HTTP
client involved.

Verification and inspection:

```bash
node scripts/verify-e2e.js     # drives the flow, then checks via the S3 API
node scripts/bucket-state.js   # objects, ETags, orphaned upload count
```

`bucket-state.js` exits non-zero if the orphan count is anything but zero, so it
works as a gate in a pipeline as well as a report.

Changing the flow:

```bash
# Edit the function bodies at the top of scripts/build-flow.js, then:
node scripts/build-flow.js     # regenerates and validates flows/flows.json
```

Configuration:

| Variable | Default | Purpose |
|---|---|---|
| `S3_ENDPOINT` | `http://127.0.0.1:5000` for scripts and tests; real AWS for the Node-RED runtime | A URL targets that endpoint; the literal `aws` targets real AWS |
| `AWS_REGION` | `us-east-1` | |
| `AWS_ACCESS_KEY_ID` | `test` for local targets only | Against real AWS the SDK credential chain is used |
| `AWS_SECRET_ACCESS_KEY` | `test` for local targets only | Same |
| `NODE_RED_PORT` | `1880` | |

Every script prints the target it resolved before it does anything. Read that line
before reading the rest of the output.

To capture evidence the way this repository does it, wrap any of the above in
`scripts/run-with-evidence.sh`, which records the command, working directory,
timestamp and full output into `docs/evidence/`.
