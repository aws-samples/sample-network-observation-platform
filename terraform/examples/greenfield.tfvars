###############################################################################
# GREENFIELD — create every resource from new.
#
# Use this to stand up the whole observation platform in a fresh account (for
# example a new Security Tooling account, or a proof-of-concept). The platform
# creates its own KMS key, analysis bucket, OpenSearch domain, SNS topic and
# (optionally) VPC Flow Logs on the VPCs you name.
###############################################################################

name_prefix = "netobs"

# Leave empty so the platform creates a dedicated customer-managed key.
kms_key_arn = ""

########################  Tier 1 — Consolidate  ###############################

create_analysis_bucket = true

# Point at the AWS Network Firewall log destinations. In a brand-new account you
# would create the firewall and its logging separately; set these once they exist.
existing_nfw_flow_logs_bucket_name = ""                                      # set when flow logs land in S3
nfw_alert_log_group_name           = "/aws/network-firewall/egress-ew/alert" # set to your alert log group
dns_firewall_log_group_name        = ""                                      # set if DNS Firewall logging is on

# Create VPC Flow Logs on these VPCs and feed them into the platform.
create_vpc_flow_logs = true
vpc_ids = [
  "vpc-0aaa1111bbbb2222c",
  "vpc-0ddd3333eeee4444f",
]

# Create Transit Gateway Flow Logs on the hub TGW (primary east-west source).
create_tgw_flow_logs = true
transit_gateway_id   = "tgw-0REPLACEME1234567"

# Create a new CloudTrail is out of scope of this module; subscribe one later if wanted.
create_cloudtrail                  = false
existing_cloudtrail_log_group_name = ""

create_athena_workgroup = true

########################  Tier 2 — Visualise  #################################

create_opensearch_domain  = true
opensearch_engine_version = "OpenSearch_2.13"
opensearch_instance_type  = "m6g.large.search"
opensearch_instance_count = 2
opensearch_volume_size_gb = 100

# An EMPTY subnet list creates a PUBLIC OpenSearch endpoint (reachable from the internet;
# fine-grained access control and Cognito login still apply). Set subnet IDs (and security
# group IDs) to place the domain in private VPC subnets, reachable only from inside the VPC.
opensearch_subnet_ids         = []
opensearch_security_group_ids = []

# Cognito MFA is OFF by default here — a deliberate low-friction PoC choice. The Dashboards
# login still enforces a strong password policy. Set enable_cognito_mfa = true to require
# TOTP MFA (and enable Cognito advanced security) for a more protected login.
enable_cognito_mfa = false
# OpenSearch fine-grained access control master user. MUST be an IAM role/user ARN
# (arn:aws:iam::<account>:role/<name>), NOT an STS assumed-role session ARN. Leaving
# this empty makes the platform use your caller ARN; under an assumed role or IAM
# Identity Center/SSO that is an STS session ARN, which OpenSearch rejects at apply.
opensearch_master_user_arn = "" # e.g. "arn:aws:iam::111122223333:role/NetObsAdmin"

create_cloudwatch_dashboard = true
iac_repo_url                = "https://git.example.internal/network/network-firewall-rules"

# Direct Connect health (metrics + alarms only — DX has no flow logs). Empty if none yet.
dx_connection_ids = []

# S3 -> OpenSearch indexing pipeline. The platform owns the analysis bucket
# here, so it also manages the S3 -> SQS notification automatically.
enable_opensearch_ingestion    = true
opensearch_ingestion_min_units = 1
opensearch_ingestion_max_units = 4

########################  Tier 3 — AI-assisted ops  ###########################

firewall_name = "example-egress-fw"

enable_cloudwatch_investigations = true
investigation_alarm_names        = [] # add alarm names once they exist

create_sns_topic   = true
notification_email = "network-oncall@example.com"

rule_hygiene_schedule = "rate(7 days)"
zero_hit_window_days  = 30

########################  Demo data injector  #################################
# A fresh POC account has no traffic; turn this on to keep the dashboards populated
# with synthetic telemetry. Disable before carrying real production data.
enable_demo_data_injector = true
demo_injector_schedule    = "rate(5 minutes)"
demo_events_per_run       = 500
demo_window_hours         = 1
# demo_flow_logs_bucket_name is intentionally left unset here: with no dedicated demo bucket,
# synthetic nfw_flow stays on the Firehose/OpenSearch path and nothing is written to any
# flow-log S3 bucket. Set it (to a dedicated bucket) only where you want synthetic flow logs
# delivered to S3, as the test-harness example does.
