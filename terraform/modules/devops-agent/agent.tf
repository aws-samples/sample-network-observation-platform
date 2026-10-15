###############################################################################
# AWS DevOps Agent: agent space + operator app + account association.
###############################################################################

# Give IAM trust policies time to propagate before the service validates them.
resource "time_sleep" "wait_for_iam" {
  depends_on = [
    aws_iam_role.agentspace,
    aws_iam_role_policy_attachment.agentspace_access,
    aws_iam_role_policy.agentspace_inline,
    aws_iam_role.operator,
    aws_iam_role_policy_attachment.operator_access,
  ]
  create_duration = "30s"
}

resource "awscc_devopsagent_agent_space" "this" {
  name        = var.agent_space_name
  description = var.agent_space_description

  operator_app = {
    iam = {
      operator_app_role_arn = aws_iam_role.operator.arn
    }
  }

  depends_on = [time_sleep.wait_for_iam]
}

# Associate this account for monitoring, so the agent can investigate its resources.
resource "awscc_devopsagent_association" "account" {
  agent_space_id = awscc_devopsagent_agent_space.this.id
  service_id     = "aws"

  configuration = {
    aws = {
      assumable_role_arn = aws_iam_role.agentspace.arn
      account_id         = local.account_id
      account_type       = "monitor"
      resources          = []
    }
  }

  depends_on = [awscc_devopsagent_agent_space.this]
}
