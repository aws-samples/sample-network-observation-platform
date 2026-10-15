variable "name_prefix" {
  description = "Name prefix."
  type        = string
}

variable "tags" {
  description = "Tags."
  type        = map(string)
  default     = {}
}

variable "agent_space_name" {
  description = "Name of the AWS DevOps Agent agent space."
  type        = string
  default     = "network-observation"
}

variable "agent_space_description" {
  description = "Description shown on the agent space / operator app."
  type        = string
  default     = "Network Observation platform — AI-assisted investigation of AWS Network Firewall, flow and DNS telemetry."
}

variable "enable_assets" {
  description = "Create the network-firefighter skill, custom agent and scheduled trigger (Part 4)."
  type        = bool
  default     = true
}

variable "trigger_schedule" {
  description = "Schedule expression for the scheduled network-firefighter run."
  type        = string
  default     = "rate(1 day)"
}

variable "glue_database_name" {
  description = "Glue database for the consolidated logs, referenced in the skill guidance."
  type        = string
  default     = ""
}

variable "opensearch_dashboards_url" {
  description = "OpenSearch Dashboards URL, referenced in the skill guidance."
  type        = string
  default     = ""
}

# --- Read access to the analysis plane, so the agent can investigate the data --- #

variable "grant_data_access" {
  description = "Grant the agent-space role read access to the analysis plane (Athena, Glue, the analysis S3 bucket, KMS, and OpenSearch) so it can query the network telemetry directly rather than only via operator-approved calls."
  type        = bool
  default     = true
}

variable "enable_directed_actions" {
  description = "Create the elevated (directed-actions) IAM role the agent assumes for operator-approved Athena query execution in environments that gate query execution behind approval. The role is scoped to the Athena query path (Athena queries, Glue/S3 reads, KMS, and query results only under athena-results/) and grants no infrastructure, firewall, or lake-data mutation. Enabling directed actions on the agent space and registering this role are done via the AWS CLI/console (not yet in awscc)."
  type        = bool
  default     = true
}

variable "platform_region" {
  description = "Region the analysis plane (Athena/Glue/S3/OpenSearch) lives in — may differ from the agent's Region."
  type        = string
  default     = ""
}

variable "analysis_bucket_name" {
  description = "Analysis S3 bucket the agent may read (and write Athena results to)."
  type        = string
  default     = ""
}

variable "flow_logs_bucket_name" {
  description = "Existing NFW flow-log bucket catalogued in place as the nfw_flow_s3 Athena table. Granted read-only so the agent can query/verify flow logs. Empty to skip."
  type        = string
  default     = ""
}

variable "athena_workgroup" {
  description = "Athena workgroup the agent may run queries in."
  type        = string
  default     = ""
}

variable "athena_agent_workgroup" {
  description = "Managed-query-results Athena workgroup for the agent. With managed results the agent needs no s3:PutObject (the guardrail blocks it), so it can run read-only SELECTs natively. When set, the skill instructs the agent to use this workgroup."
  type        = string
  default     = ""
}

variable "kms_key_arn" {
  description = "CMK protecting the analysis bucket and Athena results."
  type        = string
  default     = ""
}

variable "opensearch_domain_arn" {
  description = "OpenSearch domain ARN the agent may read (es:ESHttpGet/ESHttpPost). Also map this role in OpenSearch FGAC."
  type        = string
  default     = ""
}
