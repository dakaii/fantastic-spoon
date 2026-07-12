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
