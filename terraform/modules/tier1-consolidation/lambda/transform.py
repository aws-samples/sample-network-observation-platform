"""Amazon Data Firehose transform for the Network Observation platform.

Normalises records from every network log source into one common schema keyed on
the 5-tuple plus a time bucket, so alert, flow, DNS, VPC-flow and CloudTrail events
correlate end-to-end. The original record is preserved verbatim in the `raw` field.

Firehose invokes this with a batch of base64-encoded records. Each returned record
must carry the same recordId and a result of Ok, Dropped or ProcessingFailed.
The output is newline-delimited JSON, which Firehose then converts to Parquet using
the Glue table schema.
"""

import base64
import datetime
import gzip
import json

# Suricata / IANA protocol number -> normalised name.
PROTO_MAP = {
    "1": "icmp", "6": "tcp", "17": "udp", "58": "icmpv6",
    "TCP": "tcp", "UDP": "udp", "ICMP": "icmp",
}

# Common schema columns (must match the Glue table).
COLUMNS = [
    "event_time", "source_type", "action", "src_ip", "dst_ip", "src_port",
    "dst_port", "protocol", "rule_sid", "domain", "tls_sni", "geo_country",
    "account_id", "region", "vpc_id", "bytes", "packets", "raw",
]


def _blank():
    return {c: None for c in COLUMNS}


def _norm_proto(value):
    if value is None:
        return None
    return PROTO_MAP.get(str(value), str(value).lower())


def _to_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _norm_time(value):
    """Canonicalise any source timestamp to ISO-8601 UTC (e.g. 2026-10-06T09:55:24.000Z).

    Different log sources express time differently: NFW alert/flow, DNS and CloudTrail
    carry ISO-8601 strings, while VPC and TGW flow logs carry a Unix epoch (seconds, or
    milliseconds for some CloudWatch deliveries). Normalise them all so `event_time` is a
    single comparable ISO-8601 string across every row — that is what makes the time-bucket
    half of the 5-tuple + time correlation key work, and lets Athena's
    from_iso8601_timestamp(event_time) parse every record.
    """
    if value is None:
        return None
    s = str(value).strip()
    if not s:
        return None
    # Pure number (optionally fractional) -> Unix epoch. Treat >= 1e12 as milliseconds.
    is_epoch = s.isdigit() or (s.count(".") == 1 and s.replace(".", "", 1).isdigit())
    if is_epoch:
        try:
            num = float(s)
            if num >= 1e12:
                num /= 1000.0
            d = datetime.datetime.fromtimestamp(num, tz=datetime.timezone.utc)
            return d.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        except (ValueError, OverflowError, OSError):
            return None
    return s  # already a string timestamp (assumed ISO-8601); keep as-is


def normalise_nfw_alert(rec):
    """AWS Network Firewall alert log (Suricata EVE JSON, often wrapped by CloudWatch)."""
    out = _blank()
    ev = rec.get("event", rec)
    out["source_type"] = "nfw_alert"
    out["event_time"] = ev.get("timestamp") or rec.get("timestamp")
    out["src_ip"] = ev.get("src_ip")
    out["dst_ip"] = ev.get("dest_ip")
    out["src_port"] = _to_int(ev.get("src_port"))
    out["dst_port"] = _to_int(ev.get("dest_port"))
    out["protocol"] = _norm_proto(ev.get("proto"))
    alert = ev.get("alert") or {}
    out["action"] = alert.get("action") or "alert"
    out["rule_sid"] = str(alert.get("signature_id")) if alert.get("signature_id") is not None else None
    tls = ev.get("tls") or {}
    out["tls_sni"] = tls.get("sni")
    out["domain"] = tls.get("sni") or (ev.get("http") or {}).get("hostname")
    return out


def normalise_nfw_flow(rec):
    """AWS Network Firewall flow log (Suricata netflow EVE JSON)."""
    out = _blank()
    ev = rec.get("event", rec)
    out["source_type"] = "nfw_flow"
    out["event_time"] = ev.get("timestamp") or rec.get("timestamp")
    out["src_ip"] = ev.get("src_ip")
    out["dst_ip"] = ev.get("dest_ip")
    out["src_port"] = _to_int(ev.get("src_port"))
    out["dst_port"] = _to_int(ev.get("dest_port"))
    out["protocol"] = _norm_proto(ev.get("proto"))
    netflow = ev.get("netflow") or {}
    out["bytes"] = _to_int(netflow.get("bytes"))
    out["packets"] = _to_int(netflow.get("pkts"))
    out["action"] = "allow"
    return out


def normalise_dns(rec):
    """Route 53 Resolver DNS Firewall query log."""
    out = _blank()
    out["source_type"] = "dns_firewall"
    out["event_time"] = rec.get("query_timestamp") or rec.get("timestamp")
    out["src_ip"] = rec.get("srcaddr")
    out["src_port"] = _to_int(rec.get("srcport"))
    out["protocol"] = _norm_proto(rec.get("transport") or "udp")
    out["domain"] = (rec.get("query_name") or "").rstrip(".") or None
    out["vpc_id"] = rec.get("vpc_id")
    out["account_id"] = rec.get("account_id")
    action = rec.get("firewall_rule_action") or rec.get("action")
    out["action"] = action.lower() if action else None
    out["rule_sid"] = rec.get("firewall_rule_group_id")
    return out


def normalise_vpc_flow(rec):
    """VPC Flow Log (default format, delivered via CloudWatch as space-delimited text).
    Default format (14 fields):
    version account-id interface-id srcaddr dstaddr srcport dstport protocol packets
    bytes start end action log-status
    """
    out = _blank()
    out["source_type"] = "vpc_flow"
    msg = rec if isinstance(rec, str) else rec.get("message", "")
    parts = msg.split()
    if len(parts) >= 14:
        # log-status NODATA/SKIPDATA means the ENI captured no traffic (or skipped some)
        # in this aggregation window, so every 5-tuple field is "-". There is nothing to
        # normalise; drop it rather than emit a row of placeholders.
        if parts[13].upper() in ("NODATA", "SKIPDATA"):
            return None
        out["account_id"] = parts[1]
        out["src_ip"] = parts[3]
        out["dst_ip"] = parts[4]
        out["src_port"] = _to_int(parts[5])
        out["dst_port"] = _to_int(parts[6])
        out["protocol"] = _norm_proto(parts[7])
        out["packets"] = _to_int(parts[8])
        out["bytes"] = _to_int(parts[9])
        out["event_time"] = parts[10]
        out["action"] = parts[12].lower()
    return out


def normalise_tgw_flow(rec):
    """Transit Gateway Flow Log delivered in the platform's custom format (13 fields):
    tgw-id tgw-attachment-id srcaddr dstaddr srcport dstport protocol packets bytes
    tcp-flags flow-direction log-status start
    This field order is set on the flow log the platform creates (see tgwflow.tf). The
    trailing `start` (Unix epoch seconds) gives each TGW event a timestamp so it carries an
    event_time like every other source. If you ingest existing TGW flow logs, create them
    with the same custom format. Logs in the older 12-field format (no `start`) still parse,
    but their event_time is left for a delivery-time fallback.
    """
    out = _blank()
    out["source_type"] = "tgw_flow"
    msg = rec if isinstance(rec, str) else rec.get("message", "")
    parts = msg.split()
    if len(parts) >= 12:
        # log-status NODATA/SKIPDATA carries no 5-tuple (every field is "-"); drop it.
        if parts[11].upper() in ("NODATA", "SKIPDATA"):
            return None
        out["vpc_id"] = parts[1]  # tgw-attachment-id kept in the vpc_id/context column
        out["src_ip"] = parts[2]
        out["dst_ip"] = parts[3]
        out["src_port"] = _to_int(parts[4])
        out["dst_port"] = _to_int(parts[5])
        out["protocol"] = _norm_proto(parts[6])
        out["packets"] = _to_int(parts[7])
        out["bytes"] = _to_int(parts[8])
        # TGW flow logs have no allow/deny verdict; use log-status as the action signal.
        out["action"] = parts[11].lower()
    if len(parts) >= 13:
        out["event_time"] = parts[12]  # start (Unix epoch seconds)
    return out


def normalise_cloudtrail(rec):
    """CloudTrail management/data event."""
    out = _blank()
    out["source_type"] = "cloudtrail"
    out["event_time"] = rec.get("eventTime")
    out["src_ip"] = rec.get("sourceIPAddress")
    out["account_id"] = rec.get("recipientAccountId") or rec.get("userIdentity", {}).get("accountId")
    out["region"] = rec.get("awsRegion")
    out["action"] = rec.get("eventName")
    return out


def _source_from_log_group(log_group):
    """Classify by the originating CloudWatch log group name (most reliable)."""
    if not log_group:
        return None
    lg = log_group.lower()
    if "network-firewall" in lg and "alert" in lg:
        return "nfw_alert"
    if "network-firewall" in lg and "flow" in lg:
        return "nfw_flow"
    if "dns" in lg or "route53" in lg:
        return "dns_firewall"
    if "tgw" in lg or "transit" in lg:
        return "tgw_flow"
    if "vpc-flow" in lg or "vpc_flow" in lg:
        return "vpc_flow"
    if "cloudtrail" in lg:
        return "cloudtrail"
    return None


_NORMALISERS = {
    "nfw_alert": normalise_nfw_alert,
    "nfw_flow": normalise_nfw_flow,
    "dns_firewall": normalise_dns,
    "tgw_flow": normalise_tgw_flow,
    "vpc_flow": normalise_vpc_flow,
    "cloudtrail": normalise_cloudtrail,
}


def classify_and_normalise(rec, source_hint=None):
    """Route a record to the right normaliser. Prefer the log-group hint; fall back
    to shape (and field count) when the record is injected directly to Firehose."""
    if source_hint in _NORMALISERS:
        return _NORMALISERS[source_hint](rec)

    if isinstance(rec, str):
        # VPC default format is 14 fields; the platform's TGW custom format is 13
        # (12 in the legacy, timestamp-less variant). Anything that is not the 14-field
        # VPC line is treated as TGW.
        n = len(rec.split())
        return normalise_vpc_flow(rec) if n == 14 else normalise_tgw_flow(rec)
    if "eventName" in rec and "eventSource" in rec:
        return normalise_cloudtrail(rec)
    if "query_name" in rec or "firewall_rule_action" in rec:
        return normalise_dns(rec)
    ev = rec.get("event", rec)
    etype = ev.get("event_type")
    if etype == "alert":
        return normalise_nfw_alert(rec)
    if etype in ("netflow", "flow"):
        return normalise_nfw_flow(rec)
    if "message" in rec and isinstance(rec["message"], str):
        return classify_and_normalise(rec["message"], source_hint)
    # Fallback: keep the record but mark it unknown so nothing is silently lost.
    out = _blank()
    out["source_type"] = "unknown"
    return out


def _decode(payload):
    """Firehose payloads may be a single JSON object, a raw text line, or a CloudWatch
    Logs subscription payload embedding multiple logEvents. Returns a list of
    (record, source_hint) tuples, where source_hint is derived from the log group."""
    text = payload.strip()
    try:
        obj = json.loads(text)
    except json.JSONDecodeError:
        return [(text, None, None)]  # raw text (e.g. flow log line injected directly)
    # CloudWatch Logs sends a CONTROL_MESSAGE to validate a new subscription filter's
    # destination. It carries no log data, so drop it (no records to emit).
    if isinstance(obj, dict) and obj.get("messageType") == "CONTROL_MESSAGE":
        return []
    # CloudWatch Logs subscription filter envelope carries the source log group and a
    # per-event epoch-millis timestamp, used as an event_time fallback when the record
    # itself has none (e.g. a legacy timestamp-less TGW flow line).
    if isinstance(obj, dict) and "logEvents" in obj:
        hint = _source_from_log_group(obj.get("logGroup", ""))
        results = []
        for le in obj.get("logEvents", []):
            inner = le.get("message", "")
            fallback_ts = le.get("timestamp")
            try:
                results.append((json.loads(inner), hint, fallback_ts))
            except (json.JSONDecodeError, TypeError):
                results.append((inner, hint, fallback_ts))
        return results
    return [(obj, None, None)]


def handler(event, _context):
    output = []
    for record in event["records"]:
        try:
            raw = base64.b64decode(record["data"])
            # CloudWatch Logs subscription filters deliver gzip-compressed payloads to
            # Firehose; records injected straight to Firehose (e.g. the demo generator)
            # are plain. Gunzip when compressed, otherwise use the bytes as-is.
            try:
                raw = gzip.decompress(raw)
            except (OSError, EOFError):
                pass
            payload = raw.decode("utf-8")
            decoded = _decode(payload)
            lines = []
            for item, hint, fallback_ts in decoded:
                normalised = classify_and_normalise(item, hint)
                if normalised is None:
                    continue  # dropped (e.g. NODATA/SKIPDATA flow record)
                event_time = _norm_time(normalised.get("event_time"))
                if event_time is None and fallback_ts is not None:
                    event_time = _norm_time(fallback_ts)
                normalised["event_time"] = event_time
                normalised["raw"] = item if isinstance(item, str) else json.dumps(item)
                lines.append(json.dumps(normalised))
            if not lines:
                # Nothing to emit (CONTROL_MESSAGE, or every event was a no-traffic
                # NODATA/SKIPDATA record). Drop the record so it does not land in the
                # error prefix or trip the delivery-success alarm.
                output.append({
                    "recordId": record["recordId"],
                    "result": "Dropped",
                    "data": record["data"],
                })
                continue
            data = ("\n".join(lines) + "\n").encode("utf-8")
            output.append({
                "recordId": record["recordId"],
                "result": "Ok",
                "data": base64.b64encode(data).decode("utf-8"),
            })
        except Exception:  # noqa: BLE001 - never drop the batch on one bad record
            output.append({
                "recordId": record["recordId"],
                "result": "ProcessingFailed",
                "data": record["data"],
            })
    return {"records": output}
