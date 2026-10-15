###############################################################################
# IAM roles for AWS DevOps Agent (agent space + operator app).
# Trust the aidevops.amazonaws.com service principal, scoped to this account and to
# agent-space ARNs in the deployment Region.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition
}

# --- Agent space role: assumed by the agent to monitor the account ---------- #

data "aws_iam_policy_document" "agentspace_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["aidevops.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:aidevops:${local.region}:${local.account_id}:agentspace/*"]
    }
  }
}

resource "aws_iam_role" "agentspace" {
  name               = "${var.name_prefix}-devops-agentspace"
  assume_role_policy = data.aws_iam_policy_document.agentspace_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "agentspace_access" {
  role       = aws_iam_role.agentspace.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AIDevOpsAgentAccessPolicy"
}

# The agent creates the Resource Explorer service-linked role during onboarding.
data "aws_iam_policy_document" "agentspace_inline" {
  statement {
    sid       = "AllowCreateServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/resource-explorer-2.amazonaws.com/AWSServiceRoleForResourceExplorer"]
  }
}

resource "aws_iam_role_policy" "agentspace_inline" {
  name   = "AllowCreateServiceLinkedRoles"
  role   = aws_iam_role.agentspace.id
  policy = data.aws_iam_policy_document.agentspace_inline.json
}

# --- Operator app role: backs the web app where humans ask questions -------- #

data "aws_iam_policy_document" "operator_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["aidevops.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:aidevops:${local.region}:${local.account_id}:agentspace/*"]
    }
  }
}

resource "aws_iam_role" "operator" {
  name               = "${var.name_prefix}-devops-operator"
  assume_role_policy = data.aws_iam_policy_document.operator_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "operator_access" {
  role       = aws_iam_role.operator.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AIDevOpsOperatorAppAccessPolicy"
}

# --- Analysis-plane read access for the agent space -------------------------- #
# Lets the agent run Athena queries over the consolidated logs and read OpenSearch,
# so it can answer investigative questions directly. Scoped to this platform's
# resources. The analysis plane may be in a different Region than the agent space.

locals {
  # Region of the analysis plane (Athena/Glue/S3/OpenSearch); falls back to this Region.
  data_region = var.platform_region != "" ? var.platform_region : local.region
}

data "aws_iam_policy_document" "agentspace_data_read" {
  count = var.grant_data_access ? 1 : 0

  dynamic "statement" {
    for_each = (var.athena_workgroup != "" || var.athena_agent_workgroup != "") ? [1] : []
    content {
      sid = "Athena"
      actions = [
        "athena:StartQueryExecution",
        "athena:StopQueryExecution",
        "athena:GetQueryExecution",
        "athena:GetQueryResults",
        # Required to read Athena managed query results (agent workgroup).
        "athena:GetQueryResultsStream",
        "athena:GetWorkGroup",
        "athena:ListQueryExecutions",
      ]
      resources = compact([
        var.athena_workgroup != "" ? "arn:${local.partition}:athena:${local.data_region}:${local.account_id}:workgroup/${var.athena_workgroup}" : "",
        var.athena_agent_workgroup != "" ? "arn:${local.partition}:athena:${local.data_region}:${local.account_id}:workgroup/${var.athena_agent_workgroup}" : "",
      ])
    }
  }

  dynamic "statement" {
    for_each = var.glue_database_name != "" ? [1] : []
    content {
      sid     = "GlueCatalogRead"
      actions = ["glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables", "glue:GetPartition", "glue:GetPartitions", "glue:SearchTables"]
      resources = [
        "arn:${local.partition}:glue:${local.data_region}:${local.account_id}:catalog",
        "arn:${local.partition}:glue:${local.data_region}:${local.account_id}:database/${var.glue_database_name}",
        "arn:${local.partition}:glue:${local.data_region}:${local.account_id}:table/${var.glue_database_name}/*",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.analysis_bucket_name != "" ? [1] : []
    content {
      sid = "S3AnalysisRead"
      # The agent's base role uses the managed-query-results Athena workgroup: it reads the
      # source Parquet from S3 and reads results back via athena:GetQueryResults, so it needs
      # NO S3 write (s3:PutObject). Read-only, and never scoped to write over the lake.
      actions = [
        "s3:GetObject",
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads",
      ]
      resources = [
        "arn:${local.partition}:s3:::${var.analysis_bucket_name}",
        "arn:${local.partition}:s3:::${var.analysis_bucket_name}/*",
      ]
    }
  }

  # Read-only access to the NFW flow-log bucket (catalogued in place as nfw_flow_s3),
  # so the agent can query flow logs and verify delivery. No write.
  dynamic "statement" {
    for_each = var.flow_logs_bucket_name != "" ? [1] : []
    content {
      sid     = "S3FlowLogsRead"
      actions = ["s3:GetObject", "s3:GetBucketLocation", "s3:ListBucket"]
      resources = [
        "arn:${local.partition}:s3:::${var.flow_logs_bucket_name}",
        "arn:${local.partition}:s3:::${var.flow_logs_bucket_name}/*",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.kms_key_arn != "" ? [1] : []
    content {
      sid       = "Kms"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [var.kms_key_arn]
    }
  }

  dynamic "statement" {
    for_each = var.opensearch_domain_arn != "" ? [1] : []
    content {
      sid       = "OpenSearchRead"
      actions   = ["es:ESHttpGet", "es:ESHttpPost"]
      resources = ["${var.opensearch_domain_arn}/*"]
    }
  }
}

resource "aws_iam_role_policy" "agentspace_data_read" {
  count  = var.grant_data_access ? 1 : 0
  name   = "network-observation-data-read"
  role   = aws_iam_role.agentspace.id
  policy = data.aws_iam_policy_document.agentspace_data_read[0].json
}

# --- Elevated (directed-actions) role --------------------------------------- #
# The role AWS DevOps Agent assumes to run Athena queries in environments that gate query
# execution behind operator approval. It is scoped to the Athena query path only (Athena
# queries, Glue/S3 reads, KMS, and query results written solely under athena-results/) and
# grants no infrastructure, firewall, or lake-data mutation. This role
# is the ceiling; every directed action still requires per-action operator approval in the
# operator app, and the session is scoped to the approved operation. Trust must allow all
# three STS actions or directed actions fail.
#
# NOTE: creating this role is reproducible in Terraform, but *enabling* directed actions
# on the agent space (elevatedActionsEnabled) and *registering* this role on the
# association (agentElevatedRoleArn) are not yet exposed by the awscc provider, so they
# are done via the AWS CLI/console — see the module README / platform docs.

data "aws_iam_policy_document" "elevated_trust" {
  count = var.enable_directed_actions ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:SetSourceIdentity", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["aidevops.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:aidevops:${local.region}:${local.account_id}:agentspace/*"]
    }
  }
}

resource "aws_iam_role" "elevated" {
  count              = var.enable_directed_actions ? 1 : 0
  name               = "DevOpsAgent-ElevatedAction-${var.name_prefix}"
  assume_role_policy = data.aws_iam_policy_document.elevated_trust[0].json
  tags               = var.tags
}

# Ceiling for approved directed actions: scoped to the analysis-plane query path
# (Athena over the consolidated logs), not the broad AIDevOpsAgentActionsPolicy.
data "aws_iam_policy_document" "elevated_permissions" {
  count = var.enable_directed_actions ? 1 : 0

  dynamic "statement" {
    for_each = var.athena_workgroup != "" ? [1] : []
    content {
      sid = "Athena"
      actions = [
        "athena:StartQueryExecution",
        "athena:StopQueryExecution",
        "athena:GetQueryExecution",
        "athena:GetQueryResults",
        "athena:GetWorkGroup",
        "athena:ListQueryExecutions",
      ]
      resources = ["arn:${local.partition}:athena:${local.data_region}:${local.account_id}:workgroup/${var.athena_workgroup}"]
    }
  }

  dynamic "statement" {
    for_each = var.glue_database_name != "" ? [1] : []
    content {
      sid     = "GlueCatalogRead"
      actions = ["glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables", "glue:GetPartition", "glue:GetPartitions", "glue:SearchTables"]
      resources = [
        "arn:${local.partition}:glue:${local.data_region}:${local.account_id}:catalog",
        "arn:${local.partition}:glue:${local.data_region}:${local.account_id}:database/${var.glue_database_name}",
        "arn:${local.partition}:glue:${local.data_region}:${local.account_id}:table/${var.glue_database_name}/*",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.analysis_bucket_name != "" ? [1] : []
    content {
      sid     = "S3AnalysisRead"
      actions = ["s3:GetObject", "s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"]
      resources = [
        "arn:${local.partition}:s3:::${var.analysis_bucket_name}",
        "arn:${local.partition}:s3:::${var.analysis_bucket_name}/*",
      ]
    }
  }

  # Standard-workgroup Athena writes results only under athena-results/. Scope write access
  # to that prefix so approved directed actions cannot overwrite the consolidated Parquet.
  dynamic "statement" {
    for_each = var.analysis_bucket_name != "" ? [1] : []
    content {
      sid       = "S3WriteAthenaResults"
      actions   = ["s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
      resources = ["arn:${local.partition}:s3:::${var.analysis_bucket_name}/athena-results/*"]
    }
  }

  dynamic "statement" {
    for_each = var.kms_key_arn != "" ? [1] : []
    content {
      sid       = "Kms"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [var.kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "elevated" {
  count  = var.enable_directed_actions ? 1 : 0
  name   = "directed-actions"
  role   = aws_iam_role.elevated[0].id
  policy = data.aws_iam_policy_document.elevated_permissions[0].json
}
