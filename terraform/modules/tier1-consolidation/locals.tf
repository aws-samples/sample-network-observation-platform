data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  # Resolve the analysis bucket: create a new one or reference an existing one.
  analysis_bucket_name = var.create_analysis_bucket ? aws_s3_bucket.analysis[0].id : var.existing_analysis_bucket_name

  # CloudWatch log groups that feed the Firehose consolidation path. Each source
  # is included only when its identifier is supplied, so a partial rollout is valid.
  alert_groups      = var.nfw_alert_log_group_name != "" ? [var.nfw_alert_log_group_name] : []
  dns_groups        = var.dns_firewall_log_group_name != "" ? [var.dns_firewall_log_group_name] : []
  cloudtrail_groups = (!var.create_cloudtrail && var.existing_cloudtrail_log_group_name != "") ? [var.existing_cloudtrail_log_group_name] : []

  # VPC Flow Log groups: either the ones the platform creates, or existing ones.
  created_vpc_flow_groups  = var.create_vpc_flow_logs ? [for vpc in var.vpc_ids : aws_cloudwatch_log_group.vpc_flow[vpc].name] : []
  existing_vpc_flow_groups = var.create_vpc_flow_logs ? [] : var.existing_vpc_flow_log_group_names
  vpc_flow_groups          = concat(local.created_vpc_flow_groups, local.existing_vpc_flow_groups)

  # TGW Flow Log groups: created (one for the transit gateway) or existing ones.
  created_tgw_flow_groups  = var.create_tgw_flow_logs ? [aws_cloudwatch_log_group.tgw_flow[0].name] : []
  existing_tgw_flow_groups = var.create_tgw_flow_logs ? [] : var.existing_tgw_flow_log_group_names
  tgw_flow_groups          = concat(local.created_tgw_flow_groups, local.existing_tgw_flow_groups)

  # Every log group to attach a subscription filter to.
  subscribed_log_groups = toset(concat(
    local.alert_groups,
    local.dns_groups,
    local.cloudtrail_groups,
    local.vpc_flow_groups,
    local.tgw_flow_groups,
  ))

  glue_database_name    = replace("${var.name_prefix}_netobs", "-", "_")
  glue_table_name       = "network_events"
  consolidated_prefix   = "consolidated/"
  athena_workgroup_name = "${var.name_prefix}-netobs"
}
