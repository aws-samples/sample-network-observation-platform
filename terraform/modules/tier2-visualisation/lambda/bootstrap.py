"""OpenSearch bootstrap for the Network Observation platform.

Run once (or on demand) after the domain exists. It performs several idempotent steps
against the OpenSearch domain, authenticating with SigV4 as the Lambda execution role:

  1. Create the least-privilege `netobs_read` and `netobs_write` custom roles and map
     each supplied IAM principal into its designated role (netobs_read, netobs_write or
     all_access), plus the built-in `opensearch_dashboards_user` role for the Cognito
     Dashboards login.
  2. PUT an index template for `network-events-*` that maps the common schema,
     including geo_country as a keyword and event_time as a date.
  3. POST the bundled saved-objects NDJSON to the Dashboards _import API, creating
     the index pattern, visualisations and the operational dashboard.

Prerequisites:
  * The Lambda execution role must be mapped to an OpenSearch role that can manage
    index templates and Dashboards saved objects (for example `all_access`). When
    this module creates the domain, map the role via the Security plugin once; for
    an existing domain, ensure the mapping exists first.
  * For a VPC-attached domain, the Lambda must run in the same VPC (configured in
    Terraform when subnet IDs are supplied).

Environment:
  OPENSEARCH_ENDPOINT   host name of the domain (no scheme)
  AWS_REGION            provided by the Lambda runtime
"""

import json
import os
import time
import urllib.error
import urllib.request

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

# How long to wait for the domain's fine-grained access control to recognise this
# function's role as the master user. On a cold `terraform apply` the bootstrap
# invocation fires the moment the domain reports Active, but FGAC master-user
# recognition lags that by a few minutes (observed 2-7 min on a Cognito-enabled domain);
# privileged calls 403 until it catches up. The Lambda's own timeout (set in Terraform)
# must exceed this budget, or the function is killed mid-wait.
MASTER_READY_TIMEOUT_SECONDS = int(os.environ.get("MASTER_READY_TIMEOUT_SECONDS", "720"))

ENDPOINT = os.environ["OPENSEARCH_ENDPOINT"].replace("https://", "").rstrip("/")
REGION = os.environ["AWS_REGION"]
SERVICE = "es"

INDEX_TEMPLATE = {
    "index_patterns": ["network-events-*"],
    "template": {
        # auto_expand_replicas keeps the index green regardless of node count: 0 replicas
        # on a single-node (demo) domain, 1 replica once there are 2+ nodes. Without this a
        # single-node domain sits permanently yellow on unassignable replica shards.
        #
        # Slowlog thresholds make the OpenSearch SEARCH/INDEX slow logs actually emit when
        # slow-log publishing is enabled (enable_opensearch_slow_logs). They are deliberately
        # conservative so only genuinely slow operations are logged, and are harmless (no
        # CloudWatch delivery) when slow-log publishing is off.
        "settings": {
            "index": {
                "auto_expand_replicas": "0-1",
                "search.slowlog.threshold.query.warn": "10s",
                "search.slowlog.threshold.query.info": "5s",
                "search.slowlog.threshold.fetch.warn": "1s",
                "indexing.slowlog.threshold.index.warn": "10s",
                "indexing.slowlog.threshold.index.info": "5s",
            }
        },
        "mappings": {
            "properties": {
                "event_time": {"type": "date"},
                "source_type": {"type": "keyword"},
                "action": {"type": "keyword"},
                "src_ip": {"type": "ip"},
                "dst_ip": {"type": "ip"},
                "src_port": {"type": "integer"},
                "dst_port": {"type": "integer"},
                "protocol": {"type": "keyword"},
                "rule_sid": {"type": "keyword"},
                "domain": {"type": "keyword"},
                "tls_sni": {"type": "keyword"},
                "geo_country": {"type": "keyword"},
                "account_id": {"type": "keyword"},
                "region": {"type": "keyword"},
                "vpc_id": {"type": "keyword"},
                "bytes": {"type": "long"},
                "packets": {"type": "long"},
            }
        }
    },
}

# Least-privilege custom roles created in OpenSearch FGAC, defined exactly as the security
# review tested them (Appendix C.1). netobs_read grants read-only access to the telemetry
# indices; netobs_write adds bulk write and index creation so the ingestion pipeline and demo
# injector can index into network-events-*. The built-in all_access and
# opensearch_dashboards_user roles already exist and are only mapped, never (re)created.
CUSTOM_ROLES = {
    "netobs_read": {
        "cluster_permissions": ["cluster_composite_ops_ro"],
        "index_permissions": [
            {
                "index_patterns": ["network-events-*"],
                "allowed_actions": ["read"],
            }
        ],
    },
    "netobs_write": {
        "cluster_permissions": ["cluster_monitor", "indices:data/write/bulk"],
        "index_permissions": [
            {
                "index_patterns": ["network-events-*"],
                "allowed_actions": ["crud", "create_index"],
            }
        ],
    },
}


def _signed_request(method, path, body, content_type="application/json", extra_headers=None):
    url = f"https://{ENDPOINT}{path}"
    data = body.encode("utf-8") if isinstance(body, str) else body
    headers = {"Content-Type": content_type}
    if extra_headers:
        headers.update(extra_headers)
    request = AWSRequest(method=method, url=url, data=data, headers=headers)
    SigV4Auth(boto3.Session().get_credentials(), SERVICE, REGION).add_auth(request)
    req = urllib.request.Request(url, data=data, method=method)
    for key, value in request.headers.items():
        req.add_header(key, value)
    with urllib.request.urlopen(req) as resp:  # noqa: S310  # nosec B310 - fixed AWS HTTPS endpoint, no user-controlled scheme
        return resp.status, resp.read().decode("utf-8")


def _put_index_template():
    status, text = _signed_request(
        "PUT", "/_index_template/network-events", json.dumps(INDEX_TEMPLATE)
    )
    return {"index_template_status": status, "body": text[:500]}


def _fix_existing_replicas():
    """Apply auto_expand_replicas to already-created indices so they go green too.

    The index template only affects new indices; existing network-events-* indices keep
    whatever replica count they were created with (yellow on a single-node domain).
    """
    body = json.dumps({"index": {"auto_expand_replicas": "0-1"}})
    status, _ = _signed_request(
        "PUT",
        "/network-events-*/_settings?allow_no_indices=true&ignore_unavailable=true",
        body,
    )
    return {"replica_settings_status": status}


# Map OpenSearch field types to the OpenSearch Dashboards index-pattern field types.
_OSD_TYPE = {
    "date": "date", "keyword": "string", "text": "string", "ip": "ip",
    "integer": "number", "long": "number", "float": "number", "double": "number",
    "boolean": "boolean",
}


def _index_pattern_fields():
    """Build the Dashboards index-pattern field list from the index template mapping.

    An index pattern imported without a `fields` attribute has an empty field cache, so
    Dashboards reports "Could not locate that index-pattern-field" for every field a
    visualisation references. Deriving the field list from the template (rather than a
    live _fields_for_wildcard call) makes this deterministic and works even on a fresh
    deploy before any data has been indexed.
    """
    props = INDEX_TEMPLATE["template"]["mappings"]["properties"]
    fields = []
    for name, spec in props.items():
        os_type = spec.get("type", "keyword")
        osd_type = _OSD_TYPE.get(os_type, "string")
        fields.append({
            "name": name,
            "type": osd_type,
            "esTypes": [os_type],
            "count": 0,
            "scripted": False,
            "searchable": True,
            "aggregatable": os_type != "text",
            "readFromDocValues": os_type != "text",
        })
    # Standard Dashboards meta fields.
    fields += [
        {"name": "_id", "type": "string", "esTypes": ["_id"], "count": 0, "scripted": False, "searchable": True, "aggregatable": False, "readFromDocValues": False},
        {"name": "_index", "type": "string", "esTypes": ["_index"], "count": 0, "scripted": False, "searchable": True, "aggregatable": True, "readFromDocValues": False},
        {"name": "_score", "type": "number", "count": 0, "scripted": False, "searchable": False, "aggregatable": False, "readFromDocValues": False},
        {"name": "_source", "type": "_source", "esTypes": ["_source"], "count": 0, "scripted": False, "searchable": False, "aggregatable": False, "readFromDocValues": False},
        {"name": "_type", "type": "string", "esTypes": ["_type"], "count": 0, "scripted": False, "searchable": True, "aggregatable": True, "readFromDocValues": False},
    ]
    return fields


def _set_index_pattern_fields():
    """Overwrite the network-events index pattern with a populated field list."""
    body = json.dumps({
        "attributes": {
            "title": "network-events-*",
            "timeFieldName": "event_time",
            "fields": json.dumps(_index_pattern_fields()),
        }
    })
    status, text = _signed_request(
        "POST",
        "/_dashboards/api/saved_objects/index-pattern/network-events?overwrite=true",
        body,
        extra_headers={"osd-xsrf": "true"},
    )
    return {"index_pattern_fields_status": status, "body": text[:300]}


def _import_saved_objects():
    with open(os.path.join(os.path.dirname(__file__), "network-observation.ndjson"), "rb") as fh:
        ndjson = fh.read()
    boundary = "----netobsboundary"
    part = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="file"; filename="objects.ndjson"\r\n'
        "Content-Type: application/ndjson\r\n\r\n"
    ).encode("utf-8") + ndjson + f"\r\n--{boundary}--\r\n".encode("utf-8")
    # OpenSearch Dashboards rejects write APIs that lack the osd-xsrf header
    # (HTTP 400 "Request must contain a osd-xsrf header").
    status, text = _signed_request(
        "POST",
        "/_dashboards/api/saved_objects/_import?overwrite=true",
        part,
        content_type=f"multipart/form-data; boundary={boundary}",
        extra_headers={"osd-xsrf": "true"},
    )
    return {"import_status": status, "body": text[:500]}


def _ensure_custom_roles():
    """Create/update the least-privilege custom roles (idempotent PUT).

    PUT /_plugins/_security/api/roles/<name> creates the role or replaces it in place, so
    re-running is safe. Built-in roles (all_access, opensearch_dashboards_user) are not
    touched here — they already exist and are only mapped.
    """
    result = {}
    statuses = []
    for name, definition in CUSTOM_ROLES.items():
        status, _ = _signed_request(
            "PUT", f"/_plugins/_security/api/roles/{name}", json.dumps(definition)
        )
        result[f"role_{name}_status"] = status
        statuses.append(status)
    result["custom_role_statuses"] = statuses
    return result


def _map_role_mappings(mappings):
    """Reconcile IAM principal ARNs into their designated OpenSearch roles.

    `mappings` is a dict of {opensearch_role: [iam_role_arn, ...]} describing the exact
    desired placement of every platform-managed principal. This function's Lambda execution
    role is the FGAC master user, so it is authorised to manage role mappings.

    Reconciliation is to the desired state, not merge-only. Every platform-managed principal
    (any ARN that appears anywhere in `mappings`) is removed from the backend_roles of any
    role it is NOT designated for. So a principal that an earlier deploy mapped into
    all_access loses all_access once it is designated netobs_read/netobs_write — satisfying
    B1's requirement that only the admin principal keep all_access on an in-place upgrade.
    Backend-role entries this platform does not manage (operator-added ARNs) are preserved,
    so operator-managed mappings are never clobbered.
    """
    mappings = mappings or {}
    # Every ARN this platform manages, across all roles. Only these may be removed from an
    # existing mapping; anything else present is operator-managed and left untouched.
    managed_arns = {a for arns in mappings.values() for a in (arns or []) if a}
    result = {}
    statuses = []
    for role, arns in mappings.items():
        desired = [a for a in (arns or []) if a]
        desired_set = set(desired)
        path = f"/_plugins/_security/api/rolesmapping/{role}"
        try:
            _status, text = _signed_request("GET", path, None)
            current = json.loads(text).get(role, {})
        except urllib.error.HTTPError as exc:
            # Only a genuine 404 means the mapping does not exist yet; start empty and let
            # the PUT below create it. Every other HTTP status (403, 5xx, ...) is re-raised
            # rather than treated as absence: a failed read must NOT let the PUT overwrite
            # the live mapping with just the desired principals, which would erase the
            # operator-managed hosts, users and backend roles we never actually read.
            if exc.code != 404:
                raise
            current = {}
        # A URLError (timeout/connection) or a json parse error is intentionally not caught
        # here: it propagates so the final status gate fails the apply instead of rebuilding
        # the mapping from unread state.
        fields = ("backend_roles", "hosts", "users", "and_backend_roles")
        mapping = {f: list(current.get(f, [])) for f in fields}
        # Drop platform-managed principals not designated for THIS role (reconcile to desired
        # state); keep operator-managed entries and this role's designated principals.
        mapping["backend_roles"] = [
            arn for arn in mapping["backend_roles"]
            if arn not in managed_arns or arn in desired_set
        ]
        for arn in desired:
            if arn not in mapping["backend_roles"]:
                mapping["backend_roles"].append(arn)
        put_status, _ = _signed_request("PUT", path, json.dumps(mapping))
        result[f"mapping_{role}_status"] = put_status
        statuses.append(put_status)
    result["role_mapping_statuses"] = statuses
    return result


def _wait_until_master_ready(timeout_seconds=MASTER_READY_TIMEOUT_SECONDS):
    """Block until FGAC recognises this function's role as the master user.

    Right after the domain is created the Security plugin may not yet accept this role as
    master, so privileged calls return 403. Poll a read-only Security API until it stops
    returning 403: a 200 (mapping present) or 404 (mapping absent but we are authorised)
    both mean the master is effective. Returns a status dict; does not raise on the
    expected 403/transient cases.
    """
    deadline = time.time() + timeout_seconds
    delay = 5
    attempts = 0
    last = None
    while True:
        attempts += 1
        try:
            status, _ = _signed_request(
                "GET", "/_plugins/_security/api/rolesmapping/all_access", None
            )
            if status == 200:
                return {"master_ready": True, "attempts": attempts}
        except urllib.error.HTTPError as exc:
            last = exc.code
            if exc.code == 404:
                # Authorised, but the all_access mapping does not exist yet: master is ready.
                return {"master_ready": True, "attempts": attempts, "note": "mapping absent"}
            if exc.code != 403:
                raise
        except urllib.error.URLError as exc:
            last = str(getattr(exc, "reason", exc))
        if time.time() >= deadline:
            return {"master_ready": False, "attempts": attempts, "last": last}
        time.sleep(delay)
        delay = min(delay * 1.5, 20)


def handler(event, _context):
    event = event or {}
    mappings = event.get("role_mappings")
    if not mappings:
        try:
            mappings = json.loads(os.environ.get("FGAC_ROLE_MAPPINGS", "{}"))
        except Exception:  # noqa: BLE001
            mappings = {}

    result = {}
    # Wait out the FGAC master-readiness race before any privileged call, so a cold apply
    # does not silently 403 its way to a broken (unmapped, dashboard-less) domain.
    try:
        result.update(_wait_until_master_ready())
    except Exception as exc:  # noqa: BLE001
        result["master_ready_error"] = str(exc)

    # Create the least-privilege custom roles before mapping principals into them.
    try:
        result.update(_ensure_custom_roles())
    except Exception as exc:  # noqa: BLE001 - report, do not fail the deploy
        result["custom_roles_error"] = str(exc)
    try:
        result.update(_map_role_mappings(mappings))
    except Exception as exc:  # noqa: BLE001 - report, do not fail the deploy
        result["role_mapping_error"] = str(exc)
    try:
        result.update(_put_index_template())
    except Exception as exc:  # noqa: BLE001
        result["index_template_error"] = str(exc)
    try:
        result.update(_fix_existing_replicas())
    except Exception as exc:  # noqa: BLE001
        result["replica_settings_error"] = str(exc)
    try:
        result.update(_import_saved_objects())
    except Exception as exc:  # noqa: BLE001
        result["import_error"] = str(exc)
    # Populate the index-pattern field list after import, so visualisations can resolve
    # their fields (otherwise Dashboards reports "Could not locate that index-pattern-field").
    try:
        result.update(_set_index_pattern_fields())
    except Exception as exc:  # noqa: BLE001
        result["index_pattern_fields_error"] = str(exc)

    # Fail loudly if the privileged steps did not take. aws_lambda_invocation treats a
    # raised error as a failed apply (and, being CREATE_ONLY, retries it on the next
    # apply). That surfaces a broken bootstrap instead of reporting a green apply over a
    # domain with no custom roles, no role mappings or no index template — which would
    # leave the ingestion pipeline unauthorised and the dashboards empty.
    role_statuses = result.get("custom_role_statuses", [])
    mapping_statuses = result.get("role_mapping_statuses", [])
    roles_ok = bool(role_statuses) and all(s in (200, 201) for s in role_statuses)
    mappings_ok = bool(mapping_statuses) and all(s in (200, 201) for s in mapping_statuses)
    if not roles_ok or not mappings_ok or result.get("index_template_status") != 200:
        raise RuntimeError("OpenSearch bootstrap did not complete: " + json.dumps(result, default=str))
    return result
