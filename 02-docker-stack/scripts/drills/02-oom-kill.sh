#!/usr/bin/env bash
# DRILL B — RAM exhaustion and OOM kill.
#
# The backend is limited to 256 MiB with swap disabled (memswap_limit == memory,
# so the kernel cannot page out instead of killing). The allocation is performed
# by the backend process itself, which is PID 1 in the container.
#
# WHY PID 1 MATTERS: if the memory hog were a child process — say a `docker exec`
# of some allocator — the kernel OOM killer would pick the greediest task, reap
# the child, and leave PID 1 alive. The container would survive, `docker inspect`
# would report OOMKilled: false, and the drill would prove nothing about the
# memory limit. Allocating inside PID 1 means the OOM kill takes down the
# container itself, which is what makes State.OOMKilled true.

set -uo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$STACK_DIR"
export MSYS_NO_PATHCONV=1

HOST_PORT="$(grep -E '^HOST_PORT=' .env 2>/dev/null | cut -d= -f2)"; HOST_PORT="${HOST_PORT:-8080}"
API="http://127.0.0.1:${HOST_PORT}"

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }

echo "=== DRILL B: RAM exhaustion -> OOM kill ==="
echo ""

echo "--- configured limits (requirement 4 evidence) ---"
LIMIT_BYTES=$(docker inspect task02-backend --format '{{.HostConfig.Memory}}')
SWAP_BYTES=$(docker inspect task02-backend --format '{{.HostConfig.MemorySwap}}')
echo "    Memory limit : $LIMIT_BYTES bytes ($((LIMIT_BYTES / 1024 / 1024)) MiB)"
echo "    MemorySwap   : $SWAP_BYTES bytes ($((SWAP_BYTES / 1024 / 1024)) MiB)"
echo "    swap headroom: $(( (SWAP_BYTES - LIMIT_BYTES) / 1024 / 1024 )) MiB (0 = swap disabled, OOM cannot be masked)"
[ "$LIMIT_BYTES" -gt 0 ] && pass "a memory limit is actually applied" || fail "no memory limit set"
[ "$SWAP_BYTES" = "$LIMIT_BYTES" ] && pass "swap disabled, so exhaustion must produce an OOM kill" || fail "swap enabled; OOM may be masked"

echo ""
echo "--- PID 1 identity (the crux of this drill) ---"
PID1_COMM=$(docker exec task02-backend cat /proc/1/comm 2>/dev/null)
echo "    /proc/1/comm = $PID1_COMM"
[ "$PID1_COMM" = "node" ] \
  && pass "the application IS PID 1, so an OOM kill takes down the container" \
  || fail "PID 1 is '$PID1_COMM', not the app; an OOM kill would spare the container"

echo ""
echo "--- baseline ---"
RC_BEFORE=$(docker inspect task02-backend --format '{{.RestartCount}}')
PID_BEFORE=$(docker inspect task02-backend --format '{{.State.Pid}}')
BASE_MEM=$(docker stats --no-stream --format '{{.MemUsage}}' task02-backend 2>/dev/null)
echo "    RestartCount : $RC_BEFORE"
echo "    host PID     : $PID_BEFORE"
echo "    memory usage : $BASE_MEM"

echo ""
echo "--- triggering allocation inside PID 1 ---"
# Invoked from nginx: /internal is not proxied and the backend has no host port,
# so this endpoint is unreachable from outside the Docker networks.
docker exec task02-nginx wget -q -O- --post-data='' \
  'http://backend:3000/internal/chaos/oom?confirm=yes' 2>&1 | head -1
START_EPOCH=$(date +%s%3N)
echo "    allocating from $(date '+%H:%M:%S.%3N')"

echo ""
echo "--- watching for the kill ---"
OOM_SEEN=""
OOM_AT_KILL=""
EXIT_AT_KILL=""
KILL_AT_MS=""
for i in $(seq 1 60); do
  STATUS=$(docker inspect task02-backend --format '{{.State.Status}}' 2>/dev/null)
  OOM=$(docker inspect task02-backend --format '{{.State.OOMKilled}}' 2>/dev/null)
  EXIT=$(docker inspect task02-backend --format '{{.State.ExitCode}}' 2>/dev/null)
  if [ "$OOM" = "true" ]; then
    OOM_SEEN="yes"
    OOM_AT_KILL="$OOM"
    EXIT_AT_KILL="$EXIT"
    KILL_AT_MS=$(( $(date +%s%3N) - START_EPOCH ))
    echo "    t+${KILL_AT_MS}ms: OOMKilled=true status=$STATUS exit=$EXIT   <-- CAPTURED"
    break
  fi
  if [ "$STATUS" = "restarting" ] || [ "$STATUS" = "exited" ]; then
    echo "    t+$((  $(date +%s%3N) - START_EPOCH ))ms: status=$STATUS OOMKilled=$OOM exit=$EXIT"
  fi
  sleep 0.5
done

echo ""
echo "--- state AT THE MOMENT OF THE KILL (the evidence that matters) ---"
echo "    State.OOMKilled : ${OOM_AT_KILL:-<never observed true>}"
echo "    State.ExitCode  : ${EXIT_AT_KILL:-n/a}"
echo "                      (an OOM kill exits 137 = 128+SIGKILL. This field is"
echo "                       sampled by polling, so it can read 0 when the sample"
echo "                       lands mid-transition between the dead container and"
echo "                       its replacement. State.OOMKilled above is the"
echo "                       authoritative signal, not this exit code.)"
echo "    observed at     : t+${KILL_AT_MS:-n/a} ms after allocation began"

[ "$OOM_SEEN" = "yes" ] \
  && pass "State.OOMKilled captured as true - the cgroup limit genuinely killed the container" \
  || fail "OOMKilled never became true; the drill did not prove the limit binds"

echo ""
echo "--- state read a moment later, AFTER the restart policy acted ---"
echo "    NOTE: these describe the REPLACEMENT container, not the one that died."
echo "    Docker resets State.OOMKilled/ExitCode when it starts the new process,"
echo "    which is why a late inspect shows false/0. It is not a contradiction of"
echo "    the capture above - it is a different container instance."
echo "    State.OOMKilled : $(docker inspect task02-backend --format '{{.State.OOMKilled}}')"
echo "    State.ExitCode  : $(docker inspect task02-backend --format '{{.State.ExitCode}}')"
echo "    State.Status    : $(docker inspect task02-backend --format '{{.State.Status}}')"

echo ""
echo "--- unattended recovery after the OOM ---"
for _ in $(seq 1 120); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$API/api-health" 2>/dev/null)" = "200" ] && break
  sleep 0.5
done
RECOVER_MS=$(( $(date +%s%3N) - START_EPOCH ))

RC_AFTER=$(docker inspect task02-backend --format '{{.RestartCount}}')
PID_AFTER=$(docker inspect task02-backend --format '{{.State.Pid}}')
echo "    RestartCount : $RC_BEFORE -> $RC_AFTER"
echo "    host PID     : $PID_BEFORE -> $PID_AFTER"
echo "    health       : $(curl -s -o /dev/null -w '%{http_code}' "$API/api-health")"
echo "    time from allocation start to healthy again: ${RECOVER_MS} ms"

[ "$RC_AFTER" -gt "$RC_BEFORE" ] \
  && pass "restart policy fired after the OOM kill (an OOM is NOT an operator stop)" \
  || fail "container did not restart after the OOM"

ITEMS=$(curl -s "$API/api/items" | grep -oE '"count":[0-9]+' | cut -d: -f2)
[ -n "$ITEMS" ] && pass "service fully functional after OOM recovery: $ITEMS rows" || fail "not serving after recovery"

echo ""
echo "--- the other tiers were unaffected ---"
echo "    postgres: $(docker inspect task02-postgres --format '{{.State.Status}}') restarts=$(docker inspect task02-postgres --format '{{.RestartCount}}')"
echo "    nginx   : $(docker inspect task02-nginx --format '{{.State.Status}}') restarts=$(docker inspect task02-nginx --format '{{.RestartCount}}')"
[ "$(docker inspect task02-postgres --format '{{.RestartCount}}')" = "0" ] \
  && pass "memory limit contained the blast radius: postgres never restarted" \
  || fail "postgres was affected by the backend OOM"

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: DRILL B PASSED" || echo "RESULT: DRILL B FAILED"
exit "$RESULT"
