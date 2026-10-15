# Test harness — prerequisites in a single account

The observation platform *observes* an existing network; it does not build the firewall
or the Transit Gateway. This harness stands up a minimal but real version of those
prerequisites in **one disposable test account**, so you can validate the whole platform
end to end without a full landing zone.

## What it creates

- A small inspection VPC (`/24`) with firewall and TGW-attachment subnets across 2 AZs.
- A Transit Gateway and a VPC attachment (so the platform can enable TGW Flow Logs).
- An AWS Network Firewall with a firewall policy and a stateful rule group of Suricata
  rules (SIDs `3000010`–`3000014`, plus `3000099` which is never matched so the
  rule-hygiene report has a zero-hit candidate to find).
- Network Firewall logging: **alert logs → CloudWatch Logs**, **flow logs → S3** — the
  two destinations the platform consumes.

It deliberately creates no Internet/NAT gateway and drives no real traffic — the demo
data injector fabricates the telemetry. The harness only needs the resources to *exist*
so the platform can attach logging and read the firewall.

## Cost warning

This harness creates chargeable resources: an **AWS Network Firewall** endpoint (hourly
+ per-GB) and a **Transit Gateway** (hourly + per-attachment). The platform then adds an
**OpenSearch** domain and an **OpenSearch Ingestion** pipeline (min 1 OCU, continuous).
Fine for a short-lived test; destroy everything when you are done (`tofu destroy` in the
platform directory first, then here).

## Usage

```bash
# 1. Stand up the prerequisites
cd test-harness
tofu init
tofu apply

# 2. Read the values to feed the platform
tofu output platform_tfvars_snippet

# 3. Deploy the platform against them
cd ../terraform
#    edit examples/test-harness.tfvars with the snippet values, then:
tofu init
tofu apply -var-file=examples/test-harness.tfvars

# 4. Complete the post-apply steps (FGAC role mapping, bootstrap invoke) —
#    see the APG "Post-deployment configuration" section.
```

## Teardown

Destroy in reverse order so the platform's log subscriptions and flow logs are removed
before the harness resources they point at:

```bash
cd terraform && tofu destroy -var-file=examples/test-harness.tfvars
cd ../test-harness && tofu destroy
```

The flow-log S3 bucket is created with `force_destroy = true` so it removes cleanly.
