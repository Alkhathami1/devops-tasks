#!/usr/bin/env bash
# Run a command and append a timestamped, verbatim record of it to an evidence log.
#
#   scripts/run-with-evidence.sh <evidence-name> <label> -- <command...>
#
# Example:
#   scripts/run-with-evidence.sh 04-unit-tests "planner unit tests" -- \
#       node --test test/*.test.js
#
# Writes to docs/evidence/<evidence-name>.log. The command's stdout and stderr
# are interleaved and captured in full, along with its exit code. The exit code
# of this script mirrors the wrapped command's, so a failing verification stays
# visibly failing instead of being laundered into a pass.
#
# ENCODING
# --------
# Evidence logs are UTF-8 with a BOM, and ANSI escape sequences are stripped.
#
# The BOM is there for Windows readers. Test runners emit UTF-8 symbols
# (U+25B6 "\xe2\x96\xb6", U+2714, U+2139); without a BOM, PowerShell 5.1's
# Get-Content and Notepad decode the file as the ANSI code page and render
# those bytes as mojibake ("a-tilde, en-dash, paragraph"). A BOM makes every
# common Windows tool detect UTF-8 correctly. It is written once, when the
# file is created, never on append.
#
# ANSI colour codes are stripped because a log is read as text and pasted into
# a report; raw escape sequences are noise there. NO_COLOR/FORCE_COLOR are also
# exported so most tools never emit them in the first place.

set -uo pipefail

if [ "$#" -lt 4 ]; then
  echo "usage: $0 <evidence-name> <label> -- <command...>" >&2
  exit 2
fi

EVIDENCE_NAME="$1"; shift
LABEL="$1"; shift
if [ "$1" != "--" ]; then
  echo "error: expected '--' before the command" >&2
  exit 2
fi
shift

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_DIR="$REPO_ROOT/docs/evidence"
LOG="$EVIDENCE_DIR/${EVIDENCE_NAME}.log"
mkdir -p "$EVIDENCE_DIR"

# Ask tools for UTF-8 and no colour.
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"
export NO_COLOR=1
export FORCE_COLOR=0

# UTF-8 BOM on creation only.
if [ ! -s "$LOG" ]; then
  printf '\xef\xbb\xbf' > "$LOG"
fi

{
  printf -- '----------------------------------------------------------------\n'
  printf '### %s\n' "$LABEL"
  printf 'COMMAND   : %s\n' "$*"
  printf 'CWD       : %s\n' "$(pwd)"
  printf 'TIMESTAMP : %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
  printf -- '----------------------------------------------------------------\n'
} >> "$LOG"

# Capture to a temp file so the wrapped command's exit code is preserved
# exactly (a pipeline would report the last stage's status instead).
#
# The variable is deliberately NOT called TMP. On Windows, TMP is already an
# exported environment variable naming the temp DIRECTORY; assigning a file path
# to it silently corrupts every Windows child process that resolves its temp
# directory from the environment. `docker compose build` fails with
# "invalid output path: stat <file>: The system cannot find the path specified".
# The same applies to TEMP and TMPDIR.
CAPTURE_FILE="$(mktemp)"
trap 'rm -f "$CAPTURE_FILE"' EXIT

set +e
# stdin is closed. Tools that read it when idle - ffmpeg most notoriously -
# otherwise consume whatever the caller had attached, starving every later
# command in the same script and producing empty output rather than errors.
"$@" > "$CAPTURE_FILE" 2>&1 < /dev/null
STATUS=$?
set -e

# Strip ANSI escape sequences (CSI and simple two-byte forms) and CR line
# endings, run the result through the identity redactor, then echo to the
# terminal and append to the log.
#
# REDACTION IS PART OF THE CAPTURE PATH, not a step a human remembers. An
# earlier preflight log published a GCP billing account id and a work email
# because the redactor existed but nothing forced output through it. It runs
# in `identity` mode: the blanket 12-digit rule is destructive to legitimate
# output (disk byte counts, sha256 fragments) and is reserved for manual use.
REDACTOR="$REPO_ROOT/scripts/redact.sh"
sed -e 's/\x1b\[[0-9;?]*[ -/]*[@-~]//g' -e 's/\x1b[@-Z\\-_]//g' -e 's/\r$//' "$CAPTURE_FILE" \
  | { if [ -x "$REDACTOR" ]; then REDACT_MODE=identity "$REDACTOR"; else cat; fi; } \
  | tee -a "$LOG"

{
  printf 'EXIT CODE : %s\n' "$STATUS"
  printf '\n'
} >> "$LOG"

exit "$STATUS"
