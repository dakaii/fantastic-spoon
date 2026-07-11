variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "hybrid-k8s"
}

variable "domain_name" {
  description = "Domain for Route53 failover (leave empty until registered)"
  type        = string
  default     = ""
}

variable "app_subdomain" {
  description = "Subdomain for the app (e.g. 'app' for app.example.com)"
  type        = string
  default     = "app"
}

variable "alert_email" {
  description = "Email for failover SNS notifications"
  type        = string
  default     = ""
}

variable "primary_state_path" {
  description = "Path to primary-cluster Terraform state"
  type        = string
  default     = "../primary-cluster/terraform.tfstate"
}

variable "standby_state_path" {
  description = "Path to cloud-services Terraform state"
  type        = string
  default     = "../cloud-services/terraform.tfstate"
}

variable "primary_api_url" {
  description = "Override primary k3s API URL for witness"
  type        = string
  default     = ""
}

variable "primary_nlb_dns_name" {
  type    = string
  default = ""
}

variable "primary_nlb_zone_id" {
  type    = string
  default = ""
}

variable "standby_nlb_dns_name" {
  type    = string
  default = ""
}

variable "standby_nlb_zone_id" {
  type    = string
  default = ""
}

variable "primary_health_check_fqdn" {
  type    = string
  default = ""
}
