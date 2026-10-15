# These outputs map directly onto the observation platform's input variables.
# Copy them into a platform tfvars file (see examples/test-harness.tfvars).

output "firewall_name" {
  description = "-> platform var.firewall_name"
  value       = aws_networkfirewall_firewall.this.name
}

output "nfw_alert_log_group_name" {
  description = "-> platform var.nfw_alert_log_group_name"
  value       = aws_cloudwatch_log_group.alert.name
}

output "nfw_flow_logs_bucket_name" {
  description = "-> platform var.existing_nfw_flow_logs_bucket_name"
  value       = aws_s3_bucket.flow.id
}

output "demo_flow_logs_bucket_name" {
  description = "-> platform var.demo_flow_logs_bucket_name (dedicated bucket for the demo injector's synthetic nfw_flow logs)"
  value       = aws_s3_bucket.demo_flow.id
}

output "transit_gateway_id" {
  description = "-> platform var.transit_gateway_id (with create_tgw_flow_logs = true)"
  value       = aws_ec2_transit_gateway.test.id
}

output "vpc_ids" {
  description = "-> platform var.vpc_ids (with create_vpc_flow_logs = true)"
  value       = [aws_vpc.test.id]
}

# Convenience: a ready-to-paste block of platform variables.
output "platform_tfvars_snippet" {
  description = "Paste this into a platform tfvars file to point the platform at this harness."
  value       = <<-EOT
    firewall_name                      = "${aws_networkfirewall_firewall.this.name}"
    nfw_alert_log_group_name           = "${aws_cloudwatch_log_group.alert.name}"
    existing_nfw_flow_logs_bucket_name = "${aws_s3_bucket.flow.id}"
    demo_flow_logs_bucket_name         = "${aws_s3_bucket.demo_flow.id}"
    create_tgw_flow_logs               = true
    transit_gateway_id                 = "${aws_ec2_transit_gateway.test.id}"
    create_vpc_flow_logs               = true
    vpc_ids                            = ["${aws_vpc.test.id}"]
  EOT
}
