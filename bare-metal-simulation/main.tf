terraform {
  required_version = ">= 1.5.0"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.7"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

resource "libvirt_network" "bare_metal" {
  name      = "${var.project_name}-net"
  mode      = "nat"
  domain    = "local"
  addresses = [var.network_cidr]
  dhcp {
    enabled = true
  }
  dns {
    enabled    = true
    local_only = false
  }
}

resource "libvirt_pool" "bare_metal" {
  name = "${var.project_name}-pool"
  type = "dir"
  target {
    path = var.storage_pool_path
  }
}

resource "libvirt_volume" "base" {
  name   = "${var.project_name}-ubuntu-base"
  pool   = libvirt_pool.bare_metal.name
  source = var.ubuntu_cloud_image_url
  format = "qcow2"
}

resource "libvirt_cloudinit_disk" "nodes" {
  count     = var.node_count
  name      = "${var.project_name}-cloudinit-${count.index}.iso"
  pool      = libvirt_pool.bare_metal.name
  user_data = templatefile("${path.module}/cloud-init/node.yaml.tftpl", {
    hostname       = "${var.project_name}-node-${count.index + 1}"
    ssh_public_key = var.ssh_public_key
    node_role      = count.index < var.control_plane_count ? "server" : "agent"
    node_index     = count.index + 1
  })
}

resource "libvirt_volume" "nodes" {
  count          = var.node_count
  name           = "${var.project_name}-node-${count.index + 1}.qcow2"
  pool           = libvirt_pool.bare_metal.name
  base_volume_id = libvirt_volume.base.id
  size           = var.node_disk_gb * 1024 * 1024 * 1024
}

resource "libvirt_domain" "nodes" {
  count  = var.node_count
  name   = "${var.project_name}-node-${count.index + 1}"
  memory = var.node_memory_mb
  vcpu   = var.node_vcpu

  cloudinit = libvirt_cloudinit_disk.nodes[count.index].id

  disk {
    volume_id = libvirt_volume.nodes[count.index].id
  }

  network_interface {
    network_id     = libvirt_network.bare_metal.id
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  console {
    type        = "pty"
    target_type = "virtio"
    target_port = "1"
  }

  lifecycle {
    ignore_changes = [cloudinit]
  }
}
