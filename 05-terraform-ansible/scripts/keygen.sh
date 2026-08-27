#!/usr/bin/env bash
# Generate the SSH keypair Ansible uses. Idempotent: never overwrites.
set -uo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYDIR="$STACK_DIR/.ssh"
KEY="$KEYDIR/task05_ed25519"

mkdir -p "$KEYDIR"
if [ -f "$KEY" ]; then
  echo "keypair already present at $KEY"
else
  ssh-keygen -t ed25519 -N '' -C 'ansible@task05' -f "$KEY" > /dev/null
  echo "generated $KEY"
fi
chmod 600 "$KEY" 2>/dev/null || true
echo ""
echo "public key (goes into terraform.tfvars as ssh_public_key):"
cat "$KEY.pub"
