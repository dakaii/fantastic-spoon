output "primary_instance_names" {
  value = { for name, inst in google_compute_instance.primary : name => inst.name }
}

output "primary_public_ips" {
  value = { for name, inst in google_compute_instance.primary : name => inst.network_interface[0].access_config[0].nat_ip }
}

output "primary_control_plane_ips" {
  value = {
    for name, inst in google_compute_instance.primary :
    name => inst.network_interface[0].access_config[0].nat_ip
    if inst.labels.role == "server"
  }
}

output "primary_lb_ip" {
  description = "External TCP load balancer IP for ingress failover"
  value       = google_compute_forwarding_rule.primary_https.ip_address
}

output "primary_vpc_name" {
  value = google_compute_network.primary.name
}

output "ansible_inventory" {
  value = yamlencode({
    all = {
      vars = {
        ansible_user            = "ubuntu"
        ansible_ssh_common_args = "-o StrictHostKeyChecking=no"
        k3s_version             = "v1.29.5+k3s1"
        cluster_name            = "primary"
        cluster_profile         = "primary"
        provisioner             = "gcp-compute"
        ingress_host            = google_compute_forwarding_rule.primary_https.ip_address
        k3s_api_host            = [for name, inst in google_compute_instance.primary : inst.network_interface[0].access_config[0].nat_ip if inst.labels.role == "server"][0]
      }
      children = {
        k3s_server = {
          hosts = {
            for name, inst in google_compute_instance.primary :
            name => {
              ansible_host = inst.network_interface[0].access_config[0].nat_ip
              node_role    = "server"
            } if inst.labels.role == "server"
          }
        }
        k3s_agent = {
          hosts = {
            for name, inst in google_compute_instance.primary :
            name => {
              ansible_host = inst.network_interface[0].access_config[0].nat_ip
              node_role    = "agent"
            } if inst.labels.role == "agent"
          }
        }
      }
    }
  })
}

output "cluster_meta" {
  value = {
    provisioner     = "gcp-compute"
    cluster_name    = "primary"
    cluster_profile = "primary"
    ingress_host    = google_compute_forwarding_rule.primary_https.ip_address
    gcp_project     = var.gcp_project
    gcp_region      = var.gcp_region
    k3s_api_host    = [for name, inst in google_compute_instance.primary : inst.network_interface[0].access_config[0].nat_ip if inst.labels.role == "server"][0]
  }
}
