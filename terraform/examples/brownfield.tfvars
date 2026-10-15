###############################################################################
# BROWNFIELD — reference existing landing-zone infrastructure.
#
# Use this when deploying the observation platform incrementally on top of the
# resources the landing zone already created. Every create_* toggle is false and
# the matching existing_* identifier points at the live resource.
# Replace the placeholder identifiers with the real ones from your account.
###############################################################################

name_prefix = "netobs"

# Encrypt with an existing customer-managed key rather than creating one.
kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/REPLACE-KEY-ID"

########################  Tier 1 — Consolidate  ###############################

# Reuse the existing Log Archive analysis bucket instead of creating one.
create_analysis_bucket        = false
existing_analysis_bucket_name = "example-netobs-analysis"

# Existing AWS Network Firewall log destinations from the landing zone.
existing_nfw_flow_logs_bucket_name = "example-nfw-flow-logs"
nfw_alert_log_group_name           = "/aws/network-firewall/egress-ew/alert"
dns_firewall_log_group_name        = "example-dns-query-logs"

# Subscribe to VPC Flow Logs that already exist rather than creating new ones.
create_vpc_flow_logs = false
existing_vpc_flow_log_group_names = [
  "/example/vpc-flow/prod-app",
  "/example/vpc-flow/prod-data",
]

# Transit Gateway Flow Logs — primary east-west source and how Direct Connect traffic
# is seen. Enable on the existing TGW (or set create_tgw_flow_logs=false and list
# existing_tgw_flow_log_group_names created with the platform's custom format).
create_tgw_flow_logs = true
transit_gateway_id   = "tgw-0REPLACEME1234567"

# Subscribe to the existing organisation CloudTrail log group.
create_cloudtrail                  = false
existing_cloudtrail_log_group_name = "aws-controltower/CloudTrailLogs"

create_athena_workgroup = true

########################  Tier 2 — Visualise  #################################

# Reuse an existing OpenSearch Service domain (for example a shared security domain).
create_opensearch_domain        = false
existing_opensearch_domain_name = "example-security-obs"

create_cloudwatch_dashboard = true
iac_repo_url                = "https://git.example.internal/network/network-firewall-rules"

# Direct Connect health (metrics + alarms only — DX has no flow logs).
dx_connection_ids = ["dxcon-REPLACEme1", "dxcon-REPLACEme2"]

# S3 -> OpenSearch indexing pipeline. Because the analysis bucket is
# existing here (create_analysis_bucket = false), the module will NOT manage the
# S3 -> SQS notification; add that notification to the bucket manually (see README).
enable_opensearch_ingestion = true

########################  Tier 3 — AI-assisted ops  ###########################

firewall_name = "example-egress-fw"

enable_cloudwatch_investigations = true
investigation_alarm_names = [
  "deny-rule-stopped-firing",
  "critical-block-spike",
]

# Reuse an existing notifications topic.
create_sns_topic       = false
existing_sns_topic_arn = "arn:aws:sns:eu-west-1:111122223333:secops-alerts"

rule_hygiene_schedule = "rate(7 days)"
zero_hit_window_days  = 30
