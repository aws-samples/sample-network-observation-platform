###############################################################################
# CloudTrail S3 data events on the analysis bucket (opt-in; hardened profile).
#
# The near-real-time, IAM-attributed complement to S3 server access logging: every
# GetObject/PutObject on the consolidated telemetry becomes a CloudTrail data event with
# the full caller identity, source IP and session. Off by default because data events are
# billed per event and this bucket is written continuously by Firehose and Athena; enable
# it in production where per-object attribution is required.
#
# A dedicated regional trail scoped to *data* events only (management events are assumed to
# be covered by an organisation trail). Trail log files are delivered to a dedicated bucket
# encrypted with SSE-S3 to avoid widening the CMK grant to the CloudTrail service.
###############################################################################

locals {
  ct_enabled     = var.enable_cloudtrail_data_events
  ct_trail_name  = "${var.name_prefix}-s3-data-events"
  ct_bucket_name = "${var.name_prefix}-cloudtrail-${local.account_id}"
  ct_trail_arn   = "arn:${local.partition}:cloudtrail:${local.region}:${local.account_id}:trail/${local.ct_trail_name}"
}

# This bucket is created with count (conditional on enable_cloudtrail_data_events). KICS's
# "S3 Bucket Without Versioning"/"S3 Bucket Logging Disabled" matcher correlates a bucket to
# its versioning/logging resources via split(bucket,".")[1], which yields "cloudtrail[0]"
# for a count-indexed bucket and never matches "cloudtrail" - a false positive that no code
# change clears without removing count (which would break the conditional creation). It is a
# dedicated CloudTrail log sink (immutable, lifecycle-expired, log-file-validation enabled),
# so versioning/self-logging add no value. Suppress the KICS false positives on this block.
# kics-scan ignore-block
resource "aws_s3_bucket" "cloudtrail" {
  #checkov:skip=CKV_AWS_145:CloudTrail log sink intentionally uses SSE-S3 (AES256) to avoid widening the platform CMK grant to the CloudTrail service; see the encryption block below.
  #checkov:skip=CKV2_AWS_62:Dedicated CloudTrail log sink; S3 event notifications are not part of its design.
  #checkov:skip=CKV_AWS_21:Dedicated CloudTrail log sink — immutable, lifecycle-expired, log-file-validation enabled; versioning adds no value and would accrue noncurrent objects. By design.
  #checkov:skip=CKV_AWS_18:This bucket IS the CloudTrail log target; enabling S3 server access logging on a log sink would recurse. By design.
  #checkov:skip=CKV_AWS_144:Single-region reference architecture; cross-region replication is a deliberate adopter cost/architecture decision, not configured here.
  count         = local.ct_enabled ? 1 : 0
  bucket        = local.ct_bucket_name
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  count                   = local.ct_enabled ? 1 : 0
  bucket                  = aws_s3_bucket.cloudtrail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  count  = local.ct_enabled ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  count  = local.ct_enabled ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id
  rule {
    id     = "expire-trail-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = var.audit_log_retention_days
    }
  }
}

# Inlined via jsonencode (instead of an aws_iam_policy_document data source) so static
# analysers can read the DenyInsecureTransport statement directly from the bucket policy
# rather than an unresolved data-source reference.
resource "aws_s3_bucket_policy" "cloudtrail" {
  count  = local.ct_enabled ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id
  policy = <<-POLICY
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "AWSCloudTrailAclCheck",
          "Effect": "Allow",
          "Principal": { "Service": "cloudtrail.amazonaws.com" },
          "Action": "s3:GetBucketAcl",
          "Resource": "${aws_s3_bucket.cloudtrail[0].arn}",
          "Condition": { "StringEquals": { "aws:SourceArn": "${local.ct_trail_arn}" } }
        },
        {
          "Sid": "AWSCloudTrailWrite",
          "Effect": "Allow",
          "Principal": { "Service": "cloudtrail.amazonaws.com" },
          "Action": "s3:PutObject",
          "Resource": "${aws_s3_bucket.cloudtrail[0].arn}/AWSLogs/${local.account_id}/*",
          "Condition": {
            "StringEquals": {
              "s3:x-amz-acl": "bucket-owner-full-control",
              "aws:SourceArn": "${local.ct_trail_arn}"
            }
          }
        },
        {
          "Sid": "DenyInsecureTransport",
          "Effect": "Deny",
          "Principal": "*",
          "Action": "s3:*",
          "Resource": ["${aws_s3_bucket.cloudtrail[0].arn}", "${aws_s3_bucket.cloudtrail[0].arn}/*"],
          "Condition": { "Bool": { "aws:SecureTransport": "false" } }
        }
      ]
    }
  POLICY
}

resource "aws_cloudtrail" "s3_data_events" {
  #checkov:skip=CKV2_AWS_10:Opt-in S3 data-events trail delivering to a dedicated S3 bucket with log-file validation; CloudWatch Logs integration is extra ingestion cost, not required for per-object S3 audit. Management events are assumed covered by an org trail.
  #checkov:skip=CKV_AWS_67:Single-region data-events trail by design; management events are assumed covered by an organisation trail. Multi-region is a deliberate scope decision for this sample.
  count                         = local.ct_enabled ? 1 : 0
  name                          = local.ct_trail_name
  s3_bucket_name                = aws_s3_bucket.cloudtrail[0].id
  include_global_service_events = false
  is_multi_region_trail         = false
  enable_log_file_validation    = true
  enable_logging                = true
  tags                          = var.tags

  # Data events only, scoped to objects in the analysis bucket. Management events are
  # assumed to be captured by an organisation trail.
  advanced_event_selector {
    name = "S3 object data events on the analysis bucket"
    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }
    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }
    field_selector {
      field       = "resources.ARN"
      starts_with = ["arn:${local.partition}:s3:::${local.analysis_bucket_name}/"]
    }
  }

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}
