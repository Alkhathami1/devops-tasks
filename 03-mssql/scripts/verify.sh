#!/usr/bin/env bash
# One command runs every check for Task 03.
#
#   scripts/verify.sh            # everything, including the destructive drills
#   scripts/verify.sh --quick    # non-destructive checks only
#
# Ordering is deliberate: the non-destructive checks run first, so a failure
# there is never confused with damage a drill caused on purpose.

set -uo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STACK_DIR"
export MSYS_NO_PATHCONV=1

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

declare -a NAMES=()
declare -a CODES=()

run() {
  local name="$1"; shift
  echo ""
  echo "################################################################"
  echo "# $name"
  echo "################################################################"
  "$@"
  # Capture the status IMMEDIATELY. Writing NAMES+=(...) first and then reading
  # $? records the exit status of the array append, which is always 0 - the
  # summary can then never report a failure no matter what happened.
  local code=$?
  NAMES+=("$name"); CODES+=("$code")
  return 0
}

echo "=== Task 03 verification suite ==="
echo "started: $(date '+%Y-%m-%d %H:%M:%S %z')"
[ "$QUICK" = "1" ] && echo "mode   : quick (destructive drills skipped)"

run "0. Bring up, schema and seed (idempotent)" ./scripts/up.sh
run "1. Schema and data inventory"              ./scripts/checks/schema-report.sh
run "2. SQL Server Agent availability"          ./scripts/checks/agent-availability.sh
run "3. Backup tiers, verification, retention"  ./scripts/drills/03-backup-tiers.sh

if [ "$QUICK" = "0" ]; then
  run "4. DRILL: destroy and restore round trip" ./scripts/drills/01-restore-roundtrip.sh
  run "5. DRILL: point-in-time recovery"         ./scripts/drills/02-point-in-time.sh
fi

echo ""
echo "################################################################"
echo "# SUMMARY"
echo "################################################################"
echo ""
printf '    %-46s %s\n' "CHECK" "RESULT"
printf '    %-46s %s\n' "----------------------------------------------" "------"
FAILED=0
for i in "${!NAMES[@]}"; do
  if [ "${CODES[$i]}" = "0" ]; then
    printf '    %-46s %s\n' "${NAMES[$i]}" "PASS"
  else
    printf '    %-46s %s\n' "${NAMES[$i]}" "FAIL (exit ${CODES[$i]})"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "finished: $(date '+%Y-%m-%d %H:%M:%S %z')"
if [ "$FAILED" -eq 0 ]; then
  echo "RESULT: ALL ${#NAMES[@]} CHECKS PASSED"
else
  echo "RESULT: $FAILED of ${#NAMES[@]} CHECKS FAILED"
fi
exit "$FAILED"
