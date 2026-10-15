# Getting started (for network engineers new to AWS)

This guide is for the person who owns the firewall but does not live in AWS or Terraform.
It explains, in plain language, what this platform is, the AWS words you will meet, and one
tested path from an empty account to a working dashboard and an AI assistant you can ask
questions. If you already work with AWS and Terraform daily, skip to [README.md](README.md)
and [terraform/README.md](terraform/README.md) — they are written for you.

---

## 1. What you are deploying, in one breath

AWS Network Firewall does a good job of blocking and allowing traffic, but it does **not**
give you a single screen to see what it is doing, and it does not link a log line back to the
rule that produced it. This platform fills that gap. It has three parts ("tiers"), and you can
turn each on or off:

| Tier | Plain-language job | What you get out of it |
|------|--------------------|------------------------|
| **Tier 1 — Consolidate** | Gather every network log (firewall, DNS, flow logs, audit trail) into one tidy pile and give every record the same columns. | One place you can query, instead of ten log groups. |
| **Tier 2 — Visualise** | Turn that pile into charts. | A ready-made dashboard: top talkers, allow vs deny, blocked domains, a map, per-rule trends. |
| **Tier 3 — AI-assisted ops** | Add an AWS AI agent and some scheduled reports. | Ask "why did drops spike in the last hour?" in plain English; get a weekly "these rules never fire" report. |

You end up with: **a dashboard you log into with a normal username and password, and an AI
agent you can ask questions in a chat window.**

---

## 2. The AWS words you will meet (mini glossary)

You do not need to be an expert in these. This is just enough to not feel lost.

- **Terraform / OpenTofu** — a tool that reads text files describing what you want in AWS and
  then builds it. `apply` = build it; `destroy` = tear it down. This project is tested with
  **OpenTofu** (the command is `tofu`), but the older `terraform` command works the same way.
- **Region** — a geographic AWS location (e.g. `eu-west-2` is London). Things live in a Region.
- **S3** — AWS's file storage (like a giant shared drive). The consolidated logs land here.
- **Amazon Data Firehose** — a pipe that carries log records into S3 and reformats them on
  the way.
- **Glue + Athena** — Glue is a catalogue that says "these files are a table with these
  columns"; Athena lets you run ordinary SQL (`SELECT ...`) over those files.
- **OpenSearch + OpenSearch Dashboards** — a search database plus its charting web app. This
  is what powers the visual dashboard.
- **Cognito** — the login page. It emails you a temporary password and lets you sign in to the
  dashboard in a browser.
- **CloudWatch** — AWS's built-in metrics, logs and alarms service.
- **KMS (CMK)** — the encryption key that protects your data at rest. "CMK" = a key you own.
- **IAM role / policy** — permissions. A "role" is an identity a service assumes; a "policy"
  lists what it may do. You mostly do not touch these; the platform sets them up.
- **AWS Network Firewall / DNS Firewall** — the firewalls whose logs you are observing.
- **VPC / Transit Gateway (TGW) flow logs** — records of traffic between networks. "Appliance
  mode" on the TGW just means traffic goes through the firewall symmetrically (both directions
  take the same path) so inspection works.
- **CloudTrail** — the audit log of *who changed what* in AWS (e.g. who edited the firewall).
- **AWS DevOps Agent** — the AI agent (Tier 3). It reads your telemetry and answers questions.
  It is only available in a few Regions, so it may run in a different Region from your data —
  that is normal and handled for you.

---

## 3. Before you start

**You need:**
- An AWS account you are allowed to build in, and credentials on your machine (so
  `aws sts get-caller-identity` works). If you sign in through IAM Identity Center / SSO or by
  assuming a role, note your **role ARN** — you will need it in step 2 below.
- **OpenTofu** (or Terraform) version 1.5 or newer installed. `tofu version` should print a number.
- An email address you can check (Cognito sends your dashboard password there).
- For the greenfield path below, permission to create a small VPC, a Transit Gateway and a
  Network Firewall.

**A word on cost.** This is not a free toy. The OpenSearch domain and the OpenSearch Ingestion
pipeline (which runs continuously at a minimum size) are the main cost drivers, and the AI
agent adds more. Expect a **non-trivial monthly cost** while it runs. Treat it as an evaluation
environment and **tear it down when you are done** (see section 7).

---

## 4. The happy path: empty account to working dashboard

There are two ways in. **Greenfield** builds a throwaway firewall + network for you to try the
platform against — use this first. **Brownfield** points the platform at a firewall you already
have — see [README.md](README.md#option-b-brownfield-existing-landing-zone) once you are comfortable.

> Commands below use `tofu`. If you installed Terraform instead, replace `tofu` with
> `terraform` — the arguments are identical.

### Step 1 — Build the throwaway prerequisites (the "test harness")

```bash
cd test-harness
tofu init
tofu apply
```

`init` downloads the AWS plugins; `apply` shows a plan and asks you to type `yes`. When it
finishes it prints outputs.

**What you should see:** a list of outputs, and near the bottom a block called
`platform_tfvars_snippet`. To print just that block:

```bash
tofu output platform_tfvars_snippet
```

Copy the lines it prints (firewall name, log group, bucket, etc.).

### Step 2 — Tell the platform where things are

Open `terraform/examples/test-harness.tfvars` in a text editor and:

1. Paste the values from step 1 over the matching lines.
2. Set **`opensearch_master_user_arn`** to your own IAM role/user ARN, for example
   `arn:aws:iam::111122223333:role/Admin`. This matters — see the common error in section 6.
3. Set **`dashboards_notification_email`** (or `notification_email`) to your email address.

Save the file.

### Step 3 — Deploy the platform

```bash
cd ../terraform
tofu init
tofu apply -var-file=examples/test-harness.tfvars
```

This one takes a while (the OpenSearch domain alone is ~15–20 minutes). It is normal for it to
sit quietly for a long time.

**What you should see when it finishes:** a block of outputs including
`opensearch_dashboards_url`, `dashboards_login_username`, and (if Tier 3 is on)
`devops_agent_space_region`. If `apply` errors, jump to section 6.

### Step 4 — Log into the dashboard

1. Check your email for a message with a temporary password (from Cognito).
2. Open the URL from the `opensearch_dashboards_url` output in a browser.
3. Sign in with `dashboards_login_username` and the temporary password; set a new password when
   prompted.

**What you should see:** the pre-loaded **Network Observation** dashboard. On a brand-new
account it may be **empty** — that is expected (there is no traffic yet). See section 5 to fill
it with sample data.

### Step 5 — Ask the AI agent a question (Tier 3)

1. Open the **AWS DevOps Agent** console in the Region shown by `devops_agent_space_region`
   (default `eu-west-1`, which may differ from where your data lives — that is fine).
2. Select the **`network-observation`** agent space, open the **Operator app**.
3. Ask something like *"Which destinations were blocked most in the last 24 hours in
   eu-west-2?"* (name your data Region in the question).

The agent queries the data lake on its own with its read-only base role — no extra setup is
needed. That base role reads the lake but never writes the consolidated data. The opt-in elevated
(directed-actions) role adds only approval-gated Athena query execution — it may write query
results solely under the `athena-results/` prefix and grants no infrastructure, firewall-policy,
or lake-data mutation — and every directed action needs per-action operator approval.

---

## 5. Filling an empty dashboard with sample data

A fresh account has no real traffic, so the charts start empty. To see the platform "light up":

- **Quick, one-off:** run the generator in `tools/mock-data-generator/` against the
  `firehose_stream_names` and `opensearch_endpoint` outputs, plus `--flow-logs-bucket`
  pointed at a dedicated synthetic/demo bucket — never the real Network Firewall flow-log
  bucket — for the firewall flow logs (see that tool's README).
- **Continuous demo:** set `enable_demo_data_injector = true` and re-apply; a small scheduled
  job keeps injecting realistic-looking data every few minutes.

**Turn the injector off before any real traffic flows**, so real and synthetic data never mix.

---

## 6. When something goes wrong (the common ones)

- **`apply` fails with "The master user ARN is not one of the allowed types".**
  You left `opensearch_master_user_arn` empty while signing in via SSO or an assumed role.
  OpenSearch will not accept a temporary session identity as its master user. Fix: set
  `opensearch_master_user_arn` to a plain role/user ARN (the base role, e.g.
  `arn:aws:iam::<account>:role/Admin`) and re-apply.

- **The dashboard is empty.** Almost always "no data yet," not a bug — see section 5. If it
  stays empty after injecting data, give the ingestion pipeline a few minutes to catch up.

- **No Cognito email arrived.** Check spam; confirm `dashboards_notification_email` was set
  before apply. You can re-send by re-running apply.

- **The DevOps Agent isn't in my Region.** The service only runs in a few Regions, so the
  platform puts the agent in `devops_agent_region` (default `eu-west-1`) and points it at your
  account. Look for the agent space in *that* Region, not your data Region.

- **`apply` wants to create things you didn't expect / costs worry you.** Read the plan before
  typing `yes`. You can deploy one tier at a time with `enable_tier1_consolidation`,
  `enable_tier2_visualisation`, `enable_tier3_ai_ops` (all default `true`).

---

## 7. Tearing it down (do this when you're finished)

Destroy in the reverse order you built, to avoid dependency errors:

```bash
# 1. The platform
cd terraform
tofu destroy -var-file=examples/test-harness.tfvars

# 2. The throwaway harness (greenfield only)
cd ../test-harness
tofu destroy
```

Each asks you to confirm with `yes`. This stops the ongoing OpenSearch and pipeline charges.
If Tier 3 created an AI agent in another Region, confirm it is gone in that Region's DevOps
Agent console.

---

## 8. Where to go next

- [README.md](README.md) — the full feature list, the brownfield (existing-firewall) path, and
  the configuration toggles.
- [terraform/README.md](terraform/README.md) — how the code is laid out, every input variable,
  and the post-apply steps in detail.
- [The AWS Prescriptive Guidance pattern](https://docs.aws.amazon.com/prescriptive-guidance/latest/patterns/build-a-network-observation-platform-for-aws-network-firewall.html) —
  the full pattern, including the reasoning and the delivery plan.
