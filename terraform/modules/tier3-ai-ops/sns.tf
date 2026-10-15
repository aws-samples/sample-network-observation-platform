data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  region        = data.aws_region.current.region
  partition     = data.aws_partition.current.partition
  sns_topic_arn = var.create_sns_topic ? aws_sns_topic.alerts[0].arn : var.existing_sns_topic_arn
}

resource "aws_sns_topic" "alerts" {
  #checkov:skip=CKV_AWS_26:Topic IS encrypted with the platform CMK via kms_master_key_id below; Checkov does not resolve the var.kms_key_arn reference.
  count             = var.create_sns_topic ? 1 : 0
  name              = "${var.name_prefix}-alerts"
  kms_master_key_id = var.kms_key_arn
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.create_sns_topic && var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.notification_email
}
