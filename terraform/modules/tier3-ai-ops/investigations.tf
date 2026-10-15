# Wiring for Amazon CloudWatch investigations.
#
# CloudWatch investigations auto-start from an "investigation group" that you enable
# once per account/Region and associate with alarms (console or CLI). Because that
# configuration surface is not yet exposed as a stable Terraform resource, this module
# provisions the deterministic, Terraform-manageable half: an EventBridge rule that
# reacts when any of the named alarms enters ALARM, and forwards the event to SNS so
# the on-call is notified the moment an investigation begins. The one-time association
# of these alarms with the investigation group is documented in the README.

locals {
  # Alarms the investigation rule reacts to: any explicitly supplied, plus the
  # platform's own baseline alarms (see alarms.tf).
  all_investigation_alarms = concat(var.investigation_alarm_names, local.baseline_alarm_names)
  wire_investigations      = var.enable_cloudwatch_investigations && length(local.all_investigation_alarms) > 0
}

resource "aws_cloudwatch_event_rule" "alarm_to_investigation" {
  count       = local.wire_investigations ? 1 : 0
  name        = "${var.name_prefix}-alarm-investigation"
  description = "Notify and (via the investigation group) auto-investigate when a monitored alarm fires."

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = local.all_investigation_alarms
      state = {
        value = ["ALARM"]
      }
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "alarm_to_sns" {
  count     = local.wire_investigations ? 1 : 0
  rule      = aws_cloudwatch_event_rule.alarm_to_investigation[0].name
  target_id = "notify-sns"
  arn       = local.sns_topic_arn

  input_transformer {
    input_paths = {
      alarm  = "$.detail.alarmName"
      reason = "$.detail.state.reason"
    }
    input_template = "\"Investigation trigger: alarm <alarm> entered ALARM. Reason: <reason>\""
  }
}

# SNS topic policy for the platform-owned alerts topic. The policy exists whenever the
# platform owns the topic (baseline CloudWatch alarms publish to it regardless of whether
# investigations are wired); the EventBridge grant is added only when investigations are on.
data "aws_iam_policy_document" "sns_events" {
  count = var.create_sns_topic ? 1 : 0

  # Baseline CloudWatch alarms (alarm_actions / ok_actions) publish to the topic.
  statement {
    sid       = "AllowCloudWatchPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts[0].arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  # EventBridge forwards alarm-state-change events to the topic only when investigations
  # are wired.
  dynamic "statement" {
    for_each = local.wire_investigations ? [1] : []
    content {
      sid       = "AllowEventBridgePublish"
      actions   = ["sns:Publish"]
      resources = [aws_sns_topic.alerts[0].arn]
      principals {
        type        = "Service"
        identifiers = ["events.amazonaws.com"]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [local.account_id]
      }
    }
  }
}

resource "aws_sns_topic_policy" "events" {
  count  = var.create_sns_topic ? 1 : 0
  arn    = aws_sns_topic.alerts[0].arn
  policy = data.aws_iam_policy_document.sns_events[0].json
}
