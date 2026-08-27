#!/usr/bin/env bash
# DRILL E — the database dies underneath a running backend.
#
# The question this answers is not "does it break" but "does it LIE". A health
# endpoint that keeps returning 200 while its only datastore is unreachable will
# keep an orchestrator routing traffic to a backend that cannot serve it, and
# will keep a load balancer's pool full of useless members.
#
# Checks, in order:
#   1. /health degrades honestly to 503 while Postgres is down
#   2. the API returns a truthful error rather than a wrong answer
#   3. nginx stays up and serves the frontend regardless
#   4. the backend reconnects on its own when Postgres returns

set -uo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$STACK_DIR"
export MSYS_NO_PATHCONV=1

HOST_PORT="$(grep -E '^HOST_PORT=' .env 2>/dev/null | cut -d= -f2)"; HOST_PORT="${HOST_PORT:-8080}"
API="http://127.0.0.1:${HOST_PORT}"

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }
code_of() { curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-6}" "$1" 2>/dev/null || true; }

echo "=== DRILL E: Postgres killed under a running backend ==="
echo ""

echo "--- baseline ---"
echo "    /api-health : $(code_of "$API/api-health")"
echo "    body        : $(curl -s --max-time 5 "$API/api-health")"
BACKEND_RC_BEFORE=$(docker inspect task02-backend --format '{{.RestartCount}}')
echo "    backend RestartCount: $BACKEND_RC_BEFORE"

echo ""
echo "--- stopping Postgres ---"
# `stop` rather than `kill`: an operator stop guarantees it stays down for the
# observation window instead of being restarted underneath the measurement.
docker compose stop postgres > /dev/null 2>&1
echo "    postgres status: $(docker inspect task02-postgres --format '{{.State.Status}}')"
sleep 3

echo ""
echo "--- behaviour while the database is down ---"
# Body and status MUST come from the SAME request. Issuing two separate curls
# lets a slow probe answer one and time out on the other, so a 504 body can be
# reported alongside a 503 status from a different attempt.
HEALTH_RAW=$(curl -s -w '\n%{http_code}' --max-time 10 "$API/api-health" 2>/dev/null || true)
HEALTH_CODE=$(printf '%s' "$HEALTH_RAW" | tail -n1)
HEALTH_BODY=$(printf '%s' "$HEALTH_RAW" | sed '$d')
echo "    /api-health -> HTTP $HEALTH_CODE"
echo "    body: $HEALTH_BODY"

# Distinguish the backend answering honestly from nginx giving up on it. Both
# are non-200, but only one demonstrates that the APPLICATION degrades honestly.
if printf '%s' "$HEALTH_BODY" | grep -q '504 Gateway Time-out'; then
  fail "nginx timed out waiting for /health; the probe is too slow to be useful"
else
  pass "the response came from the backend itself, not an nginx timeout page"
fi

HEALTH_MS=$(curl -s -o /dev/null -w "%{time_total}" --max-time 10 "$API/api-health" 2>/dev/null)
echo "    /api-health response time while DB is down: ${HEALTH_MS}s"

[ "$HEALTH_CODE" = "503" ] \
  && pass "health degraded honestly to 503 instead of claiming to be fine" \
  || fail "health returned $HEALTH_CODE while the database was down"

echo "$HEALTH_BODY" | grep -q '"status":"degraded"' \
  && pass "body reports status=degraded" || fail "body does not report degradation"
echo "$HEALTH_BODY" | grep -q '"reachable":false' \
  && pass "body reports the database as unreachable" || fail "body does not flag the database"

ITEMS_CODE=$(code_of "$API/api/items" 10)
ITEMS_BODY=$(curl -s --max-time 10 "$API/api/items")
echo ""
echo "    /api/items -> HTTP $ITEMS_CODE"
echo "    body: $(echo "$ITEMS_BODY" | head -c 200)"
[ "$ITEMS_CODE" = "503" ] \
  && pass "API returns 503 rather than an empty list that would look like 'no data'" \
  || fail "API returned $ITEMS_CODE; an empty 200 would be a silent lie"

echo ""
echo "--- the proxy tier is unaffected ---"
NGINX_CODE=$(code_of "$API/healthz")
FRONTEND_CODE=$(code_of "$API/")
echo "    nginx /healthz -> HTTP $NGINX_CODE"
echo "    frontend /     -> HTTP $FRONTEND_CODE"
[ "$NGINX_CODE" = "200" ] && pass "nginx still healthy and serving" || fail "nginx affected by the database outage"
[ "$FRONTEND_CODE" = "200" ] && pass "static frontend still served during the outage" || fail "frontend unavailable"

echo ""
echo "--- did the backend survive, or crash-loop? ---"
BACKEND_STATUS=$(docker inspect task02-backend --format '{{.State.Status}}')
BACKEND_RC_DURING=$(docker inspect task02-backend --format '{{.RestartCount}}')
echo "    backend status      : $BACKEND_STATUS"
echo "    backend RestartCount: $BACKEND_RC_BEFORE -> $BACKEND_RC_DURING"
[ "$BACKEND_STATUS" = "running" ] \
  && pass "backend stayed up and kept serving truthful errors" \
  || fail "backend fell over when its dependency did"
[ "$BACKEND_RC_DURING" = "$BACKEND_RC_BEFORE" ] \
  && pass "no crash-loop: the pool error handler kept the process alive" \
  || fail "backend restarted $((BACKEND_RC_DURING - BACKEND_RC_BEFORE)) time(s), i.e. it crash-looped"

echo ""
echo "--- restarting Postgres ---"
RESTART_EPOCH=$(date +%s%3N)
docker compose start postgres > /dev/null 2>&1

RECOVERED=""
for _ in $(seq 1 120); do
  if [ "$(code_of "$API/api-health" 3)" = "200" ]; then RECOVERED=$(date +%s%3N); break; fi
  sleep 0.5
done

echo ""
echo "--- after recovery ---"
echo "    /api-health -> HTTP $(code_of "$API/api-health")"
echo "    body: $(curl -s --max-time 5 "$API/api-health")"
BACKEND_RC_AFTER=$(docker inspect task02-backend --format '{{.RestartCount}}')
echo "    backend RestartCount: $BACKEND_RC_AFTER (unchanged means it reconnected without restarting)"

if [ -n "$RECOVERED" ]; then
  echo "    reconnect time: $((RECOVERED - RESTART_EPOCH)) ms from 'compose start' to HTTP 200"
  pass "backend reconnected to Postgres automatically"
else
  fail "backend did not recover after Postgres returned"
fi

[ "$BACKEND_RC_AFTER" = "$BACKEND_RC_BEFORE" ] \
  && pass "reconnected via the connection pool, with no container restart" \
  || echo "[INFO] backend restarted during the drill (RestartCount $BACKEND_RC_BEFORE -> $BACKEND_RC_AFTER)"

ITEMS=$(curl -s "$API/api/items" | grep -oE '"count":[0-9]+' | cut -d: -f2)
[ -n "$ITEMS" ] && pass "data intact after the outage: $ITEMS rows" || fail "data not readable"

# ---------------------------------------------------------------------------
echo ""
echo "--- E2. backend STARTED while the database is already down ---"
echo "    This exercises the application-level retry loop, which is the safety"
echo "    net for cold starts. It matters because depends_on/service_healthy is"
echo "    a Compose-time construct: when the DAEMON restarts, containers are"
echo "    started by restart policy in arbitrary order and the dependency"
echo "    ordering is NOT replayed. Without this loop, a backend that wins the"
echo "    race against Postgres would crash-loop."

docker compose stop postgres > /dev/null 2>&1
docker compose restart backend > /dev/null 2>&1
sleep 6

echo ""
echo "    backend logs while its dependency is absent:"
docker logs --tail 6 task02-backend 2>&1 | sed 's/^/      /'

RETRIES=$(docker logs task02-backend 2>&1 | grep -c '"event":"db.waiting"' || true)
echo ""
echo "    db.waiting retry events observed: $RETRIES"
[ "$RETRIES" -gt 0 ] \
  && pass "the retry loop is genuinely exercised, not merely present in the source" \
  || fail "expected retry events but saw none"

BACKEND_UP=$(docker inspect task02-backend --format '{{.State.Status}}')
echo "    backend status while waiting: $BACKEND_UP"
[ "$BACKEND_UP" = "running" ] \
  && pass "backend waits patiently instead of crash-looping" \
  || fail "backend is $BACKEND_UP"

echo ""
echo "    bringing Postgres back:"
docker compose start postgres > /dev/null 2>&1
for _ in $(seq 1 120); do
  [ "$(code_of "$API/api-health" 3)" = "200" ] && break
  sleep 0.5
done
docker logs --tail 4 task02-backend 2>&1 | sed 's/^/      /'
[ "$(code_of "$API/api-health")" = "200" ] \
  && pass "backend connected as soon as Postgres returned, with no restart" \
  || fail "backend did not recover"

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: DRILL E PASSED" || echo "RESULT: DRILL E FAILED"
exit "$RESULT"
