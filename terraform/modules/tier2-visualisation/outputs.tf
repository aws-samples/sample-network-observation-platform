output "opensearch_endpoint" {
  description = "OpenSearch domain endpoint (created or referenced)."
  value       = local.domain_endpoint
}

output "opensearch_arn" {
  description = "OpenSearch domain ARN."
  value       = local.domain_arn
}

output "dashboards_url" {
  description = "OpenSearch Dashboards URL."
  value       = local.domain_dashboards_url
}

output "bootstrap_function_name" {
  description = "Lambda that loads the index template and imports the dashboards. Invoke once the role is mapped in OpenSearch Security."
  value       = aws_lambda_function.bootstrap.function_name
}

output "cloudwatch_dashboard_name" {
  description = "Native CloudWatch quick-view dashboard (null when disabled)."
  value       = var.create_cloudwatch_dashboard ? aws_cloudwatch_dashboard.quick_view[0].dashboard_name : null
}

output "dashboards_cognito_user_pool_id" {
  description = "Cognito user pool backing the OpenSearch Dashboards login (null when Cognito is disabled)."
  value       = local.cognito_enabled ? aws_cognito_user_pool.dashboards[0].id : null
}

output "dashboards_login_username" {
  description = "Initial Dashboards operator username (the invited email), or null when none was provisioned."
  value       = local.cognito_enabled && var.dashboards_notification_email != "" ? var.dashboards_notification_email : null
}
