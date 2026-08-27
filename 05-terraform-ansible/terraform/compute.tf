# ---------------------------------------------------------------------------
# INSTANCES — four e2-micro, one zone.
#
# OS LOGIN vs METADATA SSH KEYS
#
# The two are mutually exclusive: with enable-oslogin=TRUE, metadata SSH keys
# are ignored entirely, and the failure looks like a permission problem rather
# than a configuration one - the key is present, sshd is running, and the login
# is simply refused.
#
# This project has NO project-level oslogin metadata (verified with
# `gcloud compute project-info describe`), so neither mode is inherited and the
# choice is per-instance. enable-oslogin=FALSE is set EXPLICITLY on every
# instance rather than left unset, so a later change to the project default
# cannot silently break the Ansible SSH path.
#
# The trade is real and stated in the report: OS Login gives IAM-governed
# access, automatic key rotation and audit logging, and would be the right
# choice for anything long-lived. Metadata keys are chosen here because the
# whole estate exists for perhaps an hour and Ansible needs a plain
# ProxyJump-able key path.
# ---------------------------------------------------------------------------

locals {
  ssh_keys = "${var.ssh_user}:${var.ssh_public_key}"

  # Common metadata for every instance.
  common_metadata = {
    ssh-keys       = local.ssh_keys
    enable-oslogin = "FALSE"
  }
}

# --- bastion: the only way in ----------------------------------------------
resource "google_compute_instance" "bastion" {
  name         = "task05-bastion"
  machine_type = var.machine_type
  zone         = var.zone
  labels       = var.labels

  boot_disk {
    initialize_params {
      image = var.boot_image
      size  = var.boot_disk_size_gb
      type  = var.boot_disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.public.id

    # Ephemeral public IP. A reserved static address would survive destroy and
    # bill quietly while unattached, which is exactly the orphan class the
    # teardown check hunts for.
    access_config {}
  }

  service_account {
    email  = google_service_account.bastion.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = local.common_metadata

  # IP forwarding is REQUIRED for WireGuard. Without it the kernel drops any
  # packet whose destination is not this host, so the tunnel establishes, the
  # handshake completes, and then nothing routes - which reads as a firewall
  # problem and is not one.
  can_ip_forward = true

  tags = ["bastion", "wireguard"]
}

# --- nginx: the public entry point ------------------------------------------
resource "google_compute_instance" "nginx" {
  name         = "task05-nginx"
  machine_type = var.machine_type
  zone         = var.zone
  labels       = var.labels

  boot_disk {
    initialize_params {
      image = var.boot_image
      size  = var.boot_disk_size_gb
      type  = var.boot_disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.public.id
    access_config {}
  }

  service_account {
    email  = google_service_account.nginx.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = local.common_metadata
  tags     = ["nginx", "public-tier"]
}

# --- app: no public IP ------------------------------------------------------
resource "google_compute_instance" "app" {
  name         = "task05-app"
  machine_type = var.machine_type
  zone         = var.zone
  labels       = var.labels

  boot_disk {
    initialize_params {
      image = var.boot_image
      size  = var.boot_disk_size_gb
      type  = var.boot_disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.apps.id
    # No access_config: no public IP. Egress is via Cloud NAT.
  }

  service_account {
    email  = google_service_account.app.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = local.common_metadata
  tags     = ["app", "apps-tier"]

  depends_on = [google_compute_router_nat.apps]
}

# --- db: no public IP, reachable only from the apps tier --------------------
resource "google_compute_instance" "db" {
  name         = "task05-db"
  machine_type = var.machine_type
  zone         = var.zone
  labels       = var.labels

  boot_disk {
    initialize_params {
      image = var.boot_image
      size  = var.boot_disk_size_gb
      type  = var.boot_disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.dbs.id
  }

  service_account {
    email  = google_service_account.db.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = local.common_metadata
  tags     = ["db", "dbs-tier"]

  depends_on = [google_compute_router_nat.dbs]
}
