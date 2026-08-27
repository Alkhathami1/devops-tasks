#!/usr/bin/env bash
# Run every Task 01 check in order.
#
#   scripts/verify.sh

set -uo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STACK_DIR"
export MSYS_NO_PATHCONV=1

declare -a NAMES=() CODES=()
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

echo "=== Task 01 verification suite ==="
echo "started: $(date '+%Y-%m-%d %H:%M:%S %z')"

# ORDER MATTERS. Direction A mounts the Windows share, and monitoring and
# alerting both assert against that mount. Running monitoring first reports
# "no filesystem series for the SMB share", which is a true statement about a
# share that has not been mounted yet rather than a monitoring defect. The
# mount has to exist before anything can observe it.
run "0. Bring up (idempotent)"                 ./scripts/up.sh
run "1. XFS: 1 TB single-file capability"      ./scripts/xfs-demo.sh
run "2. SMB3 mount mechanics"                  ./scripts/smb-mount.sh
run "3. Direction A: Windows share -> Linux"   ./scripts/direction-a.sh
run "4. Persistence across reboots"            ./scripts/persistence.sh
run "5. Monitoring"                            ./scripts/monitoring.sh
run "6. Alerting (drives alerts to firing)"    ./scripts/alerts-fire.sh
run "7. Direction B: Linux share -> Windows"   ./scripts/direction-b.sh

echo ""
echo "################################################################"
echo "# SUMMARY"
echo "################################################################"
echo ""
printf '    %-46s %s\n' "CHECK" "RESULT"
printf '    %-46s %s\n' "----------------------------------------------" "------"
FAILED=0; NOTED=0
for i in "${!NAMES[@]}"; do
  case "${CODES[$i]}" in
    0) printf '    %-46s %s\n' "${NAMES[$i]}" "PASS" ;;
    2) printf '    %-46s %s
' "${NAMES[$i]}" "SERVER VERIFIED"; NOTED=$((NOTED+1)) ;;
    *) printf '    %-46s %s\n' "${NAMES[$i]}" "FAIL (exit ${CODES[$i]})"; FAILED=$((FAILED+1)) ;;
  esac
done

echo ""
echo "    Exit code 2 marks a check whose server side is verified here and"
echo "    whose client-side procedure is documented in the README."
echo ""
echo "finished: $(date '+%Y-%m-%d %H:%M:%S %z')"
if [ "$FAILED" -eq 0 ]; then
  echo "RESULT: ${#NAMES[@]} checks, 0 failures"
else
  echo "RESULT: $FAILED of ${#NAMES[@]} CHECKS FAILED"
fi
exit "$FAILED"
