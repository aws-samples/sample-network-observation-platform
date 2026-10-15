# Direct Connect health monitoring.
#
# Direct Connect and Direct Connect Gateway do not produce flow logs. The only
# telemetry AWS exposes is CloudWatch metrics in the AWS/DX namespace: connection
# state, optical light levels (Tx/Rx), CRC error counts, bits/packets per second and
# encryption state, plus per-virtual-interface throughput. Traffic *content* crossing
# Direct Connect is seen through the Transit Gateway / VPC Flow Logs on its attachment
# (Tier 1), not here. This file surfaces the physical/link health that a NOC watches —
# directly relevant to intermittent-loss and BGP/asymmetry investigations.

locals {
  dx_widgets = [
    for idx, cid in var.dx_connection_ids : {
      type = "metric", x = (idx % 2) * 12, y = 40 + floor(idx / 2) * 6, width = 12, height = 6,
      properties = {
        title  = "Direct Connect ${cid} — light levels & errors",
        region = local.region,
        view   = "timeSeries",
        metrics = [
          ["AWS/DX", "ConnectionLightLevelTx", "ConnectionId", cid],
          ["AWS/DX", "ConnectionLightLevelRx", "ConnectionId", cid],
          ["AWS/DX", "ConnectionCRCErrorCount", "ConnectionId", cid],
          ["AWS/DX", "ConnectionState", "ConnectionId", cid]
        ]
      }
    }
  ]
}

# Alarm: a Direct Connect connection drops (ConnectionState = 0 means down).
resource "aws_cloudwatch_metric_alarm" "dx_connection_down" {
  for_each            = toset(var.dx_connection_ids)
  alarm_name          = "${var.name_prefix}-dx-${each.value}-down"
  alarm_description   = "Direct Connect connection ${each.value} reports a down state."
  namespace           = "AWS/DX"
  metric_name         = "ConnectionState"
  dimensions          = { ConnectionId = each.value }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  ok_actions          = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  tags                = var.tags
}

# Alarm: rising CRC errors, an early indicator of a degrading circuit (the kind of
# signal behind intermittent packet loss on a redundant DX pair).
resource "aws_cloudwatch_metric_alarm" "dx_crc_errors" {
  for_each            = toset(var.dx_connection_ids)
  alarm_name          = "${var.name_prefix}-dx-${each.value}-crc-errors"
  alarm_description   = "Direct Connect connection ${each.value} is accumulating CRC errors."
  namespace           = "AWS/DX"
  metric_name         = "ConnectionCRCErrorCount"
  dimensions          = { ConnectionId = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  tags                = var.tags
}
