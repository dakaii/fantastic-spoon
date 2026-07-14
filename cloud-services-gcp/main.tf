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

resource "google_compute_network" "standby" {
  name                    = "${var.project_name}-standby-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "standby" {
  name          = "${var.project_name}-standby-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.gcp_region
  network       = google_compute_network.standby.id
}

resource "google_compute_firewall" "standby_ssh" {
  name    = "${var.project_name}-standby-allow-ssh"
  network = google_compute_network.standby.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [var.admin_cidr]
  target_tags   = ["${var.project_name}-standby"]
}

resource "google_compute_firewall" "standby_k3s_api" {
  name    = "${var.project_name}-standby-allow-k3s-api"
  network = google_compute_network.standby.name

  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }

  source_ranges = [var.admin_cidr]
  target_tags   = ["${var.project_name}-standby"]
}

resource "google_compute_firewall" "standby_web" {
  name    = "${var.project_name}-standby-allow-web"
  network = google_compute_network.standby.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "30000-32767"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.project_name}-standby"]
}

resource "google_compute_firewall" "standby_internal" {
  name    = "${var.project_name}-standby-allow-internal"
  network = google_compute_network.standby.name

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
  target_tags   = ["${var.project_name}-standby"]
}

locals {
  standby_nodes = [
    for i in range(var.standby_node_count) : {
      name = "${var.project_name}-standby-${i + 1}"
      role = i == 0 ? "server" : "agent"
      # Standby workers share zone 0 for zonal instance group + TCP LB
      zone = var.gcp_zones[0]
    }
  ]
}

resource "google_compute_instance" "standby" {
  for_each = { for node in local.standby_nodes : node.name => node }

  name         = each.key
  machine_type = var.standby_machine_type
  zone         = each.value.zone

  # Allow in-place resize when bumping off e2-micro (Terraform stops/starts the VM).
  allow_stopping_for_update = true

  tags = ["${var.project_name}-standby", "k3s-${each.value.role}"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.node_disk_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.standby.id
    access_config {}
  }

  metadata = {
    ssh-keys  = "ubuntu:${var.ssh_public_key}"
    user-data = templatefile("${path.module}/cloud-init/node.yaml.tftpl", {
      hostname  = each.key
      node_role = each.value.role
    })
  }

  labels = {
    cluster = "standby"
    role    = each.value.role
  }
}

resource "google_compute_region_health_check" "standby" {
  name   = "${var.project_name}-standby-hc"
  region = var.gcp_region

  tcp_health_check {
    port = 30443
  }

  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3
}

resource "google_compute_instance_group" "standby_workers" {
  name      = "${var.project_name}-standby-workers"
  zone      = var.gcp_zones[0]
  instances = [
    for name, inst in google_compute_instance.standby :
    inst.self_link if inst.labels.role == "agent"
  ]

  named_port {
    name = "https"
    port = 30443
  }
}

resource "google_compute_region_backend_service" "standby" {
  name                  = "${var.project_name}-standby-backend"
  region                = var.gcp_region
  load_balancing_scheme = "EXTERNAL"
  protocol              = "TCP"
  health_checks         = [google_compute_region_health_check.standby.id]

  backend {
    group          = google_compute_instance_group.standby_workers.id
    balancing_mode = "CONNECTION"
  }
}

resource "google_compute_forwarding_rule" "standby_https" {
  name                  = "${var.project_name}-standby-https"
  region                = var.gcp_region
  load_balancing_scheme = "EXTERNAL"
  ip_protocol           = "TCP"
  port_range            = "443"
  backend_service       = google_compute_region_backend_service.standby.id
}

# --- Backup Storage (GCS) ---

resource "google_storage_bucket" "backups" {
  name     = "${var.project_name}-backups-${var.gcp_project}"
  location = var.gcp_region

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = var.backup_retention_days
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 3
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_service_account" "velero" {
  account_id   = "${var.project_name}-velero"
  display_name = "Velero backup service account"
}

resource "google_storage_bucket_iam_member" "velero" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.velero.email}"
}

resource "google_storage_hmac_key" "velero" {
  service_account_email = google_service_account.velero.email
}
