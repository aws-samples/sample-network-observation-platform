###############################################################################
# SINGLE-ACCOUNT TEST — point the platform at the test harness.
#
# Workflow:
#   1. cd ../../test-harness && tofu apply
#   2. copy the harness outputs (tofu output platform_tfvars_snippet) into the
#      "from the harness" block below (the placeholder values are pre-filled with
#      the harness's default naming; replace the account-specific bits).
#   3. cd ../terraform && tofu apply -var-file=examples/test-harness.tfvars
#   4. complete the post-apply steps (FGAC mapping, bootstrap invoke) — see the APG
#      "Post-deployment configuration" section.
#
# The platform creates its own analysis bucket, OpenSearch domain, SNS topic, and the
# ingestion pipeline in the SAME test account, and the demo injector seeds data.
###############################################################################

name_prefix = "netobs"
kms_key_arn = "" # create a dedicated CMK

############  From the test harness (replace with `tofu output` values)  ######

firewall_name                      = "netobs-test-fw"
nfw_alert_log_group_name           = "/netobs-test/network-firewall/alert"
existing_nfw_flow_logs_bucket_name = "netobs-test-nfw-flow-REPLACE_ACCOUNT_ID"
create_tgw_flow_logs               = true
transit_gateway_id                 = "tgw-REPLACEME"
create_vpc_flow_logs               = true
vpc_ids                            = ["vpc-REPLACEME"]

############  Platform-owned resources (created in this test account)  ########

# Tier 1
create_analysis_bucket      = true
dns_firewall_log_group_name = "" # harness does not create DNS Firewall; demo injector fabricates DNS events
create_cloudtrail           = false
create_athena_workgroup     = true
create_access_analyzer      = false # single-account test: the harness already creates the one ACCOUNT analyzer AWS allows per Region

# Tier 2
create_opensearch_domain  = true
opensearch_instance_type  = "t3.small.search" # cheapest for a test domain
opensearch_instance_count = 1
opensearch_volume_size_gb = 20
# OpenSearch FGAC master user — set to an IAM role/user ARN (NOT an STS session ARN).
# Required when you deploy via an assumed role or SSO (the empty default uses your
# caller's STS session ARN, which OpenSearch rejects). e.g. your admin IAM role.
opensearch_master_user_arn  = "" # e.g. "arn:aws:iam::111122223333:role/Admin"
create_cloudwatch_dashboard = true
iac_repo_url                = "https://git.example.com/network/network-firewall-rules"
dx_connection_ids           = [] # no Direct Connect in a test account

# S3 -> OpenSearch indexing (platform owns the bucket, so notification is managed)
enable_opensearch_ingestion    = true
opensearch_ingestion_min_units = 1
opensearch_ingestion_max_units = 2

# Tier 3
enable_cloudwatch_investigations = true # baseline alarms (below) feed the investigation rule
investigation_alarm_names        = []   # baseline alarms are added automatically
enable_baseline_alarms           = true # OpenSearch + Firehose self-coverage alarms
create_sns_topic                 = true
notification_email               = "" # set to receive rule-hygiene reports
rule_hygiene_schedule            = "rate(1 day)"

# Seed synthetic data so the dashboards populate immediately
enable_demo_data_injector = true
demo_injector_schedule    = "rate(5 minutes)"
demo_events_per_run       = 500
demo_window_hours         = 1
# Dedicated harness-owned bucket for the injector's synthetic nfw_flow logs, so they never
# land in the real NFW flow-log bucket. Value from `tofu output platform_tfvars_snippet`.
demo_flow_logs_bucket_name = "netobs-test-demo-flow-REPLACE_ACCOUNT_ID"
