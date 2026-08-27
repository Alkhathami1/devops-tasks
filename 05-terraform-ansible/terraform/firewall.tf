# ---------------------------------------------------------------------------
# FIREWALL — deny by default, least privilege.
#
# GCP already denies all ingress implicitly at priority 65535, so there is no
# "deny all" rule to write; every rule below is an explicit hole. An explicit
# deny at priority 65534 is added anyway, purely so the intent is visible in
# `gcloud compute firewall-rules list` rather than being an unstated default
# someone has to know about.
#
# TARGETS use service accounts throughout. Service accounts beat network tags
# for targeting because a tag can be added to any instance by anyone with
# compute.instances.setTags, whereas changing an instance's service account
# requires stopping it and holds an IAM permission most people do not have.
#
# SOURCES are where GCP forces a compromise, and it is worth stating plainly
# rather than quietly working around:
#
#   Both source_tags and source_service_accounts apply ONLY to traffic from
#   instances in the SAME VPC network. They do not work across VPC peering.
#
# Every tier-to-tier hop in this design crosses a peering, so those hops cannot
# use tags or service accounts as sources - GCP will accept the rule and it
# will simply never match. The only mechanism that works across a peering is
# source_ranges.
#
# So the rule is: service accounts for targets always, service accounts for
# sources within a VPC, and a tightly-scoped /24 source_range for cross-VPC
# hops. The ranges used are single subnets, not supernets and never 0.0.0.0/0,
# and each is paired with a target service account so both ends are pinned.
# ---------------------------------------------------------------------------

# --- service accounts, one per tier ----------------------------------------

resource "google_service_account" "bastion" {
  account_id   = "task05-bastion"
  display_name = "Task05 bastion / WireGuard"
}

resource "google_service_account" "nginx" {
  account_id   = "task05-nginx"
  display_name = "Task05 nginx reverse proxy"
}

resource "google_service_account" "app" {
  account_id   = "task05-app"
  display_name = "Task05 application server"
}

resource "google_service_account" "db" {
  account_id   = "task05-db"
  display_name = "Task05 database server"
}

# ---------------------------------------------------------------------------
# PUBLIC TIER
# ---------------------------------------------------------------------------

# Internet -> nginx on 443 only. Not 80: there is no plaintext listener, and
# opening 80 "for the redirect" is how plaintext ends up serving real traffic.
resource "google_compute_firewall" "public_allow_https" {
  name        = "task05-public-allow-https"
  network     = google_compute_network.public.name
  description = "Internet to nginx on 443 only."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  source_ranges           = ["0.0.0.0/0"]
  target_service_accounts = [google_service_account.nginx.email]
}

# Internet -> bastion, SSH and WireGuard only.
#
# WireGuard is UDP/51820. It answers nothing to an unauthenticated packet: a
# port scan sees no response at all, because the handshake is dropped silently
# unless it is signed by a known peer key.
resource "google_compute_firewall" "public_allow_bastion" {
  name        = "task05-public-allow-bastion"
  network     = google_compute_network.public.name
  description = "Admin access to the bastion: SSH and the WireGuard tunnel."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  allow {
    protocol = "udp"
    ports    = ["51820"]
  }

  source_ranges           = [var.admin_source_cidr]
  target_service_accounts = [google_service_account.bastion.email]
}

# Bastion -> nginx on SSH, for Ansible. Same VPC, so a service account source
# works here and is used in preference to a CIDR.
resource "google_compute_firewall" "public_allow_bastion_ssh" {
  name        = "task05-public-allow-bastion-to-nginx"
  network     = google_compute_network.public.name
  description = "Bastion to nginx over SSH (Ansible ProxyJump). Same VPC, so a service account source works."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_service_accounts = [google_service_account.bastion.email]
  target_service_accounts = [google_service_account.nginx.email]
}

# VPN clients -> the public tier. The tunnel range is not a VPC range, so this
# has to be a source_range regardless.
resource "google_compute_firewall" "public_allow_vpn" {
  name        = "task05-public-allow-vpn"
  network     = google_compute_network.public.name
  description = "WireGuard tunnel clients into the public tier."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = [var.vpn_cidr]
}

# Health checks and IAP would come from Google's published ranges. Not opened:
# nothing here uses a load balancer, and an unused hole is still a hole.

# ---------------------------------------------------------------------------
# APPS TIER
# ---------------------------------------------------------------------------

# nginx -> app on 8080. CROSS-VPC (public -> apps), so source_service_accounts
# would silently never match and source_ranges is the only option. Scoped to
# the single public /24, and pinned at the far end to the app service account.
resource "google_compute_firewall" "apps_allow_nginx" {
  name        = "task05-apps-allow-nginx"
  network     = google_compute_network.apps.name
  description = "nginx to the app on 8080. Cross-VPC, so the source must be a CIDR - tags and service accounts do not traverse peering."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_ranges           = [var.public_subnet_cidr]
  target_service_accounts = [google_service_account.app.email]
}

# Bastion -> app over SSH, for Ansible. Also cross-VPC.
resource "google_compute_firewall" "apps_allow_bastion_ssh" {
  name        = "task05-apps-allow-bastion-ssh"
  network     = google_compute_network.apps.name
  description = "Bastion to app over SSH for Ansible ProxyJump. Cross-VPC, so a CIDR source."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges           = [var.public_subnet_cidr, var.vpn_cidr]
  target_service_accounts = [google_service_account.app.email]
}

# SMB to the app tier, reachable only through the tunnel.
#
# The source is the bastion's own address, and that is a measured choice rather
# than a loose one. The WireGuard server masquerades tunnel traffic onto the
# bastion's interface, because the apps VPC has no route back to 10.99.0.0/24
# and an unmasqueraded reply would have nowhere to go. So by the time a packet
# from the tunnel reaches the app tier, its source is the bastion, and a rule
# written against the tunnel subnet would match nothing at all.
#
# What makes this "over the VPN and no other way" is the absence of alternatives
# rather than this rule alone: the app tier holds no public address, the apps
# VPC is peered only to public and dbs, and the bastion forwards on wg0 only.
# An operator outside the tunnel has no route to 10.20.1.0/24 to try.
resource "google_compute_firewall" "apps_allow_smb_from_vpn" {
  name        = "task05-apps-allow-smb-from-vpn"
  network     = google_compute_network.apps.name
  description = "SMB to the app tier, reachable only through the tunnel."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["445"]
  }

  source_ranges           = ["${google_compute_instance.bastion.network_interface[0].network_ip}/32"]
  target_service_accounts = [google_service_account.app.email]
}


# ---------------------------------------------------------------------------
# DBS TIER — the tightest rule in the design.
# ---------------------------------------------------------------------------

# app -> db on 5432 and nothing else, from the apps subnet and nowhere else.
#
# Note what is ABSENT: any rule admitting the public subnet. Even if one were
# added by mistake, it could not take effect, because public and dbs are not
# peered and no route exists between them. Defence in depth, where the outer
# layer is routing rather than another rule at the same layer.
resource "google_compute_firewall" "dbs_allow_app" {
  name        = "task05-dbs-allow-app-postgres"
  network     = google_compute_network.dbs.name
  description = "Application tier to PostgreSQL on 5432. The only ingress the database accepts besides admin SSH."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }

  source_ranges           = [var.apps_subnet_cidr]
  target_service_accounts = [google_service_account.db.email]
}

# Admin SSH to the db. Reachable from the apps subnet only - the bastion cannot
# reach it directly, because public and dbs are not peered. Administration
# therefore chains bastion -> app -> db, which is the intended consequence of
# the topology rather than an oversight. See the report.
resource "google_compute_firewall" "dbs_allow_admin_ssh" {
  name        = "task05-dbs-allow-admin-ssh"
  network     = google_compute_network.dbs.name
  description = "SSH to the database from the apps tier only. The public tier has no route here at all."
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges           = [var.apps_subnet_cidr]
  target_service_accounts = [google_service_account.db.email]
}

# ---------------------------------------------------------------------------
# EXPLICIT DENIES
#
# Redundant with GCP's implied deny at 65535, and written anyway so the posture
# is legible to anyone reading `gcloud compute firewall-rules list` without
# having to know the implied rules exist.
# ---------------------------------------------------------------------------

resource "google_compute_firewall" "apps_deny_all" {
  name        = "task05-apps-deny-all-ingress"
  network     = google_compute_network.apps.name
  description = "Explicit catch-all deny. Redundant with the implied deny, written for legibility."
  direction   = "INGRESS"
  priority    = 65534

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "dbs_deny_all" {
  name        = "task05-dbs-deny-all-ingress"
  network     = google_compute_network.dbs.name
  description = "Explicit catch-all deny on the database tier, with logging so blocked attempts are visible."
  direction   = "INGRESS"
  priority    = 65534

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
