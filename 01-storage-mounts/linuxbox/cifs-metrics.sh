#!/usr/bin/env bash
# Export SMB client health from /proc/fs/cifs into node_exporter's textfile
# collector.
#
# WHY THIS EXISTS
# ---------------
# node_exporter reports a CIFS mount as a filesystem: size, free, readonly.
# That answers "is it mounted and does it have room", which is most of the SLO
# but not the interesting part. An SMB mount can be present, writable and
# reporting free space while the client is reconnecting on every operation
# because the session keeps dropping. The filesystem collector cannot see that.
#
# /proc/fs/cifs/Stats carries the counter that does:
#
#   5 session 2 share reconnects
#
# Reconnects are the leading indicator for an SMB share. They rise before
# throughput falls and long before the mount disappears, so alerting on their
# rate catches a degrading link while it is still serving traffic.
#
# Written atomically via a temp file and mv, because node_exporter reads the
# directory on every scrape and a half-written .prom file makes it emit a
# parse error instead of the metrics.

set -uo pipefail

OUTDIR="${1:-/var/lib/node_exporter/textfile}"
STATS=/proc/fs/cifs/Stats
OUT="$OUTDIR/cifs.prom"
TMP="$OUT.$$"

mkdir -p "$OUTDIR"

emit() {
  echo "# HELP cifs_up Whether /proc/fs/cifs/Stats is readable (the cifs module is loaded)."
  echo "# TYPE cifs_up gauge"
  if [ ! -r "$STATS" ]; then
    echo "cifs_up 0"
    return
  fi
  echo "cifs_up 1"

  # "CIFS Session: 1"
  local sessions shares recon_session recon_share vfsops inflight
  sessions="$(awk -F': *' '/^CIFS Session:/{print $2; exit}' "$STATS" 2>/dev/null)"
  shares="$(awk -F': *' '/^Share \(unique mount targets\):/{print $2; exit}' "$STATS" 2>/dev/null)"

  # "5 session 2 share reconnects" - positional, and absent on some kernels.
  recon_session="$(awk '/session .* share reconnects/{print $1; exit}' "$STATS" 2>/dev/null)"
  recon_share="$(awk '/session .* share reconnects/{print $3; exit}' "$STATS" 2>/dev/null)"

  # "Total vfs operations: 1624 maximum at one time: 3"
  vfsops="$(awk -F'[: ]+' '/^Total vfs operations:/{print $4; exit}' "$STATS" 2>/dev/null)"

  # "Max requests in flight: 3"
  inflight="$(awk -F': *' '/^Max requests in flight:/{print $2; exit}' "$STATS" 2>/dev/null)"

  num() { case "${1:-}" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

  echo "# HELP cifs_sessions Active SMB sessions held by the client."
  echo "# TYPE cifs_sessions gauge"
  echo "cifs_sessions $(num "$sessions")"

  echo "# HELP cifs_shares Unique mount targets."
  echo "# TYPE cifs_shares gauge"
  echo "cifs_shares $(num "$shares")"

  echo "# HELP cifs_session_reconnects_total Session reconnects since the module loaded."
  echo "# TYPE cifs_session_reconnects_total counter"
  echo "cifs_session_reconnects_total $(num "$recon_session")"

  echo "# HELP cifs_share_reconnects_total Share reconnects since the module loaded."
  echo "# TYPE cifs_share_reconnects_total counter"
  echo "cifs_share_reconnects_total $(num "$recon_share")"

  echo "# HELP cifs_vfs_operations_total VFS operations served through the client."
  echo "# TYPE cifs_vfs_operations_total counter"
  echo "cifs_vfs_operations_total $(num "$vfsops")"

  echo "# HELP cifs_max_requests_in_flight Peak concurrent requests on the wire."
  echo "# TYPE cifs_max_requests_in_flight gauge"
  echo "cifs_max_requests_in_flight $(num "$inflight")"
}

if [ "${LOOP:-1}" = "1" ]; then
  while true; do
    emit > "$TMP" 2>/dev/null && mv -f "$TMP" "$OUT"
    sleep "${INTERVAL:-5}"
  done
else
  emit > "$TMP" 2>/dev/null && mv -f "$TMP" "$OUT"
  cat "$OUT"
fi
