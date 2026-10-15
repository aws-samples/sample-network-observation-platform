"""Rule-hygiene report for the Network Observation platform.

This flags stateful Suricata rules that appear unused. On a schedule it:

  1. Lists the SIDs *defined* in the firewall's stateful rule groups: it calls
     DescribeFirewall -> DescribeFirewallPolicy to find the stateful rule-group ARNs,
     then DescribeRuleGroup on each and parses the `sid:` tokens out of the rules string.
     (It does NOT read native hit counts; AWS Network Firewall exposes no per-rule
     hit-count API, so there are none to read.)
  2. Lists the SIDs that have been *seen* in the consolidated logs over the window, via
     an Athena query against the normalised network_events table (nfw_alert rows).
  3. Reports the defined SIDs that were never seen (defined minus seen) as zero-hit
     candidates for retirement, and publishes the report to SNS.

It never modifies the firewall. Retirement is proposed to humans; changes flow through
the peer-reviewed IaC pipeline.

Environment:
  FIREWALL_NAME         AWS Network Firewall name
  GLUE_DATABASE         Glue database with the network_events table
  ATHENA_WORKGROUP      Athena workgroup for the reconciliation query
  ATHENA_OUTPUT         s3://bucket/prefix for Athena results
  SNS_TOPIC_ARN         topic to publish the report
  ZERO_HIT_WINDOW_DAYS  lookback window
"""

import os
import re
import time

import boto3

nfw = boto3.client("network-firewall")
athena = boto3.client("athena")
sns = boto3.client("sns")

FIREWALL_NAME = os.environ.get("FIREWALL_NAME", "")
GLUE_DATABASE = os.environ.get("GLUE_DATABASE", "")
ATHENA_WORKGROUP = os.environ.get("ATHENA_WORKGROUP", "")
ATHENA_OUTPUT = os.environ.get("ATHENA_OUTPUT", "")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
WINDOW_DAYS = int(os.environ.get("ZERO_HIT_WINDOW_DAYS", "30"))

# Static query template. The only interpolated values are deployer-controlled environment
# variables validated before use (GLUE_DATABASE charset-checked, WINDOW_DAYS int-cast) —
# never request input — so this is not user-facing SQL injection.
_SEEN_SIDS_SQL = """
        SELECT DISTINCT rule_sid
        FROM "{database}"."network_events"
        WHERE source_type = 'nfw_alert' AND rule_sid IS NOT NULL
          AND dt >= date_format(current_date - interval '{window_days}' day, '%Y-%m-%d')
    """


def _stateful_rule_group_arns():
    """Return the stateful rule-group ARNs attached to the firewall's policy."""
    fw = nfw.describe_firewall(FirewallName=FIREWALL_NAME)
    policy_arn = fw["Firewall"]["FirewallPolicyArn"]
    policy = nfw.describe_firewall_policy(FirewallPolicyArn=policy_arn)
    refs = policy["FirewallPolicy"].get("StatefulRuleGroupReferences", [])
    return [r["ResourceArn"] for r in refs]


def _seen_sids_from_logs():
    """SIDs observed in the alert logs over the window (Athena)."""
    if not (GLUE_DATABASE and ATHENA_WORKGROUP and ATHENA_OUTPUT):
        return set()
    # Query is built from deployer-controlled environment variables only (never request
    # input), so this is not user-facing SQL injection. We still defend in depth:
    # GLUE_DATABASE is validated against the Glue naming charset and WINDOW_DAYS is an int.
    if not re.fullmatch(r"[A-Za-z0-9_]+", GLUE_DATABASE):
        raise ValueError(
            f"GLUE_DATABASE contains unexpected characters: {GLUE_DATABASE!r}"
        )
    query = _SEEN_SIDS_SQL.format(database=GLUE_DATABASE, window_days=WINDOW_DAYS)  # nosec B608
    execution = athena.start_query_execution(
        QueryString=query,
        WorkGroup=ATHENA_WORKGROUP,
        ResultConfiguration={"OutputLocation": ATHENA_OUTPUT},
    )
    qid = execution["QueryExecutionId"]
    for _ in range(60):
        state = athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]["Status"]["State"]
        if state in ("SUCCEEDED", "FAILED", "CANCELLED"):
            break
        time.sleep(2)
    if state != "SUCCEEDED":
        return set()
    seen = set()
    paginator = athena.get_paginator("get_query_results")
    for page in paginator.paginate(QueryExecutionId=qid):
        for row in page["ResultSet"]["Rows"][1:]:  # skip header
            cells = row.get("Data", [])
            if cells and cells[0].get("VarCharValue"):
                seen.add(cells[0]["VarCharValue"])
    return seen


def _rule_sids_in_group(arn):
    """SIDs defined in a stateful rule group (best-effort parse of the rules string)."""
    rg = nfw.describe_rule_group(RuleGroupArn=arn, Type="STATEFUL")
    sids = []
    rules_source = rg.get("RuleGroup", {}).get("RulesSource", {})
    rules_string = rules_source.get("RulesString", "")
    for line in rules_string.splitlines():
        if "sid:" in line:
            try:
                sid = line.split("sid:")[1].split(";")[0].strip()
                sids.append(sid)
            except IndexError:
                continue
    return sids


def handler(_event, _context):
    if not FIREWALL_NAME:
        return {"error": "FIREWALL_NAME not set"}

    seen = _seen_sids_from_logs()
    defined = {}
    for arn in _stateful_rule_group_arns():
        for sid in _rule_sids_in_group(arn):
            defined[sid] = arn.split("/")[-1]

    zero_hit = sorted(sid for sid in defined if sid not in seen)

    lines = [
        "Network Firewall — rule-hygiene report",
        f"Firewall: {FIREWALL_NAME}",
        f"Window: last {WINDOW_DAYS} days",
        f"Stateful rules defined: {len(defined)}",
        f"Zero-hit candidates for retirement: {len(zero_hit)}",
        "",
    ]
    if zero_hit:
        lines.append("Candidate SIDs (no matches in the window) — review before retiring:")
        lines.extend(f"  SID {sid}  (rule group {defined[sid]})" for sid in zero_hit)
    else:
        lines.append("No zero-hit stateful rules in the window.")
    report = "\n".join(lines)

    if SNS_TOPIC_ARN:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="Network Firewall rule-hygiene report",
            Message=report,
        )
    return {"defined": len(defined), "zero_hit": len(zero_hit), "report": report}
