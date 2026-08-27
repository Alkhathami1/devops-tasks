#!/usr/bin/env bash
# Bring the Task 01 environment up from nothing. Idempotent.

set -uo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STACK_DIR"
export MSYS_NO_PATHCONV=1

say() { printf '\n==> %s\n' "$*"; }

say "1. Configuration"
if [ -s secrets/smb_password.txt ]; then
  echo "    SMB password secret present, left untouched"
else
  mkdir -p secrets
  printf 'Sm1!%s' "$(head -c 18 /dev/urandom | base64 | tr -d '\n=+/' | cut -c1-16)" > secrets/smb_password.txt
  chmod 600 secrets/smb_password.txt
  echo "    SMB password generated ($(wc -c < secrets/smb_password.txt) chars, not printed)"
fi

say "2. Load the cifs kernel module"
# A container cannot modprobe: it has no /lib/modules. The module has to be
# live in the kernel the container shares, so it is loaded from the WSL distro.
if wsl -d docker-desktop -e sh -c 'modprobe cifs 2>/dev/null; grep -q cifs /proc/filesystems'; then
  echo "    cifs module loaded and visible in /proc/filesystems"
else
  echo "    WARNING: could not load the cifs module; SMB mounts will fail"
fi

say "3. Build and start"
docker compose build || exit 1
docker compose up -d --wait --wait-timeout 240 || {
  echo "    did not become healthy; recent logs:"
  docker compose logs --tail 30 linuxbox
  exit 1
}

say "4. Service state"
docker compose ps

say "5. Endpoints"
echo "    node_exporter : http://127.0.0.1:9100/metrics"
echo "    Prometheus    : http://127.0.0.1:9090"
echo "    alerts        : http://127.0.0.1:9090/alerts"
echo "    run checks    : ./scripts/verify.sh"
