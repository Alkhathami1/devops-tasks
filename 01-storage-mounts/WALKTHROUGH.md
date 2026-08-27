# Task 1 — Cross-platform volume mounting, XFS, monitoring and alerting

A walkthrough of how this was built, what each decision rests on, and what the
measurements turned out to say. Every figure here comes from a log in
`docs/evidence/`, named beside it.

---

## 1. What was asked, and how I read it

The requirement, in the requester's wording:

> Mount a volume from Windows to Linux. Explain the protocol used and why.
> Document the mounting steps and how to make it persistent across reboots.
> Monitor the mount and disk performance, and alert to guarantee a service
> level. Create a filesystem that can handle single files up to 1 TB, and
> justify the choice. Also do the reverse direction, Linux to Windows.

Seven distinct pieces of work sit inside that paragraph, and I read them as
follows.

**"Mount a volume from Windows to Linux"** means speaking a network file
protocol from a Linux client to a Windows server. It does not mean using
whatever happens to make Windows files appear under a Linux path. On this host
`/mnt/c` already does that, and it is a 9p/drvfs passthrough — no dialect, no
session, no authentication, no ACL mapping. Demonstrating the requirement with
`/mnt/c` would demonstrate none of the things the requirement is about. So the
target is a real SMB share on the real Windows machine, mounted with
`mount.cifs`, with the negotiated dialect read back out of the kernel.

**"Explain the protocol used and why"** means the choice has to be defensible
against the alternatives that a reviewer would raise, and the property that
decided it has to be named. "SMB is native to Windows" is a slogan. The
identity model is the argument.

**"Persistent across reboots"** means the mount must be reconstructible from
system configuration alone, with no operator typing a mount command and no
password on that command line. The check that proves it is `mount -a` with no
arguments after an unmount: if the entry is complete, the share comes back.

**"Monitor the mount and disk performance"** is two things needing different
queries. Capacity is a gauge. Availability is the *absence* of a gauge, because
an exporter stops publishing a filesystem's series the moment the filesystem is
gone, and a threshold alert on a series that no longer exists never fires.

**"Alert to guarantee a service level"** means the thresholds descend from a
stated objective rather than being picked for roundness, and the rules are shown
firing. A rule that has never fired is a hypothesis: it may reference a metric
that does not exist, select on a label nothing sets, or set a threshold nothing
can reach.

**"A filesystem handling single files up to 1 TB"** is a capability claim, so
the number to produce is the filesystem's own ceiling, measured rather than
quoted. **"The reverse direction"** is the same protocol with the roles
swapped: a Linux machine serving, a Windows client consuming.

---

## 2. Design decisions

### 2.1 SMB 3.1.1, decided on the identity model

The mount speaks SMB 3.1.1 in both directions. What decided it is how each
protocol establishes *who is asking*, because the two sides of this boundary
have unrelated user databases.

**NFSv3** maps identity by numeric uid and gid. The client asserts that it is
uid 1000 and the server believes it. Across a Windows/Linux boundary that is
not an authentication decision at all — there is no Windows account with uid
1000 to compare against, and any client that can reach the export can claim any
identity in it.

**NFSv4** replaces numeric ids with string principals, which is a real
improvement, and it needs `idmapd` configured consistently on both ends to map
those principals to local accounts. For authentication rather than assertion it
needs Kerberos. Windows ships an NFS client as an optional feature, and it is a
second-class citizen there. That is three moving parts to reach the security
posture SMB has before the first byte of file data moves.

**SMB** authenticates the session — NTLMSSP or Kerberos — before any file
access, and Windows ACLs map onto it natively because it is Windows' own
protocol. On this host the kernel's own record shows what the session
negotiated:

```
Number of credits: 389,1,1 Dialect 0x311 signed
Security type: RawNTLMSSP  SessionId: 0x45cdca55 encrypted
```

(`01-smb-mount.log`, from `/proc/fs/cifs/DebugData`.)

**iSCSI** was rejected on layering. It exports a block device, not a
filesystem. Two hosts mounting the same LUN without a cluster filesystem
between them corrupt it, because each one caches metadata it believes it owns
exclusively. The requirement is a shared volume, and iSCSI does not provide
sharing.

**sshfs** was rejected on the service level. It is FUSE, single-threaded per
mount, has no ACL model, and its small-file performance is poor because every
operation is a round trip through userspace and an SSH channel. It is a
reasonable way to reach a machine for ten minutes. It is not a mount an SLO can
be written against.

**Encryption** rides inside SMB3 rather than in a tunnel around it. SMB 3.1.1
uses AES-128-GCM, and it is required at both ends here: `smb encrypt =
required` in `linuxbox/smb.conf`, and `seal` in the mount options. SMB 3.1.1
also adds pre-auth integrity hashing, which protects the *negotiate* exchange
itself — the step an attacker would otherwise use to talk both ends down to a
weaker dialect.

**SMB1 stays off.** `server min protocol = SMB3_11` on the Linux side, and
Samba's own share listing reports `SMB1 disabled -- no workgroup available`
(`01-direction-a.log`, `01-direction-b.log`). SMB1 has no encryption and weak
signing, and Windows 10 and later ship with the client removed, so allowing it
would buy nothing.

**Multichannel** is enabled in `smb.conf` with `server multi channel support =
yes`. It lets a single session spread across several TCP connections and
several NICs, for throughput and for transparent failover when one path dies.

### 2.2 XFS, decided on the extent map and the allocation groups

The filesystem for large single files is XFS, built on a loop device so the
whole demonstration is reproducible without touching a real disk.

| Filesystem | Single-file ceiling | The property that decided it |
|---|---|---|
| **XFS (chosen)** | 8 EiB, measured | Extent-based allocation and per-allocation-group free-space trees |
| ext4 | 16 TiB | Sufficient for 1 TB, but a single block-group bitmap serializes parallel allocation, and online growth is more constrained |
| ZFS | 16 EiB | Checksums and snapshots are genuinely better; out-of-tree on Linux for licence reasons, wants substantial RAM, and is a much larger operational commitment than one filesystem |
| Btrfs | 16 EiB | Comparable feature set; historically weaker RAID5/6 and more variable behavior under sustained write load |
| NTFS | 8 PiB | The Windows side of the boundary, not the Linux one. On Linux it is reached through ntfs-3g or ntfs3 with weaker POSIX semantics |

ext4's 16 TiB ceiling clears the 1 TB requirement sixteen times over, so the
ceiling is not what separates them. Two other properties do, and both are
visible in the extent map of a single 1 GiB file (`01-xfs.log`):

```
 EXT: FILE-OFFSET         BLOCK-RANGE      AG AG-OFFSET          TOTAL
   0: [0..1041151]:       1048656..2089807  1 (80..1041231)    1041152
   1: [1041152..2082303]: 3145808..4186959  3 (80..1041231)    1041152
   2: [2082304..2097151]: 192..15039        0 (192..15039)       14848
```

Three records describe a gibibyte. A block-pointer scheme would need 262,144 of
them for the same file, and every one of those pointers is metadata to read,
cache and write back. That is the difference extent-based allocation makes, and
it grows linearly with file size — which is the whole subject of this
requirement.

The `AG` column is the second property. The allocator spread one file across
allocation groups 1, 3 and 0. Each group carries its own free-space and inode
B+trees and can be allocated from independently, so parallel writers do not
queue behind one another for the same bitmap.

XFS grows online and cannot shrink. That is a real trade-off rather than a
defect, and it is the right side of the trade for a volume holding files
measured in terabytes: such volumes grow.

### 2.3 node_exporter inside the machine it monitors

node_exporter runs in the same container as the Samba server and the CIFS
client, not as a separate service. A separate node-exporter container has its
own mount namespace, and a CIFS or XFS mount made in another namespace is
invisible to it. It would report the host's filesystems, look healthy, and
silently omit the two mounts this entire task is about. The exporter belongs on
the machine it monitors, and in a container topology that means the same
container.

### 2.4 The SLO first, then the thresholds

The alert rules descend from a written objective, which is stated at the top of
`prometheus/alerts.yml` so that a reader can judge the rules against something:

- **Availability** — the mounted share is readable and writable 99.9% of the
  month. That is 43m 12s of permitted downtime per 30 days.
- **Latency** — mean disk service time below 50 ms. A mean, not a p99, because
  `/proc/diskstats` gives total service time and total operations and nothing
  in between. A percentile computed from those two numbers would be invented.
- **Capacity** — never above 85% used, and never less than 4 hours of headroom
  at the current fill rate.

The `for:` durations come from the error budget rather than from taste.
`MountMissing` pages after 30 s because the entire monthly budget is 43
minutes, so an availability breach spends it at one minute per minute.
`FilesystemSpaceCritical` waits 15 s because filling a disk is a slow failure
with time to react.

---

## 3. How it is built

Two containers on the WSL2 kernel, both on host networking.

```
                       task01-linuxbox  (privileged, network_mode: host)
                       ┌───────────────────────────────────────────────┐
  Windows              │  smbd :445          ← Direction B server      │
  \\ALKHATHAMI\        │  mount.cifs         → Direction A client      │
    task01share  ◄─────┼─ /mnt/winshare      cifs, vers=3.1.1, seal    │
                       │  /mnt/xfs           xfs on /dev/loop2         │
                       │  node_exporter :9100                          │
                       │  cifs-metrics.sh → textfile collector         │
                       └───────────────────────────────────────────────┘
                                        ▲ scrape every 5s
                       ┌────────────────┴──────────────────────────────┐
                       │  task01-prometheus :9090   10 alert rules     │
                       └───────────────────────────────────────────────┘
```

`linuxbox` is privileged and uses host networking, and neither is incidental.
Mounting anything — CIFS or XFS — requires `CAP_SYS_ADMIN`, and building a
filesystem on a loop device requires access to `/dev/loop*`. Host networking
puts Samba on the WSL VM's own interface rather than behind Docker's NAT, which
is the interface a Windows client has a route to.

### The files

| Path | What it does |
|---|---|
| `compose.yaml` | Both services, the named volumes, and the SMB password as a file secret |
| `linuxbox/Dockerfile` | Debian 12 with cifs-utils, samba, xfsprogs, sysstat, fio; node_exporter v1.8.2 copied from the official image so it is version-pinned and needs no build-time network |
| `linuxbox/smb.conf` | SMB3.1.1 floor and ceiling, `smb encrypt = required`, `server signing = mandatory`, netbios disabled, port 445 only |
| `linuxbox/entrypoint.sh` | Creates the POSIX and Samba accounts from the file secret, starts `smbd`, starts the CIFS metrics loop, starts node_exporter with the diskstats exclusion overridden |
| `linuxbox/cifs-metrics.sh` | Parses `/proc/fs/cifs/Stats` into Prometheus text format, written atomically via a temp file and `mv` |
| `prometheus/prometheus.yml` | 5 s scrape and evaluation interval, so a drill can watch a state transition |
| `prometheus/alerts.yml` | Ten rules in three groups: mount-availability, capacity, performance |
| `windows/setup-share.ps1` | The elevated Windows-side setup: dedicated local account, share, SMB-In firewall rules, with a record of what it actually changed |
| `windows/teardown-share.ps1` | Reverses exactly what the setup recorded |
| `scripts/*.sh` | One script per sub-requirement, plus `up.sh` and `verify.sh` |

### The password path

The SMB account password is generated by `scripts/up.sh` into
`secrets/smb_password.txt`, mounted into the container as a Docker secret at
`/run/secrets/smb_password`, and read by `entrypoint.sh`. It reaches
`smbpasswd` through stdin:

```bash
printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" | smbpasswd -s -a "$SMB_USER" > /dev/null
```

`smbpasswd` reads the value twice from stdin, which is the one place it is
handled, and it never appears on a command line. Section 6.2 has the
measurement showing why that matters.

On the client side the same value lives in `/etc/samba/task01.creds`, mode 600,
referenced from `/etc/fstab` by path.

### The Windows side

`windows/setup-share.ps1` runs elevated and does four things: creates a
dedicated local account `task01smb` so the operator's own Windows credentials
never enter a file on the Linux side; creates `C:\task01share` and shares it as
`task01share`, granting only that account; enables the File and Printer Sharing
(SMB-In) firewall rules; and records what it changed into
`windows/.setup-state.json` so teardown reverses that and nothing else.

Before it touches anything it runs `Assert-WindowsLimits`, which validates every
value Windows caps at the API level — local user name 20 characters, user
description 48, full name 256, share name 80, share remark 256 — plus the SAM
name rules that are not about length: not empty, no trailing period, and none of
`" / \ [ ] : ; | = , + * ? < >`. Section 6.7 explains which failure produced it.

---

## 4. The steps, as a narrative

### 4.1 Load the CIFS module, then bring the stack up

`scripts/up.sh` generates the SMB password if it is absent, then loads the
kernel module from the WSL distro:

```bash
wsl -d docker-desktop -e sh -c 'modprobe cifs 2>/dev/null; grep -q cifs /proc/filesystems'
```

This runs outside the container deliberately. A container has no
`/lib/modules`, so `modprobe cifs` inside it fails, and the module has to be
live in the kernel the container shares. After the load, `01-smb-mount.log`
records `nodev cifs` in `/proc/filesystems` and `mount.cifs version: 7.0`.

Then `docker compose build` and `docker compose up -d --wait`, which blocks
until the healthcheck — SMB answering on 445 and node_exporter serving metrics —
passes.

### 4.2 Create the Windows share

From an elevated PowerShell, `windows\setup-share.ps1`. The run that produced
the evidence recorded `UserCreated: true`, `ShareCreated: true`, and an empty
`FirewallEnabled` list — the SMB-In rules were already on by then, so it
flipped none and teardown will restore none.

### 4.3 Mount the Windows share on Linux

`scripts/direction-a.sh` finds the Windows host first. WSL2 is NAT'd, so the
Windows host is not `127.0.0.1` from inside. Three addresses reach it —
`172.25.112.1`, `host.docker.internal` and `192.168.65.254` — and the script
confirms 445 is open on all three before choosing `172.25.112.1`. It then asks
the server what it offers with `smbclient -L`, which is the first proof that an
SMB session can be established rather than merely a TCP connection:
`task01share` appears alongside the administrative shares, under the line `SMB1
disabled -- no workgroup available` (`01-direction-a.log`).

Then the mount itself:

```bash
mount -t cifs //172.25.112.1/task01share /mnt/winshare \
  -o vers=3.1.1,credentials=/etc/samba/windows.creds,seal,iocharset=utf8,\
     uid=0,gid=0,file_mode=0664,dir_mode=0775
```

Each option earns its place. `vers=3.1.1` pins the dialect so no downgrade can
be negotiated. `credentials=` keeps the password out of the process table and
out of `/etc/fstab`. `seal` requires SMB3 encryption for this mount rather than
accepting it if offered. `uid`/`gid`/`file_mode`/`dir_mode` give the server's
files a stable POSIX identity on a client whose user database the server knows
nothing about.

### 4.4 Prove the round trip from the far side

Reading a file back through the same mount proves very little. CIFS caches
aggressively, so the answer can be served from the client page cache without a
byte crossing the wire. The script writes through the mount and then asks
Windows directly:

```
    Windows Get-Content returned: written from Linux over SMB3 at 20260826T191138Z
[PASS] Windows reads back exactly what Linux wrote - a genuine round trip
```

It also lists the share directory as Windows itself sees it: the same six files
with the same lengths the Linux side sees through the mount.

### 4.5 Make it persistent

`scripts/persistence.sh` writes the fstab entry, unmounts, and remounts with
`mount -a` and no arguments:

```
//172.25.112.1/task01share  /mnt/winshare  cifs  \
  credentials=/etc/samba/windows.creds,vers=3.1.1,seal,_netdev,nofail,\
  x-systemd.automount,x-systemd.mount-timeout=30,uid=0,gid=0  0 0
```

| Option | Why it is there |
|---|---|
| `credentials=` | The password lives in a mode-600 file, because `/etc/fstab` is mode 644 by design — other tools read it |
| `vers=3.1.1` | Pins the dialect; no silent downgrade at boot |
| `seal` | Requires SMB3 encryption for this mount |
| `_netdev` | Marks the mount network-dependent so the init system does not attempt it before networking is up |
| `nofail` | Boot continues if the mount fails |
| `x-systemd.automount` | Mount lazily on first access, so boot never waits for the file server at all |
| `x-systemd.mount-timeout=30` | Bounds the wait. The default is 90 s per mount, which is a long time to wait before discovering a server is gone |

The same treatment is applied to the Samba share at `//127.0.0.1/task01`. Both
remount from their entries alone (`01-persistence.log`, `01-direction-a.log`).
`x-systemd.automount` is present in the entry, syntactically correct, and
accepted by `mount`; on a systemd host the generator turns it into an automount
unit that mounts the share on first access.

### 4.6 Show what `nofail` is for

The option's value only becomes visible when the mount fails, so the script
adds an entry pointing at `//192.0.2.99/nonexistent` — TEST-NET-1 from RFC
5737, guaranteed unroutable — without `nofail`, and attempts it under a
20-second ceiling:

```
      mount error(115): Operation now in progress
      ...gave up after 11s
[PASS] the unreachable share did NOT mount, as expected
```

On a real boot that stall sits on the critical path. systemd waits on the mount
unit, the dependency chain stalls behind it, and the machine drops to an
emergency shell. That is how a single file-server outage becomes every client
failing to boot. The entry is removed once the point is made.

### 4.7 Build the XFS filesystem

`scripts/xfs-demo.sh` creates a 2 GiB sparse image, makes an XFS filesystem on
it, mounts it, and then reads the limits out of the filesystem rather than
quoting them. The ceiling is found by binary search over `ftruncate` between 0
and 2⁶³−1, keeping the largest offset the kernel accepts.

It then creates the 1 TB file, reserves 1 GiB of real extents with `fallocate`
to exercise the allocator, prints the extent map, and grows the filesystem
online from 2 GiB to 4 GiB. The growth sequence is `truncate -s 4G` on the
backing image, then `losetup -c` on the loop device, then `xfs_growfs`. The
middle step is what makes the loop device re-read the backing file's size.

### 4.8 Monitor, then drive the alerts

`scripts/monitoring.sh` walks three layers in order — `/proc/diskstats`,
`iostat -x`, then node_exporter and Prometheus — generates 15 s of mixed random
I/O with `fio` so the counters have something in them, and queries the SLO
figures live from the Prometheus HTTP API.

`scripts/alerts-fire.sh` then drives three rules from `inactive` through
`pending` to `firing` and back:

1. Fill `/mnt/xfs` in steps, checking after each, until usage crosses 85%.
2. Unmount `/mnt/xfs` and watch `absent()` fire.
3. Unmount `/mnt/winshare` — the share from Windows — and watch the same.

Each is then recovered and watched back to `inactive`, so the whole lifecycle
is exercised rather than just the trigger edge.

### 4.9 Serve from Linux

`scripts/direction-b.sh` verifies the server end: `smbd` listening on 445 on
both address families, the share advertised, `min protocol : SMB3`, `encryption
: required`, SMB1 off. It then reads the network namespaces on both sides to
establish which address a Windows client should map, and prints the mapping
procedure built from those measurements. Section 5.6 has the numbers.

---

## 5. Measured results

### 5.1 The mount, against Windows

Source: `01-direction-a.log`.

| What | Measured |
|---|---|
| Share advertised | `task01share  Disk  Task 01 export from Windows to Linux` |
| Dialect negotiated | `Dialect 0x311` (SMB 3.1.1) |
| Session state | `encrypted` |
| Credentials file | `/etc/samba/windows.creds` → mode `600 root:root` |
| `/etc/fstab` | mode `644 root:root` |
| Read from Windows | `README-from-windows.txt`, authored on the Windows side |
| Write to Windows | Verified by Windows `Get-Content`, exact payload match |
| Remount from fstab | `mount -a` with no arguments |
| Checks passing | 10 of 10 |

### 5.2 Throughput, each row naming the layer it measures

64 MiB through `/mnt/winshare` (`01-direction-a.log`).

| Measurement | Layer it describes | Result |
|---|---|---|
| write, `conv=fsync` | SMB3 to Windows, flushed to the server | 85.1 MB/s (0.788768 s) |
| read, cached | Linux client page cache; no byte on the wire | 8.7 GB/s (0.00774955 s) |
| read, cold, caches dropped | SMB3 from Windows | 26.0 MB/s (2.58178 s) |
| read, `O_DIRECT` | SMB3 from Windows, client cache bypassed | 24.3 MB/s (2.76082 s) |

Loopback Samba, same 64 MiB, client and server on the same host
(`01-smb-mount.log`): write 329 MB/s, read 680 MB/s. Neither figure was
cache-controlled and no byte crossed a wire, so both describe Samba's own code
path and the page cache rather than an SMB transport.

### 5.3 XFS

Source: `01-xfs.log`.

| Property | Measured |
|---|---|
| Geometry | `agcount=4`, `agsize=131072 blks`, `bsize=4096`, `isize=512` |
| Feature flags | `crc=1`, `finobt=1`, `sparse=1`, `reflink=1`, `bigtime=1`, `inobtcount=1` |
| Data blocks at mkfs | 524,288 |
| Largest offset the kernel accepts | 9,223,372,036,854,775,807 bytes (8.00 EiB) |
| 1 TB file `st_size` | 1,099,511,627,776 bytes |
| 1 TB file `st_blocks` | 0 |
| `fallocate` reservation | 2,097,152 × 512 = 1,073,741,824 bytes |
| Extent records for that 1 GiB | 3, across allocation groups 1, 3 and 0 |
| Online growth | `data blocks changed from 524288 to 1048576`, 2.0G → 4.0G |
| Final state | `/dev/loop2 xfs 4.0G 1.1G 2.9G 27% /mnt/xfs` |

The 1 TB file is sparse: 1,099,511,627,776 bytes of `st_size` against 0
allocated blocks. It establishes that the filesystem addresses a 1 TB single
file. The `fallocate` step is what exercises the allocator, and it reserved
real extents — 1,073,741,824 bytes of them, laid out in the three records above.

### 5.4 Monitoring

Queried live from the Prometheus HTTP API during load (`01-monitoring.log`).

| Metric | XFS mount `/mnt/xfs` | SMB share `/mnt/winshare` |
|---|---|---|
| filesystem size | 4,227,858,432 B | 999,355,838,464 B |
| available | 3,895,836,672 B | 362,871,508,992 B |
| used | 7.8531901041666625 % | 63.68947236274421 % |
| inodes used | 0.0002384185791015625 % | — |
| mean service time | 0.0010902981624248684 s | — |
| average queue depth | 3.6895103369274693 | — |
| write throughput | 72,470,114.95 B/s | — |

The `fio` load that produced those counters: read IOPS 9,562 at 598 MiB/s,
write IOPS 4,098 at 256 MiB/s over 15,001 ms, with read completion latency at
the 99th percentile of 898 µs and at the 99.9th of 4,293 µs.

SMB client health from `/proc/fs/cifs`, exported through the textfile collector
(`01-monitoring.log`):

```
cifs_max_requests_in_flight 3
cifs_session_reconnects_total 5
cifs_sessions 1
cifs_share_reconnects_total 2
cifs_shares 2
cifs_up 1
cifs_vfs_operations_total 1941
```

Prometheus scrape state: `up{job="node"} = 1`, two targets healthy, ten
alerting rules loaded.

### 5.5 Alerting

`promtool check rules` reports `SUCCESS: 10 rules found`; the reload endpoint
returns HTTP 200 and Prometheus reports 10 rules live (`01-alerts.log`).

| Alert | Condition created | Transition | Recovery |
|---|---|---|---|
| `FilesystemSpaceCritical` | filled `/mnt/xfs` from 8% to 88% | pending t+11 s, firing t+25 s | inactive t+12 s |
| `MountMissing` | unmounted `/mnt/xfs` | pending t+8 s, firing t+38 s | inactive t+10 s |
| `SmbMountMissing` | unmounted `/mnt/winshare` | pending t+7 s, firing t+37 s | inactive t+7 s |

The firing payloads, read from the Prometheus alerts API:

```
      state    : firing
      activeAt : 2026-08-26T18:53:37.724967937Z
      value    : 8.721826946924604e+01
      severity : critical
      slo      : capacity
      summary  : Filesystem /mnt/xfs is over 85% full

      state    : firing
      activeAt : 2026-08-26T18:54:16.649344637Z
      value    : 1e+00
      severity : critical
      slo      : availability
      summary  : Monitored mount /mnt/xfs is not present

      state    : firing
      activeAt : 2026-08-26T18:55:06.649344637Z
      value    : 1e+00
      severity : critical
      slo      : availability
      summary  : SMB share /mnt/winshare is not present
```

`SmbMountMissing` is the one the availability objective is written about. The
other two watch a local loop device; this one watches the share mounted from
Windows.

### 5.6 The Linux server, and the Windows mapping procedure

Source: `01-direction-b.log`.

| What | Measured |
|---|---|
| `smbd` listening | `0.0.0.0:445` and `[::]:445`, backlog 50 |
| Share advertised | `task01  Disk  Task 01 export from Linux to Windows` |
| Protocol floor | `min protocol : SMB3` |
| Encryption | `encryption   : required` |
| SMB1 | `SMB1 disabled -- no workgroup available` |
| WSL distro namespace | netns 4026531840, eth0 172.25.112.168/20 |
| Container namespace | netns 4026532218, eth0 192.168.65.3/24 |
| Windows reaching the distro | `Test-NetConnection 172.25.112.168:4446 -> True` |
| Port 445 on Windows | held by PID 4 (System) at `0.0.0.0:445` |

Those measurements fix the address a Windows client maps. Windows has a route
to 172.25.112.0/20 and reaches a listener there, proven with the 4446 probe,
even though the WSL vSwitch adapter carries `DefaultInboundAction: Block`. The
Windows SMB client connects on 445 only, and Windows itself owns 445 on the
host, so the server has to own port 445 on an address inside that routed range.
The procedure that follows, printed by the script:

```
  wsl --install -d Ubuntu
  sudo apt-get install -y samba && sudo smbpasswd -a $USER
  # copy linuxbox/smb.conf, then: sudo systemctl start smbd

  net use Z: \\172.25.112.168\task01linux /persistent:yes
  New-SmbMapping -LocalPath Z: -RemotePath \\172.25.112.168\task01linux -Persistent $true
```

with an alternative that keeps the container and bridges the two namespaces
from the Windows side:

```
  netsh interface portproxy add v4tov4 listenport=445 \
        listenaddress=172.25.112.168 connectport=445 \
        connectaddress=192.168.65.3
```

### 5.7 The suite

`scripts/verify.sh` runs all eight checks end to end: 8 checks, 0 failures,
from 23:57:07 to 00:04:02 (`01-verify-suite.log`).

---

## 6. What the measurements revealed

### 6.1 A read taken straight after a write measures RAM

The first throughput run on the Windows share read the file back immediately
after writing it and reported 9.5 GB/s. The number is not wrong — the bytes
really were delivered that fast — but the layer it describes is the Linux
client page cache, not SMB and not the network.

What made it stand out was not suspicion. It was arithmetic. 9.5 GB/s is
roughly seventy-six times the theoretical ceiling of a 1 GbE link. A figure
that violates the physics of the path underneath it is announcing which layer
it came from. A plausible-looking number — 300 MB/s, say — would have gone
straight into the report and stayed there.

Measured properly, with `sync; echo 3 > /proc/sys/vm/drop_caches` between write
and read, and cross-checked with `iflag=direct`:

| Read | Result |
|---|---|
| Cached | 8.7 GB/s |
| Cold, caches dropped | 26.0 MB/s |
| `O_DIRECT` | 24.3 MB/s |

The cold and direct figures agree to within about 7%, and that agreement is the
reason to believe either of them: two independent ways of bypassing the cache
landed in the same place. The cached figure is 330 times higher, and it is
genuinely useful information — it shows the cache is doing its job — as long as
it is labeled as what it is. The habit this produces is cheap: bound every
measurement against something physical before believing it. Link capacity, a
cgroup limit, a device's rated throughput. The bound need not be tight, only a
ceiling the number cannot legitimately exceed.

### 6.2 An argument-passed secret really is visible in `ps`

This is the kind of claim that gets repeated without being checked, so the
script checks it. It starts a background process carrying a fake password as an
argument and greps the process table (`01-smb-mount.log`):

```
    processes exposing the fake password in ps: 1
[PASS] confirmed: an argument-passed secret IS visible in ps to any user
      root      1846  0.0  0.0   3932  2944 ?        S    03:18   0:00 bash -c sleep 5; : probe --password=FAKE-PASSWORD-abc123
```

Look at the command that produced it: `bash -c 'sleep 5; :' probe
--password=FAKE-PASSWORD-abc123`. The trailing `; :` is doing real work.
`bash -c` with a single simple command **execs** into that command and
discards the extra argv, so `bash -c "sleep 5" probe --password=X` leaves a
process whose `/proc/<pid>/cmdline` reads only `sleep 5` — the password
vanishes, and the probe reports zero processes exposing it. A second statement
in the string defeats that optimization, bash stays resident, and the full argv
including the password is right there for every user on the system to read.

A probe with that flaw reports "no leak found", which reads as *the claim is
false* rather than *the probe is broken*. A negative result deserves the same
scrutiny as a positive one, and the way to earn confidence in one is to make
the check produce a positive under conditions where the answer is known.

Hence the credentials file. `/etc/fstab` is mode 644 — measured, not assumed
(`01-persistence.log`) — because other tools have to read it, so a password
there is readable by every local account. `/etc/samba/windows.creds` is mode
600 root:root. The fstab entry names the file; the file holds the value.

### 6.3 node_exporter hides loop devices by default

node_exporter's default `--collector.diskstats.device-exclude` is:

```
^(z?ram|loop|fd|(h|s|v|xv)d[a-z]|nvme\d+n\d+p)\d+$
```

The XFS filesystem under test lives on a loop device. With the default in
place, every `node_disk_*` series for it is missing while the exporter returns
HTTP 200 and looks entirely healthy. There is no error, no warning, no
degraded state — the series simply do not exist. A dashboard built on them
renders empty panels, and an alert rule written against them evaluates against
nothing and stays inactive forever.

`/proc/diskstats` had the data the whole time. `01-monitoring.log` shows
`loop2` with 731,167 completed reads in field 4 of its counter line. The
exporter was reading that file and dropping the row.

The fix is one flag in `entrypoint.sh`, narrowing the exclusion to the devices
that genuinely are noise:

```
--collector.diskstats.device-exclude='^(z?ram|fd)[0-9]+$'
```

After it, ten `node_disk_*{device="loop2"}` series are present, including
`node_disk_io_time_seconds_total 69.612` and
`node_disk_io_time_weighted_seconds_total 1260.218` — the two the latency and
queue-depth rules are built on. The general shape is worth keeping: a default
that filters decides what you can see, and it decides silently. Verifying a
monitoring stack means asking whether the specific series a rule needs exist,
by name, for the specific device — not whether the exporter is up.

### 6.4 Availability is the absence of a series, not a value of one

When a filesystem is unmounted, node_exporter stops publishing
`node_filesystem_*` for that mountpoint. The series does not fall to zero. It
ceases to exist. Any rule of the form `node_filesystem_avail_bytes{...} < X`
has nothing left to evaluate and stays quiet through the entire outage — which
is exactly the condition it was written to catch.

So availability is monitored with `absent()`:

```yaml
- alert: SmbMountMissing
  expr: absent(node_filesystem_size_bytes{mountpoint="/mnt/winshare"})
  for: 30s
```

One detail decides the shape of these rules: `absent()` is per-expression, not
per-series. A single rule with a regex matching both mountpoints would only
fire when *both* vanished, because the vector is non-empty as long as either
one is present. Each mount therefore gets its own rule. Both were driven to
firing separately (`01-alerts.log`), which is how that property was confirmed
rather than assumed.

A mount can also be present and failing every write. The kernel remounts a
filesystem read-only when it hits an I/O error it cannot recover from, so
`MountReadOnly` watches `node_filesystem_readonly == 1` — a condition a
presence check cannot see and a capacity check would read as healthy.

### 6.5 Filesystem metrics cannot see a session that keeps reconnecting

node_exporter describes a CIFS mount the way it describes any filesystem: size,
free, read-only. That answers "is it mounted and does it have room", which is
most of the availability objective and none of the interesting part. An SMB
mount can be mounted, writable, and reporting hundreds of gigabytes free while
the client tears down and rebuilds its session on every operation. Throughput
collapses. Latency goes vertical. Every filesystem-level metric stays green.

`/proc/fs/cifs/Stats` carries the counter that sees it:

```
5 session 2 share reconnects
```

`linuxbox/cifs-metrics.sh` parses that file every 5 s into node_exporter's
textfile collector, emitting `cifs_session_reconnects_total`,
`cifs_share_reconnects_total`, `cifs_sessions`, `cifs_shares`,
`cifs_vfs_operations_total`, `cifs_max_requests_in_flight` and `cifs_up`. The
alert on it is a rate, not a threshold:

```yaml
expr: rate(cifs_session_reconnects_total[2m]) > 0
for: 1m
```

Reconnects rise before throughput falls and long before the mount disappears,
so this catches a degrading link while it is still serving traffic. The
`cifs_up` gauge covers the other end of the spectrum: if `/proc/fs/cifs/Stats`
is unreadable the module is not loaded, and no SMB mount can exist at all.

The script writes to a temp file and `mv`s it into place. node_exporter reads
that directory on every scrape, and a half-written `.prom` file makes it emit a
parse error in place of the metrics — a self-inflicted monitoring outage from a
non-atomic write.

Two lines of `01-monitoring.log` explain a scoping decision. For the CIFS
mount, `node_filesystem_files` and `node_filesystem_files_free` are both 0,
because SMB reports no inode budget. An inode-usage rule matching both mounts
would evaluate `100 * (1 - 0/0)` for the share — NaN, which never crosses a
threshold and looks healthy forever. `FilesystemInodesCritical` is scoped to
`/mnt/xfs` alone for that reason.

### 6.6 A rule that has never fired is a hypothesis

Ten rules parse. That establishes syntax and nothing else. Between a parsing
rule and a working one sit at least five failure modes: the metric may not
exist under that name, the label selector may match nothing, the threshold may
be unreachable in practice, the `for:` duration may never elapse because the
condition oscillates, and the alert may never surface on the API.

Driving three rules through the full cycle exercises all five at once. The
recovery half matters as much as the trigger: an alert that fires and then
stays firing after the condition clears is its own outage, because it trains
whoever is on call to ignore it.

The first fill attempt is the most instructive part of that drill. It computed
92% of `df --output=avail` and allocated it in one go, and reached 70% used.
The alert stayed inactive, correctly — the condition never existed. XFS
reserves blocks, so "available" is not the same as "what can still be written",
and a single calculated allocation derived from it undershoots. The script now
fills in steps and checks after each, and reached 88%:

```
      Filesystem      Size  Used Avail Use% Mounted on
      /dev/loop2      4.0G  3.5G  516M  88% /mnt/xfs
```

The rule was right both times. Only the drill needed fixing, and that is the
distinction worth being careful about when a check comes back green: whether
the thing under test passed, or the test never ran.

### 6.7 A Windows limit that lives in the API, not the language

The first elevated run of `setup-share.ps1` stopped with a
`ParameterArgumentValidationError` from `New-LocalUser`. The cause was a
52-character description:

```
-Description 'Created by 01-storage-mounts/windows/setup-share.ps1'
```

Windows caps a local account description at 48 characters. Nothing catches this
earlier. The string is a valid literal, the script parses cleanly, and
`[Parser]::ParseFile` is perfectly happy with it. The limit lives in the API
rather than the language, so it surfaces only when the account is actually
created — and the error names the parameter without ever mentioning the limit
or the length. It happened to fail before mutating anything. It could as easily
have failed halfway through, leaving an account created and no share.

A shorter string fixes that instance. The class of fault is what
`Assert-WindowsLimits` addresses: it runs before anything is mutated, validates
every value Windows caps, reports the field, the actual length, the limit and
the offending value, and refuses to touch the machine when any check fails.

The same pass hardened the password generator beside it. It came from
`[Convert]::ToBase64String($bytes) -replace '[+/=]', ''` followed by
`.Substring(0, 16)`. Stripping those three characters removes a variable amount
of material, so an unlucky draw leaves fewer than 16 characters and throws —
rarely, non-deterministically, and only at account-creation time. It now draws
until there is enough material, and a fixed `Ta1!` prefix guarantees all four
complexity classes so the local password policy is satisfied by construction
rather than by luck.

### 6.8 A listening socket and a reachable service are different things

Port 445 was reachable from the container on all three Windows addresses
throughout — `01-direction-a.log` records `445 OPEN` for `172.25.112.1`,
`host.docker.internal` and `192.168.65.254`. The TCP handshake completes.
Whether an SMB session can be established on top of it is a separate question,
and the File and Printer Sharing (SMB-In) firewall rules are what answers it.

That is why `setup-share.ps1` enables those rules explicitly and records which
ones it flipped into `windows/.setup-state.json`, so teardown re-disables
exactly those and leaves any that were already on. A reachability check that
stops at "port open" reports everything fine. The check that means something is
the share listing: `smbclient -L` returning `task01share` proves a session was
negotiated, authenticated, and served.

### 6.9 `losetup -c` before `xfs_growfs`

The first growth attempt reported success and changed nothing. `truncate -s 4G`
had grown the backing file, but the loop device was still serving the old
capacity, so `xfs_growfs` found no additional space and reported that it had
finished. A silent no-op that reports success is worse than an error, because
nothing downstream has any reason to look again.

`losetup -c` forces the loop device to re-read the backing file's size. With it
in place the sequence produces the change (`01-xfs.log`):

```
      loop now exposes 4.0 GiB
      data blocks changed from 524288 to 1048576
```

2.0G to 4.0G, online, with the filesystem mounted and in use the whole time.

### 6.10 Two environment facts that shape everything above

**A container cannot load a kernel module.** `modprobe cifs` inside the
container fails with `can't change directory to '/lib/modules'`, and `cifs` is
absent from `/proc/filesystems`. The module exists — `cifs.ko` is in the WSL
kernel tree — but a container shares the host kernel without shipping its
module tree, so the load happens outside, through `wsl -d docker-desktop` in
`scripts/up.sh`. Without it the mount fails with a bare "no such device", an
error that sends you looking at mount options, share names and credentials
before you think to check whether the filesystem type exists at all.

**`/mnt/c` is not an SMB mount.** It is the obvious shortcut and it proves none
of the things the task is about: a 9p/drvfs passthrough with no dialect
negotiated, no session authenticated, no encryption applied and no ACL
translated. Mounting a Windows volume on Linux in the sense the requirement
means is `mount -t cifs //host/share`, which is what produces `Dialect 0x311`
in the kernel's own record.

---

## 7. How to run it yourself

Docker Desktop with the WSL2 backend, and an elevated PowerShell for the
Windows-side setup.

### Bring the environment up

```bash
cd 01-storage-mounts
./scripts/up.sh
```

Idempotent. It generates the SMB password if absent, loads the `cifs` kernel
module through the WSL distro, builds `task01-linuxbox`, and blocks until both
services are healthy. It then prints the endpoints: node_exporter on
`http://127.0.0.1:9100/metrics`, Prometheus on `http://127.0.0.1:9090`, and the
alerts page at `http://127.0.0.1:9090/alerts`.

### Create the Windows share

From an elevated PowerShell, `cd 01-storage-mounts\windows` then
`.\setup-share.ps1`. It reports every value it validated and every change it
made. `.\teardown-share.ps1` reverses it.

### Run everything

```bash
./scripts/verify.sh
```

Eight checks in order, each writing its own section. Expect roughly seven
minutes — the alert drill spends most of it waiting for `for:` durations to
elapse.

### Run one piece at a time

```bash
./scripts/xfs-demo.sh      # XFS: geometry, 8 EiB ceiling, 1 TB file, extents, growth
./scripts/smb-mount.sh     # SMB3 mount mechanics against the local Samba server
./scripts/direction-a.sh   # the Windows share mounted on Linux, verified by Windows
./scripts/persistence.sh   # fstab, mount -a, and the nofail demonstration
./scripts/monitoring.sh    # diskstats, iostat, fio, node_exporter, Prometheus
./scripts/alerts-fire.sh   # drive three alerts to firing and back
./scripts/direction-b.sh   # the Linux SMB server and the Windows mapping procedure
```

`direction-a.sh` needs the Windows share to exist. Everything else is
self-contained.

### Capture evidence, and tear down

Any script can be wrapped so its command, timestamp and full output land in a
log: `../scripts/run-with-evidence.sh 01-monitoring "Requirement 4: monitoring"
bash scripts/monitoring.sh`.

`docker compose down` keeps the XFS image and the Prometheus data; `down -v`
removes both named volumes. Nothing outside Docker is left on the Linux side.
On the Windows side, `teardown-share.ps1` removes the share, the local account
and the directory, and re-disables only the firewall rules the setup run
recorded as having enabled — verified against `Get-SmbShare`, `Get-LocalUser`
and `Get-NetFirewallRule`.

---

## Evidence index for this task

| Log | Covers |
|---|---|
| `docs/evidence/01-xfs.log` | XFS geometry, 8 EiB ceiling, 1 TB file, extent map, online growth |
| `docs/evidence/01-smb-mount.log` | Credentials file, `ps` leak demonstration, dialect 0x311, encrypted session, round trip |
| `docs/evidence/01-direction-a.log` | The Windows share mounted on Linux, verified by Windows, layered throughput, fstab |
| `docs/evidence/01-persistence.log` | fstab entry option by option, `mount -a`, the `nofail` demonstration |
| `docs/evidence/01-monitoring.log` | diskstats, iostat, fio, node_exporter series, CIFS counters, live Prometheus queries |
| `docs/evidence/01-alerts.log` | The SLO, promtool, and three alerts driven inactive → pending → firing → inactive |
| `docs/evidence/01-direction-b.log` | Samba serving SMB 3.1.1 with encryption required, namespace measurements, mapping procedure |
| `docs/evidence/01-verify-suite.log` | All eight checks in one run |
