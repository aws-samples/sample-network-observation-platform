# CloudWatch Logs -> Firehose subscription path. One IAM role, one subscription
# filter per source log group (alert, DNS, CloudTrail, VPC flow).

data "aws_iam_policy_document" "cwl_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cwl_to_firehose" {
  name               = "${var.name_prefix}-cwl-to-firehose"
  assume_role_policy = data.aws_iam_policy_document.cwl_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "cwl_to_firehose" {
  statement {
    actions   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
    resources = [aws_kinesis_firehose_delivery_stream.consolidated.arn]
  }

  # The consolidated delivery stream is encrypted with the customer-managed CMK, so
  # CloudWatch Logs needs KMS use to encrypt records when it calls PutRecord*.
  statement {
    sid       = "UseKms"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "cwl_to_firehose" {
  name   = "put-firehose"
  role   = aws_iam_role.cwl_to_firehose.id
  policy = data.aws_iam_policy_document.cwl_to_firehose.json
}

resource "aws_cloudwatch_log_subscription_filter" "to_firehose" {
  for_each = local.subscribed_log_groups

  name            = "${var.name_prefix}-consolidate"
  log_group_name  = each.value
  filter_pattern  = "" # forward every event; normalisation happens in the transform
  destination_arn = aws_kinesis_firehose_delivery_stream.consolidated.arn
  role_arn        = aws_iam_role.cwl_to_firehose.arn
  distribution    = "ByLogStream"
}
