output "standby_instance_names" {
  value = { for name, inst in google_compute_instance.standby : name => inst.name }
}

output "standby_public_ips" {
  value = { for name, inst in google_compute_instance.standby : name => inst.network_interface[0].access_config[0].nat_ip }
}

output "standby_k3s_api_endpoints" {
  value = [
    for name, inst in google_compute_instance.standby :
    "https://${inst.network_interface[0].access_config[0].nat_ip}:6443"
    if inst.labels.role == "server"
  ]
}

output "backup_bucket_name" {
  description = "GCS bucket for Velero backups"
  value       = google_storage_bucket.backups.name
}

output "velero_access_key_id" {
  description = "GCS HMAC access key for Velero (S3-compatible API)"
  value       = google_storage_hmac_key.velero.access_id
  sensitive   = true
}

output "velero_secret_access_key" {
  description = "GCS HMAC secret for Velero"
  value       = google_storage_hmac_key.velero.secret
  sensitive   = true
}

output "standby_lb_ip" {
  description = "External TCP load balancer IP for standby ingress (Cloud DNS failover target)"
  value       = google_compute_forwarding_rule.standby_https.ip_address
}

output "ansible_inventory" {
  value = yamlencode({
    all = {
      vars = {
        ansible_user            = "ubuntu"
        ansible_ssh_common_args = "-o StrictHostKeyChecking=no"
        k3s_version             = "v1.29.5+k3s1"
        cluster_name            = "standby"
        cluster_profile         = "standby"
        provisioner             = "gcp-compute"
        ingress_host            = google_compute_forwarding_rule.standby_https.ip_address
        k3s_api_host            = [for name, inst in google_compute_instance.standby : inst.network_interface[0].access_config[0].nat_ip if inst.labels.role == "server"][0]
      }
      children = {
        k3s_server = {
          hosts = {
            for name, inst in google_compute_instance.standby :
            name => {
              ansible_host = inst.network_interface[0].access_config[0].nat_ip
              node_role    = "server"
            } if inst.labels.role == "server"
          }
        }
        k3s_agent = {
          hosts = {
            for name, inst in google_compute_instance.standby :
            name => {
              ansible_host = inst.network_interface[0].access_config[0].nat_ip
              node_role    = "agent"
            } if inst.labels.role == "agent"
          }
        }
      }
    }
  })
}

output "cluster_meta" {
  value = {
    provisioner       = "gcp-compute"
    cluster_name      = "standby"
    cluster_profile   = "standby"
    ingress_host      = google_compute_forwarding_rule.standby_https.ip_address
    k3s_api_host      = [for name, inst in google_compute_instance.standby : inst.network_interface[0].access_config[0].nat_ip if inst.labels.role == "server"][0]
    velero_bucket     = google_storage_bucket.backups.name
    velero_provider   = "gcp"
    velero_region     = "auto"
    velero_access_key = google_storage_hmac_key.velero.access_id
    velero_secret_key = google_storage_hmac_key.velero.secret
    gcp_project       = var.gcp_project
    gcp_region        = var.gcp_region
  }
  sensitive = true
}

output "vpc_name" {
  value = google_compute_network.standby.name
}
