# Optional: create Transit Gateway Flow Logs, delivered to a CloudWatch Logs group in
# the platform's custom field order so the transform Lambda can parse them positionally.
# For a hub-and-spoke landing zone with centralised inspection, TGW Flow Logs are the
# primary east-west visibility source and also capture traffic crossing the Direct
# Connect / VPN attachments (Direct Connect itself has no flow logs — only CloudWatch
# metrics, surfaced on the Tier 2 dashboard).
#
# Custom format (must match normalise_tgw_flow in transform.py):
#   tgw-id tgw-attachment-id srcaddr dstaddr srcport dstport protocol packets bytes
#   tcp-flags flow-direction log-status start
# The trailing `start` (Unix epoch seconds) time-stamps each TGW event so it carries an
# event_time like every other source; the transform normalises it to ISO-8601 UTC.

resource "aws_cloudwatch_log_group" "tgw_flow" {
  count             = var.create_tgw_flow_logs ? 1 : 0
  name              = "/${var.name_prefix}/tgw-flow/${var.transit_gateway_id}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

data "aws_iam_policy_document" "tgw_flow_assume" {
  count = var.create_tgw_flow_logs ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "tgw_flow" {
  count              = var.create_tgw_flow_logs ? 1 : 0
  name               = "${var.name_prefix}-tgw-flow"
  assume_role_policy = data.aws_iam_policy_document.tgw_flow_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "tgw_flow" {
  count = var.create_tgw_flow_logs ? 1 : 0
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/${var.name_prefix}/tgw-flow/*"]
  }
}

resource "aws_iam_role_policy" "tgw_flow" {
  count  = var.create_tgw_flow_logs ? 1 : 0
  name   = "deliver"
  role   = aws_iam_role.tgw_flow[0].id
  policy = data.aws_iam_policy_document.tgw_flow[0].json
}

resource "aws_flow_log" "tgw" {
  count                    = var.create_tgw_flow_logs ? 1 : 0
  transit_gateway_id       = var.transit_gateway_id
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.tgw_flow[0].arn
  iam_role_arn             = aws_iam_role.tgw_flow[0].arn
  max_aggregation_interval = 60
  log_format               = "$${tgw-id} $${tgw-attachment-id} $${srcaddr} $${dstaddr} $${srcport} $${dstport} $${protocol} $${packets} $${bytes} $${tcp-flags} $${flow-direction} $${log-status} $${start}"
  tags                     = var.tags
}
