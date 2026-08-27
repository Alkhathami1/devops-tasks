# Task 01 — Windows ↔ Linux volume mounting, XFS, monitoring and alerting

> A real Windows share mounted on Linux over SMB 3.1.1 and verified by Windows
> reading back what Linux wrote, an XFS filesystem built for 1 TB single files,
> monitoring over both mounts, and ten alert rules with three driven to firing.
> Full detail in `WALKTHROUGH.md`; evidence in `../docs/evidence/01-*.log`.

| # | Requirement | Delivered |
|---|---|---|
| 1 | Protocol choice and justification | SMB 3.1.1 on the identity model; dialect `0x311` and an encrypted session read from the kernel |
| 2 | Mounting steps | Real Windows share mounted with `mount.cifs`; round trip verified by Windows |
| 3 | Persistence across reboots | fstab for both shares with a mode-600 credentials file; remount proven by `mount -a` alone |
| 4 | Monitoring mount and disk performance | diskstats, iostat, fio, node_exporter and Prometheus over both mounts, plus CIFS session counters |
| 5 | Alerting to guarantee an SLA | 10 rules against a stated SLO; 3 driven inactive to pending to firing and back |
| 6 | Filesystem for 1 TB single files | XFS; 8 EiB ceiling measured, extent map read, grown online |
| 7a | Windows to Linux | `task01share` mounted, written, verified by Windows |
| 7b | Linux to Windows | Samba serving SMB 3.1.1 with encryption required; Windows mapping procedure documented |

## Quick start

```bash
./scripts/up.sh            # build and start linuxbox + prometheus
./scripts/verify.sh        # every check
```

Individual pieces:

```bash
./scripts/xfs-demo.sh      # req 6: build XFS, prove 1 TB capability
./scripts/smb-mount.sh     # req 1,2: SMB3 mount mechanics
./scripts/persistence.sh   # req 3: fstab, and the nofail boot-hang
./scripts/monitoring.sh    # req 4: diskstats, iostat, Prometheus queries
./scripts/alerts-fire.sh   # req 5: drive two alerts to firing
./scripts/direction-a.sh   # Windows share → Linux (needs the Windows setup)
./scripts/direction-b.sh   # Linux share → Windows
```

## Completing the Windows directions

Direction A needs a share, which needs elevation:

```powershell
# Right-click PowerShell → Run as Administrator
cd 01-storage-mounts\windows
.\setup-share.ps1        # creates a dedicated user, share, firewall rules
```

The script runs `Assert-WindowsLimits` first and refuses to touch the machine if
any value exceeds a Windows cap — local user name 20, description 48, full name
256, share name 80, share remark 256 — plus the SAM name rules (not empty, no
trailing period, no `" / \ [ ] : ; | = , + * ? < >`). These limits live in the
API rather than the language, so they pass every syntax check and then fail at
account-creation time; the first elevated run hit exactly that with a
52-character description.

Then `./scripts/direction-a.sh` completes the mount. `.\teardown-share.ps1`
reverses everything.

Direction B needs Samba to run in a **real WSL distro** rather than a
container — see the diagnosis in `../docs/evidence/01-direction-b.log`.

## Serving Direction B from the WSL distro

**Direction B.** Not a firewall problem, despite appearances. Docker Desktop
runs containers in a network namespace separate from the WSL distro:

```
WSL distro   netns 4026531840   eth0 172.25.112.168/20   ← Windows routes here
container    netns 4026532218   eth0 192.168.65.3/24     ← Windows has no route
```

`--network host` does not help — on Docker Desktop that means the *Docker VM's*
host namespace, not the distro's. Three workarounds were tested and each ruled
out: Windows *can* reach the distro (a listener on `172.25.112.168:4446`
answered `True`, so the Hyper-V firewall is not the obstacle); publishing to
IPv4 445 is impossible because Windows holds `0.0.0.0:445` (PID 4); and a
forwarder in the distro cannot reach `192.168.65.3` and the distro ships only
busybox.

## Environment gotchas handled

- **`/mnt/c` is not a CIFS mount.** It is 9p/drvfs passthrough — no dialect, no
  session, no authentication. Mounting a Windows share properly means speaking
  SMB to `\host\share`, which `direction-a.sh` does.
- **WSL2 is NAT'd**, so the Windows host is not `127.0.0.1` from inside.
- **The `cifs` module must be loaded on the host first.** A container cannot
  `modprobe` — it has no `/lib/modules`. `up.sh` loads it via the WSL distro.
- **SMB1 stays disabled**, verified on both ends.
- **node_exporter excludes loop devices by default**, which silently hides every
  disk metric for a loopback-backed filesystem.

## Layout

| Path | Purpose |
|---|---|
| `compose.yaml` | linuxbox (Samba + CIFS client + XFS + node_exporter), Prometheus |
| `linuxbox/smb.conf` | SMB3.1.1 floor, encryption required, signing mandatory |
| `prometheus/alerts.yml` | 7 alert rules tied to an explicit SLO |
| `windows/setup-share.ps1` | The elevated Windows-side setup |
| `windows/teardown-share.ps1` | Reverses all of it |
