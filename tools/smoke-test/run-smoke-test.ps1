<#
.SYNOPSIS
  Read-only smoke test for the Network Observation Platform. Runs the CLI-verifiable
  checks from the test plan and prints PASS/FAIL per feature, then a summary.

.DESCRIPTION
  Safe to run against a live deployment: every check is read-only, and the only queries are
  bounded Athena count(*)/SELECTs run with -RunAthena. No resource is created, modified, or
  deleted. The DevOps Agent operator-app chat is exercised only with -RunAgent (needs
  python + boto3). Cognito login and the OpenSearch dashboards remain manual (console) and
  are printed as instructions at the end.

.EXAMPLE
  pwsh -File tools/smoke-test/run-smoke-test.ps1
  pwsh -File tools/smoke-test/run-smoke-test.ps1 -RunAthena          # + bounded Athena queries
  pwsh -File tools/smoke-test/run-smoke-test.ps1 -RunAthena -RunAgent # + full DevOps Agent chat
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
  Justification = 'Interactive CLI smoke test: coloured PASS/FAIL console output is intended and only runs in an interactive host.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RunAthena',
  Justification = 'Referenced inside the Athena Check scriptblocks, which PSReviewUnusedParameter does not traverse.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RunAgent',
  Justification = 'Referenced inside the DevOps Agent Check scriptblock, which PSReviewUnusedParameter does not traverse.')]
param(
  [string]$Region       = "eu-west-2",   # analysis plane (Athena/Glue/S3/OpenSearch/CloudWatch)
  [string]$AgentRegion  = "eu-west-1",   # AWS DevOps Agent agent space (Tier 3)
  [string]$NamePrefix   = "netobs",
  [switch]$RunAthena,     # also run bounded Athena queries (scans data, small cost)
  [switch]$RunAgent       # also run the full DevOps Agent chat check (needs python + boto3)
)

$ErrorActionPreference = "Continue"
$script:pass = 0; $script:fail = 0; $script:skip = 0
$results = @()

function Check {
  param([string]$Name, [scriptblock]$Test)
  try {
    $ok, $detail = & $Test
    if ("$ok" -eq "SKIP") { $script:skip++; $status = "SKIP" }
    elseif ($ok)          { $script:pass++; $status = "PASS" }
    else                  { $script:fail++; $status = "FAIL" }
  } catch {
    $script:fail++; $status = "FAIL"; $detail = $_.Exception.Message
  }
  $color = @{ PASS = "Green"; FAIL = "Red"; SKIP = "Yellow" }[$status]
  Write-Host ("[{0}] {1}" -f $status, $Name) -ForegroundColor $color
  if ($detail) { Write-Host ("       {0}" -f $detail) -ForegroundColor Gray }
  $script:results += [pscustomobject]@{ Check = $Name; Status = $status; Detail = $detail }
}

function AwsJson { param([string[]]$CliArgs) return (& aws @CliArgs --output json 2>$null | ConvertFrom-Json) }

function Utc { param([int]$HoursAgo = 0) (Get-Date).AddHours(-$HoursAgo).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

$acct     = (& aws sts get-caller-identity --query Account --output text 2>$null)
$bucket   = "$NamePrefix-analysis-$acct"
$common   = @("--region", $Region, "--no-cli-pager")

Write-Host "`n=== Network Observation Platform smoke test ($Region, agent $AgentRegion, prefix '$NamePrefix') ===`n" -ForegroundColor Cyan

# 0. Credentials
Check "Credentials valid" {
  $id = AwsJson (@("sts","get-caller-identity") + $common)
  if ($id.Account) { $true, "account $($id.Account)  $($id.Arn)" } else { $false, "no identity" }
}

# 1. Tier 1 - consolidation
Check "S3 analysis bucket has consolidated Parquet" {
  $o = & aws s3 ls "s3://$bucket/consolidated/" --recursive @common 2>$null
  if ($o) { $true, ("{0} objects" -f ($o | Measure-Object).Count) } else { $false, "no objects under consolidated/ (seed demo data?)" }
}
Check "Glue table network_events present" {
  $t = AwsJson (@("glue","get-table","--database-name","${NamePrefix}_netobs","--name","network_events") + $common)
  if ($t.Table.Name -eq "network_events") { $true, ("{0} columns" -f $t.Table.StorageDescriptor.Columns.Count) } else { $false, "table missing" }
}
Check "Firehose stream ACTIVE" {
  $f = AwsJson (@("firehose","describe-delivery-stream","--delivery-stream-name","$NamePrefix-consolidated") + $common)
  $s = $f.DeliveryStreamDescription.DeliveryStreamStatus
  ($s -eq "ACTIVE"), "status $s"
}
Check "Transform Lambda has no recent errors" {
  $e = AwsJson (@("cloudwatch","get-metric-statistics","--namespace","AWS/Lambda","--metric-name","Errors",
    "--dimensions","Name=FunctionName,Value=$NamePrefix-fh-transform","--start-time",(Utc 1),
    "--end-time",(Utc 0),"--period","3600","--statistics","Sum") + $common)
  $sum = ($e.Datapoints | Measure-Object -Property Sum -Sum).Sum
  ($null -eq $sum -or $sum -eq 0), ("errors last 1h: {0}" -f ([int]$sum))
}

# 2. Tier 2 - visualise (domain + the two quick-view dashboard metric widgets)
Check "OpenSearch domain healthy (not processing, TLS+node-to-node)" {
  $d = AwsJson (@("opensearch","describe-domain","--domain-name","$NamePrefix-obs") + $common)
  $ds = $d.DomainStatus
  ($ds.Processing -eq $false -and $ds.DomainEndpointOptions.EnforceHTTPS -and $ds.NodeToNodeEncryptionOptions.Enabled), `
    ("processing=$($ds.Processing) https=$($ds.DomainEndpointOptions.EnforceHTTPS) n2n=$($ds.NodeToNodeEncryptionOptions.Enabled)")
}
Check "OpenSearch AUDIT_LOGS enabled" {
  $c = AwsJson (@("opensearch","describe-domain-config","--domain-name","$NamePrefix-obs") + $common)
  $opts = $c.DomainConfig.LogPublishingOptions.Options
  ($opts.AUDIT_LOGS.Enabled -eq $true), ("audit=" + $opts.AUDIT_LOGS.Enabled)
}
Check "OpenSearch Ingestion pipeline ACTIVE" {
  $p = AwsJson (@("osis","get-pipeline","--pipeline-name","$NamePrefix-ingest") + $common)
  ($p.Pipeline.Status -eq "ACTIVE"), ("status " + $p.Pipeline.Status)
}
Check "CloudWatch quick-view dashboard exists" {
  $null = AwsJson (@("cloudwatch","get-dashboard","--dashboard-name","$NamePrefix-quick-view") + $common)
  $true, "dashboard present"
}
# Quick-view widget 1 data: Firehose delivery to S3 (DeliveryToS3.Records over the last hour).
Check "Dashboard data: Firehose delivering to S3 (records last 1h)" {
  $m = AwsJson (@("cloudwatch","get-metric-statistics","--namespace","AWS/Firehose","--metric-name","DeliveryToS3.Records",
    "--dimensions","Name=DeliveryStreamName,Value=$NamePrefix-consolidated","--start-time",(Utc 1),
    "--end-time",(Utc 0),"--period","3600","--statistics","Sum") + $common)
  $sum = [int](($m.Datapoints | Measure-Object -Property Sum -Sum).Sum)
  ($sum -gt 0), ("records delivered last 1h: {0}{1}" -f $sum, $(if ($sum -eq 0) { " (seed demo data / check ingest)" } else { "" }))
}
# Quick-view widget 2 data: OpenSearch has searchable documents (the dashboards query this).
Check "Dashboard data: OpenSearch has searchable documents" {
  $m = AwsJson (@("cloudwatch","get-metric-statistics","--namespace","AWS/ES","--metric-name","SearchableDocuments",
    "--dimensions","Name=DomainName,Value=$NamePrefix-obs","Name=ClientId,Value=$acct","--start-time",(Utc 3),
    "--end-time",(Utc 0),"--period","300","--statistics","Maximum") + $common)
  $max = [int](($m.Datapoints | Measure-Object -Property Maximum -Maximum).Maximum)
  ($max -gt 0), ("searchable documents: {0}{1}" -f $max, $(if ($max -eq 0) { " (ingestion pipeline / bootstrap not indexing yet)" } else { "" }))
}

# 3. Tier 3 - AI ops (baseline alarms + the DevOps Agent)
Check "Baseline alarms present and OK" {
  $a = AwsJson (@("cloudwatch","describe-alarms","--alarm-name-prefix","$NamePrefix-") + $common)
  $names = $a.MetricAlarms | ForEach-Object { $_.AlarmName }
  $bad = $a.MetricAlarms | Where-Object { $_.StateValue -eq "ALARM" } | ForEach-Object { $_.AlarmName }
  ($names.Count -ge 5 -and -not $bad), ("{0} alarms; in ALARM: {1}" -f $names.Count, ($bad -join "," ))
}
Check "DevOps Agent space present" {
  $sp = AwsJson (@("devops-agent","list-agent-spaces","--region",$AgentRegion,"--no-cli-pager"))
  if ($null -eq $sp) { return "SKIP", "devops-agent CLI unavailable (old AWS CLI) or no space; use -RunAgent for the boto3 check" }
  $spaces = @($sp.agentSpaces)
  if ($spaces.Count -ge 1) { $true, ("{0} space(s): {1}" -f $spaces.Count, (($spaces | ForEach-Object { $_.name }) -join ",")) }
  else { $false, "no agent space in $AgentRegion (enable_devops_agent?)" }
}
# The regression test for the agent's data path: a query in the managed-results agent
# workgroup must SUCCEED. If its results KMS is misconfigured this FAILS with the KMS error.
Check "DevOps Agent lake query path (agent workgroup)" {
  if (-not $RunAthena) { return "SKIP", "pass -RunAthena to enable" }
  $q = "SELECT count(*) AS n FROM network_events"
  $start = AwsJson (@("athena","start-query-execution","--query-string",$q,
    "--query-execution-context","Database=${NamePrefix}_netobs","--work-group","$NamePrefix-agent") + $common)
  $qid = $start.QueryExecutionId
  if (-not $qid) { return $false, "could not start query in $NamePrefix-agent workgroup" }
  $st = ""; $reason = ""
  for ($i=0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $ex = AwsJson (@("athena","get-query-execution","--query-execution-id",$qid) + $common)
    $st = $ex.QueryExecution.Status.State
    $reason = $ex.QueryExecution.Status.StateChangeReason
    if ($st -in @("SUCCEEDED","FAILED","CANCELLED")) { break }
  }
  ($st -eq "SUCCEEDED"), ("query $st" + $(if ($reason) { " - $reason" } else { "" }))
}
# Full end-to-end agent chat (optional; needs python + boto3). Confirms the agent answers
# from the lake with no permission block.
Check "DevOps Agent full investigation (chat)" {
  if (-not $RunAgent) { return "SKIP", "pass -RunAgent (needs python + boto3)" }
  $py = Get-Command python -ErrorAction SilentlyContinue
  if (-not $py) { return "SKIP", "python not on PATH" }
  $script = Join-Path $PSScriptRoot "check-devops-agent.py"
  & python $script --agent-region $AgentRegion --lake-region $Region --glue-database "${NamePrefix}_netobs" | Out-Host
  ($LASTEXITCODE -eq 0), ("check-devops-agent.py exit $LASTEXITCODE")
}

# 4. Security / auditing
Check "S3 public access fully blocked" {
  $b = AwsJson (@("s3api","get-public-access-block","--bucket",$bucket))
  $c = $b.PublicAccessBlockConfiguration
  ($c.BlockPublicAcls -and $c.BlockPublicPolicy -and $c.IgnorePublicAcls -and $c.RestrictPublicBuckets), "all four flags true"
}
Check "S3 server access logging enabled" {
  $l = AwsJson (@("s3api","get-bucket-logging","--bucket",$bucket))
  ($l.LoggingEnabled.TargetBucket -like "*access-logs*"), ("target " + $l.LoggingEnabled.TargetBucket)
}
Check "Analysis bucket CMK-encrypted" {
  $e = AwsJson (@("s3api","get-bucket-encryption","--bucket",$bucket))
  $alg = $e.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm
  ($alg -eq "aws:kms"), ("sse " + $alg)
}
# Optional: Athena count query over the consolidated store (standard workgroup).
Check "Athena count query (network_events)" {
  if (-not $RunAthena) { return "SKIP", "pass -RunAthena to enable" }
  $q = "SELECT count(*) AS n FROM network_events"
  $start = AwsJson (@("athena","start-query-execution","--query-string",$q,
    "--query-execution-context","Database=${NamePrefix}_netobs","--work-group","$NamePrefix-netobs") + $common)
  $qid = $start.QueryExecutionId
  $st = ""
  for ($i=0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $ex = AwsJson (@("athena","get-query-execution","--query-execution-id",$qid) + $common)
    $st = $ex.QueryExecution.Status.State
    if ($st -in @("SUCCEEDED","FAILED","CANCELLED")) { break }
  }
  if ($st -ne "SUCCEEDED") { return $false, "query $st" }
  $res = AwsJson (@("athena","get-query-results","--query-execution-id",$qid) + $common)
  $n = $res.ResultSet.Rows[1].Data[0].VarCharValue
  ([int]$n -ge 0), ("count = $n")
}

# Summary
Write-Host ""
Write-Host ("=== {0} PASS  {1} FAIL  {2} SKIP ===" -f $script:pass, $script:fail, $script:skip) `
  -ForegroundColor ($(if ($script:fail) { "Red" } else { "Green" }))

# Manual checks that cannot be automated (console / browser).
$dash = AwsJson (@("opensearch","describe-domain","--domain-name","$NamePrefix-obs") + $common)
$osUrl = $dash.DomainStatus.Endpoint   # public (Cognito/FGAC) domain exposes a single endpoint
if (-not $osUrl -and $dash.DomainStatus.Endpoints) { $osUrl = $dash.DomainStatus.Endpoints.vpc }
$dashUrl = if ($osUrl) { "https://$osUrl/_dashboards/" } else { "(run: terraform output opensearch_dashboards_url)" }

Write-Host "`n--- Manual checks (console / browser; cannot be automated) ---" -ForegroundColor Cyan
Write-Host "OpenSearch Dashboards (consolidated view):" -ForegroundColor White
Write-Host "  1. Open: " -ForegroundColor White -NoNewline
Write-Host $dashUrl -ForegroundColor Yellow
Write-Host "  2. Sign in via Cognito (temp password emailed to dashboards_notification_email on apply)." -ForegroundColor White
Write-Host "  3. Open the pre-loaded 'Network Observation' dashboard; set the time range to Last 1 hour." -ForegroundColor White
Write-Host "  4. Confirm panels populate: top talkers, allow-vs-deny, blocked-domain leaderboard," -ForegroundColor White
Write-Host "     per-rule (SID) hit trends, geo map. (Discover -> index pattern network-events-* to pivot.)" -ForegroundColor White
Write-Host ""
Write-Host "CloudWatch quick-view dashboard:" -ForegroundColor White
Write-Host "  CloudWatch -> Dashboards -> $NamePrefix-quick-view  (set range to Last 1h)." -ForegroundColor White
Write-Host ""
Write-Host "DevOps Agent operator app:" -ForegroundColor White
Write-Host "  $AgentRegion -> AWS DevOps Agent -> your agent space -> Operator app; ask e.g." -ForegroundColor White
Write-Host "  'top blocked destinations in the last day?'  (or re-run this script with -RunAgent)." -ForegroundColor White

exit $script:fail
