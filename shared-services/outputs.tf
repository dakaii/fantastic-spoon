output "route53_zone_id" {
  description = "Route53 hosted zone ID (empty if no domain configured)"
  value       = var.domain_name != "" ? aws_route53_zone.main[0].zone_id : null
}

output "route53_name_servers" {
  description = "NS records to set at your domain registrar"
  value       = var.domain_name != "" ? aws_route53_zone.main[0].name_servers : null
}

output "witness_lambda_arn" {
  description = "Lambda witness function ARN"
  value       = aws_lambda_function.witness.arn
}

output "failover_state_machine_arn" {
  description = "Step Functions failover workflow ARN"
  value       = aws_sfn_state_machine.failover.arn
}

output "sns_topic_arn" {
  description = "SNS topic for failover alerts"
  value       = aws_sns_topic.failover.arn
}
