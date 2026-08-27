#!/usr/bin/env bash
# One command runs every check for Task 02.
#
#   scripts/verify.sh            # everything
#   scripts/verify.sh --quick    # skip the slow/destructive drills
#
# Ordering matters. The non-destructive checks run first so a failure there is
# not confused with damage done by a drill. The daemon restart runs LAST because
# it disrupts the engine everything else depends on.

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
  local code=$?
  NAMES+=("$name")
  CODES+=("$code")
  return 0
}

echo "=== Task 02 verification suite ==="
echo "started: $(date '+%Y-%m-%d %H:%M:%S %z')"
[ "$QUICK" = "1" ] && echo "mode   : quick (destructive drills skipped)"

# Make sure the stack is up before anything else. Idempotent.
run "0. Bring the stack up (idempotent)"      ./scripts/up.sh
run "1. Smoke test (DB round trip via proxy)" ./scripts/smoke-test.sh
run "2. Network isolation proof"              ./scripts/isolation-check.sh
run "3. Resource allocation"                  ./scripts/resources.sh
run "4. Secrets: env var vs file secret"      ./scripts/drills/05-secrets-comparison.sh

if [ "$QUICK" = "0" ]; then
  run "5. DRILL A: crash and restart policy"  ./scripts/drills/01-backend-kill.sh
  run "6. DRILL B: RAM exhaustion / OOM kill" ./scripts/drills/02-oom-kill.sh
  run "7. DRILL E: database failure"          ./scripts/drills/04-db-failure.sh
  run "8. DRILL D: data persistence"          ./scripts/drills/03-persistence.sh
  # Last: restarting the daemon disrupts everything above.
  run "9. DRILL C: daemon restart"            ./scripts/drills/06-daemon-restart.sh
fi

echo ""
echo "################################################################"
echo "# SUMMARY"
echo "################################################################"
echo ""
printf '    %-42s %s\n' "CHECK" "RESULT"
printf '    %-42s %s\n' "------------------------------------------" "------"
FAILED=0
for i in "${!NAMES[@]}"; do
  if [ "${CODES[$i]}" = "0" ]; then
    printf '    %-42s %s\n' "${NAMES[$i]}" "PASS"
  else
    printf '    %-42s %s\n' "${NAMES[$i]}" "FAIL (exit ${CODES[$i]})"
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
