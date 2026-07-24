variable "gcp_project" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "project_name" {
  type    = string
  default = "hybrid-k8s"
}

variable "domain_name" {
  description = "Domain for Cloud DNS failover (leave empty until registered)"
  type        = string
  default     = ""
}

variable "app_subdomain" {
  description = "Subdomain for the app (e.g. 'app' for app.example.com)"
  type        = string
  default     = "app"
}

variable "primary_state_path" {
  description = "Path to primary-cluster-gcp Terraform state"
  type        = string
  default     = "../primary-cluster-gcp/terraform.tfstate"
}

variable "standby_state_path" {
  description = "Path to cloud-services-gcp Terraform state"
  type        = string
  default     = "../cloud-services-gcp/terraform.tfstate"
}

variable "primary_api_url" {
  description = "Override primary k3s API URL for witness"
  type        = string
  default     = ""
}

variable "primary_lb_ip" {
  description = "Override primary load balancer IP for Cloud DNS"
  type        = string
  default     = ""
}

variable "standby_lb_ip" {
  description = "Override standby load balancer IP for Cloud DNS"
  type        = string
  default     = ""
}

variable "enable_witness" {
  description = "Deploy Cloud Function witness + Cloud Workflows (Phase 4)"
  type        = bool
  default     = true
}

variable "enable_level_c_automation" {
  description = <<-EOT
    When true (and enable_witness), Workflow calls activate-apps Cloud Function to
    scale standby Deployments. Requires Secret Manager kubeconfig
    (./scripts/seed-standby-kubeconfig.sh) and standby :6443 reachable from the
    internet (lab: k3s_api_source_ranges = ["0.0.0.0/0"] on cloud-services-gcp).
    Default false — operator path remains ./scripts/failover-gcp.sh activate-apps.
  EOT
  type        = bool
  default     = false
}

variable "standby_kubeconfig_secret_id" {
  description = "Secret Manager secret id holding standby kubeconfig YAML"
  type        = string
  default     = "hybrid-k8s-standby-kubeconfig"
}

variable "create_firestore_database" {
  description = "Create Firestore (default) DB for witness state. Set false if project already has one."
  type        = bool
  default     = true
}
