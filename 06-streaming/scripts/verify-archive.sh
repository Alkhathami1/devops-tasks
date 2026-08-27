#!/usr/bin/env bash
# Prove the S3 archive: list the .ts objects MediaLive wrote, download one, and
# ffprobe it.
#
# That last step is the strongest evidence available for this task. Anyone can
# configure an encoder to say HEVC; ffprobe reporting hevc at ~12 Mbps on a
# file MEDIALIVE produced and S3 stored is the thing that cannot be faked.

set -uo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="$STACK_DIR/terraform"
OUT="$STACK_DIR/out"
export PATH="$PATH:/c/Program Files/Amazon/AWSCLIV2"
export AWS_PAGER=""
unset MSYS_NO_PATHCONV

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }
info() { echo "       $*"; }

BUCKET="$(cd "$TF" && terraform output -raw archive_bucket 2>/dev/null)"
REGION="$(cd "$TF" && terraform output -raw region 2>/dev/null || echo eu-central-1)"
PREFIX="$(cd "$TF" && terraform output -raw archive_prefix 2>/dev/null || echo live)"

[ -n "$BUCKET" ] || { echo "no bucket in terraform output"; exit 1; }

echo "=== S3 archive verification ==="
echo "    bucket: $BUCKET"
echo "    prefix: $PREFIX"
echo ""

echo "--- objects MediaLive wrote ---"
aws s3 ls "s3://$BUCKET/" --recursive --human-readable --region "$REGION" | sed 's/^/      /'
echo ""

COUNT="$(aws s3api list-objects-v2 --bucket "$BUCKET" --region "$REGION" \
        --query 'length(Contents)' --output text 2>/dev/null)"
[ "$COUNT" = "None" ] && COUNT=0
info "object count: ${COUNT}"
[ "${COUNT:-0}" -ge 1 ] && pass "MediaLive wrote ${COUNT} object(s) to S3" \
                        || fail "the bucket is empty - nothing was archived"

TS_COUNT="$(aws s3api list-objects-v2 --bucket "$BUCKET" --region "$REGION" \
           --query "length(Contents[?ends_with(Key, '.ts')])" --output text 2>/dev/null)"
[ "$TS_COUNT" = "None" ] && TS_COUNT=0
info ".ts segment count: ${TS_COUNT}"
[ "${TS_COUNT:-0}" -ge 1 ] && pass "the archive is .ts, satisfying the container requirement" \
                           || fail "no .ts objects found"

if [ "${TS_COUNT:-0}" -ge 1 ]; then
  KEY="$(aws s3api list-objects-v2 --bucket "$BUCKET" --region "$REGION" \
        --query "Contents[?ends_with(Key, '.ts')]|[0].Key" --output text)"
  SIZE="$(aws s3api head-object --bucket "$BUCKET" --key "$KEY" --region "$REGION" \
         --query ContentLength --output text)"
  echo ""
  echo "--- downloading one segment for inspection ---"
  info "key : $KEY"
  info "size: ${SIZE} bytes"
  LOCAL="$OUT/from-medialive.ts"
  aws s3 cp "s3://$BUCKET/$KEY" "$LOCAL" --region "$REGION" --quiet && info "downloaded to $(basename "$LOCAL")"

  echo ""
  echo "--- ffprobe on the MEDIALIVE-PRODUCED file ---"
  echo "    This is the payoff: not our local encode, but what the AWS encoder"
  echo "    actually wrote and S3 actually stored."
  echo ""
  ffprobe -hide_banner "$LOCAL" 2>&1 | grep -E 'Input|Duration|Stream' | sed 's/^/      /'
  echo ""

  P_CODEC="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$LOCAL" 2>/dev/null | tr -d '\r' | head -1)"
  P_W="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$LOCAL" 2>/dev/null | tr -d '\r' | head -1)"
  P_H="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$LOCAL" 2>/dev/null | tr -d '\r' | head -1)"
  P_ACODEC="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$LOCAL" 2>/dev/null | tr -d '\r' | head -1)"
  P_DUR="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$LOCAL" 2>/dev/null | tr -d '\r' | head -1)"
  P_FMT="$(ffprobe -v error -show_entries format=format_name -of default=nw=1:nk=1 "$LOCAL" 2>/dev/null | tr -d '\r' | head -1)"
  P_RATE="$(awk -v s="$SIZE" -v d="$P_DUR" 'BEGIN{if (d>0) printf "%.0f", (s*8)/d; else print 0}')"

  printf '      %-22s %s\n' "video codec"   "$P_CODEC"
  printf '      %-22s %sx%s\n' "resolution" "$P_W" "$P_H"
  printf '      %-22s %s\n' "audio codec"   "$P_ACODEC"
  printf '      %-22s %s\n' "container"     "$P_FMT"
  printf '      %-22s %s s\n' "duration"    "$P_DUR"
  printf '      %-22s %s bps\n' "measured bitrate" "$P_RATE"

  echo ""
  [ "$P_CODEC" = "hevc" ] && pass "MediaLive produced HEVC" || fail "codec is '$P_CODEC', not hevc"
  { [ "${P_W:-0}" -ge 1920 ] && [ "${P_H:-0}" -ge 1080 ]; } \
    && pass "resolution ${P_W}x${P_H} meets Full HD" || fail "resolution ${P_W}x${P_H}"
  [ "$P_ACODEC" = "aac" ] && pass "audio is AAC" || fail "audio codec is '$P_ACODEC'"
  echo "$P_FMT" | grep -q mpegts && pass "container is MPEG-TS" || fail "container is $P_FMT"
  # A segment can start mid-GOP, so its measured rate varies around the target.
  [ "${P_RATE:-0}" -ge 9000000 ] \
    && pass "measured segment bitrate ${P_RATE} bps is consistent with a 12 Mbps target" \
    || fail "measured ${P_RATE} bps is far below the target"

  # Everything above measures the envelope, and every one of those checks
  # passes on a feed that is entirely black - a blank picture encodes to valid
  # HEVC at the requested parameters like any other. Without this, the suite
  # can report a verified archive that carries nothing.
  echo ""
  if bash "$(dirname "${BASH_SOURCE[0]}")/picture-check.sh" "$LOCAL"; then
    pass "the archived segment carries a picture"
  else
    fail "the archived segment carries no picture - check the contribution source"
  fi
fi

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: S3 ARCHIVE VERIFIED" || echo "RESULT: FAILURES PRESENT"
exit "$RESULT"
