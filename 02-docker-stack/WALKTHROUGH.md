# Task 2 — A multi-tier application on private Docker networks

A walkthrough of the topology, the decisions behind it, the five failure drills
and what they turned out to say about how Docker actually behaves. Every figure
comes from a log in `docs/evidence/`, named beside it.

---

## 1. What was asked, and how I read it

The requirement, in the requester's wording:

> Run multiple applications communicating over a private Docker network — a
> database container, a backend container, and a frontend plus reverse proxy
> container. Automate as much as possible. Use a secret manager or environment
> variables. Explain how the system recovers from unexpected failures (machine
> shutdown, RAM exhaustion, and so on). Explain how CPU, storage and RAM are
> allocated.

**"A private Docker network"** is the part that decides the whole shape. The
easy reading is "do not publish ports", and that is not the same claim. A
single shared network with no ports published keeps the database away from the
*host* while leaving it fully reachable from every other container on that
network — including a reverse proxy, which is the tier most exposed to the
outside world and therefore the one most likely to be compromised. I read the
requirement as isolation by network membership, which means more than one
network and a data tier that the edge tier cannot address at all.

**"Automate as much as possible"** means one command takes the stack from
nothing to serving, with no manual polling in the middle and no second command
to run migrations. It also means running it twice changes nothing.

**"A secret manager or environment variables"** offers a choice, and the useful
answer is to build both and show what separates them. An environment variable
is a perfectly good way to ship a database name. It is a poor way to ship a
password, and the reason is demonstrable in one `docker inspect`.

**"Explain how the system recovers from unexpected failures"** — I read
"explain" as "demonstrate, then explain". A written description of a restart
policy is a claim about behavior. Five drills that break the system in five
different ways and measure what comes back are evidence about behavior, and
three of the five contradicted what I expected before running them.

**"Explain how CPU, storage and RAM are allocated"** means the numbers have to
be read back from the daemon, not quoted from the compose file. A
`deploy.resources` block that the runtime silently ignores looks identical in
source to one it enforces.

---

## 2. Design decisions

### 2.1 PostgreSQL, decided by the memory drill

Task 3 covers MSSQL in its own dedicated container. Reusing it here would test
one engine twice and leave this task's actual subject — network isolation and
failure recovery — sharing a host with a heavyweight database.

What settled it was the RAM-exhaustion drill. The MSSQL Linux container
requires 2 GiB and refuses to start below it. The Docker VM on this host has
8,285,016,064 bytes — 7,901 MiB for all containers (`02-resources.log`). A
meaningful OOM drill needs a service whose memory limit can be set low enough
to exhaust in about a second, without the container being so constrained that
normal operation risks a spurious kill. Postgres runs comfortably in 512 MiB
and settled at 36.24 MiB idle against that limit, which leaves the drill room
to work in.

Rejected, each with the property that ruled it out:

- **MSSQL** — the 2 GiB floor makes limits and OOM drills clumsy on a 7,901 MiB
  VM, and it duplicates Task 3.
- **MySQL / MariaDB** — workable, with no advantage here, and weaker support for
  the `_FILE`-suffixed environment convention that makes the file-based secret
  demonstration clean. `POSTGRES_PASSWORD_FILE` is read by the official entry
  point with no wrapper script of mine in the path.
- **SQLite** — no separate database container, so the three-tier network
  topology that is the entire point of the task would not exist.

### 2.2 Two networks, with the data tier marked `internal: true`

```yaml
networks:
  edge-net:
    name: task02-edge-net
    driver: bridge
  internal-net:
    name: task02-internal-net
    driver: bridge
    internal: true
```

nginx joins `edge-net`. Postgres joins `internal-net`. The backend joins both,
making it the only path between them. Postgres is not a member of `edge-net` at
all, so Docker's embedded DNS does not resolve the name `postgres` for nginx —
it is not merely unreachable, it is unaddressable.

`internal: true` does a second thing worth having: it removes the default
gateway from that network, so nothing on it has an outbound internet route. A
database that cannot make outbound connections cannot exfiltrate over one.

### 2.3 The password as a file, everything else as environment

Both mechanisms are used, split by sensitivity. The password reaches Postgres
as a file-based Docker secret at `/run/secrets/postgres_password`, referenced
by `POSTGRES_PASSWORD_FILE`. Database name, role, pool size, host port and the
chaos flag live in `.env`.

The split is not arbitrary. A database name is visible in any connection error
message the application ever logs, so hiding it buys nothing. A password is
not, and must not be. Section 6.6 has the `docker inspect` output that
separates the two.

### 2.4 The application process is PID 1

The backend Dockerfile ends with `CMD ["node", "src/server.js"]` in exec form,
with no shell and no init wrapper. That is a deliberate constraint rather than
a convenience: a shell or an init as PID 1 would absorb the OOM kill of its
child, and the container would survive an event that the drill exists to
observe. `02-drill-b-oom.log` checks this before doing anything else:

```
    /proc/1/comm = node
[PASS] the application IS PID 1, so an OOM kill takes down the container
```

The consequence runs the other way too, and section 6.2 covers it: the memory
allocation has to happen *inside* PID 1, which is why the chaos endpoint lives
in the application rather than in a `docker exec`.

### 2.5 Swap disabled on the backend only

```yaml
memswap_limit: 256M     # equal to the memory limit, so no swap
```

Docker's default is to allow a container to use its memory limit again in swap.
Under that default, memory pressure degrades into paging rather than into an
OOM kill, and the drill would be inconclusive — the container would get slow
instead of dying. Setting `memswap_limit` equal to `memory` disables swap for
that container. Postgres and nginx keep the default, which is visible in the
MemSwap column of section 5.2 as 1024 M and 256 M against their 512 M and 128 M
limits.

### 2.6 Images pinned by digest

Both base images carry a tag and a digest:

```
FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32
FROM nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
```

and `postgres:16` is pinned the same way in `compose.yaml`. A floating tag
would let the runtime change underneath the measurements in this document. The
digest makes a rebuild months from now resolve the identical image.

### 2.7 The chaos endpoints, and where they are not reachable from

`POST /internal/chaos/crash` and `POST /internal/chaos/oom` exist so the drills
can produce a genuine process death and a genuine cgroup kill. Two things bound
them. They are gated on `CHAOS_ENABLED`, which the backend logs loudly at
startup. And nginx proxies `/api/` and `/api-health` and nothing else, so
`/internal/*` has no route in from the host even while the backend serves it.
The isolation check confirms it from outside: `/internal/*` through the proxy
returns HTTP 405, never the endpoint (`02-network-isolation.log`).

---

## 3. How it is built

```
  host :8080
      │
      ▼
  ┌─────────────────┐   edge-net    ┌─────────────────┐  internal-net  ┌────────────┐
  │ task02-nginx    │──────────────▶│ task02-backend  │───────────────▶│  postgres  │
  │ static frontend │               │ Node 22 Express │                │     16     │
  │ reverse proxy   │               │      pg pool    │                │ pgdata vol │
  └─────────────────┘               └─────────────────┘                └────────────┘
   the only published                 on both networks:                internal: true
        port                     the sole path between tiers        no host route, no
                                                                   outbound route
```

| Service | Image | Networks | Publishes |
|---|---|---|---|
| `postgres` | `postgres:16`, digest-pinned | internal-net | nothing |
| `backend` | `task02-backend:1.0.0`, Node 22 + Express + `pg` | edge-net **and** internal-net | nothing |
| `nginx` | `task02-nginx:1.0.0`, nginx 1.27-alpine | edge-net | 8080 |

### The files

| Path | What it does |
|---|---|
| `compose.yaml` | Three services, two networks, the named volume, the file secret, and every resource limit |
| `backend/Dockerfile` | Digest-pinned Node 22, dependencies in their own layer, `USER node`, healthcheck, exec-form CMD |
| `backend/src/config.js` | Resolves the password from `POSTGRES_PASSWORD_FILE` first, `POSTGRES_PASSWORD` second; logs the *source*, never the value |
| `backend/src/db.js` | Pool, pool-level error handler, `waitForDatabase` retry loop, idempotent migration and seed |
| `backend/src/server.js` | The API, the bounded health probe, and the two chaos endpoints |
| `nginx/nginx.conf` | Static root, `/api/` proxy, `/api-health` passthrough, `/healthz` served by nginx itself, JSON access log |
| `scripts/up.sh` | One command from nothing to healthy |
| `scripts/verify.sh` | Every check and every drill, in an order chosen so a failure is unambiguous |
| `scripts/isolation-check.sh` | 19 assertions about the network topology |
| `scripts/resources.sh` | Limits read back from the daemon, plus live usage idle and under load |
| `scripts/drills/*.sh` | The five failure drills and the secrets comparison |

### The request path

`GET /` is served by nginx from `/usr/share/nginx/html`. `GET /api/items`
proxies to `http://backend:3000`, resolved by Docker's embedded DNS on
`edge-net`, with `keepalive 16` on the upstream. `GET /api-health` proxies to
the backend's `/health` and passes the upstream status through unchanged, so a
degraded backend reads as 503 at the edge rather than being masked into a 200.
`GET /healthz` is answered by nginx itself with a literal, which is what makes
it usable as proof that the proxy tier is alive while the backend is
deliberately down.

### The timeout budget

The health path has a budget, and the numbers in it are chosen to nest:

| Layer | Setting | Value |
|---|---|---|
| backend health probe | `HEALTH_PROBE_TIMEOUT_MS` | 2000 ms |
| nginx, `/api-health` | `proxy_read_timeout` | 5 s |
| nginx, `/api/` | `proxy_read_timeout` | 10 s |
| nginx, both | `proxy_connect_timeout` | 3 s |
| pg pool | `connectionTimeoutMillis` | 5000 ms |

The probe timeout is the load-bearing one. Section 6.5 covers what happened
before it existed.

### Startup ordering and the migration

All three services carry healthchecks. `backend` declares `depends_on:
postgres: condition: service_healthy`, and `nginx` the same against `backend`.
`docker compose up -d --wait` then blocks until every healthcheck passes, which
is what makes the bring-up a single command with no polling loop of mine
(`02-stack-up.log`):

```
 Container task02-postgres  Healthy
 Container task02-backend  Starting
 Container task02-backend  Healthy
 Container task02-nginx  Starting
 Container task02-nginx  Healthy
```

The migration runs inside the backend at startup, in a transaction: `CREATE
TABLE IF NOT EXISTS` for both tables, an `INSERT ... ON CONFLICT DO NOTHING`
into `schema_migrations`, and seed rows guarded by `WHERE NOT EXISTS`. Every
start after the first logs `idempotent: true, rowsSeeded: 0`
(`02-drill-e-dbfail.log`). That property is load-bearing for the persistence
drill: a migration that duplicated rows on each start would make row counts
meaningless as evidence.

---

## 4. The steps, as a narrative

### 4.1 Bring it up

```bash
./scripts/up.sh
```

It creates `.env` from `.env.example` if absent, generates a 32-byte CSPRNG
password into `secrets/postgres_password.txt` if absent, `chmod 600`s it,
builds both images, and runs `docker compose up -d --wait --wait-timeout 180`.
Re-running reports `.env already present, left untouched` and `database
password secret already present, left untouched`, then rebuilds from cache.

Every script exports `MSYS_NO_PATHCONV=1`. Git Bash rewrites arguments that
look like absolute POSIX paths into Windows paths before handing them to
`docker.exe`, which corrupts container-side paths such as
`/run/secrets/postgres_password`.

### 4.2 Smoke test the whole path

`scripts/smoke-test.sh` runs ten assertions through port 8080 only: nginx
answers `/healthz`, the frontend HTML is served, the backend is healthy through
the proxy, a `POST /api/items` creates a row, a `GET` returns it with the
description intact, both seed rows are present, and a `POST` without a name is
rejected with 400. All ten pass (`02-smoke-test.log`).

### 4.3 Prove the topology

`scripts/isolation-check.sh` makes 19 assertions in seven groups, and the
ordering is deliberate: what publishes a port, what the host can reach, what
the edge tier can reach, what the backend can reach, what the data tier can
reach outward, and what `docker network inspect` says about membership. Section
5.1 has the results.

### 4.4 Read the limits back from the daemon

`scripts/resources.sh` asks the daemon for `HostConfig.Memory`,
`MemoryReservation`, `NanoCpus` and `MemorySwap` per container, samples
`docker stats` at idle, drives 200 requests through the proxy, and samples
again. A non-zero value in every column is what proves the compose
`deploy.resources` block is being enforced rather than parsed and discarded.

### 4.5 Contrast the two secret mechanisms

`scripts/drills/05-secrets-comparison.sh` starts a throwaway container with
`-e POSTGRES_PASSWORD=<fake>`, inspects it, then inspects the real Postgres
container the same way. It then sweeps the *entire* inspect output of all three
running containers and both built images for the real password, and checks that
the secret file is gitignored and untracked.

### 4.6 Break it five ways

`scripts/verify.sh` runs the drills in an order chosen so that a failure is
unambiguous: the non-destructive checks first, so a red there cannot be blamed
on damage a drill did, and the daemon restart last because it disrupts the
engine everything else depends on.

| Order | Drill | What it does |
|---|---|---|
| 5 | A — crash | `kill -9 1` from inside, then `docker kill`, then a genuine PID 1 exit |
| 6 | B — RAM exhaustion | Allocate 16 MiB buffers inside PID 1 until the cgroup limit is hit |
| 7 | E — database failure | Stop Postgres under a live backend, then start it again |
| 8 | D — persistence | `down` then `up`, then `down -v` |
| 9 | C — daemon restart | `docker desktop restart`, then wait without issuing any compose command |

Drill A runs three sub-cases in one script because the first two are what make
the third meaningful. Drill B samples `docker inspect` in a polling loop rather
than after the fact, for the reason in section 6.3. Drill C is the machine-level
case: Live Restore is off on this engine, so the containers genuinely stop with
the daemon, and the script issues no `docker compose up` afterwards — whatever
comes back is the restart policies doing the work.

---

## 5. Measured results

### 5.1 Network isolation

Nineteen assertions, all passing (`02-network-isolation.log`).

| Check | Result |
|---|---|
| Containers publishing a host port | 1 — nginx, on 8080 |
| backend publishes a host port | no |
| postgres publishes a host port | no |
| Host → Postgres on 5432 | refused, `curl` exit 7 |
| Host → backend on 3000 | refused, HTTP `000` |
| Host → backend through the proxy | HTTP 200 |
| `/internal/*` through the proxy | HTTP 405 |
| **nginx resolving `postgres`** | **fails, exit 2 — the name does not resolve** |
| nginx → `postgres:5432` | connection fails |
| backend resolving `postgres` | `172.20.0.2` |
| postgres resolving `example.com` | fails, exit 2 |
| `internal-net` `Internal` flag | `true` |

Membership, read from `docker network inspect`:

```
task02-edge-net      : task02-backend, task02-nginx        internal: false
task02-internal-net  : task02-postgres, task02-backend     internal: true
```

The check that carries the argument is nginx failing to resolve `postgres`.
Every other row on that list would also hold on a single shared network with no
ports published — those rows only prove nothing is exposed to the host. Name
resolution failing is what shows the data tier is unaddressable from the edge
tier, which is the property that survives a compromised proxy.

### 5.2 Resource allocation

Read back from the daemon (`02-resources.log`). Docker VM: 12 CPUs,
8,285,016,064 bytes of memory, cgroup v2.

| Service | Mem limit | Mem reservation | CPU limit | MemSwap | Idle usage | Under load |
|---|---|---|---|---|---|---|
| postgres | 512 M | 256 M | 1.00 | 1024 M | 36.24 MiB (7.08 %) | 36.24 MiB (7.08 %) |
| backend | 256 M | 64 M | 0.75 | **256 M** | 17.2 MiB (6.72 %) | 19.28 MiB (7.53 %) |
| nginx | 128 M | 32 M | 0.50 | 256 M | 10.27 MiB (8.02 %) | 10.4 MiB (8.12 %) |

Totals: 2.25 CPU and 896 MiB of limits against 12 CPUs and 7,901 MiB — about
11% of the VM's memory, leaving the rest as headroom.

The specific numbers, and why each one:

- **postgres 512 MiB / 1.00 CPU.** Postgres's default `shared_buffers` is
  128 MiB; with a 10-connection pool and per-connection `work_mem` on top,
  512 MiB is roughly four times the working set with room for autovacuum. It
  gets the largest CPU share because it is the only tier doing query work.
- **backend 256 MiB / 0.75 CPU.** Measured idle usage is 17.2 MiB, so 256 MiB
  is about fifteen times the steady state. It is deliberately low enough that
  the drill's 16 MiB allocations exhaust it quickly — the cgroup kill landed at
  t+1020 ms — without the container being so constrained that normal operation
  risks a spurious kill.
- **nginx 128 MiB / 0.50 CPU.** Static files and JSON proxying, measured at
  10.27 MiB idle. 128 MiB covers connection buffers at 1024 worker connections.
- **Reservations** sit at roughly the observed steady state, which is what a
  reservation is for — a scheduling floor, not a cap.

Storage: a named volume `task02-pgdata`, 46 MiB after seeding, at
`/var/lib/docker/volumes/task02-pgdata/_data`. Image sizes: `postgres:16`
636 MB, `task02-backend:1.0.0` 254 MB, `task02-nginx:1.0.0` 73.6 MB.

### 5.3 The five drills

| Drill | What was done | Measured | Evidence |
|---|---|---|---|
| A — process crash | PID 1 exits non-zero | `RestartCount` 0 → 1, host PID 47132 → 47319, `StartedAt` advanced, HTTP 200 through the proxy after **2827 ms**, 5 rows intact | `02-drill-a-crash.log` |
| A — operator stop | `docker kill` | exit 137, container stays exited, `RestartCount` 0 → 0, proxy returns `000` while down | `02-drill-a-crash.log` |
| A — signal to PID 1 | `kill -9 1` from inside | status `running`, host PID 9391 → 9391, `RestartCount` 0 | `02-drill-a-crash.log` |
| B — RAM exhaustion | 16 MiB buffers allocated in PID 1 against a 256 MiB limit | `OOMKilled: true`, exit 137 at **t+1020 ms**; `RestartCount` 0 → 1, host PID 520 → 1450, healthy again **2090 ms** after allocation began; postgres and nginx restarts 0 | `02-drill-b-oom.log` |
| C — daemon restart | `docker desktop restart`, no compose command afterwards | daemon responding after **19 s**, whole stack serving after **20 s**, 3 of 3 running, 4 rows intact, marker row present, `POST` returns id 5 | `02-drill-c-daemon-restart.log` |
| D — persistence | `down` then `up`; then `down -v` | `down`: volume survives, 6 rows → 6 rows, marker present, `welcome` seed occurrences 1. `down -v`: volume gone, marker gone, re-seeded to 2 rows | `02-drill-d-persistence.log` |
| E — database failure | `stop postgres` under a live backend | `/api-health` returns **503 in 2.004738 s** with `status: degraded`; `/api/items` 503; nginx `/healthz` 200 and the frontend still served; backend `RestartCount` 0 → 0; reconnected in **1503 ms** with no restart | `02-drill-e-dbfail.log` |
| E2 — cold-start race | backend started while Postgres was down | 2 `db.waiting` retries logged, `db.ready` on attempt 2, then `backend.listening`; no restart | `02-drill-e-dbfail.log` |

The degraded response body, verbatim:

```json
{"status":"degraded","database":{"reachable":false,"error":"database probe exceeded 2000ms"},"service":"backend","uptimeSeconds":48,"pid":1}
```

and the retry sequence when the backend started before its dependency:

```
{"ts":"2026-08-25T19:26:01.089Z","level":"warn","event":"db.waiting","attempt":1,"attempts":30,"error":"Connection terminated due to connection timeout"}
{"ts":"2026-08-25T19:26:04.617Z","level":"info","event":"db.ready","attempt":2}
{"ts":"2026-08-25T19:26:04.630Z","level":"info","event":"db.migrated","migrationApplied":false,"rowsSeeded":0,"idempotent":true}
{"ts":"2026-08-25T19:26:04.633Z","level":"info","event":"backend.listening","port":3000,"pid":1}
```

### 5.4 Secrets

Source: `02-secrets.log`.

| Check | Result |
|---|---|
| Password passed with `-e`, in `docker inspect` | visible in plaintext |
| Same value in `/proc/1/environ` | visible |
| Real password in `task02-postgres` inspect output | absent from the entire output |
| Real password in `task02-backend` inspect output | absent from the entire output |
| Real password in `task02-nginx` inspect output | absent from the entire output |
| Real password in `task02-backend:1.0.0` image metadata | absent |
| Real password in `task02-nginx:1.0.0` image metadata | absent |
| Secret file gitignored | yes |
| Secret file tracked by git | no |

---

## 6. What the measurements revealed

### 6.1 `docker kill` is recorded as operator intent, so the policy declines to act

The obvious way to test crash recovery is `docker kill`, and it does not do what
it looks like it does (`02-drill-a-crash.log`):

```
    status=exited  ExitCode=137  RestartCount 0 -> 0
    proxy -> backend while down: HTTP 000 (502/504 = genuinely gone)
```

The container exits 137 and stays exited. `RestartCount` never moves. Docker
records a `kill` as an operator action, and `unless-stopped` means precisely
"restart unless a human stopped it". The policy is working exactly as designed,
and a drill built on `docker kill` therefore proves the *opposite* of what it
appears to: it demonstrates the policy correctly refusing to fight an operator.

That is genuinely worth having as a check — it is the behavior you want when
you take a container down on purpose and do not want the daemon arguing with
you — so it stays in the drill, labeled for what it is. What it cannot do is
stand in for a crash.

A genuine crash is PID 1 dying on its own. `POST /internal/chaos/crash` makes
the Node process flush its response and then `process.exit(1)`. Against that,
the policy does act, and every field moves:

```
    before: RestartCount=0  hostPID=47132  StartedAt=2026-08-25T19:19:53.116251134Z
    after:  RestartCount=1  hostPID=47319  StartedAt=2026-08-25T19:20:01.09789168Z
            MEASURED DOWNTIME: 2827 ms (crash -> HTTP 200 through the proxy)
```

Three independent confirmations that it is a new process rather than a resumed
one: the restart counter incremented, the host PID changed, and `StartedAt`
advanced by 7.98 s. Any one alone could be misread. Together they are
unambiguous.

### 6.2 `kill -9 1` from inside a container does nothing at all

The natural fallback, when `docker kill` turns out to be an operator action, is
to kill PID 1 from inside the container. That is silently discarded
(`02-drill-a-crash.log`):

```
    status=running  pid 9391 -> 9391  RestartCount=0
[PASS] SIGKILL to PID 1 from inside was ignored, container untouched
```

The kernel does not deliver uncatchable signals to PID 1 from within its own
PID namespace, precisely so that a container's init cannot be trivially killed
by its own children. The container did not even die. A drill built on this and
checking only "did the service recover" would report a pass having done
absolutely nothing.

The consequence for the RAM drill is the important part. A memory hog started
with `docker exec` is a *child* process, so when the cgroup limit is hit the
kernel OOM killer reaps the child, PID 1 survives, the container stays up, and
`State.OOMKilled` reads `false`. That drill would prove nothing about the
container's memory limit while appearing to run correctly. So the allocation
happens inside the backend process itself, which is why `/proc/1/comm` is
checked to read `node` before the drill starts, and why the allocator uses
`Buffer.allocUnsafe` rather than JavaScript arrays — Buffer memory sits outside
the V8 heap, so it is not capped by `--max-old-space-size` — and fills every
buffer, because untouched pages may never be faulted in and therefore never
charged to the cgroup.

### 6.3 `State.OOMKilled` describes the container you are looking at, and after a restart that is a different one

Reading `docker inspect` after the restart policy has acted shows:

```
    State.OOMKilled : false
    State.ExitCode  : 0
    State.Status    : running
```

That is not a contradiction of the kill. It is a description of the
*replacement* container. Docker resets those fields when it starts the new
process, so an inspect taken a second too late reports a healthy container and
no evidence that anything died.

The flag has to be captured while the dead container's state is still current,
which means polling during the kill rather than inspecting afterwards. The
drill does that, and caught it at t+1020 ms:

```
    t+1020ms: OOMKilled=true status=running exit=137   <-- CAPTURED
```

One detail in that line is worth reading carefully: `status=running` alongside
`OOMKilled=true`. The sample landed mid-transition, with the flag set from the
dead instance and the status already reflecting its replacement. `ExitCode` is
subject to the same race and can read 0 in a late sample, so the drill treats
`State.OOMKilled` as the authoritative signal and labels the exit code as what
it is. The clean capture has both: `OOMKilled: true` and `ExitCode: 137`, which
is 128 + SIGKILL.

Recovery was unattended: `RestartCount` 0 → 1, host PID 520 → 1450, health
endpoint returning 200, and the whole cycle from the first allocation to a
healthy service took 2090 ms. Postgres and nginx recorded zero restarts, which
is the cgroup limit doing its other job — containing the blast radius so one
tier exhausting memory does not take the others with it.

### 6.4 `depends_on` orders the first `up`, and nothing after that

This is the finding that changed how I think about the whole pattern.

After `docker desktop restart`, all three containers came back inside a 14.66 ms
window (`02-drill-c-daemon-restart.log`):

```
    backend:  startedAt=2026-08-25T19:28:14.403921353Z
    nginx:    startedAt=2026-08-25T19:28:14.408433834Z
    postgres: startedAt=2026-08-25T19:28:14.418578633Z
```

The backend started 14.66 ms *before* Postgres. It declares `depends_on:
postgres: condition: service_healthy`, and that ordering was not applied.

The reason is that `depends_on` is a Compose-time construct. It orders the
containers that `docker compose up` creates, in the process that reads the
compose file. When the *daemon* restarts, there is no compose process involved:
the engine starts containers according to their restart policies, in an order
it chooses, and the dependency graph is not consulted because nothing is
reading it.

The stack recovered anyway — daemon back in 19 s, whole stack serving in 20 s,
all four rows intact and a write succeeding immediately afterwards. On that
particular run the backend connected on its first attempt, so its retry loop
was not what saved it; Postgres simply won the race by accepting a connection
before the backend's first query.

That makes the recovery a coincidence of timing rather than a designed
guarantee, so the safety net was tested separately. Drill E2 starts the backend
while Postgres is deliberately down. Two `db.waiting` retries are logged, then
`db.ready` on attempt 2, then `backend.listening` — with `RestartCount`
unchanged and the container status `running` throughout the wait.

The conclusion is general and it is the single most transferable thing in this
task. **Healthchecks and `depends_on` make the first start reliable. They do
nothing for a machine restart. Application-level retry is what actually
converges the stack**, and without it the backend would crash-loop until
Postgres happened to win a race, on every reboot, forever.

Two implementation details make that retry loop work rather than merely exist.
`waitForDatabase` retries 30 times at 1 s intervals before giving up, so a slow
database start is tolerated and a genuinely absent one still fails eventually
rather than hanging. And the pool carries an error handler:

```js
pool.on('error', (error) => {
  log('warn', 'db.pool.error', { error: error.message });
});
```

Without it, a pool-level error on an idle client — which is exactly what
Postgres being killed mid-connection produces — reaches Node as an uncaught
exception and the process exits. The backend would look crashed when the real
fault is entirely downstream, and `RestartCount` would climb on a container
that was working perfectly.

### 6.5 A health endpoint that blocks is its own failure mode

The first run of drill E failed, and the assertion was not what was wrong.

`/health` ran `SELECT 1` inheriting the pool's `connectionTimeoutMillis` of
5000 ms. nginx's `proxy_read_timeout` for `/api-health` is 5 s. With Postgres
down those two raced each other, so the caller sometimes received the backend's
honest JSON 503 and sometimes nginx's 504 HTML page, depending on which side
lost by a few milliseconds.

The backend was not lying. It was telling the truth slowly, and a health check
that takes five seconds to admit bad news is useless to whatever is asking —
an orchestrator, a load balancer, or a drill. Bounding the probe to 2000 ms,
comfortably inside the proxy's 5 s, makes the answer deterministic:

```
    /api-health -> HTTP 503
    /api-health response time while DB is down: 2.004738s
    body: {"status":"degraded","database":{"reachable":false,"error":"database probe exceeded 2000ms"},...}
```

The test had a second, independent fault beside it: it fetched the status code
and the body in two separate requests, so a 504 body could be reported next to
a 503 status captured from a different attempt. Both were fixed, and neither
assertion was weakened to get there — the endpoint now returns 503 in 2.00 s
every time, and the drill reads one response.

The general form: any probe inherits a timeout from somewhere. If you do not
choose it, you have chosen whatever the client library defaults to, and the
layers above you have chosen theirs independently. Nesting them explicitly is
what makes failure behavior deterministic instead of a race.

### 6.6 `docker inspect` shows the value for an environment variable and a path for a file

The comparison runs both ways in one script (`02-secrets.log`), abridged here
to the lines that carry it:

```
# A password in an environment variable
$ docker inspect <container> --format '{{range .Config.Env}}{{println .}}{{end}}'
    POSTGRES_PASSWORD=DEMO-FAKE-PASSWORD-not-the-real-one-3f9a2c   <-- the value
    APP_NAME=demo

# The same class of value as a file-based secret, on the real container
$ docker inspect task02-postgres --format '{{range .Config.Env}}{{println .}}{{end}}'
    POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password          <-- a path
    POSTGRES_DB=appdb
    POSTGRES_USER=appuser
```

Anyone who can reach the Docker socket reads the first without entering the
container and without any credential of their own. It is inherited by every
child process, it is in `/proc/1/environ`, and process-level crash reporters
routinely capture the environment block.

The sweep is the part that makes the second claim strong rather than
decorative. It searches the *entire* inspect output of all three containers —
not just `Config.Env`, but mounts, labels, args and every other field — plus
the metadata of both built images, for the real password. It appears in none of
them, and the file is gitignored and untracked.

**What the file secret is, precisely.** Compose outside Swarm implements
`secrets: file:` as a bind mount rather than the in-memory tmpfs that Swarm and
Kubernetes secrets use, and the inspect output says so:

```
      type=bind destination=/run/secrets/postgres_password rw=false
      -rwxrwxrwx root:root /run/secrets/postgres_password (41 bytes)
```

So the plaintext exists on the host disk at `secrets/postgres_password.txt`,
and the `777` mode shown is an artifact of the Windows/WSL bind mount rather
than a permission the file carries on an ext4 host. What the file form buys is
still real and still worth the change: the value stays out of container
metadata, out of every child process's environment, and out of crash dumps. The
production shape of this is the same compose file with the host file
materialized from Vault, AWS Secrets Manager, or a SOPS-encrypted file at rest,
rather than generated by `up.sh` and left in place.

### 6.7 `down` and `down -v` prove each other

The persistence claim is only meaningful if the destructive variant is also
shown to destroy. Drill D runs both halves against the same marker row
(`02-drill-d-persistence.log`):

| Operation | Volume | Row count | Marker row |
|---|---|---|---|
| write marker | present | 6 | present |
| `docker compose down`, then `up` | survives | 6 | present |
| `docker compose down -v`, then `up` | removed | 2 (seed only) | gone |

The `welcome` seed row occurs exactly once after the `down`/`up` cycle, which
is the idempotent migration doing its job. Had the seed been a blind `INSERT`,
the row count would have grown on every restart and the whole drill would be
measuring the migration rather than the volume.

That is the shape of the check: a survival claim is worth as much as its
matching destruction claim, and no more.

### 6.8 A shell variable named `TMP` broke Docker builds on Windows

The evidence-capture script used `TMP="$(mktemp)"`. On Windows, `TMP` is
already an exported environment variable naming the temp *directory*, so
assigning a *file* path to it corrupted temp resolution for every Windows child
process the script spawned. `docker compose build` failed with:

```
invalid output path: stat <file>: The system cannot find the path specified
```

An error that names neither the variable nor the script that set it. The fix is
a rename to `CAPTURE_FILE`. It is recorded here because the failure mode stays
completely silent until a native Windows binary happens to need its temp
directory, which can be many steps away from the assignment that caused it —
and because the same trap is waiting for `TEMP`, `PATH`, `HOME` and `PROGRAMDATA`
in any shell script that runs on both platforms.

---

## 7. How to run it yourself

Docker Desktop, and Git Bash if you are on Windows.

### Bring the stack up

```bash
cd 02-docker-stack
./scripts/up.sh
```

Idempotent. It generates `.env` and the database password on first run, builds
both images, and blocks until all three services report healthy. When it
finishes, the frontend is at `http://127.0.0.1:8080/` and the API at
`http://127.0.0.1:8080/api/items`.

`make` is not installed on the development host, so the Makefile targets are
convenience wrappers around these scripts. The scripts are the tested interface
and are what produced every log referenced here.

### Run everything

```bash
./scripts/verify.sh            # every check and every drill
./scripts/verify.sh --quick    # the non-destructive checks only
```

`--quick` skips drills A through E, which is what you want while iterating —
the full run restarts the Docker daemon at the end.

### Run one piece at a time

```bash
./scripts/smoke-test.sh                      # DB round trip through the proxy
./scripts/isolation-check.sh                 # 19 assertions about the topology
./scripts/resources.sh                       # limits from the daemon, usage idle and loaded
./scripts/drills/05-secrets-comparison.sh    # env var vs file secret, side by side
./scripts/drills/01-backend-kill.sh          # crash, operator stop, signal to PID 1
./scripts/drills/02-oom-kill.sh              # RAM exhaustion to OOMKilled
./scripts/drills/04-db-failure.sh            # database killed under a live backend
./scripts/drills/03-persistence.sh           # down keeps data, down -v destroys it
./scripts/drills/06-daemon-restart.sh        # daemon restart, unattended recovery
```

Run `06-daemon-restart.sh` last. It restarts the Docker engine, so anything
holding a Docker connection at the time will lose it.

### Exercise the API by hand

```bash
curl -s http://127.0.0.1:8080/api/items
curl -s -X POST http://127.0.0.1:8080/api/items \
     -H 'Content-Type: application/json' \
     -d '{"name":"hello","description":"from curl"}'
curl -s -i http://127.0.0.1:8080/api-health
curl -s http://127.0.0.1:8080/healthz
```

`/api-health` returns 503 with `status: degraded` whenever Postgres is
unreachable, and `/healthz` keeps returning 200 because nginx answers it
itself.

### Tear down

```bash
docker compose down       # stop the containers, keep task02-pgdata
docker compose down -v    # stop the containers and destroy the data volume
```

`down` leaves the volume and every row in it. `down -v` removes both, and the
next `up.sh` re-seeds a fresh database with two rows. Nothing is left running
afterwards, verified against `docker compose ps` and `docker volume ls`.

### Set it to something resembling production

Three changes, all in configuration:

1. `CHAOS_ENABLED=false` in `.env`, which removes the two `/internal/chaos/*`
   routes entirely — the backend logs the flag's state at startup either way.
2. Materialize `secrets/postgres_password.txt` from a secret manager instead of
   generating it, as described in section 6.6.
3. Put TLS in front of nginx, or terminate it there. Port 8080 is plain HTTP,
   which is right for a single-host demonstration and not for anything else.

---

## Evidence index for this task

| Log | Covers |
|---|---|
| `docs/evidence/02-stack-up.log` | One command from nothing to three healthy services |
| `docs/evidence/02-smoke-test.log` | Ten assertions on the full path through port 8080 |
| `docs/evidence/02-network-isolation.log` | Nineteen assertions about topology, DNS and membership |
| `docs/evidence/02-resources.log` | Limits read back from the daemon, usage idle and under load, volume and image sizes |
| `docs/evidence/02-secrets.log` | Environment variable against file secret, plus the full-config sweep |
| `docs/evidence/02-drill-a-crash.log` | Signal to PID 1, operator stop, genuine crash and 2827 ms recovery |
| `docs/evidence/02-drill-b-oom.log` | `OOMKilled: true` at t+1020 ms, exit 137, 2090 ms to healthy |
| `docs/evidence/02-drill-c-daemon-restart.log` | Daemon restart, 20 s unattended recovery, the 14.66 ms start window |
| `docs/evidence/02-drill-d-persistence.log` | `down` preserves, `down -v` destroys |
| `docs/evidence/02-drill-e-dbfail.log` | Honest 503 in 2.00 s, reconnect in 1503 ms, the cold-start retry loop |
