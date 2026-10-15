###############################################################################
# Amazon Cognito authentication for OpenSearch Dashboards.
#
# Why this exists: the domain uses fine-grained access control (FGAC) with an IAM
# principal as master user. With that configuration and no Cognito/SAML, the
# OpenSearch Dashboards endpoint has NO interactive browser login (requests must be
# SigV4-signed), so a human cannot open the dashboards URL. Enabling Cognito gives a
# hosted-UI login page, so `terraform apply` yields dashboards a user can actually
# open in a browser.
#
# The authenticated Cognito role is mapped into an OpenSearch role by the bootstrap
# Lambda (see dashboards.tf) so that logged-in users can read the data.
###############################################################################

locals {
  cognito_enabled = var.enable_dashboards_cognito && var.create_opensearch_domain

  # Cognito hosted-UI domain prefixes must be unique per Region. Account-scoping keeps
  # it deterministic (no random provider) while avoiding collisions across accounts.
  cognito_domain_prefix = "${var.name_prefix}-obs-${local.account_id}"
}

# --------------------------------------------------------------------------- #
# User pool + hosted-UI domain
# --------------------------------------------------------------------------- #

resource "aws_cognito_user_pool" "dashboards" {
  count = local.cognito_enabled ? 1 : 0
  name  = "${var.name_prefix}-dashboards"

  # Operators are provisioned by an admin (Terraform / console), not self sign-up.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # MFA + advanced security (threat protection) for production (enable_cognito_mfa).
  # Off by default so a PoC login is friction-free; on, all operators must enrol TOTP and
  # Cognito flags risky sign-ins. NOTE: advanced_security_mode = ENFORCED may require the
  # account's Cognito user pool to be on the Plus feature tier; drop it if not available.
  mfa_configuration = var.enable_cognito_mfa ? "ON" : "OFF"

  dynamic "software_token_mfa_configuration" {
    for_each = var.enable_cognito_mfa ? [1] : []
    content {
      enabled = true
    }
  }

  dynamic "user_pool_add_ons" {
    for_each = var.enable_cognito_mfa ? [1] : []
    content {
      advanced_security_mode = "ENFORCED"
    }
  }

  # Cognito's built-in sender (COGNITO_DEFAULT) covers demo invite volumes. For
  # production, attach Amazon SES via an email_configuration block.

  tags = var.tags
}

resource "aws_cognito_user_pool_domain" "dashboards" {
  count        = local.cognito_enabled ? 1 : 0
  domain       = local.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.dashboards[0].id
}

# --------------------------------------------------------------------------- #
# Identity pool. OpenSearch injects its managed app client as a provider when the
# domain's cognito_options are applied, so those fields are ignored here to avoid
# a perpetual diff.
# --------------------------------------------------------------------------- #

resource "aws_cognito_identity_pool" "dashboards" {
  count                            = local.cognito_enabled ? 1 : 0
  identity_pool_name               = "${var.name_prefix}-dashboards"
  allow_unauthenticated_identities = false

  lifecycle {
    ignore_changes = [
      cognito_identity_providers,
      openid_connect_provider_arns,
      supported_login_providers,
      saml_provider_arns,
    ]
  }

  tags = var.tags
}

# --------------------------------------------------------------------------- #
# Role that Amazon OpenSearch assumes to configure the Cognito integration
# (manage the user-pool app client and identity-pool providers).
# --------------------------------------------------------------------------- #

resource "aws_iam_role" "opensearch_cognito" {
  count = local.cognito_enabled ? 1 : 0
  name  = "${var.name_prefix}-opensearch-cognito"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "es.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "opensearch_cognito" {
  count      = local.cognito_enabled ? 1 : 0
  role       = aws_iam_role.opensearch_cognito[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonOpenSearchServiceCognitoAccess"
}

# --------------------------------------------------------------------------- #
# Authenticated role — the identity a logged-in Dashboards user assumes. FGAC then
# governs what that role can see; the bootstrap Lambda maps it into an OpenSearch role.
# --------------------------------------------------------------------------- #

data "aws_iam_policy_document" "cognito_authenticated_assume" {
  count = local.cognito_enabled ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["cognito-identity.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "cognito-identity.amazonaws.com:aud"
      values   = [aws_cognito_identity_pool.dashboards[0].id]
    }
    condition {
      test     = "ForAnyValue:StringLike"
      variable = "cognito-identity.amazonaws.com:amr"
      values   = ["authenticated"]
    }
  }
}

resource "aws_iam_role" "cognito_authenticated" {
  count              = local.cognito_enabled ? 1 : 0
  name               = "${var.name_prefix}-dashboards-user"
  assume_role_policy = data.aws_iam_policy_document.cognito_authenticated_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "cognito_authenticated" {
  count = local.cognito_enabled ? 1 : 0
  name  = "dashboards-access"
  role  = aws_iam_role.cognito_authenticated[0].id
  # These are the HTTP verbs the OpenSearch Dashboards UI issues at the transport layer;
  # the resource is scoped to this domain. Authorization is enforced by OpenSearch
  # fine-grained access control (FGAC), not this IAM policy: the bootstrap Lambda maps this
  # authenticated role into an OpenSearch role whose permissions decide what a logged-in
  # user can actually read or change. The IAM breadth here does not grant data access on its
  # own — FGAC is the control boundary.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["es:ESHttpGet", "es:ESHttpPost", "es:ESHttpPut", "es:ESHttpDelete", "es:ESHttpHead", "es:ESHttpPatch"]
      Resource = "${local.domain_arn}/*"
    }]
  })
}

resource "aws_cognito_identity_pool_roles_attachment" "dashboards" {
  count            = local.cognito_enabled ? 1 : 0
  identity_pool_id = aws_cognito_identity_pool.dashboards[0].id
  roles = {
    authenticated = aws_iam_role.cognito_authenticated[0].arn
  }

  # Set the authenticated role only after OpenSearch has wired its app client into
  # the identity pool, so this attachment is not overwritten by the domain update.
  depends_on = [aws_opensearch_domain.obs]
}

# --------------------------------------------------------------------------- #
# Demo operator user. When an email is supplied, Cognito emails an invitation with a
# temporary password; the user sets a permanent password on first sign-in.
# --------------------------------------------------------------------------- #

resource "aws_cognito_user" "operator" {
  count        = local.cognito_enabled && var.dashboards_notification_email != "" ? 1 : 0
  user_pool_id = aws_cognito_user_pool.dashboards[0].id
  username     = var.dashboards_notification_email

  attributes = {
    email          = var.dashboards_notification_email
    email_verified = "true"
  }

  desired_delivery_mediums = ["EMAIL"]
}
