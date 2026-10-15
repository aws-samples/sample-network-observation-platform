###############################################################################
# Shared Lambda assume-role policy
###############################################################################

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

###############################################################################
# Rule-hygiene report Lambda (scheduled)
###############################################################################

data "archive_file" "rule_hygiene" {
  type        = "zip"
  source_file = "${path.module}/lambda/rule_hygiene.py"
  output_path = "${path.module}/build/rule_hygiene.zip"
}

resource "aws_iam_role" "rule_hygiene" {
  name               = "${var.name_prefix}-rule-hygiene"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "rule_hygiene_basic" {
  role       = aws_iam_role.rule_hygiene.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "rule_hygiene_xray" {
  role       = aws_iam_role.rule_hygiene.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# s3:GetObject is scoped to the analysis bucket (AthenaResultsRead); the Athena, Glue and
# network-firewall reads are scoped to the platform workgroup, the netobs Glue catalog/
# database/table, and this account's Network Firewall resources respectively. No statement
# uses Resource="*".
data "aws_iam_policy_document" "rule_hygiene" {
  #checkov:skip=CKV_AWS_111:Write actions are constrained — s3:PutObject is scoped to the athena-results/* prefix and sns:Publish to the platform topic ARN; there is no unconstrained write access. By design.
  statement {
    sid = "DescribeFirewall"
    actions = [
      "network-firewall:DescribeFirewall",
      "network-firewall:DescribeFirewallPolicy",
      "network-firewall:DescribeRuleGroup",
    ]
    resources = [
      "arn:${local.partition}:network-firewall:${local.region}:${local.account_id}:firewall/${var.firewall_name}",
      "arn:${local.partition}:network-firewall:${local.region}:${local.account_id}:firewall-policy/*",
      "arn:${local.partition}:network-firewall:${local.region}:${local.account_id}:stateful-rulegroup/*",
    ]
  }

  # Athena actions support resource-level scoping, so limit them to the platform workgroup.
  statement {
    sid = "AthenaReconciliation"
    actions = [
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
    ]
    resources = ["arn:${local.partition}:athena:${local.region}:${local.account_id}:workgroup/${var.athena_workgroup}"]
  }

  statement {
    sid = "GlueCatalogReads"
    actions = [
      "glue:GetTable",
      "glue:GetDatabase",
      "glue:GetPartitions",
    ]
    resources = compact([
      "arn:${local.partition}:glue:${local.region}:${local.account_id}:catalog",
      var.glue_database_name != "" ? "arn:${local.partition}:glue:${local.region}:${local.account_id}:database/${var.glue_database_name}" : "",
      var.glue_database_name != "" ? "arn:${local.partition}:glue:${local.region}:${local.account_id}:table/${var.glue_database_name}/*" : "",
    ])
  }

  statement {
    sid     = "AthenaResultsRead"
    actions = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = compact([
      var.analysis_bucket_name != "" ? "arn:${local.partition}:s3:::${var.analysis_bucket_name}" : "",
      var.analysis_bucket_name != "" ? "arn:${local.partition}:s3:::${var.analysis_bucket_name}/*" : "",
    ])
  }

  # Athena writes results only under athena-results/ (the netobs workgroup enforces this
  # location, overriding the client-supplied ATHENA_OUTPUT). Scope write access to that
  # prefix so the hygiene report cannot overwrite the consolidated Parquet.
  statement {
    sid     = "AthenaResultsWrite"
    actions = ["s3:PutObject"]
    resources = compact([
      var.analysis_bucket_name != "" ? "arn:${local.partition}:s3:::${var.analysis_bucket_name}/athena-results/*" : "",
    ])
  }

  statement {
    sid     = "Publish"
    actions = ["sns:Publish"]
    # Covers both the hygiene report publish and the Lambda dead-letter target
    # (dead_letter_config below) — both use the same platform SNS topic.
    resources = [local.sns_topic_arn]
  }

  statement {
    sid       = "UseKms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "rule_hygiene" {
  name   = "hygiene"
  role   = aws_iam_role.rule_hygiene.id
  policy = data.aws_iam_policy_document.rule_hygiene.json
}

resource "aws_cloudwatch_log_group" "rule_hygiene" {
  name              = "/aws/lambda/${var.name_prefix}-rule-hygiene"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_lambda_function" "rule_hygiene" {
  # checkov:skip=CKV_AWS_117:Scheduled rule-hygiene Lambda calls AWS control-plane APIs (Athena, Glue, Network Firewall, SNS); VPC placement would require endpoints/NAT with no security benefit.
  # checkov:skip=CKV_AWS_272:Deploy artifact is built from in-repo source via archive_file; no third-party/untrusted code. Code signing is disproportionate for a reference sample.
  # checkov:skip=CKV_AWS_173:Environment variables carry only resource names/ARNs (no secrets); encrypted at rest with the AWS-managed Lambda key. CMK is optional hardening.
  # checkov:skip=CKV_AWS_115:Low-volume scheduled function; account-level concurrency is adequate and a reserved limit adds no value.
  function_name    = "${var.name_prefix}-rule-hygiene"
  role             = aws_iam_role.rule_hygiene.arn
  runtime          = "python3.12"
  handler          = "rule_hygiene.handler"
  filename         = data.archive_file.rule_hygiene.output_path
  source_code_hash = data.archive_file.rule_hygiene.output_base64sha256
  timeout          = 300
  memory_size      = 256
  tags             = var.tags

  tracing_config {
    mode = "Active"
  }

  # Dead-letter target for failed asynchronous (EventBridge-scheduled) invocations.
  # Lambda retries an async invoke twice, then sends the event here so a silently
  # failing scheduled report is visible rather than lost.
  dead_letter_config {
    target_arn = local.sns_topic_arn
  }

  environment {
    variables = {
      FIREWALL_NAME        = var.firewall_name
      GLUE_DATABASE        = var.glue_database_name
      ATHENA_WORKGROUP     = var.athena_workgroup
      ATHENA_OUTPUT        = var.analysis_bucket_name != "" ? "s3://${var.analysis_bucket_name}/${var.athena_results_prefix}/" : ""
      SNS_TOPIC_ARN        = local.sns_topic_arn
      ZERO_HIT_WINDOW_DAYS = tostring(var.zero_hit_window_days)
    }
  }

  depends_on = [aws_cloudwatch_log_group.rule_hygiene]
}

resource "aws_cloudwatch_event_rule" "rule_hygiene" {
  name                = "${var.name_prefix}-rule-hygiene"
  description         = "Scheduled AWS Network Firewall rule-hygiene report."
  schedule_expression = var.rule_hygiene_schedule
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "rule_hygiene" {
  rule      = aws_cloudwatch_event_rule.rule_hygiene.name
  target_id = "rule-hygiene-lambda"
  arn       = aws_lambda_function.rule_hygiene.arn
}

resource "aws_lambda_permission" "rule_hygiene_events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rule_hygiene.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rule_hygiene.arn
}
