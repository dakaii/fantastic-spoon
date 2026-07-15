variable "gcp_project" {
  description = "GCP project ID (create at console.cloud.google.com)"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "gcp_zones" {
  description = "GCP zones for node placement (control planes spread across zones; workers use zones[0] for LB)"
  type        = list(string)
  default     = ["us-central1-a", "us-central1-b"]
}

variable "project_name" {
  description = "Prefix for resource names"
  type        = string
  default     = "hybrid-k8s"
}

variable "subnet_cidr" {
  description = "Primary subnet CIDR"
  type        = string
  default     = "10.1.0.0/24"
}

variable "control_plane_count" {
  type    = number
  default = 1
}

variable "worker_count" {
  type    = number
  default = 2
}

variable "control_plane_machine_type" {
  description = "GCE machine type for control plane (e2-medium ~$24/mo; e2-small OOMs with Cilium+Longhorn+Argo CD)"
  type        = string
  default     = "e2-medium"
}

variable "worker_machine_type" {
  description = "GCE machine type for workers"
  type        = string
  default     = "e2-small"
}

variable "node_disk_gb" {
  type    = number
  default = 40
}

variable "ssh_public_key" {
  type = string
}

variable "admin_cidr" {
  description = "Your public IP as CIDR — run: curl -s ifconfig.me"
  type        = string
}

variable "k3s_api_source_ranges" {
  description = "CIDRs allowed to reach k3s API :6443. Empty = admin_cidr only. For Phase 4 Cloud Function witness (public egress), set [\"0.0.0.0/0\"] in lab or restrict to known ranges."
  type        = list(string)
  default     = []
}
