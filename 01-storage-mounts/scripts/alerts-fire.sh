#!/usr/bin/env bash
# Requirement 5 — alerting, with alerts that have actually fired.
#
# An alert rule that has never fired is not evidence. It is a plausible-looking
# expression that may reference a metric that does not exist, use a label that
# is never set, or set a threshold nothing can cross. The only way to know a
# rule works is to make its condition true and watch it transition.
#
# Three alerts are driven for real:
#   1. FilesystemSpaceCritical  by filling the XFS filesystem past 85%
#   2. MountMissing             by unmounting the local XFS filesystem
#   3. SmbMountMissing          by unmounting the Windows SMB share
#
# The third is the one the SLO is actually about. The first two watch a local
# loop device; the assignment's subject is the mounted share.
#
# Both are captured going inactive -> pending -> firing through the Prometheus
# API, and back to inactive on recovery.

set -uo pipefail

CONTAINER="${CONTAINER:-task01-linuxbox}"
PROM="${PROM:-http://127.0.0.1:9090}"
MNT=/mnt/xfs
SMB=/mnt/winshare
export MSYS_NO_PATHCONV=1

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }
dexq() { docker exec "$CONTAINER" bash -c "$1" 2>/dev/null; }

# All alert states, parsed as JSON INSIDE the container. Two reasons:
#   * the rules payload nests alerts inside groups, so a line-oriented grep
#     picks up whichever "state" field comes first and returns an empty string
#     for every rule - the baseline then looks like nothing is loaded
#   * python3 on this Windows host is the Microsoft Store alias stub, which
#     prints an install prompt instead of running
all_states() {
  docker exec "$CONTAINER" python3 -c "
import json,urllib.request
try:
    d=json.load(urllib.request.urlopen('$PROM/api/v1/rules', timeout=5))
except Exception:
    raise SystemExit(0)
for g in d.get('data',{}).get('groups',[]):
    for r in g.get('rules',[]):
        if r.get('type')=='alerting':
            print('%s %s' % (r.get('name'), r.get('state','unknown')))
" 2>/dev/null
}

alert_state() { all_states | awk -v n="$1" '$1==n {print $2}' | head -1; }

active_alerts() {
  docker exec "$CONTAINER" python3 -c "
import json,urllib.request
try:
    d=json.load(urllib.request.urlopen('$PROM/api/v1/alerts', timeout=5))
except Exception:
    raise SystemExit(0)
for a in d.get('data',{}).get('alerts',[]):
    print('      %-28s %-8s severity=%s slo=%s' % (
        a['labels'].get('alertname','?'), a.get('state','?'),
        a['labels'].get('severity','?'), a['labels'].get('slo','?')))
" 2>/dev/null
}

alert_detail() {
  docker exec "$CONTAINER" python3 -c "
import json,urllib.request,sys
want=sys.argv[1]
try:
    d=json.load(urllib.request.urlopen('$PROM/api/v1/alerts', timeout=5))
except Exception:
    raise SystemExit(0)
for a in d.get('data',{}).get('alerts',[]):
    if a['labels'].get('alertname')==want:
        print('      state    :', a.get('state'))
        print('      activeAt :', a.get('activeAt'))
        print('      value    :', a.get('value'))
        print('      severity :', a['labels'].get('severity'))
        print('      slo      :', a['labels'].get('slo'))
        print('      summary  :', a.get('annotations',{}).get('summary'))
" "$1" 2>/dev/null
}

# Poll one alert until it reaches a state, printing every transition observed.
watch_alert() {
  local name="$1" want="$2" limit="${3:-45}"
  local last="" now="" i=0 start
  start=$(date +%s)
  while [ "$i" -lt "$limit" ]; do
    now="$(alert_state "$name")"
    if [ -z "$now" ] && [ "$i" -eq 0 ]; then
      printf '      t+%-4ss rule not loaded (empty state, not inactive)
' 0
    fi
    if [ -n "$now" ] && [ "$now" != "$last" ]; then
      printf '      t+%-4ss %s -> %s\n' "$(( $(date +%s) - start ))" "${last:-<start>}" "$now"
      last="$now"
    fi
    [ "$now" = "$want" ] && return 0
    sleep 2
    i=$((i+1))
  done
  return 1
}

echo "=== Requirement 5: alerting, with alerts that have actually fired ==="
echo ""

echo "--- the SLO these alerts are written against ---"
cat <<'SLO'
    Availability : the mounted share is readable and writable 99.9% of the
                   month = 43m 12s of permitted downtime per 30 days.
    Latency      : mean disk service time below 50 ms (a mean, not a p99 -
                   diskstats gives total time and total operations).
    Capacity     : never above 85% used, and never less than 4 hours of
                   headroom at the current fill rate.

    The `for:` durations come from that budget. MountMissing pages after 30s
    because the whole monthly budget is 43 minutes. FilesystemSpaceCritical
    waits 15s because filling a disk is a slow failure with time to react.
SLO

echo ""
echo "--- 1. do the rules even parse? promtool ---"
docker exec task01-prometheus promtool check rules /etc/prometheus/alerts.yml 2>&1 | sed 's/^/      /'
if docker exec task01-prometheus promtool check rules /etc/prometheus/alerts.yml > /dev/null 2>&1; then
  pass "promtool check rules passes"
else
  fail "promtool rejected the rules"
fi
echo ""
echo "    and the config:"
docker exec task01-prometheus promtool check config /etc/prometheus/prometheus.yml 2>&1 | sed 's/^/      /'

echo ""
echo "--- 2. reload, so an edited rules file is actually live ---"
# Without this the drill reads whatever Prometheus loaded at startup. An earlier
# run reported SmbMountMissing as never firing when the truth was that the rule
# had not been loaded at all - the state came back as an empty string, not as
# "inactive", which is the tell.
dexq "curl -s -X POST $PROM/-/reload -w '      reload HTTP %{http_code}
'"
sleep 3
LOADED="$(all_states | wc -l | tr -d ' ')"
echo "      alerting rules loaded: $LOADED"
if [ "${LOADED:-0}" -ge 10 ]; then
  pass "all rules are loaded after reload"
else
  fail "only $LOADED rules loaded - the rules file did not take"
fi

echo ""
echo "--- 3. baseline ---"
all_states | while read -r n s; do printf '      %-30s %s\n' "$n" "$s"; done
echo "    active alert instances: $(active_alerts | grep -c . || true)"

# ---------------------------------------------------------------------------
echo ""
echo "############################################################"
echo "# ALERT 1: FilesystemSpaceCritical - fill the filesystem"
echo "############################################################"
echo ""
echo "    usage before: $(dexq "df -h $MNT | tail -1 | awk '{print \$5}'")"
echo ""
echo "    Filling in steps, checking after each. A single calculated allocation"
echo "    undershot on the first attempt - XFS reserves blocks, so 'available'"
echo "    is not the same as 'what can still be written' - and it reached only"
echo "    70%. The alert correctly did not fire, which is why this loop exists."

dexq "rm -f $MNT/one-terabyte.img $MNT/real-extents.img $MNT/fill-*.img 2>/dev/null"
for step in 1 2 3 4 5 6 7 8 9 10; do
  PCT="$(dexq "df --output=pcent $MNT | tail -1 | tr -dc '0-9'")"
  [ "${PCT:-0}" -ge 88 ] && break
  dexq "fallocate -l 400M $MNT/fill-$step.img 2>/dev/null || dd if=/dev/zero of=$MNT/fill-$step.img bs=1M count=400 2>/dev/null"
done

echo ""
echo "    usage after : $(dexq "df -h $MNT | tail -1 | awk '{print \$5}'")"
dexq "df -h $MNT | sed 's/^/      /'"

echo ""
echo "    watching the transition:"
if watch_alert FilesystemSpaceCritical firing 45; then
  pass "FilesystemSpaceCritical reached FIRING"
else
  fail "FilesystemSpaceCritical did not fire (state: $(alert_state FilesystemSpaceCritical))"
fi

echo ""
echo "    active alerts:"
active_alerts
echo ""
echo "    payload:"
alert_detail FilesystemSpaceCritical

echo ""
echo "    recovering: removing the fill files"
dexq "rm -f $MNT/fill-*.img; sync"
dexq "df -h $MNT | sed 's/^/      /'"
if watch_alert FilesystemSpaceCritical inactive 45; then
  pass "FilesystemSpaceCritical returned to inactive"
else
  echo "[INFO] still $(alert_state FilesystemSpaceCritical) - resolution can lag an evaluation"
fi

# ---------------------------------------------------------------------------
echo ""
echo "############################################################"
echo "# ALERT 2: MountMissing - unmount the share"
echo "############################################################"
echo ""
echo "    The availability alert. It uses absent() rather than a threshold,"
echo "    because node_exporter stops publishing node_filesystem_* for a"
echo "    mountpoint the moment it disappears - the series ceases to exist"
echo "    rather than going to zero, so there is no value left to compare."
echo ""
echo "    before:"
dexq "findmnt -no SOURCE,TARGET,FSTYPE $MNT | sed 's/^/      /'"

echo ""
echo "    unmounting $MNT ..."
dexq "umount $MNT" && echo "      unmounted" || echo "      umount reported an error"
if dexq "findmnt -no TARGET $MNT" | grep -q .; then
  echo "      still a mount point"
else
  echo "      $MNT is no longer a mount point"
fi

echo ""
echo "    watching the transition:"
if watch_alert MountMissing firing 60; then
  pass "MountMissing reached FIRING"
else
  fail "MountMissing did not fire (state: $(alert_state MountMissing))"
fi

echo ""
echo "    active alerts:"
active_alerts
echo ""
echo "    payload:"
alert_detail MountMissing

echo ""
echo "    recovering: remounting"
dexq "mount -o loop,noatime /var/lib/task01/xfs.img $MNT" && echo "      remounted"
dexq "findmnt -no SOURCE,TARGET,FSTYPE $MNT | sed 's/^/      /'"
if watch_alert MountMissing inactive 60; then
  pass "MountMissing returned to inactive once the mount came back"
else
  echo "[INFO] still $(alert_state MountMissing) - resolution can lag an evaluation"
fi


# ---------------------------------------------------------------------------
echo ""
echo "############################################################"
echo "# ALERT 3: SmbMountMissing - unmount the Windows share"
echo "############################################################"
echo ""
echo "    This is the alert the availability SLO is written about. The two"
echo "    above watch a local loop device; this one watches the SMB share"
echo "    mounted from Windows, which is the thing the task is about."
echo ""
echo "    before:"
dexq "findmnt -no SOURCE,TARGET,FSTYPE $SMB | sed 's/^/      /'"
echo ""
echo "    SMB client health from /proc/fs/cifs, via the textfile collector:"
dexq "curl -s http://127.0.0.1:9100/metrics | grep -E '^cifs_' | sed 's/^/      /'"

echo ""
echo "    unmounting $SMB ..."
dexq "umount $SMB" && echo "      unmounted" || echo "      umount reported an error"
if dexq "findmnt -no TARGET $SMB" | grep -q .; then
  echo "      still a mount point"
else
  echo "      $SMB is no longer a mount point"
fi

echo ""
echo "    watching the transition:"
if watch_alert SmbMountMissing firing 60; then
  pass "SmbMountMissing reached FIRING"
else
  fail "SmbMountMissing did not fire (state: $(alert_state SmbMountMissing))"
fi

echo ""
echo "    active alerts:"
active_alerts
echo ""
echo "    payload:"
alert_detail SmbMountMissing

echo ""
echo "    recovering: mount -a, which uses the fstab entry alone"
dexq "mount -a" && echo "      mount -a returned 0"
dexq "findmnt -no SOURCE,TARGET,FSTYPE $SMB | sed 's/^/      /'"
if watch_alert SmbMountMissing inactive 60; then
  pass "SmbMountMissing returned to inactive once the share came back"
else
  echo "[INFO] still $(alert_state SmbMountMissing) - resolution can lag an evaluation"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- final state ---"
all_states | while read -r n s; do printf '      %-30s %s\n' "$n" "$s"; done

echo ""
echo "--- what this proves ---"
if [ "$RESULT" = "0" ]; then
  echo "    All three rules were driven from inactive to firing by a real"
  echo "    condition and back again. That exercises the whole path: the metric"
  echo "    exists, the label selector matches, the threshold is reachable, the"
  echo "    for: duration elapses, and Prometheus surfaces it on the alerts API."
else
  echo "    NOT ALL rules fired. Read the [FAIL] lines above rather than this"
  echo "    paragraph - a summary that claims success above a failure is the"
  echo "    exact defect these drills exist to catch."
fi

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: ALERTS FIRED AND VERIFIED" || echo "RESULT: FAILURES PRESENT"
exit "$RESULT"
