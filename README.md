# Infrastructure Engineer Assignment

Six infrastructure tasks, each built and then run against a real runtime.

**Start with [`REPORT.pdf`](REPORT.pdf)** — 20 pages (19 numbered folios plus
an unnumbered cover), about 20 minutes. Also
available as [`REPORT.docx`](REPORT.docx).

**Depth per task** lives in that task's `WALKTHROUGH.md`: the full reasoning,
the complete steps, the extended findings.

**What the Task 6 feed actually carried** is measured rather than assumed.
`docs/evidence/06-picture-check.log` records that OBS's screen capture produced
no image, so the archive MediaLive wrote is valid HEVC carrying a black picture.
The pipeline is demonstrated; the picture is not.

**Re-run anything** with [`REPRODUCING.md`](REPRODUCING.md) — one block to bring
each task up, one to verify it, with the expected output named.

**How the work was reviewed** is in [`docs/METHOD.md`](docs/METHOD.md) and the
seven briefs in [`.claude/agents/`](.claude/agents/), which are written to be
read on their own.

**Verify any claim** from the evidence index in the report against the logs in
`docs/evidence/`, or run `bash scripts/audit.sh` to check the repository against
itself.

| Path | Contents |
|---|---|
| `01-storage-mounts/` | SMB3 mounts both directions, XFS, monitoring and alerting |
| `02-docker-stack/` | Postgres, backend and nginx on isolated networks, with failure drills |
| `03-mssql/` | SQL Server schema, tiered backups, point-in-time restore |
| `04-nodered-s3/` | S3 multipart copy engine and Node-RED flow |
| `05-terraform-ansible/` | Three-tier GCP network in Terraform, configured by Ansible |
| `06-streaming/` | HEVC encoding, BPP analysis, MediaLive channel and S3 archive |
| `docs/` | The report, traceability, method, and the evidence logs |
| `scripts/` | Evidence capture, redaction, repository auditor, document builders |
