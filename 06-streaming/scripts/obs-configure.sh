#!/usr/bin/env bash
# Install the Task 06 OBS profile and scene collection, and point OBS at them.
#
#   scripts/obs-configure.sh <rtmp-destination-url>
#
# OBS keeps a profile as a directory of ini and json files and a scene
# collection as a single json file, both under %APPDATA%\obs-studio. Selecting
# them is four keys in global.ini. Nothing here needs the GUI, which is what
# makes the encoder settings in the report reproducible rather than a
# screenshot of somebody's preferences.
#
# The settings themselves live in configs/obs/ and are copied in verbatim, so
# the file the report documents is the file OBS reads.

set -uo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$STACK_DIR/configs/obs"
NAME="Task06"

DEST_URL="${1:-}"
if [ -z "$DEST_URL" ]; then
  echo "usage: $0 <rtmp-destination-url>" >&2
  exit 2
fi

# MediaLive hands back one URL carrying both halves; OBS wants them split, with
# everything up to the last path element as the server and the last element as
# the stream key.
RTMP_SERVER="${DEST_URL%/*}"
RTMP_KEY="${DEST_URL##*/}"

APPDATA_WIN="$(powershell.exe -NoProfile -NonInteractive -Command '$env:APPDATA' 2>/dev/null | tr -d '\r')"
OBS_ROOT="$(cygpath -u "$APPDATA_WIN")/obs-studio"
PROFILE_DIR="$OBS_ROOT/basic/profiles/$NAME"
SCENES_DIR="$OBS_ROOT/basic/scenes"
REC_DIR_WIN='C:\Users\abual\obs-recordings'

mkdir -p "$PROFILE_DIR" "$SCENES_DIR"
mkdir -p "$(cygpath -u "$REC_DIR_WIN")"

echo "=== Installing the OBS profile and scene collection ==="
echo ""
echo "    OBS config root : $OBS_ROOT"
echo "    profile         : $PROFILE_DIR"
echo "    scene collection: $SCENES_DIR/$NAME.json"
echo "    recordings      : $REC_DIR_WIN  (outside the repository)"
echo ""

cp "$SRC/basic.ini"           "$PROFILE_DIR/basic.ini"
cp "$SRC/streamEncoder.json"  "$PROFILE_DIR/streamEncoder.json"
cp "$SRC/recordEncoder.json"  "$PROFILE_DIR/recordEncoder.json"
cp "$SRC/$NAME.json"          "$SCENES_DIR/$NAME.json"

# Recording target, appended to the profile OBS will read.
{
  echo ""
  echo "RecFilePath=$REC_DIR_WIN"
  echo "RecFilePathCCP=$REC_DIR_WIN"
} >> "$PROFILE_DIR/basic.ini"

# The stream destination. Written here rather than committed, because it names
# a live ingest endpoint that exists only while the channel does.
cat > "$PROFILE_DIR/service.json" <<JSON
{
    "type": "rtmp_custom",
    "settings": {
        "server": "$RTMP_SERVER",
        "key": "$RTMP_KEY",
        "use_auth": false,
        "bwtest": false
    }
}
JSON

# Select the profile and collection, and skip the first-run wizard so a launch
# with --startstreaming goes straight to work.
cat > "$OBS_ROOT/global.ini" <<INI
[General]
FirstRun=true
LastVersion=503382273
ConfirmOnExit=false

[Basic]
Profile=$NAME
ProfileDir=$NAME
SceneCollection=$NAME
SceneCollectionFile=$NAME
INI

echo "--- profile contents ---"
ls -1 "$PROFILE_DIR" | sed 's/^/      /'
echo ""
echo "--- video and audio, as OBS will read them ---"
grep -E '^(BaseCX|BaseCY|OutputCX|OutputCY|FPSCommon|SampleRate|Track1Bitrate|Mode|Encoder|RecFormat2)=' \
  "$PROFILE_DIR/basic.ini" | sed 's/^/      /'
echo ""
echo "--- stream encoder ---"
sed 's/^/      /' "$PROFILE_DIR/streamEncoder.json"
echo ""
echo "--- destination ---"
echo "      server: $RTMP_SERVER"
echo "      key   : $RTMP_KEY"
echo ""
echo "RESULT: OBS CONFIGURED"
