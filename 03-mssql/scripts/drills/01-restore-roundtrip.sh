#!/usr/bin/env bash
# DRILL 1 — full backup / destroy / restore round trip.
#
# The requirement is "restore from a backup". A restore that is merely executed
# proves nothing; what has to be shown is that the data AFTER the restore is
# identical to the data BEFORE the damage. So:
#
#   1. fingerprint the database (row counts + per-table checksums)
#   2. take a full backup and verify it
#   3. destroy data - delete rows AND drop a table outright
#   4. prove the damage is real (fingerprint changed, table gone)
#   5. restore
#   6. prove the fingerprint matches the original EXACTLY

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

echo "=== DRILL 1: backup -> destroy -> restore round trip ==="
echo ""

# ---------------------------------------------------------------- 1. before --
echo "--- 1. state before any damage ---"
BEFORE_FP="$(fingerprint)"
BEFORE_CUST="$(row_count customers)"
BEFORE_ORD="$(row_count orders)"
BEFORE_ITEMS="$(row_count order_items)"
BEFORE_PROD="$(row_count products)"
echo "    customers  : $BEFORE_CUST"
echo "    products   : $BEFORE_PROD"
echo "    orders     : $BEFORE_ORD"
echo "    order_items: $BEFORE_ITEMS"
echo "    fingerprint: $BEFORE_FP"
[ -n "$BEFORE_FP" ] && pass "captured a pre-damage fingerprint" || fail "could not fingerprint the database"

# ------------------------------------------------------------- 2. backup -----
echo ""
echo "--- 2. full backup (WITH CHECKSUM), then RESTORE VERIFYONLY ---"
BACKUP_PATH="/backups/full/${DB_NAME}-restoredrill.bak"
sql "BACKUP DATABASE [$DB_NAME] TO DISK = N'$BACKUP_PATH'
     WITH INIT, FORMAT, CHECKSUM, COMPRESSION, NAME = N'restore drill base';" \
     | grep -E 'processed|BACKUP DATABASE' | tail -2
[ "$?" = "0" ] && pass "full backup written" || fail "backup failed"

sql "RESTORE VERIFYONLY FROM DISK = N'$BACKUP_PATH' WITH CHECKSUM;" | tail -1
[ "$?" = "0" ] && pass "RESTORE VERIFYONLY passed - the backup is restorable" || fail "VERIFYONLY failed"

BACKUP_SIZE="$(sqlv "SELECT CAST(backup_size AS BIGINT) FROM msdb.dbo.backupset
                     WHERE database_name='$DB_NAME' AND type='D' ORDER BY backup_finish_date DESC")"
echo "    backup size: ${BACKUP_SIZE} bytes"

# ------------------------------------------------------------- 3. destroy ----
echo ""
echo "--- 3. DESTROYING data ---"
echo "    deleting every order_item row, and dropping dbo.products entirely"
DAMAGE_START=$(date +%s%3N)
sql "USE $DB_NAME;
     DELETE FROM dbo.order_items;
     DELETE FROM dbo.orders;
     ALTER TABLE dbo.order_items DROP CONSTRAINT FK_items_product;
     DROP TABLE dbo.products;" | tail -2

# ------------------------------------------------------------- 4. prove ------
echo ""
echo "--- 4. proving the damage is real ---"
DAMAGED_ITEMS="$(row_count order_items)"
DAMAGED_ORD="$(row_count orders)"
FK_AFTER_DAMAGE="$(sqlv "USE $DB_NAME; SELECT COUNT(*) FROM sys.foreign_keys")"
PRODUCTS_EXIST="$(sqlv "USE $DB_NAME; SELECT COUNT(*) FROM sys.tables WHERE name='products'")"
echo "    order_items rows now : ${DAMAGED_ITEMS:-<table unreadable>}"
echo "    orders rows now      : ${DAMAGED_ORD:-<table unreadable>}"
echo "    foreign keys now     : $FK_AFTER_DAMAGE (was 3)"
echo "    dbo.products exists  : $PRODUCTS_EXIST (0 = dropped)"

[ "${DAMAGED_ITEMS:-0}" = "0" ] && pass "order_items emptied" || fail "delete did not take effect"
[ "${DAMAGED_ORD:-0}" = "0" ]   && pass "orders emptied"      || fail "delete did not take effect"
[ "$PRODUCTS_EXIST" = "0" ]     && pass "dbo.products dropped - schema damage, not just data loss" \
                                || fail "products table still present"

# --------------------------------------------------------- 5. restore --------
echo ""
echo "--- 5. restoring from the backup ---"
RESTORE_START=$(date +%s%3N)

# A restore needs exclusive access. Without SINGLE_USER the restore fails with
# "database is in use", and the drill would look like a broken backup rather
# than a busy database.
to_single_user
sql "RESTORE DATABASE [$DB_NAME] FROM DISK = N'$BACKUP_PATH'
     WITH REPLACE, RECOVERY, STATS = 25;" | grep -E 'processed|RESTORE DATABASE' | tail -2
RESTORE_RC=$?
to_multi_user

RESTORE_MS=$(( $(date +%s%3N) - RESTORE_START ))
echo "    restore wall time: ${RESTORE_MS} ms"
[ "$RESTORE_RC" = "0" ] && pass "RESTORE DATABASE completed" || fail "restore failed"

wait_for_sql 30 > /dev/null

# ---------------------------------------------------------- 6. compare -------
echo ""
echo "--- 6. does the restored data match the original EXACTLY? ---"
AFTER_FP="$(fingerprint)"
AFTER_CUST="$(row_count customers)"
AFTER_ORD="$(row_count orders)"
AFTER_ITEMS="$(row_count order_items)"
AFTER_PROD="$(row_count products)"

echo "    customers  : $BEFORE_CUST -> $AFTER_CUST"
echo "    products   : $BEFORE_PROD -> $AFTER_PROD"
echo "    orders     : $BEFORE_ORD -> $AFTER_ORD"
echo "    order_items: $BEFORE_ITEMS -> $AFTER_ITEMS"
echo ""
echo "    fingerprint before: $BEFORE_FP"
echo "    fingerprint after : $AFTER_FP"

[ "$AFTER_FP" = "$BEFORE_FP" ] \
  && pass "fingerprints are IDENTICAL - the restore is exact, not merely approximate" \
  || fail "fingerprint mismatch: data differs after restore"

[ "$AFTER_ITEMS" = "$BEFORE_ITEMS" ] && pass "order_items row count restored ($AFTER_ITEMS)" || fail "row count mismatch"
[ "$AFTER_PROD" = "$BEFORE_PROD" ]   && pass "dbo.products table and rows restored ($AFTER_PROD)" || fail "products not restored"

# Referential integrity has to survive too - counts alone would not catch a
# restore that broke the relationships between the tables.
ORPHANS="$(sqlv "USE $DB_NAME;
  SELECT (SELECT COUNT_BIG(*) FROM dbo.orders o WHERE NOT EXISTS (SELECT 1 FROM dbo.customers c WHERE c.customer_id=o.customer_id))
       + (SELECT COUNT_BIG(*) FROM dbo.order_items oi WHERE NOT EXISTS (SELECT 1 FROM dbo.orders o WHERE o.order_id=oi.order_id))
       + (SELECT COUNT_BIG(*) FROM dbo.order_items oi WHERE NOT EXISTS (SELECT 1 FROM dbo.products p WHERE p.product_id=oi.product_id))")"
echo "    orphaned rows across all foreign keys: $ORPHANS"
[ "$ORPHANS" = "0" ] && pass "referential integrity intact after restore" || fail "$ORPHANS orphaned rows"

# The constraints themselves must come back, not just the data.
CONSTRAINTS="$(sqlv "USE $DB_NAME; SELECT COUNT(*) FROM sys.foreign_keys")"
CHECKS="$(sqlv "USE $DB_NAME; SELECT COUNT(*) FROM sys.check_constraints")"
echo "    foreign keys restored : $CONSTRAINTS"
echo "    check constraints     : $CHECKS"
[ "${CONSTRAINTS:-0}" -ge 3 ] && pass "foreign keys restored with the schema" || fail "foreign keys missing"

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: DRILL 1 PASSED" || echo "RESULT: DRILL 1 FAILED"
exit "$RESULT"
