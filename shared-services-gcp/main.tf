terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
}

data "terraform_remote_state" "primary" {
  backend = "local"

  config = {
    path = var.primary_state_path
  }
}

data "terraform_remote_state" "standby" {
  backend = "local"

  config = {
    path = var.standby_state_path
  }
}

locals {
  primary_lb_ip = var.primary_lb_ip != "" ? var.primary_lb_ip : try(data.terraform_remote_state.primary.outputs.primary_lb_ip, "")
  standby_lb_ip = var.standby_lb_ip != "" ? var.standby_lb_ip : try(data.terraform_remote_state.standby.outputs.standby_lb_ip, "")
  primary_api_url = var.primary_api_url != "" ? var.primary_api_url : "https://${try(values(data.terraform_remote_state.primary.outputs.primary_control_plane_ips)[0], "127.0.0.1")}:6443"
  dns_record_name = var.domain_name != "" ? (
    var.app_subdomain != "" ? "${var.app_subdomain}.${var.domain_name}." : "${var.domain_name}."
  ) : ""
}

# --- Cloud DNS Failover (requires domain) ---

resource "google_dns_managed_zone" "main" {
  count = var.domain_name != "" ? 1 : 0

  name        = replace("${var.project_name}-${var.domain_name}", ".", "-")
  dns_name    = "${var.domain_name}."
  description = "Hybrid k8s failover zone"
}

resource "google_dns_health_check" "primary" {
  count = var.domain_name != "" ? 1 : 0

  name               = "${var.project_name}-primary-hc"
  check_interval_sec = 30
  timeout_sec        = 5

  https_health_check {
    port         = 443
    request_path = "/"
    host         = local.primary_lb_ip
  }
}

resource "google_dns_record_set" "app_failover" {
  count = var.domain_name != "" ? 1 : 0

  name         = local.dns_record_name
  managed_zone = google_dns_managed_zone.main[0].name
  type         = "A"
  ttl          = 30

  routing_policy {
    primary_backup {
      enable_geo_fencing_for_backups = false

      primary {
        rrdatas = [local.primary_lb_ip]

        health_checked_targets {
          targets {
            ip_address = local.primary_lb_ip
          }
        }
      }

      backup {
        rrdatas = [local.standby_lb_ip]
      }
    }
  }
}

# --- Witness state (Firestore) ---

resource "google_firestore_database" "witness" {
  project     = var.gcp_project
  name        = "(default)"
  location_id = var.gcp_region
  type        = "FIRESTORE_NATIVE"
}

# --- Pub/Sub alerts ---

resource "google_pubsub_topic" "failover" {
  name = "${var.project_name}-failover-alerts"
}

# --- Cloud Function witness ---

resource "google_service_account" "witness" {
  account_id   = "${var.project_name}-witness"
  display_name = "Failover witness Cloud Function"
}

resource "google_project_iam_member" "witness_firestore" {
  project = var.gcp_project
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.witness.email}"
}

resource "google_project_iam_member" "witness_pubsub" {
  project = var.gcp_project
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.witness.email}"
}

resource "google_project_iam_member" "witness_workflows" {
  project = var.gcp_project
  role    = "roles/workflows.invoker"
  member  = "serviceAccount:${google_service_account.witness.email}"
}

data "archive_file" "witness" {
  type        = "zip"
  source_dir  = "${path.module}/cloud_function"
  output_path = "${path.module}/cloud_function/witness.zip"
}

resource "google_storage_bucket" "witness_source" {
  name     = "${var.project_name}-witness-src-${var.gcp_project}"
  location = var.gcp_region

  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_storage_bucket_object" "witness" {
  name   = "witness-${data.archive_file.witness.output_md5}.zip"
  bucket = google_storage_bucket.witness_source.name
  source = data.archive_file.witness.output_path
}

resource "google_cloudfunctions2_function" "witness" {
  name        = "${var.project_name}-witness"
  location    = var.gcp_region
  description = "Checks primary k3s API health and triggers failover workflow"

  build_config {
    runtime     = "python312"
    entry_point = "health_check"
    source {
      storage_source {
        bucket = google_storage_bucket.witness_source.name
        object = google_storage_bucket_object.witness.name
      }
    }
  }

  service_config {
    available_memory   = "256M"
    timeout_seconds    = 30
    service_account_email = google_service_account.witness.email

    environment_variables = {
      PRIMARY_API_URL       = local.primary_api_url
      FAILURE_THRESHOLD     = "3"
      FIRESTORE_DATABASE    = google_firestore_database.witness.name
      FAILOVER_WORKFLOW_ID  = google_workflows_workflow.failover.id
      PUBSUB_TOPIC          = google_pubsub_topic.failover.id
      GCP_PROJECT           = var.gcp_project
    }
  }
}

resource "google_cloudfunctions2_function_iam_member" "witness_invoker" {
  project        = google_cloudfunctions2_function.witness.project
  location       = google_cloudfunctions2_function.witness.location
  cloud_function = google_cloudfunctions2_function.witness.name
  role           = "roles/cloudfunctions.invoker"
  member         = "serviceAccount:${google_service_account.witness.email}"
}

resource "google_cloud_scheduler_job" "witness" {
  name             = "${var.project_name}-witness-schedule"
  schedule         = "*/1 * * * *"
  attempt_deadline = "60s"
  region           = var.gcp_region

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions2_function.witness.service_config[0].uri

    oidc_token {
      service_account_email = google_service_account.witness.email
    }
  }
}

# --- Cloud Workflows failover ---

resource "google_workflows_workflow" "failover" {
  name            = "${var.project_name}-failover"
  region          = var.gcp_region
  description     = "Automated failover workflow for hybrid k8s platform"
  service_account = google_service_account.witness.id

  source_contents = templatefile("${path.module}/workflows/failover.yaml", {
    pubsub_topic = google_pubsub_topic.failover.id
  })
}
