#!/usr/bin/env bash
# fmt, validate and plan. Creates nothing.
set -uo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STACK_DIR/terraform"

echo "=== terraform fmt -check -recursive ==="
if terraform fmt -check -recursive; then
  echo "  formatting clean"
else
  echo "  FAILED: run terraform fmt"
  exit 1
fi

echo ""
echo "=== terraform init ==="
terraform init -input=false -no-color | tail -3

echo ""
echo "=== terraform validate ==="
terraform validate -no-color

echo ""
echo "=== terraform plan ==="
terraform plan -input=false -no-color -out=tfplan.binary
