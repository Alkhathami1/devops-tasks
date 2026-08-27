#!/usr/bin/env bash
# Shared helpers for the backup sidecar.
#
# sqlcmd notes for SQL Server 2022 images, both of which bite immediately:
#   * the binary moved to /opt/mssql-tools18/bin/sqlcmd (the old
#     /opt/mssql-tools/bin path is gone)
#   * tools18 defaults to an ENCRYPTED connection and validates the server
#     certificate. The container's certificate is self-signed, so every command
#     fails with "SSL Provider: certificate verify failed" unless -C
#     (trust server certificate) is passed.

SQLCMD="${SQLCMD:-/opt/mssql-tools18/bin/sqlcmd}"
SQL_HOST="${SQL_HOST:-mssql}"
SQL_USER="${SQL_USER:-sa}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
DB_NAME="${DB_NAME:-AppDb}"

# Read the SA password from the file-based secret, never from an env var.
read_password() {
    local file="${SA_PASSWORD_FILE:-/run/secrets/mssql_sa_password}"
    if [ ! -r "$file" ]; then
        echo "FATAL: cannot read password secret at $file" >&2
        return 1
    fi
    tr -d '\r\n' < "$file"
}

# Run a query. -b makes sqlcmd exit non-zero on a T-SQL error, which is what
# lets a failed BACKUP actually fail the script instead of being logged and
# ignored.
sql() {
    local query="$1"
    "$SQLCMD" -S "$SQL_HOST" -U "$SQL_USER" -P "$(read_password)" -C -b \
        -Q "$query"
}

# Run a query returning a single bare value, suitable for capture.
sql_value() {
    local query="$1"
    "$SQLCMD" -S "$SQL_HOST" -U "$SQL_USER" -P "$(read_password)" -C -b \
        -h -1 -W -Q "SET NOCOUNT ON; $query" 2>/dev/null | head -1 | tr -d '\r'
}

# Run a script file.
sql_file() {
    local file="$1"
    "$SQLCMD" -S "$SQL_HOST" -U "$SQL_USER" -P "$(read_password)" -C -b \
        -i "$file"
}

log() {
    printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${1}" "${2}"
}

wait_for_sql() {
    local attempts="${1:-60}"
    for i in $(seq 1 "$attempts"); do
        if sql_value "SELECT 1" 2>/dev/null | grep -q '^1$'; then
            log INFO "SQL Server is accepting queries (attempt $i)"
            return 0
        fi
        sleep 2
    done
    log ERROR "SQL Server did not become available after $attempts attempts"
    return 1
}
