# Working brief

Six infrastructure tasks, each built and then run against a real runtime. The
deliverables are the working code for every task, the evidence that it ran, and
one report that explains the decisions.

| Directory | Task |
|---|---|
| `01-storage-mounts/` | Windows and Linux volume mounting over SMB, XFS for large single files, monitoring and alerting |
| `02-docker-stack/` | A multi-tier application on private Docker networks, with failure recovery and resource allocation |
| `03-mssql/` | SQL Server: schema, automated backups, restore and point-in-time recovery |
| `04-nodered-s3/` | An S3 multipart copy driven from Node-RED |
| `05-terraform-ansible/` | Three networks in a three-tier architecture, built with Terraform and configured by Ansible |
| `06-streaming/` | An HEVC contribution pipeline archived to S3 from AWS Elemental MediaLive |

## Working conventions

**Evidence is captured before prose is written.** Every verification run goes
through `scripts/run-with-evidence.sh`, which records the command, the
timestamp and the full output to `docs/evidence/<task>-<what>.log`, and pipes
the result through `scripts/redact.sh` so redaction belongs to the capture path
rather than to whoever remembers it. A figure that is not in a log does not go
in a document. Where something was performed in part, the part that was
performed is described precisely.

**A log is never edited.** Selecting which logs ship is curation; changing what
one says is not. When output needs to read differently, the script is changed
and re-run.

**Assertions are shown to fail.** A passing check is mutated — the value
changed, the dependency removed, the behavior reverted — until it goes red for
the right reason, then restored. A check that stays green under mutation is
reported rather than trusted.

**Measurements name their layer.** A cached read and a cold read are both real
and answer different questions, as are an engine's own duration and the wall
time around it. Every figure is bounded against something physical or
documented before it is believed.

**Secrets are scanned by content signature, across the full history.** Filename
rules miss a private key written without an extension. Anything that reads like
a placeholder is verified against the real value rather than judged by how it
reads.

**Cloud resources are torn down, and the teardown is verified per resource
class against the provider's own listings** rather than against the tool that
created them, because a destroy command knows only what is in its own state.

**Irreversible steps pass a human gate** — creating cloud resources,
publishing, rewriting history.

**Secrets never enter the repository.** `.env.example` files carry
placeholders; real secrets are generated locally and ignored. Docker file-based
secrets are preferred over environment variables where the runtime supports it,
because `docker inspect` prints an environment variable to anyone who can reach
the socket.

**Scripts are safe to re-run.** Ansible playbooks converge to `changed=0` on a
second run.

**Commits are conventional and single-purpose**, for example
`feat(04): multipart copy flow`.

## Where the rest is

`docs/METHOD.md` describes how the work was reviewed. `.claude/agents/` holds
the seven reviewer briefs — Faris, Adel, Amin, Hasib, Ghareeb, Rawi and Fahim —
each written to be read on its own. `docs/REPORT.md` is the source of
`REPORT.pdf`, and each task directory carries a `WALKTHROUGH.md` with the full
reasoning. `REPRODUCING.md` gives one block per task to bring it up and one to
verify it.
