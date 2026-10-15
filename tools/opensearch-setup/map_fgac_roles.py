#!/usr/bin/env python3
"""Map IAM roles into an OpenSearch fine-grained-access-control (FGAC) role.

Why this exists
---------------
When the platform's OpenSearch domain uses FGAC with an **IAM master user**
(the recommended setup when you deploy through an assumed role or IAM Identity
Center/SSO), the OpenSearch Dashboards "Security -> Roles -> Backend roles"
screen is not reachable from a plain browser: with an IAM master user and no
Amazon Cognito / SAML, the Dashboards endpoint has no interactive login. The
supported way to manage role mappings in that case is the OpenSearch `_security`
REST API, signed with AWS SigV4 as the master-user identity.

This script does exactly that, idempotently: it reads the current mapping for a
target FGAC role (default `all_access`), adds the backend IAM role ARNs you pass,
de-duplicates, and writes it back.

Run it as the SAME identity you set as `opensearch_master_user_arn` (for example
from AWS CloudShell in the analysis account, or any shell whose credentials
assume that role). AWS CloudShell already has boto3 and your credentials.

Examples
--------
Map the platform's ingestion, bootstrap and demo-injector roles so they can
write to and manage the `network-events-*` indices:

    python map_fgac_roles.py \
        --endpoint search-netobs-obs-xxxx.eu-west-2.es.amazonaws.com \
        --region eu-west-2 \
        --role-arn arn:aws:iam::123456789012:role/netobs-osis \
        --role-arn arn:aws:iam::123456789012:role/netobs-os-bootstrap \
        --role-arn arn:aws:iam::123456789012:role/netobs-demo-injector

Add `--dry-run` to preview the change without writing.
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

SERVICE = "es"
# Editable members of a role mapping; "reserved"/"hidden"/"static" are read-only.
MAPPING_FIELDS = ("backend_roles", "hosts", "users", "and_backend_roles")


def _signed_request(method, endpoint, region, path, body=None):
    host = endpoint.replace("https://", "").replace("http://", "").rstrip("/")
    url = f"https://{host}{path}"
    data = body.encode("utf-8") if isinstance(body, str) else body
    aws_req = AWSRequest(
        method=method, url=url, data=data, headers={"Content-Type": "application/json"}
    )
    SigV4Auth(boto3.Session().get_credentials(), SERVICE, region).add_auth(aws_req)
    req = urllib.request.Request(url, data=data, method=method)
    for key, value in aws_req.headers.items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req) as resp:  # noqa: S310  # nosec B310 - fixed AWS HTTPS endpoint, no user-controlled scheme
            return resp.status, resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--endpoint", required=True, help="OpenSearch domain endpoint host (no scheme)")
    parser.add_argument("--region", required=True, help="AWS region of the domain, e.g. eu-west-2")
    parser.add_argument("--role-arn", action="append", dest="role_arns", required=True,
                        metavar="ARN", help="IAM role ARN to add (repeatable)")
    parser.add_argument("--opensearch-role", default="all_access",
                        help="FGAC role to map into (default: all_access)")
    parser.add_argument("--dry-run", action="store_true", help="Preview without writing")
    args = parser.parse_args()

    path = f"/_plugins/_security/api/rolesmapping/{args.opensearch_role}"

    status, text = _signed_request("GET", args.endpoint, args.region, path)
    if status == 200:
        current = json.loads(text).get(args.opensearch_role, {})
    elif status == 404:
        current = {}
    elif status == 403:
        print("ERROR 403: the calling identity is not the OpenSearch master user (or a "
              "security-manager). Run as the identity set in opensearch_master_user_arn.", file=sys.stderr)
        return 2
    else:
        print(f"ERROR reading current mapping: HTTP {status}\n{text}", file=sys.stderr)
        return 1

    mapping = {f: list(current.get(f, [])) for f in MAPPING_FIELDS}
    before = sorted(mapping["backend_roles"])
    for arn in args.role_arns:
        if arn not in mapping["backend_roles"]:
            mapping["backend_roles"].append(arn)
    after = sorted(mapping["backend_roles"])

    print(f"Role mapping: {args.opensearch_role}")
    print(f"  backend_roles before: {before}")
    print(f"  backend_roles after:  {after}")

    if before == after:
        print("No change needed; all ARNs already mapped.")
        return 0
    if args.dry_run:
        print("--dry-run set; not writing.")
        return 0

    put_status, put_text = _signed_request(
        "PUT", args.endpoint, args.region, path, json.dumps(mapping)
    )
    print(f"PUT {path} -> HTTP {put_status}")
    print(put_text)
    return 0 if put_status in (200, 201) else 1


if __name__ == "__main__":
    sys.exit(main())
