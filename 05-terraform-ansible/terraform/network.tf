# ---------------------------------------------------------------------------
# THREE SEPARATE VPCs, not three subnets in one VPC.
#
# The assignment says "networks", and the distinction is not pedantry. Three
# subnets in one VPC are mutually routable by default, and the only thing
# separating the tiers would be firewall rules - one bad rule, or one rule
# applied to the wrong tag, and the database is reachable from the internet
# tier. Separate VPCs make the tiers unroutable to each other unless a peering
# explicitly exists, so the boundary survives a firewall mistake.
#
# The cost is real and is stated in the report: peering is non-transitive, so
# the topology below deliberately cannot route public -> dbs at all.
# ---------------------------------------------------------------------------

resource "google_compute_network" "public" {
  name                    = "task05-public-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  description             = "Tier 1: internet-facing. nginx reverse proxy and the WireGuard bastion."
}

resource "google_compute_network" "apps" {
  name                    = "task05-apps-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  description             = "Tier 2: application servers. No internet ingress, egress via Cloud NAT."
}

resource "google_compute_network" "dbs" {
  name                    = "task05-dbs-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  description             = "Tier 3: database. Reachable only from the apps tier."
}

# --- subnets ---------------------------------------------------------------
# Private Google Access is on for the two private tiers so they can reach
# Google APIs (package metadata, logging) without a public IP.

resource "google_compute_subnetwork" "public" {
  name                     = "task05-public-subnet"
  ip_cidr_range            = var.public_subnet_cidr
  region                   = var.region
  network                  = google_compute_network.public.id
  private_ip_google_access = true
}

resource "google_compute_subnetwork" "apps" {
  name                     = "task05-apps-subnet"
  ip_cidr_range            = var.apps_subnet_cidr
  region                   = var.region
  network                  = google_compute_network.apps.id
  private_ip_google_access = true
}

resource "google_compute_subnetwork" "dbs" {
  name                     = "task05-dbs-subnet"
  ip_cidr_range            = var.dbs_subnet_cidr
  region                   = var.region
  network                  = google_compute_network.dbs.id
  private_ip_google_access = true
}

# ---------------------------------------------------------------------------
# VPC PEERING — and its non-transitivity, which is the point.
#
# Two peerings are created:
#
#     public <--peer--> apps <--peer--> dbs
#
# GCP peering is NON-TRANSITIVE. public and dbs are each one hop from apps, but
# there is no route between them and no way to create one short of peering them
# directly. So:
#
#     nginx (public)  -> app (apps)   OK, direct peering
#     app   (apps)    -> db  (dbs)    OK, direct peering
#     nginx (public)  -> db  (dbs)    IMPOSSIBLE, no route exists
#
# This is exactly the tier boundary the assignment asks for, enforced by
# ROUTING rather than by a firewall rule. A firewall rule can be edited, or
# applied to the wrong target tag, or shadowed by a higher-priority rule. A
# missing route cannot be any of those things: the packet has nowhere to go.
#
# Each direction is a separate resource. A peering is only ACTIVE once BOTH
# sides exist, which is the source of the classic race: Terraform creates one
# side, something downstream tries to use the link, and it is still INACTIVE.
# The explicit depends_on below serialises creation, and scripts/verify.sh
# polls for state ACTIVE rather than assuming it.
# ---------------------------------------------------------------------------

resource "google_compute_network_peering" "public_to_apps" {
  name         = "task05-public-to-apps"
  network      = google_compute_network.public.self_link
  peer_network = google_compute_network.apps.self_link

  # Route exchange is limited to subnet routes. Custom routes are NOT exported,
  # so a route added in one tier cannot silently extend reachability into
  # another.
  export_custom_routes = false
  import_custom_routes = false
}

resource "google_compute_network_peering" "apps_to_public" {
  name         = "task05-apps-to-public"
  network      = google_compute_network.apps.self_link
  peer_network = google_compute_network.public.self_link

  export_custom_routes = false
  import_custom_routes = false

  # Serialised: creating both directions of a peering concurrently is a
  # documented source of transient API errors.
  depends_on = [google_compute_network_peering.public_to_apps]
}

resource "google_compute_network_peering" "apps_to_dbs" {
  name         = "task05-apps-to-dbs"
  network      = google_compute_network.apps.self_link
  peer_network = google_compute_network.dbs.self_link

  export_custom_routes = false
  import_custom_routes = false

  depends_on = [google_compute_network_peering.apps_to_public]
}

resource "google_compute_network_peering" "dbs_to_apps" {
  name         = "task05-dbs-to-apps"
  network      = google_compute_network.dbs.self_link
  peer_network = google_compute_network.apps.self_link

  export_custom_routes = false
  import_custom_routes = false

  depends_on = [google_compute_network_peering.apps_to_dbs]
}

# NOTE: there is deliberately NO public <-> dbs peering. Adding one would give
# the internet-facing tier a route to the database and destroy the property
# this design exists to demonstrate.

# ---------------------------------------------------------------------------
# CLOUD NAT for the two private tiers.
#
# app and db instances have no public IP, which means no egress at all by
# default - and the failure mode is nasty: the instance boots fine, SSH over
# the bastion works fine, and then `apt-get install` hangs until it times out
# with a DNS or connection error that says nothing about the real cause.
#
# Cloud NAT requires a Cloud Router. The router does no BGP here; it exists
# because NAT is implemented as a router feature.
# ---------------------------------------------------------------------------

resource "google_compute_router" "apps" {
  name    = "task05-apps-router"
  region  = var.region
  network = google_compute_network.apps.id
}

resource "google_compute_router_nat" "apps" {
  name   = "task05-apps-nat"
  router = google_compute_router.apps.name
  region = var.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_router" "dbs" {
  name    = "task05-dbs-router"
  region  = var.region
  network = google_compute_network.dbs.id
}

resource "google_compute_router_nat" "dbs" {
  name   = "task05-dbs-nat"
  router = google_compute_router.dbs.name
  region = var.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
