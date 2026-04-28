#Requires -Version 7.0
# Test-ScheduleConsistency.ps1 -- Schedule consistency validation tests
# Run: pwsh -File tests/Test-ScheduleConsistency.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Test harness ---
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

# Helper: validate a cron expression (5 fields, each valid)
function Test-ValidCron {
    param([string]$Cron)
    $parts = $Cron.Trim() -split '\s+'
    if ($parts.Count -ne 5) { return $false }
    $validPattern = '^(\*|L|(\*/\d+)|\d+(-\d+)?(,\d+(-\d+)?)*)$'
    foreach ($part in $parts) {
        if ($part -notmatch $validPattern) { return $false }
    }
    return $true
}

# --- Locate project root ---
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $ProjectRoot "config/agents.json"))) {
    $ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

$ConfigDir = Join-Path $ProjectRoot "config"
$SchedulesFile = Join-Path $ConfigDir "schedules.json"
$JobsDir = Join-Path $ConfigDir "jobs"

# Load configs
$schedulesRaw = Get-Content -Path $SchedulesFile -Raw | ConvertFrom-Json -AsHashtable
$schedules = if ($schedulesRaw.ContainsKey("schedules")) { $schedulesRaw["schedules"] } else { $schedulesRaw }

# Load all job files
$jobFiles = Get-ChildItem -Path $JobsDir -Filter "*.json" -File
$allJobs = @{}
foreach ($jf in $jobFiles) {
    $agentName = [System.IO.Path]::GetFileNameWithoutExtension($jf.Name)
    $jobRaw = Get-Content -Path $jf.FullName -Raw | ConvertFrom-Json -AsHashtable
    $allJobs[$agentName] = if ($jobRaw.ContainsKey("jobs")) { $jobRaw["jobs"] } else { $jobRaw }
}

# ========================================
# TC1: Every scheduled job has a valid cron expression
# ========================================
Write-Host "`nTC1: Every scheduled job has a valid cron expression" -ForegroundColor Cyan

foreach ($entry in $schedules) {
    $agent = $entry["agent"]
    $job = $entry["job"]
    $cron = $entry["cron"]
    $isValid = Test-ValidCron -Cron $cron
    Assert-True $isValid "Schedule '$agent/$job' has valid cron expression: '$cron'"
}

# ========================================
# TC2: open-pr-maintenance exists, resolve-merge-conflicts/review-pr-comments do NOT
# ========================================
Write-Host "`nTC2: open-pr-maintenance exists and resolve-merge-conflicts/review-pr-comments do NOT exist in schedules" -ForegroundColor Cyan

$scheduledJobs = $schedules | ForEach-Object { "$($_["agent"])/$($_["job"])" }

$hasOpenPrMaintenance = $scheduledJobs -contains "bug-killer/open-pr-maintenance"
Assert-True $hasOpenPrMaintenance "bug-killer/open-pr-maintenance exists in schedules"

$hasResolveMergeConflicts = $scheduledJobs -contains "bug-killer/resolve-merge-conflicts"
Assert-True (-not $hasResolveMergeConflicts) "bug-killer/resolve-merge-conflicts does NOT exist in schedules"

$hasReviewPrComments = $scheduledJobs -contains "bug-killer/review-pr-comments"
Assert-True (-not $hasReviewPrComments) "bug-killer/review-pr-comments does NOT exist in schedules"

# ========================================
# TC3: daily-summary is scheduled at 1:30am
# ========================================
Write-Host "`nTC3: daily-summary is scheduled at 1:30am (cron '30 1 * * *')" -ForegroundColor Cyan

$dailySummaryEntries = $schedules | Where-Object { $_["agent"] -eq "bug-killer" -and $_["job"] -eq "daily-summary" }
$dailySummaryCount = @($dailySummaryEntries).Count
Assert-True ($dailySummaryCount -ge 1) "bug-killer/daily-summary has at least one schedule entry"

if ($dailySummaryCount -ge 1) {
    $cron = @($dailySummaryEntries)[0]["cron"]
    Assert-True ($cron -eq "30 1 * * *") "bug-killer/daily-summary cron is '30 1 * * *' (got: '$cron')"
}

# ========================================
# TC4: hang-scout detect-hang is scheduled hourly at :45
# ========================================
Write-Host "`nTC4: hang-scout detect-hang is scheduled hourly at :45" -ForegroundColor Cyan

$detectHangEntries = $schedules | Where-Object { $_["agent"] -eq "hang-scout" -and $_["job"] -eq "detect-hang" }
$detectHangCount = @($detectHangEntries).Count
Assert-True ($detectHangCount -ge 1) "hang-scout/detect-hang has at least one schedule entry"

if ($detectHangCount -ge 1) {
    $cron = @($detectHangEntries)[0]["cron"]
    Assert-True ($cron -eq "45 * * * *") "hang-scout/detect-hang cron is '45 * * * *' (got: '$cron')"
}

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-ScheduleConsistency: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
