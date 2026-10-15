###############################################################################
# Baseline operational alarms.
#
# A greenfield deployment otherwise ships no CloudWatch alarms, so nothing pages the
# on-call and the CloudWatch-investigations loop has nothing to trigger it. These
# alarms give the platform baseline self-coverage and feed the investigation wiring.
#
# Resource names are constructed from name_prefix (not module outputs) to keep this
# module free of a dependency cycle with the tiers that own the resources. The alarms
# are created only for the tiers that are actually deployed (monitor_* flags).
###############################################################################

locals {
  os_domain_name = "${var.name_prefix}-obs"
  firehose_name  = "${var.name_prefix}-consolidated"

  make_os_alarms = var.enable_baseline_alarms && var.monitor_opensearch_domain
  make_fh_alarms = var.enable_baseline_alarms && var.monitor_firehose

  # Names are literals (var-derived) so they are known at plan time and can safely
  # drive count/for_each and the investigation event pattern.
  os_alarm_names = local.make_os_alarms ? [
    "${var.name_prefix}-os-cluster-red",
    "${var.name_prefix}-os-writes-blocked",
    "${var.name_prefix}-os-free-storage",
  ] : []
  fh_alarm_names = local.make_fh_alarms ? [
    "${var.name_prefix}-fh-delivery-freshness",
    "${var.name_prefix}-fh-delivery-success",
  ] : []

  baseline_alarm_names = concat(local.os_alarm_names, local.fh_alarm_names)
}

# --- OpenSearch -------------------------------------------------------------- #

resource "aws_cloudwatch_metric_alarm" "os_cluster_red" {
  count               = local.make_os_alarms ? 1 : 0
  alarm_name          = "${var.name_prefix}-os-cluster-red"
  alarm_description   = "OpenSearch domain ${local.os_domain_name}: cluster status RED (primary shards unassigned — potential data unavailability)."
  namespace           = "AWS/ES"
  metric_name         = "ClusterStatus.red"
  dimensions          = { ClientId = local.account_id, DomainName = local.os_domain_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sns_topic_arn]
  ok_actions          = [local.sns_topic_arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "os_writes_blocked" {
  count               = local.make_os_alarms ? 1 : 0
  alarm_name          = "${var.name_prefix}-os-writes-blocked"
  alarm_description   = "OpenSearch domain ${local.os_domain_name}: index writes blocked (commonly low disk or high JVM memory pressure)."
  namespace           = "AWS/ES"
  metric_name         = "ClusterIndexWritesBlocked"
  dimensions          = { ClientId = local.account_id, DomainName = local.os_domain_name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sns_topic_arn]
  ok_actions          = [local.sns_topic_arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "os_free_storage" {
  count               = local.make_os_alarms ? 1 : 0
  alarm_name          = "${var.name_prefix}-os-free-storage"
  alarm_description   = "OpenSearch domain ${local.os_domain_name}: free storage below ${var.opensearch_free_storage_alarm_mb} MB on a data node."
  namespace           = "AWS/ES"
  metric_name         = "FreeStorageSpace"
  dimensions          = { ClientId = local.account_id, DomainName = local.os_domain_name }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.opensearch_free_storage_alarm_mb
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sns_topic_arn]
  ok_actions          = [local.sns_topic_arn]
  tags                = var.tags
}

# --- Firehose (consolidation delivery stream) -------------------------------- #

resource "aws_cloudwatch_metric_alarm" "fh_delivery_freshness" {
  count               = local.make_fh_alarms ? 1 : 0
  alarm_name          = "${var.name_prefix}-fh-delivery-freshness"
  alarm_description   = "Firehose ${local.firehose_name}: data freshness exceeds ${var.firehose_freshness_alarm_seconds}s — delivery to S3 is falling behind."
  namespace           = "AWS/Firehose"
  metric_name         = "DeliveryToS3.DataFreshness"
  dimensions          = { DeliveryStreamName = local.firehose_name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.firehose_freshness_alarm_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sns_topic_arn]
  ok_actions          = [local.sns_topic_arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "fh_delivery_success" {
  count               = local.make_fh_alarms ? 1 : 0
  alarm_name          = "${var.name_prefix}-fh-delivery-success"
  alarm_description   = "Firehose ${local.firehose_name}: successful delivery ratio below 99% — records are failing to reach S3 (check the transform Lambda and the error prefix)."
  namespace           = "AWS/Firehose"
  metric_name         = "DeliveryToS3.Success"
  dimensions          = { DeliveryStreamName = local.firehose_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0.99
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.sns_topic_arn]
  ok_actions          = [local.sns_topic_arn]
  tags                = var.tags
}
