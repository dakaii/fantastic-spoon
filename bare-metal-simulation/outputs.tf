output "node_names" {
  description = "libvirt domain names for all nodes"
  value       = libvirt_domain.nodes[*].name
}

output "node_ips" {
  description = "DHCP-assigned IP addresses (available after boot)"
  value       = libvirt_domain.nodes[*].network_interface[0].addresses
}

output "node_roles" {
  description = "Role assignment per node (server or agent)"
  value = [
    for i in range(var.node_count) :
    i < var.control_plane_count ? "server" : "agent"
  ]
}

output "network_name" {
  description = "libvirt network name"
  value       = libvirt_network.bare_metal.name
}

output "ansible_inventory" {
  description = "Ansible inventory YAML (update IPs after first boot with virsh domifaddr)"
  value = yamlencode({
    all = {
      vars = {
        ansible_user            = "ubuntu"
        ansible_ssh_common_args = "-o StrictHostKeyChecking=no"
        k3s_version             = "v1.29.5+k3s1"
        cluster_name            = "primary"
        cluster_profile           = "primary"
        provisioner               = "libvirt"
        ingress_host              = try(libvirt_domain.nodes[var.worker_count > 0 ? var.control_plane_count : 0].network_interface[0].addresses[0], "PENDING_BOOT")
        k3s_api_host              = try(libvirt_domain.nodes[0].network_interface[0].addresses[0], "PENDING_BOOT")
      }
      children = {
        k3s_server = {
          hosts = {
            for i in range(var.control_plane_count) :
            libvirt_domain.nodes[i].name => {
              ansible_host = try(
                libvirt_domain.nodes[i].network_interface[0].addresses[0],
                "PENDING_BOOT"
              )
              node_role = "server"
            }
          }
        }
        k3s_agent = {
          hosts = {
            for i in range(var.control_plane_count, var.node_count) :
            libvirt_domain.nodes[i].name => {
              ansible_host = try(
                libvirt_domain.nodes[i].network_interface[0].addresses[0],
                "PENDING_BOOT"
              )
              node_role = "agent"
            }
          }
        }
      }
    }
  })
}

output "cluster_meta" {
  description = "Cluster metadata for bootstrap scripts"
  value = {
    provisioner     = "libvirt"
    cluster_name    = "primary"
    cluster_profile = "primary"
    k3s_api_host    = try(libvirt_domain.nodes[0].network_interface[0].addresses[0], "PENDING_BOOT")
    network_name    = libvirt_network.bare_metal.name
  }
}
