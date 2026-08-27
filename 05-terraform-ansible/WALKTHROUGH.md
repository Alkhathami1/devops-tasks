# Task 05 — Three-tier infrastructure on GCP with Terraform and Ansible

A walkthrough of what was built, why each decision went the way it did, how it
was run, and what the measurements showed. The report carries the summary; this
document carries the reasoning and the full detail behind it.

---

## 1. What this task required, and how I read it

The requirement, in the requester's words:

> **5.1** "3 networks (public: nginx reverse proxy routing to the app; apps: an
> app server that reads from and writes to the database; dbs: the database)"
>
> **5.2** "3-tier/N-tier architecture"
>
> **5.3** "proper network segmentation"
>
> **5.4** "access to the servers over a private VPN — especially the app and DB
> tiers"
>
> **5.5** "Terraform or any similar tool"
>
> **5.6** Ansible configuration of the provisioned servers

Four readings shaped everything downstream.

**"3 networks" means three networks.** GCP's word for a network is a VPC, and a
subnet is a range inside one. Three subnets in a single VPC would satisfy a
loose reading of the sentence and would produce a materially weaker result,
because subnets in one VPC route to each other by default. I read the word
literally: three VPCs.

**"Proper network segmentation" is a property of the topology, not of a rule
set.** A firewall rule is a filter applied to a packet that has somewhere to go.
Segmentation that survives an editing mistake has to remove the destination
itself. That reading is what put VPC peering, and specifically its
non-transitivity, at the center of the design.

**"Especially the app and DB tiers" describes who the VPN is for.** The private
tiers hold no public address, so the tunnel is the operator's path to the
estate. I read this as: the tunnel terminates in the public tier on a bastion,
and the routes it advertises are the ranges the bastion can actually deliver to.
Access is a claim until something is used over it, so the app tier also exports
an SMB share that has no path to it except the tunnel.

**"Ansible configuration" means the servers are configured by Ansible, not by
startup scripts.** Terraform creates the machines and the network; Ansible
installs and configures everything on them. The two tools meet at exactly one
place — `terraform output -json` — so no address is written twice.

---

## 2. Design decisions

### 2.1 Three separate VPCs rather than three subnets in one

Three subnets in one VPC are mutually routable the moment they exist. GCP
installs a subnet route for each range into the VPC's routing table, so
`public → dbs` works by default and the only thing standing between the internet
tier and the database is a firewall rule.

A firewall rule can be edited, applied to the wrong target, or shadowed by a
higher-priority rule. Each of those is a single mistake away, and each of them
leaves the topology unchanged and the boundary open.

Separate VPCs invert that. Two VPCs share no routes at all unless a peering is
created between them, so the default state is unreachable and reachability is
the thing that has to be deliberately added. That property — the boundary
survives a firewall mistake — is what decided it.

The rejected alternative and the reason: **one VPC with three subnets**,
rejected because its tier boundary is a filter over a live route rather than the
absence of a route.

`terraform/network.tf` creates `task05-public-vpc`, `task05-apps-vpc` and
`task05-dbs-vpc`, each with `auto_create_subnetworks = false` so no default
ranges appear anywhere, and `routing_mode = "REGIONAL"` because everything lives
in one region.

### 2.2 A peering chain, and non-transitivity as the enforcement mechanism

Two peering relationships exist:

```
public  <--peer-->  apps  <--peer-->  dbs
```

GCP VPC peering is **non-transitive**. `public` and `dbs` are each one hop from
`apps`, and there is no route between them — none is installed, and none can be
installed short of peering them directly. So:

| Path | Exists |
|---|---|
| nginx (public) → app (apps) | yes, direct peering |
| app (apps) → db (dbs) | yes, direct peering |
| nginx (public) → db (dbs) | no route exists |

Non-transitivity is usually written up as a constraint to work around. Here it
is the mechanism. The tier boundary between the internet-facing tier and the
database tier is enforced at the routing layer: the public VPC's routing table
holds no entry whose destination covers `10.30.0.0/16`, so a packet addressed
there has nowhere to go. There is nothing to misconfigure, because there is
nothing there.

Each direction of each peering is its own Terraform resource — four in total —
because a peering only reaches `ACTIVE` once both sides exist. Creating both
directions concurrently is a documented source of transient API errors, so
`depends_on` serializes them: `public_to_apps` → `apps_to_public` →
`apps_to_dbs` → `dbs_to_apps`.

Route exchange is narrowed on every peering: `export_custom_routes = false` and
`import_custom_routes = false`. Only subnet routes cross, so a custom route
added inside one tier cannot silently extend reachability into another.

### 2.3 The CIDR plan

| Tier | VPC | Subnet in use | Usable hosts | Spare /24s |
|---|---|---|---|---|
| public | `10.10.0.0/16` | `10.10.1.0/24` | 251 | 255 |
| apps | `10.20.0.0/16` | `10.20.1.0/24` | 251 | 255 |
| dbs | `10.30.0.0/16` | `10.30.1.0/24` | 251 | 255 |
| vpn | `10.99.0.0/24` | WireGuard peers | 251 | — |

A /24 yields **251** usable addresses rather than 254. GCP reserves four per
subnet: the network address, the default gateway, the second-to-last address,
and the broadcast address.

Each tier holds a /16 while using a single /24, which leaves 255 further /24s
per tier available without renumbering. That headroom is worth having because
**peering rejects overlapping ranges outright** — the peering does not reach
`ACTIVE`, and the error names the overlap. Renumbering a peered VPC therefore
means tearing the peering down first, and a peering that has to come down takes
the tier boundary with it for the duration.

The ranges are deliberately far apart and non-contiguous. `10.10`, `10.20` and
`10.30` rather than three adjacent /16s leaves room to summarize a tier into a
single route later without colliding with its neighbor.

`10.99.0.0/24` sits outside every VPC range on purpose. A tunnel address that
overlaps a routable range leaves the client unable to decide whether a packet
belongs in the tunnel or out its own NIC, and the symptom is intermittent rather
than clean.

### 2.4 Deny by default, with service accounts as targets

GCP denies all ingress implicitly at priority 65535, so every rule written here
is an explicit hole. An explicit catch-all deny is added anyway at priority
65534 with `log_config { metadata = "INCLUDE_ALL_METADATA" }`, so the posture
reads directly out of `gcloud compute firewall-rules list` rather than resting
on a default someone has to know about. `05-plan.log` shows
`task05-apps-deny-all-ingress` and `task05-dbs-deny-all-ingress` at that
priority.

**Targets use service accounts throughout, never network tags.** A network tag
can be added to any instance by anyone holding `compute.instances.setTags`.
Changing an instance's service account requires stopping the instance and holds
an IAM permission most people do not have. That difference in how hard the
target is to change is what decided it.

The rejected alternative and the reason: **network tags as targets**, rejected
because the set of instances a tag-targeted rule applies to can be widened by a
single API call from a low-privilege identity.

### 2.5 Cross-VPC sources: where the mechanism changes

Both `source_tags` and `source_service_accounts` apply **only to traffic from
instances in the same VPC network**. They do not traverse a VPC peering. GCP
accepts such a rule, `terraform apply` succeeds, `gcloud compute firewall-rules
list` shows it, and it never matches anything.

Every tier-to-tier hop in this topology crosses a peering, so those hops express
their source as a CIDR. The split, as built:

| Hop | Crosses peering | Source mechanism | Rule |
|---|---|---|---|
| bastion → nginx:22 | no, same VPC | `source_service_accounts` | `task05-public-allow-bastion-to-nginx` |
| nginx → app:8080 | yes | `source_ranges = ["10.10.1.0/24"]` | `task05-apps-allow-nginx` |
| bastion → app:22 | yes | `source_ranges = ["10.10.1.0/24", "10.99.0.0/24"]` | `task05-apps-allow-bastion-ssh` |
| app → db:5432 | yes | `source_ranges = ["10.20.1.0/24"]` | `task05-dbs-allow-app-postgres` |
| app → db:22 | yes | `source_ranges = ["10.20.1.0/24"]` | `task05-dbs-allow-admin-ssh` |

All five source values come from `05-plan.log`. Where a CIDR carries the source,
it is a single /24 — never a supernet, never `0.0.0.0/0` — and every one of
those rules still pins the far end with `target_service_accounts`, so both ends
are constrained even though only one end can be expressed by identity.

The database's rules admit `10.20.1.0/24` on 5432 and on 22, and nothing else.
What is worth noticing is the shape of the rule set rather than any single rule:
the public subnet appears in no rule in the dbs VPC, and even a rule that
admitted it could not take effect, because the public VPC holds no route to that
range. Two layers, and the outer one is routing rather than a second rule at the
same layer.

### 2.6 No public addresses on the app and database tiers, and Cloud NAT

The bastion and nginx each carry an ephemeral external address. The app and
database instances have no `access_config` block at all, so no public NIC exists
on them.

An instance with no public address also has no egress, and the failure mode is
worth stating because it does not look like a networking problem: the instance
boots, SSH through the bastion works, and then `apt-get install` hangs until it
times out with a DNS or connection error that says nothing about the cause.
Cloud NAT supplies that egress. NAT is implemented as a Cloud Router feature, so
each private tier carries a router that does no BGP and exists only to host the
NAT configuration: `task05-apps-router` with `task05-apps-nat`, and
`task05-dbs-router` with `task05-dbs-nat`, both `AUTO_ONLY` over
`ALL_SUBNETWORKS_ALL_IP_RANGES`, both with error logging on (`05-plan.log`).

The external addresses on the bastion and nginx are **ephemeral, not reserved**.
A reserved static address survives `terraform destroy` and stays in the project
unattached, which is exactly the class of leftover the teardown check hunts for.

`private_ip_google_access = true` on all three subnets lets the private tiers
reach Google APIs without a public address.

### 2.7 WireGuard for the tunnel

WireGuard on the bastion, installed and configured by the `wireguard` Ansible
role. Three properties decided it:

- It is in the mainline Linux kernel, so there is no userspace daemon in the
  data path.
- Its configuration is small enough to audit at a glance — an interface block
  and a peer block.
- It is silent to unauthenticated packets. A handshake not signed by a known
  peer key is dropped without a reply, so a scan of UDP 51820 draws nothing
  back.

The rejected alternatives and the reasons: **IPsec**, rejected because its
configuration surface — IKE proposals, phase 1 and phase 2 lifetimes, NAT
traversal — is large enough that auditing it at a glance is not possible;
**OpenVPN**, rejected because it runs in userspace with the tunnel's throughput
bounded by a daemon's context switching, and because it answers a TLS handshake
to any prober.

Two settings are both required for the tunnel to route, and each lives in a
different place. `can_ip_forward = true` on the bastion instance is the GCP
half — the platform otherwise drops any packet the instance emits with a source
or destination that is not its own. `net.ipv4.ip_forward = 1` is the kernel
half, set by `ansible.posix.sysctl` in the role. Either one missing produces the
same misleading symptom: the interface comes up, the handshake completes, and
nothing routes past the bastion. That reads as a firewall problem and is not
one.

### 2.8 What the tunnel advertises, and why the list is what it is

The client configuration's `AllowedIPs` reads:

```
AllowedIPs = 10.10.0.0/16, 10.20.0.0/16, 10.99.0.0/24
```

`AllowedIPs` on a WireGuard client is a routing statement: it tells the client
which destinations to send down the tunnel. The bastion sits in the public VPC,
which peers with apps and does not peer with dbs, so the bastion can forward
into `10.20.0.0/16` and cannot forward into `10.30.0.0/16`. Advertising the
database range would take the client's packets into the tunnel and drop them at
the far end — the tunnel would look healthy while that one destination failed
silently.

So the list contains the ranges the tunnel can deliver to, and administering the
database goes one hop further in, through the app tier:

```
ssh -J ansible@<bastion>,ansible@<app> ansible@<db>
```

That is the same chain the Ansible inventory builds automatically. The topology
shows up in the operator's tooling rather than only in a diagram, which is the
point of choosing routing as the enforcement layer in the first place — the
constraint is visible everywhere, including in the places that are inconvenient.

### 2.9 Metadata SSH keys, with OS Login turned off per instance

GCP offers two SSH paths and they are mutually exclusive. With
`enable-oslogin = TRUE`, metadata SSH keys are ignored entirely, and the failure
presents as a permission problem rather than a configuration one: the key is
present, sshd is running, and the login is refused.

Ansible needs a plain key path that a `ProxyJump` chain can carry through every
hop, so this build uses metadata keys. Rather than depend on whatever the
project default happens to be, `enable-oslogin = "FALSE"` is set **explicitly in
the metadata of every instance**. An instance-level value wins over the project
setting, so the Ansible path holds regardless of what the project inherits today
and regardless of what someone changes it to later.

`05-plan.log` shows that value on all four instances, at lines 346, 441, 541 and
636, each sitting beside the `ssh-keys` entry it protects:

```
+ "enable-oslogin" = "FALSE"
+ "ssh-keys"       = "ansible:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMJSMpJY7HtQ66xl5Kmn/TIMc8A7so1WTZHhhQnHaKTO ansible@task05"
```

The trade is real in both directions. OS Login gives IAM-governed access,
automatic key rotation and audit logging, and is the right choice for anything
long-lived. Metadata keys are chosen here because the estate exists for one
session and Ansible needs the key on every hop of the chain.

### 2.10 Ansible from a container

An Ansible control node has to be POSIX, and the host for this work is Windows.
The control node is therefore a container built from `ansible/Dockerfile` on
`debian:12-slim`, carrying `ansible`, `openssh-client`, `python3`,
`python3-jmespath`, `jq`, `curl`, `iputils-ping` and `netcat-openbsd`. Building
from a pinned base also fixes the Ansible version, so a rerun months later
behaves the same way.

### 2.11 Local Terraform state

Local state, deliberately, for a single operator applying and destroying inside
one session. It keeps the stack reproducible from a clone with no prior setup.

For anything shared it would be the wrong choice on two counts, both written
into `terraform/versions.tf` as the reason the decision is scoped to this
exercise:

1. **State holds secrets in plaintext.** Generated passwords, private keys and
   any sensitive output land in the state file unencrypted. `.tfstate` is
   gitignored, and `scripts/audit.sh` at the repository root fails the build if
   one is ever tracked.
2. **Concurrent applies produce a lost update.** Two operators running apply
   against the same state file overwrite each other's resource records, after
   which Terraform believes resources exist that do not, or the reverse.

The shared answer is a GCS backend, which gives remote storage and object-level
locking in one thing — no separate lock table, unlike S3's historical DynamoDB
requirement. Versioning on the bucket so a corrupted state can be rolled back,
and uniform bucket-level access to keep the ACL surface small.

### 2.12 Machine shape

`e2-micro` throughout: 2 shared vCPU, 1 GB memory, a 10 GB `pd-standard` boot
disk, `debian-cloud/debian-12`, all four instances in one zone
(`us-central1-a`). Shared-core means bursty work runs slowly rather than
failing, which is the right trade for a stack whose job is to demonstrate a
topology. Debian 12 matches the base image the Ansible roles are written
against.

---

## 3. How it is built

### 3.1 The topology

```
                          internet
                              │
                     ┌────────┴────────┐
                     │ 443             │ 22 + 51820/udp
                     ▼                 ▼
        ┌────────────────────────────────────────────┐
        │ PUBLIC VPC            10.10.0.0/16         │
        │ subnet                10.10.1.0/24         │
        │                                            │
        │   nginx 10.10.1.2       bastion 10.10.1.3  │
        │   136.113.192.221       34.61.201.209      │
        │   reverse proxy         WireGuard 10.99.0.1│
        └───────────────┬────────────────────────────┘
                        │ VPC peering
                        │ exchanges subnet routes only
                        ▼
        ┌────────────────────────────────────────────┐
        │ APPS VPC              10.20.0.0/16         │
        │ subnet                10.20.1.0/24         │
        │                                            │
        │   app 10.20.1.2   no public address        │
        │   python3 + psycopg2 on :8080              │
        │   egress via Cloud NAT                     │
        └───────────────┬────────────────────────────┘
                        │ VPC peering
                        ▼
        ┌────────────────────────────────────────────┐
        │ DBS VPC               10.30.0.0/16         │
        │ subnet                10.30.1.0/24         │
        │                                            │
        │   db 10.30.1.2    no public address        │
        │   PostgreSQL 15 on :5432                   │
        │   egress via Cloud NAT                     │
        └────────────────────────────────────────────┘

        public ─X─> dbs     no peering, no route
```

Addresses are from `05-architecture.log`.

### 3.2 The Terraform tree

| File | What it holds |
|---|---|
| `terraform/versions.tf` | Provider pin (`hashicorp/google ~> 6.0`, resolved to 6.50.0), `required_version >= 1.5`, the provider block, and the state reasoning |
| `terraform/variables.tf` | The CIDR plan with its derivation, machine shape, image, SSH user and key, `admin_source_cidr`, and the label set applied to everything |
| `terraform/network.tf` | Three VPCs, three subnets, four peering resources, two Cloud Routers, two Cloud NAT gateways |
| `terraform/firewall.tf` | Four service accounts and the tier rules, including the SMB rule measured in 5.4 |
| `terraform/compute.tf` | Four instances, the shared metadata block, `can_ip_forward` on the bastion |
| `terraform/outputs.tf` | Addresses, the CIDR plan, network names, and a single `inventory` object that the Ansible inventory generator reads |

`outputs.tf` is the contract between the two tools rather than decoration. The
`inventory` output carries the SSH user, the bastion address, and each host's
private and public address, so `scripts/inventory.sh` is one read rather than
six.

`05-plan.log` records the plan it captured at 32 resources, itemized:

| Class | Count |
|---|---|
| VPC networks | 3 |
| Subnets | 3 |
| Peering resources (two relationships, both directions) | 4 |
| Cloud Routers | 2 |
| Cloud NAT gateways | 2 |
| Firewall rules | 10 |
| Service accounts | 4 |
| Instances | 4 |
| **Total** | **32** |

`firewall.tf` carries one rule beyond that capture: the SMB rule described in
6.13, which admits 445 to the app tier. It is read back from GCP's own listing at
the end of `05-vpn-smb.log`, and 5.4 records the shape it holds in the project.

### 3.3 The Ansible tree

`ansible/site.yml` runs five plays top to bottom, and the ordering is the
orchestration: the database has to be accepting connections before the app tries
to use it, and the app has to be listening before nginx is asked to proxy to it.

| Play | Hosts | Role |
|---|---|---|
| Baseline every host | `all` | `common` |
| Database tier | `dbs_tier` | `db` |
| Application tier | `apps_tier` | `app`, then `samba` |
| Public tier — reverse proxy | `nginx` | `nginx` |
| Public tier — WireGuard VPN | `bastion` | `wireguard` |

**`common`** waits for cloud-init with `cloud-init status --wait` before
touching apt — racing cloud-init produces dpkg lock errors that read as a broken
playbook rather than a timing problem. It then updates the apt cache with a
five-attempt retry, installs `curl`, `netcat-openbsd`, `python3` and
`ca-certificates`, sets the hostname, and writes the tier into `/etc/motd`.

**`db`** installs PostgreSQL, `postgresql-contrib` and `python3-psycopg2`, finds
the configuration directory rather than assuming a version path, sets
`listen_addresses = '*'`, and adds exactly one `pg_hba.conf` line admitting
`10.20.1.0/24` for the application role under `scram-sha-256`. It then flushes
handlers so the restart happens before the database is used, creates the role
and database, creates the `items` table, grants table and sequence privileges,
and seeds one row only if the table is empty.

Listening on all interfaces is deliberate: the network boundary here is VPC
peering plus the firewall rule, not PostgreSQL's listen address. Putting the
boundary in two places invites the two to disagree.

**`app`** installs `python3` and `python3-psycopg2`, creates an `appsvc` system
user with `/usr/sbin/nologin`, deploys the application and a systemd unit, and
waits for port 8080 to accept connections. The database password lives in
`/opt/app/app.env` at mode 0600 rather than in the unit file, because a unit
file is world-readable and `systemctl show` prints `Environment=` values to any
user.

**`samba`** installs Samba on the same host and exports one share,
`task05share`, from `/srv/task05share`. It creates `smbuser` as a system account
with `/usr/sbin/nologin`, generates that account's Samba password on the app host
itself from `/dev/urandom`, writes it to a root-owned file at mode 0600, and adds
it to the Samba passdb. The password is never templated from the control node and
never printed by a task — `no_log: true` covers every task that touches it. The
share configuration is the Task 1 server standard: SMB 3.1.1 as both floor and
ceiling, `smb encrypt = required` rather than negotiated, `server signing =
mandatory`, NetBIOS disabled, and 445 as the only port. The template is deployed
with `validate: "testparm -s %s"`, so a configuration Samba would reject never
reaches `/etc/samba/smb.conf`.

Encryption is required even though the traffic already crosses a WireGuard
tunnel, and the template carries the reason: the tunnel protects the path from
the client to the bastion, while the hop from the bastion across the VPC peering
to the app tier is a separate segment. Requiring SMB3 encryption closes that
segment as well, and it means the share is no weaker if it is ever reached by
another route.

**`nginx`** installs nginx and openssl, generates a self-signed certificate
guarded by `creates:`, deploys the site configuration, removes the default site,
**validates with `nginx -t` before reloading**, and ensures the service is
running. Port 80 carries no listener; the firewall admits 443 only.

**`wireguard`** installs WireGuard, generates the server and client keypairs
(each guarded by `creates:`), enables IPv4 forwarding, deploys `wg0.conf` and
the operator's client configuration at mode 0600, starts `wg-quick@wg0`, and
reads back `wg show wg0`.

### 3.4 The scripts

| Script | What it does |
|---|---|
| `scripts/keygen.sh` | Generates the ed25519 keypair Ansible uses, into `.ssh/`. Never overwrites an existing key |
| `scripts/plan.sh` | `terraform fmt -check -recursive`, `init`, `validate`, then `plan -out=tfplan.binary`. Creates nothing |
| `scripts/inventory.sh` | Reads `terraform output -json inventory` and writes `ansible/inventory/hosts.yml`, including the ProxyJump chains |
| `scripts/ansible-run.sh` | Runs the playbook in the control-node container. `--check-idempotent` runs it twice and asserts the second run changed nothing |
| `scripts/verify.sh` | The architecture verification suite — 17 checks against the live estate |
| `scripts/vpn-smb-check.sh` | Four phases — `outside`, `inside`, `client`, `server` — that measure what the tunnel reaches from both ends of it |
| `scripts/orphan-check.sh` | Post-destroy verification against GCP's own listings, per resource class |

### 3.5 The dynamic inventory and its ProxyJump chains

No address appears anywhere in the Ansible tree. `scripts/inventory.sh`
regenerates `hosts.yml` from Terraform output after every apply, and the
generated file carries a header saying so.

The chains mirror the topology exactly:

| Host | `ansible_host` | Path | Why that path |
|---|---|---|---|
| bastion | `34.61.201.209` | direct | it has a public address |
| nginx | `10.10.1.2` | `ProxyJump=ansible@34.61.201.209` | it has a public address, and the firewall admits only 443 to it, so admin access goes through the bastion |
| app | `10.20.1.2` | `ProxyJump=ansible@34.61.201.209` | no public address; the bastion peers with the apps VPC |
| db | `10.30.1.2` | `ProxyJump=ansible@34.61.201.209,ansible@10.20.1.2` | public and dbs are not peered, so the chain has to land in the apps tier first |

Addresses from `ansible/inventory/hosts.yml` as generated for this run, matching
`05-architecture.log`.

`ansible.cfg` supplies `-F /tmp/ssh_config` on `ssh_args`, which is what puts
`IdentityFile` in front of **every** hop. `-i` applies only to the final hop, so
without the config file the key reaches the destination and each jump fails to
authenticate. `ControlMaster=auto` with `ControlPersist=120s` keeps one
connection open per host, which matters when every private host is reached
through a jump and the endpoints are shared-core.

---

## 4. The steps

**1. Generate the SSH keypair.** `scripts/keygen.sh` writes
`.ssh/task05_ed25519` and prints the public half for `terraform.tfvars`. It is
idempotent — an existing key is left alone.

**2. Fill in `terraform.tfvars`.** `project_id` and `ssh_public_key`; everything
else has a default.

**3. Plan.** `scripts/plan.sh` runs fmt, init, validate and plan in that order.
`05-plan.log` records the result: formatting clean, `Success! The configuration
is valid.`, and `Plan: 32 to add, 0 to change, 0 to destroy.`

**4. Apply.** `terraform apply tfplan.binary` against the saved plan file, so
what is applied is exactly what was reviewed.

**5. Generate the inventory.** `scripts/inventory.sh` reads the Terraform
outputs and writes `ansible/inventory/hosts.yml` with the ProxyJump chains
above.

**6. Configure.** `scripts/ansible-run.sh` builds the ssh config inside the
container, installs the key at mode 0600 — a Windows bind mount cannot hold
0600, so the key is copied to `/tmp/k` first — and runs `site.yml` across all
four hosts.

**7. Prove idempotency.** `scripts/ansible-run.sh --check-idempotent` runs the
whole playbook twice and sums every `changed=` in the second recap.

**8. Verify the architecture.** `scripts/verify.sh` runs 17 checks against the
live estate — the happy path, reachability from outside, the peering
non-transitivity test with its control, GCP's own routing table, the WireGuard
server state, and the public-address inventory.

**9. Measure the tunnel from both ends.** `scripts/vpn-smb-check.sh outside`
runs first, from the Windows host, while no tunnel exists — that phase is the
control for everything after it. The client tunnel is then raised, and `inside`,
`client` and `server` run in turn: the handshake and transfer counters as the
bastion sees them, the mapped drive as Windows sees it, and the file the client
wrote read on the server's own filesystem.

**10. Destroy.** `terraform destroy -auto-approve`.

**11. Confirm nothing remains.** `scripts/orphan-check.sh` queries GCP per
resource class, because a destroy reporting success is a claim about Terraform's
state file rather than about the project.

---

## 5. Measured results

### 5.1 The plan

| Measurement | Value | Evidence |
|---|---|---|
| `terraform fmt -check -recursive` | formatting clean | `05-plan.log` |
| `terraform validate` | `Success! The configuration is valid.` | `05-plan.log` |
| Plan summary | `Plan: 32 to add, 0 to change, 0 to destroy.` | `05-plan.log` |
| `enable-oslogin = "FALSE"` in instance metadata | 4 of 4 instances, lines 346, 441, 541, 636 | `05-plan.log` |
| `can_ip_forward = true` | bastion only, line 420; app, db and nginx are `false` at lines 325, 520 and 615 | `05-plan.log` |
| Machine type | `e2-micro` on all four instances | `05-plan.log` |

### 5.2 The architecture suite

`05-architecture.log`, run at `2026-08-26T15:04:53Z`: **17 checks, 0 failures.**

**The happy path — internet → nginx → app → database.** A `GET` through the
public HTTPS entry point returned data the app had read out of PostgreSQL:

```
GET https://136.113.192.221/api/items
{"served_by": "app", "db_host": "10.30.1.2", "count": 6,
 "items": [{"id": 1, "name": "seeded-by-ansible",
            "created_at": "2026-08-26 14:38:14.407714+00:00"}, …]}
```

The `…` elides five further items; the row count is 6 because each verification
run adds one. A `POST` through the same proxy then inserted a row and a
subsequent read returned it:

```
POST -> {"id": 7, "name": "verify-150454",
         "created_at": "2026-08-26 15:04:55.696963+00:00"}
```

That is the app tier reading **and** writing the database, which is what
requirement 5.1 asks of that tier. nginx's own health endpoint answers
separately, so the proxy tier can be distinguished from the app tier:
`{"status":"ok","service":"nginx","tier":"public"}`.

**Reachability from outside the estate**, summarized from `05-architecture.log`:

| Attempt from the operator's machine | Result |
|---|---|
| `curl http://10.20.1.2:8080` | curl exit 28 (timeout) |
| `curl http://10.30.1.2:5432` | curl exit 28 (timeout) |
| `nc 10.20.1.2 22` | exit 1 |
| `nc 10.30.1.2 22` | exit 1 |

Those are RFC1918 addresses with no public NIC behind them. There is no address
to attack, which is a stronger position than a filtered one.

**The tier boundary, tested three ways with a control**, summarized from
`05-architecture.log`:

| Test | Result | What it establishes |
|---|---|---|
| app → db:5432 | reachable | the permitted path works |
| nginx → db:5432 | no connection | the public tier has no path to the database |
| bastion → db:5432 | no connection | the same holds for the other public-tier host |
| nginx → app:8080 | reachable | control: the two results above are specific to the dbs VPC |

The control is what makes the other three mean something. Without it, two
failures are equally consistent with a broken host, a stuck firewall, or a
service that is not listening.

**GCP's own routing table for the public VPC**, quoted from
`05-architecture.log`:

```
NAME                              DEST_RANGE    NEXT_HOP_PEERING
default-route-769dccd0e2bd569f    0.0.0.0/0
default-route-r-a01b896900b9fcbd  10.10.1.0/24
peering-route-ca82d332a0ab7421    10.20.1.0/24  task05-public-to-apps
```

Three routes: the default route out, the local subnet route, and one peering
route to the apps subnet. There is no entry whose destination covers
`10.30.0.0/16`. That absence is the segmentation, read out of the platform
rather than asserted.

**Public addresses, from GCP**, quoted from `05-architecture.log`:

```
NAME            NETWORK            NETWORK_IP  NAT_IP
task05-app      task05-apps-vpc    10.20.1.2
task05-bastion  task05-public-vpc  10.10.1.3   34.61.201.209
task05-db       task05-dbs-vpc     10.30.1.2
task05-nginx    task05-public-vpc  10.10.1.2   136.113.192.221
```

Two of four instances hold a public address, and both are in the public tier.

### 5.3 The VPN, from the client through to the app tier

A WireGuard client on the Windows host raised the tunnel, and the app tier
answered through it. The same address answered nothing from the same machine
before the tunnel was up.

The server half is deployed by the `wireguard` role, which generates the keypair
on the bastion and writes the operator's client configuration with the routable
ranges and the server's public key. `05-architecture.log` prints that
configuration with the private key redacted:

```
[Interface]
Address    = 10.99.0.2/32
PrivateKey = <REDACTED>

[Peer]
PublicKey  = 772i5mdcakzmrZaqegOhtrKpGmEq8lT3MjkuBKauqTs=
Endpoint   = 34.61.201.209:51820
AllowedIPs = 10.10.0.0/16, 10.20.0.0/16, 10.99.0.0/24
PersistentKeepalive = 25
```

The two captures name different server keys. The role generates the pair on the
bastion under a `creates:` guard, so the key follows the host that made it rather
than the configuration, and the tunnel reading below — taken on 2026-08-27 —
carries the key its own bastion held.

**The control ran first.** `scripts/vpn-smb-check.sh outside`, captured in
`05-vpn-smb.log` at 2026-08-27 19:53:12, asks the Windows host three questions
before any tunnel exists:

```
      WireGuard adapter: none present
      next hop for 10.20.1.2: none
      Test-NetConnection 10.20.1.2:445 -> False
```

"Reachable over the VPN" is only a claim until the same address is shown
unreachable without it, which is why that phase runs before the tunnel is raised
rather than after. `10.20.1.2` is an RFC1918 address, this machine holds no
route to it, and the rule admitting 445 in the apps VPC names the bastion, so a
packet arriving by any other path would not match it either.

**With the tunnel up**, the `inside` phase at 20:22:30 measures both ends. On
Windows the adapter `task05-vpn`, described by the driver as `WireGuard Tunnel`,
reports `Up` and holds `10.99.0.2`. On the bastion, `wg show` gives the server's
own view of that peer — quoted whole, with the client's public endpoint masked
by the capture's redaction path:

```
interface: wg0
  public key: Q6rGOafpGUKdsuBYLczo1vhJfqpYXpoQbrBvzxaX7mA=
  private key: (hidden)
  listening port: 51820

peer: HPZaTEyMnwslcxQ/h0nxFVdLiPpPuNUtKQsISyPcVi8=
  endpoint: <PUBLIC-IP>:52869
  allowed ips: 10.99.0.2/32
  latest handshake: 51 seconds ago
  transfer: 900 B received, 764 B sent
```

A handshake alone would only prove the two ends agree on keys. The transfer
counters are what show payload moving: 900 B in and 764 B out, both nonzero,
read on the server side of the tunnel. Through it, the app tier answers ICMP and
accepts a TCP connection on 445. Those are two consecutive sections of the log,
brought into one block here with the PowerShell table's blank spacer lines
removed:

```
      Address   ResponseTime StatusCode
      -------   ------------ ----------
      10.20.1.2          214          0
      10.20.1.2          211          0
      10.20.1.2          212          0
      10.20.1.2          271          0

      Test-NetConnection 10.20.1.2:445 -> True
```

The client half of the tunnel is installed as a Windows service named
`WireGuardTunnel$task05-vpn`, with StartType `Automatic`. `docs/evidence/01-reboot.log`
reads that service back `Running` after a reboot; the reboot itself belongs to
Task 1 and is written up there.

| Measurement | Value | Evidence |
|---|---|---|
| WireGuard adapter, before the tunnel | none present | `05-vpn-smb.log`, outside phase |
| Next hop for `10.20.1.2`, before the tunnel | none | `05-vpn-smb.log`, outside phase |
| `Test-NetConnection 10.20.1.2:445`, before the tunnel | False | `05-vpn-smb.log`, outside phase |
| Client adapter, tunnel up | `task05-vpn`, `WireGuard Tunnel`, `Up` | `05-vpn-smb.log`, inside phase |
| Tunnel address held by the client | `10.99.0.2` | `05-vpn-smb.log`, inside phase |
| Latest handshake, read on the bastion | 51 seconds ago, epoch 1787851304 | `05-vpn-smb.log`, inside phase |
| Transfer counters for the peer, on the bastion | 900 B received, 764 B sent | `05-vpn-smb.log`, inside phase |
| ICMP to `10.20.1.2` through the tunnel | 214, 211, 212, 271 ms | `05-vpn-smb.log`, inside phase |
| `Test-NetConnection 10.20.1.2:445`, through the tunnel | True | `05-vpn-smb.log`, inside phase |
| Kernel forwarding on the bastion | `net.ipv4.ip_forward = 1` | `05-architecture.log` |
| Platform forwarding | `can_ip_forward = true` on the bastion | `05-plan.log` line 420 |
| Path opened to the tunnel | UDP 51820 only, on `task05-public-allow-bastion` | `05-plan.log` |
| Response to an unauthenticated UDP probe | nothing returned | `05-architecture.log` |

The 211-271 ms figures are the round trip from the Windows client out over the
internet to the bastion, through the tunnel, and across the VPC peering into the
apps VPC. They measure the whole path from where an operator sits, not the
peering hop, and not anything inside the region.

### 5.4 The app-tier share, reached through the tunnel

Samba on the app tier serves one share, `task05share`, and a Windows client
mapped it over the tunnel. The role that installs and configures it is described
in 3.3; what follows is what the two ends of the connection measured.

The client mapped the share as `Z:` and wrote a file to it, read back in the
`client` phase at 20:24:39. The interesting read is the one the server did on its
own filesystem seventeen seconds later, which never went through the client's
mount. `05-vpn-smb.log`, server phase at 20:24:56:

```
      -rw-rw-r-- 1 smbuser smbuser 68 Aug 27 17:23 from-windows.txt
      ---
      == /srv/task05share/from-windows.txt
      written from Windows over the WireGuard tunnel at 20260827T172338Z
```

The client phase of the same log lists that file at 68 bytes with the same
contents. Same byte count, same string, two filesystems, one write.

| Measurement | Value | Evidence |
|---|---|---|
| Mapping | `Z:` → `\\10.20.1.2\task05share`, Status OK, 1 connection | `05-vpn-smb.log`, client phase |
| Persistence of the mapping | `HKCU:\Network\Z` → `\\10.20.1.2\task05share` | `05-vpn-smb.log`, client phase |
| File written from Windows | `from-windows.txt`, 68 bytes | `05-vpn-smb.log`, client phase |
| The same file read on the server | 68 bytes, owner `smbuser`, contents identical | `05-vpn-smb.log`, server phase |
| Dialect and encryption, client side | `3.1.1`, `Encrypted True` | `05-vpn-smb.log`, client phase |
| Dialect, encryption and signing, server side | `SMB3_11`, `AES-128-GCM`, `AES-128-GMAC` | `05-vpn-smb.log`, server phase |
| Protocol floor in `smb.conf` | `server min/max protocol = SMB3_11`, `client min protocol = SMB3_11` | `05-vpn-smb.log`, server phase |
| Encryption and signing settings | `smb encrypt = required`, `server signing = mandatory` | `05-vpn-smb.log`, server phase |
| Ports | `smb ports = 445` | `05-vpn-smb.log`, server phase |
| Samba account | `smbuser:994:` in `pdbedit -L` | `05-vpn-smb.log`, server phase |
| Credentials file | `-rw------- 1 root root 60 /etc/samba/task05-credentials` | `05-vpn-smb.log`, server phase |
| Share directory | `drwxrwxr-x 2 smbuser smbuser /srv/task05share` | `05-vpn-smb.log`, server phase |
| Firewall rule admitting 445 | `task05-apps-allow-smb-from-vpn`, `task05-apps-vpc`, source `10.10.1.3/32`, port 445, target the `task05-app` service account | `05-vpn-smb.log` |

The two dialect readings come from different places and that is deliberate.
`Get-SmbConnection` needs elevation, so the client-side line — `3.1.1`,
`Encrypted True` — is output captured from an elevated PowerShell and read back
by the check. The server-side line comes from `smbstatus` on the app tier over
SSH and owes nothing to the client's report. Both name SMB 3.1.1 with encryption
in force, and `smbstatus` adds the ciphers the client view does not carry:
`AES-128-GCM` for encryption, `AES-128-GMAC` for signing.

### 5.5 Ansible idempotency

`05-ansible-idempotency.log` runs the playbook twice in one invocation. The
second run's recap:

```
app                        : ok=13   changed=0    unreachable=0    failed=0
bastion                    : ok=20   changed=0    unreachable=0    failed=0
db                         : ok=17   changed=0    unreachable=0    failed=0
nginx                      : ok=15   changed=0    unreachable=0    failed=0

    total changed across all hosts on the second run: 0
[PASS] idempotent: the second run changed nothing
```

Sixty-five task results across four hosts, every one of them converged on the
first run and reporting no change on the second.

Three places needed care to reach that number:

| Task | What would otherwise change every run | Guard |
|---|---|---|
| TLS certificate | a fresh self-signed certificate each run | `creates:` on the openssl command |
| WireGuard keypairs | new keys, invalidating the client configuration | `creates:` on each `wg genkey` |
| Database password | a new random password each run | derived deterministically from a seed in `roles/db/defaults/main.yml` |

The password derivation is worth naming precisely. It is
`'task05-' + (inventory_hostname + db_name) | hash('sha256') | truncate(20, true, '')`,
which is stable across runs for a given host and database. A real deployment
sources that value from a secret manager; the deterministic derivation is what
makes the idempotency claim checkable here.

The Samba password task asks the same question in a different form, and the
answer for it is not a `creates:` guard. 6.14 has that one.

### 5.6 Teardown

`terraform destroy` reporting success is a statement about the state file.
`scripts/orphan-check.sh` asks GCP instead, per resource class, and splits the
classes by whether they outlive the instance they were attached to. The check
was re-run after the tunnel and share work, at 2026-08-27 21:37:39 +0300, and
`05-destroy-orphan-check.log` holds that run:

```
Classes that survive instance deletion:
  [CLEAN]   static addresses       none
  [CLEAN]   persistent disks       none
  [CLEAN]   Cloud NAT              none
  [CLEAN]   snapshots              none
  [CLEAN]   custom images          none

Classes tied to the stack, which should also be gone:
  [CLEAN]   instances              none
  [CLEAN]   task05 networks        none
  [CLEAN]   task05 firewalls       none
  [CLEAN]   task05 svc accts       none

RESULT: PROJECT CLEAN - nothing left behind, nothing left running
```

The split is the useful part. A reserved-but-unattached static address, an
unattached persistent disk, a Cloud NAT gateway and a snapshot all keep existing
with no instance in sight, so those five classes are queried directly rather
than inferred. The second group would still mean the destroy was incomplete.
Nothing is left running, verified against GCP's own listings.

---

## 6. What the measurements revealed

### 6.1 Non-transitivity is a stronger boundary than a rule, and it propagates

The routing table in 5.2 has three entries, and the interesting one is the entry
that is not there. A firewall rule sits in front of a live route and decides
whether to pass a packet; a missing route means the packet is never deliverable
to begin with. The difference matters under exactly the conditions where
security controls usually fail — someone edits a rule, someone applies a rule to
the wrong target, someone adds a higher-priority rule that shadows another.

What the build showed that the design did not anticipate is how far that
property propagates. Choosing routing as the enforcement layer changed:

- the WireGuard client configuration, which advertises `10.10.0.0/16`,
  `10.20.0.0/16` and `10.99.0.0/24` and stops there;
- the Ansible inventory, where the `db` host needs a two-hop `ProxyJump`
  because the bastion has no route to it;
- the firewall rule set, where the dbs VPC's SSH rule admits `10.20.1.0/24`
  rather than the bastion's subnet;
- the operator's own habits, since reaching the database means going through
  the app tier every time.

A boundary that is only a rule is invisible in the tooling. This one is visible
in four places, and every one of them is a place where a mistake would be
noticed.

### 6.2 Service accounts and network tags do not traverse VPC peering

This is the finding with the sharpest edge, because GCP does not signal it.
`terraform apply` succeeds. `gcloud compute firewall-rules list` shows the rule.
The rule simply never matches, and the symptom presents as a firewall problem
when the rule under suspicion was never in play at all.

Both `source_tags` and `source_service_accounts` are scoped to instances in the
same VPC network as the rule. Every tier-to-tier hop here crosses a peering, so
four of the five inter-host rules express their source as a CIDR — the mechanism
that does work across a peering — while keeping `target_service_accounts` on the
far end. The rule descriptions carry the reason, so the next person to read them
does not have to rediscover it:

```
description = "nginx to the app on 8080. Cross-VPC, so the source must be a
               CIDR - tags and service accounts do not traverse peering."
```

The general shape: an identity-based control that silently degrades to no
control is more dangerous than one that fails loudly, and the way to find them
is to test the rule rather than to read it.

### 6.3 An ed25519 private key matches none of the usual ignore patterns

`scripts/keygen.sh` generated `.ssh/task05_ed25519`, and the check immediately
afterward reported the private key was not ignored. The repository's rules
covered `*.pem`, `*.key` and `id_rsa`. An OpenSSH private key generated with
`-f task05_ed25519` has **no extension at all** and is not named `id_rsa`, so
all three patterns missed it, and the file sat one `git add -A` away from being
committed.

Fixed with `**/.ssh/` plus a `!**/.ssh/*.pub` exception so the public half stays
visible, and `scripts/audit.sh` now checks for tracked SSH private keys by
content signature rather than by filename.

The lesson generalizes past this repository: extension-based secret rules catch
secrets that happen to have extensions. Signature-based scanning catches the
ones that do not.

### 6.4 A tool that returns nothing on failure is worse than one that errors

`MSYS_NO_PATHCONV=1` is exported across this repository so Git Bash stops
rewriting container-side paths for Docker. `gcloud` is a batch wrapper that
resolves its own library path, and with that variable set it fails to locate
`gcloud.py` — returning **empty output rather than an error, and exit status
zero**.

Inside `verify.sh` that turned "list the routes in the public VPC" into "no
routes found", which the check read as a failure and reported confidently. Two
checks failed that way against an estate that was working correctly.

Every gcloud call now runs through `env -u MSYS_NO_PATHCONV`. `05-vpn-smb.log`
holds both readings of one command, side by side. The firewall section of the
server phase printed nothing, because that call sends stderr to `/dev/null`. Run
on its own, the same describe printed `project:` with no value and then the
underlying cause, exiting 2:

```
C:\Users\abual\AppData\Local\Microsoft\WindowsApps\python3.11.exe: can't open file 'C:\\c\\Users\\abual\\AppData\\Local\\Google\\Cloud SDK\\google-cloud-sdk\\lib\\gcloud.py': [Errno 2] No such file or directory
```

The `C:\c\Users\...` prefix is the rewrite itself, visible in the error. Wrapped
in `env -u MSYS_NO_PATHCONV`, the same command returned the project name and the
rule.

The generalizable part is the diagnosis: when a check fails, the first question
is whether the command that produced its input actually ran. Empty output and
negative output are indistinguishable to a `grep`.

### 6.5 A red check that means nothing is the same bug as a green one

The idempotency verdict originally summed the `changed=` counts with `bc`, which
is not installed in the control-node image. The sum came back as `?`, the check
compared `?` against `0`, and it reported that the playbook was not idempotent —
directly beneath a recap showing `changed=0` on all four hosts.

Replaced with `awk`, which is in the image:

```
CHANGED="$(echo "$OUT" | grep -oE 'changed=[0-9]+' | grep -oE '[0-9]+' \
           | awk '{t+=$1} END {print t+0}')"
```

A check whose verdict does not depend on the thing it claims to measure is
broken the same way whichever direction it lands. The `t+0` matters too: it
forces a numeric zero rather than an empty string when the pattern matches
nothing, so an empty input produces `0` and not another `?`.

### 6.6 `grep -q '1'` matched inside an error message

The IP-forwarding check ran `sysctl -n net.ipv4.ip_forward` without root.
`sysctl` is not on the default PATH for an unprivileged shell, so the output was
`sysctl: not found` — a string containing the character `1`. `grep -q '1'`
matched it, and the check reported that IP forwarding was enabled on the
strength of a command that never ran.

Replaced with an exact comparison against the file itself, read with `become`:

```
[ "$FWD" = "1" ]     # FWD from /proc/sys/net/ipv4/ip_forward
```

Substring matching on a numeric value is a check that passes on the error text
of the command it was meant to run. The value in `05-architecture.log` —
`net.ipv4.ip_forward = 1` — is the reading after that change.

### 6.7 Ansible ignores a configuration file in a world-writable directory

A Windows bind mount always presents as mode 0777 inside a Linux container.
Ansible refuses to auto-discover an `ansible.cfg` in a world-writable directory
— sensibly, since anyone who can write the directory could redirect the
inventory — so the configuration was skipped, the inventory came up empty, and
the run reported that only implicit localhost was available. The warning does
not obviously connect to the cause.

Fixed by setting `ANSIBLE_CONFIG` explicitly on the container invocation, which
bypasses the discovery rule entirely:

```
-e ANSIBLE_CONFIG=/work/05-terraform-ansible/ansible/ansible.cfg
```

The same bind-mount property is why the SSH key is copied to `/tmp/k` at mode
600 before use — ssh refuses a key file that the mount presents as 0777.

### 6.8 Nested `ProxyCommand` quoting fails as a timeout

The two-hop chain to the database, written as a `ProxyCommand` containing
another `ProxyCommand`, needs quotes inside quotes inside YAML. Written that way
it produced `timed out during banner exchange`, which reads as a firewall or
routing problem — precisely the failure mode this topology makes plausible — and
was in fact a mangled command line.

`ProxyJump` takes a comma-separated chain natively:

```
-o ProxyJump=ansible@34.61.201.209,ansible@10.20.1.2
```

No nesting, no quoting, and the chain reads in the same order the packet
travels. The paired requirement is `-F /tmp/ssh_config` in `ansible.cfg`, since
`-i` supplies the identity only to the final hop.

### 6.9 `nginx -t` caught a version mismatch before it could take effect

`http2 on;` as a standalone directive is nginx 1.25.1 and later. Debian 12 ships
1.22, where HTTP/2 is a parameter on the `listen` line. The playbook validates
the configuration before reloading, so the mismatch surfaced as a failed Ansible
task with `unknown directive "http2"` rather than as a proxy that had already
dropped its configuration and stopped serving.

The template uses `listen 443 ssl http2;` and carries a comment naming which
nginx versions take which form. The ordering — validate, then reload — is what
turned an outage into a task failure.

### 6.10 The OS Login argument is made from the plan, not from the project

The brief for this work warned that OS Login is commonly enabled at the project
level and conflicts with metadata SSH keys. That conflict is real: with OS Login
on, the `ssh-keys` metadata this build depends on is ignored and every playbook
fails to authenticate.

Rather than read the project default and depend on it, the configuration
overrides it per instance, and the plan output is the proof. `05-plan.log` lines
346, 441, 541 and 636 each show `+ "enable-oslogin" = "FALSE"` in the metadata
block of one of the four VMs, beside the `ssh-keys` entry. An instance-level
value wins over the project setting, so the metadata-key path holds whatever the
project inherits and whatever it is changed to later.

That is a claim about the instances, and it is the claim the evidence supports.
It says nothing about the project's own setting, and it does not need to — the
point of setting the value explicitly is that the project's setting stops
mattering.

### 6.11 Both halves of IP forwarding, in two different places

`can_ip_forward = true` is a GCP instance property, checked by the platform's
virtual network. `net.ipv4.ip_forward = 1` is a kernel sysctl, checked by Linux.
A WireGuard relay needs both, and they live in different tools —
`terraform/compute.tf` and `ansible/roles/wireguard/tasks/main.yml`
respectively.

The symptom of either one missing is identical and points nowhere useful: the
interface comes up, the handshake completes, and packets stop at the bastion.
Both are verified separately — the platform half from `05-plan.log` line 420, the
kernel half from `05-architecture.log`. With both in place the packets go
through: `05-vpn-smb.log` records the handshake, 900 B and 764 B across the peer
in the two directions, and the app tier one hop past the bastion answering ICMP
and TCP 445.

### 6.12 Teardown is checked per class, because the classes behave differently

Five resource classes in GCP outlive the instance they served: reserved static
addresses, persistent disks, Cloud NAT gateways, snapshots and custom images.
Four more are tied to this stack and would indicate an incomplete destroy if
they lingered: instances, networks, firewall rules and service accounts.

`scripts/orphan-check.sh` queries all nine separately and labels the two groups
differently in its output, because they mean different things. The result in
`05-destroy-orphan-check.log` is `[CLEAN]` on every one of the nine, with the
verdict `PROJECT CLEAN - nothing left behind, nothing left running`.

Choosing ephemeral external addresses over reserved ones in `compute.tf` was a
decision made against this check: a reserved address is the easiest of the five
to leave behind, because releasing it is a separate action from deleting the
instance it was attached to.

### 6.13 A masquerading tunnel decides which address the firewall rule can name

The rule admitting 445 to the app tier names `10.10.1.3/32` — the bastion's
private address — and not the tunnel range. That is the rule's measured shape in
`05-vpn-smb.log`, and it is the only shape that would match anything.

WireGuard on the bastion masquerades tunnel traffic onto the bastion's own
interface. It has to: the apps VPC holds no route back to `10.99.0.0/24`, so an
unmasqueraded reply addressed to `10.99.0.2` would have nowhere to go. By the
time a packet from the client reaches the app tier, its source address is the
bastion's. A rule sourced on `10.99.0.0/24` would be accepted by GCP, would list
cleanly, and would match no packet ever sent.

`smbstatus -b` on the app tier settles the mechanism from the server's side. The
server phase of `05-vpn-smb.log` carries the header and one session row; the
encryption and signing columns to the right of it are cut here and reported in
5.4:

```
PID     Username     Group        Machine                                   Protocol Version
5119    smbuser      smbuser      10.10.1.3 (ipv4:10.10.1.3:60633)          SMB3_11
```

The client that wrote the file holds `10.99.0.2`. The session the server sees
comes from `10.10.1.3`. The address in the rule is the address the server
observes, and the way to learn it is the server's own session table rather than
the client's idea of who it is.

What makes the share reachable through the tunnel and by no other means is the
absence of alternatives rather than this rule alone. The app tier carries no
public address — `05-architecture.log` lists `task05-app` with a `NETWORK_IP`
and no `NAT_IP` — and from outside the tunnel the Windows host found no next hop
at all for `10.20.1.2`. There is no second path to filter.

### 6.14 A guard has to test the condition, not a file something else creates

Setting the Samba password is a run-once task, and a `creates:` guard on
`/var/lib/samba/private/passdb.tdb` reads like the right way to make it one. The
Samba package creates that file at install time. The guard is therefore satisfied
before the task has ever run, the task skips on the very first pass, and the
account is left with a Unix identity and no Samba password — a user that exists
and cannot log in to the share. A skipped task reports `ok`, so nothing in the
recap points at it.

The role guards on the condition itself. `pdbedit -L` is read into a variable
with `changed_when: false`, and the password task runs only when the account is
absent from that list:

```yaml
when: samba_user not in samba_passdb.stdout
```

`roles/samba/tasks/main.yml` carries the reason beside it, so the next person to
tighten that task does not reintroduce the file guard:

```
# Idempotency is checked against the condition itself - is this account in the
# Samba passdb - rather than against a file. passdb.tdb is created by the
# package at install time, so a `creates:` guard on it skips this task on the
# very first run and leaves the account without a Samba password.
```

The server phase of `05-vpn-smb.log` shows the account where it needs to be:
`pdbedit -L` returns `smbuser:994:`, and the session in `smbstatus` is
authenticated as `smbuser`. The general shape is worth carrying past Ansible: a
`creates:` guard asserts that the path exists if and only if the work was done.
Any installer, package or sibling task that can produce the same path breaks that
equivalence in the direction that stays quiet.

---

## 7. How to run it yourself

Requirements on the host: Terraform 1.5 or later, the Google Cloud SDK
authenticated against a project, Docker for the Ansible control node, and a
POSIX shell. Step 10 also needs a WireGuard client on the operator's machine. On
Windows, run the shell scripts from Git Bash.

```bash
cd 05-terraform-ansible

# 1. SSH keypair for Ansible. Written to .ssh/, which is gitignored.
./scripts/keygen.sh

# 2. Fill in the two required variables.
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
#    project_id     = "<your project>"
#    ssh_public_key = "<the key keygen.sh printed>"

# 3. fmt, validate, plan. Creates nothing; writes tfplan.binary.
./scripts/plan.sh

# 4. Apply the reviewed plan.
cd terraform && terraform apply tfplan.binary && cd ..

# 5. Build the Ansible control node image (once).
docker build -t task05-ansible:1.0.0 ansible/

# 6. Generate the inventory from Terraform output.
./scripts/inventory.sh

# 7. Configure all four hosts.
./scripts/ansible-run.sh

# 8. Run the playbook twice and assert the second run changes nothing.
./scripts/ansible-run.sh --check-idempotent

# 9. Prove the architecture: 17 checks against the live estate.
./scripts/verify.sh

# 10. The tunnel and the share it reaches. Run `outside` before raising the
#     client tunnel: that phase is the control for the three that follow.
./scripts/vpn-smb-check.sh outside
./scripts/vpn-smb-check.sh inside
./scripts/vpn-smb-check.sh client
./scripts/vpn-smb-check.sh server

# 11. Tear down.
cd terraform && terraform destroy -auto-approve && cd ..

# 12. Confirm nothing remains, per resource class, against GCP's listings.
./scripts/orphan-check.sh
```

Notes for a clean run:

- **Set `admin_source_cidr`.** It defaults to `0.0.0.0/0` because the operator's
  address here is dynamic and the estate lives for one session. With a fixed
  range, that variable takes that range and the bastion accepts SSH and
  WireGuard from nowhere else. The bastion and nginx are the only hosts that
  accept anything from outside at all.
- **Run gcloud through `env -u MSYS_NO_PATHCONV`** if that variable is exported
  in your shell. See 6.4.
- **`terraform apply` and `scripts/inventory.sh` are a pair.** Re-applying with
  a different zone or CIDR changes the addresses, and the inventory is
  regenerated rather than edited.
- **The verification suite is safe to re-run.** Each run inserts one row through
  the proxy and reads it back, so the `count` in the happy-path output grows by
  one each time.
- **The client configuration comes off the bastion.** The `wireguard` role writes
  it there at mode 0600; read it over SSH and import it into the WireGuard client
  on the operator's machine. The Windows client names the adapter after the file
  it imported, which is why the reading in 5.3 shows `task05-vpn`.
- **The share password stays on the app host.** It is generated there and written
  to `/etc/samba/task05-credentials`, root-owned at mode 0600. Read it over SSH
  when mapping the drive; nothing in the repository carries it.
- **`.tfstate` and `.ssh/` are gitignored**, and `scripts/audit.sh` at the
  repository root fails the build if either is ever tracked.

### Evidence produced by these steps

| Log | Produced by | What it records |
|---|---|---|
| `docs/evidence/05-plan.log` | `scripts/plan.sh` | fmt, validate, and the full 32-resource plan |
| `docs/evidence/05-ansible-idempotency.log` | `scripts/ansible-run.sh --check-idempotent` | both runs in full, and the summed verdict |
| `docs/evidence/05-architecture.log` | `scripts/verify.sh` | 17 checks against the live estate |
| `docs/evidence/05-vpn-smb.log` | `scripts/vpn-smb-check.sh`, four phases | the app tier before the tunnel, the tunnel measured at both ends, the mapped drive from Windows, the share read on the server, and the firewall rule read back from GCP |
| `docs/evidence/05-destroy-orphan-check.log` | `scripts/orphan-check.sh` | nine resource classes queried against GCP after destroy |
