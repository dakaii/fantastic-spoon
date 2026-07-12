output "dns_managed_zone_name" {
  description = "Cloud DNS managed zone name (empty if no domain configured)"
  value       = var.domain_name != "" ? google_dns_managed_zone.main[0].name : null
}

output "dns_name_servers" {
  description = "NS records to set at your domain registrar"
  value       = var.domain_name != "" ? google_dns_managed_zone.main[0].name_servers : null
}

output "witness_function_name" {
  description = "Cloud Function witness name"
  value       = var.enable_witness ? google_cloudfunctions2_function.witness[0].name : null
}

output "failover_workflow_id" {
  description = "Cloud Workflows failover workflow ID"
  value       = var.enable_witness ? google_workflows_workflow.failover[0].id : null
}

output "pubsub_topic_id" {
  description = "Pub/Sub topic for failover alerts"
  value       = var.enable_witness ? google_pubsub_topic.failover[0].id : null
}

output "app_dns_name" {
  description = "Fully qualified DNS name for the app (when domain configured)"
  value       = var.domain_name != "" ? local.dns_record_name : null
}
