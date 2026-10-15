# Minimal inspection VPC for the test harness. It exists so the observation platform
# has a real VPC (for VPC Flow Logs), firewall subnets (for the Network Firewall
# endpoint) and TGW attachment subnets (for the Transit Gateway). No IGW/NAT is created
# — the demo injector fabricates the telemetry, so no real egress traffic is required.

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  # /28 subnets carved from the /24 VPC: firewall subnets at .0/.16, tgw at .32/.48.
  firewall_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  tgw_subnet_cidrs      = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + var.az_count)]
}

resource "aws_vpc" "test" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "${var.name_prefix}-inspection" })
}

# Adopt and lock down the VPC's default security group: no ingress or egress rules, so it
# denies all traffic. Nothing uses it (the firewall endpoints and TGW attachments get
# purpose-built SGs); this just ensures the default SG is not left permissive.
resource "aws_default_security_group" "test" {
  vpc_id = aws_vpc.test.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-default-locked" })
}

resource "aws_subnet" "firewall" {
  count             = var.az_count
  vpc_id            = aws_vpc.test.id
  cidr_block        = local.firewall_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = merge(var.tags, { Name = "${var.name_prefix}-fw-${local.azs[count.index]}" })
}

resource "aws_subnet" "tgw" {
  count             = var.az_count
  vpc_id            = aws_vpc.test.id
  cidr_block        = local.tgw_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = merge(var.tags, { Name = "${var.name_prefix}-tgw-${local.azs[count.index]}" })
}

# VPC Flow Logs for the test inspection VPC, delivered to the existing NFW flow-log
# bucket (its policy already grants delivery.logs.amazonaws.com write access). The VPC
# carries no real egress traffic — the injector fabricates telemetry — so this exists to
# satisfy flow-log coverage rather than to capture live traffic.
resource "aws_flow_log" "test" {
  vpc_id               = aws_vpc.test.id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = aws_s3_bucket.flow.arn
  tags                 = var.tags
}
