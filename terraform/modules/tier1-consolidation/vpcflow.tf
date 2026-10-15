# Optional: create VPC Flow Logs on the supplied VPCs, delivered to a CloudWatch
# Logs group per VPC. When create_vpc_flow_logs = false, the module instead
# subscribes to the existing flow-log groups named in existing_vpc_flow_log_group_names.

resource "aws_cloudwatch_log_group" "vpc_flow" {
  for_each          = var.create_vpc_flow_logs ? toset(var.vpc_ids) : []
  name              = "/${var.name_prefix}/vpc-flow/${each.value}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

data "aws_iam_policy_document" "vpc_flow_assume" {
  count = var.create_vpc_flow_logs ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vpc_flow" {
  count              = var.create_vpc_flow_logs ? 1 : 0
  name               = "${var.name_prefix}-vpc-flow"
  assume_role_policy = data.aws_iam_policy_document.vpc_flow_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "vpc_flow" {
  count = var.create_vpc_flow_logs ? 1 : 0
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/${var.name_prefix}/vpc-flow/*"]
  }
}

resource "aws_iam_role_policy" "vpc_flow" {
  count  = var.create_vpc_flow_logs ? 1 : 0
  name   = "deliver"
  role   = aws_iam_role.vpc_flow[0].id
  policy = data.aws_iam_policy_document.vpc_flow[0].json
}

resource "aws_flow_log" "vpc" {
  for_each                 = var.create_vpc_flow_logs ? toset(var.vpc_ids) : []
  vpc_id                   = each.value
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.vpc_flow[each.value].arn
  iam_role_arn             = aws_iam_role.vpc_flow[0].arn
  max_aggregation_interval = 60
  tags                     = var.tags
}
