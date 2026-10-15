#!/usr/bin/env python3
"""Deep check for the AWS DevOps Agent (Tier 3).

Opens a chat with the deployed agent space, asks a bounded investigation question, and
confirms the agent actually answers from the consolidated lake WITHOUT a permissions
(KMS / AccessDenied) block. This is the end-to-end counterpart to the smoke test's
deterministic "agent workgroup query" check: it exercises the real agent runtime, not
just the data path.

Read-only: it only starts a chat and sends one message. Nothing is created or changed in
the account's infrastructure.

Usage:
    python check-devops-agent.py                      # auto-discover the agent space
    python check-devops-agent.py --agent-region eu-west-1 --lake-region eu-west-2
    python check-devops-agent.py --agent-space-id <id> --question "..."

Exit codes: 0 = agent answered from the lake; 1 = agent was blocked/empty; 2 = setup error
(no boto3, no agent space, API/credentials failure).

Requires: boto3 and AWS credentials for the deployment account. The devops-agent service is
new; if this boto3's bundled endpoint rules are stale, the script falls back to the
documented data-plane host (dp.aidevops.<region>.api.aws)."""
import argparse
import sys

try:
    import boto3
    from botocore.config import Config
    from botocore.exceptions import EndpointConnectionError, ClientError, BotoCoreError
except ImportError:
    print("[SKIP] boto3 not installed - cannot run the deep agent check "
          "(pip install boto3). The smoke test's agent-workgroup query already "
          "covers the agent data path.")
    sys.exit(2)

# Agent answers contain Unicode (arrows, en-dashes); Windows consoles default to cp1252.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:  # noqa: BLE001 - best-effort; older Python without reconfigure
    pass

# Markers that mean the agent could not actually query the lake.
BLOCK_MARKERS = (
    "accessdenied",
    "denied access to the kms",
    "access to the configured kms",
    "insufficient privileges",
    "is denied access",
    "not able to run",
    "cannot run these queries",
    "can't run",
    "permissions gap",
    "i'm blocked",
    "i am blocked",
)


def make_client(region):
    """devops-agent client, with a fallback for stale bundled endpoint rules."""
    cfg = Config(read_timeout=600, connect_timeout=15, retries={"max_attempts": 0})
    client = boto3.client("devops-agent", region_name=region, config=cfg)
    try:
        client.list_agent_spaces()  # probe endpoint resolution
        return client
    except EndpointConnectionError:
        # Base host; the service's endpoint ruleset prepends the dp.* data-plane label.
        return boto3.client(
            "devops-agent",
            region_name=region,
            endpoint_url="https://aidevops.%s.api.aws" % region,
            config=cfg,
        )


def collect_text(obj, out):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "text" and isinstance(v, str):
                out.append(v)
            else:
                collect_text(v, out)
    elif isinstance(obj, list):
        for v in obj:
            collect_text(v, out)


def main():
    ap = argparse.ArgumentParser(description="Deep check for the AWS DevOps Agent.")
    ap.add_argument("--agent-region", default="eu-west-1",
                    help="Region the agent space is deployed in (default eu-west-1).")
    ap.add_argument("--lake-region", default="eu-west-2",
                    help="Region the Athena/Glue analysis plane lives in (default eu-west-2).")
    ap.add_argument("--glue-database", default="netobs_netobs",
                    help="Glue database holding network_events (default netobs_netobs).")
    ap.add_argument("--agent-space-id", default=None,
                    help="Agent space id; auto-discovered from list-agent-spaces if omitted.")
    ap.add_argument("--question", default=None, help="Override the investigation question.")
    args = ap.parse_args()

    try:
        client = make_client(args.agent_region)
    except (BotoCoreError, ClientError) as e:
        print("[FAIL] could not create devops-agent client in %s: %s" % (args.agent_region, e))
        return 2

    space_id = args.agent_space_id
    if not space_id:
        try:
            spaces = client.list_agent_spaces().get("agentSpaces", [])
        except (ClientError, BotoCoreError) as e:
            print("[FAIL] list-agent-spaces failed in %s: %s" % (args.agent_region, e))
            return 2
        if not spaces:
            print("[FAIL] no DevOps Agent space found in %s (is enable_devops_agent true?)"
                  % args.agent_region)
            return 2
        space_id = spaces[0].get("id") or spaces[0].get("agentSpaceId")
        name = spaces[0].get("name", "?")
        print("Using agent space '%s' (%s) in %s" % (name, space_id, args.agent_region))

    question = args.question or (
        "Load the network-firewall-investigation skill. The lake is Amazon Athena database "
        "%s, table network_events, in Region %s (NOT this agent home Region). Report the "
        "event counts by source_type over the last 24 hours. event_time is a VARCHAR, wrap "
        "it in from_iso8601_timestamp()." % (args.glue_database, args.lake_region)
    )

    try:
        chat = client.create_chat(agentSpaceId=space_id, userType="IAM")
        execution_id = chat["executionId"]
        resp = client.send_message(agentSpaceId=space_id, executionId=execution_id,
                                   content=question)
    except (ClientError, BotoCoreError) as e:
        print("[FAIL] agent chat call failed: %s" % e)
        return 2

    parts = []
    try:
        for event in resp["events"]:
            for etype, payload in event.items():
                if etype in ("contentBlockDelta", "responseCompleted", "summary"):
                    collect_text(payload, parts)
    except (BotoCoreError, Exception) as e:  # noqa: BLE001 - surface stream errors as failure
        print("[FAIL] error reading agent response stream: %s" % e)
        return 2

    answer = "".join(parts).strip()
    if not answer:
        print("[FAIL] agent returned no text.")
        return 1

    lowered = answer.lower()
    blocked = next((m for m in BLOCK_MARKERS if m in lowered), None)

    print("\n----- agent answer -----\n%s\n------------------------" % answer)
    if blocked:
        print("[FAIL] agent could not query the lake (matched block marker: %r). "
              "Check the agent workgroup / KMS data path." % blocked)
        return 1
    print("[PASS] agent answered from the lake with no permission block.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
