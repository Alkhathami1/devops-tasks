# Task 03 — SQL Server 2022: database, automated backups, restore and PITR

> SQL Server 2022 self-hosted in Docker, pinned by tag and digest. A schema of
> four related tables with constraints proven by negative tests, three backup
> tiers each verified with `RESTORE VERIFYONLY`, a full restore round trip
> returning a byte-identical fingerprint, and a point-in-time recovery landing
> between two committed transactions. Full detail in `WALKTHROUGH.md`; evidence
> in `../docs/evidence/03-*.log`.

## What is here

| Path | Purpose |
|---|---|
| `compose.yaml` | SQL Server 2022 + backup sidecar, digest-pinned |
| `mssql/entrypoint.sh` | Reads the SA password from a Docker secret; validates complexity |
| `sql/01-create-database.sql` | Creates `AppDb`, sets FULL recovery and CHECKSUM page verify |
| `sql/02-schema.sql` | Four related tables, foreign keys, indexes, check constraints |
| `sql/03-seed.sql` | ~60 customers, 40 products, 300 orders, ~750 order lines |
| `sql/90-state.sql` | Deterministic fingerprint used to prove a restore is exact |
| `backup/scheduler.sh` | The automated schedule (full / differential / log) |
| `backup/backup.sh` | Takes one backup of a tier, then `RESTORE VERIFYONLY` |
| `backup/retention.sh` | Per-tier retention so backups do not grow unbounded |
| `scripts/drills/01-restore-roundtrip.sh` | Destroy data, restore, compare fingerprints |
| `scripts/drills/02-point-in-time.sh` | `STOPAT` recovery between two committed rows |
| `scripts/drills/03-backup-tiers.sh` | The three tiers, verification, retention, SIMPLE-mode failure |
| `scripts/checks/agent-availability.sh` | Probes whether SQL Server Agent is really available |

## Running it

```bash
./scripts/up.sh        # engine up, database created, schema applied, seeded
./scripts/verify.sh    # every check and both restore drills
./scripts/verify.sh --quick   # non-destructive only
```

A `Makefile` mirrors these targets, but **`make` is not installed on this host**,
so the shell scripts are the tested interface.

## Schema

```
customers ──< orders ──< order_items >── products
```

Four tables with foreign keys (`NO ACTION` from orders to customers so history
cannot be silently destroyed; `CASCADE` from order_items to orders because a
line has no meaning without its order), unique constraints on `email` and `sku`,
check constraints on price, quantity and status, and non-clustered indexes on
every foreign key column — SQL Server indexes primary and unique keys
automatically but **not** foreign keys.

## Backup strategy

Three tiers, each with a different job:

| Tier | Default interval | Retention | What it costs to restore |
|---|---|---|---|
| Full | 1 h | 24 h | One file, longest to write |
| Differential | 15 min | 6 h | Full + one differential |
| Transaction log | 5 min | 2 h | Full + differential + every log since |

Every backup is written `WITH CHECKSUM` and then validated with
`RESTORE VERIFYONLY`. A backup that has never been verified is an assumption,
not a recovery plan.

`AppDb` is set to **FULL** recovery model, which is what makes log backups and
point-in-time recovery possible at all. Under SIMPLE recovery `BACKUP LOG`
fails with Msg 4208 — drill 3 demonstrates that failure deliberately rather
than asserting it.

## Secrets

The SA password is a file-based Docker secret, following Task 02's pattern.

**The honest tension:** unlike the Postgres image, the SQL Server image has no
`_FILE` convention — `sqlservr` reads `MSSQL_SA_PASSWORD` from the environment
and there is no supported alternative. The mitigation is `mssql/entrypoint.sh`,
which reads the secret file and exports the value only into the process it
execs. The consequence:

- the password does **not** appear in `docker inspect`, because nothing is set
  via compose `environment:` — that is where it would otherwise be readable by
  anyone with Docker socket access, for the life of the container
- a new process in the container sees `MSSQL_SA_PASSWORD` as **empty**
  (length 0), because the export applies only to the exec'd process
- `/proc/1/environ` is **`-r-------- root root` and unreadable even as uid 0**:
  SQL Server marks itself non-dumpable, which reassigns the proc file to root
  and requires `CAP_SYS_PTRACE`, which the container does not hold

Measured, not assumed — an earlier draft of this file claimed root could read
the value from `/proc/1/environ`, and testing disproved it.

One consequence worth knowing: because the variable is absent from the
container's configured environment, a **healthcheck cannot see it either**. The
healthcheck reads the secret file directly; using `$MSSQL_SA_PASSWORD` there
produces `Login failed for user 'sa'` against a perfectly healthy engine.

The backup sidecar has no such constraint and reads the secret file directly.

## Known environment gotchas handled here

- **2 GB RAM floor.** SQL Server refuses to start below it. `MSSQL_MEMORY_LIMIT_MB`
  is 2048 against a 3 GiB container limit, leaving headroom above the buffer pool.
- **Named volume, not a bind mount.** The container runs as `mssql` (uid 10001)
  and must own `/var/opt/mssql`. A Windows bind mount cannot express that
  ownership and the engine fails at startup.
- **Password complexity.** A weak SA password makes the container exit with a
  single log line. `entrypoint.sh` validates length and category count first and
  fails with a readable message.
- **sqlcmd moved.** It is `/opt/mssql-tools18/bin/sqlcmd` in 2022 images, and
  tools18 encrypts by default — every command needs `-C` or fails with a
  certificate error.
- **Healthchecks.** A port probe reports healthy while the engine still cannot
  answer a query. The healthcheck runs a real `SELECT 1`.
