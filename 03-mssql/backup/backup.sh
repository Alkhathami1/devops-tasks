#!/usr/bin/env bash
# Take one backup of a given type: full | diff | log
#
#   backup.sh full
#   backup.sh diff
#   backup.sh log
#
# Every backup is written WITH CHECKSUM and then validated with
# RESTORE VERIFYONLY. A backup that has never been verified is an assumption,
# not a recovery plan: a corrupt or truncated .bak fails at exactly the moment
# it is needed and there is no second chance.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TYPE="${1:-full}"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"

case "$TYPE" in
  full) EXT="bak";  SUBDIR="full" ;;
  diff) EXT="dif";  SUBDIR="diff" ;;
  log)  EXT="trn";  SUBDIR="log"  ;;
  *) echo "usage: $0 {full|diff|log}" >&2; exit 2 ;;
esac

mkdir -p "$BACKUP_DIR/$SUBDIR"
TARGET="$BACKUP_DIR/$SUBDIR/${DB_NAME}-${TYPE}-${STAMP}.${EXT}"

log INFO "starting $TYPE backup of $DB_NAME -> $TARGET"

# --- guard: log backups require FULL recovery -------------------------------
if [ "$TYPE" = "log" ]; then
    MODEL="$(sql_value "SELECT recovery_model_desc FROM sys.databases WHERE name = '$DB_NAME'")"
    if [ "$MODEL" != "FULL" ]; then
        log ERROR "recovery model is '$MODEL', not FULL. BACKUP LOG cannot run (Msg 4208)."
        exit 3
    fi
fi

# --- guard: a differential or log backup needs a full backup to base on ------
if [ "$TYPE" != "full" ]; then
    HAS_FULL="$(sql_value "SELECT COUNT(*) FROM msdb.dbo.backupset WHERE database_name = '$DB_NAME' AND type = 'D'")"
    if [ "${HAS_FULL:-0}" = "0" ]; then
        log ERROR "no full backup exists yet; a $TYPE backup has no base to apply to"
        exit 4
    fi
fi

# --- take the backup --------------------------------------------------------
case "$TYPE" in
  full)
    STMT="BACKUP DATABASE [$DB_NAME] TO DISK = N'$TARGET'
          WITH INIT, FORMAT, CHECKSUM, COMPRESSION, STATS = 25,
          NAME = N'$DB_NAME full backup $STAMP';"
    ;;
  diff)
    STMT="BACKUP DATABASE [$DB_NAME] TO DISK = N'$TARGET'
          WITH DIFFERENTIAL, INIT, CHECKSUM, COMPRESSION, STATS = 25,
          NAME = N'$DB_NAME differential backup $STAMP';"
    ;;
  log)
    STMT="BACKUP LOG [$DB_NAME] TO DISK = N'$TARGET'
          WITH INIT, CHECKSUM, COMPRESSION, STATS = 25,
          NAME = N'$DB_NAME log backup $STAMP';"
    ;;
esac

if ! sql "$STMT"; then
    log ERROR "$TYPE backup FAILED"
    rm -f "$TARGET"
    exit 5
fi

# --- verify -----------------------------------------------------------------
# VERIFYONLY re-reads the backup and validates its checksums. This is the step
# that turns "a file exists" into "a file that can be restored".
if ! sql "RESTORE VERIFYONLY FROM DISK = N'$TARGET' WITH CHECKSUM;"; then
    log ERROR "VERIFYONLY FAILED for $TARGET - the backup is not trustworthy"
    exit 6
fi

SIZE="$(stat -c %s "$TARGET" 2>/dev/null || echo 0)"
log INFO "$TYPE backup complete and verified: $TARGET ($SIZE bytes)"

# --- record it in a manifest for the retention pass and for evidence ---------
printf '%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$TYPE" "$TARGET" "$SIZE" \
    >> "$BACKUP_DIR/manifest.tsv"

exit 0
