#!/usr/bin/env bash
# What OBS was configured to do, and what it reported doing.
#
# The profile and scene collection are placed by scripts/obs-configure.sh, so
# the encoder settings documented in the report are the settings OBS read off
# disk rather than a description of somebody's GUI.

set -uo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset MSYS_NO_PATHCONV

APPDATA_WIN="$(powershell.exe -NoProfile -NonInteractive -Command '$env:APPDATA' 2>/dev/null | tr -d '\r')"
OBS_ROOT="$(cygpath -u "$APPDATA_WIN")/obs-studio"
PROFILE="$OBS_ROOT/basic/profiles/Task06"
SCENES="$OBS_ROOT/basic/scenes/Task06.json"

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }

echo "=== OBS Studio as the contribution encoder ==="
echo ""
powershell.exe -NoProfile -NonInteractive -Command \
  "(Get-Item 'C:\Program Files\obs-studio\bin\64bit\obs64.exe').VersionInfo | Select-Object ProductName,ProductVersion | Format-List | Out-String" 2>/dev/null \
  | tr -d '\r' | grep -E '\S' | sed 's/^/    /'

echo ""
echo "--- the profile OBS reads, on disk ---"
echo "    $PROFILE"
ls -1 "$PROFILE" 2>/dev/null | sed 's/^/      /'

echo ""
echo "--- video and audio ---"
grep -E '^(BaseCX|BaseCY|OutputCX|OutputCY|FPSType|FPSCommon|ColorFormat|ColorSpace|ColorRange|SampleRate|ChannelSetup|Mode|Encoder|RecFormat2|Track1Bitrate)=' \
  "$PROFILE/basic.ini" 2>/dev/null | sed 's/^/      /'

echo ""
echo "--- the stream encoder, field by field ---"
sed 's/^/      /' "$PROFILE/streamEncoder.json" 2>/dev/null

echo ""
echo "--- the scene collection ---"
python -c "
import json,sys
d=json.load(open(r'$(cygpath -w "$SCENES")', encoding='utf-8'))
print('      collection : %s' % d.get('name'))
print('      scene      : %s' % d.get('current_program_scene'))
print('      canvas     : %sx%s' % (d['resolution']['x'], d['resolution']['y']))
for s in d.get('sources', []):
    if s.get('id') != 'scene':
        print('      source     : %s  (%s)' % (s.get('name'), s.get('id')))
" 2>/dev/null

echo ""
echo "--- what OBS logged while it ran ---"
LOGDIR="$OBS_ROOT/logs"
LATEST="$(ls -t "$LOGDIR"/*.txt 2>/dev/null | head -1)"
echo "      log: $(basename "$LATEST")"
echo ""
grep -E 'Connecting to RTMP|Connection to rtmp.*successful|Streaming Start|Recording Start|Writing file|video settings reset|audio settings reset|\[x264 encoder: .adv' \
  "$LATEST" 2>/dev/null | sed 's/^/      /' | head -20

echo ""
grep -qE 'Connection to rtmp.*successful' "$LATEST" 2>/dev/null \
  && pass "OBS connected to the MediaLive RTMP ingest" \
  || fail "no successful RTMP connection in the OBS log"
grep -q '==== Streaming Start' "$LATEST" 2>/dev/null \
  && pass "OBS started streaming" || fail "no streaming start recorded"
grep -q '==== Recording Start' "$LATEST" 2>/dev/null \
  && pass "OBS started recording locally" || fail "no recording start recorded"

echo ""
echo "--- output resolution and frame rate, from the OBS log ---"
grep -E 'base resolution|output resolution|fps:|video settings reset' -A4 "$LATEST" 2>/dev/null \
  | grep -E 'base resolution|output resolution|fps' | sed 's/^/      /' | head -6

echo ""
echo "    The contribution leg is H.264 over RTMP, because that is what"
echo "    MediaLive's RTMP input accepts. The channel decodes it and encodes"
echo "    HEVC into the ARCHIVE output group, so the .ts segments in S3 - the"
echo "    thing the task asks to record - are HEVC. See 06-s3-archive.log."

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: OBS CONTRIBUTION VERIFIED" || echo "RESULT: FAILURES PRESENT"
exit "$RESULT"
