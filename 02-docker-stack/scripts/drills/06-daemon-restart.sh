#!/usr/bin/env bash
# DRILL C — machine shutdown / daemon restart.
#
# The closest faithful simulation of "the machine was shut down" available
# without actually rebooting the host: the Docker daemon is stopped and started,
# which tears down every running container and brings the engine back cold.
#
# The requirement is that the stack returns with NO human intervention. This
# script therefore never runs `docker compose up` after the restart — if the
# stack comes back, it is the restart policies doing it.
#
# Note `Live Restore` is disabled on this engine, so containers genuinely stop
# when the daemon does; they are not simply handed back still running.

set -uo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$STACK_DIR"
export MSYS_NO_PATHCONV=1

HOST_PORT="$(grep -E '^HOST_PORT=' .env 2>/dev/null | cut -d= -f2)"; HOST_PORT="${HOST_PORT:-8080}"
API="http://127.0.0.1:${HOST_PORT}"

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }

echo "=== DRILL C: Docker daemon restart (machine shutdown analogue) ==="
echo ""

echo "--- engine configuration ---"
echo "    Live Restore Enabled: $(docker info --format '{{.LiveRestoreEnabled}}')"
echo "    (false = containers really stop with the daemon, so recovery is genuine)"

echo ""
echo "--- state before ---"
docker ps --format '    {{.Names}} | {{.Status}}'
for c in task02-postgres task02-backend task02-nginx; do
  echo "    ${c#task02-}: policy=$(docker inspect "$c" --format '{{.HostConfig.RestartPolicy.Name}}') restarts=$(docker inspect "$c" --format '{{.RestartCount}}')"
done

# A marker row, to prove the data volume survives a cold engine restart.
MARKER="daemon-restart-$(date +%s)"
curl -s -X POST "$API/api/items" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$MARKER\",\"description\":\"written before the daemon was restarted\"}" > /dev/null
BEFORE_COUNT=$(curl -s "$API/api/items" | grep -oE '"count":[0-9]+' | cut -d: -f2)
echo "    marker row written: $MARKER"
echo "    row count before  : $BEFORE_COUNT"

echo ""
echo "--- restarting the Docker daemon ---"
echo "    NOTE: no 'docker compose up' is issued after this point."
RESTART_EPOCH=$(date +%s)
docker desktop restart 2>&1 | sed 's/^/    /'

echo ""
echo "--- waiting for the daemon to come back ---"
DAEMON_BACK=""
for i in $(seq 1 180); do
  if docker info > /dev/null 2>&1; then
    DAEMON_BACK=$(date +%s)
    echo "    daemon responding after $((DAEMON_BACK - RESTART_EPOCH))s"
    break
  fi
  sleep 2
done
[ -n "$DAEMON_BACK" ] && pass "Docker daemon came back" || { fail "daemon did not return"; exit 1; }

echo ""
echo "--- waiting for the stack to return UNATTENDED ---"
STACK_BACK=""
for i in $(seq 1 180); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$API/api-health" 2>/dev/null || true)
  if [ "$CODE" = "200" ]; then
    STACK_BACK=$(date +%s)
    echo "    stack serving again after $((STACK_BACK - RESTART_EPOCH))s total"
    break
  fi
  if [ $((i % 10)) -eq 0 ]; then
    echo "    t+$(( $(date +%s) - RESTART_EPOCH ))s: still waiting (last HTTP ${CODE:-000})"
  fi
  sleep 2
done

echo ""
echo "--- state after ---"
docker ps --format '    {{.Names}} | {{.Status}}'

if [ -n "$STACK_BACK" ]; then
  pass "whole stack recovered with no human intervention in $((STACK_BACK - RESTART_EPOCH))s"
else
  fail "stack did not return within the timeout"
fi

RUNNING=$(docker ps --filter 'label=com.docker.compose.project=task02' --format '{{.Names}}' | wc -l)
[ "$RUNNING" = "3" ] && pass "all three services are running again ($RUNNING/3)" || fail "only $RUNNING/3 running"

echo ""
echo "--- did the data survive a cold engine restart? ---"
AFTER_COUNT=$(curl -s "$API/api/items" | grep -oE '"count":[0-9]+' | cut -d: -f2)
FOUND=$(curl -s "$API/api/items" | grep -c "$MARKER" || true)
echo "    row count after: $AFTER_COUNT (was $BEFORE_COUNT)"
echo "    marker present : $FOUND"
[ "$AFTER_COUNT" = "$BEFORE_COUNT" ] && pass "row count preserved across the daemon restart" || fail "rows changed: $BEFORE_COUNT -> $AFTER_COUNT"
[ "$FOUND" -ge 1 ] && pass "marker row survived: $MARKER" || fail "marker row lost"

echo ""
echo "--- end-to-end through the proxy after recovery ---"
SMOKE_NAME="post-restart-$(date +%s)"
CREATED=$(curl -s -X POST "$API/api/items" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$SMOKE_NAME\",\"description\":\"written after the daemon restart\"}")
echo "    POST -> $(echo "$CREATED" | head -c 120)"
echo "$CREATED" | grep -q '"id"' && pass "writes work again through the full stack" || fail "cannot write after recovery"

echo ""
echo "--- ordering was still respected on cold start ---"
for c in task02-postgres task02-backend task02-nginx; do
  echo "    ${c#task02-}: health=$(docker inspect "$c" --format '{{.State.Health.Status}}') startedAt=$(docker inspect "$c" --format '{{.State.StartedAt}}')"
done
echo "    (backend depends_on postgres:service_healthy, nginx on backend:service_healthy;"
echo "     a backend that outran Postgres would show up as a crash-loop here)"

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: DRILL C PASSED" || echo "RESULT: DRILL C FAILED"
exit "$RESULT"
