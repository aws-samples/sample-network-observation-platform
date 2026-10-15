###############################################################################
# HARDENED EXAMPLE: enables additional security controls for evaluation. This is not a
# production configuration.
#
# This is sample code, for non-production usage. You should work with your security and
# legal teams to meet your organizational security, regulatory and compliance requirements
# before deployment. This example turns on the security/auditing controls that a
# proof-of-concept does not need. Copy it, then replace every <REPLACE...>
# placeholder with your real values before applying:
#
#     cp examples/hardened.tfvars my-hardened.tfvars
#     # edit my-hardened.tfvars
#     tofu apply -var-file=my-hardened.tfvars
#
# What this example enables beyond the PoC defaults:
#   - OpenSearch attached to a private VPC (no public endpoint)         [network]
#   - OpenSearch AUDIT_LOGS (on everywhere) + SEARCH/INDEX slow logs    [audit]
#   - S3 server access logging on the analysis bucket (on everywhere)   [audit]
#   - CloudTrail S3 data events on the analysis bucket                  [audit]
#   - Cognito TOTP MFA + advanced security on the Dashboards login      [auth]
#   - Audit-grade log retention (365+ days)                            [retention]
#   - The demo data injector OFF                                       [safety]
#
# ─────────────────────────────────────────────────────────────────────────────
# IMPORTANT — VPC endpoint reachability. With opensearch_subnet_ids set, the
# OpenSearch/Dashboards endpoint becomes PRIVATE (resolvable only inside the VPC).
# Browser users reach it via VPN, Direct Connect, a bastion, or a reverse proxy.
# Cognito login still works, but only for users who can already reach the endpoint.
# ─────────────────────────────────────────────────────────────────────────────
#
# ASSUMED ORG/ACCOUNT PREREQUISITES (this module does NOT create these — they are
# landing-zone responsibilities; confirm they are in place):
#   - An organization CloudTrail capturing management events
#   - AWS Config (resource configuration history / compliance)
#   - Amazon GuardDuty (threat detection, incl. S3 protection)
#   - AWS Security Hub and IAM Access Analyzer
#
# OPTIONAL, NOT WIRED HERE (deliberate manual decision):
#   - S3 Object Lock (WORM) on the access-log / CloudTrail buckets for tamper-proof,
#     immutable audit retention. It is irreversible and needs a chosen retention
#     period, so enable it by hand on those buckets per your compliance policy.
###############################################################################

name_prefix = "netobs"

# Use an existing org CMK if you have one, or leave empty to create a dedicated key.
kms_key_arn = ""

########################  Tier 1 — Consolidate  ###############################

create_analysis_bucket = true
# Protect versioned telemetry: a destroy using this example will NOT empty the analysis
# bucket. Empty it deliberately (with a retention/backup step) before any teardown.
analysis_bucket_force_destroy      = false
existing_nfw_flow_logs_bucket_name = "<REPLACE-nfw-flow-logs-bucket>"
nfw_alert_log_group_name           = "<REPLACE-/aws/network-firewall/.../alert>"
dns_firewall_log_group_name        = "<REPLACE-or-empty>"

create_vpc_flow_logs = false # reference existing landing-zone flow logs below, or set true
existing_vpc_flow_log_group_names = [
  "<REPLACE-vpc-flow-log-group>",
]

create_tgw_flow_logs = false
existing_tgw_flow_log_group_names = [
  "<REPLACE-tgw-flow-log-group>",
]

create_athena_workgroup = true

# --- Auditing --------------------------------------------------------------- #
enable_s3_access_logging        = true # on by default; kept explicit here
existing_access_log_bucket_name = ""   # or point at a central Log Archive bucket
enable_cloudtrail_data_events   = true # per-object, IAM-attributed access trail (costs per event)
audit_log_retention_days        = 365  # raise (e.g. 730/2555) to match your retention policy

########################  Tier 2 — Visualise  #################################

create_opensearch_domain  = true
opensearch_engine_version = "OpenSearch_2.13"
opensearch_instance_type  = "m6g.large.search"
opensearch_instance_count = 3 # multi-AZ for resilience
opensearch_volume_size_gb = 200

# Private VPC attachment (removes the public endpoint). REQUIRED for this profile.
opensearch_subnet_ids = [
  "<REPLACE-private-subnet-a>",
  "<REPLACE-private-subnet-b>",
]
opensearch_security_group_ids = [
  "<REPLACE-security-group-allowing-443-from-your-clients>",
]

# MUST be an IAM role/user ARN (NOT an STS assumed-role session ARN).
opensearch_master_user_arn = "<REPLACE-arn:aws:iam::ACCOUNT:role/NetObsAdmin>"

# Dashboards login hardening.
enable_dashboards_cognito     = true
enable_cognito_mfa            = true # enforce TOTP MFA + advanced security (may need Cognito Plus tier)
dashboards_notification_email = "<REPLACE-dashboards-operator@example.com>"

# Slow logs for query-latency forensics.
enable_opensearch_slow_logs = true

create_cloudwatch_dashboard = true
iac_repo_url                = "<REPLACE-https://git.example.internal/network/network-firewall-rules>"

dx_connection_ids = []

enable_opensearch_ingestion    = true
opensearch_ingestion_min_units = 1
opensearch_ingestion_max_units = 4

########################  Tier 3 — AI-assisted ops  ###########################

firewall_name = "<REPLACE-firewall-name>"

enable_cloudwatch_investigations = true
investigation_alarm_names        = [] # add your critical alarm names

create_sns_topic   = true
notification_email = "<REPLACE-network-oncall@example.com>"

rule_hygiene_schedule = "rate(7 days)"
zero_hit_window_days  = 30

########################  Demo data injector  #################################
# OFF so synthetic and real telemetry never mix.
enable_demo_data_injector = false
