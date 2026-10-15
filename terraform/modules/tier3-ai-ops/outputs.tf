output "sns_topic_arn" {
  description = "SNS topic for hygiene reports and critical alerts (created or referenced)."
  value       = local.sns_topic_arn
}

output "rule_hygiene_function_name" {
  description = "Scheduled rule-hygiene report Lambda."
  value       = aws_lambda_function.rule_hygiene.function_name
}

output "baseline_alarm_names" {
  description = "Platform baseline CloudWatch alarms feeding notifications and investigations."
  value       = local.baseline_alarm_names
}
