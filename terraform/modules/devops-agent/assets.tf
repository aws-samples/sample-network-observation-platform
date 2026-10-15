###############################################################################
# Part 4 — a "network-firefighter" skill, a custom agent that uses it, and a
# scheduled trigger that runs the agent. This is what turns the generic agent
# space into one that knows how to investigate THIS platform's telemetry.
###############################################################################

locals {
  # The agent queries the consolidated lake directly with Athena. The base agent role is
  # read-only over the lake data: it reads Glue and S3, and because the managed-query-results
  # workgroup (netobs-agent) returns rows through the Athena API it needs no S3 write grant at
  # all, so it never writes the consolidated Parquet. Any write happens only under the elevated
  # directed-actions role, which is scoped to Athena query execution, may write solely to the
  # Athena results prefix, and requires per-action operator approval.
  athena_guidance_text = <<-EOT3
    ## PRIMARY WAY TO QUERY THE DATA: run Athena yourself with `use_aws`
    Answer every data question ("what was blocked", "top blocked destinations", "which rule
    SIDs fired", "trace this IP", flow volumes, DNS blocks, CloudTrail firewall changes) by
    running a read-only Amazon Athena query with your built-in **`use_aws`** tool. There is
    no separate, custom, or user-provided query tool for this lake — do NOT call
    `search_user_tools` or go looking for one; `use_aws` against Athena IS how you query it.

    Mechanism — call `use_aws` with `service_name = "athena"` and
    `aws_region = "${var.platform_region}"` (the lake's Region, NOT the agent's home Region):
    1. `start_query_execution` with your SQL, `WorkGroup = "${var.athena_agent_workgroup}"`,
       and `QueryExecutionContext.Database = "${var.glue_database_name}"`.
    2. Poll `get_query_execution` until `Status.State = "SUCCEEDED"`.
    3. `get_query_results` to read the rows.

    `athena:StartQueryExecution` here is a read-only SELECT and your base role is read-only over
    the lake data (it reads Glue and S3; with the managed-results workgroup it needs no S3 write
    at all), so it needs no operator approval and never writes the consolidated Parquet. Any write
    happens only under the elevated directed-actions role, which is limited to Athena query
    execution (results under athena-results/ only) and requires per-action operator approval. The
    `${var.athena_agent_workgroup}` workgroup uses managed query results, so you need no S3 write access.

    - Pass a single ANSI/Trino SQL SELECT. Example: `SELECT COALESCE(domain, tls_sni, dst_ip)
      dest, count(*) n FROM ${var.glue_database_name}.network_events WHERE action IN
      ('block','drop','reject') GROUP BY 1 ORDER BY n DESC LIMIT 10`.
    - **`event_time` is a VARCHAR string, not a timestamp type.** You MUST wrap it in
      `from_iso8601_timestamp(event_time)` before any time comparison. Comparing the raw
      column to a timestamp (e.g. `event_time >= current_timestamp - interval '7' day`)
      fails with TYPE_MISMATCH. Always use the parsed form, e.g.
      `WHERE from_iso8601_timestamp(event_time) >= current_timestamp - interval '7' day`.

  EOT3

  athena_guidance = var.athena_agent_workgroup != "" ? local.athena_guidance_text : ""

  # Investigation guidance handed to the agent. References the platform's data planes
  # so the agent knows where to look when asked about network-firewall behaviour.
  skill_markdown = <<-EOT
    # Network Firewall Investigation

    > ## ⚠️ READ FIRST — Region and lake location
    > All platform data lives in AWS Region **${var.platform_region}**, in database
    > `${var.glue_database_name}` (table `network_events`). This agent space runs in a
    > DIFFERENT Region. On your VERY FIRST query, and every `use_aws` call after it
    > (Athena, Glue, S3, OpenSearch), set `aws_region = "${var.platform_region}"`. Do NOT
    > query the agent's home Region: it returns AccessDenied or empty results, which does
    > NOT mean the data is missing — it means you used the wrong Region. Never conclude
    > "no data" from a home-Region call; retry in ${var.platform_region} first.

    ${local.athena_guidance}

    Use this skill for ANY question about the Network Observation data lake — event counts,
    "what was blocked", top talkers, which rule SIDs fired, tracing an IP, flow volumes, DNS
    blocks, CloudTrail firewall changes — as well as AWS Network Firewall, Transit Gateway/VPC
    flow, or Route 53 Resolver DNS Firewall investigations. Load it before your first query.

    ## Source of truth: the consolidated observation plane
    Always answer questions about "what was blocked", "which rule SIDs fired", "top
    talkers", "blocked domains", etc. from the **consolidated, normalised event store** —
    that is the entire point of this platform. Do NOT answer these questions by inspecting
    the raw AWS Network Firewall resource, its route tables, or its associations.

    - **Athena (authoritative):** database `${var.glue_database_name}`, table
      `network_events`, WorkGroup `${var.athena_agent_workgroup}` (see the primary query
      section above). Columns: event_time, source_type (nfw_alert, dns_firewall,
      vpc_flow, tgw_flow, cloudtrail), action, src_ip, dst_ip, dst_port,
      protocol, rule_sid, domain, tls_sni, geo_country, bytes, packets. Run SELECT
      queries here first; this is where most findings live.
    - **AWS Network Firewall flow logs** are in a separate in-place table `nfw_flow_s3`
      in the same database (columns: timestamp, event_type, src_ip, src_port, dest_ip,
      dest_port, proto, and the nested netflow.pkts / netflow.bytes). The firewall
      delivers flow logs straight to S3, so they are NOT in `network_events`; query
      `nfw_flow_s3` for byte/packet volumes and correlate with `network_events` on the
      5-tuple + time window. Note the column names differ (dest_ip/dest_port/proto here
      vs dst_ip/dst_port/protocol in network_events).
    - **OpenSearch Dashboards** (interactive search): ${var.opensearch_dashboards_url}
      index pattern `network-events-*` — the same events for ad-hoc pivoting.
    - **CloudWatch dashboard** `${var.name_prefix}-quick-view` for at-a-glance metrics.
    - **SNS** topic `${var.name_prefix}-alerts` carries hygiene reports and alarms.

    The raw firewall configuration (DescribeFirewall, route tables, rule groups) is only
    **secondary corroboration** — for example to confirm a policy change or that a rule
    exists. Never use "the firewall has no associations / empty native logs" to conclude
    "there were no events": the consolidated store, not the firewall's own logs, is the
    observation surface, and it may aggregate multiple firewalls and sources.

    ## If a lake query is cancelled or unauthorised
    - Athena queries are read-only and should run without approval. If one is ever cancelled
      as "Cancelled mutative operation ... requires an operator approval" (an environment where
      query execution is still gated), do NOT treat it as "no traffic": ask the operator to
      approve it in interactive chat, or run it under the elevated role if directed actions are
      enabled. Otherwise summarise from CloudWatch metrics/alarms and tell the operator the
      detailed lake breakdown needs approval.
    - Use WorkGroup `${var.athena_agent_workgroup}` in Region ${var.platform_region} so the
      call uses managed query results and needs no S3 write access.
    - In a demo or test-harness account the telemetry is often **synthetic**: a data
      injector writes events straight into Firehose/OpenSearch (and flow logs into the
      flow-log S3 bucket) downstream of the firewall, so the underlying firewall can
      legitimately be idle or out of the traffic path while the consolidated store and
      the nfw_flow_s3 table are full of events. An idle firewall therefore does NOT mean
      "no findings" — report what `network_events` contains, and note the data is
      synthetic only if asked to distinguish real from demo traffic.

    ## How to investigate
    1. Establish the blast radius from `network_events`: which source_type, the time
       window, and blocking activity. The `action` values in the data are `allow`, `ok`,
       `accept` (permitted); `block`, `drop`, `reject` (blocked); `alert` (alert-only);
       plus CloudTrail event names when source_type='cloudtrail'. For "blocked" questions
       filter `action IN ('block','drop','reject')`. Group by rule_sid and dst_port.
    2. For a spike in blocks, list the top src_ip and tls_sni/domain values and whether
       geo_country falls outside the expected allow-list.
    3. For a DROP in expected traffic, check whether a rule_sid stopped firing (compare
       against the rule-hygiene report) or a firewall policy change occurred (source_type
       = cloudtrail, eventName Update*/Associate*).
    4. Correlate DNS Firewall blocks with subsequent NFW alerts for the same src_ip.
    5. Recommend a rule change only with the evidence (SIDs, counts, time range) attached.
  EOT
}

resource "awscc_devopsagent_asset" "skill" {
  count          = var.enable_assets ? 1 : 0
  agent_space_id = awscc_devopsagent_agent_space.this.id
  asset_type     = "skill"

  metadata = jsonencode({
    name        = "network-firewall-investigation"
    description = "How to answer ANY question about the Network Observation data lake (Athena table network_events in Region ${var.platform_region}): event counts, what was blocked, top talkers, rule SIDs, IP traces, flow volumes, DNS blocks, CloudTrail firewall changes, plus Network Firewall / TGW-VPC flow / DNS Firewall investigations. Load before querying; it gives the exact Region, workgroup, database and SQL conventions."
    agent_types = ["GENERIC"]
  })

  files = [{
    path         = "SKILL.md"
    content_text = local.skill_markdown
  }]

  # The DevOps Agent service augments the asset metadata with its own keys after creation.
  # Ignore metadata drift so those service-added keys do not produce a perpetual diff.
  lifecycle {
    ignore_changes = [metadata]
  }
}

resource "awscc_devopsagent_asset" "agent" {
  count          = var.enable_assets ? 1 : 0
  agent_space_id = awscc_devopsagent_agent_space.this.id
  asset_type     = "custom_agent"

  metadata = jsonencode({
    name   = "network-firefighter"
    skills = [awscc_devopsagent_asset.skill[0].asset_id]
  })

  files = [{
    path         = "AGENT.md"
    content_text = <<-EOT
      # Network Firefighter
      Custom agent for AWS Network Firewall incident response on the Network Observation
      platform. Loads the network-firewall-investigation skill and correlates firewall
      alerts, flow logs and DNS Firewall blocks to find likely root cause.
    EOT
  }]

  # The DevOps Agent service augments the asset metadata with its own keys after creation.
  # Ignore metadata drift so those service-added keys do not produce a perpetual diff.
  lifecycle {
    ignore_changes = [metadata]
  }
}

# Runs the custom agent on a schedule so the account gets a periodic proactive sweep.
resource "awscc_devopsagent_trigger" "scheduled" {
  count          = var.enable_assets ? 1 : 0
  agent_space_id = awscc_devopsagent_agent_space.this.id
  type           = "TIME_BASED"

  condition = {
    schedule = {
      expression = var.trigger_schedule
    }
  }

  action = jsonencode({
    actionType = "create:task"
    task = {
      agent = "custom:${awscc_devopsagent_asset.agent[0].asset_id}"
    }
  })

  status = "Active"
}
