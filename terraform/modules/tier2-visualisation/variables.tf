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

variable "create_opensearch_domain" {
  description = "Create opensearch domain."
  type        = bool
}

variable "existing_opensearch_domain_name" {
  description = "Existing opensearch domain name."
  type        = string
  default     = ""
}

variable "opensearch_engine_version" {
  description = "Opensearch engine version."
  type        = string
  default     = "OpenSearch_2.13"
}

variable "opensearch_instance_type" {
  description = "Opensearch instance type."
  type        = string
  default     = "m6g.large.search"
}

variable "opensearch_instance_count" {
  description = "Opensearch instance count."
  type        = number
  default     = 2
}

variable "opensearch_volume_size_gb" {
  description = "Opensearch volume size gb."
  type        = number
  default     = 100
}

variable "opensearch_subnet_ids" {
  description = "Opensearch subnet ids."
  type        = list(string)
  default     = []
}

variable "opensearch_security_group_ids" {
  description = "Opensearch security group ids."
  type        = list(string)
  default     = []
}

variable "opensearch_master_user_arn" {
  description = "Opensearch master user arn."
  # Must be an IAM role/user/root ARN, not an STS assumed-role session ARN. See the
  # root variable of the same name for the full explanation.
  type    = string
  default = ""
}

variable "create_cloudwatch_dashboard" {
  description = "Create cloudwatch dashboard."
  type        = bool
  default     = true
}

variable "iac_repo_url" {
  description = "Iac repo url."
  type        = string
  default     = ""
}

variable "athena_workgroup" {
  description = "Athena workgroup."
  type        = string
  default     = ""
}

variable "dx_connection_ids" {
  description = "Direct Connect connection IDs to surface health metrics/alarms for (DX has no flow logs, only CloudWatch metrics)."
  type        = list(string)
  default     = []
}

variable "sns_topic_arn" {
  description = "SNS topic for DX health alarms. Empty disables alarm actions."
  type        = string
  default     = ""
}

variable "enable_dashboards_cognito" {
  description = "Provision Amazon Cognito so OpenSearch Dashboards has a browser login (required for human access on an IAM-master-user FGAC domain)."
  type        = bool
  default     = true
}

variable "dashboards_notification_email" {
  description = "Email address to provision as the initial Dashboards operator. Cognito emails an invitation with a temporary password. Empty creates the user pool but no user."
  type        = string
  default     = ""
}

variable "auto_bootstrap" {
  description = "Invoke the bootstrap Lambda during apply to map FGAC roles and load the index template + dashboards. Disable only if you manage OpenSearch setup out of band."
  type        = bool
  default     = true
}

variable "audit_log_retention_days" {
  description = "Retention (days) for the OpenSearch audit and slow-log CloudWatch log groups. Defaults to 365; raise for compliance."
  type        = number
  default     = 365
}

variable "enable_opensearch_slow_logs" {
  description = "Publish OpenSearch SEARCH_SLOW_LOGS and INDEX_SLOW_LOGS to CloudWatch (needs the bootstrap-set per-index thresholds to emit). Off by default; enable for production performance forensics."
  type        = bool
  default     = false
}

variable "enable_cognito_mfa" {
  description = "Enforce TOTP MFA and enable Cognito advanced security (threat protection) on the Dashboards user pool. Off by default for a low-friction PoC; on for production. Note: advanced security may require the Cognito Plus feature tier on the account."
  type        = bool
  default     = false
}

variable "firewall_name" {
  description = "AWS Network Firewall name. Used to query the native AWS/NetworkFirewall CloudWatch metrics for the quick-view dashboard's firewall widgets. Empty omits those widgets."
  type        = string
  default     = ""
}

variable "transit_gateway_id" {
  description = "Transit Gateway ID. Used to query the native AWS/TransitGateway CloudWatch metrics for the quick-view dashboard's TGW widgets. Empty omits those widgets."
  type        = string
  default     = ""
}
