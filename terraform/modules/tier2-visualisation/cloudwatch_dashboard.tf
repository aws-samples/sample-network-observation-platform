# Native CloudWatch quick-view dashboard: at-a-glance health of the network data plane and
# the consolidation platform, complementing (not replacing) the rich OpenSearch dashboards and
# the native AWS Network Firewall monitoring dashboard.
#
# Widgets (all from native CloudWatch metrics):
#   - AWS Network Firewall: traffic verdicts, and drops / TLS inspection (AWS/NetworkFirewall).
#   - Transit Gateway: throughput, and blackhole / no-route dropped packets (AWS/TransitGateway).
#   - Consolidation pipeline: Firehose delivery to S3 (AWS/Firehose).
#   - OpenSearch domain health (AWS/ES).
#   - Direct Connect link health per connection, appended when dx_connection_ids is set.
# Firewall and TGW metrics are summed across their sub-dimensions (AZ / attachment) per
# resource with a metric-math SEARCH, so each works regardless of how many AZs/attachments
# exist. They reflect real data-plane traffic, so they read near zero until the firewall /
# TGW carries live traffic (a synthetic-log demo does not drive them).
#
# The full per-flow detail for every source (Network Firewall, DNS Firewall, VPC and Transit
# Gateway flow, CloudTrail) is normalised into the consolidated lake and explored in the
# OpenSearch dashboards / Athena — CloudWatch metrics exist only for the services that emit
# them, so this view is service health, not the cross-source record analytics.

locals {
  # ---- AWS Network Firewall (AWS/NetworkFirewall), summed across AZs for this firewall ----
  nfw_metric = { for m in [
    { metric = "ReceivedPackets", label = "Received", id = "nfw_recv" },
    { metric = "PassedPackets", label = "Passed", id = "nfw_pass" },
    { metric = "DroppedPackets", label = "Dropped", id = "nfw_drop" },
    { metric = "RejectedPackets", label = "Rejected", id = "nfw_rej" },
    { metric = "OtherDroppedPackets", label = "Other dropped", id = "nfw_other" },
    { metric = "InvalidDroppedPackets", label = "Invalid dropped", id = "nfw_inval" },
    { metric = "StreamExceptionPolicyPackets", label = "Stream exception", id = "nfw_strm" },
    { metric = "TLSErrors", label = "TLS errors", id = "nfw_tls" },
    ] : m.metric => m }
  nfw_expr = { for k, m in local.nfw_metric : k =>
    [{
      expression = "SUM(SEARCH('Namespace=\"AWS/NetworkFirewall\" FirewallName=\"${var.firewall_name}\" MetricName=\"${m.metric}\"', 'Sum', 300))"
      label      = m.label
      id         = m.id
    }]
  }
  nfw_widgets = var.firewall_name == "" ? [] : [
    {
      type = "metric", x = 0, y = 3, width = 12, height = 6,
      properties = {
        title = "Network Firewall — traffic verdicts (packets)", region = local.region,
        view = "timeSeries", stacked = false, period = 300,
        metrics = [local.nfw_expr["ReceivedPackets"], local.nfw_expr["PassedPackets"], local.nfw_expr["DroppedPackets"], local.nfw_expr["RejectedPackets"]]
      }
    },
    {
      type = "metric", x = 12, y = 3, width = 12, height = 6,
      properties = {
        title = "Network Firewall — drops & TLS inspection (packets)", region = local.region,
        view = "timeSeries", stacked = false, period = 300,
        metrics = [local.nfw_expr["OtherDroppedPackets"], local.nfw_expr["InvalidDroppedPackets"], local.nfw_expr["StreamExceptionPolicyPackets"], local.nfw_expr["TLSErrors"]]
      }
    },
  ]

  # ---- Transit Gateway (AWS/TransitGateway), summed across attachments for this TGW ----
  tgw_metric = { for m in [
    { metric = "BytesIn", label = "Bytes in", id = "tgw_bin" },
    { metric = "BytesOut", label = "Bytes out", id = "tgw_bout" },
    { metric = "PacketDropCountBlackhole", label = "Dropped (blackhole)", id = "tgw_blk" },
    { metric = "PacketDropCountNoRoute", label = "Dropped (no route)", id = "tgw_nrt" },
    ] : m.metric => m }
  tgw_expr = { for k, m in local.tgw_metric : k =>
    [{
      expression = "SUM(SEARCH('Namespace=\"AWS/TransitGateway\" TransitGateway=\"${var.transit_gateway_id}\" MetricName=\"${m.metric}\"', 'Sum', 300))"
      label      = m.label
      id         = m.id
    }]
  }
  tgw_widgets = var.transit_gateway_id == "" ? [] : [
    {
      type = "metric", x = 0, y = 9, width = 12, height = 6,
      properties = {
        title = "Transit Gateway — throughput (bytes)", region = local.region,
        view = "timeSeries", stacked = false, period = 300,
        metrics = [local.tgw_expr["BytesIn"], local.tgw_expr["BytesOut"]]
      }
    },
    {
      type = "metric", x = 12, y = 9, width = 12, height = 6,
      properties = {
        title = "Transit Gateway — dropped packets (blackhole / no-route)", region = local.region,
        view = "timeSeries", stacked = false, period = 300,
        metrics = [local.tgw_expr["PacketDropCountBlackhole"], local.tgw_expr["PacketDropCountNoRoute"]]
      }
    },
  ]

  cw_dashboard_body = jsonencode({
    widgets = concat([
      {
        type = "text", x = 0, y = 0, width = 24, height = 3,
        properties = {
          markdown = join("\n", [
            "# Network Observation — quick view",
            "Native CloudWatch health for the network data plane: **AWS Network Firewall** verdicts and drops/TLS, and **Transit Gateway** throughput and blackhole/no-route drops — plus the platform's **Firehose → S3** consolidation pipeline and **OpenSearch** domain.",
            "Every source (Network Firewall, DNS Firewall, VPC and Transit Gateway flow, CloudTrail) is normalised into the consolidated lake: use the **OpenSearch Dashboards** (`network-events-*`) and **Amazon Athena** (workgroup `${var.athena_workgroup}`) for cross-source analysis — top talkers, allow vs deny, blocked domains, per-rule SID trends, geo. For single-firewall packet/flow detail use the native **AWS Network Firewall monitoring dashboard** in the console.",
            var.iac_repo_url != "" ? "**Log → rule:** open a Suricata SID at ${var.iac_repo_url}/search?q=<SID>" : "**Log → rule:** set `iac_repo_url` to enable the SID deep link.",
          ])
        }
      },
      {
        type = "metric", x = 0, y = 15, width = 12, height = 6,
        properties = {
          title   = "Consolidation pipeline — Firehose delivery to S3",
          region  = local.region,
          view    = "timeSeries",
          stacked = false,
          metrics = [
            ["AWS/Firehose", "DeliveryToS3.Records", "DeliveryStreamName", "${var.name_prefix}-consolidated"],
            ["AWS/Firehose", "DeliveryToS3.DataFreshness", "DeliveryStreamName", "${var.name_prefix}-consolidated"]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 15, width = 12, height = 6,
        properties = {
          title   = "OpenSearch domain health",
          region  = local.region,
          view    = "timeSeries",
          stacked = false,
          metrics = [
            ["AWS/ES", "ClusterStatus.yellow", "DomainName", local.domain_name, "ClientId", local.account_id],
            ["AWS/ES", "ClusterStatus.red", "DomainName", local.domain_name, "ClientId", local.account_id],
            ["AWS/ES", "SearchableDocuments", "DomainName", local.domain_name, "ClientId", local.account_id]
          ]
        }
      }
    ], local.nfw_widgets, local.tgw_widgets, local.dx_widgets)
  })
}

resource "aws_cloudwatch_dashboard" "quick_view" {
  count          = var.create_cloudwatch_dashboard ? 1 : 0
  dashboard_name = "${var.name_prefix}-quick-view"
  dashboard_body = local.cw_dashboard_body
}
