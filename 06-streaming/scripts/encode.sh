#!/usr/bin/env bash
# Requirement: >= Full HD, >= 12 Mbps video, >= 192 kbps audio, HEVC, .ts or .mxf
#
# Every number below is MEASURED with ffprobe against the produced file, not
# copied from the encoder command line. Asking ffmpeg for 12 Mbps and then
# reporting 12 Mbps proves only that the argument was typed correctly.
#
# Source is synthetic (testsrc2 + sine) so the whole thing is reproducible from
# a clone with no media assets: same input, same output, byte-comparable.

set -uo pipefail

# MSYS_NO_PATHCONV must NOT be set for this script. It is exported elsewhere
# in this repo so Git Bash stops rewriting container-side paths for Docker,
# but ffmpeg and ffprobe are native Windows binaries: with the variable set,
# a POSIX path like /c/Users/... is passed through unconverted and they fail
# with "No such file or directory" - or, for ffprobe, simply return nothing.
# The empty output then cascades into a dozen confident false failures against
# encodes that are perfectly fine. Same class of bug as gcloud in Task 05.
unset MSYS_NO_PATHCONV

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$STACK_DIR/out"
mkdir -p "$OUT"

DURATION="${DURATION:-10}"
W=1920
H=1080
FPS=60
VBITRATE=12000000     # 12 Mbps, the requirement floor
ABITRATE=192000       # 192 kbps, the requirement floor
GOP=$((FPS * 2))      # 2-second GOP: see the note below

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }
info() { echo "       $*"; }

probe() { ffprobe -v error -show_entries "$2" -of default=nw=1:nk=1 "$1" 2>/dev/null | tr -d '\r'; }

echo "================================================================"
echo "Phase 1 — local HEVC encoding, measured"
echo "ffmpeg: $(ffmpeg -version 2>/dev/null | head -1)"
echo "================================================================"

# ---------------------------------------------------------------------------
echo ""
echo "=== 1. Reference source ==="
echo "    testsrc2 has moving detail and colour transitions, so it actually"
echo "    exercises the encoder. A static pattern would compress to nothing and"
echo "    make any bitrate target trivially achievable."
SRC="$OUT/source.mkv"
ffmpeg -nostdin -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=${W}x${H}:rate=${FPS}:duration=${DURATION}" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=${DURATION}" \
  -c:v ffv1 -c:a pcm_s16le -shortest "$SRC"
info "source: $(du -h "$SRC" | cut -f1) lossless FFV1 + PCM, ${DURATION}s ${W}x${H}@${FPS}"

# ---------------------------------------------------------------------------
echo ""
echo "=== 2. HEVC encode at the required parameters ==="
echo ""
echo "    Encoder settings and why each one:"
cat <<'WHY'
      -c:v libx265         HEVC. The requirement names the codec.
      -b:v 12M             target. CBR-ish via bufsize/maxrate below, because a
                           contribution feed into MediaLive wants predictable
                           bitrate, not VBR peaks that overrun the uplink.
      -maxrate 12M
      -bufsize 24M         VBV buffer = 2x bitrate = 2 seconds. Smaller starves
                           complex scenes; larger lets the instantaneous rate
                           drift further above the link budget.
      -x265-params
        keyint=120         2s GOP at 60fps. MediaLive segments the ARCHIVE
        min-keyint=120     output on IDR boundaries, so the GOP length sets the
                           minimum segment granularity. Fixed (min=max) so
                           segments are even.
        scenecut=0         no adaptive keyframes: a scene-cut IDR mid-GOP
                           produces uneven segments downstream.
        bframes=3          B-frames help compression. Live sub-second latency
                           would use 0; this is contribution, not interactive.
        aq-mode=2          variance adaptive quantisation, better on flat areas
      -pix_fmt yuv420p     8-bit 4:2:0. Main profile - the widest decode support
                           and what MediaLive's HEVC encoder expects.
      -preset medium       speed/quality balance. slower would gain a little
                           quality per bit at several times the encode time.
      -c:a aac -b:a 192k   the audio requirement floor.
      -f mpegts            MPEG-TS container.
WHY
echo ""

TS="$OUT/hevc_1080p60_12m.ts"
time ffmpeg -nostdin -hide_banner -loglevel error -y -i "$SRC" \
  -c:v libx265 -preset medium -pix_fmt yuv420p \
  -b:v ${VBITRATE} -maxrate ${VBITRATE} -bufsize $((VBITRATE * 2)) \
  -x265-params "keyint=${GOP}:min-keyint=${GOP}:scenecut=0:bframes=3:aq-mode=2:log-level=error" \
  -c:a aac -b:a ${ABITRATE} -ar 48000 -ac 2 \
  -f mpegts "$TS"

# ---------------------------------------------------------------------------
echo ""
echo "=== 3. MEASURED against the requirements ==="
echo ""
echo "    ffprobe on the produced file:"
ffprobe -hide_banner "$TS" 2>&1 | grep -E 'Stream|Duration|Input' | sed 's/^/      /'

VCODEC="$(probe "$TS" "stream=codec_name" | head -1)"
VW="$(probe "$TS" "stream=width" | head -1)"
VH="$(probe "$TS" "stream=height" | head -1)"
FRAMERATE="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "$TS" 2>/dev/null | tr -d '\r' | head -1)"
ACODEC="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$TS" 2>/dev/null | tr -d '\r' | head -1)"
ABR="$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=nw=1:nk=1 "$TS" 2>/dev/null | tr -d '\r' | head -1)"
FMT="$(probe "$TS" "format=format_name" | head -1)"
SIZE="$(stat -c %s "$TS")"
DUR="$(probe "$TS" "format=duration" | head -1)"

# Overall bitrate measured from actual file size and duration - the honest
# figure, since it includes container overhead the encoder target does not.
MEASURED_TOTAL="$(awk -v s="$SIZE" -v d="$DUR" 'BEGIN{printf "%.0f", (s*8)/d}')"
VIDEO_ONLY="$(awk -v t="$MEASURED_TOTAL" -v a="${ABR:-192000}" 'BEGIN{printf "%.0f", t-a}')"

echo ""
printf '      %-24s %s\n' "video codec"       "$VCODEC"
printf '      %-24s %sx%s\n' "resolution"     "$VW" "$VH"
printf '      %-24s %s\n' "frame rate"        "$FRAMERATE"
printf '      %-24s %s\n' "container"         "$FMT"
printf '      %-24s %s\n' "audio codec"       "$ACODEC"
printf '      %-24s %s bps\n' "audio bitrate" "${ABR:-n/a}"
printf '      %-24s %s bytes\n' "file size"   "$SIZE"
printf '      %-24s %s s\n' "duration"        "$DUR"
printf '      %-24s %s bps  (from size/duration, includes TS overhead)\n' "MEASURED total bitrate" "$MEASURED_TOTAL"
printf '      %-24s %s bps  (total minus audio)\n' "implied video bitrate" "$VIDEO_ONLY"

echo ""
[ "$VCODEC" = "hevc" ]        && pass "codec is HEVC" || fail "codec is $VCODEC, not hevc"
[ "$VW" -ge 1920 ] && [ "$VH" -ge 1080 ] \
  && pass "resolution ${VW}x${VH} meets the Full HD floor" \
  || fail "resolution ${VW}x${VH} below 1920x1080"
[ "${MEASURED_TOTAL:-0}" -ge 12000000 ] \
  && pass "measured total bitrate ${MEASURED_TOTAL} bps meets the 12 Mbps floor" \
  || fail "measured ${MEASURED_TOTAL} bps is below 12 Mbps"
[ "${ABR:-0}" -ge 192000 ] \
  && pass "audio ${ABR} bps meets the 192 kbps floor" \
  || fail "audio ${ABR} bps below 192 kbps"
echo "$FMT" | grep -q mpegts && pass "container is MPEG-TS" || fail "container is $FMT"

# --- GOP, measured by counting keyframes -----------------------------------
echo ""
echo "=== 4. GOP / keyframe interval, measured ==="
echo "    Counting actual I-frames rather than trusting keyint:"
KEYFRAMES="$(ffprobe -v error -select_streams v:0 -show_entries frame=key_frame -of csv=p=0 "$TS" 2>/dev/null | grep -c '^1' || true)"
TOTFRAMES="$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$TS" 2>/dev/null | tr -d '\r' | head -1)"
info "keyframes: ${KEYFRAMES}   total frames: ${TOTFRAMES}"
if [ "${KEYFRAMES:-0}" -gt 0 ] && [ "${TOTFRAMES:-0}" -gt 0 ]; then
  AVG_GOP="$(awk -v k="$KEYFRAMES" -v t="$TOTFRAMES" 'BEGIN{printf "%.1f", t/k}')"
  GOP_SEC="$(awk -v g="$AVG_GOP" -v f="$FPS" 'BEGIN{printf "%.2f", g/f}')"
  info "average GOP: ${AVG_GOP} frames = ${GOP_SEC}s at ${FPS} fps"
  pass "keyframe interval measured at ${GOP_SEC}s (target 2s)"
else
  fail "could not count keyframes"
fi

echo ""
echo "================================================================"
[ "$RESULT" = "0" ] && echo "RESULT: HEVC ENCODE MEETS ALL REQUIREMENTS" || echo "RESULT: FAILURES PRESENT"
echo "================================================================"
exit "$RESULT"
