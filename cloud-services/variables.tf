variable "aws_region" {
  description = "AWS region for cloud resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix for all cloud resource names"
  type        = string
  default     = "hybrid-k8s"
}

variable "standby_instance_type" {
  description = "EC2 instance type for standby k3s nodes (min 1 GB RAM — use t4g.micro)"
  type        = string
  default     = "t4g.micro"
}

variable "standby_node_count" {
  description = "Number of cloud standby nodes (1 server + N-1 agents)"
  type        = number
  default     = 2
}

variable "node_disk_gb" {
  description = "Root volume size in GB for standby nodes"
  type        = number
  default     = 30
}

variable "ssh_public_key" {
  description = "SSH public key for standby instances"
  type        = string
}

variable "admin_cidr" {
  description = "CIDR allowed to SSH and access k3s API"
  type        = string
}

variable "backup_retention_days" {
  description = "S3 lifecycle retention for Velero backups"
  type        = number
  default     = 30
}

variable "domain_name" {
  description = "Domain for ExternalDNS (optional)"
  type        = string
  default     = ""
}
