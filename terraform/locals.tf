locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  # A single dedicated CMK is created when the caller does not supply one.
  create_kms  = var.kms_key_arn == ""
  kms_key_arn = local.create_kms ? aws_kms_key.platform[0].arn : var.kms_key_arn

  common_tags = merge(var.tags, {
    Platform = "network-observation-platform"
  })
}
