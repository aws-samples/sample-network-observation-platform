# Mock data generator

Seeds the Network Observation platform with realistic synthetic telemetry so the
dashboards and Athena queries show data before real traffic exists. Everything it
produces is **synthetic** — no personal data; internal addresses use the landing-zone
`10.x` ranges and all external domains/addresses are obviously fake.

It writes to three targets:

| Target | Flag | What it feeds |
|---|---|---|
| Firehose | `--firehose-stream` | Sends **source-shaped** records to the consolidation Firehose stream. They pass through the real transform Lambda into Parquet in S3, so they appear in **Athena**. This exercises the whole pipeline. |
| OpenSearch | `--opensearch-endpoint` | Bulk-indexes **normalised** documents straight into the `network-events-*` index that the **OpenSearch dashboards** read. |
| Flow logs (S3) | `--flow-logs-bucket` | Delivers the **`nfw_flow`** events as gzipped Suricata EVE JSON straight to the bucket you name, exactly as AWS Network Firewall ships flow logs itself — **not** via Firehose. Point this at a dedicated synthetic/demo bucket, **never** the real Network Firewall flow-log bucket, so synthetic and real flow logs never mix. The `nfw_flow_s3` Athena table reads it in place only if the Glue catalog is pointed at that bucket; otherwise leave the flag off and `nfw_flow` stays on the Firehose/OpenSearch (`network_events`) path. Pair with `--firewall-name` for a realistic key path. |

Supply one or more.

## Prerequisites

- Python 3.12+ with `boto3` (`pip install boto3==1.43.0`).
- AWS credentials for the platform account on your shell (`AWS_PROFILE` / `AWS_REGION`).
- For the OpenSearch target: the identity you run as must be mapped in the OpenSearch
  Security plugin to a role that can write (for example `all_access`), the same
  fine-grained-access-control requirement as the dashboard bootstrap. For a
  VPC-attached domain, run from somewhere with network reach to the domain.

## One-shot demo seed

Populate the last 24 hours with 5,000 events across all targets:

```bash
python generate_events.py \
  --firehose-stream netobs-consolidated \
  --opensearch-endpoint search-netobs-obs-xxxx.eu-west-1.es.amazonaws.com \
  --flow-logs-bucket netobs-demo-flow-<account-id> \
  --firewall-name netobs-test-fw \
  --count 5000 --hours 24
```

The stream name and OpenSearch endpoint are Terraform outputs
(`firehose_stream_names`, `opensearch_endpoint`); the flow-log bucket must be a dedicated
synthetic/demo bucket (for example the test harness's `demo_flow_logs_bucket_name` bucket),
**never** the real Network Firewall flow-log bucket, so synthetic and real flow logs stay
separate. The firewall name is `firewall_name`. Include `--flow-logs-bucket` only when the
Glue catalog points at that demo bucket, so the `nfw_flow` events populate the `nfw_flow_s3`
table; omit it and `nfw_flow` falls back to the Firehose path instead.

Notes:
- Firehose buffers before writing to S3 (up to ~5 minutes / 128 MB), so Athena results
  appear shortly after, not instantly.
- The generator emits a spread of allow/deny/alert/block actions, a blocked-domain
  leaderboard, geo sources, and Suricata SIDs. A few SIDs are intentionally never
  emitted so the Tier 3 rule-hygiene report has zero-hit candidates to find.

## Continuous injection (live-looking demo)

Two options:

1. **Cron / scheduled task** on any host with credentials, calling the command above
   with a smaller `--count` and `--hours 1` every few minutes.
2. **The Terraform demo-injector module** (`modules/demo-data-injector`), which deploys
   this same script as a Lambda on an EventBridge schedule. Enable it with
   `enable_demo_data_injector = true`. See the root `terraform/README.md`.

## Cleaning up

- Athena/S3: delete the synthetic objects under the `consolidated/` prefix for the demo
  dates, or just let the S3 lifecycle policy age them out.
- OpenSearch: delete the demo indices, for example
  `DELETE network-events-2026.09.*` from Dev Tools.

Remove or disable the generator before the platform carries real production traffic so
synthetic and real data are never mixed.
