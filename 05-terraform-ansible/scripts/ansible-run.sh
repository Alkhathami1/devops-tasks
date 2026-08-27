#!/usr/bin/env bash
# Run the playbook from the containerised control node.
#
#   scripts/ansible-run.sh                    one run
#   scripts/ansible-run.sh --check-idempotent run twice, fail if the second changes anything
set -uo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$STACK_DIR/.." && pwd)"
export MSYS_NO_PATHCONV=1

IMAGE=task05-ansible:1.0.0
# ANSIBLE_CONFIG must be set explicitly. Ansible refuses to auto-discover an
# ansible.cfg in a world-writable directory, and a Windows bind mount always
# presents as 0777 inside the container - so the config is silently ignored and
# the inventory comes up empty with only an implicit localhost.
CFG=/work/05-terraform-ansible/ansible/ansible.cfg
INV=/work/05-terraform-ansible/ansible/inventory/hosts.yml
KEY=/work/05-terraform-ansible/.ssh/task05_ed25519

RUN="docker run --rm -v ${REPO_ROOT}:/work -w /work/05-terraform-ansible/ansible      -e ANSIBLE_CONFIG=${CFG} -e ANSIBLE_INVENTORY=${INV} ${IMAGE}"

# The key must be 0600 or ssh refuses it; the bind mount does not preserve that.
PREP="install -m 600 ${KEY} /tmp/k && printf 'Host *\n  IdentityFile /tmp/k\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  ServerAliveInterval 15\n' > /tmp/ssh_config &&"

run_once() {
  $RUN "$PREP ansible-playbook site.yml ${1:-}"
}

if [ "${1:-}" = "--check-idempotent" ]; then
  echo "############################################################"
  echo "# RUN 1 - convergence"
  echo "############################################################"
  run_once
  echo ""
  echo "############################################################"
  echo "# RUN 2 - idempotency: every changed= must be 0"
  echo "############################################################"
  OUT="$($RUN "$PREP ansible-playbook site.yml" 2>&1)"
  echo "$OUT"
  echo ""
  echo "=== idempotency verdict ==="
  # awk, not bc: bc is not installed in the control-node image, so the sum came
  # back as "?" and the verdict reported FAIL against a run that was in fact
  # perfectly idempotent - a false negative, the mirror of a false green.
  CHANGED="$(echo "$OUT" | grep -oE 'changed=[0-9]+' | grep -oE '[0-9]+' | awk '{t+=$1} END {print t+0}')"
  echo "    total changed across all hosts on the second run: ${CHANGED:-?}"
  if [ "${CHANGED:-1}" = "0" ]; then
    echo "[PASS] idempotent: the second run changed nothing"
    exit 0
  else
    echo "[FAIL] the second run reported ${CHANGED} change(s); the playbook is not idempotent"
    exit 1
  fi
fi

run_once "$@"
