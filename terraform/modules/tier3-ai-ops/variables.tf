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

variable "firewall_name" {
  description = "Firewall name."
  type        = string
  default     = ""
}

variable "enable_cloudwatch_investigations" {
  description = "Enable cloudwatch investigations."
  type        = bool
  default     = true
}

variable "investigation_alarm_names" {
  description = "Investigation alarm names."
  type        = list(string)
  default     = []
}

variable "enable_baseline_alarms" {
  description = "Enable baseline alarms."
  type        = bool
  default     = true
}

variable "monitor_opensearch_domain" {
  description = "Monitor opensearch domain."
  type        = bool
  default     = false
}

variable "monitor_firehose" {
  description = "Monitor firehose."
  type        = bool
  default     = false
}

variable "opensearch_free_storage_alarm_mb" {
  description = "Opensearch free storage alarm mb."
  type        = number
  default     = 5120
}

variable "firehose_freshness_alarm_seconds" {
  description = "Firehose freshness alarm seconds."
  type        = number
  default     = 900
}

variable "create_sns_topic" {
  description = "Create sns topic."
  type        = bool
  default     = true
}

variable "existing_sns_topic_arn" {
  description = "Existing sns topic arn."
  type        = string
  default     = ""
}

variable "notification_email" {
  description = "Notification email."
  type        = string
  default     = ""
}

variable "rule_hygiene_schedule" {
  description = "Rule hygiene schedule."
  type        = string
  default     = "rate(7 days)"
}

variable "zero_hit_window_days" {
  description = "Zero hit window days."
  type        = number
  default     = 30
}

variable "log_retention_days" {
  description = "Log retention days."
  type        = number
  default     = 365
}

variable "analysis_bucket_name" {
  description = "Analysis bucket name."
  type        = string
  default     = ""
}

variable "glue_database_name" {
  description = "Glue database name."
  type        = string
  default     = ""
}

variable "athena_workgroup" {
  description = "Athena workgroup."
  type        = string
  default     = ""
}

variable "athena_results_prefix" {
  description = "Athena results prefix."
  type        = string
  default     = "athena-results/rule-hygiene"
}
