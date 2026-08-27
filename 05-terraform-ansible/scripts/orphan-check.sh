#!/usr/bin/env bash
# After destroy: confirm the project is actually empty.
#
# `terraform destroy` reporting success is NOT the same as nothing being left.
# Anything created outside Terraform, or orphaned by a partial failure, is
# invisible to state and outlives it silently. These are the classes that
# with no instance attached:
#
#   static addresses   persist while RESERVED and unattached
#   persistent disks   survive instance deletion if
#                      auto-delete was off
#   Cloud NAT gateway  survives if the router is left behind
#   Cloud Router       no charge itself, but keeps a NAT alive
#   snapshots/images   persist independently of their source
set -uo pipefail
P="${GCP_PROJECT:-test-environment-506521}"
gc() { env -u MSYS_NO_PATHCONV gcloud "$@"; }

FOUND=0
check() {
  local label="$1"; shift
  local out
  out="$("$@" 2>/dev/null)"
  local n
  n="$(echo "$out" | grep -c '[^[:space:]]' || true)"
  if [ "${n:-0}" -eq 0 ]; then
    printf '  [CLEAN]   %-22s none\n' "$label"
  else
    printf '  [ORPHAN]  %-22s %s found\n' "$label" "$n"
    echo "$out" | sed 's/^/            /'
    FOUND=$((FOUND + n))
  fi
}

echo "=== Post-destroy orphan check: project $P ==="
echo ""
echo "Classes that survive instance deletion:"
check "static addresses"  gc compute addresses  list --project="$P" --format='value(name,region,status)'
check "persistent disks"  gc compute disks      list --project="$P" --format='value(name,zone,sizeGb)'
check "Cloud NAT"         gc compute routers    list --project="$P" --format='value(name,region)'
check "snapshots"         gc compute snapshots  list --project="$P" --format='value(name,diskSizeGb)'
check "custom images"     gc compute images     list --project="$P" --no-standard-images --format='value(name)'
echo ""
echo "Classes tied to the stack, which should also be gone:"
check "instances"         gc compute instances  list --project="$P" --format='value(name,zone,status)'
check "task05 networks"   bash -c "env -u MSYS_NO_PATHCONV gcloud compute networks list --project=$P --format='value(name)' | grep task05 || true"
check "task05 firewalls"  bash -c "env -u MSYS_NO_PATHCONV gcloud compute firewall-rules list --project=$P --format='value(name)' | grep task05 || true"
check "task05 svc accts"  bash -c "env -u MSYS_NO_PATHCONV gcloud iam service-accounts list --project=$P --format='value(email)' | grep task05 || true"

echo ""
echo "================================================================"
if [ "$FOUND" -eq 0 ]; then
  echo "RESULT: PROJECT CLEAN - nothing left behind, nothing left running"
else
  echo "RESULT: $FOUND ORPHANED RESOURCE(S) - these are still present"
fi
echo "================================================================"
exit "$FOUND"
