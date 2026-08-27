#!/usr/bin/env bash
# DRILL A — backend process failure and unattended recovery.
#
# This drill runs TWO scenarios, because the obvious one does not do what it
# appears to do:
#
#   A1. `docker kill` — an OPERATOR action. Docker records the container as
#       manually stopped, so `restart: unless-stopped` deliberately declines to
#       restart it. Exit 137, RestartCount stays 0. This is the policy behaving
#       correctly, and it is worth proving rather than assuming.
#
#   A2. PID 1 exits on its own — a genuine CRASH. The restart policy treats this
#       as an unexpected failure and restarts the container unattended. This is
#       the scenario the requirement is actually about.
#
# (A third approach, `kill -9 1` from inside the container, does nothing at all:
#  the kernel does not deliver uncatchable signals to PID 1 from within its own
#  PID namespace. Demonstrated in A0 below.)

set -uo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$STACK_DIR"
export MSYS_NO_PATHCONV=1

HOST_PORT="$(grep -E '^HOST_PORT=' .env 2>/dev/null | cut -d= -f2)"; HOST_PORT="${HOST_PORT:-8080}"
API="http://127.0.0.1:${HOST_PORT}"

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }

code_of() { curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-3}" "$1" 2>/dev/null || true; }

wait_healthy() {
  for _ in $(seq 1 120); do
    [ "$(code_of "$API/api-health" 2)" = "200" ] && return 0
    sleep 0.5
  done
  return 1
}

echo "=== DRILL A: backend failure and unattended recovery ==="
echo "restart policy: $(docker inspect task02-backend --format '{{.HostConfig.RestartPolicy.Name}}')"
echo ""

# ---------------------------------------------------------------------------
echo "--- A0. kill -9 against PID 1 from INSIDE the container ---"
echo "    (expected: no effect - PID 1 is signal-protected in its own namespace)"
A0_BEFORE_PID=$(docker inspect task02-backend --format '{{.State.Pid}}')
A0_BEFORE_RC=$(docker inspect task02-backend --format '{{.RestartCount}}')
docker exec task02-backend kill -9 1 2>&1 || true
sleep 3
A0_STATUS=$(docker inspect task02-backend --format '{{.State.Status}}')
A0_AFTER_PID=$(docker inspect task02-backend --format '{{.State.Pid}}')
echo "    status=$A0_STATUS  pid $A0_BEFORE_PID -> $A0_AFTER_PID  RestartCount=$A0_BEFORE_RC"
[ "$A0_STATUS" = "running" ] && [ "$A0_BEFORE_PID" = "$A0_AFTER_PID" ] \
  && pass "SIGKILL to PID 1 from inside was ignored, container untouched" \
  || fail "unexpected: container reacted to an in-namespace SIGKILL"

# ---------------------------------------------------------------------------
echo ""
echo "--- A1. docker kill (operator action) ---"
echo "    (expected: container stays down; unless-stopped honours operator intent)"
A1_RC_BEFORE=$(docker inspect task02-backend --format '{{.RestartCount}}')
docker kill task02-backend > /dev/null 2>&1
sleep 6
A1_STATUS=$(docker inspect task02-backend --format '{{.State.Status}}')
A1_EXIT=$(docker inspect task02-backend --format '{{.State.ExitCode}}')
A1_RC_AFTER=$(docker inspect task02-backend --format '{{.RestartCount}}')
echo "    status=$A1_STATUS  ExitCode=$A1_EXIT  RestartCount $A1_RC_BEFORE -> $A1_RC_AFTER"

DURING=$(code_of "$API/api-health" 3)
echo "    proxy -> backend while down: HTTP ${DURING:-000} (502/504 = genuinely gone)"

[ "$A1_STATUS" = "exited" ] && [ "$A1_EXIT" = "137" ] \
  && pass "docker kill stopped the container with SIGKILL (exit 137)" \
  || fail "unexpected state after docker kill: $A1_STATUS/$A1_EXIT"
[ "$A1_RC_AFTER" = "$A1_RC_BEFORE" ] \
  && pass "restart policy correctly did NOT fire for an operator stop" \
  || fail "restart policy fired for an operator stop, which contradicts unless-stopped"
[ "$DURING" != "200" ] \
  && pass "backend genuinely unreachable through the proxy during the outage" \
  || fail "backend still answering while supposedly killed"

echo ""
echo "    recovering with 'docker compose up -d' (the documented operator remedy)"
docker compose up -d --wait --wait-timeout 120 > /dev/null 2>&1
wait_healthy && pass "stack restored by a single compose command" || fail "did not recover"

# ---------------------------------------------------------------------------
echo ""
echo "--- A2. genuine crash: PID 1 exits non-zero ---"
echo "    (expected: restart policy fires, container returns with NO intervention)"

A2_RC_BEFORE=$(docker inspect task02-backend --format '{{.RestartCount}}')
A2_PID_BEFORE=$(docker inspect task02-backend --format '{{.State.Pid}}')
A2_START_BEFORE=$(docker inspect task02-backend --format '{{.State.StartedAt}}')
echo "    before: RestartCount=$A2_RC_BEFORE  hostPID=$A2_PID_BEFORE"
echo "            StartedAt=$A2_START_BEFORE"

# Triggered from another container on edge-net, because /internal is not proxied
# and the backend publishes no host port. nginx can reach it; the host cannot.
CRASH_EPOCH=$(date +%s%3N)
docker exec task02-nginx wget -q -O- --post-data='' \
  'http://backend:3000/internal/chaos/crash?confirm=yes&code=1' 2>&1 | head -1
echo "    crash requested at $(date '+%H:%M:%S.%3N')"

sleep 2
echo "    status right after crash: $(docker inspect task02-backend --format '{{.State.Status}}')"

if wait_healthy; then
  RECOVERED_EPOCH=$(date +%s%3N)
  DOWNTIME_MS=$((RECOVERED_EPOCH - CRASH_EPOCH))
else
  DOWNTIME_MS=""
fi

A2_RC_AFTER=$(docker inspect task02-backend --format '{{.RestartCount}}')
A2_PID_AFTER=$(docker inspect task02-backend --format '{{.State.Pid}}')
A2_START_AFTER=$(docker inspect task02-backend --format '{{.State.StartedAt}}')

echo ""
echo "    after:  RestartCount=$A2_RC_AFTER  hostPID=$A2_PID_AFTER"
echo "            StartedAt=$A2_START_AFTER"
echo "            status=$(docker inspect task02-backend --format '{{.State.Status}}')  health=$(docker inspect task02-backend --format '{{.State.Health.Status}}')"
[ -n "$DOWNTIME_MS" ] && echo "            MEASURED DOWNTIME: ${DOWNTIME_MS} ms (crash -> HTTP 200 through the proxy)"

echo ""
[ "$A2_RC_AFTER" -gt "$A2_RC_BEFORE" ] \
  && pass "RestartCount incremented $A2_RC_BEFORE -> $A2_RC_AFTER" \
  || fail "RestartCount did not increment"
[ "$A2_PID_AFTER" != "$A2_PID_BEFORE" ] \
  && pass "new host PID ($A2_PID_BEFORE -> $A2_PID_AFTER): a genuinely new process" \
  || fail "PID unchanged"
[ "$A2_START_AFTER" != "$A2_START_BEFORE" ] \
  && pass "StartedAt advanced, confirming a real restart" \
  || fail "StartedAt unchanged"
[ -n "$DOWNTIME_MS" ] \
  && pass "recovered unattended in ${DOWNTIME_MS} ms" \
  || fail "did not recover within 60s"

# The data tier must be untouched by a backend crash.
ITEMS=$(curl -s "$API/api/items" | grep -oE '"count":[0-9]+' | cut -d: -f2)
[ -n "$ITEMS" ] && pass "database still serving after recovery: $ITEMS rows" || fail "rows not readable"

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: DRILL A PASSED" || echo "RESULT: DRILL A FAILED"
exit "$RESULT"
