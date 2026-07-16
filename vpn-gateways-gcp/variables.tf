variable "gcp_project" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region for this VPN city"
  type        = string
  default     = "us-central1"
}

variable "gcp_zone" {
  description = "GCP zone for the gateway VM"
  type        = string
  default     = "us-central1-a"
}

variable "project_name" {
  description = "Prefix for resource names"
  type        = string
  default     = "hybrid-k8s"
}

variable "city" {
  description = "Short city/profile name (used in instance name and client configs)"
  type        = string
  default     = "us"
}

variable "subnet_cidr" {
  description = "VPN VPC subnet CIDR (isolated from primary/standby)"
  type        = string
  default     = "10.50.0.0/24"
}

variable "machine_type" {
  description = "GCE machine type for the WireGuard gateway"
  type        = string
  default     = "e2-small"
}

variable "node_disk_gb" {
  type    = number
  default = 20
}

variable "ssh_public_key" {
  type = string
}

variable "admin_cidr" {
  description = "Your public IP as CIDR for SSH — run: curl -s ifconfig.me && echo /32"
  type        = string
}

variable "vpn_client_cidrs" {
  description = "CIDRs allowed to reach UDP WireGuard. Empty = use admin_cidr only."
  type        = list(string)
  default     = []
}

variable "vpn_metrics_cidrs" {
  description = "CIDRs allowed to scrape node_exporter (9100). Empty = admin_cidr. Add primary node NAT IPs for in-cluster Prometheus."
  type        = list(string)
  default     = []
}

variable "node_exporter_port" {
  description = "TCP port for Prometheus node_exporter on the gateway"
  type        = number
  default     = 9100
}

variable "wireguard_port" {
  description = "UDP listen port for WireGuard"
  type        = number
  default     = 51820
}

variable "reserve_static_ip" {
  description = "Reserve a static external IP so client configs do not churn"
  type        = bool
  default     = true
}
