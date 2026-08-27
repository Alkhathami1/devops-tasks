#!/usr/bin/env bash
# Bring the whole stack up from nothing. Idempotent: safe to re-run.
#
#   scripts/up.sh
#
# Creates .env from .env.example and generates the database password secret if
# they do not already exist, builds the images, starts the stack, and blocks
# until every service reports healthy.

set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STACK_DIR"

# Git Bash rewrites arguments that look like absolute POSIX paths into Windows
# paths before handing them to docker.exe. That corrupts container-side paths
# such as /run/secrets/... so it is disabled for everything here.
export MSYS_NO_PATHCONV=1

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

say "1. Configuration"

if [ -f .env ]; then
  echo "    .env already present, left untouched"
else
  cp .env.example .env
  echo "    .env created from .env.example"
fi

SECRET_FILE=secrets/postgres_password.txt
mkdir -p secrets

if [ -s "$SECRET_FILE" ]; then
  echo "    database password secret already present, left untouched"
else
  # 32 bytes of CSPRNG output, base64, stripped of characters that complicate
  # shell quoting and Postgres URIs.
  if command -v openssl > /dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '\n=+/' > "$SECRET_FILE"
  else
    head -c 32 /dev/urandom | base64 | tr -d '\n=+/' > "$SECRET_FILE"
  fi
  echo "    database password secret generated ($(wc -c < "$SECRET_FILE") chars, not printed)"
fi

# The secret must not be world readable. Best effort on Windows filesystems.
chmod 600 "$SECRET_FILE" 2>/dev/null || true

say "2. Build images"
docker compose build

say "3. Start the stack"
# --wait blocks until every service with a healthcheck is healthy, or fails.
# This is what makes the whole bring-up a single command with no manual polling.
docker compose up -d --wait --wait-timeout 180

say "4. Service state"
docker compose ps

say "Stack is up"
HOST_PORT="$(grep -E '^HOST_PORT=' .env | cut -d= -f2 || echo 8080)"
echo "    frontend  : http://127.0.0.1:${HOST_PORT:-8080}/"
echo "    API       : http://127.0.0.1:${HOST_PORT:-8080}/api/items"
echo "    run checks: scripts/verify.sh"
