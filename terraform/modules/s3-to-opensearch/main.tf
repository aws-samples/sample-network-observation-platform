###############################################################################
# S3 -> OpenSearch indexing via Amazon OpenSearch Ingestion (OSIS).
#
# Firehose writes normalised Parquet to the analysis bucket (for Athena).
# This module streams those same objects into the OpenSearch network-events-* index
# so the OpenSearch dashboards reflect real traffic. It uses the S3 source with an
# SQS notification and the Parquet codec, and the OpenSearch sink.
#
# FGAC note: the pipeline role (aws_iam_role.pipeline) is mapped into the least-privilege
# netobs_write OpenSearch role (read + write/create on network-events-*) automatically by
# the Tier 2 bootstrap Lambda during apply, so its writes succeed with no manual Security
# plugin step.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
}

# --------------------------------------------------------------------------- #
# SQS queue receiving S3 ObjectCreated notifications
# --------------------------------------------------------------------------- #

resource "aws_sqs_queue" "dlq" {
  #checkov:skip=CKV_AWS_27:Queue IS encrypted with the platform CMK via kms_master_key_id below; Checkov does not resolve the var.kms_key_arn reference.
  name                      = "${var.name_prefix}-ingest-dlq"
  kms_master_key_id         = var.kms_key_arn
  message_retention_seconds = 1209600
  tags                      = var.tags
}

resource "aws_sqs_queue" "notifications" {
  #checkov:skip=CKV_AWS_27:Queue IS encrypted with the platform CMK via kms_master_key_id below; Checkov does not resolve the var.kms_key_arn reference.
  name                       = "${var.name_prefix}-ingest"
  kms_master_key_id          = var.kms_key_arn
  visibility_timeout_seconds = 300
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 5
  })
  tags = var.tags
}

data "aws_iam_policy_document" "queue" {
  statement {
    sid       = "AllowS3SendMessage"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.notifications.arn]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [var.analysis_bucket_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sqs_queue_policy" "notifications" {
  queue_url = aws_sqs_queue.notifications.id
  policy    = data.aws_iam_policy_document.queue.json
}

# S3 -> SQS notification. Managed only when the platform owns the bucket, to avoid
# clobbering an existing bucket's notification configuration.
resource "aws_s3_bucket_notification" "analysis" {
  count  = var.manage_bucket_notification ? 1 : 0
  bucket = var.analysis_bucket_name

  queue {
    queue_arn     = aws_sqs_queue.notifications.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = var.consolidated_prefix
  }

  depends_on = [aws_sqs_queue_policy.notifications]
}

# --------------------------------------------------------------------------- #
# Pipeline IAM role
# --------------------------------------------------------------------------- #

data "aws_iam_policy_document" "pipeline_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["osis-pipelines.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "pipeline" {
  name               = "${var.name_prefix}-osis"
  assume_role_policy = data.aws_iam_policy_document.pipeline_assume.json
  tags               = var.tags
}

# KICS "IAM policy allows for data exfiltration" flags s3:GetObject regardless of Resource.
# Here s3:GetObject is scoped to the analysis bucket (ReadSource); OpenSearch and KMS actions
# are scoped to the domain and CMK. The pipeline must read the source objects it ingests.
# False positive.
# kics-scan ignore-block
data "aws_iam_policy_document" "pipeline" {
  statement {
    sid       = "ReadSource"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [var.analysis_bucket_arn, "${var.analysis_bucket_arn}/*"]
  }

  statement {
    sid = "Sqs"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [aws_sqs_queue.notifications.arn]
  }

  statement {
    sid       = "OpenSearchIngest"
    actions   = ["es:DescribeDomain", "es:ESHttpPost", "es:ESHttpPut", "es:ESHttpGet"]
    resources = [var.opensearch_domain_arn, "${var.opensearch_domain_arn}/*"]
  }

  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "pipeline" {
  name   = "ingest"
  role   = aws_iam_role.pipeline.id
  policy = data.aws_iam_policy_document.pipeline.json
}

# --------------------------------------------------------------------------- #
# OpenSearch Ingestion pipeline
# --------------------------------------------------------------------------- #

resource "aws_cloudwatch_log_group" "pipeline" {
  name              = "/aws/vendedlogs/OpenSearchIngestion/${var.name_prefix}-ingest"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

locals {
  # Data Prepper configuration. Note the HCL escapes:
  #   %%{ -> literal %{  (Data Prepper date pattern)
  pipeline_body = <<-YAML
    version: "2"
    network-events-pipeline:
      source:
        s3:
          acknowledgments: true
          notification_type: "sqs"
          compression: "none"
          codec:
            parquet:
          sqs:
            queue_url: "${aws_sqs_queue.notifications.url}"
            maximum_messages: 10
            visibility_timeout: "PT5M"
          aws:
            region: "${local.region}"
            sts_role_arn: "${aws_iam_role.pipeline.arn}"
      sink:
        - opensearch:
            hosts: [ "https://${var.opensearch_endpoint}" ]
            index: "${var.opensearch_index_name}-%%{yyyy.MM.dd}"
            aws:
              region: "${local.region}"
              sts_role_arn: "${aws_iam_role.pipeline.arn}"
  YAML
}

resource "aws_osis_pipeline" "this" {
  pipeline_name               = "${var.name_prefix}-ingest"
  min_units                   = var.min_units
  max_units                   = var.max_units
  pipeline_configuration_body = local.pipeline_body

  log_publishing_options {
    is_logging_enabled = true
    cloudwatch_log_destination {
      log_group = aws_cloudwatch_log_group.pipeline.name
    }
  }

  dynamic "vpc_options" {
    for_each = length(var.opensearch_subnet_ids) > 0 ? [1] : []
    content {
      subnet_ids         = var.opensearch_subnet_ids
      security_group_ids = var.opensearch_security_group_ids
    }
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy.pipeline]
}
