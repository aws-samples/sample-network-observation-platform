output "agent_space_id" {
  description = "AWS DevOps Agent agent space ID."
  value       = awscc_devopsagent_agent_space.this.id
}

output "agent_space_arn" {
  description = "AWS DevOps Agent agent space ARN."
  value       = awscc_devopsagent_agent_space.this.arn
}

output "agent_space_name" {
  description = "AWS DevOps Agent agent space name."
  value       = awscc_devopsagent_agent_space.this.name
}

output "agentspace_role_arn" {
  description = "IAM role the agent assumes to monitor the account."
  value       = aws_iam_role.agentspace.arn
}

output "operator_role_arn" {
  description = "IAM role backing the operator app (where humans ask questions)."
  value       = aws_iam_role.operator.arn
}

output "elevated_role_arn" {
  description = "Elevated (directed-actions) role ARN to register on the association via `aws devops-agent update-association` (null when disabled)."
  value       = var.enable_directed_actions ? aws_iam_role.elevated[0].arn : null
}

output "region" {
  description = "Region the agent space is deployed in (a DevOps Agent supported Region)."
  value       = local.region
}
