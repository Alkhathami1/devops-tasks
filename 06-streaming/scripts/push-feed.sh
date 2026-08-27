#!/usr/bin/env bash
# Push the Phase 1 HEVC file to the MediaLive input.
#
# ffmpeg rather than OBS, and the report says so plainly: OBS is interactive
# and cannot be driven reproducibly from a script. configs/obs-settings.md is
# the operator-facing equivalent, written as a runbook, NOT as a record of
# something that ran.
#
# -re paces the file at real time. Without it ffmpeg pushes as fast as it can
# read, MediaLive sees a feed hundreds of times faster than wall clock, and the
# input buffer overruns.
set -uo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="$STACK_DIR/terraform"
OUT="$STACK_DIR/out"
unset MSYS_NO_PATHCONV
export PATH="$PATH:/c/Program Files/Amazon/AWSCLIV2"; export AWS_PAGER=""

SECONDS_TO_PUSH="${1:-90}"
SRC="$OUT/hevc_1080p60_12m.ts"
[ -f "$SRC" ] || { echo "run scripts/encode.sh first"; exit 1; }

ENDPOINT="$(cd "$TF" && terraform output -json input_destinations 2>/dev/null \
  | python -c "import json,sys; d=json.load(sys.stdin); print(d[0]['url'])" 2>/dev/null)"
[ -n "${ENDPOINT:-}" ] || { echo "no input endpoint in terraform output"; exit 1; }

echo "=== pushing the HEVC contribution feed ==="
echo "    source   : $(basename "$SRC")"
echo "    endpoint : <redacted in evidence>"
echo "    duration : ${SECONDS_TO_PUSH}s, looped, paced with -re"
echo ""
echo "    ffmpeg -re -stream_loop -1 -i <hevc.ts> -c copy -f rtp_mpegts <endpoint>"
echo ""

# -c copy: the file is ALREADY HEVC at 12 Mbps from Phase 1. Re-encoding here
# would prove nothing about the pipeline and would cost CPU for no reason.
timeout "${SECONDS_TO_PUSH}" ffmpeg -nostdin -hide_banner -loglevel warning \
  -re -stream_loop -1 -i "$SRC" \
  -c copy -f rtp_mpegts "$ENDPOINT" 2>&1 | tail -20

echo ""
echo "    push finished after ${SECONDS_TO_PUSH}s"
