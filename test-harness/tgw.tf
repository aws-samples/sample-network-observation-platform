# Transit Gateway so the observation platform can enable TGW Flow Logs on it
# (the platform creates the flow log itself, given this transit_gateway_id).

resource "aws_ec2_transit_gateway" "test" {
  description                     = "${var.name_prefix} test transit gateway"
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"
  tags                            = merge(var.tags, { Name = "${var.name_prefix}-tgw" })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "test" {
  transit_gateway_id = aws_ec2_transit_gateway.test.id
  vpc_id             = aws_vpc.test.id
  subnet_ids         = aws_subnet.tgw[*].id
  tags               = merge(var.tags, { Name = "${var.name_prefix}-tgw-attach" })
}
