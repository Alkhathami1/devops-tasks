# Task 06 — HEVC contribution to AWS Elemental MediaLive, archived to S3

A walkthrough of the encoder decisions, the pipeline that was built and run, the
numbers it produced, and what those numbers turned out to mean. The report
carries the summary; this document carries the reasoning, the arithmetic, and
the findings in full.

---

## 1. What this task required, and how I read it

The requirement, in the requester's words:

> Stream from **OBS or vMix** into **AWS Elemental**, and:
>
> **6.1** "at least Full HD"
>
> **6.2** "at least 12 Mbps video and 192 kbps audio"
>
> **6.3** "optionally justify a different bitrate with an explicit BPP formula"
>
> **6.4** "HEVC codec"
>
> **6.5** "record the stream to S3 as .mxf or .ts"
>
> **6.6** "document every step"

Four readings shaped the build.

**There are two encoders in this chain, and the codec requirement lands on the
second.** OBS Studio produces the contribution feed that travels to AWS;
MediaLive's own encoder produces the archive. Both run at 1920x1080, 60 fps and
12 Mbps CBR. OBS contributes H.264, because MediaLive's RTMP input expects
H.264, and the channel encodes HEVC into the ARCHIVE output group — so the `.ts`
segments that land in S3, which is what the task asks to record, are HEVC.
Section 2.8 works through why the transport decides that split. A third encode,
libx265 driven by ffmpeg on a synthetic source, is the local measurement bench
in Phase 1: the same operating point, probed field by field, reproducible from a
clone.

**"At least" makes these floors, and a floor has to be measured on the
artifact.** Asking ffmpeg for `-b:v 12M` and then reporting 12 Mbps proves the
argument was typed correctly. Every figure in section 5 comes from ffprobe run
against a produced file, or from a byte count divided by a probed duration.

**The BPP clause is the instrument, not a footnote.** Bits per pixel normalizes
a bitrate against how much picture is being produced per second, which is the
only way to say whether 12 Mbps is generous or starved. I read 6.3 as an
invitation to compute the whole surface — several resolutions, several frame
rates, several bitrates — rather than to compute the one number the requirement
already names.

**"Document every step" includes the encoder a human would otherwise click
through.** OBS was configured from files rather than from its interface:
`scripts/obs-configure.sh` installs a profile and a scene collection where OBS
reads them, and `scripts/obs-evidence.sh` prints those same files back and then
quotes what OBS logged while it ran. The encoder settings this document
describes are the settings OBS read off disk.

---

## 2. Design decisions

### 2.1 12 Mbps at 1080p60, justified by bits per pixel

```
BPP = bitrate / (width × height × fps)

12,000,000 / (1920 × 1080 × 60) = 12,000,000 / 124,416,000 = 0.0965 bpp
```

The working band for live HEVC runs roughly **0.05 – 0.15 bpp**. Below about
0.05 the encoder runs out of bits before it runs out of detail, and motion
blocks up. Above about 0.15 the extra bits buy progressively less visible
improvement while the uplink carries every one of them.

0.0965 bpp sits almost exactly mid-band. That is what makes 12 Mbps a defensible
number here rather than a round one, and the full table in 5.1 is what makes it
checkable.

The rejected alternatives and the reasons: **8 Mbps** (0.0643 bpp), rejected
because it sits under the requirement floor and near the lower edge of the band
where 60 fps content starts to show it; **20 Mbps** (0.1608 bpp), rejected
because it is above the band's upper edge, where the uplink carries every extra
bit while the visible return on it falls off.

### 2.2 HEVC, and measuring what it actually buys

The requirement names HEVC, so HEVC is what the archive carries and what the
local encode produces. That settles the choice and leaves an open question worth
answering: how much does it buy at this operating point?

I encoded the same source at the same bitrate with the same preset through
libx265 and libx264 and scored both against a common reference with VMAF. The
result at 12 Mbps is in 5.3 and it does not match the figure the codec is
usually sold on. Running it at a second, much lower bitrate is what turned a
confusing number into a usable one.

The decision that came out of it: HEVC for this build because the requirement
names it and because MediaLive is configured to produce it, with the efficiency
argument stated where the measurement supports it — at low bits per pixel —
rather than as a blanket claim.

### 2.3 CBR rather than VBR

A contribution uplink has a fixed budget. VBR allocates bits where the content
needs them, which is the right behavior for a file and the wrong behavior for a
link: the peaks overrun the budget, and the transport then drops packets. A
dropped packet takes out more picture than the bits VBR was trying to save.

Local encode: `-b:v 12M -maxrate 12M -bufsize 24M`. The VBV buffer is set to
twice the bitrate, which is two seconds at this rate. A smaller buffer starves
complex scenes; a larger one lets the instantaneous rate drift further above the
link budget before the buffer pulls it back.

MediaLive: `rate_control_mode = "CBR"` with `max_bitrate = var.video_bitrate`
and `buf_size = var.video_bitrate * 2` — the same shape, expressed in the
provider's schema. OBS: `"rate_control": "CBR"` at `"bitrate": 12000` in the
profile's `streamEncoder.json`, printed back in `06-obs.log`.

### 2.4 A fixed 2-second GOP

`keyint=120` with `min-keyint=120` at 60 fps, and `scenecut=0`.

The GOP length sets the minimum granularity at which a downstream archive can
cut a segment, because segments break on IDR frames. Fixing `min-keyint` equal
to `keyint` and turning scene-cut detection off means every GOP is exactly 120
frames, so segment boundaries land where the segmenter expects them. Adaptive
keyframes would insert an IDR mid-GOP at a scene change and produce uneven
segments downstream.

MediaLive matches with `gop_size = 2`, `gop_size_units = "SECONDS"` and
`scene_change_detect = "DISABLED"`, and the ARCHIVE group's `rollover_interval`
is 10 seconds — five whole GOPs.

### 2.5 Main profile, 8-bit 4:2:0

`-pix_fmt yuv420p`, `profile = "MAIN"`, `tier = "MAIN"` on the MediaLive side.

The rejected alternative and the reason: **Main10**, rejected because the source
is 8-bit. Encoding an 8-bit source at 10-bit depth consumes bitrate carrying
precision the source never had, and narrows the set of decoders that will play
the result.

### 2.6 B-frames on, no low-latency tune

`bframes=3` locally; `gop_closed_cadence = 1` on MediaLive.

The rejected alternative and the reason: **`tune=zerolatency`**, rejected
because it disables B-frames and lookahead. Those are the right things to
disable when glass-to-glass latency is the binding constraint — an interactive
stream — and the wrong things to disable for contribution, where the constraint
is the link budget and B-frames are a real compression gain.

### 2.7 MPEG-TS over MXF for the archive

MXF **refused the HEVC stream**, which settles the question by measurement
rather than by argument. From `06-analysis.log`:

```
[mxf @ 00000134f2584b00] track 0: could not find essence container ul,
                         codec not currently supported in container
[out#0/mxf @ 00000134f1b2eb80] Could not write header
                         (incorrect codec parameters ?): Operation not permitted
```

Falling back to MPEG-2 video with PCM audio produced a valid MXF, which
establishes that the muxer works and the refusal is codec-specific rather than a
broken invocation.

Beyond that one result, four properties separate the two containers for this
job:

| Property | MPEG-TS | MXF |
|---|---|---|
| Segmentable | 188-byte packets with periodic PAT/PMT; cuts on any IDR without rewriting an index | wants a complete index |
| Error resilience | each packet independently framed with its own PID; a damaged region loses those packets and the decoder resynchronizes at the next PAT | a damaged header or index can leave the whole file unreadable |
| HEVC | native, stream type `0x24` | the OP1a mappings in common use are built around MPEG-2, DV and JPEG 2000 |
| Live-native | open-ended, no header rewrite on close | a file format, which wants a clean close |

MXF's strengths are real and belong to a different job: rich per-frame metadata,
timecode, and the interchange format post houses expect. For an archive written
continuously by a live encoder and possibly cut off mid-write, TS is the safer
choice — and it is what MediaLive's ARCHIVE output group writes, for the same
reasons.

### 2.8 RTMP_PUSH for the contribution input, and where the codec requirement is met

The deployed input is `RTMP_PUSH`, and the contribution leg is therefore H.264.
OBS speaks RTMP natively from its own Stream output — `scripts/obs-configure.sh`
writes a `service.json` of type `rtmp_custom`, splitting the MediaLive URL into
a server and a stream key — and MediaLive's RTMP input expects H.264. The
channel decodes that feed and encodes HEVC into the ARCHIVE output group, so the
`.ts` segments in S3 are HEVC.

That is the one place to state it plainly: **the codec requirement is met at the
deliverable rather than on the wire.** The task asks to record the stream to S3
in HEVC, and the recorded artifact is HEVC, confirmed by ffprobe on a segment
pulled back out of the bucket (5.8).

The received wisdom is that RTMP cannot carry HEVC. I wrote the test expecting a
mux failure and got the opposite: **the mux succeeded.** From `06-analysis.log`:

```
Stream #0:0: Video: hevc (Main), yuv420p(tv), 1920x1080 [SAR 1:1 DAR 16:9], 60 fps
Stream #0:1: Audio: aac (LC), 48000 Hz, stereo, fltp, 194 kb/s
```

Classic RTMP/FLV carries a 4-bit CodecID with assigned values for Sorenson
H.263, VP6, H.264 (7) and a few others, and no value for HEVC — Adobe stopped
developing the specification in 2012, before HEVC deployment mattered. That is
where the claim comes from, and it was true for years. **Enhanced RTMP (2023)**
adds HEVC, AV1 and VP9 through a FourCC extension, and ffmpeg 8.0.1 implements
it.

So the container is not what decides the transport here. The receiver is:
**MediaLive's RTMP input expects H.264**, a property checkable against the
MediaLive API, where the container claim was checkable against ffmpeg and came
out false. The consequence is the H.264 contribution leg and the HEVC encode
happening inside the channel.

The rejected alternatives and the reasons: **RTP_PUSH**, which carries MPEG-TS
and would carry HEVC end to end as stream type `0x24`, rejected because OBS's
Stream output does not emit RTP-MPEGTS — reaching RTP from OBS means configuring
Custom Output (FFmpeg) instead, which puts ffmpeg back in the encoding path that
the OBS profile was written to own, and the task names OBS as the encoder.
**SRT_CALLER**, MediaLive's SRT input type, in which MediaLive dials out to an
SRT listener the operator runs, rejected because it inverts the direction: an
encoder behind NAT pushes, and a push input is what both RTMP_PUSH and RTP_PUSH
give it. SRT remains the better transport over an unmanaged network, because it
retransmits lost packets within a configurable latency window where RTP over UDP
does not recover them at all and RTMP over TCP stalls head-of-line and backs the
encoder up.

### 2.9 SINGLE_PIPELINE

`channel_class = "SINGLE_PIPELINE"`.

The rejected alternative and the reason: **STANDARD**, which runs two
independent pipelines in separate availability zones so that a pipeline failure
does not interrupt the output. Redundancy is a different property from the one
this build demonstrates, and one encoder with one output path is what the
archive verification reasons about.

### 2.10 S3 configuration

Four resources beyond the bucket itself, each doing one thing:

| Resource | Setting | Why |
|---|---|---|
| `aws_s3_bucket_public_access_block` | all four flags true | an archive bucket has exactly one reader, and this removes the ACL and policy paths that could make it public |
| `aws_s3_bucket_server_side_encryption_configuration` | `AES256` | encryption at rest with no key management to get wrong |
| `aws_s3_bucket_lifecycle_configuration` | `expiration { days = 1 }` | a forgotten segment expires on its own rather than accumulating |
| `force_destroy = true` on the bucket | — | MediaLive writes objects Terraform does not track; without this, destroy fails on a non-empty bucket and leaves it behind |

The bucket name is `${var.name_prefix}-archive-${random_id.suffix.hex}`. A
`random_id` suffix makes it globally unique without embedding the account
identifier, which does not belong in a repository.

### 2.11 IAM scoped to the one bucket

The role MediaLive assumes carries three statements, written as an inline policy
rather than an attached managed policy:

- S3: `PutObject`, `GetObject`, `DeleteObject`, `ListBucket`,
  `GetBucketLocation`, on this bucket's ARN and its object ARNs only.
- CloudWatch Logs: create group, create stream, put events, describe.
- EC2 describe on subnets, network interfaces and security groups — required
  because a push input causes MediaLive to create ENIs to receive the feed.

The rejected alternative and the reason: **the AWS-managed
`MediaLiveFullAccess` policy**, rejected because it grants across every
MediaLive resource and every bucket in the account, where an archive output
needs write access to one prefix.

### 2.12 Creating the channel and running it are separate actions

A MediaLive channel has two states that matter. Created and IDLE, it exists and
transcodes nothing. RUNNING, it transcodes whether or not anything is being
pushed to its input — an idle feed and a live feed put it in exactly the same
state.

So `terraform apply` deliberately stops at creation. `scripts/channel.sh`
carries `start`, `stop`, `status` and `endpoints`, writes a timestamp when the
channel starts, and prints the elapsed running time on every invocation, so the
channel's state is a deliberate and visible thing rather than a side effect of
an apply.

### 2.13 OBS Studio as the contribution encoder, configured from files

OBS Studio 32.2.1 is the contribution encoder, and it was configured
programmatically. OBS keeps a profile as a directory holding `basic.ini`,
`streamEncoder.json` and `recordEncoder.json`, keeps a scene collection as a
single JSON file, and records which of each is active in four keys in
`global.ini` — all under `%APPDATA%\obs-studio`. `scripts/obs-configure.sh`
copies `configs/obs/` into those locations, appends the recording path, writes
the `service.json` naming the MediaLive ingest, and sets the four keys. Nothing
in that path goes through the interface.

The profile, as `06-obs.log` prints it back off disk: 1920x1080 base and output,
`FPSCommon=60`, `ColorFormat=NV12`, `ColorSpace=709`, `ColorRange=Partial`,
`SampleRate=48000` stereo, `Track1Bitrate=192`, advanced output mode with
`Encoder=obs_x264`. The stream encoder JSON carries eight keys, six of them with
values: `"bitrate": 12000`, `"rate_control": "CBR"`, `"keyint_sec": 2`,
`"preset": "medium"`, `"profile": "main"`, `"bf": 3`, with `tune` and `x264opts`
left empty. The scene collection is one scene, `Task06`, on a 1920x1080 canvas
with a single `monitor_capture` source.

Those values are the ones argued for in 2.1 through 2.6, expressed in OBS's own
schema: CBR because a contribution uplink has a fixed budget, a 2-second
keyframe interval because that sets the downstream segment granularity, `main`
profile because the pipeline is 8-bit 4:2:0, three B-frames because this is
contribution rather than interactive.

The stream destination is written at configure time rather than committed,
because it names a live ingest endpoint that exists only while the channel does.

Phase 1 stays on ffmpeg with a synthetic source (`testsrc2` plus `sine`), which
is what makes the encoder measurements, the BPP table and the VMAF comparison
reproducible from a clone: the same commands produce the same artifacts on any
machine with ffmpeg installed, with no capture hardware and no AWS account.

---

## 3. How it is built

### 3.1 The pipeline

```
  OBS Studio 32.2.1  ──  x264 CBR 12000 kbps, 1080p60, 2 s keyframes,
     │                   AAC 192 kbps 48 kHz stereo
     │  RTMP push  (Stream output, rtmp_custom service)
     ▼
  MediaLive input  RTMP_PUSH
     │             guarded by an input security group
     ▼
  MediaLive channel  SINGLE_PIPELINE
     │   decode: H.264 in
     │   video : H265, 12 Mbps, CBR, 2 s GOP, MAIN profile, 1920x1080@60
     │   audio : AAC-LC, 192 kbps, 48 kHz stereo
     │   mux   : M2TS, CBR at 13,192,000 bps
     │
     │  ARCHIVE output group, 10 s rollover, s3ssl://
     ▼
  S3 bucket   SSE-AES256, public access blocks on, 1-day expiry
     │
     ▼
  aws s3 cp  ──  ffprobe on what AWS produced
```

### 3.2 Phase 1 — the local encoder

| File | What it does |
|---|---|
| `scripts/encode.sh` | Builds a lossless FFV1 + PCM reference from `testsrc2` and `sine`, encodes it to HEVC 1080p60 at 12 Mbps in MPEG-TS, then measures the produced file with ffprobe against every requirement floor and counts I-frames to derive the real GOP length |
| `scripts/analysis.sh` | Computes the BPP table across four resolution/frame-rate combinations at six bitrates; runs the HEVC-vs-H.264 VMAF comparison at two bitrates; attempts the MXF mux and reports what the muxer says; attempts the FLV/RTMP mux with HEVC and reports the result either way |

`testsrc2` is chosen over a static pattern because it carries moving detail and
color transitions, so it exercises the encoder. A still pattern compresses to
nothing and makes any bitrate target trivially achievable.

### 3.3 Phase 2 — the AWS pipeline

`terraform/main.tf` describes ten resources:

| Resource | Purpose |
|---|---|
| `random_id.suffix` | 4 bytes of entropy for the bucket name |
| `aws_s3_bucket.archive` | the archive destination, `force_destroy` |
| `aws_s3_bucket_public_access_block.archive` | all four flags |
| `aws_s3_bucket_server_side_encryption_configuration.archive` | AES256 |
| `aws_s3_bucket_lifecycle_configuration.archive` | 1-day expiry |
| `aws_iam_role.medialive` | the role MediaLive assumes |
| `aws_iam_role_policy.medialive_s3` | scoped inline policy |
| `aws_medialive_input_security_group.this` | source range permitted to push |
| `aws_medialive_input.this` | `RTMP_PUSH`, with `stream_name = "task06/live"` |
| `aws_medialive_channel.this` | the encoder and the ARCHIVE output group |

`terraform/variables.tf` holds the numbers as variables — `video_bitrate`
(12,000,000), `audio_bitrate` (192,000), `segment_seconds` (10),
`archive_prefix` (`live`), `input_codec`, `ingest_source_cidr` — so the
channel's configuration and the arithmetic that justifies it stay in one place.

`input_codec` deserves a note, because the name reads ambiguously: it feeds
`input_specification.codec` and describes the codec of the **contribution
feed**, which MediaLive must decode on the way in. The channel always encodes
HEVC on the way out, and that is set separately in `h265_settings`.

Supporting scripts:

| Script | What it does |
|---|---|
| `scripts/channel.sh` | `start`, `stop`, `status`, `endpoints`. Stamps the start time and prints elapsed running time on every call |
| `scripts/obs-configure.sh` | Installs the `configs/obs/` profile and scene collection under `%APPDATA%\obs-studio`, writes the `service.json` naming the ingest, and selects both in `global.ini` |
| `scripts/obs-evidence.sh` | Reads the installed profile back off disk, resolves the OBS binary's version, and quotes the connection, streaming and recording lines from OBS's own log |
| `scripts/trim-recording.sh` | Trims the screen recording to the streaming window with a stream copy, remuxes to mp4, probes either side and measures what the keyframe-aligned cut actually removed. Refuses to write inside the repository |
| `scripts/verify-archive.sh` | Lists the objects MediaLive wrote, downloads one, and runs ffprobe on it |
| `scripts/teardown-check.sh` | Queries AWS per resource class after destroy |

### 3.4 The three rate settings, and where each one lives

This is the part of the configuration most likely to be misread later, so it is
worth laying out explicitly. Three distinct rates are configured, at three
different layers:

| Layer | Setting | Value | Where |
|---|---|---|---|
| Video elementary stream | `h265_settings.bitrate` | 12,000,000 bps | `terraform/main.tf`, from `var.video_bitrate` |
| Audio elementary stream | `aac_settings.bitrate` | 192,000 bps | `terraform/main.tf`, from `var.audio_bitrate` |
| MPEG-TS multiplex | `m2ts_settings.bitrate`, `rate_mode = "CBR"` | `var.video_bitrate + var.audio_bitrate + 1000000` = **13,192,000 bps** | `terraform/main.tf:331` |

The mux rate is video plus audio plus one megabit of headroom, held constant by
padding with null packets. Section 6.4 works through what each layer measures
and why a probe of a container file reports the third number rather than the
first.

The rest of the `m2ts_settings` block: `audio_buffer_model = "ATSC"`,
`audio_frames_per_pes = 4`, `buffer_model = "MULTIPLEX"`, `pcr_control =
"PCR_EVERY_PES_PACKET"`, `segmentation_markers = "NONE"`.

---

## 4. The steps

**Phase 1, local.**

**1. Build the reference.** `scripts/encode.sh` generates a 10-second 1920x1080
at 60 fps `testsrc2` video and a 440 Hz `sine` audio track, muxed lossless as
FFV1 plus PCM. `06-encode.log` records the result as 64M.

**2. Encode to HEVC.** libx265 at 12 Mbps CBR-shaped, `keyint=120
min-keyint=120 scenecut=0 bframes=3 aq-mode=2`, `-preset medium`, AAC at 192k,
MPEG-TS out.

**3. Measure it.** ffprobe against the produced file: codec, resolution, frame
rate, container, audio bitrate, file size and duration, with the total bitrate
computed from size over duration rather than read off the command line. Then
count actual I-frames and divide to get the real GOP length.

**4. Compute the BPP surface.** `scripts/analysis.sh` computes bits per pixel
for 1080p30, 1080p60, 4K30 and 4K60 at 6, 8, 12, 20, 35 and 50 Mbps, and labels
each against the 0.05–0.15 band.

**5. Compare the codecs.** The same source encoded with libx265 and libx264 at
12 Mbps, both scored with VMAF against a common reference. Then the same
comparison at 3 Mbps.

**6. Test the containers.** Mux the HEVC stream into MXF and report what the
muxer says; fall back to MPEG-2 plus PCM to confirm the muxer works. Mux the
HEVC stream into FLV — the RTMP container — and report the result either way,
then do the same with H.264 as a baseline.

**Phase 2, AWS.**

**7. Plan.** `terraform fmt -check -recursive`, `validate`, `plan -out`.
`06-terraform-plan.log` records formatting clean, `Success! The configuration is
valid.`, and `Plan: 10 to add, 0 to change, 0 to destroy.`

**8. Apply.** Creates the bucket, the IAM role, the input, the input security
group and the channel. The channel is left IDLE.

**9. Start the channel.** `scripts/channel.sh start` stamps the time, calls
`start-channel`, and polls until the state reads RUNNING.

**10. Configure OBS and start it.** `scripts/obs-configure.sh` takes the RTMP
destination printed by `channel.sh endpoints`, installs the Task06 profile and
scene collection under `%APPDATA%\obs-studio`, and writes the `service.json`
that points OBS at the channel. OBS is then launched with `--startstreaming
--startrecording`, so it connects, encodes and records without a click.

**11. Record what OBS did.** `scripts/obs-evidence.sh` prints the installed
profile back off disk and quotes OBS's own log — the audio and video resets, the
x264 preset and profile lines, the RTMP connection, `==== Streaming Start ====`
and `==== Recording Start ====`.

**12. Verify the archive.** `scripts/verify-archive.sh` lists what MediaLive
wrote to S3, downloads one segment, and runs ffprobe on it.

**13. Stop the channel.** `scripts/channel.sh stop` polls until the state reads
IDLE.

**14. Destroy, then confirm.** `terraform destroy`, then
`scripts/teardown-check.sh` against AWS's own listings per resource class.

---

## 5. Measured results

### 5.1 Bits per pixel

Computed by `scripts/analysis.sh`, recorded in `06-analysis.log`:

| Resolution | fps | 6 Mbps | 8 Mbps | 12 Mbps | 20 Mbps | 35 Mbps | 50 Mbps |
|---|---|---|---|---|---|---|---|
| 1920x1080 | 30 | 0.0965 | 0.1286 | 0.1929 | 0.3215 | 0.5626 | 0.8038 |
| 1920x1080 | 60 | 0.0482 | 0.0643 | **0.0965** | 0.1608 | 0.2813 | 0.4019 |
| 3840x2160 | 30 | 0.0241 | 0.0322 | 0.0482 | 0.0804 | 0.1407 | 0.2009 |
| 3840x2160 | 60 | 0.0121 | 0.0161 | 0.0241 | 0.0402 | 0.0703 | 0.1005 |

The bold cell is the operating point. The log labels each cell against the band:
"in range" between roughly 0.05 and 0.15, "too low - visible artefacts" below,
"wasteful - diminishing returns" above.

### 5.2 The local encode, measured

All figures from `06-encode.log`, produced by ffmpeg 8.0.1.

| Property | Measured | Requirement |
|---|---|---|
| Video codec | `hevc (Main) (HEVC / 0x43564548)` | HEVC |
| Resolution | 1920x1080, SAR 1:1, DAR 16:9 | at least Full HD |
| Frame rate | 60/1 | — |
| Container | `mpegts` | .ts or .mxf |
| Audio codec | `aac (LC)`, 48000 Hz, stereo | — |
| Audio bitrate | 194,205 bps | at least 192 kbps |
| File size | 15,849,152 bytes | — |
| Duration | 10.021333 s | — |
| Total bitrate, size over duration | 12,652,330 bps | at least 12 Mbps |
| Implied video bitrate, total minus audio | 12,458,125 bps | — |
| Encode wall time | 16.360 s for 10 s of content | — |

Six checks, all passing. Note the layer on the two bitrate figures: 12,652,330
bps is a **container** rate measured from file size over duration, and it
includes MPEG-TS packet overhead. Subtracting the measured audio rate gives
12,458,125 bps as the implied video rate, which is itself an arithmetic result
rather than a probe of the elementary stream.

**The GOP, counted rather than assumed** (`06-encode.log`):

```
keyframes: 5   total frames: 600
average GOP: 120.0 frames = 2.00s at 60 fps
```

Counting I-frames in the output is what makes the 2-second claim a measurement.
`keyint=120` on the command line is a request.

### 5.3 HEVC against H.264, by VMAF

From `06-analysis.log`. Same source, same bitrate, same preset, both scored
against a common reference.

| Bitrate | bpp at 1080p60 | HEVC | H.264 | Delta (HEVC − H.264) |
|---|---|---|---|---|
| 12 Mbps | 0.0965 | 74.686293 | **75.093992** | **−0.41** |
| 3 Mbps | 0.0241 | **69.975861** | 69.023453 | **+0.95** |

File sizes at the 12 Mbps target, also from `06-analysis.log`: HEVC 15,849,152
bytes, H.264 16,621,456 bytes. The HEVC file is 4.65% smaller while scoring 0.41
VMAF points lower, which is a fair summary of what "roughly equivalent" looks
like when both encoders are near their ceiling.

### 5.4 Containers

**MXF, from `06-analysis.log`:**

```
[mxf @ ...] track 0: could not find essence container ul,
            codec not currently supported in container
[out#0/mxf @ ...] Could not write header (incorrect codec parameters ?)
```

**The fallback that confirms the muxer works**, also from `06-analysis.log`:

```
Input #0, mxf, from 'hevc_1080p60_12m.mxf':
  Duration: 00:00:03.00, start: 0.000000, bitrate: 13597 kb/s
  Stream #0:0: Video: mpeg2video (Main), yuv420p(tv, progressive), 1920x1080, 60 fps
  Stream #0:1: Audio: pcm_s16le, 48000 Hz, 1 channels, s16, 768 kb/s
```

**FLV, the RTMP container, with HEVC**, from `06-analysis.log`:

```
Stream #0:0: Video: hevc (Main), yuv420p(tv), 1920x1080 [SAR 1:1 DAR 16:9], 60 fps
Stream #0:1: Audio: aac (LC), 48000 Hz, stereo, fltp, 194 kb/s
```

and the same container with H.264 as the baseline every RTMP receiver supports:

```
Stream #0:0: Video: h264 (High), yuv420p(progressive), 1920x1080, 60 fps
```

### 5.5 The MediaLive plan

| Measurement | Value | Evidence |
|---|---|---|
| `terraform fmt -check -recursive` | `fmt clean` | `06-terraform-plan.log` |
| `terraform validate` | `Success! The configuration is valid.` | `06-terraform-plan.log` |
| Plan summary | `Plan: 10 to add, 0 to change, 0 to destroy.` | `06-terraform-plan.log` |
| Region | `eu-central-1` | `06-terraform-plan.log` |
| Channel name | `task06-channel` | `06-terraform-plan.log` |
| Archive prefix | `live` | `06-terraform-plan.log` |

### 5.6 The contribution encoder, as OBS read it and logged it

All figures from `06-obs.log`, captured 2026-08-27 20:51:38 +0300.

| Measurement | Value |
|---|---|
| OBS Studio version | 32.2.1 |
| Base resolution | 1920x1080 |
| Output resolution | 1920x1080 |
| Frame rate | 60/1 |
| Stream encoder | `obs_x264`, 12000 kbps, CBR |
| Keyframe interval | 2 s |
| Preset / profile / B-frames | `medium` / `main` / 3 |
| Audio | 48000 Hz stereo, `Track1Bitrate=192` |
| Recording start | 20:41:58.966 |
| RTMP connection successful | 20:42:00.322 |
| Streaming start | 20:42:00.328 |

The resolution and frame rate are OBS's own account of what it produced, not the
profile read back:

```
20:41:56.119: 	base resolution:   1920x1080
20:41:56.119: 	output resolution: 1920x1080
20:41:56.119: 	fps:               60/1
```

and the connection, with the ingest address masked by the capture path:

```
20:41:58.915: [rtmp stream: 'adv_stream'] Connecting to RTMP URL rtmp://<PUBLIC-IP>:1935/task06...
20:42:00.322: [rtmp stream: 'adv_stream'] Connection to rtmp://<PUBLIC-IP>:1935/task06 (<PUBLIC-IP>) successful
20:42:00.328: ==== Streaming Start ===============================================
```

Three checks pass on that log: the RTMP connection, the streaming start and the
recording start.

OBS recorded the screen locally while it streamed — `==== Recording Start ====`
at 20:41:58.966, 1.356 s before the RTMP connection completed. That recording is
written outside the repository and is not tracked; it is published as a release
asset on the tag. `scripts/trim-recording.sh` trims it to the streaming window
with a stream copy and remuxes it to mp4, taking that 1.356 s as its default
offset, and probes either side (`06-recording.log`):

| Property | As OBS wrote it | After the trim and remux |
|---|---|---|
| Container | `matroska,webm` | `mov,mp4,m4a,3gp,3g2,mj2` |
| Duration | 336.618000 s | 335.304000 s |
| Size | 513,154,423 bytes | 513,457,606 bytes |
| Video | `h264`, 1920x1080, `60/1` | `h264`, 1920x1080, `60/1` |
| Audio | `aac`, 48000 Hz, stereo | `aac`, 48000 Hz, stereo |

The codecs are identical on both sides, which is what a stream copy means: the
same H.264 and AAC bitstreams in a different container, with the leading portion
before the RTMP connection removed. The probed duration falls by 1.314 s rather
than the 1.356 s asked for: with `-ss` ahead of `-i` and `-c copy`, ffmpeg seeks
to the nearest preceding keyframe, so the cut lands on a GOP boundary and the
script measures what was removed instead of restating what was requested. The
byte count rises by 303,183 across the remux while carrying less content, and
since the log records no re-encode, that difference belongs to the containers
rather than to the picture.

### 5.7 The archive, as written by MediaLive

`06-s3-archive.log`, bucket `task06-archive-ef6ec5fe`, prefix `live`. The
listing runs to 36 lines; below are the first three and the last two, with the
31 between them elided:

```
2026-08-27 20:42:14   18.6 MiB live-hevc1080p60.000000.ts
2026-08-27 20:42:24   18.9 MiB live-hevc1080p60.000001.ts
2026-08-27 20:42:34   18.9 MiB live-hevc1080p60.000002.ts
[ ... 000003 through 000033 elided: 18.9 MiB each, one every 10 s ... ]
2026-08-27 20:47:54   18.9 MiB live-hevc1080p60.000034.ts
2026-08-27 20:47:56    6.9 MiB live-hevc1080p60.000035.ts
```

| Measurement | Value | Source |
|---|---|---|
| Object count | 36 | `06-s3-archive.log` |
| Objects with a `.ts` extension | 36 | `06-s3-archive.log` |
| Total size, summing the listed sizes | 668.1 MiB | derived from `06-s3-archive.log` |
| Steady-state segments (000001–000034) | 18.9 MiB each, 10 s apart | `06-s3-archive.log` |
| Listing span | 20:42:14 to 20:47:56 | `06-s3-archive.log` |
| Intervals of exactly 10 s | 34 of 35 | derived from the timestamps above |

Two checks pass on the listing: 36 objects written, and all 36 carrying a `.ts`
extension. The first object appears at 20:42:14, 13.7 s after OBS logged
`==== Streaming Start ====` at 20:42:00.328 — one 10-second rollover plus the
write, reading the two logs against each other.

### 5.8 The segment AWS produced, probed

`scripts/verify-archive.sh` downloaded `live-hevc1080p60.000000.ts` —
19,451,232 bytes — and probed it. From `06-s3-archive.log`, with the input path
shortened to its basename and nothing else altered:

```
Input #0, mpegts, from 'from-medialive.ts':
  Duration: 00:00:10.01, start: 2.000000, bitrate: 15552 kb/s
  Stream #0:0[0x1e1]: Video: hevc (Main) ([36][0][0][0] / 0x0024), yuv420p(tv, bt709), 1920x1080 [SAR 1:1 DAR 16:9], 60 fps, 60 tbr, 90k tbn, start 2.033333
  Stream #0:1[0x1e2](und): Audio: aac (LC) ([15][0][0][0] / 0x000F), 48000 Hz, stereo, fltp, 192 kb/s, start 2.000000
```

| Property | Measured | Requirement |
|---|---|---|
| Video codec | `hevc (Main)`, TS stream type `0x0024` | HEVC |
| Resolution | 1920x1080, SAR 1:1, DAR 16:9 | at least Full HD |
| Frame rate | 60 fps | — |
| Color | `yuv420p(tv, bt709)` | — |
| Audio | `aac (LC)`, 48000 Hz, stereo, 192 kb/s | at least 192 kbps |
| Container | `mpegts` | .ts or .mxf |
| Duration | 10.005333 s | — |
| Container bitrate, size over duration | 15,552,691 bps | — |

Five checks pass on the probe. This is the payoff measurement: not the local
encode and not the H.264 that OBS put on the wire, but what the AWS encoder
produced and S3 stored. `0x0024` is the MPEG-TS stream type for HEVC, and the
audio lands on 192 kb/s exactly — the requirement floor, hit precisely, because
MediaLive was configured with that number and produced it.

### 5.9 Teardown

`06-teardown.log`, region `eu-central-1`, captured 2026-08-27 20:50:45 +0300.
The log prints each class heading and its result on separate lines; they are
paired up here, one class per line:

```
--- MediaLive channels ---              [CLEAN]   no channels
--- MediaLive inputs ---                [CLEAN]   no inputs
--- MediaLive input security groups --- [CLEAN]   none
--- S3 buckets matching task06 ---      [CLEAN]   no task06 buckets
--- IAM roles matching task06 ---       [CLEAN]   none

RESULT: CLEAN — nothing remains, nothing left running
```

Five classes, queried against AWS's own listings rather than inferred from a
destroy summary. Nothing is left running.

---

## 6. What the measurements revealed

### 6.1 A bitrate figure without a resolution and frame rate attached says nothing

The BPP table's real content is its asymmetry. The **same** 12 Mbps is:

- 0.1929 bpp at 1080p30 — above the band, where extra bits buy progressively
  less;
- 0.0965 bpp at 1080p60 — mid-band;
- 0.0482 bpp at 4K30 — under the lower edge;
- 0.0241 bpp at 4K60 — a **quarter** of the 1080p60 value.

One number, four verdicts. That is the whole argument for why requirement 6.3
asks for a BPP justification rather than a bitrate: "12 Mbps" is generous at one
operating point and starved at another, and the sentence "we stream at 12 Mbps"
carries no information until the pixel rate is attached.

There is a second reading in the table worth keeping. 6 Mbps at 1080p30 and 12
Mbps at 1080p60 both come out at 0.0965 bpp — half the pixel rate at half the
bitrate lands on the same bits-per-pixel figure. BPP is the quantity that stays
put when resolution and frame rate move, which is exactly what makes it the
right instrument for comparing encoder configurations that differ in more than
one dimension.

The table also disciplines the prose written about it. Reading the 4K60 row at 6
Mbps (0.0121) while writing a sentence about 12 Mbps produces "an eighth of the
1080p60 value" where the table says 0.0241 — a quarter. The table is computed by
a script; the sentence about the table is typed by hand. Generating the table is
what makes the two comparable at a glance, and what makes a discrepancy between
them visible.

### 6.2 The HEVC efficiency claim is a low-bitrate result

At 12 Mbps HEVC scored **74.686293** against H.264's **75.093992** — HEVC 0.41
points behind. That is not the "40–50% more efficient" figure the codec is
usually sold on, and reporting that figure here would have been reporting
something that did not happen on this build.

Two properties of the test explain it:

1. **0.0965 bpp is a generous budget for this content.** Both encoders are close
   to their quality ceiling, so neither is bit-starved and there is little for
   HEVC's better tools to win back. The efficiency advantage is measured in bits
   saved at equal quality, and when quality is already near the ceiling there
   are few bits left to save.
2. **`testsrc2` is synthetic.** Hard geometric edges, flat color fields and
   deterministic motion. Real camera content carries grain, complex motion and
   shallow depth of field, which is where HEVC's larger transform blocks and
   better intra prediction actually earn their complexity.

The 3 Mbps row exists because the first result was surprising, and it is what
turns a confusing number into a usable one. At a quarter of the bitrate — 0.0241
bpp, under the band's lower edge — the direction flips: **69.975861 against
69.023453**, HEVC ahead by 0.95. The crossover is real, and it locates where the
advantage lives: at low bits per pixel, where the bit budget is the binding
constraint.

That reframes the codec argument for 4K rather than weakening it. At 4K60, 12
Mbps is 0.0241 bpp — the same operating point where HEVC won here. The
efficiency claim is right about where it matters and overstated where it does
not.

One more reading worth keeping: a delta under roughly 6 VMAF points sits below
the threshold of noticeable difference. So at 12 Mbps the honest conclusion is
that the two codecs are **visually equivalent on this source**, with HEVC
producing a file 4.65% smaller. Neither "HEVC wins" nor "H.264 wins" survives
the measurement; "the difference is not visible at this budget" does.

A single data point at the required bitrate would have supported either
narrative, told confidently. Two points at different bitrates constrain the
story to what actually happened.

### 6.3 The RTMP constraint is real and sits one layer away from where it is usually placed

I wrote the FLV mux test expecting it to fail, and the script was structured to
capture the error. It succeeded, cleanly, with `hevc (Main)` in the output.

The claim "RTMP cannot carry HEVC" was true from 2012 until 2023, for a
specific reason: FLV's 4-bit CodecID has no assigned value for HEVC, and Adobe
stopped developing the specification. Enhanced RTMP added HEVC, AV1 and VP9
through a FourCC extension, and ffmpeg 8.0.1 implements it, so the container
represents HEVC without complaint.

The constraint that governs this design is therefore on the **receiver**:
MediaLive's `RTMP_PUSH` input expects H.264. That statement is checkable against
the MediaLive API, where the previous statement was checkable against ffmpeg and
came out false.

That distinction is what the built pipeline runs on rather than a theoretical
aside. The channel takes an H.264 contribution feed over RTMP from OBS and
encodes HEVC into the archive, and `06-s3-archive.log` reads
`hevc (Main) ([36][0][0][0] / 0x0024)` back off a segment S3 stored. The
container could have carried HEVC on the wire; the receiver would not have taken
it; the requirement is satisfied where the artifact is, which is the bucket.

The transferable point is narrower than "test your assumptions". Producing a
file that ffmpeg is happy to mux proves something about ffmpeg and nothing about
what a remote service will ingest, and the two claims are easy to conflate
because they use the same words. Every claim about interoperability names two
parties, and a test that involves only one of them answers a different question.

### 6.4 A container rate, an elementary stream rate, and a configured mux rate are three numbers

The probe of the downloaded segment reports 15,552,691 bps. The requirement asks
for at least 12 Mbps of video. Those two numbers describe different things, and
reading the first as an answer to the second happens to clear the floor here
while being the wrong reasoning.

Three layers, and what each one is:

| Layer | Number | How it is known |
|---|---|---|
| Video elementary stream | 12,000,000 bps | configured in `h265_settings.bitrate` |
| Audio elementary stream | 192,000 bps | configured in `aac_settings.bitrate`, and the probe reads back exactly `192 kb/s` |
| MPEG-TS multiplex | 13,192,000 bps | configured at `terraform/main.tf:331` as video + audio + 1,000,000, CBR, padded with null packets |

An ffprobe of a `.ts` file divides the file's byte count by its duration. What
that produces is the **container** rate — video, audio, PSI tables, PCR, null
padding, and 188-byte packet framing, all of it.

The probed file is segment `000000`, the first object of the run.
`06-s3-archive.log` records it as 19,451,232 bytes with a duration of 10.005333
s and a measured bitrate of 15,552,691 bps, and that figure describes that one
segment.

Working the steady-state segments the same way, from the listed sizes and the
probed segment duration:

```
18.9 MiB × 1,048,576 × 8 / 10.005333 s ≈ 15.85 Mbps
```

The listing rounds to 0.1 MiB, so that figure is an approximation of a rounded
input, and the duration is the one probed segment's duration applied to the
others — which the uniform 10-second timestamps support. It is good enough to
identify which layer it describes, which is the point of computing it.

Both container measurements sit above the configured multiplex rate:
15,552,691 bps against 13,192,000 bps is a difference of 2,360,691 bps on the
probed segment. That is a fact about the container the ARCHIVE group wrote, and
it is not a reading of the video elementary stream, which is configured at
12,000,000 bps and cannot be recovered by dividing a file's byte count by its
duration.

So: the figure to compare against the 12 Mbps requirement is the video
elementary stream rate. The figure the uplink has to carry is the mux rate. The
figure a probe of a segment reports is neither, and taking it for the video rate
here would overstate by 3,552,691 bps.

### 6.5 The first and last objects of a live archive are not samples of the steady state

Thirty-four of the thirty-six segments sit at 18.9 MiB, ten seconds apart. Two
do not, and the shape of the exceptions is informative:

| Segment | Size | What it is |
|---|---|---|
| `000000` | 18.6 MiB | the first segment, 0.3 MiB under the 34 that follow it |
| `000035` | 6.9 MiB | the final object, written 2 s after the previous rollover |

`000034` is stamped `20:47:54` and `000035` `20:47:56`, so the 10-second spacing
holds for thirty-four of the thirty-five intervals and not for the last. That
last write is a flush rather than a rollover: the channel stopped mid-segment
and the encoder wrote what it had.

The operational reading matters for anyone consuming such an archive. A
verification that probes the first object measures the first object, which here
carries the start of the encode and computes about 293 kbps below the
steady-state figure derived in 6.4. That is small, and the reason to know it is
that nothing in the probe says which segment it landed on. Deriving the
steady-state band separately is what keeps one probe from standing in for
thirty-six.

### 6.6 ffmpeg consumes stdin, and it starves every later ffmpeg in the script

Under the evidence-capture wrapper, every `ffprobe` returned empty and a dozen
checks failed against encodes that were fine.

ffmpeg reads stdin for interactive keypresses — `q` to quit, `?` for help. With
stdin attached to something, it consumes whatever is there. In a script where
several ffmpeg and ffprobe calls run in sequence with a shared stdin, the first
call drains it and every later call starts against a closed or empty stream.

Fixed two ways, belt and braces: `-nostdin` on every ffmpeg and ffprobe call,
and the evidence wrapper now redirects stdin from `/dev/null` so future tasks
inherit the protection without anyone having to remember it.

### 6.7 `MSYS_NO_PATHCONV=1` breaks ffprobe the same way it breaks gcloud

That variable is exported across this repository so Git Bash stops rewriting
container-side paths for Docker. `ffprobe.exe` is a native Windows binary: with
the variable set, a POSIX path like `/c/Users/...` reaches it unconverted, and
it fails with *"No such file or directory"* — or, when its output is being
captured into a variable, simply returns nothing.

`scripts/encode.sh` and `scripts/analysis.sh` both `unset MSYS_NO_PATHCONV` at
the top, with the reason written above the line.

This is the same class of fault as the gcloud behavior in Task 05, and it was
found the same way: by running the tool outside the wrapper and comparing. When
a suite of checks fails all at once against work that is known good, the
question is not which check is wrong but what all of them share.

### 6.8 MPEG-TS makes ffprobe print every value twice

`ffprobe -show_entries stream=bit_rate` against a `.ts` file returns `194205` on
two lines. MPEG-TS describes each stream both standalone and within the program,
so the entry appears once for each context.

Captured into a shell variable that becomes the two-line string `194205\n194205`
— and every numeric comparison afterward dies with *"integer expression
expected"*, against an encode that met every requirement.

Every extraction in `scripts/encode.sh` now takes the first line. The general
shape: a probe that returns a set where the caller expects a scalar produces a
type error far downstream, at a comparison that looks unrelated to the probe.

### 6.9 `terraform validate` earns its place in the sequence

`framerate_control` is not a valid argument inside `h265_settings` for the AWS
provider. `validate` caught it before any plan or apply — a schema check against
the provider's own definitions, run in under a second with nothing created.

The value is in where the error surfaces. A schema error found at validate time
is a message. The same error found during an apply against a half-created
channel is a partially built pipeline to reason about and clean up. Running
`fmt -check`, `validate` and `plan -out` as a single sequence before any apply
is what keeps that ordering, and it is the same sequence Task 05 uses.

### 6.10 An encoder configuration is a set of files, so it can be installed and read back

OBS is usually documented as a screenshot of somebody's settings dialog. It does
not have to be. A profile is `basic.ini` plus `streamEncoder.json` and
`recordEncoder.json` in a directory, a scene collection is one JSON file, and
which of each is active is four keys in `global.ini` — all under
`%APPDATA%\obs-studio`. `scripts/obs-configure.sh` writes all of it, and OBS
starts on it.

The consequence for evidence is the part worth keeping. `scripts/obs-evidence.sh`
reads the installed profile back off disk and prints it — `BaseCX`, `OutputCX`,
`FPSCommon`, `Track1Bitrate`, and `streamEncoder.json` field by field — and then
quotes what OBS itself logged: `base resolution: 1920x1080`, `output
resolution: 1920x1080`, `fps: 60/1`. The configuration and the encoder's own
account of what it did come from two independent places in `06-obs.log` and
agree, and neither of them is a screenshot.

Launching with `--startstreaming --startrecording` closes the loop, because the
run needs no click. A configuration that is documented and a configuration that
was executed are then the same set of files, and the way to check the claim is
to read them.

---

## 7. How to run it yourself

Requirements on the host: ffmpeg and ffprobe 8.x with libx265, libx264 and the
VMAF filter; Terraform 1.5 or later; the AWS CLI v2 authenticated; OBS Studio
for the contribution leg, 32.2.1 in this run; and a POSIX shell. On Windows, run
the scripts from Git Bash.

### Phase 1 — local, reproducible from a clone

```bash
cd 06-streaming

# HEVC 1080p60 at 12 Mbps, then measured with ffprobe against every floor.
./scripts/encode.sh

# BPP table, HEVC vs H.264 by VMAF at two bitrates, MXF and RTMP container tests.
./scripts/analysis.sh
```

The source is synthetic (`testsrc2` plus `sine`), so no media assets are needed
and the outputs are comparable run to run. Both scripts write into `out/`.

### Phase 2 — the AWS pipeline

```bash
cd 06-streaming/terraform
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -input=false -out=tfplan.binary

# Creates the bucket, IAM role, input, input security group and channel.
# The channel is created IDLE.
terraform apply tfplan.binary
cd ..

# The channel's running clock starts here, and every call prints elapsed time.
./scripts/channel.sh start

# The RTMP destination, printed to the operator's terminal only.
./scripts/channel.sh endpoints

# Install the profile and scene collection where OBS reads them, and write the
# service.json pointing OBS at that destination.
./scripts/obs-configure.sh <rtmp-destination-url>

# Then start OBS with --startstreaming --startrecording, and leave it running.

# What OBS was configured to do, and what its own log says it did.
./scripts/obs-evidence.sh

# List what MediaLive wrote, download one segment, probe it.
./scripts/verify-archive.sh

./scripts/channel.sh stop

cd terraform && terraform destroy -auto-approve && cd ..

# Query AWS per resource class and confirm nothing remains.
./scripts/teardown-check.sh
```

Notes for a clean run:

- **`terraform apply` deliberately leaves the channel IDLE.** Creating a channel
  and running one are separate decisions, and `scripts/channel.sh` makes each of
  them an explicit, timestamped action. `channel.sh status` prints the elapsed
  running time whenever a start stamp exists.
- **Set `ingest_source_cidr`.** It defaults to `0.0.0.0/0` because the operator
  address here is dynamic and the channel existed for minutes. With a fixed
  address, that variable takes it and the input accepts a push from nowhere
  else.
- **The RTMP destination is written at configure time, not committed.**
  `obs-configure.sh` builds `service.json` from the URL passed to it, splitting
  the last path element off as the stream key, because that URL names an ingest
  that exists only while the channel does.
- **`unset MSYS_NO_PATHCONV`** before calling ffmpeg, ffprobe, terraform or the
  AWS CLI from Git Bash. Every script in this directory already does. See 6.7.
- **`force_destroy` on the bucket is what lets destroy complete**, because
  MediaLive writes objects Terraform never recorded.
- **The endpoint is masked on the way into evidence.** `channel.sh endpoints`
  prints the ingest URL to the operator's terminal only, and the capture path
  masks the address before it reaches a log — `06-obs.log` carries OBS's
  connection lines as `rtmp://<PUBLIC-IP>:1935/task06`.

### Evidence produced by these steps

| Log | Produced by | What it records |
|---|---|---|
| `docs/evidence/06-encode.log` | `scripts/encode.sh` | the encoder settings with reasons, the ffprobe measurement of the produced file, and the I-frame count behind the 2.00 s GOP |
| `docs/evidence/06-analysis.log` | `scripts/analysis.sh` | the 24-cell BPP table, both VMAF comparisons, the MXF muxer's refusal and the MPEG-2 fallback, and the FLV/HEVC result |
| `docs/evidence/06-terraform-plan.log` | terraform fmt/validate/plan | `Plan: 10 to add, 0 to change, 0 to destroy.` |
| `docs/evidence/06-obs.log` | `scripts/obs-evidence.sh` | OBS Studio 32.2.1, the installed profile read back field by field, and OBS's own log lines for the RTMP connection, the streaming start and the recording start |
| `docs/evidence/06-recording.log` | ffprobe on the OBS screen recording | container, duration, size and stream parameters as OBS wrote the recording and again after the lossless trim and remux |
| `docs/evidence/06-s3-archive.log` | `scripts/verify-archive.sh` | the 36-object listing, the downloaded segment's size, and ffprobe on what AWS produced |
| `docs/evidence/06-teardown.log` | `scripts/teardown-check.sh` | five resource classes queried against AWS after destroy |
