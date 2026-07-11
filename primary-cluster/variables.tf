variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix for all resource names"
  type        = string
  default     = "hybrid-k8s"
}

variable "vpc_cidr" {
  description = "VPC CIDR block for primary cluster"
  type        = string
  default     = "10.1.0.0/16"
}

variable "availability_zones" {
  description = "AZs to spread primary nodes across"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "control_plane_count" {
  description = "Number of k3s server nodes (use 1 for dev, 3 for HA)"
  type        = number
  default     = 1
}

variable "worker_count" {
  description = "Number of k3s agent nodes"
  type        = number
  default     = 2
}

variable "control_plane_instance_type" {
  description = "EC2 instance type for control plane nodes"
  type        = string
  default     = "t4g.small"
}

variable "worker_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t4g.small"
}

variable "node_disk_gb" {
  description = "Root volume size in GB"
  type        = number
  default     = 40
}

variable "ssh_public_key" {
  description = "SSH public key for node access"
  type        = string
}

variable "admin_cidr" {
  description = "CIDR allowed for SSH and k3s API access"
  type        = string
}
