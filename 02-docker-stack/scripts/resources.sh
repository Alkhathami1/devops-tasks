#!/usr/bin/env bash
# Requirement 4 evidence: CPU, RAM and storage allocation.
#
# Shows the limits and reservations Docker actually applied (read back from the
# daemon, not from the compose file) and live usage under load, so the numbers
# can be seen to bind rather than merely be declared.

set -uo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STACK_DIR"
export MSYS_NO_PATHCONV=1

HOST_PORT="$(grep -E '^HOST_PORT=' .env 2>/dev/null | cut -d= -f2)"; HOST_PORT="${HOST_PORT:-8080}"

echo "=== Resource allocation (requirement 4) ==="
echo ""

echo "--- host / Docker VM capacity being divided up ---"
docker info --format '    Docker VM CPUs   : {{.NCPU}}'
TOTAL_MEM=$(docker info --format '{{.MemTotal}}')
echo "    Docker VM memory : $TOTAL_MEM bytes ($((TOTAL_MEM / 1024 / 1024)) MiB for all containers)"
echo "    cgroup version   : $(docker info --format '{{.CgroupVersion}}')  (v2 is required for reliable memory accounting)"

echo ""
echo "--- applied limits, read back from the daemon ---"
printf '    %-18s %12s %12s %14s %12s\n' CONTAINER MEM_LIMIT MEM_RESV CPU_LIMIT MEMSWAP
for c in task02-postgres task02-backend task02-nginx; do
  MEM=$(docker inspect "$c" --format '{{.HostConfig.Memory}}')
  RESV=$(docker inspect "$c" --format '{{.HostConfig.MemoryReservation}}')
  NANO=$(docker inspect "$c" --format '{{.HostConfig.NanoCpus}}')
  SWAP=$(docker inspect "$c" --format '{{.HostConfig.MemorySwap}}')
  printf '    %-18s %10s M %10s M %12s cpu %10s M\n' \
    "${c#task02-}" \
    "$((MEM / 1024 / 1024))" \
    "$((RESV / 1024 / 1024))" \
    "$(awk -v n="$NANO" 'BEGIN{printf "%.2f", n/1000000000}')" \
    "$((SWAP / 1024 / 1024))"
done

echo ""
echo "    A non-zero value in every column is the proof that the compose"
echo "    deploy.resources block is being enforced, not silently ignored."
echo ""
echo "    Read the MEMSWAP column carefully. Where it is DOUBLE the memory limit"
echo "    (postgres 512->1024, nginx 128->256) that is Docker's default: a"
echo "    container may use its limit again in swap, so memory pressure degrades"
echo "    into paging rather than an OOM kill. Only the backend sets"
echo "    memswap_limit equal to its memory limit, which disables swap entirely."
echo "    That is deliberate: without it the RAM-exhaustion drill could page"
echo "    instead of dying and would never produce OOMKilled: true."

echo ""
echo "--- live usage against those limits ---"
docker stats --no-stream \
  --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}' \
  task02-postgres task02-backend task02-nginx

echo ""
echo "--- usage under load (200 requests through the proxy) ---"
for i in $(seq 1 200); do
  curl -s -o /dev/null "http://127.0.0.1:${HOST_PORT}/api/items" &
  if [ $((i % 25)) -eq 0 ]; then wait; fi
done
wait
echo "    load generated; sampling again"
docker stats --no-stream \
  --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' \
  task02-postgres task02-backend task02-nginx

echo ""
echo "--- storage ---"
echo "    named volume:"
docker volume inspect task02-pgdata --format '      name={{.Name}} driver={{.Driver}} scope={{.Scope}}'
echo "      mountpoint: $(docker volume inspect task02-pgdata --format '{{.Mountpoint}}')"
echo "    size on disk inside the container:"
docker exec task02-postgres du -sh /var/lib/postgresql/data 2>/dev/null | sed 's/^/      /'
echo "    image sizes:"
docker images --format '      {{.Repository}}:{{.Tag}}  {{.Size}}' \
  | grep -E 'task02-|postgres' | sort -u
