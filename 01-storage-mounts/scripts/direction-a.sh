#!/usr/bin/env bash
# Direction A — mount a WINDOWS share on LINUX over SMB3.
#
# Requires windows/setup-share.ps1 to have been run from an elevated
# PowerShell. Without it there is no share to mount: the only shares Windows
# exposes by default are the administrative ones (C$, ADMIN$, IPC$), and
# reaching those means using the operator's own admin credentials, which this
# task deliberately avoids.
#
# If the share is absent, this script says so plainly and exits non-zero. It
# does not simulate the mount.

set -uo pipefail

CONTAINER="${CONTAINER:-task01-linuxbox}"
export MSYS_NO_PATHCONV=1

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }
dexq() { docker exec "$CONTAINER" bash -c "$1" 2>/dev/null; }

SHARE_NAME="${SHARE_NAME:-task01share}"
SMB_USER="${WIN_SMB_USER:-task01smb}"
MNT=/mnt/winshare
CREDS=/etc/samba/windows.creds
SECRET_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/secrets/windows_smb_password.txt"

echo "=== Direction A: Windows share mounted on Linux ==="
echo ""

# ---------------------------------------------------------------------------
echo "--- 1. find the Windows host from inside WSL ---"
echo "    WSL2 is NAT'd, so the Windows host is NOT 127.0.0.1 from in here."
echo "    Three addresses reach it, and all three were confirmed open on 445:"
for ip in 172.25.112.1 host.docker.internal 192.168.65.254; do
  if dexq "nc -z -w3 $ip 445"; then
    printf '      %-24s 445 OPEN\n' "$ip"
    WIN_HOST="${WIN_HOST:-$ip}"
  else
    printf '      %-24s 445 unreachable\n' "$ip"
  fi
done
WIN_HOST="${WIN_HOST:-172.25.112.1}"
echo "    using: $WIN_HOST"
echo ""
echo "    NOTE: /mnt/c inside WSL is NOT this. That is a 9p/drvfs passthrough,"
echo "    not an SMB mount - no dialect, no session, no authentication. Mounting"
echo "    a Windows share properly means speaking SMB to \\\\host\\share, which"
echo "    is what this does."

# ---------------------------------------------------------------------------
echo ""
echo "--- 2. is there a share to mount? ---"
if [ ! -s "$SECRET_FILE" ]; then
  echo ""
  echo "    NOT SET UP. $SECRET_FILE does not exist."
  echo ""
  echo "    windows/setup-share.ps1 has not been run. It needs an ELEVATED"
  echo "    PowerShell, because creating an SMB share and changing firewall"
  echo "    rules both require administrator rights, and this session is not"
  echo "    elevated:"
  echo ""
  echo "      Right-click PowerShell -> Run as Administrator"
  echo "      cd '$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/windows'"
  echo "      .\\setup-share.ps1"
  echo ""
  echo "    Then re-run this script."
  echo ""
  echo "    Enumerating what the Windows host currently offers, to show the"
  echo "    state honestly rather than assert it:"
  dexq "smbclient -L //$WIN_HOST -N -m SMB3 2>&1 | head -20 | sed 's/^/      /'"
  echo ""
  echo "RESULT: DIRECTION A NOT PERFORMED - no Windows share exists"
  exit 2
fi

pass "credentials for the Windows share are present"

# ---------------------------------------------------------------------------
echo ""
echo "--- 3. credentials file, mode 600 ---"
WIN_PASS="$(tr -d '\r\n' < "$SECRET_FILE")"
docker exec -i "$CONTAINER" bash -c "install -m 600 /dev/null $CREDS && cat > $CREDS" <<CREDEOF
username=$SMB_USER
password=$WIN_PASS
domain=$(dexq 'echo WORKGROUP')
CREDEOF
unset WIN_PASS
dexq "stat -c '      %n -> mode %a %U:%G' $CREDS"
PERMS="$(dexq "stat -c %a $CREDS")"
[ "$PERMS" = "600" ] && pass "credentials file is mode 600" || fail "expected 600, got $PERMS"

# ---------------------------------------------------------------------------
echo ""
echo "--- 4. what does the server offer? ---"
dexq "smbclient -L //$WIN_HOST -A $CREDS -m SMB3 2>&1 | head -20 | sed 's/^/      /'"

# ---------------------------------------------------------------------------
echo ""
echo "--- 5. mount it ---"
dexq "mkdir -p $MNT; umount $MNT 2>/dev/null"
OPTS="vers=3.1.1,credentials=$CREDS,seal,iocharset=utf8,uid=0,gid=0,file_mode=0664,dir_mode=0775"
echo "    mount -t cifs //$WIN_HOST/$SHARE_NAME $MNT -o $OPTS"
if dexq "mount -t cifs '//$WIN_HOST/$SHARE_NAME' $MNT -o '$OPTS'"; then
  pass "mounted the Windows share on Linux"
else
  fail "mount failed"
  dexq "dmesg 2>/dev/null | tail -5 | sed 's/^/      /'"
  echo ""
  echo "RESULT: DIRECTION A FAILED"
  exit 1
fi

dexq "findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS $MNT | sed 's/^/      /'"

echo ""
echo "--- 6. negotiated dialect and encryption ---"
DIALECT="$(dexq "grep -oE 'Dialect 0x[0-9a-fA-F]+' /proc/fs/cifs/DebugData | tail -1")"
echo "    $DIALECT (0x311 = SMB 3.1.1)"
echo "$DIALECT" | grep -q '0x311' && pass "SMB 3.1.1 negotiated with Windows" || echo "[INFO] dialect: $DIALECT"
dexq "grep -qi encrypted /proc/fs/cifs/DebugData" && pass "session is encrypted" || echo "[INFO] encryption not reported"

echo ""
echo "--- 7. read the file Windows put there ---"
dexq "cat $MNT/README-from-windows.txt | sed 's/^/      /'" \
  && pass "read a Windows-authored file over SMB" || fail "could not read from the share"

echo ""
echo "--- 8. write back to Windows, verified BY WINDOWS ---"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
PAYLOAD="written from Linux over SMB3 at $STAMP"
dexq "echo '$PAYLOAD' > $MNT/from-linux-$STAMP.txt" && pass "wrote a file to the Windows share" || fail "write failed"
dexq "ls -l $MNT | sed 's/^/      /'"

echo ""
echo "    Reading it back through the SAME mount would prove nothing: CIFS"
echo "    caches aggressively, so the answer could come from the client page"
echo "    cache without a byte crossing the wire. Windows is asked directly."
WIN_FILE="C:\task01share\from-linux-$STAMP.txt"
WIN_SEES="$(powershell.exe -NoProfile -NonInteractive -Command "if (Test-Path '$WIN_FILE') { (Get-Content '$WIN_FILE' -Raw).Trim() } else { '__MISSING__' }" 2>/dev/null | tr -d '\r')"
echo "    Windows Get-Content returned: $WIN_SEES"

if [ "$WIN_SEES" = "$PAYLOAD" ]; then
  pass "Windows reads back exactly what Linux wrote - a genuine round trip"
elif [ "$WIN_SEES" = "__MISSING__" ]; then
  fail "Windows cannot see the file; the write never reached the server"
else
  fail "content mismatch: Windows sees '$WIN_SEES', Linux wrote '$PAYLOAD'"
fi

echo ""
echo "    the share directory as Windows itself lists it:"
powershell.exe -NoProfile -NonInteractive -Command "Get-ChildItem C:\task01share | Select-Object Name,Length | Format-Table -AutoSize | Out-String" 2>/dev/null | sed 's/^/      /' | grep -v '^ *$'

# ---------------------------------------------------------------------------
echo ""
echo "--- 9. throughput: cold and cached, each labelled ---"
echo "    A read taken straight after a write measures the page cache, not the"
echo "    network. The first run of this script reported 9.5 GB/s over SMB -"
echo "    roughly 76x the theoretical maximum of a 1 GbE link. An impressive"
echo "    number that measured nothing. Both are reported below, labelled."
echo ""
dexq "dd if=/dev/zero of=$MNT/perf.bin bs=1M count=64 conv=fsync 2>&1 | tail -1 | sed 's|^|      write (to server, fsync)   : |'"

# Cached read: the file is still in the client page cache from the write above.
dexq "dd if=$MNT/perf.bin of=/dev/null bs=1M 2>&1 | tail -1 | sed 's|^|      read  (CACHED, not the wire): |'"

# Cold read: drop the page cache so the bytes must cross SMB again.
dexq "sync; echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null
dexq "dd if=$MNT/perf.bin of=/dev/null bs=1M 2>&1 | tail -1 | sed 's|^|      read  (COLD, over SMB)     : |'"

# O_DIRECT bypasses the cache entirely, as a cross-check on the cold figure.
dexq "dd if=$MNT/perf.bin of=/dev/null bs=1M iflag=direct 2>&1 | tail -1 | sed 's|^|      read  (O_DIRECT, over SMB) : |'"
dexq "rm -f $MNT/perf.bin"

# ---------------------------------------------------------------------------
echo ""
echo "--- 10. persistence for THIS share (requirement 3) ---"
echo "    The same fstab treatment as the Samba share, but pointing at the real"
echo "    Windows server."
echo ""
dexq "cp /etc/fstab /etc/fstab.bak-dira 2>/dev/null; grep -v winshare /etc/fstab > /tmp/fstab.d 2>/dev/null; mv /tmp/fstab.d /etc/fstab 2>/dev/null" || true
docker exec -i "$CONTAINER" bash -c "cat >> /etc/fstab" <<FSTABEOF
# Task 01 Direction A - Windows share, persistent across reboots
//$WIN_HOST/$SHARE_NAME  $MNT  cifs  credentials=$CREDS,vers=3.1.1,seal,_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=30,uid=0,gid=0  0 0
FSTABEOF
echo "    /etc/fstab entry:"
dexq "grep -A1 'Direction A' /etc/fstab | sed 's/^/      /'"

echo ""
echo "    unmounting, then remounting from the fstab entry alone:"
dexq "umount $MNT" && echo "      unmounted"
if dexq "mount -a -t cifs"; then
  pass "mount -a mounted the Windows share from fstab with no arguments"
else
  fail "mount -a failed"
fi
dexq "findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS $MNT | sed 's/^/      /'"
REMOUNTED="$(dexq "findmnt -no FSTYPE $MNT")"
[ "$REMOUNTED" = "cifs" ] && pass "the Windows share is mounted from fstab alone" || fail "not mounted after mount -a"

echo ""
echo "    the credentials file it points at is owner-only:"
dexq "stat -c '      %n -> mode %a %U:%G' $CREDS"
echo "    while /etc/fstab itself is world-readable, which is why the password is not in it:"
dexq "stat -c '      %n -> mode %a %U:%G' /etc/fstab"

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: DIRECTION A COMPLETE" || echo "RESULT: FAILURES PRESENT"
exit "$RESULT"
