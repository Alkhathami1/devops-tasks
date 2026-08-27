# Reproducing this work

Every task brings itself up from nothing and verifies itself. Each block below
is copy-paste, run from the repository root.

## Prerequisites

| Tool | Used by | Notes |
|---|---|---|
| Docker Desktop with the WSL2 backend | Tasks 1–4 | Tasks 1 and 3 need about 4 GB free for the containers |
| Node.js 20 or newer | Task 4 | |
| Terraform | Tasks 5–6 | |
| ffmpeg and ffprobe with libx265 and libvmaf | Task 6 | |
| `gcloud`, authenticated | Task 5 | |
| AWS CLI v2, configured | Task 6 | |
| An elevated PowerShell, once | Task 1 | To create the Windows share |

Every verification writes to `docs/evidence/` through
`scripts/run-with-evidence.sh`, which records the command, the timestamp and the
full output. Run `bash scripts/audit.sh` at any point to check the repository
against itself.

---

## Task 1 — Cross-platform volume mounting

The Windows share is created once, from an elevated PowerShell:

```powershell
cd 01-storage-mounts\windows
.\setup-share.ps1
```

Then bring the Linux side up and verify:

```bash
cd 01-storage-mounts
bash scripts/up.sh
bash scripts/verify.sh
```

**Expect:** `RESULT: 8 checks, 0 failures`, with the summary showing the XFS
capability, SMB3 mount mechanics, Direction A, persistence, monitoring, alerting
and the Direction B server. The alerting stage takes about two minutes because
it fills a filesystem and waits for three alert rules to transition.

Individual stages run on their own: `scripts/xfs-demo.sh`,
`scripts/direction-a.sh`, `scripts/monitoring.sh`, `scripts/alerts-fire.sh`.

Tear down with `docker compose down`.

---

## Task 2 — Containerized multi-tier application

```bash
cd 02-docker-stack
bash scripts/up.sh
bash scripts/verify.sh
```

**Expect:** the stack healthy, 19 network-isolation checks passing including
nginx unable to resolve `postgres`, and the five failure drills each reporting
their result — `OOMKilled=true` with exit 137 for the memory drill, and a
recovered backend for the crash drill.

The drills also run individually:

```bash
bash scripts/drills/01-backend-kill.sh
bash scripts/drills/02-oom-kill.sh
bash scripts/drills/03-persistence.sh
bash scripts/drills/04-db-failure.sh
bash scripts/drills/05-secrets-comparison.sh
bash scripts/drills/06-daemon-restart.sh    # restarts the Docker daemon
```

Tear down with `docker compose down`, or `docker compose down -v` to remove the
database volume as well.

---

## Task 3 — SQL Server administration

```bash
cd 03-mssql
bash scripts/up.sh
bash scripts/verify.sh
```

**Expect:** SQL Server healthy on 1433, the schema report showing four tables
with constraints proven by negative tests, all three backup tiers taken and
verified, a restore round trip returning a byte-identical fingerprint, and a
point-in-time recovery reporting marker A present and marker B absent.

The first run pulls a large image. `up.sh` is idempotent and safe to re-run.

Tear down with `docker compose down -v`.

---

## Task 4 — S3 multipart copy through Node-RED

The suites run against `moto`, a local S3-compatible server, so no cloud account
is involved:

```bash
cd 04-nodered-s3
npm ci
docker run -d --name moto -p 5000:5000 motoserver/moto:latest
npm run test:unit
npm run test:integration
```

**Expect:** 19 of 19 unit tests and 9 of 9 integration tests. The integration
suite creates its buckets, copies an object with `UploadPartCopy`, and asserts
the destination ETag carries a `-5` suffix against a single-PUT source.

To drive the copy through Node-RED itself:

```bash
npm run node-red        # then import flows/flows.json and trigger the inject node
node scripts/bucket-state.js
```

`bucket-state.js` resolves to the local endpoint unless `S3_ENDPOINT=aws` is set
explicitly, and prints the resolved target before doing anything.

Tear down with `docker rm -f moto`.

---

## Task 5 — Three-tier infrastructure as code

Creates cloud resources. Teardown is scripted and verified.

```bash
cd 05-terraform-ansible
bash scripts/keygen.sh
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # set project_id
bash scripts/plan.sh
```

**Expect:** `Plan: 32 to add, 0 to change, 0 to destroy.`

Then apply, configure and verify:

```bash
cd terraform && terraform apply tfplan.binary && cd ..
bash scripts/ansible-run.sh
bash scripts/verify.sh
```

**Expect:** 17 of 17 architecture checks, including a row written through nginx
to the app to the database and read back, and confirmation that no route to the
database range exists in the public VPC. A second `ansible-run.sh` reports
`changed=0` on all four hosts.

Tear down and confirm nothing is left running:

```bash
cd terraform && terraform destroy && cd ..
bash scripts/orphan-check.sh
```

**Expect:** `RESULT: PROJECT CLEAN - nothing left behind, nothing left running`,
checked per resource class against GCP's own listings.

---

## Task 6 — HEVC contribution and MediaLive archive

The local half needs no cloud account:

```bash
cd 06-streaming
bash scripts/encode.sh
bash scripts/analysis.sh
```

**Expect:** a 1080p60 HEVC encode measured by ffprobe at about 12.65 Mbps
overall with a 2.00 s GOP, then the bits-per-pixel table across four resolutions
and six bitrates, and a VMAF comparison against H.264 at two bitrates.

The AWS half creates cloud resources. Teardown is scripted and verified.

```bash
cd terraform && terraform init && terraform plan -out=tfplan.binary
terraform apply tfplan.binary && cd ..
bash scripts/channel.sh start
bash scripts/push-feed.sh
bash scripts/verify-archive.sh
bash scripts/channel.sh stop
```

**Expect:** the channel reaching `RUNNING`, `.ts` segments appearing in S3, and
`verify-archive.sh` pulling one back and reporting `hevc (Main)` with stream
type `0x24` at 1920x1080 and AAC at 192 kb/s.

`channel.sh` prints the elapsed running time on every invocation, and
`terraform apply` deliberately does not start the channel — creating it and
running it are separate decisions.

Tear down and confirm nothing is left running:

```bash
cd terraform && terraform destroy && cd ..
bash scripts/teardown-check.sh
```

**Expect:** `RESULT: CLEAN — nothing remains, nothing left running`, checked per
resource class against the AWS APIs.

---

## Rebuilding the deliverables

```bash
python scripts/build-pdf.py       # -> REPORT.pdf
python scripts/build-docx.py      # -> REPORT.docx
python scripts/verify-pdf.py      # fonts, sizes, pagination, margins, length
bash scripts/audit.sh             # the repository against itself
```
