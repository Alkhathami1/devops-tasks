#!/usr/bin/env bash
# DRILL 2 — point-in-time recovery.
#
# The strongest possible evidence for "restore from a backup": recovering the
# database to a chosen INSTANT, not merely to the state of the last backup file.
#
# Timeline constructed by this drill:
#
#   t0  full backup            <- the base of the restore chain
#   t1  INSERT marker A
#   t2  log backup #1
#   t3  RECORD STOPAT time T   <- the instant we will recover to
#   t4  INSERT marker B
#   t5  log backup #2
#
# Then restore full WITH NORECOVERY, apply the logs, and STOP AT T.
# Correct behaviour: marker A is present, marker B is NOT. Recovering to a
# point between two committed transactions is something no file-level copy of
# the data directory can do.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

echo "=== DRILL 2: point-in-time recovery ==="
echo ""

FULL_BAK="/backups/full/${DB_NAME}-pitr-base.bak"
LOG1="/backups/log/${DB_NAME}-pitr-1.trn"
LOG2="/backups/log/${DB_NAME}-pitr-2.trn"

# ------------------------------------------------------- recovery model ------
echo "--- 0. preconditions ---"
MODEL="$(sqlv "SELECT recovery_model_desc FROM sys.databases WHERE name='${DB_NAME}'")"
echo "    recovery model: $MODEL"
if [ "$MODEL" = "FULL" ]; then
  pass "FULL recovery model - transaction log backups are possible"
else
  fail "recovery model is $MODEL; PITR is impossible without FULL"
fi

# A marker table isolated from the seeded schema, so the drill cannot be
# confused with ordinary data.
sql "USE ${DB_NAME};
     IF OBJECT_ID('dbo.pitr_markers','U') IS NULL
        CREATE TABLE dbo.pitr_markers (
            marker_id   INT IDENTITY(1,1) PRIMARY KEY,
            label       VARCHAR(32) NOT NULL,
            inserted_at DATETIME2(3) NOT NULL DEFAULT SYSDATETIME());
     DELETE FROM dbo.pitr_markers;" > /dev/null 2>&1

# ------------------------------------------------------------- t0: full ------
echo ""
echo "--- t0. full backup (the base of the chain) ---"
if sql "BACKUP DATABASE [${DB_NAME}] TO DISK = N'${FULL_BAK}'
        WITH INIT, FORMAT, CHECKSUM, COMPRESSION, NAME = N'pitr base';" | tail -1; then
  pass "base full backup taken"
else
  fail "base backup failed"
fi

# ------------------------------------------------------------- t1: A ---------
echo ""
echo "--- t1. INSERT marker A ---"
sql "USE ${DB_NAME}; INSERT INTO dbo.pitr_markers (label) VALUES ('MARKER-A');" > /dev/null
A_TIME="$(sqlv "USE ${DB_NAME}; SELECT CONVERT(VARCHAR(23), inserted_at, 126) FROM dbo.pitr_markers WHERE label='MARKER-A'")"
echo "    MARKER-A committed at (server time): $A_TIME"

# ------------------------------------------------------------- t2: log #1 ----
echo ""
echo "--- t2. transaction log backup #1 ---"
if sql "BACKUP LOG [${DB_NAME}] TO DISK = N'${LOG1}' WITH INIT, CHECKSUM, COMPRESSION, NAME = N'pitr log 1';" | tail -1; then
  pass "log backup #1 taken"
else
  fail "log backup #1 failed"
fi

# ------------------------------------------------------------- t3: STOPAT ----
echo ""
echo "--- t3. record the recovery target ---"
# Wait so the STOPAT instant is unambiguously after A and before B. DATETIME2(3)
# has millisecond resolution, but a couple of seconds of separation removes any
# doubt about which side of the target each row falls on.
sleep 3
STOPAT="$(server_now)"
echo "    STOPAT target (server local time): $STOPAT"
sleep 3

# ------------------------------------------------------------- t4: B ---------
echo ""
echo "--- t4. INSERT marker B (AFTER the recovery target) ---"
sql "USE ${DB_NAME}; INSERT INTO dbo.pitr_markers (label) VALUES ('MARKER-B');" > /dev/null
B_TIME="$(sqlv "USE ${DB_NAME}; SELECT CONVERT(VARCHAR(23), inserted_at, 126) FROM dbo.pitr_markers WHERE label='MARKER-B'")"
echo "    MARKER-B committed at (server time): $B_TIME"

echo ""
echo "    timeline:  A=$A_TIME   STOPAT=$STOPAT   B=$B_TIME"
BOTH="$(sqlv "USE ${DB_NAME}; SELECT COUNT(*) FROM dbo.pitr_markers")"
echo "    markers currently in the database: $BOTH (expect 2)"
if [ "$BOTH" = "2" ]; then pass "both markers present before recovery"; else fail "expected 2 markers, found $BOTH"; fi

# ------------------------------------------------------------- t5: log #2 ----
echo ""
echo "--- t5. transaction log backup #2 (contains marker B) ---"
if sql "BACKUP LOG [${DB_NAME}] TO DISK = N'${LOG2}' WITH INIT, CHECKSUM, COMPRESSION, NAME = N'pitr log 2';" | tail -1; then
  pass "log backup #2 taken"
else
  fail "log backup #2 failed"
fi

# ------------------------------------------------- restore chain -------------
echo ""
echo "--- restore chain: full NORECOVERY -> log NORECOVERY -> log STOPAT RECOVERY ---"
echo "    NORECOVERY leaves the database in RESTORING state so further log files"
echo "    can be applied. Only the final restore uses RECOVERY, which rolls back"
echo "    uncommitted transactions and brings the database online. Using RECOVERY"
echo "    too early ends the chain and makes the remaining logs unusable."
echo ""

PITR_START=$(date +%s%3N)
to_single_user

echo "    [1/3] RESTORE DATABASE ... WITH NORECOVERY"
sql "RESTORE DATABASE [${DB_NAME}] FROM DISK = N'${FULL_BAK}' WITH REPLACE, NORECOVERY, STATS = 50;" | tail -1
STATE="$(sqlv "SELECT state_desc FROM sys.databases WHERE name='${DB_NAME}'")"
echo "          database state now: $STATE"
if [ "$STATE" = "RESTORING" ]; then
  pass "database is RESTORING - the chain is open"
else
  fail "expected RESTORING, got $STATE"
fi

echo "    [2/3] RESTORE LOG #1 ... WITH NORECOVERY"
if sql "RESTORE LOG [${DB_NAME}] FROM DISK = N'${LOG1}' WITH NORECOVERY;" | tail -1; then
  pass "log #1 applied"
else
  fail "log #1 restore failed"
fi

echo "    [3/3] RESTORE LOG #2 ... WITH STOPAT, RECOVERY"
echo "          STOPAT = $STOPAT"
if sql "RESTORE LOG [${DB_NAME}] FROM DISK = N'${LOG2}' WITH STOPAT = N'${STOPAT}', RECOVERY;" | tail -1; then
  pass "log #2 applied with STOPAT, database recovered"
else
  fail "STOPAT restore failed"
fi
PITR_MS=$(( $(date +%s%3N) - PITR_START ))

to_multi_user
wait_for_sql 30 > /dev/null
echo "    point-in-time restore wall time: ${PITR_MS} ms"

# ------------------------------------------------------------- verdict -------
echo ""
echo "--- the proof: which markers survived? ---"
STATE_AFTER="$(sqlv "SELECT state_desc FROM sys.databases WHERE name='${DB_NAME}'")"
echo "    database state: $STATE_AFTER"

HAS_A="$(sqlv "USE ${DB_NAME}; SELECT COUNT(*) FROM dbo.pitr_markers WHERE label='MARKER-A'")"
HAS_B="$(sqlv "USE ${DB_NAME}; SELECT COUNT(*) FROM dbo.pitr_markers WHERE label='MARKER-B'")"
TOTAL="$(sqlv "USE ${DB_NAME}; SELECT COUNT(*) FROM dbo.pitr_markers")"

echo "    MARKER-A (committed BEFORE the target): $HAS_A"
echo "    MARKER-B (committed AFTER  the target): $HAS_B"
echo "    total markers: $TOTAL"

if [ "$STATE_AFTER" = "ONLINE" ]; then pass "database is ONLINE after recovery"; else fail "database is $STATE_AFTER"; fi
if [ "$HAS_A" = "1" ]; then
  pass "MARKER-A survived - data committed before the target was recovered"
else
  fail "MARKER-A missing; the restore lost committed data"
fi
if [ "$HAS_B" = "0" ]; then
  pass "MARKER-B is ABSENT - recovery genuinely stopped at the target instant"
else
  fail "MARKER-B present; STOPAT did not take effect and this is not PITR"
fi

# The rest of the database must be intact - PITR is not supposed to be
# selective about anything except time.
CUST="$(row_count customers)"
ITEMS="$(row_count order_items)"
echo "    customers after PITR  : $CUST"
echo "    order_items after PITR: $ITEMS"
if [ "${CUST:-0}" -gt 0 ] && [ "${ITEMS:-0}" -gt 0 ]; then
  pass "the seeded schema survived the point-in-time restore intact"
else
  fail "seeded data missing after PITR"
fi

echo ""
if [ "$RESULT" = "0" ]; then echo "RESULT: DRILL 2 PASSED"; else echo "RESULT: DRILL 2 FAILED"; fi
exit "$RESULT"
