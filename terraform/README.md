# Network Observation Platform — Terraform

Terraform for the three-tier Network Observation platform described in the
[APG pattern](https://docs.aws.amazon.com/prescriptive-guidance/latest/patterns/build-a-network-observation-platform-for-aws-network-firewall.html). It consolidates AWS Network Firewall, Route 53 Resolver
DNS Firewall, Transit Gateway Flow Log, VPC Flow Log and CloudTrail telemetry into one
queryable plane (Tier 1), presents it through curated dashboards (Tier 2), and adds
AWS-native AI-assisted operations (Tier 3). An OpenSearch Ingestion pipeline
streams the consolidated data into the OpenSearch dashboards from real traffic.

## Sources

| Source | How it is captured | Notes |
|---|---|---|
| AWS Network Firewall alert | CloudWatch Logs → Firehose | Drops and the matching Suricata SID |
| AWS Network Firewall flow | S3 (in place) + Firehose | Cataloged in place from the existing flow-log bucket |
| Route 53 DNS Firewall | CloudWatch Logs → Firehose | Blocked/allowed domains |
| Transit Gateway Flow Logs | CloudWatch Logs → Firehose | Primary east-west source; also how Direct Connect / VPN traffic is seen |
| VPC Flow Logs | CloudWatch Logs → Firehose | Per-ENI accept/reject |
| CloudTrail | CloudWatch Logs → Firehose | Who changed the firewall, and when |
| Direct Connect health | CloudWatch metrics + alarms | **No flow logs exist for DX/DXGW** — only AWS/DX metrics (state, light levels, CRC errors, bps/pps). Surfaced on the dashboard; traffic content crossing DX appears in the TGW/VPC flow logs above. |

## Existing infrastructure or new — the core design point

Every external dependency follows one pattern:

- `create_<thing> = true` — the platform provisions the resource.
- `create_<thing> = false` + `existing_<thing>_...` — the platform reads the existing
  resource by identifier (through a data source) and wires the platform to it.

This lets the same code deploy incrementally against a live landing zone
(see `examples/brownfield.tfvars`) or stand the whole platform up from scratch
(see `examples/greenfield.tfvars`).

## Layout

```
terraform/
  providers.tf        aws >= 6.0 + archive; region/credentials from the caller session
  variables.tf        all inputs, grouped by tier, with the create_* / existing_* toggles
  locals.tf, kms.tf   optional dedicated customer-managed KMS key
  main.tf             wires the three tier modules (each gated by enable_tierN_*)
  outputs.tf
  examples/           greenfield.tfvars, brownfield.tfvars, hardened.tfvars
  modules/
    tier1-consolidation/  Firehose + transform Lambda, S3, Glue, Athena, subscriptions,
                          optional VPC Flow Logs, optional TGW Flow Logs
    tier2-visualisation/  OpenSearch domain, dashboards + bootstrap Lambda, CloudWatch
                          dashboard, Direct Connect health metrics/alarms
    tier3-ai-ops/         CloudWatch-investigations wiring, baseline alarms,
                          rule-hygiene Lambda
    s3-to-opensearch/     OpenSearch Ingestion pipeline (S3 Parquet -> OpenSearch) + SQS
    demo-data-injector/   optional scheduled Lambda that seeds synthetic telemetry
```

## Prerequisites

- Terraform/OpenTofu 1.5.0+ and the **AWS** (6.0.0+), **awscc** (1.98.0+), **time**, and
  **archive** providers (`terraform init` installs them). `awscc` and `time` are only needed
  for Tier 3's AWS DevOps Agent. Python-free deployment — Lambdas are zipped by the `archive`
  provider from the bundled source, so there is no build step.
- AWS credentials for the analysis account (Log Archive or Security Tooling). The
  Region comes from your session; export `AWS_REGION`/`AWS_PROFILE` as usual.
- AWS Network Firewall with **both** flow and alert logging enabled, and appliance
  mode enabled on the Transit Gateway inspection attachment (symmetric routing).

## Usage

```bash
terraform init
terraform plan  -var-file=examples/brownfield.tfvars   # or greenfield.tfvars
terraform apply -var-file=examples/brownfield.tfvars
```

Deploy tiers independently by toggling `enable_tier1_consolidation`,
`enable_tier2_visualisation`, and `enable_tier3_ai_ops`. The recommended sequence is
Tier 1, then Tier 2, then Tier 3, matching the APG delivery plan.

## Post-apply steps

OpenSearch setup is now automatic. During apply, a bootstrap Lambda — the domain's
fine-grained-access-control (FGAC) master user — creates the least-privilege
`netobs_read` / `netobs_write` roles and maps each principal into the role it needs
(your admin principal into `all_access`; the Cognito login role and the DevOps Agent both
into `netobs_read`, with only the Cognito browser-login role additionally mapped to the
built-in `opensearch_dashboards_user`; the ingestion pipeline and demo injector into
`netobs_write`), creates the `network-events-*` index
template, and imports the index pattern, visualisations and the "Network Observation"
dashboard. There is no manual
Security-console role-mapping step (and none would be reachable on an IAM-master-user
domain). Set `auto_bootstrap = false` only if you manage OpenSearch setup out of band.

What still needs a human:

1. **Sign in to OpenSearch Dashboards (Tier 2).** Browser access is via Amazon Cognito
   (`enable_dashboards_cognito`, on by default). Set `dashboards_notification_email`
   (or `notification_email`); Cognito emails a temporary password on apply. Open the
   `opensearch_dashboards_url` output, sign in, set a new password, and the dashboards
   are already loaded. To manage OpenSearch security by API instead, use
   `../tools/opensearch-setup/map_fgac_roles.py` as the master-user identity.

2. **Ask the AWS DevOps Agent (Tier 3).** Open the AWS DevOps Agent console in
   `devops_agent_region` (default `eu-west-1`) → the `network-observation` agent space →
   Operator app, and ask investigative questions. The `devops_agent_space_arn` output
   identifies it.

3. **Enable CloudWatch investigations (Tier 3, optional).** CloudWatch investigations is an
   account/Region-level capability: enable an investigation group once and associate it with
   the alarms (console or CLI) so an investigation can auto-start from an alarm action — this
   is not yet a stable Terraform resource, so the platform does not create it. What the
   platform wires: `investigation_alarm_names` (plus the baseline alarms) feeds an EventBridge
   rule that forwards alarm state changes to SNS, so on-call is notified when an investigation
   would start.

4. **Confirm the email subscription** if `notification_email` was set (SNS sends a
   confirmation link).

5. **Brownfield only — add the S3 → SQS notification.** When the analysis bucket is
   pre-existing (`create_analysis_bucket = false`), the ingestion module does not touch
   the bucket's notification configuration (to avoid clobbering existing ones). Add a
   notification for the `consolidated/` prefix to the `<name_prefix>-ingest` SQS queue
   (the `notification_queue_url` output) yourself, or via EventBridge.

## Seeding a demo account with synthetic data

A fresh account has no traffic, so the dashboards start empty. Two ways to populate them:

- **One-shot / on-demand:** run the CLI generator in `../tools/mock-data-generator`
  against the `firehose_stream_names` and `opensearch_endpoint` outputs, plus
  `--flow-logs-bucket` pointed at a dedicated synthetic/demo bucket — never the real
  Network Firewall flow-log bucket — which the `nfw_flow_s3` table reads only when the
  Glue catalog is pointed at that demo bucket. See that tool's README.
- **Continuous (live-looking demo):** set `enable_demo_data_injector = true`. This
  deploys the same generator as a Lambda on an EventBridge schedule
  (`demo_injector_schedule`, default every 5 minutes), wired automatically to the
  Firehose stream (Tier 1), the OpenSearch domain (Tier 2), and — only when you set
  `demo_flow_logs_bucket_name` to a dedicated demo bucket — that bucket for the `nfw_flow`
  events (delivered as the firewall would, not via Firehose). Leave `demo_flow_logs_bucket_name`
  unset to keep synthetic `nfw_flow` on the Firehose/OpenSearch fallback path; never point it
  at the real Network Firewall flow-log bucket, so synthetic and real flow logs never mix.
  Tune volume with `demo_events_per_run` and `demo_window_hours`.

The injector is **for demo/POC accounts only** — disable it before the platform carries
real production traffic so synthetic and real data are never mixed. The injector's
Lambda role is mapped into OpenSearch fine-grained access control automatically by the
bootstrap Lambda during apply, so its OpenSearch writes succeed with no manual step.

## How data reaches OpenSearch (ingestion pipeline and demo)

Tier 1's Firehose lands normalised **Parquet** in S3, which powers the
**Athena** views directly. The **OpenSearch dashboards** read a separate
`network-events-*` index, populated by:

- **Ingestion pipeline (real traffic):** the `s3-to-opensearch` module — an
  [Amazon OpenSearch Ingestion](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/ingestion.html)
  pipeline that reads the Parquet objects from S3 (via an SQS notification, Parquet
  codec) and indexes them into OpenSearch. Enabled by `enable_opensearch_ingestion`
  (default on). The bootstrap Lambda maps its role into the `netobs_write` FGAC role
  automatically during apply. Note the pipeline runs a minimum of 1 OCU continuously, so
  it carries an ongoing cost.
- **Demo:** the mock-data generator / demo injector, which also bulk-indexes straight
  into OpenSearch so a fresh account shows data before real traffic (and before the
  pipeline has anything to read).

Both paths write to the same `network-events-*` index and the same schema, so the
dashboards behave identically whether the data is synthetic or real.

## Notes and things to verify before production

- **Firehose Parquet conversion** relies on the Glue `network_events` table schema; if
  you change the normalised schema in `transform.py`, update `glue.tf` to match.
- **Existing NFW flow logs in S3** are catalogued in place (`flow_s3.tf`) rather than
  re-ingested, to avoid mutating the existing bucket's event notifications. Refine the
  table `location` to the exact prefix if the bucket holds other content.
- **CloudWatch investigations** have been generally available since June 2025 (previously the
  Amazon Q Developer operational-investigations preview) and run in a subset of Regions. An
  investigation can auto-trigger from a CloudWatch alarm action; confirm Region availability
  and current behaviour against the AWS docs before relying on the alarm-triggered path.
- **Existing TGW Flow Logs** (`create_tgw_flow_logs = false`) must be created with the
  platform's custom field order (see `modules/tier1-consolidation/tgwflow.tf`) so the
  transform parses them positionally; otherwise fields will misalign. The platform sets
  this format automatically for the flow logs it creates.
- **OpenSearch Ingestion Parquet codec**: the pipeline reads the Firehose-written
  Parquet directly. Confirm the Parquet codec is available in your Region's OSIS version;
  if not, switch the Firehose to newline-JSON output and the pipeline codec to `newline`.
- **Geo enrichment**: `geo_country` is populated only if the source logs already carry
  it (for example NFW `geoip` matches). Add an enrichment step in `transform.py` if you
  need geo on every record.
- For a **security-sensitive or compliance-driven** environment: keep the
  customer-managed KMS key, VPC-attach the OpenSearch domain, and do not add
  sensitive data to dashboards or sample data. Start from **`examples/hardened.tfvars`**, the
  hardened profile that turns on VPC attachment, S3 access logging, CloudTrail S3 data
  events, OpenSearch audit + slow logs, Cognito MFA, and audit-grade retention. Auditing
  controls that are additive and cheap (S3 access logging, OpenSearch audit logs) are on by
  default even in the PoC; the rest are opt-in via `enable_cloudtrail_data_events`, `enable_cognito_mfa`,
  `enable_opensearch_slow_logs`, and the `opensearch_subnet_ids` VPC inputs. Note that a
  VPC-attached domain has a private endpoint — plan browser access (VPN / Direct Connect /
  bastion / proxy) accordingly. Organization CloudTrail, AWS Config, GuardDuty, Security
  Hub and Access Analyzer are assumed to exist at the landing-zone layer.
