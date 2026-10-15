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

variable "create_analysis_bucket" {
  description = "Create analysis bucket."
  type        = bool
}

variable "existing_analysis_bucket_name" {
  description = "Existing analysis bucket name."
  type        = string
  default     = ""
}

variable "analysis_bucket_force_destroy" {
  description = "Allow `tofu destroy` to empty and delete the analysis bucket even when it holds objects/versions. True eases PoC teardown; set false (hardened example) to prevent a destroy from silently emptying versioned telemetry."
  type        = bool
  default     = true
}

variable "existing_nfw_flow_logs_bucket_name" {
  description = "Existing nfw flow logs bucket name."
  type        = string
  default     = ""
}

variable "nfw_alert_log_group_name" {
  description = "Nfw alert log group name."
  type        = string
  default     = ""
}

variable "dns_firewall_log_group_name" {
  description = "Dns firewall log group name."
  type        = string
  default     = ""
}

variable "create_vpc_flow_logs" {
  description = "Create vpc flow logs."
  type        = bool
  default     = false
}

variable "vpc_ids" {
  description = "Vpc ids."
  type        = list(string)
  default     = []
}

variable "existing_vpc_flow_log_group_names" {
  description = "Existing vpc flow log group names."
  type        = list(string)
  default     = []
}

variable "create_tgw_flow_logs" {
  description = "Create tgw flow logs."
  type        = bool
  default     = false
}

variable "transit_gateway_id" {
  description = "Transit gateway id."
  type        = string
  default     = ""
}

variable "existing_tgw_flow_log_group_names" {
  description = "Existing tgw flow log group names."
  type        = list(string)
  default     = []
}

variable "create_cloudtrail" {
  description = "Create cloudtrail."
  type        = bool
  default     = false
}

variable "existing_cloudtrail_log_group_name" {
  description = "Existing cloudtrail log group name."
  type        = string
  default     = ""
}

variable "create_athena_workgroup" {
  description = "Create athena workgroup."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Log retention days."
  type        = number
  default     = 365
}

variable "s3_transition_ia_days" {
  description = "S3 transition ia days."
  type        = number
  default     = 90
}

variable "s3_transition_glacier_days" {
  description = "S3 transition glacier days."
  type        = number
  default     = 180
}

variable "enable_s3_access_logging" {
  description = "Enable S3 server access logging on the analysis bucket (delivered to a dedicated log bucket). Additive and low-cost; on by default."
  type        = bool
  default     = true
}

variable "existing_access_log_bucket_name" {
  description = "Deliver S3 server access logs to this existing central log bucket instead of creating a dedicated one. Empty creates a dedicated <prefix>-access-logs-<account> bucket."
  type        = string
  default     = ""
}

variable "audit_log_retention_days" {
  description = "Retention (days) for audit-grade logs: the S3 access-log bucket lifecycle expiration and (via the root) the OpenSearch audit/slow-log and API Gateway access-log groups. Defaults to 365; raise for compliance."
  type        = number
  default     = 365
}

variable "enable_cloudtrail_data_events" {
  description = "Create a CloudTrail trail capturing S3 data events (object reads/writes) on the analysis bucket, delivered to a dedicated trail bucket. Off by default (per-event cost); enable in production for IAM-attributed object-access auditing."
  type        = bool
  default     = false
}
