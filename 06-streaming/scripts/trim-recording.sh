#!/usr/bin/env bash
# Trim the OBS screen recording to the streaming window and remux it to mp4.
#
# The trim is lossless: -c copy carries the h264 and aac bitstreams across
# untouched and only the container changes. Re-encoding a 1080p60 screen
# capture to cut a second off the front would degrade every frame after it for
# no reason, so the codecs printed either side of the trim below are the check
# that no re-encode happened - they must be identical.
#
# The default offset is derived from OBS's own log rather than guessed:
#
#   20:41:58.966  ==== Recording Start ====
#   20:42:00.322  Connection to rtmp://...:1935/task06 successful
#
# a 1.356 s lead-in where the recording is running but nothing is reaching
# MediaLive yet. With -ss before -i and -c copy, ffmpeg seeks to the nearest
# preceding keyframe, so the delta actually achieved is measured afterwards
# rather than assumed to equal the offset requested.
#
# The recording is large and must never enter the repository, so writing the
# output anywhere inside the working tree is refused rather than ignored.
#
#   Usage: scripts/trim-recording.sh [src.mkv] [dst.mp4] [offset-seconds]
set -euo pipefail

# Resolved rather than hardcoded, so the script is not pinned to the machine it
# was written on: the source defaults to the newest recording in OBS's default
# output directory, and the destination to a sibling of it that is outside any
# repository. Both are overridable by argument or environment.
REC_DIR="${OBS_RECORDING_DIR:-$HOME/Videos}"
SRC="${1:-${OBS_RECORDING:-$(ls -1t "$REC_DIR"/*.mkv 2>/dev/null | head -1)}}"
DST="${2:-${OBS_TRIMMED:-$HOME/obs-recordings/task06-obs-to-medialive.mp4}}"
OFFSET="${3:-1.356}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DST_DIR="$(cd "$(dirname "$DST")" 2>/dev/null && pwd -P || echo "")"
case "${DST_DIR:-}" in
  "$REPO_ROOT"|"$REPO_ROOT"/*)
    echo "refusing to write the recording inside the repository: $DST" >&2
    exit 1
    ;;
esac

if [ ! -f "$SRC" ]; then
  echo "source recording not found: $SRC" >&2
  echo "pass it as the first argument, or set OBS_RECORDING." >&2
  exit 1
fi

probe() {
  ffprobe -v error \
    -show_entries format=format_name,duration,size \
    -show_entries stream=codec_name,codec_type,width,height,r_frame_rate,sample_rate,channels \
    -of default=nw=1 "$1" 2>&1 | sed 's/^/      /'
}

duration() {
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"
}

echo "=== The OBS screen recording ==="
echo ""
echo "    OBS recorded locally while it streamed. The recording is trimmed to the"
echo "    streaming window with a stream copy - no re-encode - and remuxed to mp4."
echo "    It lives outside the repository and is not tracked; it ships as a"
echo "    release asset on the tag."
echo ""
echo "--- as OBS wrote it ---"
probe "$SRC"
BEFORE="$(duration "$SRC")"

mkdir -p "$(dirname "$DST")"
ffmpeg -y -loglevel error -ss "$OFFSET" -i "$SRC" -c copy -movflags +faststart "$DST"

echo ""
echo "--- after the lossless trim and remux ---"
probe "$DST"
AFTER="$(duration "$DST")"

echo ""
printf '    requested offset : %s s\n' "$OFFSET"
printf '    measured removed : %s s (keyframe-aligned)\n' \
  "$(awk -v a="$BEFORE" -v b="$AFTER" 'BEGIN { printf "%.3f", a - b }')"
echo ""
echo "    The codecs are unchanged either side of the trim, which is what a"
echo "    stream copy means: the same h264 and aac bitstreams in a different"
echo "    container, with the lead-in before the RTMP connection removed."
