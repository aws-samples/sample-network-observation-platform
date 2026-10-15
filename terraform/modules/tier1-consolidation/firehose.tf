###############################################################################
# Transform Lambda (Firehose record normalisation)
###############################################################################

data "archive_file" "transform" {
  type        = "zip"
  source_file = "${path.module}/lambda/transform.py"
  output_path = "${path.module}/build/transform.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "transform" {
  name               = "${var.name_prefix}-fh-transform"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "transform_basic" {
  role       = aws_iam_role.transform.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "transform_xray" {
  role       = aws_iam_role.transform.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_cloudwatch_log_group" "transform" {
  name              = "/aws/lambda/${var.name_prefix}-fh-transform"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_lambda_function" "transform" {
  # checkov:skip=CKV_AWS_117:Firehose transform Lambda processes records in-line and calls no VPC-internal resources; VPC placement would add endpoints/NAT with no security benefit.
  # checkov:skip=CKV_AWS_116:Firehose invokes this transform synchronously; a Lambda DLQ is async-only and would never fire. Delivery failures go to Firehose error_output_prefix + CloudWatch logging. By design.
  # checkov:skip=CKV_AWS_272:Deploy artifact is built from in-repo source via archive_file; no third-party/untrusted code. Code signing is disproportionate for a reference sample.
  # checkov:skip=CKV_AWS_115:Low-volume Firehose transform; account-level concurrency is adequate and a reserved limit risks throttling delivery under burst.
  function_name = "${var.name_prefix}-fh-transform"
  role          = aws_iam_role.transform.arn
  # No dead_letter_config: Firehose invokes this transform *synchronously*, so a Lambda
  # DLQ (async-only) would never fire. Delivery failures are captured by Firehose's own
  # error_output_prefix ("errors/...") on the delivery stream below, plus its CloudWatch
  # logging — that is the correct failure path for a Firehose data transformer.
  runtime          = "python3.12"
  handler          = "transform.handler"
  filename         = data.archive_file.transform.output_path
  source_code_hash = data.archive_file.transform.output_base64sha256
  timeout          = 60
  memory_size      = 256
  tags             = var.tags

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.transform]
}

###############################################################################
# Firehose delivery role
###############################################################################

data "aws_iam_policy_document" "firehose_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "firehose" {
  name               = "${var.name_prefix}-firehose"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume.json
  tags               = var.tags
}

# s3:GetObject is scoped to the analysis bucket ARN only (S3Delivery statement); the Glue
# schema reads are scoped to the netobs catalog/database/table. No statement uses Resource="*".
data "aws_iam_policy_document" "firehose" {
  statement {
    sid = "S3Delivery"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
    ]
    resources = [
      "arn:${local.partition}:s3:::${local.analysis_bucket_name}",
      "arn:${local.partition}:s3:::${local.analysis_bucket_name}/*",
    ]
  }

  statement {
    sid     = "InvokeTransform"
    actions = ["lambda:InvokeFunction", "lambda:GetFunctionConfiguration"]
    # Firehose invokes the transform with the ":$LATEST" qualifier (see the
    # processor's LambdaArn below). An IAM resource for the unqualified function
    # ARN does not authorise a version/alias-qualified invoke, so both the
    # unqualified and qualified (":*") ARNs are required or Firehose fails every
    # record with Lambda.InvokeAccessDenied.
    resources = [
      aws_lambda_function.transform.arn,
      "${aws_lambda_function.transform.arn}:*",
    ]
  }

  statement {
    sid     = "Glue"
    actions = ["glue:GetTable", "glue:GetTableVersion", "glue:GetTableVersions"]
    resources = [
      "arn:${local.partition}:glue:${local.region}:${local.account_id}:catalog",
      "arn:${local.partition}:glue:${local.region}:${local.account_id}:database/${aws_glue_catalog_database.netobs.name}",
      "arn:${local.partition}:glue:${local.region}:${local.account_id}:table/${aws_glue_catalog_database.netobs.name}/${aws_glue_catalog_table.network_events.name}",
    ]
  }

  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:PutLogEvents", "logs:CreateLogStream"]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/kinesisfirehose/*"]
  }
}

resource "aws_iam_role_policy" "firehose" {
  name   = "delivery"
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.firehose.json
}

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${var.name_prefix}-consolidated"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_cloudwatch_log_stream" "firehose" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

###############################################################################
# Consolidated delivery stream (JSON -> Parquet via Glue schema)
###############################################################################

resource "aws_kinesis_firehose_delivery_stream" "consolidated" {
  #checkov:skip=CKV_AWS_241:Stream IS encrypted with the platform CMK via the server_side_encryption (CUSTOMER_MANAGED_CMK) block below; Checkov does not resolve the var.kms_key_arn reference.
  name        = "${var.name_prefix}-consolidated"
  destination = "extended_s3"
  tags        = var.tags

  # Encrypt records at rest while buffered inside Firehose, using the platform CMK.
  # Valid because this is a DirectPut stream (no kinesis_source_configuration); the
  # delivered S3 objects are separately encrypted via extended_s3_configuration.kms_key_arn.
  # firehose.amazonaws.com is granted Encrypt/Decrypt/GenerateDataKey on the key in kms.tf.
  server_side_encryption {
    enabled  = true
    key_type = "CUSTOMER_MANAGED_CMK"
    key_arn  = var.kms_key_arn
  }

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = "arn:${local.partition}:s3:::${local.analysis_bucket_name}"
    prefix              = "${local.consolidated_prefix}dt=!{timestamp:yyyy-MM-dd}/"
    error_output_prefix = "errors/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd}/"
    buffering_size      = 128
    buffering_interval  = 300
    compression_format  = "UNCOMPRESSED" # Parquet applies its own compression
    kms_key_arn         = var.kms_key_arn

    processing_configuration {
      enabled = true
      processors {
        type = "Lambda"
        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = "${aws_lambda_function.transform.arn}:$LATEST"
        }
      }
    }

    data_format_conversion_configuration {
      input_format_configuration {
        deserializer {
          open_x_json_ser_de {}
        }
      }
      output_format_configuration {
        serializer {
          parquet_ser_de {}
        }
      }
      schema_configuration {
        role_arn      = aws_iam_role.firehose.arn
        database_name = aws_glue_catalog_database.netobs.name
        table_name    = aws_glue_catalog_table.network_events.name
        region        = local.region
      }
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose.name
    }
  }
}
