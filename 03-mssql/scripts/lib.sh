#!/usr/bin/env bash
# Host-side helpers. All SQL runs via `docker exec` into the mssql container,
# so nothing needs to be installed on the host.

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MSYS_NO_PATHCONV=1   # keep Git Bash from rewriting container-side paths

SQL_CONTAINER="${SQL_CONTAINER:-task03-mssql}"
BACKUP_CONTAINER="${BACKUP_CONTAINER:-task03-backup}"
DB_NAME="${DB_NAME:-AppDb}"
SQLCMD_PATH="/opt/mssql-tools18/bin/sqlcmd"
SECRET_FILE="$STACK_DIR/secrets/mssql_sa_password.txt"

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }
info() { echo "[INFO] $*"; }

sa_password() { tr -d '\r\n' < "$SECRET_FILE"; }

# Run a T-SQL batch. -C trusts the self-signed certificate (mandatory with
# mssql-tools18, which encrypts by default); -b makes T-SQL errors set a
# non-zero exit code so failures cannot pass silently.
sql() {
    docker exec -i "$SQL_CONTAINER" "$SQLCMD_PATH" \
        -S localhost -U sa -P "$(sa_password)" -C -b -Q "$1"
}

# Single bare value, trimmed - suitable for capture into a shell variable.
#
# The filtering is not cosmetic. A query containing `USE AppDb;` makes sqlcmd
# print "Changed database context to 'AppDb'." on stdout BEFORE the result set.
# Unfiltered, THAT is what gets captured, and every later comparison compares
# two identical copies of the same message - which reads as a PASS while
# proving nothing whatsoever.
sqlv() {
    docker exec -i "$SQL_CONTAINER" "$SQLCMD_PATH" \
        -S localhost -U sa -P "$(sa_password)" -C -b -h -1 -W \
        -Q "SET NOCOUNT ON; $1" 2>/dev/null | grep -v -e '^$' -e 'Changed database context' -e 'Changed language setting' -e 'rows affected' | head -1 | tr -d '\r'
}

# Run a .sql file that lives in the repo, by piping it in.
sqlfile() {
    docker exec -i "$SQL_CONTAINER" "$SQLCMD_PATH" \
        -S localhost -U sa -P "$(sa_password)" -C -b < "$1"
}

# The whole-database fingerprint used to prove a restore is exact.
fingerprint() {
    sqlv "USE $DB_NAME;
          SELECT CONCAT(
            (SELECT COUNT_BIG(*) FROM dbo.customers),   '|',
            (SELECT COUNT_BIG(*) FROM dbo.products),    '|',
            (SELECT COUNT_BIG(*) FROM dbo.orders),      '|',
            (SELECT COUNT_BIG(*) FROM dbo.order_items), '|',
            (SELECT ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(*)),0) FROM dbo.customers),   '|',
            (SELECT ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(*)),0) FROM dbo.products),    '|',
            (SELECT ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(*)),0) FROM dbo.orders),      '|',
            (SELECT ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(*)),0) FROM dbo.order_items), '|',
            (SELECT ISNULL(CAST(SUM(quantity*unit_price*100) AS BIGINT),0) FROM dbo.order_items))"
}

row_count() { sqlv "USE $DB_NAME; SELECT COUNT_BIG(*) FROM dbo.$1"; }

# Server-local time, formatted for STOPAT. Deliberately the SERVER clock, not
# the host's: STOPAT is interpreted in the server's local time zone, and the
# two differ here (host is +03, container is UTC).
server_now() { sqlv "SELECT CONVERT(VARCHAR(23), SYSDATETIME(), 126)"; }

# Restoring needs exclusive access; other sessions must be evicted first.
to_single_user() {
    sql "ALTER DATABASE [$DB_NAME] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" > /dev/null 2>&1
}
to_multi_user() {
    sql "ALTER DATABASE [$DB_NAME] SET MULTI_USER;" > /dev/null 2>&1
}

wait_for_sql() {
    for i in $(seq 1 "${1:-90}"); do
        [ "$(sqlv 'SELECT 1' 2>/dev/null)" = "1" ] && return 0
        sleep 2
    done
    return 1
}
