#!/bin/bash
# Entrypoint wrapper for SQL Server.
#
# WHY THIS EXISTS — the secrets tension, stated honestly.
#
# The Postgres image reads POSTGRES_PASSWORD_FILE natively, so the password
# never has to become an environment variable. The SQL Server image has no
# equivalent: sqlservr reads MSSQL_SA_PASSWORD from the environment and there
# is no supported _FILE convention.
#
# The mitigation is this wrapper. The secret is read from the mounted file and
# exported ONLY into the process this script execs. The consequence:
#
#   * the password does NOT appear in `docker inspect` (nothing is set via
#     compose `environment:`), which is where an attacker with socket access
#     looks first and which persists for the life of the container
#   * the password DOES appear in /proc/1/environ INSIDE the container, because
#     sqlservr requires it there. Anyone who can already exec into the container
#     as root can read it
#
# That residual exposure is unavoidable without patching the image, and it is
# strictly smaller than putting the password in compose. The backup sidecar has
# no such constraint and reads the secret file directly, never exporting it.

set -euo pipefail

SECRET_FILE="${MSSQL_SA_PASSWORD_FILE:-/run/secrets/mssql_sa_password}"

fail() { echo "FATAL: $*" >&2; exit 1; }

if [ ! -r "$SECRET_FILE" ]; then
    fail "SA password secret not readable at $SECRET_FILE"
fi

PASSWORD="$(tr -d '\r\n' < "$SECRET_FILE")"

# ---------------------------------------------------------------------------
# Validate complexity BEFORE handing off to sqlservr.
#
# SQL Server rejects a weak SA password and then exits, logging a single line
# and leaving a container that simply will not start. Validating here turns
# that into an explicit, readable error instead of a silent startup failure
# that looks like a broken image.
#
# Policy: at least 8 characters, and characters from at least three of
# uppercase / lowercase / digits / symbols.
# ---------------------------------------------------------------------------
LENGTH=${#PASSWORD}
[ "$LENGTH" -ge 8 ] || fail "SA password is $LENGTH characters; SQL Server requires at least 8"

CATEGORIES=0
[[ "$PASSWORD" =~ [A-Z] ]]                  && CATEGORIES=$((CATEGORIES + 1))
[[ "$PASSWORD" =~ [a-z] ]]                  && CATEGORIES=$((CATEGORIES + 1))
[[ "$PASSWORD" =~ [0-9] ]]                  && CATEGORIES=$((CATEGORIES + 1))
[[ "$PASSWORD" =~ [^A-Za-z0-9] ]]           && CATEGORIES=$((CATEGORIES + 1))

if [ "$CATEGORIES" -lt 3 ]; then
    fail "SA password uses only $CATEGORIES of the 4 character categories; SQL Server requires at least 3 (upper, lower, digit, symbol)"
fi

echo "[entrypoint] SA password read from $SECRET_FILE (${LENGTH} chars, ${CATEGORIES}/4 categories) - not logged"
echo "[entrypoint] MSSQL_MEMORY_LIMIT_MB=${MSSQL_MEMORY_LIMIT_MB:-<unset>}  MSSQL_PID=${MSSQL_PID:-<unset>}  MSSQL_AGENT_ENABLED=${MSSQL_AGENT_ENABLED:-<unset>}"

export MSSQL_SA_PASSWORD="$PASSWORD"
unset PASSWORD

# exec so sqlservr becomes PID 1 and receives signals directly.
exec "$@"
