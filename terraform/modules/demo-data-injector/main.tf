data "aws_partition" "current" {}

locals {
  partition = data.aws_partition.current.partition
  # The generator lives under tools/ at the repo root, shared with the CLI usage.
  source_file = "${path.module}/../../../tools/mock-data-generator/generate_events.py"
}

data "archive_file" "injector" {
  type        = "zip"
  source_file = local.source_file
  output_path = "${path.module}/build/injector.zip"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "injector" {
  name               = "${var.name_prefix}-demo-injector"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.injector.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.injector.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

data "aws_iam_policy_document" "injector" {
  dynamic "statement" {
    for_each = var.firehose_stream_arn != "" ? [1] : []
    content {
      sid       = "Firehose"
      actions   = ["firehose:PutRecordBatch", "firehose:PutRecord"]
      resources = [var.firehose_stream_arn]
    }
  }

  dynamic "statement" {
    for_each = var.opensearch_domain_arn != "" ? [1] : []
    content {
      sid       = "OpenSearch"
      actions   = ["es:ESHttpPost", "es:ESHttpPut"]
      resources = ["${var.opensearch_domain_arn}/*"]
    }
  }

  # Write synthetic flow logs into the dedicated demo flow-log bucket named by
  # var.flow_logs_bucket_name (SSE-S3, so no KMS needed), mirroring how the firewall
  # delivers flow logs directly to S3. The root module wires this to the isolated
  # demo_flow_logs_bucket_name, never the real Network Firewall flow-log bucket, so
  # synthetic data never lands alongside production flow logs. Empty name emits no grant.
  dynamic "statement" {
    for_each = var.flow_logs_bucket_name != "" ? [1] : []
    content {
      sid       = "FlowLogsPut"
      actions   = ["s3:PutObject"]
      resources = ["arn:${local.partition}:s3:::${var.flow_logs_bucket_name}/*"]
    }
  }

  statement {
    sid       = "UseKms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }

  # Allow delivery of failed asynchronous (EventBridge-scheduled) invocations to the
  # dead-letter queue so a silently failing demo seed is visible.
  statement {
    sid       = "DeadLetter"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.injector_dlq.arn]
  }
}

resource "aws_iam_role_policy" "injector" {
  name   = "inject"
  role   = aws_iam_role.injector.id
  policy = data.aws_iam_policy_document.injector.json
}

# Dead-letter queue for failed asynchronous invocations of the demo injector.
# Encrypted with the platform CMK; short retention since these are disposable demo runs.
resource "aws_sqs_queue" "injector_dlq" {
  #checkov:skip=CKV_AWS_27:Queue IS encrypted with the platform CMK via kms_master_key_id below; Checkov does not resolve the var.kms_key_arn reference.
  name                              = "${var.name_prefix}-demo-injector-dlq"
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = 300
  message_retention_seconds         = 1209600 # 14 days
  tags                              = var.tags
}

resource "aws_cloudwatch_log_group" "injector" {
  name              = "/aws/lambda/${var.name_prefix}-demo-injector"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_lambda_function" "injector" {
  # checkov:skip=CKV_AWS_117:Demo injector calls AWS control-plane APIs (Firehose, S3, OpenSearch, STS). VPC placement would require interface endpoints or NAT with no security benefit for a synthetic-data generator, so it is intentionally not VPC-bound.
  # checkov:skip=CKV_AWS_272:Deploy artifact is built from in-repo source via archive_file; no third-party/untrusted code. Code signing (Signer profile + config) is disproportionate for a reference sample.
  # checkov:skip=CKV_AWS_173:Environment variables carry only resource names/ARNs (no secrets); encrypted at rest with the AWS-managed Lambda key. CMK is optional hardening.
  function_name = "${var.name_prefix}-demo-injector"
  role          = aws_iam_role.injector.arn
  runtime       = "python3.12"
  handler       = "generate_events.lambda_handler"
  filename      = data.archive_file.injector.output_path
  # Cap concurrency: this is a scheduled demo injector that never needs to fan out, so a
  # small reserved limit prevents runaway concurrent executions.
  reserved_concurrent_executions = 2
  source_code_hash               = data.archive_file.injector.output_base64sha256
  timeout                        = 120
  memory_size                    = 256
  tags                           = var.tags

  tracing_config {
    mode = "Active"
  }

  # Failed async (EventBridge) invocations go to the DLQ after Lambda's retries.
  dead_letter_config {
    target_arn = aws_sqs_queue.injector_dlq.arn
  }

  environment {
    variables = {
      FIREHOSE_STREAM     = var.firehose_stream_name
      OPENSEARCH_ENDPOINT = var.opensearch_endpoint
      FLOW_LOGS_BUCKET    = var.flow_logs_bucket_name
      FIREWALL_NAME       = var.firewall_name
      EVENTS_PER_RUN      = tostring(var.events_per_run)
      WINDOW_HOURS        = tostring(var.window_hours)
    }
  }

  depends_on = [aws_cloudwatch_log_group.injector]
}

resource "aws_cloudwatch_event_rule" "injector" {
  name                = "${var.name_prefix}-demo-injector"
  description         = "Periodically inject synthetic telemetry so the demo account looks live."
  schedule_expression = var.schedule_expression
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "injector" {
  rule      = aws_cloudwatch_event_rule.injector.name
  target_id = "demo-injector-lambda"
  arn       = aws_lambda_function.injector.arn
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.injector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.injector.arn
}
