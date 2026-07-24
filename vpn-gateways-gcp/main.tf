terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
}

data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

locals {
  vpn_client_cidrs  = length(var.vpn_client_cidrs) > 0 ? var.vpn_client_cidrs : [var.admin_cidr]
  vpn_metrics_cidrs = length(var.vpn_metrics_cidrs) > 0 ? var.vpn_metrics_cidrs : [var.admin_cidr]
}

# Dedicated VPC per city — not peered with primary/standby. Safe to destroy alone.
# City suffix avoids name collisions when us + hk run as separate TF states.
resource "google_compute_network" "vpn" {
  name                    = "${var.project_name}-vpn-${var.city}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "vpn" {
  name          = "${var.project_name}-vpn-${var.city}-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.gcp_region
  network       = google_compute_network.vpn.id
}

resource "google_compute_firewall" "vpn_ssh" {
  name    = "${var.project_name}-vpn-${var.city}-allow-ssh"
  network = google_compute_network.vpn.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [var.admin_cidr]
  target_tags   = ["vpn-gateway"]
}

resource "google_compute_firewall" "vpn_wireguard" {
  name    = "${var.project_name}-vpn-${var.city}-allow-wireguard"
  network = google_compute_network.vpn.name

  allow {
    protocol = "udp"
    ports    = [tostring(var.wireguard_port)]
  }

  source_ranges = local.vpn_client_cidrs
  target_tags   = ["vpn-gateway"]
}

resource "google_compute_firewall" "vpn_icmp" {
  name    = "${var.project_name}-vpn-${var.city}-allow-icmp"
  network = google_compute_network.vpn.name

  allow {
    protocol = "icmp"
  }

  source_ranges = local.vpn_client_cidrs
  target_tags   = ["vpn-gateway"]
}

# node_exporter (:9100) — scrape from admin / primary Prometheus egress only
resource "google_compute_firewall" "vpn_metrics" {
  name    = "${var.project_name}-vpn-${var.city}-allow-metrics"
  network = google_compute_network.vpn.name

  allow {
    protocol = "tcp"
    ports    = [tostring(var.node_exporter_port)]
  }

  source_ranges = local.vpn_metrics_cidrs
  target_tags   = ["vpn-gateway"]
}

resource "google_compute_address" "vpn" {
  count  = var.reserve_static_ip ? 1 : 0
  name   = "${var.project_name}-vpn-${var.city}-ip"
  region = var.gcp_region
}

resource "google_compute_instance" "vpn" {
  name         = "${var.project_name}-vpn-${var.city}"
  machine_type = var.machine_type
  zone         = var.gcp_zone

  # Required for WireGuard NAT egress (consumer VPN full-tunnel)
  can_ip_forward = true

  tags = ["${var.project_name}-vpn", "vpn-gateway"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.node_disk_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.vpn.id
    access_config {
      nat_ip = var.reserve_static_ip ? google_compute_address.vpn[0].address : null
    }
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
    user-data = templatefile("${path.module}/cloud-init/vpn-gateway.yaml.tftpl", {
      hostname = "${var.project_name}-vpn-${var.city}"
      city     = var.city
    })
  }

  # Never set labels.cluster=primary|standby — keeps generate-gcp-inventory.sh away.
  labels = {
    role      = "vpn-gateway"
    city      = var.city
    component = "wireguard"
  }

  allow_stopping_for_update = true
}
