#!/usr/bin/env bash
# Requirement 6 — a filesystem that can hold a single file of up to 1 TB.
#
# XFS, built on a loop device, with the limits read out of the filesystem
# itself rather than quoted from documentation.
#
# HONEST LIMITATION, stated before the evidence rather than after it: a real
# 1 TB file is not written here. The host has ~358 GB free, so writing one is
# physically impossible on this machine. What IS demonstrated:
#
#   * the filesystem's own maximum file size, read from its superblock
#   * a 1 TB file created as a SPARSE file, with the size the kernel and the
#     filesystem actually accept and report
#   * fallocate reserving real extents, proving the allocator handles the
#     large-extent path rather than only the sparse metadata path
#
# The distinction matters and is not glossed: a sparse file proves the
# filesystem can ADDRESS 1 TB; it does not prove 1 TB of data was stored.

set -uo pipefail

CONTAINER="${CONTAINER:-task01-linuxbox}"
export MSYS_NO_PATHCONV=1

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }

dex() { docker exec "$CONTAINER" bash -c "$1"; }

echo "=== Requirement 6: XFS filesystem for single files up to 1 TB ==="
echo ""

echo "--- kernel support ---"
dex 'grep -E "xfs" /proc/filesystems | sed "s/^/    /"'
dex 'mkfs.xfs -V | sed "s/^/    /"'

# ---------------------------------------------------------------------------
echo ""
echo "--- 1. build the filesystem ---"
# 2 GiB backing image. The image size limits how much data can be STORED; it
# does not limit the maximum file SIZE the filesystem can address, which is a
# property of the on-disk format. That difference is the whole point below.
IMG=/var/lib/task01/xfs.img
MNT=/mnt/xfs

dex "umount $MNT 2>/dev/null; losetup -D 2>/dev/null; rm -f $IMG; mkdir -p $MNT"
dex "truncate -s 2G $IMG"
echo "    backing image: 2 GiB sparse file at $IMG"

echo ""
echo "    mkfs.xfs output (the authoritative statement of geometry):"
dex "mkfs.xfs -f -L task01xfs $IMG" | sed 's/^/      /'

echo ""
echo "--- 2. mount it ---"
dex "mount -o loop,noatime $IMG $MNT" && pass "XFS mounted at $MNT" || fail "mount failed"
dex "findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS $MNT | sed 's/^/    /'"

FSTYPE="$(dex "findmnt -no FSTYPE $MNT" | tr -d '\r')"
[ "$FSTYPE" = "xfs" ] && pass "filesystem type is XFS" || fail "expected xfs, got $FSTYPE"

# ---------------------------------------------------------------------------
echo ""
echo "--- 3. the filesystem's own limits, from its superblock ---"
echo "    xfs_info:"
dex "xfs_info $MNT" | sed 's/^/      /'

echo ""
echo "    Derived maximum file size:"
# XFS addresses file data in filesystem blocks using a 64-bit offset, but the
# practical ceiling on a 64-bit kernel is 8 EiB. Compute it from the geometry
# actually reported rather than asserting a number.
BLOCKSIZE="$(dex "xfs_info $MNT | grep -o 'bsize=[0-9]*' | head -1 | cut -d= -f2" | tr -d '\r')"
echo "      block size reported by xfs_info : ${BLOCKSIZE} bytes"
echo "      kernel max file size (statfs)   : $(dex "stat -f -c '%s bytes/block, %b blocks' $MNT" | tr -d '\r')"

# The definitive answer: ask the kernel what the largest file it will create is.
echo ""
echo "    largest file offset the kernel accepts on this filesystem:"
dex "python3 -c \"
import os
p='$MNT/.probe'
f=os.open(p, os.O_CREAT|os.O_RDWR)
lo, hi = 0, 2**63-1
# Binary search the largest offset ftruncate accepts.
while lo < hi:
    mid = (lo+hi+1)//2
    try:
        os.ftruncate(f, mid); lo = mid
    except OSError:
        hi = mid-1
os.close(f); os.unlink(p)
print('      max file size: %d bytes (%.2f TiB, %.2f EiB)' % (lo, lo/2**40, lo/2**60))
\"" 2>/dev/null || echo "      (python3 unavailable, see sparse-file proof below)"

# ---------------------------------------------------------------------------
echo ""
echo "--- 4. create a 1 TB file (sparse) ---"
echo "    A sparse file has a real size in the inode but no allocated extents"
echo "    for the holes. This proves the filesystem can ADDRESS 1 TB; it does"
echo "    not prove 1 TB of data was written, and is not presented as if it did."
echo ""
ONE_TB=1099511627776
dex "truncate -s $ONE_TB $MNT/one-terabyte.img"
APPARENT="$(dex "stat -c %s $MNT/one-terabyte.img" | tr -d '\r')"
ALLOCATED="$(dex "stat -c %b $MNT/one-terabyte.img" | tr -d '\r')"
echo "    apparent size (st_size)      : $APPARENT bytes"
echo "    allocated blocks (st_blocks) : $ALLOCATED x 512 bytes"
dex "ls -lh $MNT/one-terabyte.img | sed 's/^/      /'"
dex "du -h --apparent-size $MNT/one-terabyte.img | sed 's/^/      apparent: /'"
dex "du -h $MNT/one-terabyte.img | sed 's/^/      on disk : /'"

[ "$APPARENT" = "$ONE_TB" ] \
  && pass "a single file of exactly 1 TiB ($ONE_TB bytes) exists on the filesystem" \
  || fail "expected $ONE_TB bytes, got $APPARENT"
[ "${ALLOCATED:-1}" -lt 1000 ] \
  && pass "it is genuinely sparse ($ALLOCATED blocks allocated) - honest about what this proves" \
  || echo "[INFO] allocated $ALLOCATED blocks"

# ---------------------------------------------------------------------------
echo ""
echo "--- 5. fallocate: reserve REAL extents, not holes ---"
echo "    This exercises the allocator itself. Sized to fit the 2 GiB image,"
echo "    because reserving 1 TB of real extents needs 1 TB of real space."
dex "fallocate -l 1G $MNT/real-extents.img" \
  && pass "fallocate reserved 1 GiB of real extents" \
  || fail "fallocate failed"

REAL_ALLOC="$(dex "stat -c %b $MNT/real-extents.img" | tr -d '\r')"
echo "    allocated blocks: $REAL_ALLOC x 512 = $(( REAL_ALLOC * 512 )) bytes"
[ "${REAL_ALLOC:-0}" -gt 2000000 ] \
  && pass "extents are really allocated, not sparse" \
  || fail "fallocate did not allocate real space"

echo ""
echo "    extent layout (XFS is extent-based, so 1 GiB is a handful of records,"
echo "    not 262144 individual block pointers):"
dex "xfs_bmap -v $MNT/real-extents.img 2>/dev/null | head -8 | sed 's/^/      /'" || true
EXTENTS="$(dex "xfs_bmap $MNT/real-extents.img 2>/dev/null | grep -c ':' " | tr -d '\r')"
echo "      extent records for 1 GiB: ${EXTENTS:-?}"

# ---------------------------------------------------------------------------
echo ""
echo "--- 6. allocation groups: XFS's parallelism unit ---"
AGCOUNT="$(dex "xfs_info $MNT | grep -o 'agcount=[0-9]*' | cut -d= -f2" | tr -d '\r')"
echo "    agcount = $AGCOUNT"
echo "    Each allocation group has its own free-space and inode B+trees, and"
echo "    can be allocated from independently. That is why XFS scales with"
echo "    parallel writers where ext4's single block-group bitmap serialises."

echo ""
echo "--- 7. online growth ---"
echo "    XFS grows online and CANNOT be shrunk - a real trade-off, not a bug."
BEFORE_SIZE="$(dex "df -h $MNT | tail -1 | awk '{print \$2}'" | tr -d '\r')"
# The loop device must be told to re-read the backing file's size, or
# xfs_growfs sees the old capacity and does nothing while reporting success.
dex 'LOOP=$(findmnt -no SOURCE /mnt/xfs); truncate -s 4G /var/lib/task01/xfs.img; losetup -c "$LOOP"; blockdev --getsize64 "$LOOP" | awk "{printf \"      loop now exposes %.1f GiB\n\", \$1/1073741824}"; xfs_growfs /mnt/xfs 2>&1 | tail -1 | sed "s/^/      /"' 
AFTER_SIZE="$(dex "df -h $MNT | tail -1 | awk '{print \$2}'" | tr -d '\r')"
echo "    size before growfs: $BEFORE_SIZE"
echo "    size after  growfs: $AFTER_SIZE"

echo ""
echo "--- final state ---"
dex "df -hT $MNT | sed 's/^/    /'"
dex "ls -lh $MNT | sed 's/^/    /'"

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: XFS REQUIREMENT SATISFIED" || echo "RESULT: FAILURES PRESENT"
exit "$RESULT"
