data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.region
  partition   = data.aws_partition.current.partition
  domain_name = "${var.name_prefix}-obs"

  # The FGAC master user is the platform's own bootstrap automation role. This lets the
  # bootstrap Lambda manage OpenSearch security (map role mappings) and load the
  # dashboards during `terraform apply`, with no manual master/human step. See dashboards.tf.
  master_user_arn = aws_iam_role.bootstrap.arn

  # Admin IAM principal additionally granted all_access for CLI/API use (for example the
  # mock-data generator writing directly to OpenSearch). Defaults to the deploying caller.
  admin_principal_arn = var.opensearch_master_user_arn != "" ? var.opensearch_master_user_arn : data.aws_caller_identity.current.arn

  # Resolve the domain whether created here or referenced from an existing one.
  domain_endpoint       = var.create_opensearch_domain ? aws_opensearch_domain.obs[0].endpoint : data.aws_opensearch_domain.existing[0].endpoint
  domain_dashboards_url = var.create_opensearch_domain ? "https://${aws_opensearch_domain.obs[0].endpoint}/_dashboards/" : "https://${data.aws_opensearch_domain.existing[0].dashboard_endpoint}"
  domain_arn            = var.create_opensearch_domain ? aws_opensearch_domain.obs[0].arn : data.aws_opensearch_domain.existing[0].arn
}

# Reference an existing domain when create_opensearch_domain = false.
data "aws_opensearch_domain" "existing" {
  count       = var.create_opensearch_domain ? 0 : 1
  domain_name = var.existing_opensearch_domain_name
}

resource "aws_cloudwatch_log_group" "opensearch" {
  count             = var.create_opensearch_domain ? 1 : 0
  name              = "/aws/opensearch/${local.domain_name}/application"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

data "aws_iam_policy_document" "opensearch_logs" {
  count = var.create_opensearch_domain ? 1 : 0
  statement {
    actions = ["logs:PutLogEvents", "logs:CreateLogStream", "logs:PutLogEventsBatch"]
    # Scoped to this domain's log groups (application/audit/slow), not every log group
    # in the account.
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/opensearch/${local.domain_name}/*"]
    principals {
      type        = "Service"
      identifiers = ["es.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "opensearch" {
  count           = var.create_opensearch_domain ? 1 : 0
  policy_name     = "${var.name_prefix}-opensearch-logs"
  policy_document = data.aws_iam_policy_document.opensearch_logs[0].json
}

# Audit logs: the data-plane access/auth trail for the domain. Requires fine-grained
# access control (enabled below) and is on by default — it is the record of who accessed the
# dashboards data. Retained for audit_log_retention_days. The resource policy above already
# grants es.amazonaws.com log delivery to all log groups in the account, so no extra policy.
resource "aws_cloudwatch_log_group" "opensearch_audit" {
  count             = var.create_opensearch_domain ? 1 : 0
  name              = "/aws/opensearch/${local.domain_name}/audit"
  retention_in_days = var.audit_log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

# Slow logs (opt-in): search/indexing performance forensics. Publishing alone emits nothing
# until per-index slowlog thresholds are set (the bootstrap index template sets conservative
# defaults). Enable in production where query-latency investigation is needed.
resource "aws_cloudwatch_log_group" "opensearch_search_slow" {
  count             = var.create_opensearch_domain && var.enable_opensearch_slow_logs ? 1 : 0
  name              = "/aws/opensearch/${local.domain_name}/search-slow"
  retention_in_days = var.audit_log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "opensearch_index_slow" {
  count             = var.create_opensearch_domain && var.enable_opensearch_slow_logs ? 1 : 0
  name              = "/aws/opensearch/${local.domain_name}/index-slow"
  retention_in_days = var.audit_log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_opensearch_domain" "obs" {
  #checkov:skip=CKV_AWS_317:Audit logging IS enabled — the AUDIT_LOGS log_publishing_options block is present and on by default. Checkov does not correlate the count-indexed ([0]) audit log group to this domain.
  #checkov:skip=CKV2_AWS_59:Dedicated master nodes add 3 always-on instances; not warranted for the single/low-node reference default. Scaled via the hardened profile.
  #checkov:skip=CKV_AWS_318:A 3-node dedicated-master HA topology is a production scaling choice, not required for the reference/PoC default.
  #checkov:skip=CKV_AWS_247:Domain IS encrypted at rest with the platform CMK via encrypt_at_rest.kms_key_id below; Checkov does not resolve the var.kms_key_arn reference.
  count          = var.create_opensearch_domain ? 1 : 0
  domain_name    = local.domain_name
  engine_version = var.opensearch_engine_version
  tags           = var.tags

  cluster_config {
    instance_type          = var.opensearch_instance_type
    instance_count         = var.opensearch_instance_count
    zone_awareness_enabled = var.opensearch_instance_count > 1
    dynamic "zone_awareness_config" {
      for_each = var.opensearch_instance_count > 1 ? [1] : []
      content {
        availability_zone_count = min(var.opensearch_instance_count, 3)
      }
    }
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = var.opensearch_volume_size_gb
  }

  # VPC attachment when subnets are supplied; otherwise a public endpoint secured
  # by fine-grained access control. Supply subnets for production.
  dynamic "vpc_options" {
    for_each = length(var.opensearch_subnet_ids) > 0 ? [1] : []
    content {
      subnet_ids         = var.opensearch_subnet_ids
      security_group_ids = var.opensearch_security_group_ids
    }
  }

  encrypt_at_rest {
    enabled    = true
    kms_key_id = var.kms_key_arn
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https = true
    # Current AWS-recommended policy: adds TLS 1.3 and enforces Perfect Forward Secrecy
    # cipher suites for TLS 1.2 connections (stronger in-transit baseline than the
    # 2019-07 policy).
    tls_security_policy = "Policy-Min-TLS-1-2-PFS-2023-10"
  }

  # Fail at plan time with an actionable message rather than ~2 minutes into apply with
  # a cryptic API error. The common trigger is deploying via an assumed role or IAM
  # Identity Center/SSO with opensearch_master_user_arn left empty: local.master_user_arn
  # then resolves to the caller's STS session ARN, which OpenSearch FGAC does not accept.
  lifecycle {
    precondition {
      condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(role|user|root)", local.admin_principal_arn))
      error_message = "opensearch_master_user_arn must be an IAM role/user/root ARN (arn:aws:iam::<account>:role/<name>), but resolved to \"${local.admin_principal_arn}\". The empty default uses the deploying caller's ARN, which under an assumed role or IAM Identity Center/SSO login is an STS assumed-role session ARN that OpenSearch fine-grained access control rejects. Set it explicitly to the base IAM role/user ARN."
    }
  }

  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = false
    master_user_options {
      master_user_arn = local.master_user_arn
    }
  }

  # Cognito login for OpenSearch Dashboards (see cognito.tf). Without this, an
  # IAM-master-user FGAC domain has no interactive browser login.
  dynamic "cognito_options" {
    for_each = local.cognito_enabled ? [1] : []
    content {
      enabled          = true
      user_pool_id     = aws_cognito_user_pool.dashboards[0].id
      identity_pool_id = aws_cognito_identity_pool.dashboards[0].id
      role_arn         = aws_iam_role.opensearch_cognito[0].arn
    }
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch[0].arn
    log_type                 = "ES_APPLICATION_LOGS"
  }

  # Audit logs: on by default (see the log group above).
  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_audit[0].arn
    log_type                 = "AUDIT_LOGS"
  }

  # Slow logs: only when enable_opensearch_slow_logs = true.
  dynamic "log_publishing_options" {
    for_each = var.enable_opensearch_slow_logs ? [1] : []
    content {
      cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_search_slow[0].arn
      log_type                 = "SEARCH_SLOW_LOGS"
    }
  }

  dynamic "log_publishing_options" {
    for_each = var.enable_opensearch_slow_logs ? [1] : []
    content {
      cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_index_slow[0].arn
      log_type                 = "INDEX_SLOW_LOGS"
    }
  }

  # With fine-grained access control enabled, the domain access policy is intentionally
  # permissive at the account boundary (HTTP verbs only) and FGAC performs the actual
  # authorization. This lets the Cognito login role, ingestion pipeline, injector and
  # admin principal reach the endpoint; what each may do is controlled by FGAC role mappings.
  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
      Action    = "es:ESHttp*"
      Resource  = "arn:${local.partition}:es:${local.region}:${local.account_id}:domain/${local.domain_name}/*"
    }]
  })
}
