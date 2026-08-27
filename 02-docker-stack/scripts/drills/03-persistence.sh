#!/usr/bin/env bash
# DRILL D — data persistence across a full stack teardown.
#
# Two distinct behaviours, frequently confused, and the difference is the
# difference between a routine restart and permanent data loss:
#
#   `docker compose down`     removes containers and networks. Named volumes
#                             are left alone, so the database survives.
#   `docker compose down -v`  ALSO removes named volumes. The database is gone.
#
# This drill proves both halves, in that order.

set -uo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$STACK_DIR"
export MSYS_NO_PATHCONV=1

HOST_PORT="$(grep -E '^HOST_PORT=' .env 2>/dev/null | cut -d= -f2)"; HOST_PORT="${HOST_PORT:-8080}"
API="http://127.0.0.1:${HOST_PORT}"

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }

count_items() { curl -s --max-time 5 "$API/api/items" | grep -oE '"count":[0-9]+' | cut -d: -f2; }
wait_healthy() {
  for _ in $(seq 1 120); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$API/api-health" 2>/dev/null)" = "200" ] && return 0
    sleep 1
  done
  return 1
}

echo "=== DRILL D: data persistence ==="
echo ""

echo "--- volume configuration ---"
docker volume inspect task02-pgdata --format '    name={{.Name}} driver={{.Driver}} mountpoint={{.Mountpoint}}' 2>/dev/null
echo "    mounted at: $(docker inspect task02-postgres --format '{{range .Mounts}}{{.Name}} -> {{.Destination}} ({{.Type}}){{end}}')"

echo ""
echo "--- write a marker row ---"
MARKER="persist-$(date +%s)-$$"
curl -s -X POST "$API/api/items" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$MARKER\",\"description\":\"written before docker compose down\"}" > /dev/null
BEFORE=$(count_items)
echo "    marker  : $MARKER"
echo "    rowcount: $BEFORE"

# ---------------------------------------------------------------------------
echo ""
echo "--- 1. docker compose down (volumes retained) ---"
docker compose down > /dev/null 2>&1
echo "    containers after down: $(docker ps -a --filter 'label=com.docker.compose.project=task02' --format '{{.Names}}' | wc -l)"
VOL_EXISTS=$(docker volume ls --filter name=task02-pgdata --format '{{.Name}}' | wc -l)
echo "    task02-pgdata volume still present: $VOL_EXISTS"
[ "$VOL_EXISTS" = "1" ] && pass "named volume survived 'docker compose down'" || fail "volume was removed by plain down"

echo ""
echo "--- bringing the stack back up ---"
docker compose up -d --wait --wait-timeout 180 > /dev/null 2>&1
wait_healthy || fail "stack did not come back healthy"

AFTER=$(count_items)
echo "    rowcount after up: $AFTER (was $BEFORE)"
FOUND=$(curl -s "$API/api/items" | grep -c "$MARKER" || true)
echo "    marker row present: $FOUND"

[ "$AFTER" = "$BEFORE" ] && pass "row count identical across down/up: $BEFORE" || fail "row count changed: $BEFORE -> $AFTER"
[ "$FOUND" -ge 1 ] && pass "the specific marker row survived: $MARKER" || fail "marker row lost"

# Re-running migrations on an existing database must not duplicate the seed.
SEED_COUNT=$(curl -s "$API/api/items" | grep -o '"name":"welcome"' | wc -l)
echo "    'welcome' seed row occurrences: $SEED_COUNT"
[ "$SEED_COUNT" = "1" ] && pass "migration/seed is idempotent, no duplicate on restart" || fail "seed duplicated: $SEED_COUNT copies"

# ---------------------------------------------------------------------------
echo ""
echo "--- 2. docker compose down -v (volumes destroyed) ---"
echo "    This is the destructive variant. Proving it destroys data is the point:"
echo "    it is what makes the survival above meaningful rather than accidental."
docker compose down -v > /dev/null 2>&1
VOL_AFTER=$(docker volume ls --filter name=task02-pgdata --format '{{.Name}}' | wc -l)
echo "    task02-pgdata volume present after down -v: $VOL_AFTER"
[ "$VOL_AFTER" = "0" ] && pass "'down -v' removed the named volume" || fail "volume survived down -v"

echo ""
echo "--- rebuilding from an empty volume ---"
docker compose up -d --wait --wait-timeout 180 > /dev/null 2>&1
wait_healthy || fail "stack did not come back after down -v"

FRESH=$(count_items)
FRESH_MARKER=$(curl -s "$API/api/items" | grep -c "$MARKER" || true)
echo "    rowcount on the fresh volume: $FRESH (seed rows only)"
echo "    marker row present: $FRESH_MARKER"

[ "$FRESH_MARKER" = "0" ] && pass "marker row is GONE, confirming down -v destroyed the data" || fail "marker survived down -v"
[ "$FRESH" = "2" ] && pass "database re-seeded from scratch: $FRESH rows" || echo "[INFO] fresh row count is $FRESH (expected 2 seed rows)"

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: DRILL D PASSED" || echo "RESULT: DRILL D FAILED"
exit "$RESULT"
