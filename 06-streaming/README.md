# Task 06 — OBS/vMix to AWS Elemental MediaLive, HEVC to S3

> Local HEVC encodes measured with ffprobe and a bits-per-pixel analysis, then a
> MediaLive channel run end to end: HEVC at 12 Mbps encoded in AWS, archived to
> S3 as `.ts`, and a segment pulled back and probed to confirm it. Destroyed
> afterwards and the account verified clean per resource class. Full detail in
> `WALKTHROUGH.md`; evidence in `../docs/evidence/06-*.log`.

## Requirements and where each is met

| Requirement | Where | Delivered |
|---|---|---|
| ≥ Full HD | `scripts/encode.sh` | 1920x1080 measured |
| ≥ 12 Mbps video | `scripts/encode.sh` | 12,652,330 bps measured |
| ≥ 192 kbps audio | `scripts/encode.sh` | 194,205 bps measured |
| HEVC | `scripts/encode.sh` | `hevc (Main)` measured |
| BPP justification | `scripts/analysis.sh` | 0.0965 bpp, computed |
| Record to S3 as .ts/.mxf | `terraform/` | 13 .ts segments, ffprobe-verified |
| Document every step | this file + report §8 | |

## Phase 1 — run it

```bash
./scripts/encode.sh     # HEVC 1080p60 12 Mbps, then measure it with ffprobe
./scripts/analysis.sh   # BPP table, VMAF comparison, containers, RTMP test
```

Source is synthetic (`testsrc2` + `sine`), so this is reproducible from a clone
with no media assets.

## Phase 2 — AWS

```bash
cd terraform && terraform init && terraform validate && terraform plan
terraform apply                     # creates the channel; does NOT start it
../scripts/channel.sh start         # <-- the running clock starts HERE
../scripts/push-feed.sh 90          # or push the Phase 1 file instead of OBS
../scripts/verify-archive.sh        # list, download and ffprobe a segment
../scripts/channel.sh stop          # <-- back to IDLE
terraform destroy
../scripts/teardown-check.sh        # confirm nothing remains or is running
```

**A MediaLive channel transcodes while RUNNING whether or not anything is
pushed to its input**, so creating it and running it are separate decisions:
`terraform apply` deliberately does not start it. `scripts/channel.sh` prints
the elapsed running time on every invocation, and `scripts/teardown-check.sh`
verifies afterwards, per resource class, that nothing is left running.

## Key findings from Phase 1

**BPP.** 12 Mbps at 1080p60 = **0.0965 bpp**, mid-band for the 0.05–0.15 range
where live HEVC lives. The same 12 Mbps at 4K60 is 0.0241 bpp — a quarter the
value and unusable, which is exactly why a bitrate figure means nothing without
the resolution and frame rate attached.

**HEVC did not beat H.264 at 12 Mbps.** VMAF 74.64 vs 75.09 — HEVC *lower* by
0.45. At 3 Mbps the direction flips: 69.98 vs 69.02, HEVC ahead by 0.95. The
textbook "HEVC is 40% more efficient" claim does not reproduce at a generous
bitrate on synthetic content, and reporting it would have been reporting
something that did not happen.

**RTMP carried HEVC fine.** The expectation was a mux failure. This ffmpeg
implements Enhanced RTMP (2023), which adds HEVC to FLV via a FourCC
extension, and the mux succeeded. The real constraint is the *receiver*:
MediaLive's RTMP_PUSH input expects H.264. So OBS contributes H.264 over RTMP
and the channel encodes HEVC into the archive, which puts the codec requirement
where it belongs — in the `.ts` segments — justified by what MediaLive accepts
rather than by a container constraint this test disproved.

**MXF genuinely rejected HEVC:** `could not find essence container ul, codec not
currently supported in container`. MPEG-TS is chosen for the archive on
segmentability and error resilience.

## Secrets

The repository is public. No credential, account id or ARN appears in any file
or evidence log. `../scripts/redact.sh` filters anything account-identifying on the
way into a log, and `../scripts/audit.sh` fails the build on credential-shaped
content.
