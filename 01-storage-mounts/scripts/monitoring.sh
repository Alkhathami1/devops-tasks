#!/usr/bin/env bash
# Requirement 4 — monitoring mount availability and disk performance.
#
# Three layers, because each answers a different question:
#   /proc/diskstats  the kernel's raw counters, the source everything else reads
#   iostat           the operator's tool: latency, queue depth, utilisation
#   node_exporter    the same counters as time series, scraped by Prometheus

set -uo pipefail

CONTAINER="${CONTAINER:-task01-linuxbox}"
PROM="${PROM:-http://127.0.0.1:9090}"
export MSYS_NO_PATHCONV=1

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }
dex()  { docker exec "$CONTAINER" bash -c "$1"; }
dexq() { docker exec "$CONTAINER" bash -c "$1" 2>/dev/null; }

# Query Prometheus and return the first sample value.
promv() {
  dexq "curl -sG --data-urlencode 'query=$1' $PROM/api/v1/query" \
    | grep -oE '"value":\[[0-9.]+,"[^"]*"\]' | head -1 \
    | grep -oE '"[0-9.e+-]+"\]$' | tr -d '"]'
}

# The loop device backing the XFS filesystem is assigned at mount time and is
# not stable across runs, so it is derived rather than hardcoded.
XFSDEV="$(dexq 'findmnt -no SOURCE /mnt/xfs | xargs -r basename' | tr -d '\r')"
XFSDEV="${XFSDEV:-loop0}"

echo "=== Requirement 4: monitoring mounts and disk performance ==="
echo "backing device for /mnt/xfs: $XFSDEV"
echo ""

# ---------------------------------------------------------------------------
echo "--- 1. /proc/diskstats: the kernel's raw counters ---"
echo "    Fields 4-7 are reads (completed, merged, sectors, ms), 8-11 the same"
echo "    for writes, field 12 is I/O in flight, 13 is ms spent doing I/O, and"
echo "    14 is weighted ms - the integral of queue depth over time."
dexq "grep -E ' ($XFSDEV|sd[a-z]) ' /proc/diskstats | head -5 | sed 's/^/      /'"

echo ""
echo "--- 2. iostat: the same data as an operator reads it ---"
echo "    r_await/w_await are mean service time per read/write in ms, which is"
echo "    the latency the SLO is written against. aqu-sz is average queue depth."
dexq "iostat -x -d 2 2 | tail -n +4 | grep -E 'Device|$XFSDEV' | sed 's/^/      /'" \
  || echo "      (iostat unavailable)"

echo ""
echo "--- 3. generate real I/O, then measure it ---"
echo "    fio: 15s of mixed random read/write against the XFS mount"
dexq "fio --name=task01 --directory=/mnt/xfs --size=128M --numjobs=2 \
      --rw=randrw --rwmixread=70 --bs=64k --runtime=15 --time_based \
      --group_reporting 2>/dev/null \
      | grep -E 'read:|write:|clat percentiles|99.00th|IOPS' | head -10 | sed 's/^/      /'" \
  || echo "      (fio unavailable)"

echo ""
echo "    iostat immediately after the load (non-zero now, unlike at idle):"
dexq "iostat -x -d 1 2 | tail -n +4 | grep -E 'Device|$XFSDEV' | sed 's/^/      /'"

# ---------------------------------------------------------------------------
echo ""
echo "--- 4. node_exporter is serving the same counters as metrics ---"
NE_UP="$(dexq "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9100/metrics")"
echo "    node_exporter /metrics -> HTTP $NE_UP"
[ "$NE_UP" = "200" ] && pass "node_exporter is serving metrics" || fail "node_exporter not responding"

echo ""
echo "    filesystem series for the XFS mount:"
dexq "curl -s http://127.0.0.1:9100/metrics | grep -E '^node_filesystem_[a-z_]+\{[^}]*mountpoint=\"/mnt/xfs\"' | sed 's/^/      /'"

echo ""
echo "    filesystem series for the SMB share - the mount the task is about:"
dexq "curl -s http://127.0.0.1:9100/metrics | grep -E '^node_filesystem_[a-z_]+\{[^}]*mountpoint=\"/mnt/winshare\"' | sed 's/^/      /'"
echo ""
echo "    note node_filesystem_files and _files_free are 0 for CIFS: SMB does"
echo "    not report an inode budget, which is why the inode alert is scoped to"
echo "    the XFS mount only. Including CIFS would evaluate 100*(1-0/0) = NaN,"
echo "    a value that never crosses a threshold and looks healthy forever."

echo ""
echo "    SMB client health from /proc/fs/cifs, exported via the textfile"
echo "    collector. A share can be mounted, writable and reporting free space"
echo "    while the session reconnects on every operation - the filesystem"
echo "    collector cannot see that, and reconnects are the leading indicator."
dexq "cat /proc/fs/cifs/Stats | head -12 | sed 's/^/      /'"
echo ""
dexq "curl -s http://127.0.0.1:9100/metrics | grep -E '^cifs_' | sed 's/^/      /'"

echo ""
echo "    disk counter series for $XFSDEV:"
dexq "curl -s http://127.0.0.1:9100/metrics | grep -E \"^node_disk_[a-z_]+\{device=\\\"$XFSDEV\\\"\" | head -10 | sed 's/^/      /'"

# ---------------------------------------------------------------------------
echo ""
echo "--- 5. Prometheus has scraped it ---"
UP="$(promv 'up{job="node"}')"
echo "    up{job=\"node\"} = ${UP:-<no data>}"
[ "${UP:-0}" = "1" ] && pass "Prometheus is scraping node_exporter successfully" || fail "target is down"

TARGETS="$(dexq "curl -s $PROM/api/v1/targets" | grep -oE '"health":"[a-z]+"' | sort | uniq -c | tr -d '\n')"
echo "    target health:$TARGETS"

echo ""
echo "    the numbers the SLO is written against, queried live:"

SIZE="$(promv "node_filesystem_size_bytes{mountpoint=\"/mnt/xfs\"}")"
AVAIL="$(promv "node_filesystem_avail_bytes{mountpoint=\"/mnt/xfs\"}")"
USEDPCT="$(promv "100 * (1 - node_filesystem_avail_bytes{mountpoint=\"/mnt/xfs\"} / node_filesystem_size_bytes{mountpoint=\"/mnt/xfs\"})")"
LAT="$(promv "(rate(node_disk_read_time_seconds_total{device=\"$XFSDEV\"}[1m]) + rate(node_disk_write_time_seconds_total{device=\"$XFSDEV\"}[1m])) / clamp_min(rate(node_disk_reads_completed_total{device=\"$XFSDEV\"}[1m]) + rate(node_disk_writes_completed_total{device=\"$XFSDEV\"}[1m]), 1)")"
QUEUE="$(promv "rate(node_disk_io_time_weighted_seconds_total{device=\"$XFSDEV\"}[1m])")"
THRU="$(promv "rate(node_disk_written_bytes_total{device=\"$XFSDEV\"}[1m])")"
INODES="$(promv "100 * (1 - node_filesystem_files_free{mountpoint=\"/mnt/xfs\"} / node_filesystem_files{mountpoint=\"/mnt/xfs\"})")"

printf '      %-30s %s\n' "filesystem size (bytes)"   "${SIZE:-<no data>}"
printf '      %-30s %s\n' "available (bytes)"         "${AVAIL:-<no data>}"
printf '      %-30s %s\n' "used (%)"                  "${USEDPCT:-<no data>}"
printf '      %-30s %s\n' "inodes used (%)"           "${INODES:-<no data>}"
printf '      %-30s %s\n' "mean service time (s)"     "${LAT:-<no data>}"
printf '      %-30s %s\n' "avg queue depth"           "${QUEUE:-<no data>}"
printf '      %-30s %s\n' "write throughput (B/s)"    "${THRU:-<no data>}"

SMBSIZE="$(promv "node_filesystem_size_bytes{mountpoint=\"/mnt/winshare\"}")"
SMBAVAIL="$(promv "node_filesystem_avail_bytes{mountpoint=\"/mnt/winshare\"}")"
SMBUSED="$(promv "100 * (1 - node_filesystem_avail_bytes{mountpoint=\"/mnt/winshare\"} / node_filesystem_size_bytes{mountpoint=\"/mnt/winshare\"})")"
SMBRECON="$(promv "cifs_session_reconnects_total")"
SMBSESS="$(promv "cifs_sessions")"

echo ""
echo "    and the same for the SMB share:"
printf '      %-30s %s
' "share size (bytes)"        "${SMBSIZE:-<no data>}"
printf '      %-30s %s
' "available (bytes)"         "${SMBAVAIL:-<no data>}"
printf '      %-30s %s
' "used (%)"                  "${SMBUSED:-<no data>}"
printf '      %-30s %s
' "cifs sessions"             "${SMBSESS:-<no data>}"
printf '      %-30s %s
' "cifs session reconnects"   "${SMBRECON:-<no data>}"

[ -n "${SIZE:-}" ]  && pass "mount capacity is observable in Prometheus" || fail "no filesystem series"
[ -n "${SMBSIZE:-}" ] && pass "SMB share capacity is observable in Prometheus" || fail "no filesystem series for the SMB share"
[ -n "${SMBSESS:-}" ] && pass "SMB session state is observable in Prometheus" || fail "no cifs_* series"
[ -n "${LAT:-}" ]   && pass "disk latency is observable (the iostat await equivalent)" || fail "no latency series"
[ -n "${QUEUE:-}" ] && pass "queue depth is observable" || fail "no queue depth series"
[ -n "${THRU:-}" ]  && pass "throughput is observable" || fail "no throughput series"

# ---------------------------------------------------------------------------
echo ""
echo "--- 6. mount AVAILABILITY, which is not the same as capacity ---"
echo "    node_exporter stops exporting node_filesystem_* for a mountpoint the"
echo "    moment it is unmounted - the series does not go to zero, it ceases to"
echo "    exist. So availability is monitored with absent(), not a threshold."
PRESENT="$(promv "absent(node_filesystem_size_bytes{mountpoint=\"/mnt/xfs\"})")"
echo "    absent(node_filesystem_size_bytes{mountpoint=\"/mnt/xfs\"}) = ${PRESENT:-<empty, i.e. mount present>}"
[ -z "${PRESENT:-}" ] && pass "the mount is present (absent() returns nothing)" || fail "the mount is missing"

SMBPRESENT="$(promv "absent(node_filesystem_size_bytes{mountpoint=\"/mnt/winshare\"})")"
echo "    absent(node_filesystem_size_bytes{mountpoint=\"/mnt/winshare\"}) = ${SMBPRESENT:-<empty, i.e. share present>}"
[ -z "${SMBPRESENT:-}" ] && pass "the SMB share is present (absent() returns nothing)" || fail "the SMB share is missing"

RO="$(promv "node_filesystem_readonly{mountpoint=\"/mnt/xfs\"}")"
echo "    node_filesystem_readonly = ${RO:-<no data>} (1 would mean the kernel remounted it read-only)"

# ---------------------------------------------------------------------------
echo ""
echo "--- 7. the alert rules are loaded ---"
RULES="$(dexq "curl -s $PROM/api/v1/rules" | grep -oE '"name":"[A-Za-z]+"' | cut -d'"' -f4 | sort -u | tr '\n' ' ')"
echo "    loaded: $RULES"
RULECOUNT="$(dexq "curl -s $PROM/api/v1/rules" | grep -oE '"type":"alerting"' | wc -l | tr -d ' ')"
echo "    alerting rules: $RULECOUNT"
[ "${RULECOUNT:-0}" -ge 10 ] && pass "$RULECOUNT alert rules loaded" || fail "expected 10 alert rules, found ${RULECOUNT:-0}"

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: MONITORING VERIFIED" || echo "RESULT: FAILURES PRESENT"
exit "$RESULT"
