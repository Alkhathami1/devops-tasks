#!/usr/bin/env bash
# Smoke test: a database-backed round trip through the reverse proxy.
#
# POSTs a uniquely named item through nginx, then GETs the collection back
# through nginx and asserts the row is present with the data that was written.
# This exercises every tier — proxy, backend, database — in one assertion.

set -uo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STACK_DIR"
export MSYS_NO_PATHCONV=1

HOST_PORT="$(grep -E '^HOST_PORT=' .env 2>/dev/null | cut -d= -f2)"
BASE="http://127.0.0.1:${HOST_PORT:-8080}"

FAILURES=0
check() {
  local label="$1" condition="$2" detail="${3:-}"
  if [ "$condition" = "0" ]; then
    printf '[PASS] %s%s\n' "$label" "${detail:+ -- $detail}"
  else
    printf '[FAIL] %s%s\n' "$label" "${detail:+ -- $detail}"
    FAILURES=$((FAILURES + 1))
  fi
}

echo "=== Smoke test: DB-backed round trip through the proxy ==="
echo "base URL: $BASE"
echo ""

# --- 1. The proxy itself -----------------------------------------------------
NGINX_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/healthz")
[ "$NGINX_STATUS" = "200" ]; check "nginx responds on /healthz" $? "HTTP $NGINX_STATUS"

# --- 2. The frontend it serves ----------------------------------------------
HTML=$(curl -s "$BASE/")
echo "$HTML" | grep -q "Multi-tier Docker stack"; check "frontend HTML served by nginx" $?

# --- 3. Backend health, proxied ---------------------------------------------
HEALTH=$(curl -s "$BASE/api-health")
echo "$HEALTH" | grep -q '"status":"ok"'; check "backend healthy through the proxy" $? "$HEALTH"
echo "$HEALTH" | grep -q '"reachable":true'; check "backend reports the database reachable" $?

# --- 4. WRITE through the proxy ---------------------------------------------
UNIQUE="smoke-$(date +%s)-$$"
CREATE=$(curl -s -X POST "$BASE/api/items" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"$UNIQUE\",\"description\":\"written by smoke-test.sh through nginx\"}")
CREATED_ID=$(echo "$CREATE" | grep -oE '"id":[0-9]+' | head -1 | cut -d: -f2)

[ -n "$CREATED_ID" ]; check "POST /api/items created a row" $? "id=$CREATED_ID"

# --- 5. READ it back through the proxy --------------------------------------
LIST=$(curl -s "$BASE/api/items")
echo "$LIST" | grep -q "$UNIQUE"; check "GET /api/items returns the written row" $? "name=$UNIQUE"
echo "$LIST" | grep -q "written by smoke-test.sh through nginx"; check "the written description round-tripped intact" $?

# --- 6. The seeded rows from the idempotent migration ------------------------
echo "$LIST" | grep -q '"name":"welcome"'; check "seeded row 'welcome' present" $?
echo "$LIST" | grep -q '"name":"persistence-probe"'; check "seeded row 'persistence-probe' present" $?

# --- 7. Validation is enforced ----------------------------------------------
BAD_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/items" \
  -H 'Content-Type: application/json' -d '{"description":"no name"}')
[ "$BAD_STATUS" = "400" ]; check "POST without a name is rejected" $? "HTTP $BAD_STATUS"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "RESULT: SMOKE TEST PASSED"
else
  echo "RESULT: $FAILURES CHECK(S) FAILED"
fi
exit "$FAILURES"
