# Smoke test

`run-smoke-test.ps1` runs the CLI-verifiable checks from the platform test plan and
prints `PASS`/`FAIL`/`SKIP` per feature, then a summary, and finally the manual
console/browser checks (with the live OpenSearch Dashboards URL filled in). It is
**read-only and safe to run against a live deployment** — every check is a
`describe`/`get`/`list`, and the only queries are bounded Athena `count(*)` runs enabled
with `-RunAthena`. Nothing is created, modified, or deleted.

`check-devops-agent.py` is an optional boto3 helper the script calls under `-RunAgent`; it
opens a chat with the DevOps Agent and confirms it answers from the lake with no
permission block. It can also be run on its own.

## Prerequisites
- AWS credentials for the deployment account (`aws sts get-caller-identity` should succeed).
- AWS CLI v2 and PowerShell (Windows PowerShell 5.1 or PowerShell 7+).
- For `-RunAgent` only: `python` on PATH with `boto3` installed.

## Usage
```powershell
# fast pass (read-only describes/metrics; no queries)
powershell -NoProfile -ExecutionPolicy Bypass -File tools/smoke-test/run-smoke-test.ps1

# also run bounded Athena count(*) queries, incl. the DevOps Agent workgroup data path
powershell -NoProfile -ExecutionPolicy Bypass -File tools/smoke-test/run-smoke-test.ps1 -RunAthena

# also exercise the full DevOps Agent chat end-to-end (needs python + boto3)
powershell -NoProfile -ExecutionPolicy Bypass -File tools/smoke-test/run-smoke-test.ps1 -RunAthena -RunAgent

# the agent deep-check can also run standalone:
python tools/smoke-test/check-devops-agent.py --agent-region eu-west-1 --lake-region eu-west-2
```

Parameters (all optional): `-Region` (default `eu-west-2`), `-AgentRegion` (default
`eu-west-1`), `-NamePrefix` (default `netobs`), `-RunAthena` (switch), `-RunAgent` (switch).
The script exits non-zero if any check fails, so it can gate a pipeline.

## What it covers
- **Tier 1** — S3 consolidated Parquet, Glue `network_events` table, Firehose stream ACTIVE,
  transform Lambda error-free.
- **Tier 2** — OpenSearch domain health (TLS + node-to-node), audit logs, ingestion pipeline
  ACTIVE, CloudWatch `*-quick-view` dashboard exists, and the **data behind its two metric
  widgets**: Firehose `DeliveryToS3.Records` in the last hour and OpenSearch
  `SearchableDocuments` (so you know the dashboard and the OpenSearch dashboards will show
  data, not just that they exist).
- **Tier 3** — baseline alarms present and not in ALARM; **DevOps Agent** space present, its
  managed-results **workgroup query path succeeds** (`-RunAthena` — this is the regression
  check for the agent's KMS/results config), and, with `-RunAgent`, a **full agent chat**
  that must answer from the lake with no permission block.
- **Security / auditing** — S3 public-access block, CMK encryption, S3 access logging,
  Firehose confused-deputy `aws:SourceAccount` condition.

## Not covered (manual — printed at the end of the run)
The OpenSearch **Dashboards** themselves require a Cognito browser login, so they stay a
manual check: the script prints the exact Dashboards URL, the login step, and the panels to
confirm. (The DevOps Agent operator app is covered by `-RunAgent`; the console path is also
printed for convenience.)
