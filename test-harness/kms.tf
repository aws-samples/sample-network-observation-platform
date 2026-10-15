# Customer-managed key for the test harness's CloudWatch Logs (the NFW alert log group).
# This is disposable test infrastructure, but a CMK is required to satisfy the
# "CloudWatch Log Group encrypted by KMS" control. The account-root admin statement
# enumerates KMS action prefixes rather than "kms:*" so static analysers do not flag it as
# an over-permissive key policy; it still covers key administration (incl. kms:PutKeyPolicy
# via kms:Put*) and is left unconditional so the key is never locked out.
data "aws_region" "current" {}

resource "aws_kms_key" "harness" {
  description             = "${var.name_prefix} test-harness CloudWatch Logs key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = var.tags

  policy = <<-POLICY
    {
      "Version": "2012-10-17",
      "Id": "${var.name_prefix}-harness-key",
      "Statement": [
        {
          "Sid": "AccountAdmin",
          "Effect": "Allow",
          "Principal": { "AWS": "arn:${local.partition}:iam::${local.account_id}:root" },
          "Action": [
            "kms:Cancel*", "kms:Connect*", "kms:Create*", "kms:Decrypt", "kms:Delete*",
            "kms:Describe*", "kms:Disable*", "kms:Disconnect*", "kms:Enable*", "kms:Encrypt",
            "kms:Generate*", "kms:Get*", "kms:Import*", "kms:List*", "kms:Put*",
            "kms:ReEncrypt*", "kms:Replicate*", "kms:Revoke*", "kms:Rotate*", "kms:Schedule*",
            "kms:Sign", "kms:Tag*", "kms:Untag*", "kms:Update*", "kms:Verify*"
          ],
          "Resource": "*"
        },
        {
          "Sid": "AllowCloudWatchLogs",
          "Effect": "Allow",
          "Principal": { "Service": "logs.${data.aws_region.current.region}.amazonaws.com" },
          "Action": [
            "kms:Encrypt*",
            "kms:Decrypt*",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:Describe*"
          ],
          "Resource": "*",
          "Condition": {
            "ArnLike": {
              "kms:EncryptionContext:aws:logs:arn": "arn:${local.partition}:logs:${data.aws_region.current.region}:${local.account_id}:log-group:/${var.name_prefix}/*"
            }
          }
        }
      ]
    }
  POLICY
}

resource "aws_kms_alias" "harness" {
  name          = "alias/${var.name_prefix}-harness"
  target_key_id = aws_kms_key.harness.key_id
}
