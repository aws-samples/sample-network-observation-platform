variable "name_prefix" {
  description = "Name prefix."
  type        = string
}

variable "tags" {
  description = "Tags."
  type        = map(string)
  default     = {}
}

variable "kms_key_arn" {
  description = "Kms key arn."
  type        = string
}

variable "firehose_stream_name" {
  description = "Consolidation Firehose stream to inject source-shaped records into. Empty to skip."
  type        = string
  default     = ""
}

variable "firehose_stream_arn" {
  description = "ARN of the Firehose stream (for the IAM policy). Empty to skip."
  type        = string
  default     = ""
}

variable "opensearch_endpoint" {
  description = "OpenSearch domain endpoint to bulk-index normalised docs into. Empty to skip."
  type        = string
  default     = ""
}

variable "opensearch_domain_arn" {
  description = "ARN of the OpenSearch domain (for the IAM policy). Empty to skip."
  type        = string
  default     = ""
}

variable "flow_logs_bucket_name" {
  description = "NFW flow-log S3 bucket. When set, nfw_flow events are delivered here as gzipped EVE JSON (as a real firewall does), read in place by the nfw_flow_s3 table. Empty to skip (nfw_flow then rides the Firehose path)."
  type        = string
  default     = ""
}

variable "firewall_name" {
  description = "Firewall name used in the synthetic flow-log S3 key path (cosmetic; matches the real NFW delivery layout)."
  type        = string
  default     = "firewall"
}

variable "schedule_expression" {
  description = "EventBridge schedule for the injector."
  type        = string
  default     = "rate(5 minutes)"
}

variable "events_per_run" {
  description = "Number of synthetic events generated per invocation."
  type        = number
  default     = 500
}

variable "window_hours" {
  description = "Spread each run's events over the last N hours."
  type        = number
  default     = 1
}

variable "log_retention_days" {
  description = "Log retention days."
  type        = number
  default     = 365
}
