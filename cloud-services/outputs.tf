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

output "vpc_id" {
  description = "VPC ID for standby cluster"
  value       = aws_vpc.standby.id
}
