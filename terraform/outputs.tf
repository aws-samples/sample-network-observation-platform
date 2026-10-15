output "kms_key_arn" {
  description = "KMS key protecting the analysis plane."
  value       = local.kms_key_arn
}

output "analysis_bucket_name" {
  description = "Central S3 analysis bucket (created or referenced)."
  value       = try(module.tier1_consolidation[0].analysis_bucket_name, null)
}

output "glue_database_name" {
  description = "Glue database backing the Athena tables."
  value       = try(module.tier1_consolidation[0].glue_database_name, null)
}

output "athena_workgroup_name" {
  description = "Athena workgroup for consolidated-log queries."
  value       = try(module.tier1_consolidation[0].athena_workgroup_name, null)
}

output "firehose_stream_names" {
  description = "Amazon Data Firehose delivery streams created for log ingest."
  value       = try(module.tier1_consolidation[0].firehose_stream_names, null)
}

output "opensearch_endpoint" {
  description = "OpenSearch domain endpoint (created or referenced)."
  value       = try(module.tier2_visualisation[0].opensearch_endpoint, null)
}

output "opensearch_dashboards_url" {
  description = "OpenSearch Dashboards URL."
  value       = try(module.tier2_visualisation[0].dashboards_url, null)
}

output "cloudwatch_dashboard_name" {
  description = "Native CloudWatch quick-win dashboard."
  value       = try(module.tier2_visualisation[0].cloudwatch_dashboard_name, null)
}

output "dashboards_login_username" {
  description = "Initial OpenSearch Dashboards operator (Cognito). Open opensearch_dashboards_url and sign in as this user; the temporary password was emailed on apply."
  value       = try(module.tier2_visualisation[0].dashboards_login_username, null)
}

output "sns_topic_arn" {
  description = "SNS topic for hygiene reports and critical alerts."
  value       = try(module.tier3_ai_ops[0].sns_topic_arn, null)
}

output "devops_agent_space_arn" {
  description = "AWS DevOps Agent agent space ARN (null when disabled)."
  value       = try(module.devops_agent[0].agent_space_arn, null)
}

output "devops_agent_space_id" {
  description = "AWS DevOps Agent agent space ID."
  value       = try(module.devops_agent[0].agent_space_id, null)
}

output "devops_agent_space_region" {
  description = "Region the DevOps Agent agent space is deployed in."
  value       = try(module.devops_agent[0].region, null)
}

output "devops_agent_operator_role_arn" {
  description = "IAM role backing the DevOps Agent operator app (the surface where operators ask questions)."
  value       = try(module.devops_agent[0].operator_role_arn, null)
}

output "devops_agent_elevated_role_arn" {
  description = "Elevated (directed-actions) role — enable directed actions and register this on the association via the AWS CLI to allow operator-approved Athena queries."
  value       = try(module.devops_agent[0].elevated_role_arn, null)
}

output "rule_hygiene_function_name" {
  description = "Scheduled rule-hygiene report Lambda."
  value       = try(module.tier3_ai_ops[0].rule_hygiene_function_name, null)
}

output "baseline_alarm_names" {
  description = "Platform baseline CloudWatch alarms (self-coverage + investigation triggers)."
  value       = try(module.tier3_ai_ops[0].baseline_alarm_names, null)
}

output "demo_injector_function_name" {
  description = "Scheduled demo data-injector Lambda (null when disabled)."
  value       = try(module.demo_data_injector[0].injector_function_name, null)
}

output "opensearch_ingestion_pipeline_name" {
  description = "S3->OpenSearch ingestion pipeline (null when disabled)."
  value       = try(module.s3_to_opensearch[0].pipeline_name, null)
}

output "notification_queue_url" {
  description = "SQS queue that receives S3 object-created notifications for the ingestion pipeline. Brownfield deployments (create_analysis_bucket = false) wire their bucket's notification to this queue. Null when ingestion is disabled."
  value       = try(module.s3_to_opensearch[0].notification_queue_url, null)
}

output "opensearch_ingestion_role_arn" {
  description = "Ingestion pipeline role — map this in OpenSearch Security (FGAC) so it can write to the index."
  value       = try(module.s3_to_opensearch[0].pipeline_role_arn, null)
}
