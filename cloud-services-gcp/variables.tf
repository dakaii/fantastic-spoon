variable "gcp_project" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "gcp_zones" {
  description = "GCP zones for standby node placement"
  type        = list(string)
  default     = ["us-central1-a"]
}

variable "project_name" {
  description = "Prefix for resource names"
  type        = string
  default     = "hybrid-k8s"
}

variable "subnet_cidr" {
  description = "Standby subnet CIDR"
  type        = string
  default     = "10.0.0.0/24"
}

variable "standby_node_count" {
  description = "Number of standby nodes (1 server + N-1 agents)"
  type        = number
  default     = 2
}

variable "standby_machine_type" {
  description = "GCE machine type for standby nodes (e2-small minimum; e2-micro OOMs / times out during bootstrap)"
  type        = string
  default     = "e2-small"
}

variable "node_disk_gb" {
  type    = number
  default = 30
}

variable "ssh_public_key" {
  type = string
}

variable "admin_cidr" {
  description = "Your public IP as CIDR — run: curl -s ifconfig.me"
  type        = string
}

variable "backup_retention_days" {
  description = "GCS lifecycle retention for Velero backups"
  type        = number
  default     = 30
}
