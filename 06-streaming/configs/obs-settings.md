# OBS Studio settings for a 1080p60 HEVC contribution feed

Every field below, with the reason for the value rather than just the value.
These match the ffmpeg parameters in `scripts/encode.sh`, so the local encode
and the OBS path produce equivalent streams.

## Output → Streaming

| Field | Value | Why |
|---|---|---|
| Service | Custom | MediaLive is not in the preset list |
| Server | `rtmp://<medialive-input>:1935/task06` | **The deployed input is `RTMP_PUSH`.** OBS emits this from its own Stream output, which is why the channel takes RTMP. See "Transport" below |
| Stream Key | `live` | The last path element of the MediaLive destination URL |
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

## Transport: why RTMP here, and where SRT fits

**The contribution codec and the archive codec are different, on purpose.** OBS
contributes H.264 over RTMP. MediaLive decodes it and the channel encodes HEVC
into the ARCHIVE output group, so the `.ts` segments that land in S3 are HEVC.
The requirement is met where the requirement lives — in the recording.

**RTMP is not ruled out by the container.** Classic RTMP/FLV has a 4-bit CodecID
with no value for HEVC, and Enhanced RTMP (2023) adds one via a FourCC
extension that modern ffmpeg implements — muxing HEVC into FLV succeeds, which
is the opposite of what the textbook answer predicts. What decides the
transport is the receiver: MediaLive's `RTMP_PUSH` input expects H.264. So the
contribution leg is H.264 and the codec requirement is satisfied downstream.

**RTP_PUSH is the alternative when the encoder can emit it.** RTP carries
MPEG-TS, which has a native stream type for HEVC (0x24), and ffmpeg pushes it
with `-f rtp_mpegts` — that path carries HEVC end to end. OBS's native Stream
output cannot emit RTP-MPEGTS, so reaching it from OBS means Custom Output
(FFmpeg) rather than the Stream panel.

**SRT is the better choice over the public internet.** SRT retransmits lost
packets within a configurable latency window; RTP over UDP does not recover them
at all, and RTMP over TCP stalls head-of-line on loss and backs the encoder up.
For a real contribution feed crossing an unmanaged network, choose SRT.

## Where these settings come from

**These are the settings OBS read off disk.** `scripts/obs-configure.sh` writes
the profile and the scene collection into `%APPDATA%\obs-studio`, so every field
above is installed rather than typed into a dialog, and OBS was launched from
the command line with `--startstreaming --startrecording`. That is what makes
this document reproducible: the file the report describes is the file OBS reads.

The measurements are in `docs/evidence/06-obs.log`, which carries OBS's own log
reporting `base resolution: 1920x1080`, `output resolution: 1920x1080` and
`fps: 60/1`, then the successful RTMP connection and the streaming and recording
starts.
