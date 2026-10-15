# Central analysis bucket. Created only when create_analysis_bucket = true;
# otherwise the module references the existing bucket by name.
# force_destroy is controlled by var.analysis_bucket_force_destroy: true (PoC default) lets
# `tofu destroy` empty the bucket (object versions and delete markers included, since
# versioning is enabled) so teardown does not fail with BucketNotEmpty; the hardened example
# sets it false so a destroy cannot silently delete versioned telemetry.
# Security properties enforced on this bucket by the companion resources below: SSE-KMS
# encryption with the platform CMK, object versioning, server access logging to a dedicated
# log bucket, a full public-access block, lifecycle tiering/expiry, and TLS-only access.
# kics-scan ignore-block
resource "aws_s3_bucket" "analysis" {
  #checkov:skip=CKV_AWS_145:SSE-KMS (CMK) is configured via aws_s3_bucket_server_side_encryption_configuration.analysis.
  #checkov:skip=CKV2_AWS_62:Object-created notifications are configured in the s3-to-opensearch module (SQS); a second notification block here would conflict.
  #checkov:skip=CKV_AWS_21:Versioning is enabled via aws_s3_bucket_versioning.analysis.
  #checkov:skip=CKV_AWS_18:Server access logging is enabled via aws_s3_bucket_logging.analysis.
  #checkov:skip=CKV2_AWS_6:A public-access block is configured via aws_s3_bucket_public_access_block.analysis.
  #checkov:skip=CKV2_AWS_61:A lifecycle configuration is present via aws_s3_bucket_lifecycle_configuration.analysis.
  #checkov:skip=CKV_AWS_144:Single-region reference architecture; cross-region replication is a deliberate adopter decision.
  count         = var.create_analysis_bucket ? 1 : 0
  bucket        = "${var.name_prefix}-analysis-${local.account_id}"
  force_destroy = var.analysis_bucket_force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "analysis" {
  count                   = var.create_analysis_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.analysis[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "analysis" {
  count  = var.create_analysis_bucket ? 1 : 0
  bucket = aws_s3_bucket.analysis[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "analysis" {
  count  = var.create_analysis_bucket ? 1 : 0
  bucket = aws_s3_bucket.analysis[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "analysis" {
  count  = var.create_analysis_bucket ? 1 : 0
  bucket = aws_s3_bucket.analysis[0].id

  rule {
    id     = "tier-and-expire"
    status = "Enabled"
    filter {}

    transition {
      days          = var.s3_transition_ia_days
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = var.s3_transition_glacier_days
      storage_class = "GLACIER"
    }
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  rule {
    id     = "abort-incomplete-multipart-upload"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Enforce TLS-only access to the analysis bucket: the DenyInsecureTransport statement denies
# any request made over plaintext HTTP (aws:SecureTransport = false). The policy is inlined
# via jsonencode so the deny statement is explicit in the bucket policy.
resource "aws_s3_bucket_policy" "analysis" {
  count  = var.create_analysis_bucket ? 1 : 0
  bucket = aws_s3_bucket.analysis[0].id
  policy = <<-POLICY
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "DenyInsecureTransport",
          "Effect": "Deny",
          "Principal": "*",
          "Action": "s3:*",
          "Resource": ["${aws_s3_bucket.analysis[0].arn}", "${aws_s3_bucket.analysis[0].arn}/*"],
          "Condition": { "Bool": { "aws:SecureTransport": "false" } }
        }
      ]
    }
  POLICY
}

###############################################################################
# S3 server access logging for the analysis bucket.
#
# Records object-level access to the central telemetry store. Logs are delivered to a
# dedicated log bucket (never the same bucket — that would recurse) that the platform
# creates by default, or to an existing central log bucket if you set
# existing_access_log_bucket_name.
#
# The log bucket is encrypted with SSE-S3 (AES256), NOT the CMK: S3 server-access-log
# delivery to an SSE-KMS bucket requires a key grant for the log-delivery service, and
# these access logs are request metadata rather than the sensitive telemetry itself, so
# SSE-S3 keeps delivery robust without widening the CMK's grants. For near-real-time,
# IAM-attributed object access instead, enable CloudTrail S3 data events (see cloudtrail.tf).
###############################################################################

locals {
  create_access_log_bucket = var.create_analysis_bucket && var.enable_s3_access_logging && var.existing_access_log_bucket_name == ""
  access_log_bucket_name = (
    var.existing_access_log_bucket_name != "" ? var.existing_access_log_bucket_name :
    (local.create_access_log_bucket ? aws_s3_bucket.access_logs[0].id : "")
  )
}

# Dedicated server-access-log sink for the analysis bucket. Security properties enforced by
# the companion resources below: SSE-S3 (AES256) encryption, a full public-access block,
# lifecycle expiry, and TLS-only access. It is itself the log target, so versioning and
# self-logging are intentionally omitted (they would only accrue noncurrent log objects or
# recurse).
# kics-scan ignore-block
resource "aws_s3_bucket" "access_logs" {
  #checkov:skip=CKV_AWS_145:Server-access-log sink intentionally uses SSE-S3 (AES256); S3 log delivery to an SSE-KMS bucket needs a key grant for the log-delivery service, and these are request-metadata logs, so SSE-S3 keeps delivery robust.
  #checkov:skip=CKV2_AWS_62:Dedicated log-delivery sink; S3 event notifications are not part of its design.
  #checkov:skip=CKV_AWS_21:Dedicated server-access-log sink (append-only, lifecycle-expired); versioning adds no value and would accrue noncurrent log objects. By design.
  #checkov:skip=CKV_AWS_18:This bucket IS the server-access-log target; enabling access logging on a log sink would recurse. By design.
  #checkov:skip=CKV_AWS_144:Single-region reference architecture; cross-region replication is a deliberate adopter cost/architecture decision, not configured here.
  count         = local.create_access_log_bucket ? 1 : 0
  bucket        = "${var.name_prefix}-access-logs-${local.account_id}"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  count                   = local.create_access_log_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.access_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  count  = local.create_access_log_bucket ? 1 : 0
  bucket = aws_s3_bucket.access_logs[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  count  = local.create_access_log_bucket ? 1 : 0
  bucket = aws_s3_bucket.access_logs[0].id
  rule {
    id     = "expire-access-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = var.audit_log_retention_days
    }
  }

  rule {
    id     = "abort-incomplete-multipart-upload"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Modern (bucket-policy, ACL-free) grant for the S3 log-delivery service to write logs,
# scoped to the source bucket and this account, plus TLS-only enforcement: the
# DenyInsecureTransport statement denies any plaintext-HTTP request. Inlined via jsonencode
# so both statements are explicit in the bucket policy.
resource "aws_s3_bucket_policy" "access_logs" {
  count  = local.create_access_log_bucket ? 1 : 0
  bucket = aws_s3_bucket.access_logs[0].id
  policy = <<-POLICY
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "S3ServerAccessLogsPolicy",
          "Effect": "Allow",
          "Principal": { "Service": "logging.s3.amazonaws.com" },
          "Action": "s3:PutObject",
          "Resource": "${aws_s3_bucket.access_logs[0].arn}/*",
          "Condition": {
            "ArnLike": { "aws:SourceArn": "${aws_s3_bucket.analysis[0].arn}" },
            "StringEquals": { "aws:SourceAccount": "${local.account_id}" }
          }
        },
        {
          "Sid": "DenyInsecureTransport",
          "Effect": "Deny",
          "Principal": "*",
          "Action": "s3:*",
          "Resource": ["${aws_s3_bucket.access_logs[0].arn}", "${aws_s3_bucket.access_logs[0].arn}/*"],
          "Condition": { "Bool": { "aws:SecureTransport": "false" } }
        }
      ]
    }
  POLICY
}

# Point the analysis bucket's server access logging at the log bucket. Only when the
# platform manages the analysis bucket (brownfield deployments configure this on their
# own bucket) and a log target is resolved.
# count depends only on plan-time-known variables (not local.access_log_bucket_name, which
# embeds the created bucket's id and is unknown until apply). When both toggles are on the
# target always resolves — to the dedicated bucket we create, or existing_access_log_bucket_name.
resource "aws_s3_bucket_logging" "analysis" {
  count         = var.create_analysis_bucket && var.enable_s3_access_logging ? 1 : 0
  bucket        = aws_s3_bucket.analysis[0].id
  target_bucket = local.access_log_bucket_name
  target_prefix = "s3-access/"
}
