#!/usr/bin/env bash
# Prove the architecture by measurement, not by reading the configuration.
#
# Everything here is an observation against the running estate: a request that
# succeeds, a connection that is refused, a route that does not exist. Reading
# firewall.tf back and asserting it says what it says would prove nothing.

set -uo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$STACK_DIR/.." && pwd)"
TF="$STACK_DIR/terraform"

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }
info() { echo "       $*"; }

# gcloud must run WITHOUT MSYS_NO_PATHCONV. It is a batch wrapper that
# resolves its own library path, and with the variable set it fails to find
# gcloud.py - returning empty output rather than an error. That silently
# turned "no routes found" into a false FAIL when this script was invoked
# from a wrapper that exported the variable for docker.
gc() { env -u MSYS_NO_PATHCONV gcloud "$@"; }

tfout() { (cd "$TF" && MSYS_NO_PATHCONV=1 terraform output -raw "$1" 2>/dev/null); }

BASTION="$(tfout bastion_public_ip)"
NGINX_PUB="$(tfout nginx_public_ip)"
NGINX_PRIV="$(tfout nginx_private_ip)"
APP_IP="$(tfout app_private_ip)"
DB_IP="$(tfout db_private_ip)"
SSH_USER="$(tfout ssh_user)"

# Run a command on a host through the Ansible container, reusing the same
# ProxyJump chain the playbook uses.
onhost() {
  local host="$1" cmd="$2"
  MSYS_NO_PATHCONV=1 docker run --rm -v "${REPO_ROOT}:/work" \
    -w /work/05-terraform-ansible/ansible \
    -e ANSIBLE_CONFIG=/work/05-terraform-ansible/ansible/ansible.cfg \
    -e ANSIBLE_INVENTORY=/work/05-terraform-ansible/ansible/inventory/hosts.yml \
    task05-ansible:1.0.0 \
    "install -m 600 /work/05-terraform-ansible/.ssh/task05_ed25519 /tmp/k \
     && printf 'Host *\n  IdentityFile /tmp/k\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n' > /tmp/ssh_config \
     && ansible ${host} -b -m shell -a \"${cmd}\" 2>/dev/null | tail -n +2" 2>/dev/null
}

echo "================================================================"
echo "Task 05 — architecture verified by measurement"
echo "timestamp : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "================================================================"
echo ""
echo "  bastion (public) : $BASTION"
echo "  nginx   (public) : $NGINX_PUB / $NGINX_PRIV"
echo "  app     (apps)   : $APP_IP        no public address"
echo "  db      (dbs)    : $DB_IP        no public address"

# ---------------------------------------------------------------------------
echo ""
echo "=== 1. The happy path: internet -> nginx -> app -> database ==="
echo ""
echo "    HTTPS through the public entry point (-k: self-signed cert):"
BODY="$(curl -sk --max-time 20 "https://${NGINX_PUB}/api/items" 2>&1)"
echo "$BODY" | head -c 400 | sed 's/^/      /'
echo ""
if echo "$BODY" | grep -q '"items"'; then
  pass "an HTTP request through nginx returned DB-backed data"
else
  fail "no DB-backed payload came back through the proxy"
fi
echo "$BODY" | grep -q 'seeded-by-ansible' \
  && pass "the row Ansible seeded in PostgreSQL is visible through the proxy" \
  || fail "seeded row not present"

echo ""
echo "    a WRITE through the proxy, then read back (app reads AND writes the DB):"
STAMP="verify-$(date -u '+%H%M%S')"
CREATED="$(curl -sk --max-time 20 -X POST "https://${NGINX_PUB}/api/items" \
  -H 'Content-Type: application/json' -d "{\"name\":\"${STAMP}\"}" 2>&1)"
echo "$CREATED" | head -c 200 | sed 's/^/      POST -> /'
echo ""
READBACK="$(curl -sk --max-time 20 "https://${NGINX_PUB}/api/items" 2>&1)"
if echo "$READBACK" | grep -q "$STAMP"; then
  pass "the written row is returned by a subsequent read - the app tier reads and writes the DB"
else
  fail "written row not found on read-back"
fi

echo ""
echo "    nginx's own health, distinct from the app's:"
curl -sk --max-time 10 "https://${NGINX_PUB}/nginx-health" | sed 's/^/      /'
echo ""

# ---------------------------------------------------------------------------
echo ""
echo "=== 2. The private tiers are NOT reachable from the internet ==="
echo ""
echo "    These addresses are RFC1918 and have no public NIC at all, so the"
echo "    attempt cannot even leave this machine correctly. That is the point:"
echo "    there is no address to attack."
for target in "app:${APP_IP}:8080" "db:${DB_IP}:5432"; do
  NAME="${target%%:*}"; REST="${target#*:}"; IP="${REST%%:*}"; PORT="${REST##*:}"
  OUT="$(curl -s --connect-timeout 8 "http://${IP}:${PORT}/" 2>&1; echo "exit=$?")"
  CODE="$(echo "$OUT" | grep -oE 'exit=[0-9]+' | cut -d= -f2)"
  info "direct to ${NAME} ${IP}:${PORT} -> curl exit ${CODE} (7=refused, 28=timeout)"
  [ "$CODE" != "0" ] && pass "${NAME} tier unreachable directly from the internet" \
                     || fail "${NAME} tier answered a direct request"
done

echo ""
echo "    and SSH to the private tiers from here is equally impossible:"
for target in "app:${APP_IP}" "db:${DB_IP}"; do
  NAME="${target%%:*}"; IP="${target##*:}"
  OUT="$(MSYS_NO_PATHCONV=1 docker run --rm alpine:3.20 sh -c "nc -z -w6 ${IP} 22; echo exit=\$?" 2>/dev/null | tail -1)"
  info "nc ${NAME} ${IP}:22 from an unprivileged container -> ${OUT}"
  echo "$OUT" | grep -q 'exit=0' && fail "${NAME}:22 reachable from outside" \
                                 || pass "${NAME}:22 not reachable from outside the VPC"
done

# ---------------------------------------------------------------------------
echo ""
echo "=== 3. The database accepts the app tier and nothing else ==="
echo ""
echo "    from the APP tier (permitted: apps subnet -> dbs:5432):"
APP_TO_DB="$(onhost app "timeout 8 bash -c '</dev/tcp/${DB_IP}/5432' && echo REACHABLE || echo BLOCKED")"
info "app -> db:5432 : $(echo "$APP_TO_DB" | tr -d '\r' | tail -1)"
echo "$APP_TO_DB" | grep -q REACHABLE \
  && pass "the app tier can reach PostgreSQL" \
  || fail "the app tier cannot reach the database"

echo ""
echo "    from the PUBLIC tier (nginx). This is the peering non-transitivity"
echo "    test: public peers with apps, apps peers with dbs, and yet there is"
echo "    NO route from public to dbs. Not a firewall rule - no route exists."
NGINX_TO_DB="$(onhost nginx "timeout 8 bash -c '</dev/tcp/${DB_IP}/5432' && echo REACHABLE || echo BLOCKED")"
info "nginx -> db:5432 : $(echo "$NGINX_TO_DB" | tr -d '\r' | tail -1)"
echo "$NGINX_TO_DB" | grep -q BLOCKED \
  && pass "the public tier CANNOT reach the database - peering is non-transitive" \
  || fail "the public tier reached the database; the tier boundary is broken"

echo ""
echo "    the same from the bastion, which is also in the public tier:"
BAS_TO_DB="$(onhost bastion "timeout 8 bash -c '</dev/tcp/${DB_IP}/5432' && echo REACHABLE || echo BLOCKED")"
info "bastion -> db:5432 : $(echo "$BAS_TO_DB" | tr -d '\r' | tail -1)"
echo "$BAS_TO_DB" | grep -q BLOCKED \
  && pass "the bastion cannot reach the database either" \
  || fail "the bastion reached the database"

echo ""
echo "    control: the public tier CAN reach the app tier, so the failure above"
echo "    is specific to the dbs VPC and not a broken host:"
NGINX_TO_APP="$(onhost nginx "timeout 8 bash -c '</dev/tcp/${APP_IP}/8080' && echo REACHABLE || echo BLOCKED")"
info "nginx -> app:8080 : $(echo "$NGINX_TO_APP" | tr -d '\r' | tail -1)"
echo "$NGINX_TO_APP" | grep -q REACHABLE \
  && pass "public -> apps works, so the public->dbs failure is the peering topology" \
  || fail "public cannot reach apps either; something else is wrong"

# ---------------------------------------------------------------------------
echo ""
echo "=== 4. Routing tables: the absence of a route, from GCP itself ==="
echo ""
echo "    Routes in the PUBLIC VPC (note: no 10.30.0.0/16 destination):"
gc compute routes list --project="$(cd "$TF" && MSYS_NO_PATHCONV=1 terraform output -raw project_id 2>/dev/null || echo test-environment-506521)" \
  --filter="network:task05-public-vpc" --format='table(name,destRange,nextHopPeering)' 2>/dev/null | sed 's/^/      /'
echo ""
PUB_ROUTES="$(gc compute routes list --project=test-environment-506521 --filter='network:task05-public-vpc' --format='value(destRange)' 2>/dev/null)"
echo "$PUB_ROUTES" | grep -q '10.30' \
  && fail "a route to the dbs range exists in the public VPC" \
  || pass "no route to 10.30.0.0/16 exists in the public VPC - the packet has nowhere to go"

echo "$PUB_ROUTES" | grep -q '10.20' \
  && pass "a route to 10.20.0.0/16 (apps) does exist, via the peering" \
  || fail "no route to the apps range"

# ---------------------------------------------------------------------------
echo ""
echo "=== 5. WireGuard VPN ==="
echo ""
WG="$(onhost bastion "wg show")"
echo "$WG" | sed 's/^/      /'
echo ""
echo "$WG" | grep -q 'interface: wg0' \
  && pass "the WireGuard interface is up on the bastion" \
  || fail "wg0 is not up"
echo "$WG" | grep -q 'public key' \
  && pass "a peer is configured" || fail "no peer configured"

FWD="$(onhost bastion "cat /proc/sys/net/ipv4/ip_forward" | tr -d "
" | tail -1 | tr -d " ")"
info "net.ipv4.ip_forward = $(echo "$FWD" | tr -d '\r' | tail -1)"
[ "$FWD" = "1" ] \
  && pass "IP forwarding is on - without it the tunnel establishes but nothing routes" \
  || fail "IP forwarding is not 1 (got: ${FWD})"

echo ""
echo "    UDP 51820 is open to the internet but answers nothing unsigned:"
SCAN="$(MSYS_NO_PATHCONV=1 docker run --rm alpine:3.20 sh -c "nc -u -z -w4 ${BASTION} 51820; echo exit=\$?" 2>/dev/null | tail -1)"
info "unauthenticated UDP probe -> ${SCAN}"
info "WireGuard drops any handshake not signed by a known peer key, silently."

echo ""
echo "    the client configuration the operator would import:"
onhost bastion "sed -e 's/^PrivateKey.*/PrivateKey = <REDACTED>/' /etc/wireguard/client-wg0.conf" | sed 's/^/      /'

# ---------------------------------------------------------------------------
echo ""
echo "=== 6. No public addresses on the private tiers, from GCP ==="
gc compute instances list --project=test-environment-506521 \
  --format='table(name,networkInterfaces[0].network.basename(),networkInterfaces[0].networkIP,networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null | sed 's/^/      /'
NAT_COUNT="$(gc compute instances list --project=test-environment-506521 --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null | grep -c '[0-9]' || true)"
info "instances with a public address: ${NAT_COUNT} of 4"
[ "${NAT_COUNT}" = "2" ] \
  && pass "only the two public-tier hosts have public addresses" \
  || fail "expected exactly 2 public addresses, found ${NAT_COUNT}"

echo ""
echo "================================================================"
[ "$RESULT" = "0" ] && echo "RESULT: ARCHITECTURE VERIFIED" || echo "RESULT: FAILURES PRESENT"
echo "================================================================"
exit "$RESULT"
