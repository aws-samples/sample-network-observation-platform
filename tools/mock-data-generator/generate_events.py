#!/usr/bin/env python3
"""Synthetic network-telemetry generator for the Network Observation platform.

Produces realistic-but-fake events across all five sources (AWS Network Firewall
alert + flow, Route 53 Resolver DNS Firewall, VPC Flow Logs, CloudTrail) so the
dashboards and Athena queries show data before real traffic exists.

Three delivery targets, usable together:

  * firehose   -> sends SOURCE-shaped records to the consolidation Firehose stream.
                  They flow through the real transform Lambda into Parquet in S3 and
                  become queryable in Athena. This exercises the pipeline.
  * opensearch -> bulk-indexes NORMALISED documents straight into the network-events-*
                  index that the OpenSearch dashboards read.
  * flow-logs  -> delivers the nfw_flow events as gzipped Suricata EVE JSON straight to a
                  DEDICATED synthetic/demo S3 bucket (NEVER the real Network Firewall flow-log
                  bucket), using the same object shape AWS Network Firewall uses and the same
                  direct-to-S3 path (NOT via Firehose). The nfw_flow_s3 Athena table reads them
                  in place only when its Glue location points at that demo bucket. When a flow
                  bucket is given, nfw_flow is routed there and kept out of the
                  Firehose/OpenSearch (network_events) path. Keep synthetic and real flow logs
                  separate: do not point this at a bucket a real firewall writes to.

The same module is used by the optional Terraform demo-injector Lambda (see
`lambda_handler`) so a scheduled job can keep the demo account looking live.

Data policy: everything here is SYNTHETIC. No personal data. Internal addresses use
the landing-zone 10.x ranges; external addresses and domains are obviously fake.

Usage (local, one-shot seed of the last 24h):
  python generate_events.py \
      --firehose-stream netobs-consolidated \
      --opensearch-endpoint search-netobs-obs-xxxx.eu-west-1.es.amazonaws.com \
      --count 5000 --hours 24

Send to only one target by omitting the other flag.
"""

import argparse
import datetime as dt
import gzip
import io
import json
import os
import uuid
from random import SystemRandom

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

# Synthetic demo data only: use a dedicated SystemRandom (os.urandom-backed) instance so
# static analysers do not flag the non-cryptographic default PRNG. There is no security
# context here; SystemRandom is a drop-in with the same API as the random module.
_rng = SystemRandom()

# --------------------------------------------------------------------------- #
# Synthetic fixtures
# --------------------------------------------------------------------------- #

# Internal workload ranges (RFC 1918): prod workload-a, prod workload-b, staging.
INTERNAL_PREFIXES = ["10.1.0.", "10.1.4.", "10.1.8.", "10.0.2."]

# Obviously-fake external endpoints, split into normally-allowed and normally-blocked.
ALLOWED_DOMAINS = [
    "api.partner.example.com", "cdn.assets.example.net", "updates.example.org",
    "feed.odds.example.com", "payments.psp.example.com", "telemetry.example.net",
]
BLOCKED_DOMAINS = [
    "c2.malware.example", "phish-login.example", "tracker.adtech.example",
    "exfil.badstuff.example", "coinminer.example",
]

# Single neutral synthetic geo list — no country is treated as inherently "allowed" or
# "blocked" (both geo_country assignments draw from this one list).
GEO_ALLOWED = ["IE", "GB", "US", "DE", "NL", "FR"]

PROTOCOLS = ["tcp", "udp", "icmp"]
COMMON_PORTS = [443, 443, 443, 80, 53, 8443, 3306, 22]

# Suricata SIDs the mock alerts reference; a couple are intentionally never emitted so
# the rule-hygiene report has zero-hit candidates to find.
ACTIVE_SIDS = list(range(3000001, 3000031))

CLOUDTRAIL_EVENTS = [
    ("UpdateFirewallPolicy", "network-firewall.amazonaws.com"),
    ("CreateRuleGroup", "network-firewall.amazonaws.com"),
    ("AssociateFirewallPolicy", "network-firewall.amazonaws.com"),
    ("PutResourcePolicy", "network-firewall.amazonaws.com"),
]

NORMALISED_COLUMNS = [
    "event_time", "source_type", "action", "src_ip", "dst_ip", "src_port",
    "dst_port", "protocol", "rule_sid", "domain", "tls_sni", "geo_country",
    "account_id", "region", "vpc_id", "bytes", "packets", "raw",
]


def _rand_internal():
    return _rng.choice(INTERNAL_PREFIXES) + str(_rng.randint(4, 250))


def _rand_external():
    return ".".join(str(_rng.randint(1, 254)) for _ in range(4))


def _iso(ts):
    return ts.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def _epoch(iso):
    """Unix epoch seconds for an ISO-8601 event_time like '2026-10-06T09:55:24.123Z'."""
    d = dt.datetime.strptime(iso, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=dt.timezone.utc)
    return int(d.timestamp())


# --------------------------------------------------------------------------- #
# Event generation (produces a normalised event dict)
# --------------------------------------------------------------------------- #

def _blank():
    return {c: None for c in NORMALISED_COLUMNS}


def make_event(when, source_type):
    e = _blank()
    e["event_time"] = _iso(when)
    e["source_type"] = source_type
    e["account_id"] = _rng.choice(["111122223333", "444455556666"])
    e["region"] = os.environ.get("AWS_REGION", "eu-west-1")
    e["vpc_id"] = _rng.choice(["vpc-0aaa1111bbbb2222c", "vpc-0ddd3333eeee4444f"])

    if source_type == "nfw_flow":
        e["action"] = "allow"
        e["src_ip"] = _rand_internal()
        e["dst_ip"] = _rand_external()
        e["src_port"] = _rng.randint(1024, 65535)
        e["dst_port"] = _rng.choice(COMMON_PORTS)
        e["protocol"] = _rng.choices(PROTOCOLS, weights=[80, 18, 2])[0]
        e["bytes"] = _rng.randint(200, 5_000_000)
        e["packets"] = _rng.randint(2, 4000)

    elif source_type == "nfw_alert":
        blocked = _rng.random() < 0.6
        e["action"] = _rng.choice(["drop", "reject"]) if blocked else "alert"
        e["src_ip"] = _rand_external() if blocked else _rand_internal()
        e["dst_ip"] = _rand_internal() if blocked else _rand_external()
        e["src_port"] = _rng.randint(1024, 65535)
        e["dst_port"] = _rng.choice(COMMON_PORTS)
        e["protocol"] = "tcp"
        e["rule_sid"] = str(_rng.choice(ACTIVE_SIDS))
        sni = _rng.choice(BLOCKED_DOMAINS if blocked else ALLOWED_DOMAINS)
        e["tls_sni"] = sni
        e["domain"] = sni
        e["geo_country"] = _rng.choice(GEO_ALLOWED)

    elif source_type == "dns_firewall":
        blocked = _rng.random() < 0.25
        e["action"] = "block" if blocked else "allow"
        e["src_ip"] = _rand_internal()
        e["src_port"] = _rng.randint(1024, 65535)
        e["protocol"] = "udp"
        e["domain"] = _rng.choice(BLOCKED_DOMAINS if blocked else ALLOWED_DOMAINS)
        e["rule_sid"] = "dns-fw-" + _rng.choice(["managed-badlist", "custom-denylist"]) if blocked else None
        e["geo_country"] = _rng.choice(GEO_ALLOWED)

    elif source_type == "vpc_flow":
        rejected = _rng.random() < 0.15
        e["action"] = "reject" if rejected else "accept"
        e["src_ip"] = _rand_internal()
        e["dst_ip"] = _rand_external()
        e["src_port"] = _rng.randint(1024, 65535)
        e["dst_port"] = _rng.choice(COMMON_PORTS)
        e["protocol"] = _rng.choices(PROTOCOLS, weights=[80, 18, 2])[0]
        e["bytes"] = _rng.randint(60, 2_000_000)
        e["packets"] = _rng.randint(1, 1500)

    elif source_type == "tgw_flow":
        # East-west traffic between attachments (incl. traffic crossing Direct Connect).
        e["action"] = "ok"
        e["src_ip"] = _rand_internal()
        e["dst_ip"] = _rand_internal()
        e["src_port"] = _rng.randint(1024, 65535)
        e["dst_port"] = _rng.choice(COMMON_PORTS)
        e["protocol"] = _rng.choices(PROTOCOLS, weights=[85, 13, 2])[0]
        e["bytes"] = _rng.randint(60, 3_000_000)
        e["packets"] = _rng.randint(1, 2500)
        e["vpc_id"] = _rng.choice(["tgw-attach-0aaa111", "tgw-attach-0ddd333", "tgw-attach-0dx0001"])

    elif source_type == "cloudtrail":
        name, _ = _rng.choice(CLOUDTRAIL_EVENTS)
        e["action"] = name
        e["src_ip"] = _rand_external()

    return e


# --------------------------------------------------------------------------- #
# Rebuild a plausible SOURCE-shaped record from a normalised event (for Firehose)
# --------------------------------------------------------------------------- #

def to_source_record(e):
    st = e["source_type"]
    if st == "nfw_alert":
        return json.dumps({
            "timestamp": e["event_time"], "event_type": "alert",
            "src_ip": e["src_ip"], "src_port": e["src_port"],
            "dest_ip": e["dst_ip"], "dest_port": e["dst_port"], "proto": e["protocol"].upper(),
            "alert": {"action": e["action"], "signature_id": int(e["rule_sid"]) if e["rule_sid"] else None,
                       "signature": "SYNTHETIC demo signature"},
            "tls": {"sni": e["tls_sni"]},
        })
    if st == "nfw_flow":
        return json.dumps({
            "timestamp": e["event_time"], "event_type": "netflow",
            "src_ip": e["src_ip"], "src_port": e["src_port"],
            "dest_ip": e["dst_ip"], "dest_port": e["dst_port"], "proto": e["protocol"].upper(),
            "netflow": {"pkts": e["packets"], "bytes": e["bytes"]},
        })
    if st == "dns_firewall":
        return json.dumps({
            "query_timestamp": e["event_time"], "srcaddr": e["src_ip"], "srcport": e["src_port"],
            "query_name": (e["domain"] or "") + ".", "transport": "Udp",
            "firewall_rule_action": e["action"].upper(),
            "firewall_rule_group_id": e["rule_sid"], "vpc_id": e["vpc_id"], "account_id": e["account_id"],
        })
    if st == "vpc_flow":
        # Default VPC flow log format as a single space-delimited line (14 fields).
        start = _epoch(e["event_time"])
        proto_num = {"tcp": "6", "udp": "17", "icmp": "1"}.get(e["protocol"], "6")
        msg = (f"2 {e['account_id']} eni-0synthetic {e['src_ip']} {e['dst_ip']} "
               f"{e['src_port']} {e['dst_port']} {proto_num} {e['packets']} {e['bytes']} "
               f"{start} {start + 60} {e['action'].upper()} OK")
        return msg  # sent as raw text; transform handles the string path
    if st == "tgw_flow":
        # Platform custom TGW format (13 fields) — matches normalise_tgw_flow. The trailing
        # `start` (Unix epoch seconds) time-stamps the event like a real TGW flow log.
        proto_num = {"tcp": "6", "udp": "17", "icmp": "1"}.get(e["protocol"], "6")
        direction = _rng.choice(["ingress", "egress"])
        start = _epoch(e["event_time"])
        msg = (f"tgw-0synthetic {e['vpc_id']} {e['src_ip']} {e['dst_ip']} "
               f"{e['src_port']} {e['dst_port']} {proto_num} {e['packets']} {e['bytes']} "
               f"- {direction} OK {start}")
        return msg
    if st == "cloudtrail":
        return json.dumps({
            "eventTime": e["event_time"], "eventName": e["action"],
            "eventSource": "network-firewall.amazonaws.com",
            "sourceIPAddress": e["src_ip"], "awsRegion": e["region"],
            "recipientAccountId": e["account_id"],
            "userIdentity": {"accountId": e["account_id"], "type": "AssumedRole"},
        })
    return json.dumps(e)


# --------------------------------------------------------------------------- #
# Delivery
# --------------------------------------------------------------------------- #

SOURCE_WEIGHTS = {
    "nfw_flow": 35, "tgw_flow": 25, "dns_firewall": 18, "nfw_alert": 12,
    "vpc_flow": 7, "cloudtrail": 3,
}


def generate(count, hours):
    now = dt.datetime.now(dt.timezone.utc)
    types = list(SOURCE_WEIGHTS)
    weights = list(SOURCE_WEIGHTS.values())
    events = []
    for _ in range(count):
        when = now - dt.timedelta(seconds=_rng.randint(0, hours * 3600))
        st = _rng.choices(types, weights=weights)[0]
        events.append(make_event(when, st))
    return events


def send_to_firehose(events, stream):
    client = boto3.client("firehose")
    sent = 0
    batch = []
    for e in events:
        rec = to_source_record(e)
        data = rec if rec.endswith("\n") else rec + "\n"
        batch.append({"Data": data.encode("utf-8")})
        if len(batch) == 500:
            client.put_record_batch(DeliveryStreamName=stream, Records=batch)
            sent += len(batch)
            batch = []
    if batch:
        client.put_record_batch(DeliveryStreamName=stream, Records=batch)
        sent += len(batch)
    return sent


def _signed_opensearch(method, endpoint, path, body):
    region = os.environ.get("AWS_REGION", "eu-west-1")
    host = endpoint.replace("https://", "").rstrip("/")
    url = f"https://{host}{path}"
    request = AWSRequest(method=method, url=url, data=body,
                         headers={"Content-Type": "application/x-ndjson"})
    SigV4Auth(boto3.Session().get_credentials(), "es", region).add_auth(request)
    import urllib.request
    req = urllib.request.Request(url, data=body, method=method)
    for k, v in request.headers.items():
        req.add_header(k, v)
    with urllib.request.urlopen(req) as resp:  # noqa: S310  # nosec B310 - fixed AWS HTTPS endpoint, no user-controlled scheme
        return resp.status, resp.read().decode("utf-8")


def send_to_opensearch(events, endpoint):
    """Bulk-index normalised docs into daily network-events-YYYY.MM.DD indices."""
    sent = 0
    lines = []
    for e in events:
        day = e["event_time"][:10].replace("-", ".")
        index = f"network-events-{day}"
        doc = {k: v for k, v in e.items() if v is not None and k != "raw"}
        lines.append(json.dumps({"index": {"_index": index, "_id": str(uuid.uuid4())}}))
        lines.append(json.dumps(doc))
        if len(lines) >= 2000:
            body = ("\n".join(lines) + "\n").encode("utf-8")
            _signed_opensearch("POST", endpoint, "/_bulk", body)
            sent += len(lines) // 2
            lines = []
    if lines:
        body = ("\n".join(lines) + "\n").encode("utf-8")
        _signed_opensearch("POST", endpoint, "/_bulk", body)
        sent += len(lines) // 2
    return sent


# --------------------------------------------------------------------------- #
# NFW flow logs -> S3 (as the firewall delivers them; read by the nfw_flow_s3 table)
# --------------------------------------------------------------------------- #

def _flow_eve_record(e):
    """Reshape a normalised nfw_flow event into Suricata netflow EVE JSON matching the
    nfw_flow_s3 Glue table (netflow struct: pkts, bytes, start, end, age)."""
    return json.dumps({
        "timestamp": e["event_time"],
        "event_type": "netflow",
        "flow_id": _rng.randint(10**14, 10**15),
        "src_ip": e["src_ip"],
        "src_port": e["src_port"],
        "dest_ip": e["dst_ip"],
        "dest_port": e["dst_port"],
        "proto": (e["protocol"] or "tcp").upper(),
        "app_proto": _rng.choice(["tls", "http", "dns", "failed"]),
        "netflow": {
            "pkts": e["packets"],
            "bytes": e["bytes"],
            "start": e["event_time"],
            "end": e["event_time"],
            "age": _rng.randint(1, 60),
        },
    })


def send_flow_logs_to_s3(events, bucket, firewall_name):
    """Deliver nfw_flow events to a DEDICATED synthetic/demo S3 bucket (never the real
    Network Firewall flow-log bucket) as one gzipped Suricata EVE JSON object, using the same
    object shape and direct-to-S3 path a real firewall uses (not through Firehose). The
    nfw_flow_s3 Athena table reads them in place only when its Glue location points at this
    demo bucket. Caller must pass a bucket that no real firewall writes to."""
    if not events:
        return 0
    region = os.environ.get("AWS_REGION", "eu-west-1")
    account_id = boto3.client("sts").get_caller_identity()["Account"]

    body = ("\n".join(_flow_eve_record(e) for e in events) + "\n").encode("utf-8")
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb") as gz:
        gz.write(body)

    now = dt.datetime.now(dt.timezone.utc)
    key = (
        f"flow/AWSLogs/{account_id}/network-firewall/flow/{region}/{firewall_name}/"
        f"{now:%Y/%m/%d/%H}/"
        f"{account_id}_network-firewall_flow_{region}_{firewall_name}_"
        f"{now:%Y%m%dT%H%M}Z_{uuid.uuid4().hex[:8]}.log.gz"
    )
    boto3.client("s3", region_name=region).put_object(
        Bucket=bucket, Key=key, Body=buf.getvalue(), ContentType="application/x-gzip"
    )
    return len(events)


# --------------------------------------------------------------------------- #
# Entry points
# --------------------------------------------------------------------------- #

def run(count, hours, firehose_stream=None, opensearch_endpoint=None,
        flow_logs_bucket=None, firewall_name="firewall"):
    events = generate(count, hours)
    result = {"generated": len(events)}

    # nfw_flow objects use the firewall's native direct-to-S3 shape (read in place by the
    # nfw_flow_s3 Athena table), never Firehose. When a flow bucket is configured — which must
    # be a dedicated synthetic/demo bucket, never a real firewall's flow-log bucket — route
    # nfw_flow there and keep it out of the network_events pipeline.
    if flow_logs_bucket:
        flow_events = [e for e in events if e["source_type"] == "nfw_flow"]
        pipeline_events = [e for e in events if e["source_type"] != "nfw_flow"]
        result["flow_logs_s3"] = send_flow_logs_to_s3(flow_events, flow_logs_bucket, firewall_name)
    else:
        pipeline_events = events

    if firehose_stream:
        result["firehose_sent"] = send_to_firehose(pipeline_events, firehose_stream)
    if opensearch_endpoint:
        result["opensearch_indexed"] = send_to_opensearch(pipeline_events, opensearch_endpoint)
    return result


def lambda_handler(_event, _context):
    """Used by the optional Terraform demo-injector module."""
    count = int(os.environ.get("EVENTS_PER_RUN", "500"))
    hours = int(os.environ.get("WINDOW_HOURS", "1"))
    return run(
        count=count,
        hours=hours,
        firehose_stream=os.environ.get("FIREHOSE_STREAM") or None,
        opensearch_endpoint=os.environ.get("OPENSEARCH_ENDPOINT") or None,
        flow_logs_bucket=os.environ.get("FLOW_LOGS_BUCKET") or None,
        firewall_name=os.environ.get("FIREWALL_NAME") or "firewall",
    )


def _cli():
    p = argparse.ArgumentParser(description="Generate synthetic network telemetry for the demo.")
    p.add_argument("--count", type=int, default=5000, help="number of events to generate")
    p.add_argument("--hours", type=int, default=24, help="spread events over the last N hours")
    p.add_argument("--firehose-stream", default=None, help="consolidation Firehose delivery stream name")
    p.add_argument("--opensearch-endpoint", default=None, help="OpenSearch domain endpoint (host, no scheme)")
    p.add_argument("--flow-logs-bucket", default=None, help="DEDICATED synthetic/demo S3 bucket for nfw_flow events (never the real Network Firewall flow-log bucket); delivered as gzipped EVE JSON instead of via Firehose, and read by the nfw_flow_s3 table only when its Glue location points at this bucket")
    p.add_argument("--firewall-name", default="firewall", help="firewall name used in the flow-log S3 key path")
    args = p.parse_args()
    if not args.firehose_stream and not args.opensearch_endpoint and not args.flow_logs_bucket:
        p.error("supply --firehose-stream and/or --opensearch-endpoint and/or --flow-logs-bucket")
    print(json.dumps(run(args.count, args.hours, args.firehose_stream, args.opensearch_endpoint,
                         args.flow_logs_bucket, args.firewall_name), indent=2))


if __name__ == "__main__":
    _cli()
