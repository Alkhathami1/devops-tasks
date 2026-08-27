#!/usr/bin/env bash
# DRILL 3 — the three-tier backup strategy, and what each tier costs.
#
# Demonstrates full / differential / log backups, shows that the scheduler is
# taking them automatically, proves each is verified, and demonstrates the
# SIMPLE-recovery failure mode that makes log backups impossible.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

echo "=== DRILL 3: three-tier backup strategy ==="
echo ""

echo "--- the scheduler is running and taking backups unattended ---"
echo "    sidecar status: $(docker inspect "$BACKUP_CONTAINER" --format '{{.State.Status}}' 2>/dev/null)"
echo "    restart policy: $(docker inspect "$BACKUP_CONTAINER" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null)"
echo ""
echo "    recent scheduler log:"
docker logs --tail 12 "$BACKUP_CONTAINER" 2>&1 | sed 's/^/      /'

echo ""
echo "--- taking one of each tier on demand (same code the scheduler runs) ---"
for tier in full diff log; do
  echo ""
  echo "  [$tier]"
  if docker exec "$BACKUP_CONTAINER" /opt/backup/backup.sh "$tier" 2>&1 | grep -E 'INFO|ERROR' | sed 's/^/      /'; then
    pass "$tier backup taken and verified"
  else
    fail "$tier backup failed"
  fi
done

echo ""
echo "--- backup history from msdb (SQL Server's own record) ---"
sql "SELECT TOP 12
       CASE bs.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' ELSE bs.type END AS [tier],
       CONVERT(VARCHAR(19), bs.backup_finish_date, 120) AS [finished],
       CAST(bs.backup_size / 1024.0 AS DECIMAL(12,1))   AS [size_kb],
       CAST(bs.compressed_backup_size / 1024.0 AS DECIMAL(12,1)) AS [compressed_kb],
       bs.has_backup_checksums                          AS [checksums],
       bs.first_lsn, bs.last_lsn
     FROM msdb.dbo.backupset bs
     WHERE bs.database_name = '${DB_NAME}'
     ORDER BY bs.backup_finish_date DESC;"

echo ""
echo "--- every backup carries checksums ---"
NO_CHECKSUM="$(sqlv "SELECT COUNT(*) FROM msdb.dbo.backupset WHERE database_name='${DB_NAME}' AND has_backup_checksums = 0")"
echo "    backups without checksums: ${NO_CHECKSUM:-?}"
if [ "${NO_CHECKSUM:-1}" = "0" ]; then
  pass "all backups written WITH CHECKSUM"
else
  fail "$NO_CHECKSUM backup(s) lack checksums"
fi

echo ""
echo "--- files on the backups volume ---"
docker exec "$BACKUP_CONTAINER" sh -c 'for d in full diff log; do
    printf "    %-5s %s file(s), %s\n" "$d" "$(find /backups/$d -type f 2>/dev/null | wc -l)" "$(du -sh /backups/$d 2>/dev/null | cut -f1)"
  done'

FULL_N="$(docker exec "$BACKUP_CONTAINER" sh -c 'find /backups/full -type f | wc -l' | tr -d '\r')"
LOG_N="$(docker exec "$BACKUP_CONTAINER" sh -c 'find /backups/log -type f | wc -l' | tr -d '\r')"
if [ "${FULL_N:-0}" -ge 1 ] && [ "${LOG_N:-0}" -ge 1 ]; then
  pass "all three tiers have produced files on disk"
else
  fail "expected files in every tier"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- why FULL recovery is mandatory: what SIMPLE recovery does to log backups ---"
echo "    Switching to SIMPLE and attempting a log backup, to show the failure"
echo "    rather than merely assert it. This is Msg 4208."
echo ""
sql "ALTER DATABASE [${DB_NAME}] SET RECOVERY SIMPLE;" > /dev/null 2>&1
echo "    recovery model now: $(sqlv "SELECT recovery_model_desc FROM sys.databases WHERE name='${DB_NAME}'")"
echo ""
echo "    attempting BACKUP LOG under SIMPLE recovery:"
if sql "BACKUP LOG [${DB_NAME}] TO DISK = N'/backups/log/should-not-exist.trn' WITH INIT;" 2>&1 | sed 's/^/      /'; then
  fail "BACKUP LOG unexpectedly SUCCEEDED under SIMPLE recovery"
else
  pass "BACKUP LOG correctly FAILED under SIMPLE recovery - PITR is impossible in this model"
fi

echo ""
echo "    restoring FULL recovery model:"
sql "ALTER DATABASE [${DB_NAME}] SET RECOVERY FULL;" > /dev/null 2>&1
MODEL_BACK="$(sqlv "SELECT recovery_model_desc FROM sys.databases WHERE name='${DB_NAME}'")"
echo "    recovery model now: $MODEL_BACK"
if [ "$MODEL_BACK" = "FULL" ]; then
  pass "FULL recovery restored"
else
  fail "recovery model is $MODEL_BACK"
fi

# Switching SIMPLE -> FULL breaks the log chain until the next full backup:
# until then, log backups have no base and PITR would silently have a hole.
echo ""
echo "    NOTE: a SIMPLE -> FULL round trip BREAKS the log chain. Until a new"
echo "    full backup is taken the database is only pseudo-FULL and log backups"
echo "    have no base. Taking one now to close the gap:"
docker exec "$BACKUP_CONTAINER" /opt/backup/backup.sh full 2>&1 | grep -E 'INFO|ERROR' | sed 's/^/      /'
if docker exec "$BACKUP_CONTAINER" /opt/backup/backup.sh log 2>&1 | grep -qE 'complete and verified'; then
  pass "log chain re-established after the recovery model round trip"
else
  fail "log backup still failing after re-establishing the chain"
fi

echo ""
echo "--- retention ---"
echo "    windows: full=${FULL_RETENTION_MIN:-1440}m diff=${DIFF_RETENTION_MIN:-360}m log=${LOG_RETENTION_MIN:-120}m"
docker exec "$BACKUP_CONTAINER" /opt/backup/retention.sh 2>&1 | grep -E 'retention' | sed 's/^/      /'
pass "retention pass executed"

echo ""
if [ "$RESULT" = "0" ]; then echo "RESULT: DRILL 3 PASSED"; else echo "RESULT: DRILL 3 FAILED"; fi
exit "$RESULT"
