output "standby_instance_ids" {
  description = "EC2 instance IDs for standby nodes"
  value       = aws_instance.standby[*].id
}

output "standby_public_ips" {
  description = "Public IPs of standby nodes"
  value       = aws_instance.standby[*].public_ip
}

output "standby_k3s_api_endpoints" {
  description = "k3s API endpoints for Argo CD cluster registration"
  value       = [for ip in aws_instance.standby[*].public_ip : "https://${ip}:6443"]
}

output "backup_bucket_name" {
  description = "S3 bucket for Velero backups"
  value       = aws_s3_bucket.backups.id
}

output "backup_bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.backups.arn
}

output "velero_access_key_id" {
  description = "IAM access key for Velero (store in External Secrets)"
  value       = aws_iam_access_key.velero.id
  sensitive   = true
}

output "velero_secret_access_key" {
  description = "IAM secret key for Velero (store in External Secrets)"
  value       = aws_iam_access_key.velero.secret
  sensitive   = true
}

output "standby_nlb_dns_name" {
  description = "NLB DNS name for Route53 failover (standby record)"
  value       = aws_lb.standby.dns_name
}

output "standby_nlb_zone_id" {
  description = "NLB hosted zone ID for Route53 alias record"
  value       = aws_lb.standby.zone_id
}

output "ansible_inventory" {
  description = "Ansible inventory for standby cluster nodes"
  value = yamlencode({
    all = {
      vars = {
        ansible_user            = "ubuntu"
        ansible_ssh_common_args = "-o StrictHostKeyChecking=no"
        k3s_version             = "v1.29.5+k3s1"
        cluster_name            = "standby"
      }
      children = {
        k3s_server = {
          hosts = {
            for idx, inst in aws_instance.standby :
            inst.tags.Name => {
              ansible_host = inst.public_ip
              node_role    = "server"
            } if inst.tags.Role == "server"
          }
        }
        k3s_agent = {
          hosts = {
            for idx, inst in aws_instance.standby :
            inst.tags.Name => {
              ansible_host = inst.public_ip
              node_role    = "agent"
            } if inst.tags.Role == "agent"
          }
        }
      }
    }
  })
}

output "vpc_id" {
  description = "VPC ID for standby cluster"
  value       = aws_vpc.standby.id
}
