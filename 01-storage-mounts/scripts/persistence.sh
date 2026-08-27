#!/usr/bin/env bash
# Requirement 3 — making the mount survive a reboot, without making the reboot
# depend on the share being reachable.
#
# Writes a real /etc/fstab entry, validates it with `mount -a`, and then
# demonstrates the failure mode that makes `nofail` non-optional: an fstab
# entry for an unreachable share, WITHOUT nofail, blocks boot.

set -uo pipefail

CONTAINER="${CONTAINER:-task01-linuxbox}"
export MSYS_NO_PATHCONV=1

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }
dex()  { docker exec "$CONTAINER" bash -c "$1"; }
dexq() { docker exec "$CONTAINER" bash -c "$1" 2>/dev/null; }

echo "=== Requirement 3: persistence across reboots ==="
echo ""

echo "--- the fstab entry, option by option ---"
cat <<'EXPLAIN'
    //127.0.0.1/task01  /mnt/smb  cifs  credentials=/etc/samba/task01.creds,vers=3.1.1,seal,_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=30,uid=0,gid=0  0 0

    credentials=      the password comes from a mode-600 file. Putting it in
                      fstab directly would expose it to every user on the
                      system, because /etc/fstab is world-readable (644) by
                      design - other tools need to read it.
    vers=3.1.1        pin the dialect. Without it the client negotiates, and a
                      downgrade is exactly what an attacker wants.
    seal              require SMB3 encryption for this mount.
    _netdev           tell the init system this needs the network. Without it,
                      systemd may try to mount before networking is up and the
                      mount simply fails at boot.
    nofail            boot continues if the mount fails. WITHOUT THIS, an
                      unreachable share blocks boot: systemd waits on the mount
                      unit, the dependency chain stalls, and the machine drops
                      to an emergency shell. This is the classic way a file
                      server outage turns into every client failing to boot.
    x-systemd.automount
                      mount lazily on first access rather than at boot. The
                      boot does not wait for the server at all, and a share
                      that is down at boot but up later still works.
    x-systemd.mount-timeout=30
                      bound the wait. The default is 90s per mount, which is a
                      long time to spend discovering a server is gone.
EXPLAIN

echo ""
echo "--- writing it to /etc/fstab ---"
dex "cp /etc/fstab /etc/fstab.bak 2>/dev/null; grep -v 'task01' /etc/fstab > /tmp/fstab.new 2>/dev/null || true; mv /tmp/fstab.new /etc/fstab 2>/dev/null || true"
dex "cat >> /etc/fstab <<'FSTAB'
# Task 01 - SMB3 mount, persistent across reboots
//127.0.0.1/task01  /mnt/smb  cifs  credentials=/etc/samba/task01.creds,vers=3.1.1,seal,_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=30,uid=0,gid=0  0 0
FSTAB"
echo "    /etc/fstab now contains:"
dexq "grep -A1 'Task 01' /etc/fstab | sed 's/^/      /'"

echo ""
echo "--- /etc/fstab is world-readable, which is why the password is not in it ---"
FSTAB_PERMS="$(dexq "stat -c '%a %U:%G' /etc/fstab" | tr -d '\r')"
echo "    /etc/fstab -> mode $FSTAB_PERMS"
[ "${FSTAB_PERMS%% *}" = "644" ] \
  && pass "fstab is mode 644: any local user can read it, so it must not hold secrets" \
  || echo "[INFO] fstab mode is $FSTAB_PERMS"

echo "    the credentials file it points at is not:"
dexq "stat -c '      %n -> mode %a %U:%G' /etc/samba/task01.creds"

echo ""
echo "--- does the entry actually work? mount -a ---"
dex "umount /mnt/smb 2>/dev/null" || true
if dex "mount -a -t cifs" 2>&1 | sed 's/^/      /'; then
  pass "mount -a mounted the fstab entry without error"
else
  fail "mount -a failed"
fi
dexq "findmnt -no SOURCE,TARGET,FSTYPE /mnt/smb | sed 's/^/      /'"
MOUNTED="$(dexq "findmnt -no FSTYPE /mnt/smb" | tr -d '\r')"
[ "$MOUNTED" = "cifs" ] && pass "the share is mounted from the fstab entry alone" || fail "not mounted"

echo ""
echo "--- the nofail failure mode, demonstrated ---"
echo "    An entry pointing at a host that does not exist, WITHOUT nofail."
echo "    On a real boot systemd would block on this; here mount -a shows the"
echo "    same failure directly, bounded so the drill does not hang."
dex "mkdir -p /mnt/deadshare"
dex "cp /etc/fstab /etc/fstab.safe"
dex "cat >> /etc/fstab <<'FSTAB'
//192.0.2.99/nonexistent  /mnt/deadshare  cifs  credentials=/etc/samba/task01.creds,vers=3.1.1,_netdev  0 0
FSTAB"
echo ""
echo "    (192.0.2.0/24 is TEST-NET-1 from RFC 5737 - guaranteed unroutable)"
echo "    attempting the mount with a 20s ceiling:"
START=$(date +%s)
dex "timeout 20 mount /mnt/deadshare 2>&1 | head -3 | sed 's/^/      /'" || true
ELAPSED=$(( $(date +%s) - START ))
echo "      ...gave up after ${ELAPSED}s"
MOUNTED_DEAD="$(dexq "findmnt -no TARGET /mnt/deadshare" | tr -d '\r')"
[ -z "$MOUNTED_DEAD" ] \
  && pass "the unreachable share did NOT mount, as expected" \
  || fail "something mounted at /mnt/deadshare"
echo ""
echo "    Without nofail this hang happens during boot, on the critical path."
echo "    With nofail the same failure is logged and boot proceeds. With"
echo "    x-systemd.automount it is not even attempted until first access."

dex "cp /etc/fstab.safe /etc/fstab"
echo "    (removed the deliberately broken entry)"

echo ""
echo "--- systemd automount option ---"
echo "    x-systemd.automount is present in the fstab entry, syntactically"
echo "    correct, and accepted by mount. On a systemd host the generator"
echo "    turns it into an automount unit that mounts the share on first"
echo "    access rather than at boot, which is what keeps a slow or absent"
echo "    server from delaying startup. This container runs smbd as PID 1,"
echo "    so the option is carried in the entry and read by mount here."

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: PERSISTENCE CONFIGURED AND VERIFIED" || echo "RESULT: FAILURES PRESENT"
exit "$RESULT"
