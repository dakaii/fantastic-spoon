output "vpn_instance_name" {
  value = google_compute_instance.vpn.name
}

output "vpn_public_ip" {
  description = "WireGuard endpoint IP for client configs"
  value       = google_compute_instance.vpn.network_interface[0].access_config[0].nat_ip
}

output "vpn_zone" {
  value = google_compute_instance.vpn.zone
}

output "vpn_city" {
  value = var.city
}

output "wireguard_port" {
  value = var.wireguard_port
}

output "node_exporter_port" {
  value = var.node_exporter_port
}

output "vpn_metrics_url" {
  description = "Prometheus scrape target for the VPN gateway"
  value       = "${google_compute_instance.vpn.network_interface[0].access_config[0].nat_ip}:${var.node_exporter_port}"
}

output "vpn_vpc_name" {
  value = google_compute_network.vpn.name
}

output "ansible_inventory" {
  description = "Inventory fragment for ansible/playbooks/vpn-gateway.yml"
  value = yamlencode({
    all = {
      vars = {
        ansible_user            = "ubuntu"
        ansible_ssh_common_args = "-o StrictHostKeyChecking=no"
        vpn_city                = var.city
        wireguard_port          = var.wireguard_port
      }
      children = {
        vpn_gateway = {
          hosts = {
            (google_compute_instance.vpn.name) = {
              ansible_host = google_compute_instance.vpn.network_interface[0].access_config[0].nat_ip
              city         = var.city
            }
          }
        }
      }
    }
  })
}
