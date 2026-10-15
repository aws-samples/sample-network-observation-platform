data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

# --------------------------------------------------------------------------- #
# Log destinations the observation platform consumes
# --------------------------------------------------------------------------- #

# Alert logs -> CloudWatch Logs (the platform subscribes this group to Firehose).
resource "aws_cloudwatch_log_group" "alert" {
  name              = "/${var.name_prefix}/network-firewall/alert"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.harness.arn
  tags              = var.tags
}

# Flow logs -> S3 (the platform catalogs this bucket in place for Athena). This is itself a
# log-delivery sink (the firewall writes flow logs here), so S3 server-access logging on it
# adds no value; suppress the KICS "logging disabled" finding on this disposable test bucket.
# kics-scan ignore-block
resource "aws_s3_bucket" "flow" {
  #checkov:skip=CKV_AWS_144:Disposable test-harness flow-log sink (Lifecycle=disposable-test) holding only synthetic data; cross-region replication is not warranted for throwaway test infrastructure.
  #checkov:skip=CKV_AWS_145:Intentionally SSE-S3 (AES256) to keep AWS log delivery robust without a CMK grant; the bucket holds only synthetic test flow logs. Used in tests.
  #checkov:skip=CKV_AWS_18:This bucket IS the flow-log delivery sink; S3 server access logging on a disposable test log bucket adds no value and would recurse.
  #checkov:skip=CKV2_AWS_62:No consumer needs S3 object-created events; the platform catalogs this disposable test bucket in place for Athena. Not applicable.
  bucket        = "${var.name_prefix}-nfw-flow-${local.account_id}"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "flow" {
  bucket                  = aws_s3_bucket.flow.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flow" {
  bucket = aws_s3_bucket.flow.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "flow" {
  bucket = aws_s3_bucket.flow.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "flow" {
  bucket = aws_s3_bucket.flow.id
  rule {
    id     = "expire-flow-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
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

# Bucket policy allowing the AWS log-delivery service to write flow logs.
data "aws_iam_policy_document" "flow_bucket" {
  statement {
    sid       = "AWSLogDeliveryWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.flow.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
  statement {
    sid       = "AWSLogDeliveryAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.flow.arn]
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
  }

  # Enforce TLS-only access to the flow-log bucket.
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.flow.arn, "${aws_s3_bucket.flow.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "flow" {
  bucket = aws_s3_bucket.flow.id
  policy = data.aws_iam_policy_document.flow_bucket.json
}

# --------------------------------------------------------------------------- #
# Dedicated bucket for the demo data injector's SYNTHETIC nfw_flow logs. Kept separate
# from aws_s3_bucket.flow (the real firewall flow-log sink) so synthetic data never lands
# in the firewall's own flow-log bucket. Wired to the platform via
# demo_flow_logs_bucket_name in examples/test-harness.tfvars.
# kics-scan ignore-block
resource "aws_s3_bucket" "demo_flow" {
  #checkov:skip=CKV_AWS_144:Disposable test-harness synthetic-data sink (Lifecycle=disposable-test); cross-region replication is not warranted for throwaway test infrastructure.
  #checkov:skip=CKV_AWS_145:Intentionally SSE-S3 (AES256) so the injector Lambda writes without a CMK grant; the bucket holds only synthetic test flow logs.
  #checkov:skip=CKV_AWS_18:Disposable synthetic-data sink; S3 server access logging on a throwaway test bucket adds no value.
  #checkov:skip=CKV2_AWS_62:No consumer needs S3 object-created events on this synthetic-data sink. Not applicable.
  bucket        = "${var.name_prefix}-demo-flow-${local.account_id}"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "demo_flow" {
  bucket                  = aws_s3_bucket.demo_flow.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "demo_flow" {
  bucket = aws_s3_bucket.demo_flow.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "demo_flow" {
  bucket = aws_s3_bucket.demo_flow.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "demo_flow" {
  bucket = aws_s3_bucket.demo_flow.id
  rule {
    id     = "expire-demo-flow-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
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

# Enforce TLS-only access to the synthetic demo flow-log bucket.
resource "aws_s3_bucket_policy" "demo_flow" {
  bucket = aws_s3_bucket.demo_flow.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.demo_flow.arn, "${aws_s3_bucket.demo_flow.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}

# --------------------------------------------------------------------------- #
# Stateful rule group — a handful of Suricata rules with SIDs. The platform's rule-hygiene
# report reconciles the SIDs defined here against the SIDs seen in the consolidated logs. A
# few SIDs are intentionally never matched by the demo traffic so zero-hit candidates exist.
# --------------------------------------------------------------------------- #

resource "aws_networkfirewall_rule_group" "stateful" {
  name     = "${var.name_prefix}-stateful"
  type     = "STATEFUL"
  capacity = 100
  tags     = var.tags

  encryption_configuration {
    type   = "CUSTOMER_KMS"
    key_id = aws_kms_key.harness.arn
  }

  rule_group {
    rules_source {
      rules_string = <<-RULES
        alert tls any any -> any any (msg:"DEMO alert on partner SNI"; tls.sni; content:"api.partner.example.com"; sid:3000010; rev:1;)
        drop tls any any -> any any (msg:"DEMO drop known-bad C2 SNI"; tls.sni; content:"c2.malware.example"; sid:3000011; rev:1;)
        drop tls any any -> any any (msg:"DEMO drop phishing SNI"; tls.sni; content:"phish-login.example"; sid:3000012; rev:1;)
        alert http any any -> any any (msg:"DEMO alert on tracker host"; http.host; content:"tracker.adtech.example"; sid:3000013; rev:1;)
        drop tcp any any -> any 3306 (msg:"DEMO drop unexpected MySQL egress"; flow:to_server; sid:3000014; rev:1;)
        alert tls any any -> any any (msg:"DEMO never-matched rule (zero-hit candidate)"; tls.sni; content:"unused-domain-should-never-appear.example"; sid:3000099; rev:1;)
      RULES
    }
  }
}

# --------------------------------------------------------------------------- #
# Firewall policy + firewall
# --------------------------------------------------------------------------- #

resource "aws_networkfirewall_firewall_policy" "this" {
  name = "${var.name_prefix}-policy"
  tags = var.tags

  encryption_configuration {
    type   = "CUSTOMER_KMS"
    key_id = aws_kms_key.harness.arn
  }

  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.stateful.arn
    }
  }
}

resource "aws_networkfirewall_firewall" "this" {
  # checkov:skip=CKV_AWS_344:Disposable test harness (tags Lifecycle=disposable-test); firewall deletion protection would block `terraform destroy` teardown. Not appropriate for throwaway test infrastructure.
  name                = "${var.name_prefix}-fw"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.this.arn
  vpc_id              = aws_vpc.test.id
  tags                = var.tags

  encryption_configuration {
    type   = "CUSTOMER_KMS"
    key_id = aws_kms_key.harness.arn
  }

  dynamic "subnet_mapping" {
    for_each = aws_subnet.firewall
    content {
      subnet_id = subnet_mapping.value.id
    }
  }
}

resource "aws_networkfirewall_logging_configuration" "this" {
  firewall_arn = aws_networkfirewall_firewall.this.arn

  logging_configuration {
    log_destination_config {
      log_type             = "ALERT"
      log_destination_type = "CloudWatchLogs"
      log_destination = {
        logGroup = aws_cloudwatch_log_group.alert.name
      }
    }
    log_destination_config {
      log_type             = "FLOW"
      log_destination_type = "S3"
      log_destination = {
        bucketName = aws_s3_bucket.flow.id
        prefix     = "flow"
      }
    }
  }

  depends_on = [aws_s3_bucket_policy.flow]
}
