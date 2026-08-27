#!/usr/bin/env bash
# Backup scheduler — the sidecar's PID 1.
#
# WHY A SIDECAR RATHER THAN SQL SERVER AGENT
# ------------------------------------------
# SQL Server Agent is the native scheduler and would normally be the right
# answer. In the Linux container it is present but DISABLED by default, and
# enabling it requires MSSQL_AGENT_ENABLED=true plus a container restart.
# `scripts/checks/agent-availability.sh` probes this on the running instance
# and records what is actually true here rather than relying on folklore.
#
# The sidecar is used regardless because it keeps the schedule in version
# control as plain shell, works identically on Express edition (where Agent is
# genuinely absent), and makes the backup logic runnable by hand for the drills.
#
# A plain loop is used rather than cron: cron in a container needs a running
# daemon, does not inherit the container environment without help, and swallows
# stdout so backup output never reaches `docker logs`. A loop is simpler and its
# output is visible where an operator would look for it.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FULL_INTERVAL_SEC="${FULL_INTERVAL_SEC:-3600}"
DIFF_INTERVAL_SEC="${DIFF_INTERVAL_SEC:-900}"
LOG_INTERVAL_SEC="${LOG_INTERVAL_SEC:-300}"
RETENTION_INTERVAL_SEC="${RETENTION_INTERVAL_SEC:-1800}"
TICK_SEC="${TICK_SEC:-15}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log INFO "backup scheduler starting"
log INFO "  full backup      every ${FULL_INTERVAL_SEC}s"
log INFO "  differential     every ${DIFF_INTERVAL_SEC}s"
log INFO "  transaction log  every ${LOG_INTERVAL_SEC}s"
log INFO "  retention pass   every ${RETENTION_INTERVAL_SEC}s"

mkdir -p "$BACKUP_DIR"/{full,diff,log}

if ! wait_for_sql 120; then
    log ERROR "giving up waiting for SQL Server"
    exit 1
fi

# Wait for the database itself, not just the instance: the init job may still
# be creating it when this sidecar starts.
for i in $(seq 1 120); do
    EXISTS="$(sql_value "SELECT COUNT(*) FROM sys.databases WHERE name = '$DB_NAME'")"
    [ "${EXISTS:-0}" = "1" ] && { log INFO "database $DB_NAME is present"; break; }
    log INFO "waiting for database $DB_NAME to be created ($i)"
    sleep 2
done

# Take an immediate full backup so a restore chain exists from the moment the
# stack is up, rather than only after the first hour elapses.
log INFO "taking initial full backup so a restore base exists immediately"
"$HERE/backup.sh" full || log ERROR "initial full backup failed"

NOW=$(date +%s)
LAST_FULL=$NOW
LAST_DIFF=$NOW
LAST_LOG=$NOW
LAST_RETENTION=$NOW

# Graceful shutdown so `docker compose down` is not a 10s SIGKILL wait.
RUNNING=1
trap 'log INFO "received shutdown signal"; RUNNING=0' TERM INT

while [ "$RUNNING" = "1" ]; do
    NOW=$(date +%s)

    if [ $((NOW - LAST_FULL)) -ge "$FULL_INTERVAL_SEC" ]; then
        "$HERE/backup.sh" full && LAST_FULL=$NOW || log ERROR "scheduled full backup failed"
    fi

    if [ $((NOW - LAST_DIFF)) -ge "$DIFF_INTERVAL_SEC" ]; then
        "$HERE/backup.sh" diff && LAST_DIFF=$NOW || log ERROR "scheduled differential backup failed"
    fi

    if [ $((NOW - LAST_LOG)) -ge "$LOG_INTERVAL_SEC" ]; then
        "$HERE/backup.sh" log && LAST_LOG=$NOW || log ERROR "scheduled log backup failed"
    fi

    if [ $((NOW - LAST_RETENTION)) -ge "$RETENTION_INTERVAL_SEC" ]; then
        "$HERE/retention.sh" && LAST_RETENTION=$NOW || log ERROR "retention pass failed"
    fi

    sleep "$TICK_SEC"
done

log INFO "scheduler stopped"
