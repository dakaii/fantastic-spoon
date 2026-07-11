variable "project_name" {
  description = "Prefix for VM and network names"
  type        = string
  default     = "hybrid-k8s"
}

variable "libvirt_uri" {
  description = "libvirt connection URI"
  type        = string
  default     = "qemu:///system"
}

variable "network_cidr" {
  description = "NAT network CIDR for simulated bare-metal nodes"
  type        = string
  default     = "192.168.122.0/24"
}

variable "storage_pool_path" {
  description = "Directory for libvirt storage pool"
  type        = string
  default     = "/var/lib/libvirt/images/hybrid-k8s"
}

variable "ubuntu_cloud_image_url" {
  description = "Ubuntu cloud image URL (qcow2)"
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "node_count" {
  description = "Total number of simulated bare-metal nodes"
  type        = number
  default     = 5
}

variable "control_plane_count" {
  description = "Number of k3s server (control plane) nodes"
  type        = number
  default     = 3
}

variable "node_vcpu" {
  description = "vCPUs per node"
  type        = number
  default     = 2
}

variable "node_memory_mb" {
  description = "RAM per node in MB"
  type        = number
  default     = 4096
}

variable "node_disk_gb" {
  description = "Disk size per node in GB"
  type        = number
  default     = 40
}

variable "ssh_public_key" {
  description = "SSH public key injected via cloud-init"
  type        = string
}
