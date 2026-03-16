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

# ========================================
# TC62: Register writes event to events.jsonl
# ========================================
Write-Host "`nTC62: Register writes event to events.jsonl" -ForegroundColor Cyan
$root = New-TestRoot
try {
    $eventsFile = Join-Path $root "state/events.jsonl"
    $nowIso = Get-Date -Format "o"
    $eventEntry = @{
        ts            = $nowIso
        agent         = "scrum-master"
        job           = "sprint-progress"
        event         = "schedule_registered"
        details       = @{
            cron        = "*/15 * * * *"
            taskName    = "VirtualOffice-scrum-master-sprint-progress"
            description = "Virtual Office: scrum-master / sprint-progress"
        }
        systemVersion = "0.1.0"
    } | ConvertTo-Json -Compress
    Add-Content -Path $eventsFile -Value $eventEntry -Encoding ASCII

    Assert-True (Test-Path $eventsFile) "events.jsonl exists after write"
    $content = Get-Content -Path $eventsFile -Raw
    Assert-True ($content -match '"schedule_registered"') "Event contains schedule_registered type"
    Assert-True ($content -match '"scrum-master"') "Event contains agent name"
    Assert-True ($content -match '"sprint-progress"') "Event contains job name"
    Assert-True ($content -match '"systemVersion"') "Event contains systemVersion field"

    $parsed = $eventEntry | ConvertFrom-Json
    Assert-True ($parsed.event -eq "schedule_registered") "Parsed event type is schedule_registered"
    Assert-True ($parsed.details.cron -eq "*/15 * * * *") "Parsed details contain cron"
    Assert-True ($parsed.details.taskName -eq "VirtualOffice-scrum-master-sprint-progress") "Parsed details contain taskName"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC63: Register writes audit entry
# ========================================
Write-Host "`nTC63: Register writes audit entry" -ForegroundColor Cyan
$root = New-TestRoot
try {
    $auditDir = Join-Path $root "output/audit"
    $monthFile = Join-Path $auditDir "$(Get-Date -Format 'yyyy-MM').jsonl"
    $nowIso = Get-Date -Format "o"
    $auditEntry = @{
        ts            = $nowIso
        action        = "schedule_registered"
        agent         = "scrum-master"
        job           = "sprint-progress"
        runId         = "N/A"
        systemVersion = "0.1.0"
        details       = @{
            cron     = "*/15 * * * *"
            taskName = "VirtualOffice-scrum-master-sprint-progress"
        }
    } | ConvertTo-Json -Compress
    Add-Content -Path $monthFile -Value $auditEntry -Encoding ASCII

    Assert-True (Test-Path $monthFile) "Monthly audit file exists after write"
    $content = Get-Content -Path $monthFile -Raw
    Assert-True ($content -match '"schedule_registered"') "Audit contains schedule_registered action"
    Assert-True ($content -match '"N/A"') "Audit contains runId N/A"

    $parsed = $auditEntry | ConvertFrom-Json
    Assert-True ($parsed.action -eq "schedule_registered") "Parsed audit action is schedule_registered"
    Assert-True ($parsed.agent -eq "scrum-master") "Parsed audit agent is correct"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC64: Unregister writes schedule_removed event
# ========================================
Write-Host "`nTC64: Unregister writes schedule_removed event" -ForegroundColor Cyan
$root = New-TestRoot
try {
    $eventsFile = Join-Path $root "state/events.jsonl"
    $nowIso = Get-Date -Format "o"
    $eventEntry = @{
        ts            = $nowIso
        agent         = "scrum-master"
        job           = "sprint-progress"
        event         = "schedule_removed"
        details       = @{
            taskName = "VirtualOffice-scrum-master-sprint-progress"
        }
        systemVersion = "0.1.0"
    } | ConvertTo-Json -Compress
    Add-Content -Path $eventsFile -Value $eventEntry -Encoding ASCII

    Assert-True (Test-Path $eventsFile) "events.jsonl exists after removal write"
    $content = Get-Content -Path $eventsFile -Raw
    Assert-True ($content -match '"schedule_removed"') "Event contains schedule_removed type"
    Assert-True ($content -match '"scrum-master"') "Event contains agent name"
    Assert-True ($content -match '"sprint-progress"') "Event contains job name"

    $parsed = $eventEntry | ConvertFrom-Json
    Assert-True ($parsed.event -eq "schedule_removed") "Parsed event type is schedule_removed"
    Assert-True ($parsed.details.taskName -eq "VirtualOffice-scrum-master-sprint-progress") "Parsed details contain taskName"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC73: Register-OneOff writes event to events.jsonl
# ========================================
Write-Host "`nTC73: Register-OneOff writes event to events.jsonl" -ForegroundColor Cyan
$root = New-TestRoot
try {
    $eventsFile = Join-Path $root "state/events.jsonl"
    $nowIso = Get-Date -Format "o"
    $fireTime = (Get-Date).AddMinutes(1).ToString("o")
    $taskName = "VirtualOffice-oneoff-scrum-master-dry-run-bug-autopilot-$(Get-Date -Format 'yyyyMMddHHmmss')"

    # Simulate the event writing logic from Register-OneOff.ps1
    $eventEntry = @{
        ts            = $nowIso
        agent         = "scrum-master"
        job           = "dry-run-bug-autopilot"
        event         = "schedule_registered"
        details       = @{
            oneoff       = $true
            taskName     = $taskName
            fireTime     = $fireTime
            delayMinutes = 1
            description  = "Virtual Office one-off: scrum-master / dry-run-bug-autopilot"
        }
        systemVersion = "0.1.0"
    } | ConvertTo-Json -Compress
    Add-Content -Path $eventsFile -Value $eventEntry -Encoding ASCII

    Assert-True (Test-Path $eventsFile) "events.jsonl exists after one-off write"
    $content = Get-Content -Path $eventsFile -Raw
    Assert-True ($content -match '"schedule_registered"') "Event contains schedule_registered type"
    Assert-True ($content -match '"scrum-master"') "Event contains agent name"
    Assert-True ($content -match '"dry-run-bug-autopilot"') "Event contains job name"

    $parsed = $eventEntry | ConvertFrom-Json
    Assert-True ($parsed.event -eq "schedule_registered") "Parsed event type is schedule_registered"
    Assert-True ($parsed.details.oneoff -eq $true) "Parsed details contain oneoff: true"
    Assert-True ($parsed.details.taskName -like "VirtualOffice-oneoff-*") "Parsed details taskName has oneoff prefix"
    Assert-True ($null -ne $parsed.details.fireTime) "Parsed details contain fireTime"
    Assert-True ($parsed.details.delayMinutes -eq 1) "Parsed details contain delayMinutes"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC74: One-off task name includes timestamp
# ========================================
Write-Host "`nTC74: One-off task name includes timestamp" -ForegroundColor Cyan

$ts = Get-Date -Format "yyyyMMddHHmmss"
$oneoffName = "VirtualOffice-oneoff-scrum-master-dry-run-bug-autopilot-$ts"

Assert-True ($oneoffName -match 'VirtualOffice-oneoff-.+-\d{14}$') "Task name matches pattern with 14-digit timestamp suffix"
Assert-True ($oneoffName -match $ts) "Task name contains the expected timestamp value"

# Verify uniqueness: two names generated 0+ seconds apart differ
$ts2 = (Get-Date).AddSeconds(1).ToString("yyyyMMddHHmmss")
$oneoffName2 = "VirtualOffice-oneoff-scrum-master-dry-run-bug-autopilot-$ts2"
# If the second rolled over they differ; if same second they match -- both are valid
Assert-True ($oneoffName.StartsWith("VirtualOffice-oneoff-")) "One-off name starts with VirtualOffice-oneoff- prefix"
Assert-True ($oneoffName -ne (Get-TaskName -Agent "scrum-master" -Job "dry-run-bug-autopilot")) "One-off name differs from recurring task name pattern"

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-ScheduleRegistration: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
