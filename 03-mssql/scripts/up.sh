#!/usr/bin/env bash
# Bring SQL Server up from nothing, create the database, apply the schema and
# seed it. Idempotent: safe to re-run.
#
#   scripts/up.sh

set -uo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STACK_DIR"
export MSYS_NO_PATHCONV=1

. "$STACK_DIR/scripts/lib.sh"

say() { printf '\n==> %s\n' "$*"; }

say "1. Configuration"

if [ -f .env ]; then
  echo "    .env present, left untouched"
else
  cp .env.example .env
  echo "    .env created from .env.example"
fi

SECRET_FILE=secrets/mssql_sa_password.txt
mkdir -p secrets

if [ -s "$SECRET_FILE" ]; then
  echo "    SA password secret present, left untouched"
else
  # SQL Server requires >= 8 chars from at least 3 of: upper, lower, digit,
  # symbol. Building the password from explicit parts guarantees all four
  # categories rather than hoping a random string happens to contain them —
  # a weak password makes the container exit at startup with one log line.
  RANDOM_PART="$(head -c 24 /dev/urandom | base64 | tr -d '\n=+/' | cut -c1-20)"
  printf 'Aa1!%s' "$RANDOM_PART" > "$SECRET_FILE"
  echo "    SA password generated ($(wc -c < "$SECRET_FILE") chars, 4/4 categories, not printed)"
fi
chmod 600 "$SECRET_FILE" 2>/dev/null || true

say "2. Build images"
docker compose build || { echo "build failed"; exit 1; }

say "3. Start the stack"
# --wait blocks until the healthcheck (a real SELECT 1, not a port probe)
# passes. SQL Server's first start initialises system databases and can take
# a minute, hence the generous timeout.
docker compose up -d --wait --wait-timeout 300 || {
  echo "    stack did not become healthy; recent engine logs:"
  docker compose logs --tail 40 mssql
  exit 1
}

say "4. Service state"
docker compose ps

say "5. Create database, schema and seed (idempotent)"
wait_for_sql 60 || { echo "SQL Server not answering queries"; exit 1; }

for f in sql/01-create-database.sql sql/02-schema.sql sql/03-seed.sql; do
  echo ""
  echo "--- $f ---"
  sqlfile "$f" || { echo "FAILED: $f"; exit 1; }
done

say "6. Current state"
sqlfile sql/90-state.sql

say "Stack is up"
echo "    connect: sqlcmd -S 127.0.0.1,${HOST_SQL_PORT:-1433} -U sa -C"
echo "    checks : scripts/verify.sh"
