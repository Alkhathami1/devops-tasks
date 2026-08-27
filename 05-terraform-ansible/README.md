# Task 05 — 3-tier GCP infrastructure with Terraform and Ansible

> Three VPCs applied to real GCP infrastructure and configured by Ansible, with
> a row written through nginx to the app to the database and read back. 32
> resources, 17 of 17 architecture checks, Ansible idempotent on the second run,
> and the project verified clean per resource class after destroy. Full detail in
> `WALKTHROUGH.md`; evidence in `../docs/evidence/05-*.log`.

## Topology

```
internet ──443──> nginx ──peering──> app ──peering──> db
             ──22/51820──> bastion (WireGuard)
   public 10.10.0.0/16   apps 10.20.0.0/16   dbs 10.30.0.0/16

   public ─X─> dbs    no peering, no route, not possible
```

Three separate VPCs, not three subnets. Peering is **non-transitive**, so the
tier boundary is enforced by routing rather than by a firewall rule — a rule can
be edited or misapplied; a missing route cannot.

## Run it

```bash
./scripts/keygen.sh          # SSH keypair (gitignored)
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # then edit
./scripts/plan.sh            # fmt + validate + plan, creates nothing

cd terraform && terraform apply tfplan.binary && cd ..

./scripts/inventory.sh                      # dynamic inventory from tf output
./scripts/ansible-run.sh                    # configure all four hosts
./scripts/ansible-run.sh --check-idempotent # run twice, assert changed=0
./scripts/verify.sh                         # prove the architecture

cd terraform && terraform destroy -auto-approve && cd ..
./scripts/orphan-check.sh    # confirm nothing is left running
```

Ansible runs from a container (`ansible/Dockerfile`) because Windows cannot be
an Ansible control node.

## Teardown

`terraform destroy` reporting success is not the same as the project being
empty: it knows only what is in its own state. `scripts/orphan-check.sh` queries
GCP directly, per resource class, covering the classes that outlive an instance —
reserved addresses, disks, NAT gateways, snapshots and images — and reports each
one clean or present.

## Gotchas handled

- **Peering is non-transitive** — public cannot reach dbs, by design. The DB is
  administered by chaining `bastion → app → db`.
- **Service accounts and tags do not traverse peering** as firewall *sources*.
  GCP accepts such a rule and it silently never matches; cross-VPC hops must use
  a CIDR. Targets still use service accounts.
- **Cloud NAT needs a Cloud Router**, and without egress the Ansible bootstrap
  hangs with no obvious cause.
- **`can_ip_forward` AND `net.ipv4.ip_forward`** are both required for
  WireGuard. Missing either: the tunnel establishes and nothing routes.
- **`MSYS_NO_PATHCONV=1` breaks gcloud** — it returns empty output rather than
  an error, which reads as "no resources found".
- **An ed25519 private key has no extension**, so `*.pem`/`*.key`/`id_rsa` miss
  it entirely. `**/.ssh/` is now gitignored and `../scripts/audit.sh` checks.
