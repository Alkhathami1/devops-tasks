#!/usr/bin/env bash
# Retention: delete backups older than their tier's retention window.
#
# Without this, backups grow without bound until the volume fills and — the
# genuinely dangerous part — the next backup FAILS for lack of space, meaning
# the first symptom of a full disk is having no recent backup at all.
#
# Windows are deliberately different per tier, because the tiers have different
# jobs:
#   full  kept longest  - the base every restore chain starts from
#   diff  medium        - only useful until the next full backup supersedes it
#   log   shortest      - only useful for PITR within the recent window, but
#                         they are also the most numerous
#
# Retention here is measured in MINUTES so the drill can demonstrate it inside
# a test run. Production values belong in .env.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FULL_RETENTION_MIN="${FULL_RETENTION_MIN:-1440}"
DIFF_RETENTION_MIN="${DIFF_RETENTION_MIN:-360}"
LOG_RETENTION_MIN="${LOG_RETENTION_MIN:-120}"

prune() {
    local subdir="$1" minutes="$2" label="$3"
    local dir="$BACKUP_DIR/$subdir"
    [ -d "$dir" ] || return 0

    local before after
    before="$(find "$dir" -type f | wc -l)"

    # -mmin +N is "modified more than N minutes ago".
    find "$dir" -type f -mmin "+$minutes" -print -delete | while read -r f; do
        log INFO "retention: removed $label backup $(basename "$f") (older than ${minutes}m)"
    done

    after="$(find "$dir" -type f | wc -l)"
    log INFO "retention: $label $before -> $after files (window ${minutes}m)"
}

log INFO "retention pass starting"
prune full "$FULL_RETENTION_MIN" full
prune diff "$DIFF_RETENTION_MIN" differential
prune log  "$LOG_RETENTION_MIN"  log

# Never prune the last full backup, whatever its age: deleting the only base
# would leave the differentials and logs unrestorable.
REMAINING_FULL="$(find "$BACKUP_DIR/full" -type f 2>/dev/null | wc -l)"
if [ "$REMAINING_FULL" = "0" ]; then
    log WARN "retention removed every full backup; taking a fresh one to keep the chain restorable"
    "$(dirname "${BASH_SOURCE[0]}")/backup.sh" full
fi

log INFO "retention pass complete"
