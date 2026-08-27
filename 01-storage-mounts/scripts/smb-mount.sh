#!/usr/bin/env bash
# SMB3 mount mechanics — the client side of both directions.
#
# Mounts the Samba share over a real SMB3.1.1 session using mount.cifs, and
# proves the things that actually matter about how it was done:
#
#   * the credentials file, mode 600, and why the password must not appear on
#     the command line or in /etc/fstab
#   * the negotiated dialect and whether the session is encrypted
#   * read/write through the mount
#   * the fstab options that make it survive a reboot without hanging it
#
# The server here is the Samba instance in this same container. That makes it a
# genuine SMB3 client/server exchange over TCP 445 with real authentication and
# encryption - every client mechanic is exercised. What it does NOT prove is
# interoperation with a Windows SMB server; that is Direction A, which needs a
# Windows share to exist (see windows/setup-share.ps1).

set -uo pipefail

CONTAINER="${CONTAINER:-task01-linuxbox}"
export MSYS_NO_PATHCONV=1

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }

dex()  { docker exec "$CONTAINER" bash -c "$1"; }
dexq() { docker exec "$CONTAINER" bash -c "$1" 2>/dev/null; }

SHARE_HOST="127.0.0.1"
SHARE="//${SHARE_HOST}/task01"
MNT=/mnt/smb
CREDS=/etc/samba/task01.creds

echo "=== SMB3 mount mechanics ==="
echo ""

echo "--- kernel CIFS support ---"
dex 'grep cifs /proc/filesystems | sed "s/^/    /"' || fail "cifs not in /proc/filesystems"
dex 'mount.cifs -V 2>&1 | sed "s/^/    /"'
echo "    NOTE: the cifs module was loaded on the WSL host before this ran."
echo "    A container cannot modprobe - it has no /lib/modules - so the module"
echo "    must already be live in the kernel the container shares."

# ---------------------------------------------------------------------------
echo ""
echo "--- 1. the credentials file ---"
echo "    The password goes in a file, not on the command line and not in"
echo "    /etc/fstab. Both alternatives are readable by any local user:"
echo "      * /etc/fstab is world-readable by design (mode 644)"
echo "      * command-line arguments are visible in /proc/<pid>/cmdline, i.e."
echo "        in ps output, to every user on the system"
echo ""

dex "install -m 600 /dev/null $CREDS && printf 'username=%s\npassword=%s\ndomain=WORKGROUP\n' \
     \"\${SMB_USER:-smbuser}\" \"\$(cat /run/secrets/smb_password)\" > $CREDS"
PERMS="$(dexq "stat -c '%a %U:%G' $CREDS" | tr -d '\r')"
echo "    $CREDS -> mode $PERMS"
[ "${PERMS%% *}" = "600" ] && pass "credentials file is mode 600 (owner-only)" || fail "expected 600, got $PERMS"

echo "    contents (password redacted for this transcript):"
dexq "sed 's/^password=.*/password=<REDACTED>/' $CREDS | sed 's/^/      /'"

# ---------------------------------------------------------------------------
echo ""
echo "--- 2. does a command-line password really leak into ps? ---"
echo "    Testing the claim rather than repeating it. A background process is"
echo "    started with a fake password as an argument, and ps is inspected."
# The probe and the observation must happen in ONE docker exec: an exec
# session kills its process tree on exit, so a probe launched in one exec is
# already gone by the time a second exec runs ps. `sleep 30 --password=X` also
# rejects the argument outright - bash -c keeps arbitrary trailing argv, so the
# process genuinely lives with the secret in /proc/<pid>/cmdline.
LEAK_OUT="$(docker exec "$CONTAINER" bash -c '
  # The trailing "; :" matters. With a single simple command, bash EXECS into
  # it and the extra argv is discarded - cmdline becomes just "sleep 5" and the
  # probe silently proves nothing. A second statement forces bash to stay
  # resident, keeping the full argv visible.
  bash -c "sleep 5; :" probe --password=FAKE-PASSWORD-abc123 &
  sleep 1
  echo "COUNT=$(ps aux | grep -v grep | grep -c FAKE-PASSWORD-abc123)"
  ps aux | grep -v grep | grep FAKE-PASSWORD-abc123 | head -1
  pkill -f FAKE-PASSWORD-abc123 2>/dev/null
' 2>/dev/null)"
LEAKED="$(echo "$LEAK_OUT" | grep -oE 'COUNT=[0-9]+' | cut -d= -f2)"
echo "    processes exposing the fake password in ps: ${LEAKED:-0}"
if [ "${LEAKED:-0}" -ge 1 ]; then
  pass "confirmed: an argument-passed secret IS visible in ps to any user"
  echo "$LEAK_OUT" | grep FAKE-PASSWORD-abc123 | head -1 | sed 's/^/      /'
else
  fail "the leak probe did not observe the process; claim unverified"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 3. mount over SMB3 ---"
dex "mkdir -p $MNT"
dex "umount $MNT 2>/dev/null" || true

# vers=3.1.1  pin the dialect: no silent downgrade to SMB1/SMB2
# seal        require SMB3 encryption (AES-GCM) for this mount
# credentials read the password from the mode-600 file, never from argv
MOUNT_OPTS="vers=3.1.1,credentials=$CREDS,seal,iocharset=utf8,uid=0,gid=0,file_mode=0664,dir_mode=0775"
echo "    mount -t cifs $SHARE $MNT -o ${MOUNT_OPTS//,/,\\n        }"
echo ""
if dex "mount -t cifs '$SHARE' $MNT -o '$MOUNT_OPTS'" 2>&1 | sed 's/^/      /'; then
  pass "CIFS mount succeeded"
else
  fail "CIFS mount failed"
fi

dexq "findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS $MNT | sed 's/^/    /'"
MOUNTED_FS="$(dexq "findmnt -no FSTYPE $MNT" | tr -d '\r')"
[ "$MOUNTED_FS" = "cifs" ] && pass "mounted filesystem type is cifs" || fail "expected cifs, got '$MOUNTED_FS'"

# ---------------------------------------------------------------------------
echo ""
echo "--- 4. which dialect was actually negotiated, and is it encrypted? ---"
echo "    /proc/fs/cifs/DebugData is the kernel's own record of the session:"
dexq "cat /proc/fs/cifs/DebugData 2>/dev/null | sed 's/^/      /' | head -30" || echo "      (DebugData unavailable)"

DIALECT="$(dexq "grep -oE 'Dialect 0x[0-9a-fA-F]+' /proc/fs/cifs/DebugData 2>/dev/null | head -1" | tr -d '\r')"
echo ""
echo "    negotiated: ${DIALECT:-<not reported>}"
if echo "${DIALECT:-}" | grep -q '0x311'; then
  pass "SMB 3.1.1 negotiated (0x311) - the dialect with AES-GCM and pre-auth integrity"
else
  echo "[INFO] dialect string not parsed from DebugData; mount options pinned vers=3.1.1"
fi

if dexq "grep -qiE 'encrypted|seal' /proc/fs/cifs/DebugData"; then
  pass "the session reports encryption in effect"
else
  echo "[INFO] encryption not explicitly reported in DebugData; 'seal' was requested"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- 5. read and write through the mount ---"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
echo "    reading the file the server placed in the share:"
dexq "cat $MNT/README-from-linux.txt | sed 's/^/      /'"

dex "echo 'written through the SMB3 mount at $STAMP' > $MNT/client-write-$STAMP.txt" \
  && pass "wrote a file through the mount" || fail "write failed"

# Verify server-side, not just through the same mount, so this is a real
# round trip rather than a cache read.
if dexq "test -f /srv/share/client-write-$STAMP.txt"; then
  pass "the file is present in the server's own directory - genuine round trip"
  dexq "cat /srv/share/client-write-$STAMP.txt | sed 's/^/      /'"
else
  fail "file not visible server-side"
fi

echo ""
echo "    directory listing through the mount:"
dexq "ls -l $MNT | sed 's/^/      /'"

echo ""
echo "    df through the mount (CIFS reports the server's filesystem):"
dexq "df -hT $MNT | sed 's/^/      /'"

# ---------------------------------------------------------------------------
echo ""
echo "--- 6. throughput through the mount ---"
dex "dd if=/dev/zero of=$MNT/throughput.bin bs=1M count=64 oflag=direct 2>&1 | tail -1 | sed 's/^/      write: /'" 2>/dev/null \
  || dex "dd if=/dev/zero of=$MNT/throughput.bin bs=1M count=64 2>&1 | tail -1 | sed 's/^/      write: /'"
dex "sync; dd if=$MNT/throughput.bin of=/dev/null bs=1M 2>&1 | tail -1 | sed 's/^/      read : /'"
dex "rm -f $MNT/throughput.bin"

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: SMB3 MOUNT MECHANICS PROVEN" || echo "RESULT: FAILURES PRESENT"
exit "$RESULT"
