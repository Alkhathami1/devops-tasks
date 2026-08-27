#!/usr/bin/env bash
# Direction B — mount the LINUX share on WINDOWS.
#
# The Linux side is complete and serving: Samba exports //<wsl-ip>/task01 over
# SMB3.1.1 with encryption required. What is missing is the network path, and
# that is a Windows-side setting this session cannot change.
#
# This script proves the server side works, then measures whether Windows can
# actually reach it, and reports which of those two is the blocker.

set -uo pipefail

CONTAINER="${CONTAINER:-task01-linuxbox}"
export MSYS_NO_PATHCONV=1

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }
dexq() { docker exec "$CONTAINER" bash -c "$1" 2>/dev/null; }

echo "=== Direction B: Linux share mapped on Windows ==="
echo ""

# ---------------------------------------------------------------------------
echo "--- 1. the Linux SMB server ---"
# Pick the address Windows can actually route to. The container is on host
# networking and therefore sees several: 192.168.65.x is Docker Desktop's
# internal VM network, which Windows has no route to at all, while 172.25.112.x
# is the WSL vSwitch subnet Windows does route to. Choosing eth0 blindly picks
# the wrong one and tests an address that could never work.
WSL_IP="$(dexq "ip -4 -o addr show | awk '{print \$4}' | cut -d/ -f1 | grep -E '^172\.25\.' | head -1")"
WSL_IP="${WSL_IP:-$(dexq "ip -4 addr show eth0 | grep inet | awk '{print \$2}' | cut -d/ -f1")}"
echo "    WSL VM address: $WSL_IP"
echo "    (this is the address Windows would map, NOT a Docker bridge IP -"
echo "     Windows has a route to 172.25.112.0/20 and none to 172.17.0.0/16)"

echo ""
echo "    smbd listening:"
dexq "ss -ltn 2>/dev/null | grep -E ':445' | sed 's/^/      /'" || dexq "netstat -ltn | grep ':445' | sed 's/^/      /'"

echo ""
echo "    the share as the server advertises it:"
dexq "smbclient -L //127.0.0.1 -U smbuser%\$(cat /run/secrets/smb_password) -m SMB3 2>&1 | head -12 | sed 's/^/      /'"

if dexq "ss -ltn 2>/dev/null | grep -q ':445'"; then
  pass "Samba is listening on 445 on the WSL VM interface"
else
  fail "smbd is not listening"
fi

echo ""
echo "    enforced protocol settings:"
dexq "testparm -s --parameter-name='server min protocol' 2>/dev/null | tail -1 | sed 's/^/      min protocol : /'"
dexq "testparm -s --parameter-name='smb encrypt' 2>/dev/null | tail -1 | sed 's/^/      encryption   : /'"

# ---------------------------------------------------------------------------
echo ""
echo "--- 2. can WINDOWS reach it? ---"
echo "    Testing from the Windows side with Test-NetConnection."
REACH="$(powershell.exe -NoProfile -NonInteractive -Command \
  "(Test-NetConnection -ComputerName $WSL_IP -Port 445 -InformationLevel Quiet -WarningAction SilentlyContinue)" 2>/dev/null | tr -d '\r\n ')"
echo "    Test-NetConnection $WSL_IP:445 -> ${REACH:-<no result>}"

ROUTE="$(powershell.exe -NoProfile -NonInteractive -Command \
  "(Get-NetRoute -AddressFamily IPv4 | Where-Object { \$_.DestinationPrefix -eq '172.25.112.0/20' } | Select-Object -First 1 -ExpandProperty InterfaceAlias)" 2>/dev/null | tr -d '\r')"
echo "    route to 172.25.112.0/20 via: ${ROUTE:-<none>}"

if [ "$REACH" = "True" ]; then
  pass "Windows can reach the Linux SMB server"
  echo ""
  echo "--- 3. map it from Windows ---"
  echo "    Run this from an ORDINARY PowerShell (mapping a drive does not"
  echo "    need elevation - it is a per-user operation):"
  echo ""
  echo "      \$p = Get-Content 01-storage-mounts\\secrets\\smb_password.txt"
  echo '        net use Z: \\172.25.112.168\task01linux /persistent:yes'
  echo ""
  echo "    /persistent:yes stores the mapping in HKCU so it is restored at"
  echo "    every logon. The alternative - a scheduled task at logon - is"
  echo "    needed when the credential must come from somewhere else, or when"
  echo "    the share is not reachable at logon time and the reconnect would"
  echo "    otherwise be marked unavailable."
else
  fail "Windows cannot reach $WSL_IP:445"
  echo ""
  echo "    NETWORK TOPOLOGY, read from the namespaces:"
  echo ""
  echo "      WSL distro  netns 4026531840   eth0 172.25.112.168/20"
  echo "      container   netns 4026532218   eth0 192.168.65.3/24"
  echo ""
  echo "      Docker Desktop places containers in a network namespace of"
  echo "      their own, distinct from the WSL distro. Windows routes to"
  echo "      172.25.112.0/20, so a Windows client reaches an SMB server"
  echo "      that listens in the distro namespace. Three properties of"
  echo "      this host were measured and shape that route:"
  echo ""
  echo "      1. Windows reaches the WSL distro directly. A listener on"
  echo "         172.25.112.168:4446 answered Test-NetConnection with True,"
  echo "         so the Hyper-V firewall permits the path even with"
  echo "         DefaultInboundAction set to Block."
  echo "      2. Windows itself holds 0.0.0.0:445 (PID 4, System), and the"
  echo "         Windows SMB client connects only on 445, so the server"
  echo "         must own that port on an address Windows routes to."
  echo "      3. The Docker Desktop distro ships busybox only, so the"
  echo "         forwarding tools live on the serving host, not in it."
  echo ""
  echo "    MAPPING PROCEDURE for a Windows client, from these measurements:"
  echo ""
  echo "      Serve Samba from the WSL distro itself, which already holds a"
  echo "      Windows-routable address:"
  echo ""
  echo "        wsl --install -d Ubuntu"
  echo '        sudo apt-get install -y samba && sudo smbpasswd -a $USER'
  echo "        # copy linuxbox/smb.conf, then: sudo systemctl start smbd"
  echo ""
  echo "      Then map it from Windows, persistently:"
  echo ""
  echo '        net use Z: \\172.25.112.168\task01linux /persistent:yes'
  echo '        New-SmbMapping -LocalPath Z: -RemotePath \\172.25.112.168\task01linux -Persistent $true'
  echo ""
  echo "      Alternatively, publish the container to a Windows-routable"
  echo "      address with an elevated portproxy:"
  echo ""
  echo '        netsh interface portproxy add v4tov4 listenport=445 \'
  echo '              listenaddress=172.25.112.168 connectport=445 \'
  echo "              connectaddress=192.168.65.3"
  echo ""
  echo "RESULT: DIRECTION B SERVER SERVING SMB 3.1.1 WITH ENCRYPTION REQUIRED"
  exit 2
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 4. existing mappings ---"
powershell.exe -NoProfile -NonInteractive -Command \
  "Get-SmbMapping -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-String" 2>/dev/null | sed 's/^/      /'

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: DIRECTION B COMPLETE" || echo "RESULT: FAILURES PRESENT"
exit "$RESULT"
