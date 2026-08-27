#!/usr/bin/env bash
# Proves the network isolation claims rather than asserting them.
#
# Four things must hold:
#   1. Only nginx publishes a host port.
#   2. Postgres is NOT reachable from the host.
#   3. The backend is NOT reachable from the host, only through the proxy.
#   4. nginx cannot reach Postgres at all — it is not on internal-net.
#
# Point 4 is the one that matters most: 2 and 3 would also hold on a single
# shared network simply by not publishing ports. Only network membership stops
# a compromised nginx from talking to the database directly.

set -uo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STACK_DIR"
export MSYS_NO_PATHCONV=1

HOST_PORT="$(grep -E '^HOST_PORT=' .env 2>/dev/null | cut -d= -f2)"
HOST_PORT="${HOST_PORT:-8080}"

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

echo "=== Network isolation proof ==="
echo ""

# --- 1. Published ports ------------------------------------------------------
echo "--- 1. Which containers publish host ports ---"
docker compose ps --format 'table {{.Service}}\t{{.Publishers}}'
echo ""

PUBLISHED=$(docker ps --filter "label=com.docker.compose.project=task02" \
  --format '{{.Names}} {{.Ports}}' | grep -c '0.0.0.0' || true)
[ "$PUBLISHED" = "1" ]; check "exactly one container publishes a host port" $? "count=$PUBLISHED"

docker port task02-nginx 2>/dev/null | grep -q "$HOST_PORT"; check "nginx publishes $HOST_PORT" $?
[ -z "$(docker port task02-backend 2>/dev/null)" ]; check "backend publishes NO host port" $?
[ -z "$(docker port task02-postgres 2>/dev/null)" ]; check "postgres publishes NO host port" $?

# --- 2. Postgres unreachable from the host -----------------------------------
echo ""
echo "--- 2. Postgres from the host (must fail) ---"
# --connect-timeout bounds the wait; a filtered port would otherwise hang.
PG_FROM_HOST=$(curl -s --connect-timeout 5 "http://127.0.0.1:5432" 2>&1; echo "exit=$?")
echo "    curl 127.0.0.1:5432 -> $PG_FROM_HOST"
echo "$PG_FROM_HOST" | grep -qv 'exit=0'; check "host cannot open a connection to Postgres on 5432" $?

# --- 3. Backend unreachable from the host, reachable via the proxy -----------
echo ""
echo "--- 3. Backend from the host (must fail) vs through the proxy (must work) ---"
BACKEND_DIRECT=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://127.0.0.1:3000/health" 2>&1)
echo "    direct  127.0.0.1:3000/health -> '${BACKEND_DIRECT}' (empty/000 means refused)"
[ "$BACKEND_DIRECT" != "200" ]; check "backend NOT reachable directly from the host on 3000" $? "got '${BACKEND_DIRECT:-connection refused}'"

VIA_PROXY=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HOST_PORT}/api-health")
echo "    proxied 127.0.0.1:${HOST_PORT}/api-health -> $VIA_PROXY"
[ "$VIA_PROXY" = "200" ]; check "backend IS reachable through the proxy" $? "HTTP $VIA_PROXY"

# The chaos endpoint is served by the backend but not proxied, so it must 404
# at the edge even though it exists.
CHAOS_EDGE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${HOST_PORT}/internal/chaos/oom?confirm=yes")
[ "$CHAOS_EDGE" != "202" ]; check "backend /internal/* not exposed through the proxy" $? "HTTP $CHAOS_EDGE"

# --- 4. nginx cannot reach Postgres ------------------------------------------
echo ""
echo "--- 4. nginx -> postgres (must fail: nginx is not on internal-net) ---"
# getent hosts returns non-zero when the name does not resolve on any network
# this container is attached to.
NGINX_DNS=$(docker exec task02-nginx getent hosts postgres 2>&1; echo "exit=$?")
echo "    nginx resolving 'postgres' -> $NGINX_DNS"
echo "$NGINX_DNS" | grep -q 'exit=0' && DNS_OK=1 || DNS_OK=0
[ "$DNS_OK" = "0" ]; check "nginx cannot even resolve 'postgres'" $?

NGINX_TO_PG=$(docker exec task02-nginx timeout 5 wget -q -O- --timeout=3 "http://postgres:5432" 2>&1; echo "exit=$?")
echo "$NGINX_TO_PG" | grep -qv 'exit=0'; check "nginx cannot connect to postgres:5432" $?

# --- 5. Backend CAN reach Postgres (the one permitted path) ------------------
echo ""
echo "--- 5. backend -> postgres (must succeed: the one permitted path) ---"
BACKEND_TO_PG=$(docker exec task02-backend getent hosts postgres 2>&1)
echo "    backend resolving 'postgres' -> $BACKEND_TO_PG"
[ -n "$BACKEND_TO_PG" ]; check "backend resolves 'postgres' on internal-net" $?

# --- 6. internal-net has no route off the host -------------------------------
echo ""
echo "--- 6. internal-net egress (internal: true means no outbound route) ---"
PG_EGRESS=$(docker exec task02-postgres timeout 6 getent hosts example.com 2>&1; echo "exit=$?")
echo "    postgres resolving example.com -> $PG_EGRESS"
echo "$PG_EGRESS" | grep -qv '^exit=0'; check "postgres has no outbound internet route" $?

# --- 7. Network membership, from Docker itself -------------------------------
echo ""
echo "--- 7. docker network inspect: membership ---"
for net in task02-edge-net task02-internal-net; do
  echo "  $net:"
  docker network inspect "$net" --format '{{range .Containers}}    - {{.Name}}{{println}}{{end}}'
  echo "    internal: $(docker network inspect "$net" --format '{{.Internal}}')"
done

EDGE_MEMBERS=$(docker network inspect task02-edge-net --format '{{range .Containers}}{{.Name}} {{end}}')
INT_MEMBERS=$(docker network inspect task02-internal-net --format '{{range .Containers}}{{.Name}} {{end}}')

echo "$EDGE_MEMBERS" | grep -q 'task02-nginx';    check "nginx on edge-net" $?
echo "$EDGE_MEMBERS" | grep -q 'task02-backend';  check "backend on edge-net" $?
echo "$EDGE_MEMBERS" | grep -qv 'task02-postgres'; check "postgres NOT on edge-net" $?

echo "$INT_MEMBERS" | grep -q 'task02-backend';   check "backend on internal-net" $?
echo "$INT_MEMBERS" | grep -q 'task02-postgres';  check "postgres on internal-net" $?
echo "$INT_MEMBERS" | grep -qv 'task02-nginx';    check "nginx NOT on internal-net" $?

[ "$(docker network inspect task02-internal-net --format '{{.Internal}}')" = "true" ]
check "internal-net is marked internal: true" $?

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "RESULT: ISOLATION PROVEN - all checks passed"
else
  echo "RESULT: $FAILURES CHECK(S) FAILED"
fi
exit "$FAILURES"
