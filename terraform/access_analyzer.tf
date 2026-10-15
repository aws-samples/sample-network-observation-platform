# IAM Access Analyzer (account scope). Continuously monitors resource-based policies and
# flags access granted to principals outside the account (the zone of trust), addressing
# the "IAM Access Analyzer Not Enabled" control. One analyzer covers the whole account.
#
# Off by default (create_access_analyzer = false): the platform usually deploys into an
# existing Security Tooling / Log Archive account that already has an account-scope
# analyzer, and AWS permits only one ACCOUNT analyzer per Region — creating a second one
# fails with ServiceQuotaExceededException. Enable it for a standalone/greenfield account.
resource "aws_accessanalyzer_analyzer" "account" {
  count         = var.create_access_analyzer ? 1 : 0
  analyzer_name = "${var.name_prefix}-account"
  type          = "ACCOUNT"
  tags          = var.tags
}
