# Task 3 — SQL Server: database, tables, automated backups, restore

This is the long form of Task 3. Section 5 of `docs/REPORT.md` carries the
two-page summary; everything below is the reasoning, the full build, and the
findings that came out of running it.

Every figure names the evidence file it came from. The evidence lives in
`docs/evidence/03-*.log`.

---

## 1. What this task required, and how I read it

The requester's words, clause by clause:

> set up an MSSQL database (managed or self-hosted)
> create a database
> create tables and insert data
> automated backups
> restore from a backup

Five clauses, and four of them have more than one honest reading. I fixed each
reading before writing code, and I state them here so the work can be judged
against the interpretation rather than against a guess.

**"managed or self-hosted" is a real choice, so it gets a real justification.**
The clause offers two paths and does not say which. That makes the decision part
of the deliverable, not a detail. Section 2.1 makes the case and names what the
rejected path would have done better.

**"create tables and insert data" means related tables.** A single flat table
with a thousand rows satisfies the sentence and proves nothing about a restore.
Referential integrity is the property most likely to be quietly broken by a bad
recovery, so the schema is four tables joined by three foreign keys with two
different delete rules. A restore that returns rows but breaks the relationships
between them has to fail visibly.

**"automated backups" means a schedule that runs with nobody watching, and
verification of what it produced.** Writing a `.bak` file is the easy half. A
backup nobody has ever read back is an assumption, not a recovery plan — so
every backup this task produces is written `WITH CHECKSUM` and then read back
with `RESTORE VERIFYONLY` before it is called done.

**"restore from a backup" means proving the data afterward is the data from
before.** A restore that merely completes proves the command parses. What has to
be shown is equality: a fingerprint of the database taken before the damage, and
the identical fingerprint after the recovery. Row counts alone would pass a
restore that returned the right number of rows with the wrong contents inside
them.

I then went one step past the clause. Restoring a whole database from a file is
what a file copy of the data directory can also do. Recovering to a chosen
*instant* — one that lands between two committed transactions, with the
transaction after it rolled away — is what a transaction log chain buys and
nothing else does. So the task carries a second restore drill that does exactly
that, and it is the strongest evidence in this section.

---

## 2. Design decisions

### 2.1 Self-hosted SQL Server 2022 in Docker, over a managed database service

The decisive property: **a managed service owns the backup mechanics, and the
backup mechanics are what this task asks to demonstrate.**

Azure SQL Database takes full, differential and log backups on its own cadence,
and point-in-time restore is a control in a portal. Every one of those is a good
thing to have in production and a bad thing to submit as evidence of
understanding. A screenshot of a managed backup blade shows that the provider
implements backups. It does not show that I can build a restore chain, and it
never surfaces the one detail that decides whether a chain works — that
`NORECOVERY` must precede `RECOVERY`, and that using `RECOVERY` one step early
throws away every log file still waiting to be applied.

| Property | Self-hosted SQL Server 2022 (chosen) | Azure SQL Database / RDS for SQL Server |
|---|---|---|
| Who owns the backup schedule | Me: interval, retention, verification | The provider; the schedule is not mine to change |
| Point-in-time restore | Assembled by hand from full + log chain with `STOPAT` | A portal control; the chain is not visible |
| Recovery model | Mine to set, and mine to demonstrate failing under SIMPLE | Fixed at FULL |
| Reproducibility | `compose.yaml` and scripts in git, digest-pinned | Depends on subscription and resource state |

What the rejected path does better, stated plainly: a managed service handles
patching, high availability, geo-redundant backup storage and automated
failover. For a production order-management database, Azure SQL is very likely
the better answer. The decision here is driven by what the assignment asks to be
*demonstrated*.

### 2.2 FULL recovery model, over SIMPLE

FULL recovery keeps every transaction in the log until a log backup captures it.
That is the entire basis for point-in-time recovery, and it is why the choice is
load-bearing rather than cosmetic.

SIMPLE recovery truncates the log at each checkpoint. The engine does not warn
about the consequence in advance; it refuses at the moment you try to use it.
`03-backup-tiers.log` carries the refusal, produced deliberately by switching
`AppDb` to SIMPLE and asking for a log backup:

```
Msg 4208, Level 16, State 1, Server b18f0ab97122, Line 1
The statement BACKUP LOG is not allowed while the recovery model is SIMPLE. Use BACKUP DATABASE or change the recovery model using ALTER DATABASE.
Msg 3013, Level 16, State 1, Server b18f0ab97122, Line 1
BACKUP LOG is terminating abnormally.
```

Demonstrating the failure is worth more than asserting the requirement, because
the failure is where the wrong choice actually bites. Under SIMPLE,
the recovery point available to you is the last full or differential backup, full
stop.

There is a second-order effect the same drill closes. A SIMPLE-to-FULL round trip
**breaks the log chain**: until a fresh full backup exists, the database is only
nominally in FULL recovery and a log backup has no base to attach to. That is a
realistic way to acquire a silent hole in a recovery plan — the model reads FULL,
the log backups appear to run, and the chain reaches back to nothing. The drill
takes a new full backup immediately after restoring the model and confirms the
next log backup succeeds (`03-backup-tiers.log`, "log chain re-established after
the recovery model round trip").

`ALTER DATABASE AppDb SET PAGE_VERIFY CHECKSUM` is set alongside it
(`sql/01-create-database.sql`). Every page written carries a checksum validated
on read, which is what `BACKUP ... WITH CHECKSUM` then relies on to validate
pages as they stream into the backup file. `03-schema.log` reports `page_verify`
as `CHECKSUM`.

### 2.3 Four related tables, over one table with more rows

```
customers ──< orders ──< order_items >── products
```

The shape was chosen so that a restore has something to get wrong. Two delete
rules, deliberately different:

- `order_items` cascades from `orders`. A line item has no meaning without the
  order that contains it, so removing the order should take its lines with it.
- `orders` does **not** cascade from `customers`. Deleting a customer who has
  live orders should fail loudly rather than silently destroy order history.

Every foreign key column carries a non-clustered index. SQL Server creates
indexes for primary keys and unique constraints automatically and **does not**
create one for a foreign key, so without `IX_orders_customer`, `IX_items_order`
and `IX_items_product`, every parent-to-child join and every referential check
performed on a delete is a scan.

The seed data is generated arithmetically from a recursive-CTE tally table rather
than from `RAND()` or `NEWID()` (`sql/03-seed.sql`). Determinism is the point: the
same seed produces byte-identical rows, so `CHECKSUM_AGG(BINARY_CHECKSUM(*))` is
comparable across runs and across a restore. A random seed would make the
fingerprint meaningless the moment the stack was rebuilt.

Everything is idempotent — `IF OBJECT_ID(...) IS NULL` around each object,
`NOT EXISTS` around each insert. The drills bring the stack up repeatedly, and
duplicate seed rows would quietly invalidate every row-count assertion that
follows.

### 2.4 A sidecar scheduler, over SQL Server Agent — with Agent's availability measured, not assumed

The common claim is that SQL Server Agent is unavailable in Linux containers.
I probed the running instance instead of repeating it, and the claim is the
wrong way round for this image.

From `03-agent-availability.log`, querying `sys.dm_server_services`:

```
servicename                     status_desc   startup_type_desc
SQL Server Agent (MSSQLSERVER)  Running       Automatic
```

Agent is **present and Running** on this instance, with `MSSQL_AGENT_ENABLED=true`
passed to the container. `msdb.dbo.sysjobs` is reachable, with a row count of 0.
Agent ships disabled in the Developer image, not absent — one environment
variable and a restart turns it on.

I kept the sidecar anyway, for three reasons that survive Agent being available:

1. **The schedule stays in version control as plain shell.** Agent's schedule
   lives as rows inside `msdb`, which is itself only recoverable from a backup.
   A backup schedule whose definition depends on a working restore is a circular
   dependency I would rather not own.
2. **The scheduled code and the demonstrated code are provably the same code.**
   `backup/backup.sh` is what the scheduler calls on its interval, and it is what
   the drills call by hand. There is no second implementation to drift.
3. **It works on Express edition**, where Agent genuinely is absent.

A plain `while` loop is used rather than cron inside the container. Cron needs a
running daemon, does not inherit the container environment without help, and
swallows stdout so backup output never reaches `docker logs`. The loop ticks
every 15 seconds (`TICK_SEC`) and compares elapsed time against each tier's
interval, so its output lands exactly where an operator looks for it.

### 2.5 A named volume for `/var/opt/mssql`, over a Windows bind mount

The container runs as the unprivileged `mssql` user, uid 10001, and SQL Server
insists on owning its data directory. A Windows bind mount cannot express that
ownership: files surface as root-owned or 0777 with no way to `chown` them, and
the engine exits at startup on the data files. A named volume lives inside the
Linux VM filesystem where ownership behaves normally. The reasoning is recorded
at the mount point itself in `compose.yaml` so the next person to "simplify" it
into a bind mount reads why first.

### 2.6 A file-based secret with an entrypoint wrapper

The SA password is a Docker secret at `./secrets/mssql_sa_password.txt`, mounted
into both containers at `/run/secrets/mssql_sa_password`.

The tension is specific to this image and worth naming. The Postgres image reads
`POSTGRES_PASSWORD_FILE` natively, so the value never has to become an
environment variable at all. The SQL Server image has no `_FILE` convention:
`sqlservr` reads `MSSQL_SA_PASSWORD` from its environment.

The wrapper at `mssql/entrypoint.sh` is the mitigation. It reads the secret file,
validates it, exports the value, and `exec`s `sqlservr` so the engine becomes
PID 1 and receives signals directly. `MSSQL_SA_PASSWORD` is absent from the
compose `environment:` block, with the reason written at `compose.yaml:33`:

```
# NOTE: MSSQL_SA_PASSWORD is deliberately absent. The entrypoint wrapper
# reads it from the secret below, so it never enters this configuration
# and therefore never appears in `docker inspect`.
```

The property that holds by construction: the variable is created by the wrapper
at container start, so it is not part of the container's configuration, and
container configuration is what `docker inspect` reads.

The validation step is worth its lines. SQL Server rejects a weak SA password and
then exits, logging one line, leaving a container that simply will not start and
gives no hint why. The wrapper checks length and character classes first and
fails with a readable message:

```
[ "$LENGTH" -ge 8 ] || fail "SA password is $LENGTH characters; SQL Server requires at least 8"
...
fail "SA password uses only $CATEGORIES of the 4 character categories; SQL Server requires at least 3"
```

`scripts/up.sh` generates the password as `Aa1!` plus 20 random base64 characters,
so all four categories are present by construction rather than by luck.

The backup sidecar has no such constraint. `backup/lib.sh` reads the secret file
directly on each invocation and never exports it.

### 2.7 A healthcheck that runs a real query

A healthcheck that probes TCP 1433 reports healthy while the engine is still
recovering databases and cannot answer anything. The healthcheck in
`mssql/Dockerfile` runs `SELECT 1` through sqlcmd, with `-C` to trust the
self-signed certificate and `-l 5` so a hung probe fails instead of blocking.

The backup sidecar depends on `service_healthy`, not `service_started`. The
engine accepts TCP connections well before it can answer a query, and a backup
issued inside that window fails.

---

## 3. How it is built

Two containers on a private bridge network, sharing a backups volume.

```
                      task03-db-net (bridge)
   ┌──────────────────────────┐        ┌─────────────────────────────┐
   │ task03-mssql             │        │ task03-backup               │
   │  entrypoint.sh           │◀───────│  scheduler.sh  (PID 1)      │
   │   └─ sqlservr (PID 1)    │ sqlcmd │   ├─ backup.sh full|diff|log│
   │  healthcheck: SELECT 1   │        │   └─ retention.sh           │
   └────────────┬─────────────┘        └──────────────┬──────────────┘
                │                                     │
        mssqldata (named)                    backups (named, shared)
                                                      │
                                            /backups/{full,diff,log}
                     host :1433 ──▶ mssql:1433
```

### 3.1 The engine container

`mssql/Dockerfile` builds on `mcr.microsoft.com/mssql/server:2022-latest`, pinned
by digest `sha256:ba4c8329f48fb8f02e1416be6a930ebfd71268caee78aa985f3af4315e457c89`
as well as by tag, so a rebuild resolves the identical base image rather than
whatever `2022-latest` points at that week. The digest is echoed back by the
build in `03-stack-up.log`.

Resource envelope, from `compose.yaml`: 2.00 CPUs and 3072 MB limit, 0.50 CPUs
and 2048 MB reservation. `MSSQL_MEMORY_LIMIT_MB=2048` sits inside that. The
ordering matters — SQL Server's own ceiling caps the buffer pool, and the process
needs headroom above it for thread stacks and everything the pool does not cover.
SQL Server also refuses to start below a 2 GB floor, which is what sets the shape
of these numbers.

### 3.2 The SQL, in three files

| File | What it does |
|---|---|
| `sql/01-create-database.sql` | Creates `AppDb` if absent, sets FULL recovery, sets `PAGE_VERIFY CHECKSUM`, reports the three properties back |
| `sql/02-schema.sql` | Four tables, three foreign keys, seven check constraints, four non-clustered indexes, one summary view |
| `sql/03-seed.sql` | Deterministic seed from a tally table: 60 customers, 40 products, 300 orders, 750 order lines |
| `sql/90-state.sql` | The fingerprint query and the orphan count, used to prove a restore is exact |

Each of the first three is guarded so re-running changes nothing. `03-stack-up.log`
shows the second run of `up.sh` reporting `Database AppDb already exists, leaving
it alone` and `AppDb already in FULL recovery model`, with the row counts
unchanged.

### 3.3 The backup sidecar

Four shell files, each with one job.

**`backup/lib.sh`** — the sqlcmd wrapper. Two details about SQL Server 2022 images
bite immediately and are handled here: the binary moved to
`/opt/mssql-tools18/bin/sqlcmd`, and tools18 encrypts by default and validates the
server certificate, so every command needs `-C` or fails with a certificate error.
`-b` is passed on every call so a T-SQL error sets a non-zero exit code — without
it a failed `BACKUP` is logged and ignored.

**`backup/backup.sh`** — takes one backup of one tier. It guards before it acts:
a log backup checks the recovery model is FULL and exits 3 with a readable
message rather than producing Msg 4208; a differential or log backup checks
`msdb.dbo.backupset` for an existing full backup and exits 4 if there is no base
to apply to. Then it runs the backup `WITH INIT, CHECKSUM, COMPRESSION`, and
follows it immediately with:

```sql
RESTORE VERIFYONLY FROM DISK = N'$TARGET' WITH CHECKSUM;
```

`VERIFYONLY` re-reads the file and validates its checksums. It is the step that
turns "a file exists" into "a file that can be restored". On failure the target
file is removed rather than left as a trap for a future restore.

**`backup/scheduler.sh`** — PID 1 in the sidecar. It waits for the instance to
answer queries, then waits for `AppDb` itself to exist (the init job may still be
creating it), then takes an immediate full backup so a restore base exists from
the moment the stack is up rather than only after the first hour elapses. It then
enters the tick loop. It traps `TERM`/`INT` and drops out of the loop, so
`docker compose down` is not a ten-second wait for SIGKILL.

**`backup/retention.sh`** — per-tier pruning by `find -mmin`. The windows differ
because the tiers have different jobs: full backups are the base every chain
starts from and are kept longest; differentials are only useful until the next
full backup replaces them; logs are the shortest-lived and the most numerous.
After pruning it counts the remaining full backups and takes a fresh one if the
count reached zero — deleting the only base would leave every differential and
log unrestorable.

The failure mode retention actually prevents is worth naming precisely. It is not
"the disk fills". It is that **the next backup fails** when the disk fills, so the
first symptom of an unmanaged volume is having no recent backup.

### 3.4 The host-side harness

`scripts/lib.sh` runs all SQL through `docker exec` into the engine container, so
nothing needs installing on the host. It carries five helpers that the drills
lean on:

- `sql()` — a T-SQL batch with `-b` so errors propagate.
- `sqlv()` — a single bare value suitable for capture into a shell variable. Its
  filter is not cosmetic; see section 6.3.
- `fingerprint()` — the whole-database fingerprint: four row counts, four
  `CHECKSUM_AGG(BINARY_CHECKSUM(*))` values, and the summed order value in
  integer cents.
- `server_now()` — `SYSDATETIME()` on the **server**, formatted for `STOPAT`.
  Deliberately not the host clock: `STOPAT` is interpreted in the server's local
  time zone, and the two differ here — the host runs UTC+03 and the container runs
  UTC.
- `to_single_user()` / `to_multi_user()` — `SET SINGLE_USER WITH ROLLBACK
  IMMEDIATE` before a restore. Without it the restore fails with "database is in
  use", which reads like a broken backup rather than a busy database.

Three drills and two checks sit on top, and `scripts/verify.sh` runs all of them
in one command. Ordering there is deliberate: the non-destructive checks run
first, so a failure in one is never confused with damage a drill caused on
purpose.

---

## 4. The steps, as a narrative

What follows is the sequence `scripts/verify.sh` executes, told as a person would
follow it.

**Step 1 — configuration.** `scripts/up.sh` copies `.env.example` to `.env` if
absent and leaves an existing one untouched. It generates the SA password secret
if the file is empty, `chmod 600`, and prints the character count and category
count without printing the value. On the captured run both already existed:
`.env present, left untouched` / `SA password secret present, left untouched`
(`03-stack-up.log`).

**Step 2 — build.** Both images build from the digest-pinned base. The build
output in `03-stack-up.log` shows the layers cached and both images tagged
`task03-mssql:1.0.0` and `task03-backup:1.0.0`.

**Step 3 — start, and wait for a query to succeed.** `docker compose up -d --wait
--wait-timeout 300`. The compose output walks through
`task03-mssql Starting → Started → Waiting → Healthy`, then the sidecar, then
both healthy. The generous timeout exists because SQL Server's first start
initializes system databases.

**Step 4 — create, apply, seed.** The three SQL files run in order through
`docker exec`. On a fresh database this creates everything; on a re-run it is a
no-op that prints so. `03-stack-up.log` closes on the fingerprint and orphan
count:

```
FINGERPRINT:60|40|300|750|1717351129|1666377240|1234855848|-361695091|33093050
ORPHANS:0|0|0
```

**Step 5 — inventory the schema, and prove the constraints bite.**
`scripts/checks/schema-report.sh` lists database properties, tables with row
counts and storage, foreign keys with their delete rules, check constraints with
their definitions, and indexes. It then attempts two inserts that must fail. Both
do, with Msg 547 (`03-schema.log`): a product at `unit_price = -1.00` rejected by
`CK_products_price`, and an order for customer 999999 rejected by
`FK_orders_customer`. Constraints that have never been tested are decoration.

**Step 6 — probe Agent.** `scripts/checks/agent-availability.sh` reads the
edition and version, the container's `MSSQL_AGENT_ENABLED`, and
`sys.dm_server_services`, then checks that `msdb.dbo.sysjobs` is reachable. The
result is section 2.4.

**Step 7 — the backup tiers drill.** `scripts/drills/03-backup-tiers.sh`:

1. Confirms the sidecar is running with `restart: unless-stopped` and prints its
   recent log, including the unattended startup full backup.
2. Takes one backup of each tier on demand, calling the same `backup.sh` the
   scheduler calls.
3. Reads `msdb.dbo.backupset` — SQL Server's own record — for tier, finish time,
   size, compressed size, checksum flag and LSN range.
4. Counts backups written without checksums. The answer has to be 0.
5. Lists the files actually on the volume, per tier.
6. Switches to SIMPLE, attempts `BACKUP LOG`, captures Msg 4208, restores FULL,
   takes a fresh full backup to re-establish the chain, and confirms a log backup
   then succeeds.
7. Runs the retention pass and prints the before/after file counts per tier.

**Step 8 — the restore round trip.** `scripts/drills/01-restore-roundtrip.sh`:
fingerprint, full backup, `RESTORE VERIFYONLY`, then damage, then proof of
damage, then restore, then fingerprint again and compare. The damage is
schema-level, not just data-level:

```sql
USE AppDb;
DELETE FROM dbo.order_items;
DELETE FROM dbo.orders;
ALTER TABLE dbo.order_items DROP CONSTRAINT FK_items_product;
DROP TABLE dbo.products;
```

The `ALTER TABLE ... DROP CONSTRAINT` on the third line is load-bearing; section
6.4 explains why.

**Step 9 — point-in-time recovery.** `scripts/drills/02-point-in-time.sh` builds
a timeline and then recovers into the middle of it:

```
t0  full backup                 <- base of the chain
t1  INSERT MARKER-A
t2  log backup #1
t3  read SYSDATETIME() as the STOPAT target
t4  INSERT MARKER-B
t5  log backup #2               <- contains MARKER-B
```

then restores full `WITH NORECOVERY`, applies log #1 `WITH NORECOVERY`, and
applies log #2 `WITH STOPAT, RECOVERY`. Correct behavior is MARKER-A present and
MARKER-B absent. The drill asserts the intermediate database state is `RESTORING`
between steps, which is what catches a chain accidentally closed early.

**Step 10 — summary.** `verify.sh` prints a pass line per check. The captured run
reports `ALL 6 CHECKS PASSED` (`03-verify-suite.log`).

---

## 5. Measured results

### 5.1 Engine and database

| Property | Value | Evidence |
|---|---|---|
| Edition | Developer Edition (64-bit) | `03-agent-availability.log` |
| Version | 16.0.4265.3, product level RTM | `03-agent-availability.log` |
| Base image digest | `sha256:ba4c8329…e457c89` | `03-stack-up.log` |
| Database | `AppDb`, state ONLINE, compatibility level 160 | `03-schema.log` |
| Recovery model | FULL | `03-schema.log` |
| Page verification | CHECKSUM | `03-schema.log` |
| SQL Server Agent | Running, startup type Automatic | `03-agent-availability.log` |
| `msdb.dbo.sysjobs` | reachable, 0 rows | `03-agent-availability.log` |

### 5.2 Schema and data

All from `03-schema.log`.

| Table | Rows | Size | Foreign keys | Check constraints | Indexes |
|---|---|---|---|---|---|
| `customers` | 60 | 0.07 MB | 0 | 2 | 2 |
| `products` | 40 | 0.07 MB | 0 | 2 | 2 |
| `orders` | 300 | 0.07 MB | 1 | 1 | 3 |
| `order_items` | 750 | 0.20 MB | 2 | 2 | 4 |
| **total** | **1150** | | **3** | **7** | **11** |

| Check | Result | Evidence |
|---|---|---|
| Orphaned rows across all three foreign keys | `ORPHANS:0\|0\|0` | `03-schema.log` |
| Insert with `unit_price = -1.00` | Msg 547, rejected by `CK_products_price` | `03-schema.log` |
| Order referencing customer 999999 | Msg 547, rejected by `FK_orders_customer` | `03-schema.log` |
| Fingerprint | `60\|40\|300\|750\|1717351129\|1666377240\|1234855848\|-361695091\|33093050` | `03-schema.log`, `03-stack-up.log` |

### 5.3 The three backup tiers

Configured intervals and retention windows come from `.env.example`; the
retention windows are echoed back by the drill.

| Tier | Interval (config) | Retention window | RPO this interval implies | Files a restore needs |
|---|---|---|---|---|
| Full | 3600 s | 1440 min | 1 h | 1 |
| Differential | 900 s | 360 min | 15 min | full + 1 differential |
| Transaction log | 300 s | 120 min | **5 min** | full + differential + every log since |

Effective RPO is **5 minutes**, set by the shortest interval. The tiers exist
because RPO and restore effort pull against each other. Taking only full backups
every five minutes would buy the same RPO at a storage and I/O burden that
scales with database size on every single backup. Taking only log backups makes restores
grow without bound, because every log written since the last full backup must be
replayed in order. The differential tier bounds that replay: a restore needs the
last full, the most recent differential, and only the logs written *since that
differential*.

Measured sizes from `msdb.dbo.backupset`, `03-backup-tiers.log`:

| Tier | Backup size | Compressed | Compression ratio | Checksums |
|---|---|---|---|---|
| FULL | 4440.0 KB | 544.7 KB | 8.2× | yes |
| DIFF | 920.0 KB | 97.4 KB | 9.4× | yes |
| LOG | 1296.0 KB | 259.2 KB | 5.0× | yes |

| Measurement | Value | Evidence |
|---|---|---|
| Backups recorded without checksums | 0 | `03-backup-tiers.log` |
| Files on the volume after the drill | full 3 (1.6M), diff 1 (120K), log 1 (280K) | `03-backup-tiers.log` |
| Retention pass, full tier | 4 → 4 files (window 1440 m) | `03-backup-tiers.log` |
| Retention pass, differential tier | 1 → 1 files (window 360 m) | `03-backup-tiers.log` |
| Retention pass, log tier | 2 → 2 files (window 120 m) | `03-backup-tiers.log` |
| `BACKUP LOG` under SIMPLE recovery | Msg 4208, terminated abnormally | `03-backup-tiers.log` |
| Log chain after restoring FULL + fresh full backup | re-established, next log backup succeeded | `03-backup-tiers.log` |

The startup full backup, taken unattended by the sidecar before any human command:

```
2026-08-25T20:58:03Z [INFO] taking initial full backup so a restore base exists immediately
BACKUP DATABASE successfully processed 546 pages in 0.109 seconds (39.098 MB/sec).
The backup set on file 1 is valid.
2026-08-25T20:58:04Z [INFO] full backup complete and verified: /backups/full/AppDb-full-20260825-205803.bak (569344 bytes)
```

### 5.4 The scheduler running on its intervals

`03-verify-suite.log`, captured a day later, carries `msdb` history from a stack
that had been up for roughly an hour with nobody driving it. Times in this table
are the engine's local clock (UTC); the log header timestamps are host clock
(UTC+03).

| Tier | Finish time | Size | Compressed |
|---|---|---|---|
| LOG | 02:32:42 | 80.0 KB | 11.7 KB |
| LOG | 02:37:42 | 80.0 KB | 8.7 KB |
| LOG | 02:42:42 | 80.0 KB | 8.9 KB |
| LOG | 02:47:43 | 80.0 KB | 15.3 KB |
| DIFF | 02:47:43 | 536.0 KB | 54.6 KB |
| LOG | 02:52:43 | 80.0 KB | 9.4 KB |
| LOG | 02:57:44 | 80.0 KB | 10.1 KB |

Six log backups, five minutes apart, matching `LOG_INTERVAL_SEC=300`, with a
differential landing at 02:47:43. Across those five intervals the total drift is
2 seconds — the loop ticks every 15 seconds, so a scheduled backup fires within
that window of its due time and the drift does not accumulate faster than the
tick.

### 5.5 The restore round trip

All from `03-restore-roundtrip.log`.

| Step | Measurement |
|---|---|
| Pre-damage fingerprint | `60\|40\|300\|750\|1717351129\|1666377240\|1234855848\|-361695091\|33093050` |
| Full backup | 554 pages in 0.091 s (47.518 MB/sec), 4,612,096 bytes |
| `RESTORE VERIFYONLY` | "The backup set on file 1 is valid." |
| Damage: `order_items` | 750 → 0 rows |
| Damage: `orders` | 300 → 0 rows |
| Damage: foreign keys | 3 → 2 |
| Damage: `dbo.products` | dropped (`sys.tables` count 0) |
| `RESTORE DATABASE ... WITH REPLACE, RECOVERY` | 554 pages in **0.050 s** (86.484 MB/sec) |
| Restore wall time, end to end | **2092 ms** |
| Post-restore fingerprint | identical to pre-damage, character for character |
| `customers` / `products` / `orders` / `order_items` | 60 / 40 / 300 / 750, all restored |
| Orphaned rows across all foreign keys | 0 |
| Foreign keys / check constraints after restore | 3 / 7 |

**RTO stated at both layers, because they differ by a factor of forty.**

SQL Server reports the restore itself at **0.050 s for 554 pages**. The drill's
own timer reports **2092 ms**. Both are correct measurements of different things.
The engine figure covers the restore operation and nothing else, and it is the
one that scales with database size. The 2092 ms figure wraps `SET SINGLE_USER
WITH ROLLBACK IMMEDIATE`, the restore, and `SET MULTI_USER` — three separate
`docker exec` invocations, each paying a container exec and a sqlcmd startup.

An operator plans against the 2092 ms figure, because the tooling around the
restore is part of the outage. An engineer sizing a restore for a 500 GB database
extrapolates from the 0.050 s figure, because that is the part that grows.

A second capture of the same drill (`03-verify-suite.log`, against a database
that had accumulated more log activity) reports 690 pages in 0.059 s at
91.300 MB/sec, and 2164 ms end to end — the engine time tracks page count, the
wall time tracks the fixed tooling overhead.

### 5.6 Point-in-time recovery

All from `03-point-in-time.log`. Times are the engine's local clock.

```
t0  full backup                554 pages in 0.099 s
t1  MARKER-A committed         2026-08-25T21:01:31.203
t2  log backup #1               19 pages in 0.015 s
t3  STOPAT target               2026-08-25T21:01:35.666
t4  MARKER-B committed         2026-08-25T21:01:39.109
t5  log backup #2                4 pages in 0.014 s
```

The restore chain, and the database state observed after each step:

| Step | Command | Pages / time | State after |
|---|---|---|---|
| 1 | `RESTORE DATABASE ... WITH REPLACE, NORECOVERY` | 554 pages in 0.050 s | `RESTORING` |
| 2 | `RESTORE LOG` (#1) `WITH NORECOVERY` | 19 pages in 0.026 s | `RESTORING` |
| 3 | `RESTORE LOG` (#2) `WITH STOPAT = '…35.666', RECOVERY` | 4 pages in 0.025 s | `ONLINE` |

| Result | Value |
|---|---|
| MARKER-A (committed 4.463 s **before** the target) | **1** |
| MARKER-B (committed 3.443 s **after** the target) | **0** |
| Total markers after recovery | 1 |
| `customers` after PITR | 60 |
| `order_items` after PITR | 750 |
| Point-in-time restore wall time | **3608 ms** |

**Reconciling the target against the log-backup boundaries.** This is the part
that makes the drill mean something rather than merely pass.

Log backup #1 was taken at t2, after MARKER-A and before the target was even
read. So MARKER-A is inside log #1, and applying log #1 in full brings MARKER-A
back — no `STOPAT` needed for it.

The target instant at t3 falls *after* log backup #1 closed and *before* log
backup #2 closed. It therefore lies strictly inside the interval that log backup
#2 covers, and so does MARKER-B. Log #2 is the only file that contains both the
target instant and the transaction that must not survive it. That is precisely
why the `STOPAT` clause belongs on the final `RESTORE LOG` and nowhere else:
applying log #2 in full would replay MARKER-B's insert, and stopping short of log
#2 entirely would recover to the end of log #1 — a different instant that happens
to give the same marker answer here but is not the instant that was asked for.

The chain is the other half. `NORECOVERY` leaves the database in `RESTORING` so
further log files can be applied. Only the final restore uses `RECOVERY`, which
rolls back uncommitted transactions and brings the database online. Using
`RECOVERY` one step early ends the chain and makes every remaining log unusable —
which is why the drill asserts `RESTORING` after steps 1 and 2 rather than
trusting them.

A second capture (`03-verify-suite.log`) reproduces it on a different timeline:
A at 03:56:11.727, target at 03:56:16.115, B at 03:56:19.536, 3584 ms end to end,
same marker outcome.

### 5.7 The suite

`03-verify-suite.log`:

| Check | Result |
|---|---|
| 0. Bring up, schema and seed (idempotent) | PASS |
| 1. Schema and data inventory | PASS |
| 2. SQL Server Agent availability | PASS |
| 3. Backup tiers, verification, retention | PASS |
| 4. DRILL: destroy and restore round trip | PASS |
| 5. DRILL: point-in-time recovery | PASS |
| | **ALL 6 CHECKS PASSED** |

---

## 6. What the measurements revealed

### 6.1 Compression is doing real work, and the ratio varies by tier

8.2× on the full backup, 9.4× on the differential, 5.0× on the log
(`03-backup-tiers.log`). The differential compresses best and the log worst,
which follows from what each contains: a differential is a set of changed data
pages carrying the same repetitive row structure the full backup carries, while a
log backup is a stream of log records with far less internal repetition.

`WITH COMPRESSION` consumes CPU while the backup runs and repays it during the
restore by reading far fewer bytes off disk. For anything that is not already
compressed at rest, it is worth having on by default.

Two numbers describe the same full backup and are not interchangeable. `msdb`
records 544.7 KB of compressed backup data; `stat` on the file reports 573,440
bytes. The first is what the engine wrote as backup content, the second is the
file on the volume. Quote the one that matches the question being asked — volume
capacity planning wants the file size.

### 6.2 The size asymmetry is what makes tiering worthwhile

In the same capture: full 4440.0 KB, differential 920.0 KB, log 1296.0 KB
uncompressed. The differential is about a fifth of the full backup. That ratio is
the entire argument for the middle tier — it is cheap enough to take every 15
minutes and it collapses the log replay a restore has to perform down to the logs
written after it.

The scheduled-interval capture in section 5.4 sharpens the point: the scheduler's
routine log backups are 80.0 KB each, compressing to between 8.7 and 15.3 KB.
Taking one every five minutes is nearly free. Taking a *full* backup every five
minutes for the same RPO would write 4440 KB each time, on a database of 1150
rows — and that multiplier does not improve as the database grows.

### 6.3 A green check that compares two error messages proves nothing

This is the most instructive thing that happened in this task.

The restore drill reported `[PASS] fingerprints are IDENTICAL`. They were
identical. Both of them were the string `Changed database context to 'AppDb'.`

`sqlcmd` prints that banner on stdout, before the result set, whenever a batch
contains `USE AppDb;`. It is visible in `03-schema.log` above nearly every
result set in the file:

```
--- tables, with row counts and storage ---
Changed database context to 'AppDb'.
table                          row_count   size_mb
```

The value-capture helper took the first non-blank line of output. Every captured
value was therefore that banner — every row count, every fingerprint, every
foreign key count. And a comparison of two identical banners passes. The drill
was green while measuring nothing at all.

What gave it away was reading the drill's own output: the row counts printed as
`Changed database context to 'AppDb'.` in the same block that reported them.

`sqlv()` in `scripts/lib.sh` now filters the banner explicitly, along with
`Changed language setting` and `rows affected`, and the comment above it says
why:

```
# The filtering is not cosmetic. A query containing `USE AppDb;` makes sqlcmd
# print "Changed database context to 'AppDb'." on stdout BEFORE the result set.
# Unfiltered, THAT is what gets captured, and every later comparison compares
# two identical copies of the same message - which reads as a PASS while
# proving nothing whatsoever.
```

The generalizable lesson is about test design, not about sqlcmd. **A comparison
assertion needs a demonstration that it can fail.** The drill compares a
fingerprint before damage with one after restore, and between those two moments
it now *proves the damage landed* — order_items 750 → 0, orders 300 → 0, foreign
keys 3 → 2, `dbo.products` gone. Those intermediate assertions are what make the
final equality meaningful: the fingerprint is shown to differ when the data
differs, so its matching afterward is information rather than an artifact of a
constant.

A red check invites investigation. A green check that proves nothing is worse,
because nothing ever prompts you to look at it again.

### 6.4 Foreign key ordering makes `DROP TABLE` a two-statement operation

The damage batch originally deleted rows and dropped `dbo.products` in one go.
The `DROP TABLE` failed — `order_items` still held `FK_items_product` referencing
it — but the batch carried on, the deletes succeeded, and the drill went ahead to
"restore" a table that had never gone away. The `products` row count came back
correct for the least interesting reason: it had never changed.

The damage step now drops the referencing constraint first:

```sql
ALTER TABLE dbo.order_items DROP CONSTRAINT FK_items_product;
DROP TABLE dbo.products;
```

and the drill asserts the foreign key count actually falls from 3 to 2 before it
restores anything (`03-restore-roundtrip.log`: `foreign keys now : 2 (was 3)`).

Two things are worth carrying away. First, the schema-level ordering itself:
SQL Server will not drop a table that a foreign key still points at, and a
multi-statement batch does not stop at the first error, so the failure is easy to
walk straight past. Second — and this is the same lesson as 6.3 arriving from a
different direction — **a drill that does not verify its own setup is testing the
setup, not the thing.** Damage has to be proven before recovery can mean
anything.

### 6.5 A healthcheck cannot see what an entrypoint exported

The first bring-up failed with `Login failed for user 'sa'` repeating every five
seconds against an engine that was, in fact, perfectly healthy. Logging in by
hand using the secret file worked immediately, which is what isolated it.

The cause falls directly out of the secrets design in 2.6. The entrypoint exports
`MSSQL_SA_PASSWORD` into the `sqlservr` process it `exec`s. A healthcheck is a
*separate* process, started by the daemon, which inherits the container's
**configured** environment — where that variable is deliberately absent, and
therefore empty. The healthcheck was authenticating with an empty password.

The healthcheck in `mssql/Dockerfile` now reads the secret file directly:

```
CMD /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$(cat /run/secrets/mssql_sa_password)" ...
```

The general shape is worth remembering: **any `docker exec`-based tooling around
a secret-injecting entrypoint has this same blind spot.** Healthchecks, `docker
exec` debugging, sidecars that shell into the main container — none of them see
what the entrypoint exported, and all of them need their own path to the secret.
The drill harness in `scripts/lib.sh` reads the secret file on the host for the
same reason.

### 6.6 `STOPAT` is interpreted in the server's time zone

The host runs UTC+03 and the container runs UTC. Reading the recovery target from
the host clock would produce a `STOPAT` value three hours ahead of any log record
in the chain, and the restore would recover everything and report success — a
point-in-time restore that silently degraded into an ordinary one.

`server_now()` reads `SYSDATETIME()` from the engine, formatted with
`CONVERT(VARCHAR(23), …, 126)`. The three-hour offset is visible across the
evidence: `03-point-in-time.log` has a host header timestamp of
`2026-08-26 00:01:29 +0300` and marker times of `2026-08-25T21:01:31.203`.

The same offset explains why `msdb.dbo.backupset` finish times in section 5.4 sit
three hours behind the log header. Naming the clock a timestamp belongs to is
not pedantry here — it is the difference between a recovery target that lands
where you meant it to and one that lands past the end of the chain.

### 6.7 Agent availability is worth probing rather than repeating

The received wisdom is that SQL Server Agent is unavailable in Linux containers.
On this image it is present, Running, and startup type Automatic
(`03-agent-availability.log`). The claim is not merely imprecise, it is backwards
for the Developer image: Agent ships **disabled**, and one environment variable
plus a restart turns it on.

The measurement did not change the architecture — the reasons in section 2.4 hold
either way — but it changed the sentence I get to write about it. "The sidecar is
used because Agent is unavailable" would have been false. "The sidecar is used
because the schedule should live in version control rather than in `msdb`" is
true, and it is a better reason.

The pattern generalizes: an architectural decision defended by a claim about the
environment should be defended by a *probe* of the environment. The probe is
eight lines of shell and it either confirms the folklore or it saves you from
publishing it.

### 6.8 `RESTORE VERIFYONLY` and `WITH CHECKSUM` are two halves of one guarantee

`WITH CHECKSUM` computes and stores checksums as the backup is written, and
validates the page checksums that `PAGE_VERIFY CHECKSUM` already put on the data
pages. `RESTORE VERIFYONLY ... WITH CHECKSUM` reads the finished file back and
validates it. Neither alone is sufficient: checksums written and never read back
are a claim about a file nobody has opened, and a verify without checksums has
much less to check against.

Across every backup this task produced, `msdb` reports **0 backups without
checksums** (`03-backup-tiers.log`). `backup.sh` treats a `VERIFYONLY` failure as
fatal and removes the target file, because a backup file that cannot be verified
is worse than no file — it looks like a recovery option right up until the moment
it is needed.

---

## 7. Running it yourself

Prerequisites: Docker Desktop with the Linux engine, and bash (Git Bash on
Windows). Nothing else — sqlcmd runs inside the container.

```bash
cd 03-mssql

# Bring up the engine, create AppDb, apply the schema, seed it.
# Idempotent: safe to run repeatedly.
./scripts/up.sh

# Every check and both restore drills.
./scripts/verify.sh

# Non-destructive checks only.
./scripts/verify.sh --quick
```

Individual pieces:

```bash
./scripts/checks/schema-report.sh        # inventory + constraint enforcement
./scripts/checks/agent-availability.sh   # probe SQL Server Agent
./scripts/drills/03-backup-tiers.sh      # three tiers, verify, retention, SIMPLE failure
./scripts/drills/01-restore-roundtrip.sh # destroy and restore, fingerprint comparison
./scripts/drills/02-point-in-time.sh     # STOPAT recovery between two committed rows
```

Watching the scheduler work is the one thing that needs patience rather than a
command. With the default intervals, a log backup lands every 300 seconds:

```bash
docker compose logs -f --tail=50 backup
```

An interactive session:

```bash
docker exec -it task03-mssql /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "$(cat secrets/mssql_sa_password.txt)" -C
```

The `-C` is mandatory. `mssql-tools18` encrypts by default and validates the
server certificate, which is self-signed here.

Tearing down:

```bash
docker compose down       # stops containers, KEEPS the data and backup volumes
docker compose down -v    # also destroys both volumes
```

A `Makefile` mirrors these targets. `make` is not installed on the host this was
built on, so the shell scripts are the tested interface and the Makefile is a
convenience.

To capture evidence the way this repository does it, wrap any of the above in
`scripts/run-with-evidence.sh`, which records the command, working directory,
timestamp and full output into `docs/evidence/`.
