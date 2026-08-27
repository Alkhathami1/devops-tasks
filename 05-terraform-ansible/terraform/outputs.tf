# Outputs feed the Ansible dynamic inventory (scripts/inventory.sh reads these
# with `terraform output -json`), so they are the contract between the two
# tools rather than decoration.

output "bastion_public_ip" {
  description = "Public address of the bastion. The only inbound admin path."
  value       = google_compute_instance.bastion.network_interface[0].access_config[0].nat_ip
}

output "bastion_private_ip" {
  value = google_compute_instance.bastion.network_interface[0].network_ip
}

output "nginx_public_ip" {
  description = "Public address of the reverse proxy. Serves 443 to the internet."
  value       = google_compute_instance.nginx.network_interface[0].access_config[0].nat_ip
}

output "nginx_private_ip" {
  value = google_compute_instance.nginx.network_interface[0].network_ip
}

output "app_private_ip" {
  description = "App server. No public address exists by design."
  value       = google_compute_instance.app.network_interface[0].network_ip
}

output "db_private_ip" {
  description = "Database. No public address, and no route from the public tier."
  value       = google_compute_instance.db.network_interface[0].network_ip
}

output "ssh_user" {
  value = var.ssh_user
}

output "vpn_cidr" {
  value = var.vpn_cidr
}

output "subnets" {
  description = "The CIDR plan, emitted so the verification scripts assert against Terraform rather than hardcoding."
  value = {
    public = var.public_subnet_cidr
    apps   = var.apps_subnet_cidr
    dbs    = var.dbs_subnet_cidr
    vpn    = var.vpn_cidr
  }
}

output "networks" {
  value = {
    public = google_compute_network.public.name
    apps   = google_compute_network.apps.name
    dbs    = google_compute_network.dbs.name
  }
}

# Inventory in one object, so the Ansible inventory script is a single jq call
# rather than six.
output "inventory" {
  description = "Everything Ansible needs: addresses, the bastion to jump through, and the login."
  value = {
    ssh_user   = var.ssh_user
    bastion_ip = google_compute_instance.bastion.network_interface[0].access_config[0].nat_ip
    hosts = {
      bastion = {
        ansible_host = google_compute_instance.bastion.network_interface[0].access_config[0].nat_ip
        private_ip   = google_compute_instance.bastion.network_interface[0].network_ip
        tier         = "public"
        via_bastion  = false
      }
      nginx = {
        ansible_host = google_compute_instance.nginx.network_interface[0].access_config[0].nat_ip
        private_ip   = google_compute_instance.nginx.network_interface[0].network_ip
        tier         = "public"
        via_bastion  = false
      }
      app = {
        ansible_host = google_compute_instance.app.network_interface[0].network_ip
        private_ip   = google_compute_instance.app.network_interface[0].network_ip
        tier         = "apps"
        via_bastion  = true
      }
      # The db is reached by chaining THROUGH the app host, not directly from
      # the bastion. public and dbs are not peered, so the bastion has no route
      # to it - a consequence of the topology, not a workaround for a bug.
      db = {
        ansible_host = google_compute_instance.db.network_interface[0].network_ip
        private_ip   = google_compute_instance.db.network_interface[0].network_ip
        tier         = "dbs"
        via_bastion  = true
        via_app      = true
      }
    }
  }
}
