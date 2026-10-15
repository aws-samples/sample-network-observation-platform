###############################################################################
# Network Observation platform — root module
#
# Wires three independently deployable tiers. Each tier module implements the
# existing-vs-new pattern internally: pass create_* = false plus an existing_*
# identifier to reuse landing-zone infrastructure, or create_* = true to build
# it from new.
###############################################################################

module "tier1_consolidation" {
  count  = var.enable_tier1_consolidation ? 1 : 0
  source = "./modules/tier1-consolidation"

  # Wait for the customer-managed KMS key POLICY before creating any CMK-encrypted
  # resources (notably CloudWatch log groups, which reference the key ARN, not the
  # policy, and otherwise race ahead of it and fail with KMS AccessDenied on a cold apply).
  depends_on = [aws_kms_key.platform]

  name_prefix = var.name_prefix
  tags        = local.common_tags
  kms_key_arn = local.kms_key_arn

  create_analysis_bucket             = var.create_analysis_bucket
  existing_analysis_bucket_name      = var.existing_analysis_bucket_name
  analysis_bucket_force_destroy      = var.analysis_bucket_force_destroy
  existing_nfw_flow_logs_bucket_name = var.existing_nfw_flow_logs_bucket_name
  nfw_alert_log_group_name           = var.nfw_alert_log_group_name
  dns_firewall_log_group_name        = var.dns_firewall_log_group_name

  create_vpc_flow_logs              = var.create_vpc_flow_logs
  vpc_ids                           = var.vpc_ids
  existing_vpc_flow_log_group_names = var.existing_vpc_flow_log_group_names

  create_tgw_flow_logs              = var.create_tgw_flow_logs
  transit_gateway_id                = var.transit_gateway_id
  existing_tgw_flow_log_group_names = var.existing_tgw_flow_log_group_names

  create_cloudtrail                  = var.create_cloudtrail
  existing_cloudtrail_log_group_name = var.existing_cloudtrail_log_group_name

  create_athena_workgroup = var.create_athena_workgroup

  log_retention_days         = var.log_retention_days
  s3_transition_ia_days      = var.s3_transition_ia_days
  s3_transition_glacier_days = var.s3_transition_glacier_days

  # Auditing: S3 server access logging + optional CloudTrail S3 data events.
  enable_s3_access_logging        = var.enable_s3_access_logging
  existing_access_log_bucket_name = var.existing_access_log_bucket_name
  enable_cloudtrail_data_events   = var.enable_cloudtrail_data_events
  audit_log_retention_days        = var.audit_log_retention_days
}

module "tier2_visualisation" {
  count  = var.enable_tier2_visualisation ? 1 : 0
  source = "./modules/tier2-visualisation"

  # Wait for the KMS key policy before creating CMK-encrypted resources (avoids log-group race).
  depends_on = [aws_kms_key.platform]

  name_prefix = var.name_prefix
  tags        = local.common_tags
  kms_key_arn = local.kms_key_arn

  create_opensearch_domain        = var.create_opensearch_domain
  existing_opensearch_domain_name = var.existing_opensearch_domain_name
  opensearch_engine_version       = var.opensearch_engine_version
  opensearch_instance_type        = var.opensearch_instance_type
  opensearch_instance_count       = var.opensearch_instance_count
  opensearch_volume_size_gb       = var.opensearch_volume_size_gb
  opensearch_subnet_ids           = var.opensearch_subnet_ids
  opensearch_security_group_ids   = var.opensearch_security_group_ids
  opensearch_master_user_arn      = var.opensearch_master_user_arn

  # Cognito browser login for OpenSearch Dashboards (on by default). The demo operator
  # email falls back to notification_email so a single address configures both.
  enable_dashboards_cognito     = var.enable_dashboards_cognito
  dashboards_notification_email = var.dashboards_notification_email != "" ? var.dashboards_notification_email : var.notification_email
  auto_bootstrap                = var.auto_bootstrap

  create_cloudwatch_dashboard = var.create_cloudwatch_dashboard
  iac_repo_url                = var.iac_repo_url
  firewall_name               = var.firewall_name
  transit_gateway_id          = var.transit_gateway_id

  # Auditing/hardening: audit logs on by default, slow logs + Cognito MFA opt-in.
  audit_log_retention_days    = var.audit_log_retention_days
  enable_opensearch_slow_logs = var.enable_opensearch_slow_logs
  enable_cognito_mfa          = var.enable_cognito_mfa

  # Analytics wiring from Tier 1 (empty when Tier 1 is disabled).
  athena_workgroup = try(module.tier1_consolidation[0].athena_workgroup_name, "")

  # Direct Connect health (metrics/alarms only — DX has no flow logs).
  dx_connection_ids = var.dx_connection_ids
  sns_topic_arn     = try(module.tier3_ai_ops[0].sns_topic_arn, "")
}

# S3 -> OpenSearch indexing pipeline. Bridges Tier 1 (S3 Parquet) and
# Tier 2 (OpenSearch), so the dashboards reflect real traffic.
module "s3_to_opensearch" {
  count  = var.enable_opensearch_ingestion && var.enable_tier1_consolidation && var.enable_tier2_visualisation ? 1 : 0
  source = "./modules/s3-to-opensearch"

  # Wait for the KMS key policy (CMK-encrypted resources), and for all of Tier 2 including
  # its bootstrap invocation, so the network-events-* index template is applied before this
  # pipeline creates any index. An index created before the template gets dynamic mappings
  # (text instead of ip/keyword) and its shards fail dashboard aggregations. Tier 2 refers
  # to this module's role by deterministic name, not output, so there is no dependency cycle.
  depends_on = [aws_kms_key.platform, module.tier2_visualisation]

  name_prefix = var.name_prefix
  tags        = local.common_tags
  kms_key_arn = local.kms_key_arn

  analysis_bucket_name = module.tier1_consolidation[0].analysis_bucket_name
  analysis_bucket_arn  = module.tier1_consolidation[0].analysis_bucket_arn
  consolidated_prefix  = module.tier1_consolidation[0].consolidated_prefix
  # Only manage the S3 notification when the platform created the bucket.
  manage_bucket_notification = var.create_analysis_bucket

  opensearch_endpoint           = module.tier2_visualisation[0].opensearch_endpoint
  opensearch_domain_arn         = module.tier2_visualisation[0].opensearch_arn
  opensearch_subnet_ids         = var.opensearch_subnet_ids
  opensearch_security_group_ids = var.opensearch_security_group_ids

  min_units = var.opensearch_ingestion_min_units
  max_units = var.opensearch_ingestion_max_units
}

module "tier3_ai_ops" {
  count  = var.enable_tier3_ai_ops ? 1 : 0
  source = "./modules/tier3-ai-ops"

  # Wait for the KMS key policy before creating CMK-encrypted resources (avoids log-group race).
  depends_on = [aws_kms_key.platform]

  name_prefix = var.name_prefix
  tags        = local.common_tags
  kms_key_arn = local.kms_key_arn

  firewall_name = var.firewall_name

  enable_cloudwatch_investigations = var.enable_cloudwatch_investigations
  investigation_alarm_names        = var.investigation_alarm_names

  # Baseline operational alarms (self-coverage + investigation triggers). Only alarm on
  # the tiers that are actually deployed; resource names are derived from name_prefix.
  enable_baseline_alarms    = var.enable_baseline_alarms
  monitor_opensearch_domain = var.enable_tier2_visualisation && var.create_opensearch_domain
  monitor_firehose          = var.enable_tier1_consolidation

  create_sns_topic       = var.create_sns_topic
  existing_sns_topic_arn = var.existing_sns_topic_arn
  notification_email     = var.notification_email

  rule_hygiene_schedule = var.rule_hygiene_schedule
  zero_hit_window_days  = var.zero_hit_window_days
  log_retention_days    = var.log_retention_days

  # Analytics wiring from Tier 1 (empty when Tier 1 is disabled).
  analysis_bucket_name  = try(module.tier1_consolidation[0].analysis_bucket_name, "")
  glue_database_name    = try(module.tier1_consolidation[0].glue_database_name, "")
  athena_workgroup      = try(module.tier1_consolidation[0].athena_workgroup_name, "")
  athena_results_prefix = "athena-results/rule-hygiene"
}

# Optional demo data injector — populates the dashboards with synthetic telemetry.
# Wired to whichever tiers are enabled: Firehose (Tier 1) and/or OpenSearch (Tier 2).
module "demo_data_injector" {
  count  = var.enable_demo_data_injector ? 1 : 0
  source = "./modules/demo-data-injector"

  # Wait for the KMS key policy (CMK-encrypted resources), and for all of Tier 2 including
  # its bootstrap invocation, so the network-events-* index template is applied before the
  # injector writes any document. An index created before the template gets dynamic mappings
  # (text instead of ip/keyword) and its shards fail dashboard aggregations. Tier 2 refers to
  # this module's role by deterministic name, not output, so there is no dependency cycle.
  depends_on = [aws_kms_key.platform, module.tier2_visualisation]

  name_prefix = var.name_prefix
  tags        = local.common_tags
  kms_key_arn = local.kms_key_arn

  firehose_stream_name  = try(module.tier1_consolidation[0].firehose_stream_name, "")
  firehose_stream_arn   = try(module.tier1_consolidation[0].firehose_stream_arn, "")
  opensearch_endpoint   = try(module.tier2_visualisation[0].opensearch_endpoint, "")
  opensearch_domain_arn = try(module.tier2_visualisation[0].opensearch_arn, "")

  # Synthetic nfw_flow logs go to a dedicated demo bucket so they never land in the real
  # NFW flow-log bucket. Leave demo_flow_logs_bucket_name empty to keep nfw_flow on the
  # Firehose/OpenSearch path instead.
  flow_logs_bucket_name = var.demo_flow_logs_bucket_name
  firewall_name         = var.firewall_name

  schedule_expression = var.demo_injector_schedule
  events_per_run      = var.demo_events_per_run
  window_hours        = var.demo_window_hours
}

# AWS DevOps Agent (Tier 3, real): an agent space + operator app where operators ask
# questions and an AI investigates the account's telemetry, plus a network-firefighter
# skill/custom-agent/trigger scoped to this platform's data. Deployed via the awscc
# provider in a DevOps-Agent-supported Region (see providers.tf), which may differ from
# the platform's Region.
module "devops_agent" {
  count  = var.enable_devops_agent ? 1 : 0
  source = "./modules/devops-agent"

  providers = {
    aws   = aws.devops_agent
    awscc = awscc.devops_agent
  }

  name_prefix = var.name_prefix
  tags        = local.common_tags

  agent_space_name        = var.devops_agent_space_name
  agent_space_description = var.devops_agent_space_description
  enable_assets           = var.devops_agent_enable_assets
  trigger_schedule        = var.devops_agent_trigger_schedule

  # Referenced in the agent's investigation skill so it knows where the data lives.
  glue_database_name        = try(module.tier1_consolidation[0].glue_database_name, "")
  opensearch_dashboards_url = try(module.tier2_visualisation[0].dashboards_url, "")

  # Read access to the analysis plane so the agent can query the telemetry directly.
  # The analysis plane is in this (the platform's) Region, which may differ from the
  # agent's Region. IAM is global, so the region-qualified ARNs resolve either way.
  grant_data_access       = var.devops_agent_grant_data_access
  enable_directed_actions = var.devops_agent_directed_actions
  platform_region         = local.region
  analysis_bucket_name    = try(module.tier1_consolidation[0].analysis_bucket_name, "")
  flow_logs_bucket_name   = var.existing_nfw_flow_logs_bucket_name
  athena_workgroup        = try(module.tier1_consolidation[0].athena_workgroup_name, "")
  # Managed-query-results workgroup: lets the agent run Athena natively (no S3 write / no gate).
  athena_agent_workgroup = try(module.tier1_consolidation[0].athena_agent_workgroup_name, "")
  kms_key_arn            = local.kms_key_arn
  opensearch_domain_arn  = try(module.tier2_visualisation[0].opensearch_arn, "")
}
