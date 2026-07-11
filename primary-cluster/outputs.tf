output "primary_instance_ids" {
  description = "EC2 instance IDs for all primary nodes"
  value       = { for name, inst in aws_instance.primary : name => inst.id }
}

output "primary_public_ips" {
  description = "Public IPs of primary nodes"
  value       = { for name, inst in aws_instance.primary : name => inst.public_ip }
}

output "primary_control_plane_ips" {
  description = "Public IPs of control plane nodes only"
  value = {
    for name, inst in aws_instance.primary :
    name => inst.public_ip
    if inst.tags.Role == "server"
  }
}

output "primary_nlb_dns_name" {
  description = "NLB DNS name for Route53 failover (primary record)"
  value       = aws_lb.primary.dns_name
}

output "primary_nlb_zone_id" {
  description = "NLB hosted zone ID for Route53 alias record"
  value       = aws_lb.primary.zone_id
}

output "primary_vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.primary.id
}

output "ansible_inventory" {
  description = "Ansible inventory for primary cluster nodes"
  value = yamlencode({
    all = {
      vars = {
        ansible_user            = "ubuntu"
        ansible_ssh_common_args = "-o StrictHostKeyChecking=no"
        k3s_version             = "v1.29.5+k3s1"
        cluster_name            = "primary"
      }
      children = {
        k3s_server = {
          hosts = {
            for name, inst in aws_instance.primary :
            name => {
              ansible_host = inst.public_ip
              node_role    = "server"
            } if inst.tags.Role == "server"
          }
        }
        k3s_agent = {
          hosts = {
            for name, inst in aws_instance.primary :
            name => {
              ansible_host = inst.public_ip
              node_role    = "agent"
            } if inst.tags.Role == "agent"
          }
        }
      }
    }
  })
}
