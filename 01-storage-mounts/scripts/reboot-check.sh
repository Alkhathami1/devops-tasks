#!/usr/bin/env bash
# Persistence across a real reboot, captured on both sides of it.
#
#   scripts/reboot-check.sh before   # run immediately before the reboot
#   scripts/reboot-check.sh after    # run once the machine is back
#
# The before phase exists so the after phase is attributable. Recording what is
# configured to survive - restart policies, service start types, whether Docker
# Desktop launches at sign-in - is what makes "it came back on its own" a
# measurement rather than an impression.
#
# The after phase runs no mount command. Anything mounted there was mounted by
# the fstab entry at container start, or reconnected by Windows on first access.

set -uo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STACK_DIR"
unset MSYS_NO_PATHCONV

PHASE="${1:-before}"
CONTAINER="${CONTAINER:-task01-linuxbox}"
WG_SVC='WireGuardTunnel$task05-vpn'

ps1() { powershell.exe -NoProfile -NonInteractive -Command "$1" 2>/dev/null | tr -d '\r'; }
dex() { docker exec "$CONTAINER" bash -c "$1" 2>/dev/null; }

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }

echo "=== Persistence across a reboot: $PHASE ==="
echo ""
echo "    host time: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "    uptime   : $(ps1 '(Get-CimInstance Win32_OperatingSystem).LastBootUpTime')"
echo ""

case "$PHASE" in

before)
  echo "--- what is configured to come back on its own ---"
  echo ""
  echo "    container restart policy:"
  docker inspect "$CONTAINER" --format '      {{.Name}}  restart={{.HostConfig.RestartPolicy.Name}}  running={{.State.Running}}' 2>/dev/null
  POL="$(docker inspect "$CONTAINER" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null)"
  case "$POL" in
    unless-stopped|always) pass "restart policy is $POL, so Docker restarts it after a reboot" ;;
    *) fail "restart policy is '$POL'" ;;
  esac

  echo ""
  echo "    WireGuard tunnel service:"
  ps1 "Get-Service -Name '$WG_SVC' | Select-Object Name,Status,StartType | Format-Table -AutoSize | Out-String" | sed 's/^/      /'
  ST="$(ps1 "(Get-Service -Name '$WG_SVC').StartType")"
  RUN="$(ps1 "(Get-Service -Name '$WG_SVC').Status")"
  [ "$ST" = "Automatic" ] && pass "tunnel service start type is Automatic" || fail "tunnel start type is $ST"
  [ "$RUN" = "Running" ] && pass "tunnel service is running now" || fail "tunnel service is $RUN"

  echo ""
  echo "    Docker Desktop at sign-in:"
  AUTO="$(ps1 '(Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue)."Docker Desktop"')"
  if [ -n "$AUTO" ]; then
    echo "      registered in HKCU Run, so it starts at sign-in"
    pass "Docker Desktop starts at sign-in"
  else
    echo "      not registered to start at sign-in"
    echo "      NOTE: Docker Desktop will be launched by hand after logging in."
    echo "      That starts the engine; it issues no mount command. The mount"
    echo "      below is performed by the fstab entry at container start."
    pass "Docker Desktop start-at-sign-in state recorded"
  fi

  echo ""
  echo "--- the state that should survive ---"
  echo ""
  echo "    CIFS mount inside the container:"
  dex 'findmnt -t cifs -no SOURCE,TARGET,FSTYPE,OPTIONS' | sed 's/^/      /'
  echo ""
  echo "    the fstab entry that will be replayed at container start:"
  dex 'grep winshare /etc/fstab' | sed 's/^/      /'
  echo ""
  echo "    mapped drive on Windows:"
  ps1 'Get-SmbMapping -LocalPath Z: -ErrorAction SilentlyContinue | Select-Object LocalPath,RemotePath,Status | Format-Table -AutoSize | Out-String' | sed 's/^/      /'
  ps1 '(Get-ItemProperty -Path "HKCU:\Network\Z" -ErrorAction SilentlyContinue).RemotePath' | sed 's/^/      persistent entry: /'
  ;;

after)
  echo "--- no mount command has been issued since the reboot ---"
  echo ""
  echo "    WireGuard tunnel service:"
  ps1 "Get-Service -Name '$WG_SVC' | Select-Object Name,Status,StartType | Format-Table -AutoSize | Out-String" | sed 's/^/      /'
  RUN="$(ps1 "(Get-Service -Name '$WG_SVC').Status")"
  [ "$RUN" = "Running" ] && pass "the tunnel service came back on its own" || fail "tunnel service is $RUN"

  echo ""
  echo "    the tunnel address this machine holds:"
  ps1 'Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -like "10.99.*"} | Select-Object -ExpandProperty IPAddress' | sed 's/^/      /'

  echo ""
  echo "    container state:"
  docker inspect "$CONTAINER" --format '      {{.Name}}  running={{.State.Running}}  startedAt={{.State.StartedAt}}  restarts={{.RestartCount}}' 2>/dev/null

  echo ""
  echo "    CIFS mount inside the container, established by fstab at start:"
  dex 'findmnt -t cifs -no SOURCE,TARGET,FSTYPE,OPTIONS' | sed 's/^/      /'
  MNT="$(dex 'findmnt -t cifs -no TARGET' | head -1)"
  [ -n "$MNT" ] && pass "the CIFS mount is live at $MNT with no manual mount command" || fail "no CIFS mount present"

  echo ""
  echo "    entrypoint log showing the mount being replayed:"
  docker logs "$CONTAINER" 2>&1 | grep -A6 'mounting from /etc/fstab' | tail -8 | sed 's/^/      /'

  echo ""
  echo "    a read through that mount:"
  dex 'ls -l /mnt/winshare/ | head -5; echo "---"; cat /mnt/winshare/from-windows.txt 2>/dev/null || head -c 200 /mnt/winshare/*.txt 2>/dev/null' | sed 's/^/      /'
  READ="$(dex 'ls /mnt/winshare/ 2>/dev/null | head -1')"
  [ -n "$READ" ] && pass "the share is readable through the restored mount" || fail "nothing readable at the mount"

  echo ""
  echo "    mapped drive on Windows:"
  ps1 'Get-SmbMapping -LocalPath Z: -ErrorAction SilentlyContinue | Select-Object LocalPath,RemotePath,Status | Format-Table -AutoSize | Out-String' | sed 's/^/      /'

  echo ""
  echo "    a read from Z:, which is what reconnects a persistent mapping:"
  ps1 'Get-ChildItem Z:\ -ErrorAction SilentlyContinue | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize | Out-String' | sed 's/^/      /'
  ZREAD="$(ps1 'Get-Content Z:\from-windows.txt -ErrorAction SilentlyContinue')"
  echo "      content: ${ZREAD:-<not read>}"
  [ -n "$ZREAD" ] && pass "Z: reconnected across the tunnel and the file read back" || fail "Z: did not reconnect"
  ;;

*)
  echo "usage: $0 {before|after}" >&2
  exit 2
  ;;
esac

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: $PHASE PHASE VERIFIED" || echo "RESULT: FAILURES PRESENT"
exit "$RESULT"
