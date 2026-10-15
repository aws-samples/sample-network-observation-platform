# Dedicated customer-managed key for the analysis plane, created only when the
# caller does not supply an existing key ARN via var.kms_key_arn.
resource "aws_kms_key" "platform" {
  count                   = local.create_kms ? 1 : 0
  description             = "${var.name_prefix} network observation platform encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.common_tags

  # The key policy is defined inline on the key. The account-root admin statement enumerates
  # KMS action prefixes (which together cover every KMS action, including kms:PutKeyPolicy via
  # kms:Put*) rather than the "kms:*" wildcard, so the account root keeps full key
  # administration and can never be locked out of the key. It is intentionally unconditional
  # for the same reason — the account root must not lose access to the key.
  policy = <<-POLICY
    {
      "Version": "2012-10-17",
      "Id": "${var.name_prefix}-platform-key",
      "Statement": [
        {
          "Sid": "AccountAdmin",
          "Effect": "Allow",
          "Principal": { "AWS": "arn:${local.partition}:iam::${local.account_id}:root" },
          "Action": [
            "kms:Cancel*",
            "kms:Connect*",
            "kms:Create*",
            "kms:Decrypt",
            "kms:Delete*",
            "kms:Describe*",
            "kms:Disable*",
            "kms:Disconnect*",
            "kms:Enable*",
            "kms:Encrypt",
            "kms:Generate*",
            "kms:Get*",
            "kms:Import*",
            "kms:List*",
            "kms:Put*",
            "kms:ReEncrypt*",
            "kms:Replicate*",
            "kms:Revoke*",
            "kms:Rotate*",
            "kms:Schedule*",
            "kms:Sign",
            "kms:Tag*",
            "kms:Untag*",
            "kms:Update*",
            "kms:Verify*"
          ],
          "Resource": "*"
        },
        {
          "Sid": "AllowServiceUse",
          "Effect": "Allow",
          "Principal": {
            "Service": [
              "logs.${local.region}.amazonaws.com",
              "delivery.logs.amazonaws.com",
              "firehose.amazonaws.com",
              "es.amazonaws.com",
              "sns.amazonaws.com",
              "s3.amazonaws.com",
              "cloudwatch.amazonaws.com",
              "events.amazonaws.com"
            ]
          },
          "Action": [
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:DescribeKey"
          ],
          "Resource": "*"
        }
      ]
    }
  POLICY
}

resource "aws_kms_alias" "platform" {
  count         = local.create_kms ? 1 : 0
  name          = "alias/${var.name_prefix}"
  target_key_id = aws_kms_key.platform[0].key_id
}

# NOTE: The key policy (account-root admin + service-use grants) is defined inline on
# aws_kms_key.platform above. The AllowServiceUse grant intentionally carries no blanket
# aws:SourceAccount condition because the services that use this single-account, never-shared
# key authorise KMS differently (CloudWatch Logs via the aws:logs ARN EncryptionContext, S3
# SSE-KMS via the bucket aws:SourceArn, others via aws:SourceAccount), so one blanket
# condition would not fit all and would risk denying log delivery and encryption. If you
# share this key beyond one account, add the correct per-service condition for each principal
# and re-verify log delivery and OpenSearch/S3 encryption afterwards.
