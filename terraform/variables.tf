###############################################################################
# Global
###############################################################################

variable "name_prefix" {
  description = "Prefix applied to all resource names created by the platform."
  type        = string
  default     = "netobs"
}

variable "tags" {
  description = "Tags applied to every resource that supports tagging."
  type        = map(string)
  default = {
    Project   = "network-observation-platform"
    Owner     = "network-engineering"
    ManagedBy = "terraform"
  }
}

variable "kms_key_arn" {
  description = <<-EOT
    Customer-managed AWS KMS key ARN used to encrypt the analysis bucket, delivery
    streams, OpenSearch domain and SNS topic. Leave empty to let the platform create
    a dedicated CMK. All platform data stores are encrypted with a customer-managed key.
  EOT
  type        = string
  default     = ""
}

variable "enable_tier1_consolidation" {
  description = "Deploy Tier 1 (log consolidation: Firehose, S3, Glue, Athena)."
  type        = bool
  default     = true
}

variable "enable_tier2_visualisation" {
  description = "Deploy Tier 2 (OpenSearch Dashboards and the CloudWatch dashboard)."
  type        = bool
  default     = true
}

variable "enable_tier3_ai_ops" {
  description = "Deploy Tier 3 (CloudWatch investigations and the rule-hygiene Lambda)."
  type        = bool
  default     = true
}

###############################################################################
# Tier 1 — Consolidation. Every input follows the existing-vs-new pattern:
#   create_* = true   -> the platform provisions the resource
#   create_* = false  -> the platform reads the existing resource by identifier
###############################################################################

# Central analysis bucket (destination for all normalised logs)
variable "create_analysis_bucket" {
  description = "Create the central S3 analysis bucket. If false, existing_analysis_bucket_name must be set."
  type        = bool
  default     = true
}

variable "existing_analysis_bucket_name" {
  description = "Name of an existing S3 bucket to use as the analysis store (used when create_analysis_bucket = false)."
  type        = string
  default     = ""
}

variable "analysis_bucket_force_destroy" {
  description = "Allow `tofu destroy` to empty and delete the platform-created analysis bucket even when it holds objects/versions. True (default) eases PoC teardown; the hardened example sets it false so a destroy cannot silently empty versioned telemetry."
  type        = bool
  default     = true
}

# AWS Network Firewall flow logs (already delivered to S3 by the landing zone)
variable "existing_nfw_flow_logs_bucket_name" {
  description = "Existing S3 bucket that already receives AWS Network Firewall flow logs (e.g. example-nfw-flow-logs). Empty to skip flow-log ingest."
  type        = string
  default     = ""
}

# AWS Network Firewall alert logs (CloudWatch Logs group to subscribe to Firehose)
variable "nfw_alert_log_group_name" {
  description = "Existing CloudWatch Logs group receiving AWS Network Firewall alert logs (e.g. /aws/network-firewall/egress-ew/alert). Empty to skip alert-log ingest."
  type        = string
  default     = ""
}

# Route 53 Resolver DNS Firewall query logs
variable "dns_firewall_log_group_name" {
  description = "Existing CloudWatch Logs group receiving Route 53 Resolver DNS Firewall query logs (e.g. example-dns-query-logs). Empty to skip DNS-log ingest."
  type        = string
  default     = ""
}

# Transit Gateway Flow Logs — the primary east-west source in a hub-and-spoke design,
# and how traffic crossing Direct Connect / VPN attachments is seen (DX has no flow logs).
variable "create_tgw_flow_logs" {
  description = "Create Transit Gateway Flow Logs on transit_gateway_id and feed them into the platform."
  type        = bool
  default     = false
}

variable "transit_gateway_id" {
  description = "Transit Gateway ID to enable flow logs on (used when create_tgw_flow_logs = true)."
  type        = string
  default     = ""
}

variable "existing_tgw_flow_log_group_names" {
  description = "Existing CloudWatch Logs groups that already receive TGW Flow Logs (used when create_tgw_flow_logs = false). Create them with the platform's custom format — see the README."
  type        = list(string)
  default     = []
}

# VPC Flow Logs — create on given VPCs, or subscribe to existing flow-log groups
variable "create_vpc_flow_logs" {
  description = "Create VPC Flow Logs on the VPCs listed in vpc_ids and deliver them to the analysis plane."
  type        = bool
  default     = false
}

variable "vpc_ids" {
  description = "VPC IDs on which to create flow logs (used when create_vpc_flow_logs = true)."
  type        = list(string)
  default     = []
}

variable "existing_vpc_flow_log_group_names" {
  description = "Existing CloudWatch Logs groups that already receive VPC Flow Logs (used when create_vpc_flow_logs = false)."
  type        = list(string)
  default     = []
}

# CloudTrail
variable "create_cloudtrail" {
  description = "Create an organization/account CloudTrail feeding the analysis plane. If false, existing_cloudtrail_log_group_name may be set to subscribe an existing trail's log group."
  type        = bool
  default     = false
}

variable "existing_cloudtrail_log_group_name" {
  description = "Existing CloudWatch Logs group receiving CloudTrail events (used when create_cloudtrail = false). Empty to skip CloudTrail ingest."
  type        = string
  default     = ""
}

# IAM Access Analyzer
variable "create_access_analyzer" {
  description = "Create an account-scope IAM Access Analyzer (addresses the 'IAM Access Analyzer Not Enabled' control). Off by default: this platform typically deploys into an existing Security Tooling / Log Archive account that already has an account analyzer, and AWS allows only one ACCOUNT analyzer per Region (a second fails with a quota error). Set true for a standalone/greenfield account with no existing analyzer."
  type        = bool
  default     = false
}

# Analytics
variable "create_athena_workgroup" {
  description = "Create a dedicated Athena workgroup and named queries over the consolidated logs."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for platform-created log groups (Lambda, Firehose errors). Defaults to 365 to satisfy the >= 1 year retention control; lower it if a shorter window is acceptable."
  type        = number
  default     = 365
}

variable "s3_transition_ia_days" {
  description = "Days before analysis-bucket objects transition to S3 Standard-IA."
  type        = number
  default     = 90
}

variable "s3_transition_glacier_days" {
  description = "Days before analysis-bucket objects transition to Glacier."
  type        = number
  default     = 180
}

###############################################################################
# Tier 2 — Visualisation
###############################################################################

variable "create_opensearch_domain" {
  description = "Create an Amazon OpenSearch Service domain. If false, existing_opensearch_domain_name must be set."
  type        = bool
  default     = true
}

variable "existing_opensearch_domain_name" {
  description = "Name of an existing OpenSearch Service domain to reuse (used when create_opensearch_domain = false)."
  type        = string
  default     = ""
}

variable "opensearch_engine_version" {
  description = "OpenSearch engine version for a newly created domain."
  type        = string
  default     = "OpenSearch_2.13"
}

variable "opensearch_instance_type" {
  description = "Data node instance type for a newly created domain."
  type        = string
  default     = "m6g.large.search"
}

variable "opensearch_instance_count" {
  description = "Data node count for a newly created domain."
  type        = number
  default     = 2
}

variable "opensearch_volume_size_gb" {
  description = "EBS volume size per data node (GiB) for a newly created domain."
  type        = number
  default     = 100
}

variable "opensearch_subnet_ids" {
  description = "Subnet IDs for a VPC-attached OpenSearch domain. An EMPTY list creates a PUBLIC-endpoint domain, reachable from the internet (fine-grained access control and Cognito login still apply); set subnet IDs to place the domain in private VPC subnets reachable only from inside the VPC."
  type        = list(string)
  default     = []
}

variable "opensearch_security_group_ids" {
  description = "Security group IDs for a VPC-attached OpenSearch domain."
  type        = list(string)
  default     = []
}

variable "opensearch_master_user_arn" {
  description = <<-EOT
    IAM ARN granted OpenSearch fine-grained access control master access. Must be an
    IAM role/user/root ARN (for example arn:aws:iam::<account>:role/<name>), NOT an STS
    assumed-role session ARN. When left empty the platform falls back to the deploying
    caller's ARN, which only works if you deploy as a plain IAM user or role; under an
    assumed role or IAM Identity Center/SSO login the caller ARN is an STS session ARN
    (arn:aws:sts::<account>:assumed-role/<role>/<session>) that OpenSearch rejects. Set
    this explicitly in those cases.
  EOT
  type        = string
  default     = ""
}

variable "enable_dashboards_cognito" {
  description = <<-EOT
    Provision Amazon Cognito so OpenSearch Dashboards has a browser login. On by default:
    with fine-grained access control and an IAM master user, the Dashboards endpoint has
    no interactive login otherwise, so a human cannot open the dashboards. Turn off only
    if you front the domain with SAML/IAM Identity Center or your own signing proxy.
  EOT
  type        = bool
  default     = true
}

variable "dashboards_notification_email" {
  description = <<-EOT
    Email address provisioned as the initial OpenSearch Dashboards operator in Cognito.
    Cognito emails an invitation with a temporary password; the user sets a permanent
    password on first sign-in. When empty, falls back to notification_email.
  EOT
  type        = string
  default     = ""
}

variable "auto_bootstrap" {
  description = <<-EOT
    Automatically run the OpenSearch bootstrap during apply: map the required FGAC roles
    (Cognito login, ingestion pipeline, injector, admin principal) and load the index
    template and dashboards. Disable only if you manage OpenSearch setup out of band.
  EOT
  type        = bool
  default     = true
}

variable "create_cloudwatch_dashboard" {
  description = "Create the native CloudWatch dashboard quick-win view."
  type        = bool
  default     = true
}

variable "iac_repo_url" {
  description = "Base URL of the firewall rules IaC repository, used for the log-to-rule deep link (e.g. https://git.example.com/network/network-firewall-rules)."
  type        = string
  default     = ""
}

variable "dx_connection_ids" {
  description = "Direct Connect connection IDs to add health metrics and alarms for (state, light levels, CRC errors). DX has no flow logs — these are CloudWatch metrics only."
  type        = list(string)
  default     = []
}

# S3 -> OpenSearch indexing (OpenSearch Ingestion pipeline). Requires both
# Tier 1 and Tier 2. This is what populates the OpenSearch dashboards from real traffic;
# the mock-data generator is only for demo accounts.
variable "enable_opensearch_ingestion" {
  description = "Deploy the OpenSearch Ingestion pipeline that streams the consolidated Parquet from S3 into the OpenSearch index."
  type        = bool
  default     = true
}

variable "opensearch_ingestion_min_units" {
  description = "Minimum OCUs for the ingestion pipeline."
  type        = number
  default     = 1
}

variable "opensearch_ingestion_max_units" {
  description = "Maximum OCUs for the ingestion pipeline."
  type        = number
  default     = 4
}

###############################################################################
# Tier 3 — AI-assisted operations
###############################################################################

variable "firewall_name" {
  description = "Name of the AWS Network Firewall whose stateful rule SIDs the rule-hygiene report reconciles against the SIDs seen in the logs."
  type        = string
  default     = ""
}

variable "enable_cloudwatch_investigations" {
  description = "Wire alarms (baseline + any in investigation_alarm_names) to Amazon CloudWatch investigations via EventBridge."
  type        = bool
  default     = true
}

variable "enable_baseline_alarms" {
  description = <<-EOT
    Create baseline CloudWatch alarms for the deployed tiers (OpenSearch cluster status,
    index-writes-blocked, free storage; Firehose delivery freshness and success), wired
    to the SNS topic and fed into the investigation rule. Gives a greenfield deployment
    self-coverage instead of no alarms at all.
  EOT
  type        = bool
  default     = true
}

variable "investigation_alarm_names" {
  description = "Names of existing CloudWatch alarms that should start an investigation when they enter ALARM (e.g. the deny-rule-stopped-firing alarm)."
  type        = list(string)
  default     = []
}

variable "create_sns_topic" {
  description = "Create the SNS topic for hygiene reports and critical alerts. If false, existing_sns_topic_arn must be set."
  type        = bool
  default     = true
}

variable "existing_sns_topic_arn" {
  description = "ARN of an existing SNS topic (used when create_sns_topic = false)."
  type        = string
  default     = ""
}

variable "notification_email" {
  description = "Optional email address subscribed to the SNS topic for hygiene reports. Empty to manage subscriptions elsewhere."
  type        = string
  default     = ""
}

variable "rule_hygiene_schedule" {
  description = "EventBridge Scheduler expression for the rule-hygiene report."
  type        = string
  default     = "rate(7 days)"
}

variable "zero_hit_window_days" {
  description = "Window over which a stateful rule with zero hits is flagged as a retirement candidate."
  type        = number
  default     = 30
}

###############################################################################
# AWS DevOps Agent (Tier 3, real). Provisions an agent space + operator app (the
# surface where operators ask questions and an AI investigates the account) plus a
# network-firefighter skill/custom-agent/trigger. Uses the awscc provider and must be
# deployed in a DevOps-Agent-supported Region.
###############################################################################

variable "enable_devops_agent" {
  description = <<-EOT
    Deploy AWS DevOps Agent: an agent space, operator app and a network-firefighter
    skill/custom-agent/scheduled trigger. Requires the awscc provider and a supported
    Region (set devops_agent_region). Incurs its own cost. On by default so a full
    deployment yields an agent you can ask questions of; set false to skip.
  EOT
  type        = bool
  default     = true
}

variable "devops_agent_region" {
  description = <<-EOT
    Region for the DevOps Agent agent space. AWS DevOps Agent is available only in
    us-east-1, us-west-2, ap-southeast-2, ap-northeast-1, eu-central-1 and eu-west-1.
    When the platform runs elsewhere (for example London/eu-west-2), the agent space is
    created here and still monitors this account. Defaults to Europe (Ireland).
  EOT
  type        = string
  default     = "eu-west-1"
}

variable "devops_agent_space_name" {
  description = "Name of the DevOps Agent agent space."
  type        = string
  default     = "network-observation"
}

variable "devops_agent_space_description" {
  description = "Description shown on the agent space / operator app."
  type        = string
  default     = "Network Observation platform — AI-assisted investigation of AWS Network Firewall, flow and DNS telemetry."
}

variable "devops_agent_enable_assets" {
  description = "Create the network-firefighter skill, custom agent and scheduled trigger."
  type        = bool
  default     = true
}

variable "devops_agent_trigger_schedule" {
  description = "Schedule expression for the periodic network-firefighter run."
  type        = string
  default     = "rate(1 day)"
}

variable "devops_agent_directed_actions" {
  description = <<-EOT
    Create the elevated (directed-actions) IAM role the DevOps Agent assumes for
    operator-approved Athena query execution in environments that gate query execution
    behind approval. The role is scoped to the Athena query path (Athena queries, Glue/S3
    reads, KMS, and writing query results only under the athena-results/ prefix); it grants
    no infrastructure, firewall, or lake-data mutation. Enabling directed actions on the agent space and
    registering this role on the association are done via the AWS CLI/console because
    the awscc provider does not yet expose those fields — see the docs.
  EOT
  type        = bool
  default     = true
}

variable "devops_agent_grant_data_access" {
  description = <<-EOT
    Grant the DevOps Agent's role read access to the analysis plane (Athena, Glue, the
    analysis S3 bucket, KMS and OpenSearch) so it can query the network telemetry
    directly. Without this the agent can still reason but must fall back to
    operator-approved calls to read data. The agent role is also mapped into OpenSearch
    fine-grained access control when this is on.
  EOT
  type        = bool
  default     = true
}

###############################################################################
# Demo data injector (optional) — seeds synthetic telemetry so dashboards show
# data before real traffic exists. Disable before carrying real production data.
###############################################################################

variable "enable_demo_data_injector" {
  description = "Deploy a scheduled Lambda that injects synthetic telemetry into Firehose and/or OpenSearch. For demo/POC accounts only."
  type        = bool
  default     = false
}

variable "demo_flow_logs_bucket_name" {
  description = <<-EOT
    Dedicated S3 bucket that receives the demo injector's synthetic nfw_flow logs. Keeps
    synthetic data out of the real AWS Network Firewall flow-log bucket. Empty (the
    default) skips the S3 flow-log path and keeps nfw_flow on the Firehose/OpenSearch path.
  EOT
  type        = string
  default     = ""
}

variable "demo_injector_schedule" {
  description = "EventBridge schedule for the demo data injector."
  type        = string
  default     = "rate(5 minutes)"
}

variable "demo_events_per_run" {
  description = "Synthetic events generated per injector invocation."
  type        = number
  default     = 500
}

variable "demo_window_hours" {
  description = "Spread each injector run's events over the last N hours."
  type        = number
  default     = 1
}

###############################################################################
# Auditing / hardening options (see examples/hardened.tfvars)
###############################################################################

variable "enable_s3_access_logging" {
  description = "Enable S3 server access logging on the analysis bucket, delivered to a dedicated log bucket. Additive and low-cost; on by default."
  type        = bool
  default     = true
}

variable "existing_access_log_bucket_name" {
  description = "Deliver S3 access logs to this existing central log bucket instead of creating a dedicated one. Empty creates <name_prefix>-access-logs-<account>."
  type        = string
  default     = ""
}

variable "enable_cloudtrail_data_events" {
  description = "Create a CloudTrail trail capturing S3 data events (object read/write) on the analysis bucket, for IAM-attributed object-access auditing. Off by default (per-event cost); on in the hardened profile."
  type        = bool
  default     = false
}

variable "audit_log_retention_days" {
  description = "Retention (days) for audit-grade logs: the S3 access-log bucket and the OpenSearch audit/slow-log groups. Defaults to 365; raise for compliance."
  type        = number
  default     = 365
}

variable "enable_opensearch_slow_logs" {
  description = "Publish OpenSearch search/index slow logs to CloudWatch. Off by default; on in the hardened profile for query-latency forensics."
  type        = bool
  default     = false
}

variable "enable_cognito_mfa" {
  description = "Enforce TOTP MFA and Cognito advanced security (threat protection) on the Dashboards login. Off by default for a frictionless PoC; on in the hardened profile. May require the Cognito Plus feature tier."
  type        = bool
  default     = false
}
