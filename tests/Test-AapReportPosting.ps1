#Requires -Version 7.0
# Test-AapReportPosting.ps1 -- AAP poster routing and template validation

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:Passed++
        Write-Host "  [PASS] $Message" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "  [FAIL] $Message" -ForegroundColor Red
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$jobsPath = Join-Path $projectRoot "config" "jobs" "mPoster.json"
$templatePath = Join-Path $projectRoot "templates" "mPoster-aap-report-posting.html"
$jobs = Get-Content -Path $jobsPath -Raw | ConvertFrom-Json -AsHashtable
$prompt = [string]$jobs["jobs"]["AAP-report-posting"]["prompt"]

Assert-True (Test-Path $templatePath) "AAP fixed template exists"
Assert-True ($prompt.Contains('${REPO_PERSONAL}/virtual-office/templates/mPoster-aap-report-posting.html')) "Job references the fixed template"
Assert-True ($prompt.Contains("19:MY8MVBkbsY_A7wbQRh1BHedFQbOpwcRlGTOiIReg9NI1@thread.tacv2")) "Job targets ADO-Autopilot"
Assert-True (-not $prompt.Contains("19:xSmqZj8J0oCRD2uutKlu6GqMVy33JhGNjuPdSlE2GJY1@thread.tacv2")) "Job does not target Test Autopilot"

if (Test-Path $templatePath) {
    $template = Get-Content -Path $templatePath -Raw
    foreach ($placeholder in @("{{SHARE_URL}}", "{{TOTAL}}", "{{UPDATED}}", "{{NO_CHANGE}}", "{{FEATURE_ROWS}}", "{{VO_SUBTITLE}}")) {
        Assert-True ($template.Contains($placeholder)) "Template contains $placeholder"
    }
    Assert-True ($template.Contains('<at id="0">Josh Xu</at>')) "Template mentions Josh Xu"
    Assert-True ($template.Contains('<at id="1">Varun Venkatesh</at>')) "Template mentions Varun Venkatesh"
    Assert-True ($template.Contains('<at id="2">Naveen Shrivastava</at>')) "Template mentions Naveen Shrivastava"
}

Write-Host "`nTest-AapReportPosting: $script:Passed passed, $script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
