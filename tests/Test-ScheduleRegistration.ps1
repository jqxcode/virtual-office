#Requires -Version 7.0
# Test-ScheduleRegistration.ps1 -- Tests for schedule parsing and task name generation
# Run: pwsh -File tests/Test-ScheduleRegistration.ps1
# NOTE: These are DRY-RUN only. No actual Task Scheduler entries are created.

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

function New-TestRoot {
    $root = Join-Path $env:TEMP "vo-test-$(Get-Random)"
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    foreach ($d in @("config/jobs", "state", "output/audit", "runner")) {
        New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null
    }
    return $root
}

function Remove-TestRoot {
    param([string]$Root)
    if ($Root -and (Test-Path $Root)) {
        Remove-Item -Path $Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Helper: parse a cron expression into its 5 parts
# Returns $null if invalid
function Parse-CronExpression {
    param([string]$Cron)
    $parts = $Cron.Trim() -split '\s+'
    if ($parts.Count -ne 5) { return $null }
    # Validate each part is either *, a number, or a cron pattern (*/N, N-M, etc.)
    $validPattern = '^(\*|(\*/\d+)|\d+(-\d+)?(,\d+(-\d+)?)*)$'
    foreach ($part in $parts) {
        if ($part -notmatch $validPattern) { return $null }
    }
    return @{
        Minute     = $parts[0]
        Hour       = $parts[1]
        DayOfMonth = $parts[2]
        Month      = $parts[3]
        DayOfWeek  = $parts[4]
    }
}

# Helper: generate the task name from agent + job
function Get-TaskName {
    param([string]$Agent, [string]$Job)
    return "VirtualOffice-$Agent-$Job"
}

# ========================================
# TC18: Parses schedules.json correctly
# ========================================
Write-Host "`nTC18: Parse schedules.json" -ForegroundColor Cyan
$root = New-TestRoot
try {
    # Write a schedules.json with multiple entries
    $schedules = @{
        schedules = @(
            @{ agent = "agent-a"; job = "job-1"; cron = "*/5 * * * *"; description = "Every 5 min" }
            @{ agent = "agent-b"; job = "job-2"; cron = "0 9 * * 1-5"; description = "Weekday 9am" }
            @{ agent = "agent-c"; job = "job-3"; cron = "30 14 1 * *"; description = "Monthly 2:30pm on the 1st" }
        )
    }
    $schedulesJson = $schedules | ConvertTo-Json -Depth 5
    $schedulesFile = Join-Path $root "config/schedules.json"
    Set-Content -Path $schedulesFile -Value $schedulesJson -Encoding UTF8

    # Parse it
    $parsed = Get-Content -Path $schedulesFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($parsed.ContainsKey("schedules")) "Root key 'schedules' exists"
    Assert-True ($parsed["schedules"].Count -eq 3) "Contains 3 schedule entries"

    $first = $parsed["schedules"][0]
    Assert-True ($first["agent"] -eq "agent-a") "First entry agent is agent-a"
    Assert-True ($first["job"] -eq "job-1") "First entry job is job-1"
    Assert-True ($first["cron"] -eq "*/5 * * * *") "First entry cron is correct"

    $second = $parsed["schedules"][1]
    Assert-True ($second["cron"] -eq "0 9 * * 1-5") "Second entry cron is weekday pattern"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC19: Generates correct task names
# ========================================
Write-Host "`nTC19: Task name generation" -ForegroundColor Cyan

$taskName1 = Get-TaskName -Agent "scrum-master" -Job "sprint-progress"
Assert-True ($taskName1 -eq "VirtualOffice-scrum-master-sprint-progress") "Task name: scrum-master/sprint-progress"

$taskName2 = Get-TaskName -Agent "my-agent" -Job "daily-report"
Assert-True ($taskName2 -eq "VirtualOffice-my-agent-daily-report") "Task name: my-agent/daily-report"

$taskName3 = Get-TaskName -Agent "a" -Job "b"
Assert-True ($taskName3 -eq "VirtualOffice-a-b") "Task name: minimal input"

# Verify the pattern prefix
Assert-True ($taskName1.StartsWith("VirtualOffice-")) "Task name starts with VirtualOffice- prefix"

# ========================================
# TC20: Invalid cron expression handled gracefully
# ========================================
Write-Host "`nTC20: Invalid cron expressions" -ForegroundColor Cyan

# Valid crons should parse
$valid1 = Parse-CronExpression "*/5 * * * *"
Assert-True ($null -ne $valid1) "Valid cron '*/5 * * * *' parses"
if ($valid1) {
    Assert-True ($valid1.Minute -eq "*/5") "Minute part is */5"
}

$valid2 = Parse-CronExpression "0 9 * * 1-5"
Assert-True ($null -ne $valid2) "Valid cron '0 9 * * 1-5' parses"

$valid3 = Parse-CronExpression "30 14 1 * *"
Assert-True ($null -ne $valid3) "Valid cron '30 14 1 * *' parses"

# Invalid crons should return $null
$invalid1 = Parse-CronExpression "not a cron"
Assert-True ($null -eq $invalid1) "Invalid cron 'not a cron' returns null"

$invalid2 = Parse-CronExpression "* * *"
Assert-True ($null -eq $invalid2) "Too few parts '* * *' returns null"

$invalid3 = Parse-CronExpression "* * * * * *"
Assert-True ($null -eq $invalid3) "Too many parts '* * * * * *' returns null"

$invalid4 = Parse-CronExpression ""
Assert-True ($null -eq $invalid4) "Empty string returns null"

$invalid5 = Parse-CronExpression "abc * * * *"
Assert-True ($null -eq $invalid5) "Non-numeric part 'abc' returns null"

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-ScheduleRegistration: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
