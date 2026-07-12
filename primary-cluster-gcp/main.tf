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

resource "google_compute_network" "primary" {
  name                    = "${var.project_name}-primary-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "primary" {
  name          = "${var.project_name}-primary-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.gcp_region
  network       = google_compute_network.primary.id
}

resource "google_compute_firewall" "primary_ssh" {
  name    = "${var.project_name}-primary-allow-ssh"
  network = google_compute_network.primary.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [var.admin_cidr]
  target_tags   = ["${var.project_name}-primary"]
}

resource "google_compute_firewall" "primary_k3s_api" {
  name    = "${var.project_name}-primary-allow-k3s-api"
  network = google_compute_network.primary.name

  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }

  source_ranges = [var.admin_cidr]
  target_tags   = ["${var.project_name}-primary"]
}

resource "google_compute_firewall" "primary_web" {
  name    = "${var.project_name}-primary-allow-web"
  network = google_compute_network.primary.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "30000-32767"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.project_name}-primary"]
}

resource "google_compute_firewall" "primary_internal" {
  name    = "${var.project_name}-primary-allow-internal"
  network = google_compute_network.primary.name

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr]
  target_tags   = ["${var.project_name}-primary"]
}

locals {
  control_plane_nodes = [
    for i in range(var.control_plane_count) : {
      name = "${var.project_name}-cp-${i + 1}"
      role = "server"
      zone = var.gcp_zones[i % length(var.gcp_zones)]
    }
  ]

  worker_nodes = [
    for i in range(var.worker_count) : {
      name = "${var.project_name}-worker-${i + 1}"
      role = "agent"
      # Workers must share a zone — zonal instance group for the TCP load balancer
      zone = var.gcp_zones[0]
    }
  ]

  all_nodes = concat(local.control_plane_nodes, local.worker_nodes)
}

resource "google_compute_instance" "primary" {
  for_each = { for node in local.all_nodes : node.name => node }

  name         = each.key
  machine_type = each.value.role == "server" ? var.control_plane_machine_type : var.worker_machine_type
  zone         = each.value.zone

  tags = ["${var.project_name}-primary", "k3s-${each.value.role}"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.node_disk_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.primary.id
    access_config {}
  }

  metadata = {
    ssh-keys  = "ubuntu:${var.ssh_public_key}"
    user-data = templatefile("${path.module}/cloud-init/node.yaml.tftpl", {
      hostname   = each.key
      node_role  = each.value.role
      node_index = index([for n in local.all_nodes : n.name], each.key) + 1
    })
  }

  labels = {
    cluster = "primary"
    role    = each.value.role
  }
}

resource "google_compute_health_check" "primary" {
  name = "${var.project_name}-primary-hc"

  tcp_health_check {
    port = 30443
  }

  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3
}

resource "google_compute_instance_group" "primary_workers" {
  name      = "${var.project_name}-primary-workers"
  zone      = var.gcp_zones[0]
  instances = [
    for name, inst in google_compute_instance.primary :
    inst.self_link if inst.labels.role == "agent"
  ]

  named_port {
    name = "https"
    port = 30443
  }
}

resource "google_compute_region_backend_service" "primary" {
  name                  = "${var.project_name}-primary-backend"
  region                = var.gcp_region
  load_balancing_scheme = "EXTERNAL"
  protocol              = "TCP"
  health_checks         = [google_compute_health_check.primary.id]

  backend {
    group          = google_compute_instance_group.primary_workers.id
    balancing_mode = "CONNECTION"
  }
}

resource "google_compute_forwarding_rule" "primary_https" {
  name                  = "${var.project_name}-primary-https"
  region                = var.gcp_region
  load_balancing_scheme = "EXTERNAL"
  ip_protocol           = "TCP"
  port_range            = "443"
  backend_service       = google_compute_region_backend_service.primary.id
}

resource "google_compute_forwarding_rule" "primary_http" {
  name                  = "${var.project_name}-primary-http"
  region                = var.gcp_region
  load_balancing_scheme = "EXTERNAL"
  ip_protocol           = "TCP"
  port_range            = "80"
  backend_service       = google_compute_region_backend_service.primary.id
}
