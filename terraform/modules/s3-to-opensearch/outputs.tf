output "pipeline_name" {
  description = "OpenSearch Ingestion pipeline name."
  value       = aws_osis_pipeline.this.pipeline_name
}

output "pipeline_role_arn" {
  description = "Pipeline IAM role ARN — map this in OpenSearch Security (FGAC) so it can write to the index."
  value       = aws_iam_role.pipeline.arn
}

output "notification_queue_url" {
  description = "SQS queue receiving S3 object-created notifications."
  value       = aws_sqs_queue.notifications.url
}
