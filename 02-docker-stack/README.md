# Task 02 — Integrated multi-container system on private Docker networks

Three tiers on **two** Docker networks, with only the reverse proxy exposed to
the host.

```
host :8080 ──► nginx + frontend ──edge-net──► backend API ──internal-net──► postgres
                     ▲                                                          ▲
            the only published port                     internal: true — no route to
                                                        or from the host at all
```

## Quick start

> `make` is not installed on the development host, so the Makefile targets are
> unexecuted wrappers. The tested interface is the scripts they call:
> `./scripts/up.sh` and `./scripts/verify.sh`.

```bash
make up        # bring the whole stack up from nothing (idempotent)
make verify    # run every check and every failure drill
make quick     # non-destructive checks only
make down      # stop, KEEPING data
make destroy   # stop and DESTROY the data volume
```

`make up` generates `.env` from `.env.example` and a random database password on
first run, builds both images, and blocks until all three services are healthy.
Re-running changes nothing.

## Services

| Service | Image | Networks | Published | Limits |
|---|---|---|---|---|
| `postgres` | `postgres:16` (digest-pinned) | internal-net | none | 1.00 CPU / 512 MiB |
| `backend` | built from `backend/` | edge-net + internal-net | none | 0.75 CPU / 256 MiB |
| `nginx` | built from `nginx/` | edge-net | **8080** | 0.50 CPU / 128 MiB |

The backend is the only container on both networks: it is the sole path between
the edge and the data tier.

## API

| Route | Purpose |
|---|---|
| `GET /` | Static frontend, served by nginx |
| `GET /api/items` | List rows (proxied to the backend) |
| `POST /api/items` | Insert a row (proxied) |
| `GET /api-health` | Backend health, proxied; 503 when the DB is unreachable |
| `GET /healthz` | nginx's own liveness, independent of the backend |

`/internal/*` on the backend is deliberately **not** proxied, so the chaos
endpoints used by the drills cannot be reached from the host.

## Secrets

Both mechanisms are used, for different classes of data:

- **Database password** — a file-based Docker secret at
  `/run/secrets/postgres_password`. Never in the environment, so it does not
  appear in `docker inspect`.
- **Everything else** — `.env` (database name, role, pool size, host port).
  Committed as `.env.example`; the real `.env` is gitignored.

`./scripts/drills/05-secrets-comparison.sh` (target: `make secrets`)
demonstrates the difference side by side: a password passed via `-e` is
plainly visible in `docker inspect`, the file-based secret is not.

## Failure drills

Run the scripts directly — these are what were executed. The `make` targets
in the second column are unexecuted wrappers, as noted under Quick start.

| Script | `make` target | Scenario |
|---|---|---|
| `./scripts/drills/01-backend-kill.sh` | `drill-crash` | SIGKILL vs a genuine crash; restart policy and downtime |
| `./scripts/drills/02-oom-kill.sh` | `drill-oom` | RAM exhaustion until the cgroup OOM-kills PID 1 |
| `./scripts/drills/06-daemon-restart.sh` | `drill-daemon` | Docker daemon restart — machine-shutdown analogue |
| `./scripts/drills/03-persistence.sh` | `drill-persist` | `down` preserves data; `down -v` destroys it |
| `./scripts/drills/04-db-failure.sh` | `drill-db` | Database killed under a live backend |

Every drill writes evidence to `../docs/evidence/02-*.log` when run through
`../scripts/run-with-evidence.sh`. Results and analysis are in section 4 of
`../docs/REPORT.md`.

## Notes for Windows

All scripts export `MSYS_NO_PATHCONV=1`. Without it Git Bash rewrites
container-side absolute paths such as `/run/secrets/postgres_password` into
Windows paths before handing them to `docker.exe`.
