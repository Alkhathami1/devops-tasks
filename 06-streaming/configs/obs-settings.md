# OBS Studio settings for a 1080p60 HEVC contribution feed

Every field below, with the reason for the value rather than just the value.
These match the ffmpeg parameters in `scripts/encode.sh`, so the local encode
and the OBS path produce equivalent streams.

## Output → Streaming

| Field | Value | Why |
|---|---|---|
| Service | Custom | MediaLive is not in the preset list |
| Server | `rtp://<medialive-input>:5000` | **The deployed input is `RTP_PUSH`.** OBS's native Streaming output cannot emit RTP-MPEGTS, so this goes through Settings → Output → **Custom Output (FFmpeg)** with container `rtp_mpegts`. See "Transport" below |
| Encoder | x264 → **change to HEVC** | `libx265`, NVENC HEVC, AMF HEVC or QSV HEVC depending on hardware |
| Rate Control | **CBR** | A contribution uplink has a fixed budget. VBR peaks overrun it and the transport then drops packets, which is worse than the quality VBR buys |
| Bitrate | **12000 kbps** | 0.0965 bpp at 1080p60 — mid-band. See the BPP table |
| Keyframe Interval | **2 s** | Sets the minimum segment granularity downstream. MediaLive's ARCHIVE output cuts on IDR |
| Preset | `medium` / `quality` | On NVENC use `p5`/`slow`. Faster presets waste bits; slower ones risk dropped frames on a live encode |
| Profile | **main** | 8-bit 4:2:0. `main10` only if the source is genuinely 10-bit — otherwise it costs bitrate for nothing |
| Tune | *(none)* | `zerolatency` disables B-frames and lookahead. Right for interactive, wasteful for contribution |
| B-frames | **3** | Real compression gain. Set 0 only if sub-second glass-to-glass latency is required |
| Look-ahead | on | Lets rate control see complexity coming and allocate ahead of it |
| Psycho Visual Tuning | on | Perceptual optimisation; helps at this bpp |

## Output → Audio

| Field | Value | Why |
|---|---|---|
| Audio Bitrate | **192 kbps** | The requirement floor. Stereo AAC-LC at 192k is transparent for speech and most music |
| Codec | AAC-LC | What MediaLive expects for an MPEG-TS contribution feed |

## Video

| Field | Value | Why |
|---|---|---|
| Base (Canvas) | 1920x1080 | |
| Output (Scaled) | **1920x1080** | No scaling. Scaling on the contribution encoder throws away detail the downstream encoder could have used |
| Downscale Filter | Lanczos | Only relevant if scaling; sharpest of the options |
| FPS | **60** | Matches the BPP calculation. 30 would halve the pixel rate and double the bpp at the same bitrate |

## Advanced

| Field | Value | Why |
|---|---|---|
| Color Format | NV12 | 8-bit 4:2:0, what the encoders want; avoids a conversion |
| Color Space | Rec. 709 | HD standard. 601 is SD and will shift colours |
| Color Range | Limited | Broadcast convention (16-235). Full range through a limited-range chain crushes blacks and clips whites |

## Transport: why RTP here, and where SRT fits

**RTMP is ruled out by the receiver, not the container.** Classic RTMP/FLV has a
4-bit CodecID with no value for HEVC. Enhanced RTMP (2023) adds one via a FourCC
extension and modern ffmpeg implements it — `scripts/analysis.sh` muxes HEVC
into FLV without complaint, which is the opposite of what the textbook answer
predicts. MediaLive's `RTMP_PUSH` input still expects H.264 and will not ingest
it. Producing a file ffmpeg is happy to mux proves nothing about what AWS will
accept.

**RTP_PUSH is what this channel deploys.** RTP carries MPEG-TS, which has a
native stream type for HEVC (0x24), and ffmpeg pushes it with `-f rtp_mpegts`.
It is the shortest path from an HEVC encoder to a MediaLive input, and it is
what `terraform/main.tf` creates.

**SRT is the better choice over the public internet, and is not what was
built.** SRT retransmits lost packets within a configurable latency window;
RTP over UDP does not recover them at all, and RTMP over TCP stalls
head-of-line on loss and backs the encoder up. For a real contribution feed
crossing the internet, SRT is the right transport and MediaLive supports it as
an input type. It was not used here because RTP_PUSH was sufficient for a
channel that existed for four minutes on a known-good local path, and every
extra input type is another thing to get right inside a short window. On an
unmanaged network, choose SRT.

## The honest note about this file

**OBS was not used to produce the evidence for this task.** OBS is interactive
and cannot be driven reproducibly from a script, so the contribution feed was
pushed with ffmpeg using the parameters above. This document is the
operator-facing equivalent — the settings a human would enter to produce the
same stream — and is written as a runbook, not as a record of something that
was executed.
