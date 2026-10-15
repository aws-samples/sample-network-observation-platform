output "analysis_bucket_name" {
  description = "Central S3 analysis bucket (created or referenced)."
  value       = local.analysis_bucket_name
}

output "analysis_bucket_arn" {
  description = "ARN of the central S3 analysis bucket."
  value       = "arn:${local.partition}:s3:::${local.analysis_bucket_name}"
}

output "consolidated_prefix" {
  description = "S3 key prefix under which normalised Parquet objects are written."
  value       = local.consolidated_prefix
}

output "glue_database_name" {
  description = "Glue database backing the Athena tables."
  value       = aws_glue_catalog_database.netobs.name
}

output "glue_table_name" {
  description = "Normalised network-events table."
  value       = aws_glue_catalog_table.network_events.name
}

output "athena_workgroup_name" {
  description = "Athena workgroup (null when create_athena_workgroup = false)."
  value       = var.create_athena_workgroup ? aws_athena_workgroup.netobs[0].name : null
}

output "athena_agent_workgroup_name" {
  description = "Managed-query-results Athena workgroup for the DevOps Agent (no S3 write needed). Null when create_athena_workgroup = false."
  value       = var.create_athena_workgroup ? aws_athena_workgroup.agent[0].name : null
}

output "firehose_stream_names" {
  description = "Amazon Data Firehose delivery streams."
  value       = [aws_kinesis_firehose_delivery_stream.consolidated.name]
}

output "firehose_stream_name" {
  description = "Consolidation Firehose delivery stream name."
  value       = aws_kinesis_firehose_delivery_stream.consolidated.name
}

output "firehose_stream_arn" {
  description = "Consolidation Firehose delivery stream ARN."
  value       = aws_kinesis_firehose_delivery_stream.consolidated.arn
}

output "subscribed_log_groups" {
  description = "CloudWatch log groups forwarded into the consolidation path."
  value       = tolist(local.subscribed_log_groups)
}

output "access_log_bucket_name" {
  description = "S3 server-access-log bucket for the analysis bucket (null when logging is disabled or an external log bucket is used)."
  value       = local.create_access_log_bucket ? aws_s3_bucket.access_logs[0].id : (var.existing_access_log_bucket_name != "" ? var.existing_access_log_bucket_name : null)
}
