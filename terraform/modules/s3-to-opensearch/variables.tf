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

variable "analysis_bucket_name" {
  description = "S3 analysis bucket that Firehose writes normalised Parquet objects into."
  type        = string
}

variable "analysis_bucket_arn" {
  description = "Analysis bucket arn."
  type        = string
}

variable "consolidated_prefix" {
  description = "Key prefix under which the normalised Parquet objects are written."
  type        = string
  default     = "consolidated/"
}

variable "manage_bucket_notification" {
  description = "Let this module create the S3 -> SQS event notification on the analysis bucket. Set true only when the platform owns the bucket; managing notifications on a pre-existing bucket can overwrite existing ones."
  type        = bool
  default     = true
}

variable "opensearch_endpoint" {
  description = "OpenSearch domain endpoint (host, no scheme)."
  type        = string
}

variable "opensearch_domain_arn" {
  description = "Opensearch domain arn."
  type        = string
}

variable "opensearch_index_name" {
  description = "Base index name; a daily suffix is appended (network-events-YYYY.MM.dd)."
  type        = string
  default     = "network-events"
}

variable "opensearch_subnet_ids" {
  description = "Subnets for the pipeline network interfaces when the OpenSearch domain is VPC-attached."
  type        = list(string)
  default     = []
}

variable "opensearch_security_group_ids" {
  description = "Opensearch security group ids."
  type        = list(string)
  default     = []
}

variable "min_units" {
  description = "Minimum OpenSearch Compute Units (OCUs) for the ingestion pipeline."
  type        = number
  default     = 1
}

variable "max_units" {
  description = "Maximum OCUs for the ingestion pipeline."
  type        = number
  default     = 4
}

variable "log_retention_days" {
  description = "Log retention days."
  type        = number
  default     = 365
}
