# IAM Access Analyzer (account scope) for the test account, addressing the
# "IAM Access Analyzer Not Enabled" control.
resource "aws_accessanalyzer_analyzer" "account" {
  analyzer_name = "${var.name_prefix}-account"
  type          = "ACCOUNT"
  tags          = var.tags
}
