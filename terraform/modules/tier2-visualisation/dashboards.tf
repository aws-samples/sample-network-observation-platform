# Bootstrap Lambda: the platform's OpenSearch setup automation. Its execution role is
# the domain's FGAC master user (see opensearch.tf), so it can (1) create the
# least-privilege netobs_read/netobs_write roles and map each IAM principal into the role
# it needs (admin principal -> all_access; Cognito login and the DevOps Agent both ->
# netobs_read, with only the Cognito browser-login role additionally mapped to the built-in
# opensearch_dashboards_user; ingestion pipeline + injector -> netobs_write),
# (2) PUT the network-events-* index template, and (3) import the Dashboards saved objects
# (index pattern, visualisations, dashboard). It is invoked automatically during
# `terraform apply` via aws_lambda_invocation below, so a cold apply yields working,
# mapped, dashboard-loaded OpenSearch with no manual step.

data "archive_file" "bootstrap" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/build/bootstrap.zip"
}

data "aws_iam_policy_document" "bootstrap_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bootstrap" {
  name               = "${var.name_prefix}-os-bootstrap"
  assume_role_policy = data.aws_iam_policy_document.bootstrap_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "bootstrap_basic" {
  role       = aws_iam_role.bootstrap.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "bootstrap_xray" {
  role       = aws_iam_role.bootstrap.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# VPC access for the Lambda when the domain is VPC-attached.
resource "aws_iam_role_policy_attachment" "bootstrap_vpc" {
  count      = length(var.opensearch_subnet_ids) > 0 ? 1 : 0
  role       = aws_iam_role.bootstrap.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "bootstrap" {
  statement {
    actions   = ["es:ESHttpGet", "es:ESHttpPut", "es:ESHttpPost", "es:ESHttpHead"]
    resources = ["${local.domain_arn}/*"]
  }
}

resource "aws_iam_role_policy" "bootstrap" {
  name   = "opensearch-access"
  role   = aws_iam_role.bootstrap.id
  policy = data.aws_iam_policy_document.bootstrap.json
}

resource "aws_cloudwatch_log_group" "bootstrap" {
  name              = "/aws/lambda/${var.name_prefix}-os-bootstrap"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_lambda_function" "bootstrap" {
  # checkov:skip=CKV_AWS_116:Invoked synchronously via aws_lambda_invocation during apply; a Lambda DLQ is async-only and would never fire. A failure surfaces directly as an apply error. By design.
  # checkov:skip=CKV_AWS_272:Deploy artifact is built from in-repo source via archive_file; no third-party/untrusted code. Code signing is disproportionate for a reference sample.
  # checkov:skip=CKV_AWS_173:Environment variables carry only resource names/ARNs (no secrets); encrypted at rest with the AWS-managed Lambda key. CMK is optional hardening.
  function_name = "${var.name_prefix}-os-bootstrap"
  role          = aws_iam_role.bootstrap.arn
  # No dead_letter_config: this function is invoked *synchronously* via
  # aws_lambda_invocation during `terraform apply`, so a Lambda DLQ (async-only) would
  # never fire. A failure surfaces directly as an apply error, which is the desired,
  # visible failure path for a one-shot bootstrap.
  runtime          = "python3.12"
  handler          = "bootstrap.handler"
  filename         = data.archive_file.bootstrap.output_path
  source_code_hash = data.archive_file.bootstrap.output_base64sha256
  # One-shot bootstrap invoked synchronously during apply; reserve a single concurrent
  # execution so it never fans out.
  reserved_concurrent_executions = 1
  # Long enough to out-wait the FGAC master-readiness lag after a cold domain create
  # (observed 2-7 min): MASTER_READY_TIMEOUT_SECONDS (720s) + the bootstrap work, with margin.
  timeout     = 840
  memory_size = 256
  tags        = var.tags

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      OPENSEARCH_ENDPOINT = local.domain_endpoint
      # Fallback FGAC role->principals map used when the function is invoked without a
      # role_mappings event payload (for example a manual invoke).
      FGAC_ROLE_MAPPINGS = jsonencode(local.fgac_role_mappings)
    }
  }

  dynamic "vpc_config" {
    for_each = length(var.opensearch_subnet_ids) > 0 ? [1] : []
    content {
      subnet_ids         = var.opensearch_subnet_ids
      security_group_ids = var.opensearch_security_group_ids
    }
  }

  depends_on = [aws_cloudwatch_log_group.bootstrap]
}

###############################################################################
# Least-privilege FGAC role mappings, and automatic bootstrap invocation.
###############################################################################

locals {
  # Principal ARNs mapped into each OpenSearch role by the bootstrap Lambda. The ingestion
  # pipeline, injector and DevOps Agent roles are referenced by their deterministic names
  # (constructed here rather than via module outputs, which would create a dependency cycle:
  # those modules depend on this one for the domain endpoint). A mapping for a role that
  # does not exist is harmless — it simply matches no principal.
  cognito_login_role_arn     = local.cognito_enabled ? aws_iam_role.cognito_authenticated[0].arn : ""
  osis_pipeline_role_arn     = "arn:${local.partition}:iam::${local.account_id}:role/${var.name_prefix}-osis"
  demo_injector_role_arn     = "arn:${local.partition}:iam::${local.account_id}:role/${var.name_prefix}-demo-injector"
  devops_agentspace_role_arn = "arn:${local.partition}:iam::${local.account_id}:role/${var.name_prefix}-devops-agentspace"

  # Least-privilege FGAC mapping: OpenSearch role name -> IAM principal ARNs mapped into it.
  #   all_access   - full cluster admin; only the master/admin principal.
  #   netobs_read  - read-only on network-events-* (dashboard viewers + the DevOps Agent).
  #   netobs_write - read + write/create on network-events-* (ingestion pipeline + injector).
  #   opensearch_dashboards_user - built-in role the Cognito browser login needs to use
  #                                Dashboards (tenant/.kibana access); provided by OpenSearch.
  # The bootstrap Lambda creates netobs_read/netobs_write and maps the principals below.
  fgac_role_mappings = {
    all_access                 = compact([local.admin_principal_arn])
    netobs_read                = compact([local.cognito_login_role_arn, local.devops_agentspace_role_arn])
    netobs_write               = compact([local.osis_pipeline_role_arn, local.demo_injector_role_arn])
    opensearch_dashboards_user = compact([local.cognito_login_role_arn])
  }
}

# Run the bootstrap during apply. Re-runs whenever the role mappings, the domain
# endpoint, or the function code change.
resource "aws_lambda_invocation" "bootstrap" {
  count         = var.auto_bootstrap && var.create_opensearch_domain ? 1 : 0
  function_name = aws_lambda_function.bootstrap.function_name

  input = jsonencode({
    role_mappings = local.fgac_role_mappings
    endpoint      = local.domain_endpoint
    code_hash     = aws_lambda_function.bootstrap.source_code_hash
  })

  depends_on = [
    aws_opensearch_domain.obs,
    aws_iam_role_policy.bootstrap,
    aws_cognito_identity_pool_roles_attachment.dashboards,
  ]
}
