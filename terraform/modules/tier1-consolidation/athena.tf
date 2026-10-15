resource "aws_athena_workgroup" "netobs" {
  count = var.create_athena_workgroup ? 1 : 0
  name  = local.athena_workgroup_name
  tags  = var.tags

  # Recursively delete the workgroup on destroy even when it holds query-execution
  # history or saved queries (Athena's DeleteWorkGroup fails on a non-empty workgroup
  # otherwise, breaking `tofu destroy`).
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${local.analysis_bucket_name}/athena-results/"
      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = var.kms_key_arn
      }
    }
  }
}

# Dedicated workgroup for the AWS DevOps Agent, using Athena **managed query results**.
# The agent's session guardrail blocks s3:PutObject, so it cannot write query results to a
# customer S3 bucket — a standard workgroup therefore fails for the agent. Managed query
# results store output in Athena-owned storage (auto-deleted after 24h) and are read back via
# athena:GetQueryResults / GetQueryResultsStream scoped to the workgroup, so the agent needs
# no S3 write access. This lets the agent run read-only SELECTs against the lake natively.
# (Query results use an AWS-owned key; the source Parquet stays encrypted with the platform CMK.)
resource "aws_athena_workgroup" "agent" {
  #checkov:skip=CKV_AWS_159:Workgroup query results are encrypted; it uses Athena managed query results (always encrypted), which AWS forbids combining with a result_configuration encryption block.
  count         = var.create_athena_workgroup ? 1 : 0
  name          = "${var.name_prefix}-agent"
  tags          = var.tags
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    # No result_configuration is set here: the agent's scoped session blocks s3:PutObject, so
    # it must use managed query results, and AWS rejects a workgroup that sets both blocks.
    # The managed results are encrypted with the Athena-managed AWS-owned key, not the
    # platform CMK, and that is deliberate: the agent's session guardrail does not carry
    # kms:GenerateDataKey/Decrypt on the CMK (the same guardrail that blocks s3:PutObject), so
    # a CMK here would make every agent query fail with a KMS access-denied error. The results
    # are transient (Athena-owned storage, auto-deleted after 24h) and the source Parquet in
    # S3 remains CMK-encrypted, so no telemetry is persisted under the AWS-owned key.
    managed_query_results_configuration {
      enabled = true
    }
  }
}

locals {
  fq_table = "\"${local.glue_database_name}\".\"${local.glue_table_name}\""
}

# Saved queries that back the dashboards and support incident tracing. These are the
# equivalent of a firewall policy-optimiser and traffic-dashboard views, expressed as SQL.

resource "aws_athena_named_query" "top_talkers" {
  count       = var.create_athena_workgroup ? 1 : 0
  name        = "${var.name_prefix}-top-talkers"
  workgroup   = aws_athena_workgroup.netobs[0].name
  database    = local.glue_database_name
  description = "Top source/destination pairs by event volume over the last day."
  query       = <<-SQL
    SELECT src_ip, dst_ip, dst_port, protocol, count(*) AS events
    FROM ${local.fq_table}
    WHERE dt >= date_format(current_date - interval '1' day, '%Y-%m-%d')
    GROUP BY src_ip, dst_ip, dst_port, protocol
    ORDER BY events DESC
    LIMIT 100;
  SQL
}

resource "aws_athena_named_query" "allow_vs_deny" {
  count       = var.create_athena_workgroup ? 1 : 0
  name        = "${var.name_prefix}-allow-vs-deny"
  workgroup   = aws_athena_workgroup.netobs[0].name
  database    = local.glue_database_name
  description = "Allow versus deny/drop volume by hour."
  query       = <<-SQL
    SELECT date_trunc('hour', from_iso8601_timestamp(event_time)) AS hour,
           action, count(*) AS events
    FROM ${local.fq_table}
    WHERE source_type IN ('nfw_alert','vpc_flow','dns_firewall')
      AND dt >= date_format(current_date - interval '7' day, '%Y-%m-%d')
    GROUP BY 1, 2
    ORDER BY 1;
  SQL
}

resource "aws_athena_named_query" "blocked_domains" {
  count       = var.create_athena_workgroup ? 1 : 0
  name        = "${var.name_prefix}-blocked-domains"
  workgroup   = aws_athena_workgroup.netobs[0].name
  database    = local.glue_database_name
  description = "Blocked-domain leaderboard from DNS Firewall."
  query       = <<-SQL
    SELECT domain, count(*) AS blocks
    FROM ${local.fq_table}
    WHERE source_type = 'dns_firewall'
      AND action IN ('block','deny','blocked')
      AND dt >= date_format(current_date - interval '7' day, '%Y-%m-%d')
    GROUP BY domain
    ORDER BY blocks DESC
    LIMIT 100;
  SQL
}

resource "aws_athena_named_query" "trace_incident" {
  count       = var.create_athena_workgroup ? 1 : 0
  name        = "${var.name_prefix}-trace-incident-by-5tuple"
  workgroup   = aws_athena_workgroup.netobs[0].name
  database    = local.glue_database_name
  description = "Trace a single incident across every source on the 5-tuple within a time window."
  query       = <<-SQL
    -- Replace the placeholders, then run to see alert, flow, DNS and CloudTrail
    -- events for one conversation, ordered in time.
    SELECT event_time, source_type, action, src_ip, src_port, dst_ip, dst_port,
           protocol, rule_sid, domain
    FROM ${local.fq_table}
    WHERE dt = 'REPLACE_YYYY-MM-DD'
      AND (src_ip = 'REPLACE_SRC_IP' OR dst_ip = 'REPLACE_SRC_IP')
      AND (dst_ip = 'REPLACE_DST_IP' OR src_ip = 'REPLACE_DST_IP')
    ORDER BY event_time;
  SQL
}

resource "aws_athena_named_query" "rule_hit_gaps" {
  count       = var.create_athena_workgroup ? 1 : 0
  name        = "${var.name_prefix}-rule-hit-gaps"
  workgroup   = aws_athena_workgroup.netobs[0].name
  database    = local.glue_database_name
  description = "Suricata SIDs seen in alert logs, for reconciliation against the rule base (zero-hit report)."
  query       = <<-SQL
    SELECT rule_sid, count(*) AS hits, max(event_time) AS last_seen
    FROM ${local.fq_table}
    WHERE source_type = 'nfw_alert' AND rule_sid IS NOT NULL
      AND dt >= date_format(current_date - interval '30' day, '%Y-%m-%d')
    GROUP BY rule_sid
    ORDER BY hits ASC;
  SQL
}
