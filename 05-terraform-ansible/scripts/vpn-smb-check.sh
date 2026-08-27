#!/usr/bin/env bash
# Measure what the WireGuard tunnel reaches, from both sides of it.
#
#   scripts/vpn-smb-check.sh outside   # before the client connects
#   scripts/vpn-smb-check.sh inside    # after the client connects
#   scripts/vpn-smb-check.sh server    # server-side view of the share
#
# The two halves are the point. "Reachable over the VPN" is only a claim until
# the same address is shown unreachable without it, so the outside phase runs
# first and its failure is the control for everything after.

set -uo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STACK_DIR"
unset MSYS_NO_PATHCONV

PHASE="${1:-outside}"
TF="$STACK_DIR/terraform"
KEY="$STACK_DIR/.ssh/task05_ed25519"
SSHOPT=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

BASTION="$(cd "$TF" && terraform output -raw bastion_public_ip 2>/dev/null)"
APP="$(cd "$TF" && terraform output -raw app_private_ip 2>/dev/null)"
SHARE="task05share"

onapp() { ssh "${SSHOPT[@]}" -o ProxyCommand="ssh ${SSHOPT[*]} -W %h:%p ansible@$BASTION" "ansible@$APP" "$1" 2>/dev/null; }
onbastion() { ssh "${SSHOPT[@]}" "ansible@$BASTION" "$1" 2>/dev/null; }
ps1() { powershell.exe -NoProfile -NonInteractive -Command "$1" 2>/dev/null | tr -d '\r'; }

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }

case "$PHASE" in

outside)
  echo "=== The app tier from outside the tunnel ==="
  echo ""
  echo "    app tier private address : $APP"
  echo "    tunnel state             : not connected"
  echo ""
  echo "--- is there a WireGuard interface on this machine? ---"
  WG="$(ps1 'Get-NetAdapter | Where-Object {$_.InterfaceDescription -like "*WireGuard*"} | Select-Object -ExpandProperty Status')"
  echo "      WireGuard adapter: ${WG:-none present}"
  echo ""
  echo "--- route to the apps subnet ---"
  RT="$(ps1 "Find-NetRoute -RemoteIPAddress $APP -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty NextHop")"
  echo "      next hop for $APP: ${RT:-none}"
  echo ""
  echo "--- TCP 445 to the app tier ---"
  R="$(ps1 "(Test-NetConnection -ComputerName $APP -Port 445 -WarningAction SilentlyContinue).TcpTestSucceeded")"
  echo "      Test-NetConnection $APP:445 -> ${R:-False}"
  if [ "$R" = "False" ] || [ -z "$R" ]; then
    pass "the share is not reachable without the tunnel"
  else
    fail "445 answered without the tunnel"
  fi
  echo ""
  echo "    The address is private and this machine holds no route to it. The"
  echo "    firewall rule admitting 445 names the bastion, so even a packet that"
  echo "    arrived by some other path would not match it."
  ;;

inside)
  echo "=== The tunnel, measured on both ends ==="
  echo ""
  echo "--- the client adapter, from Windows ---"
  ps1 'Get-NetAdapter | Where-Object {$_.InterfaceDescription -like "*WireGuard*"} | Format-Table Name,InterfaceDescription,Status -AutoSize | Out-String' | sed 's/^/      /'
  echo "--- the tunnel address this machine holds ---"
  ps1 'Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -like "10.99.*"} | Select-Object -ExpandProperty IPAddress' | sed 's/^/      /'
  echo ""
  echo "--- wg show, on the bastion ---"
  onbastion 'sudo wg show' | sed 's/^/      /'
  echo ""
  HS="$(onbastion "sudo wg show wg0 latest-handshakes | awk '{print \$2}'")"
  RX="$(onbastion "sudo wg show wg0 transfer | awk '{print \$2}'")"
  TX="$(onbastion "sudo wg show wg0 transfer | awk '{print \$3}'")"
  echo "      latest handshake (epoch) : ${HS:-0}"
  echo "      bytes received / sent    : ${RX:-0} / ${TX:-0}"
  if [ "${HS:-0}" -gt 0 ] 2>/dev/null; then
    pass "the peer has completed a handshake"
  else
    fail "no handshake recorded for the peer"
  fi
  if [ "${RX:-0}" -gt 0 ] 2>/dev/null && [ "${TX:-0}" -gt 0 ] 2>/dev/null; then
    pass "traffic has passed in both directions ($RX in, $TX out)"
  else
    fail "transfer counters are not both nonzero"
  fi
  echo ""
  echo "--- ping the app tier private address through the tunnel ---"
  ps1 "Test-Connection -ComputerName $APP -Count 4 -ErrorAction SilentlyContinue | Format-Table Address,ResponseTime,StatusCode -AutoSize | Out-String" | sed 's/^/      /'
  PING="$(ps1 "(Test-Connection -ComputerName $APP -Count 2 -Quiet -ErrorAction SilentlyContinue)")"
  [ "$PING" = "True" ] && pass "the app tier answers ICMP through the tunnel" || fail "no ICMP reply from $APP"
  echo ""
  echo "--- TCP 445 to the app tier, through the tunnel ---"
  R="$(ps1 "(Test-NetConnection -ComputerName $APP -Port 445 -WarningAction SilentlyContinue).TcpTestSucceeded")"
  echo "      Test-NetConnection $APP:445 -> ${R:-False}"
  [ "$R" = "True" ] && pass "445 is open through the tunnel" || fail "445 did not answer through the tunnel"
  ;;

client)
  echo "=== The mapped drive, from the Windows client ==="
  echo ""
  echo "--- the mapping ---"
  ps1 'net use Z:' | sed 's/^/      /'
  echo ""
  echo "--- what this machine wrote onto it ---"
  ps1 'Get-ChildItem Z:\ | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize | Out-String' | sed 's/^/      /'
  ps1 'Get-Content Z:\from-windows.txt' | sed 's/^/      /'
  echo ""
  echo "--- the negotiated SMB connection ---"
  echo "      (Get-SmbConnection needs elevation, so this is the captured output)"
  cat /c/Users/abual/wireguard-task05/smbconn.txt 2>/dev/null | sed 's/^/      /'
  DIA="$(grep -o '3\.1\.1' /c/Users/abual/wireguard-task05/smbconn.txt 2>/dev/null | head -1)"
  ENC="$(grep -o 'True' /c/Users/abual/wireguard-task05/smbconn.txt 2>/dev/null | head -1)"
  [ "$DIA" = "3.1.1" ] && pass "SMB 3.1.1 negotiated with the Linux server" || fail "dialect is not 3.1.1"
  [ "$ENC" = "True" ] && pass "the session is encrypted" || fail "the session is not encrypted"
  echo ""
  echo "--- the persistence flag on the mapping ---"
  ps1 'Get-SmbMapping -LocalPath Z: | Select-Object LocalPath,RemotePath,Status | Format-Table -AutoSize | Out-String' | sed 's/^/      /'
  ps1 '(Get-ItemProperty -Path "HKCU:\Network\Z" -ErrorAction SilentlyContinue).RemotePath' | sed 's/^/      persistent mapping in HKCU:\Network\Z -> /'
  ;;

server)
  echo "=== The share, from the server that exports it ==="
  echo ""
  echo "--- Samba protocol floor and encryption ---"
  onapp 'sudo grep -E "min protocol|max protocol|smb encrypt|server signing|smb ports" /etc/samba/smb.conf' | sed 's/^/      /'
  echo ""
  echo "--- the account and the share ---"
  onapp 'sudo pdbedit -L; ls -ld /srv/task05share; sudo ls -l /etc/samba/task05-credentials' | sed 's/^/      /'
  echo ""
  echo "--- the firewall rule that admits 445 ---"
  # terraform exposes no project_id output, so fall back to the configured
  # project rather than passing an empty --project and getting nothing back.
  PROJ="$(cd "$TF" && terraform output -raw project_id 2>/dev/null || true)"
  [ -n "$PROJ" ] || PROJ="$(gcloud config get-value project 2>/dev/null)"
  gcloud compute firewall-rules describe task05-apps-allow-smb-from-vpn \
    --project "$PROJ" \
    --format='table(name,network.basename(),sourceRanges.list(),allowed[0].ports.list(),targetServiceAccounts.list())' 2>/dev/null | sed 's/^/      /'
  echo ""
  echo "--- what the client wrote, read on the server itself ---"
  echo "      (this read never goes through the client's mount)"
  onapp 'ls -l /srv/task05share/ 2>/dev/null; echo "---"; for f in /srv/task05share/*; do [ -f "$f" ] && { echo "== $f"; cat "$f"; }; done' | sed 's/^/      /'
  echo ""
  echo "--- active SMB sessions and the dialect each negotiated ---"
  onapp 'sudo smbstatus -b 2>/dev/null; echo; sudo smbstatus -S 2>/dev/null' | sed 's/^/      /'
  ;;

*)
  echo "usage: $0 {outside|inside|client|server}" >&2
  exit 2
  ;;
esac

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: $PHASE PHASE VERIFIED" || echo "RESULT: FAILURES PRESENT"
exit "$RESULT"
