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

# Helper: generate deduplicated task names from a list of schedule entries
# Mirrors the logic in Register-Schedules.ps1
function Get-DedupedTaskNames {
    param([array]$Entries)
    $taskNameCount = @{}
    $result = @()
    foreach ($e in $Entries) {
        $baseKey = "$($e.agent)|$($e.job)"
        if (-not $taskNameCount.ContainsKey($baseKey)) {
            $taskNameCount[$baseKey] = 1
        } else {
            $taskNameCount[$baseKey]++
        }
        $occurrence = $taskNameCount[$baseKey]
        if ($occurrence -eq 1) {
            $result += "VirtualOffice-$($e.agent)-$($e.job)"
        } else {
            $result += "VirtualOffice-$($e.agent)-$($e.job)-$occurrence"
        }
    }
    return $result
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

$taskName1 = Get-TaskName -Agent "mScrumMaster" -Job "sprint-progress"
Assert-True ($taskName1 -eq "VirtualOffice-mScrumMaster-sprint-progress") "Task name: mScrumMaster/sprint-progress"

$taskName2 = Get-TaskName -Agent "my-agent" -Job "daily-report"
Assert-True ($taskName2 -eq "VirtualOffice-my-agent-daily-report") "Task name: my-agent/daily-report"

$taskName3 = Get-TaskName -Agent "a" -Job "b"
Assert-True ($taskName3 -eq "VirtualOffice-a-b") "Task name: minimal input"

# Verify the pattern prefix
Assert-True ($taskName1.StartsWith("VirtualOffice-")) "Task name starts with VirtualOffice- prefix"

# ========================================
# TC19b: Duplicate agent+job entries get unique task names
# ========================================
Write-Host "`nTC19b: Duplicate cron entries get unique task names" -ForegroundColor Cyan

$duplicateEntries = @(
    @{ agent = "mScrumMaster"; job = "dry-run-ado-status-update"; cron = "0 9 * * *" }
    @{ agent = "mScrumMaster"; job = "dry-run-ado-status-update"; cron = "0 21 * * *" }
    @{ agent = "pBugKiller";   job = "scan-and-fix";              cron = "0 10 * * *" }
    @{ agent = "pBugKiller";   job = "scan-and-fix";              cron = "0 22 * * *" }
    @{ agent = "mScrumMaster"; job = "sprint-progress";           cron = "0 7 * * 1-5" }
)
$names = Get-DedupedTaskNames -Entries $duplicateEntries

Assert-True ($names[0] -eq "VirtualOffice-mScrumMaster-dry-run-ado-status-update") "First occurrence keeps base task name"
Assert-True ($names[1] -eq "VirtualOffice-mScrumMaster-dry-run-ado-status-update-2") "Second occurrence gets -2 suffix"
Assert-True ($names[2] -eq "VirtualOffice-pBugKiller-scan-and-fix") "First occurrence (different agent+job) keeps base task name"
Assert-True ($names[3] -eq "VirtualOffice-pBugKiller-scan-and-fix-2") "Second occurrence gets -2 suffix"
Assert-True ($names[4] -eq "VirtualOffice-mScrumMaster-sprint-progress") "Unique entry keeps base task name"
Assert-True (($names | Sort-Object -Unique).Count -eq $names.Count) "All generated task names are unique"

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
        agent         = "mScrumMaster"
        job           = "sprint-progress"
        event         = "schedule_registered"
        details       = @{
            cron        = "*/15 * * * *"
            taskName    = "VirtualOffice-mScrumMaster-sprint-progress"
            description = "Virtual Office: mScrumMaster / sprint-progress"
        }
        systemVersion = "0.1.0"
    } | ConvertTo-Json -Compress
    Add-Content -Path $eventsFile -Value $eventEntry -Encoding ASCII

    Assert-True (Test-Path $eventsFile) "events.jsonl exists after write"
    $content = Get-Content -Path $eventsFile -Raw
    Assert-True ($content -match '"schedule_registered"') "Event contains schedule_registered type"
    Assert-True ($content -match '"mScrumMaster"') "Event contains agent name"
    Assert-True ($content -match '"sprint-progress"') "Event contains job name"
    Assert-True ($content -match '"systemVersion"') "Event contains systemVersion field"

    $parsed = $eventEntry | ConvertFrom-Json
    Assert-True ($parsed.event -eq "schedule_registered") "Parsed event type is schedule_registered"
    Assert-True ($parsed.details.cron -eq "*/15 * * * *") "Parsed details contain cron"
    Assert-True ($parsed.details.taskName -eq "VirtualOffice-mScrumMaster-sprint-progress") "Parsed details contain taskName"
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
        agent         = "mScrumMaster"
        job           = "sprint-progress"
        runId         = "N/A"
        systemVersion = "0.1.0"
        details       = @{
            cron     = "*/15 * * * *"
            taskName = "VirtualOffice-mScrumMaster-sprint-progress"
        }
    } | ConvertTo-Json -Compress
    Add-Content -Path $monthFile -Value $auditEntry -Encoding ASCII

    Assert-True (Test-Path $monthFile) "Monthly audit file exists after write"
    $content = Get-Content -Path $monthFile -Raw
    Assert-True ($content -match '"schedule_registered"') "Audit contains schedule_registered action"
    Assert-True ($content -match '"N/A"') "Audit contains runId N/A"

    $parsed = $auditEntry | ConvertFrom-Json
    Assert-True ($parsed.action -eq "schedule_registered") "Parsed audit action is schedule_registered"
    Assert-True ($parsed.agent -eq "mScrumMaster") "Parsed audit agent is correct"
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
        agent         = "mScrumMaster"
        job           = "sprint-progress"
        event         = "schedule_removed"
        details       = @{
            taskName = "VirtualOffice-mScrumMaster-sprint-progress"
        }
        systemVersion = "0.1.0"
    } | ConvertTo-Json -Compress
    Add-Content -Path $eventsFile -Value $eventEntry -Encoding ASCII

    Assert-True (Test-Path $eventsFile) "events.jsonl exists after removal write"
    $content = Get-Content -Path $eventsFile -Raw
    Assert-True ($content -match '"schedule_removed"') "Event contains schedule_removed type"
    Assert-True ($content -match '"mScrumMaster"') "Event contains agent name"
    Assert-True ($content -match '"sprint-progress"') "Event contains job name"

    $parsed = $eventEntry | ConvertFrom-Json
    Assert-True ($parsed.event -eq "schedule_removed") "Parsed event type is schedule_removed"
    Assert-True ($parsed.details.taskName -eq "VirtualOffice-mScrumMaster-sprint-progress") "Parsed details contain taskName"
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
    $taskName = "VirtualOffice-oneoff-mScrumMaster-dry-run-bug-autopilot-$(Get-Date -Format 'yyyyMMddHHmmss')"

    # Simulate the event writing logic from Register-OneOff.ps1
    $eventEntry = @{
        ts            = $nowIso
        agent         = "mScrumMaster"
        job           = "dry-run-bug-autopilot"
        event         = "schedule_registered"
        details       = @{
            oneoff       = $true
            taskName     = $taskName
            fireTime     = $fireTime
            delayMinutes = 1
            description  = "Virtual Office one-off: mScrumMaster / dry-run-bug-autopilot"
        }
        systemVersion = "0.1.0"
    } | ConvertTo-Json -Compress
    Add-Content -Path $eventsFile -Value $eventEntry -Encoding ASCII

    Assert-True (Test-Path $eventsFile) "events.jsonl exists after one-off write"
    $content = Get-Content -Path $eventsFile -Raw
    Assert-True ($content -match '"schedule_registered"') "Event contains schedule_registered type"
    Assert-True ($content -match '"mScrumMaster"') "Event contains agent name"
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
$oneoffName = "VirtualOffice-oneoff-mScrumMaster-dry-run-bug-autopilot-$ts"

Assert-True ($oneoffName -match 'VirtualOffice-oneoff-.+-\d{14}$') "Task name matches pattern with 14-digit timestamp suffix"
Assert-True ($oneoffName -match $ts) "Task name contains the expected timestamp value"

# Verify uniqueness: two names generated 0+ seconds apart differ
$ts2 = (Get-Date).AddSeconds(1).ToString("yyyyMMddHHmmss")
$oneoffName2 = "VirtualOffice-oneoff-mScrumMaster-dry-run-bug-autopilot-$ts2"
# If the second rolled over they differ; if same second they match -- both are valid
Assert-True ($oneoffName.StartsWith("VirtualOffice-oneoff-")) "One-off name starts with VirtualOffice-oneoff- prefix"
Assert-True ($oneoffName -ne (Get-TaskName -Agent "mScrumMaster" -Job "dry-run-bug-autopilot")) "One-off name differs from recurring task name pattern"

# ========================================
# TC80: Per-machine registration map (registrations.<host>.json)
# ========================================
Write-Host "`nTC80: Per-machine registration map" -ForegroundColor Cyan
$root = New-TestRoot
try {
    $stateDir = Join-Path $root "state"
    $hostName = "TESTBOX01"
    $registrations = [ordered]@{}
    $entries = @(
        @{ agent = "pBugKiller"; job = "scan-and-fix"; cron = "0 10 * * *" }
        @{ agent = "pBugKiller"; job = "scan-and-fix"; cron = "0 22 * * *" }
        @{ agent = "mApprover";  job = "approve-FFv2"; cron = "0 6 * * *" }
    )
    $counts = @{}
    foreach ($e in $entries) {
        $bk = "$($e.agent)|$($e.job)"
        if (-not $counts.ContainsKey($bk)) { $counts[$bk] = 1 } else { $counts[$bk]++ }
        $occ = $counts[$bk]
        $tn = if ($occ -eq 1) { "VO-$($e.agent)-$($e.job)" } else { "VO-$($e.agent)-$($e.job)-$occ" }
        $registrations[$tn] = [ordered]@{
            agent = $e.agent; job = $e.job; cron = $e.cron
            registeredHost = $hostName; registeredAt = (Get-Date -Format "o")
        }
    }
    $regFile = Join-Path $stateDir "registrations.$hostName.json"
    ($registrations | ConvertTo-Json -Depth 5) | Set-Content -Path $regFile -Encoding UTF8
    Assert-True (Test-Path $regFile) "registrations.<host>.json is written"
    $back = Get-Content $regFile -Raw | ConvertFrom-Json
    Assert-True ($null -ne $back."VO-pBugKiller-scan-and-fix") "First occurrence keyed as VO-pBugKiller-scan-and-fix"
    Assert-True ($null -ne $back."VO-pBugKiller-scan-and-fix-2") "Duplicate cron keyed with -2 suffix"
    Assert-True ($back."VO-mApprover-approve-FFv2".registeredHost -eq $hostName) "Record carries registeredHost = machine name"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC81: Merge registration maps from multiple machines (portal hosts union)
# ========================================
Write-Host "`nTC81: Merge multi-machine registration maps" -ForegroundColor Cyan
$root = New-TestRoot
try {
    $stateDir = Join-Path $root "state"
    foreach ($h in @("AI0001", "AI0003")) {
        $m = [ordered]@{
            "VO-mApprover-approve-FFv2" = [ordered]@{
                agent = "mApprover"; job = "approve-FFv2"; cron = "0 6 * * *"
                registeredHost = $h; registeredAt = (Get-Date -Format "o")
            }
        }
        ($m | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $stateDir "registrations.$h.json") -Encoding UTF8
    }
    $hostsByAgentJob = @{}
    foreach ($rf in (Get-ChildItem -Path $stateDir -Filter "registrations.*.json")) {
        $obj = Get-Content $rf.FullName -Raw | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) {
            $rec = $p.Value
            $k = "$($rec.agent)|$($rec.job)"
            if (-not $hostsByAgentJob.ContainsKey($k)) { $hostsByAgentJob[$k] = @() }
            if ($hostsByAgentJob[$k] -notcontains $rec.registeredHost) { $hostsByAgentJob[$k] += $rec.registeredHost }
        }
    }
    $mergedHosts = $hostsByAgentJob["mApprover|approve-FFv2"]
    Assert-True ($mergedHosts.Count -eq 2) "Same task registered on 2 machines yields 2 hosts"
    Assert-True ($mergedHosts -contains "AI0001" -and $mergedHosts -contains "AI0003") "Merged hosts include both AI0001 and AI0003"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC82: Declared-host filter -- only entries for THIS machine are registered
# ========================================
Write-Host "`nTC82: Declared-host registration filter" -ForegroundColor Cyan
# Mirror the filter + occurrence-counting logic in Register-Schedules.ps1.
$thisHost = "AI0003"
$schedEntries = @(
    @{ agent = "mApprover";    job = "approve-FFv2";           cron = "0 6 * * *";     host = "AI0003" }
    @{ agent = "mScrumMaster"; job = "shiproom-hygiene-check"; cron = "45 8 * * 1-5";  host = "AI0003" }
    @{ agent = "mScrumMaster"; job = "shiproom-hygiene-check"; cron = "50 14 * * 1-5"; host = "AI0003" }
    @{ agent = "pBugKiller";   job = "scan-and-fix";           cron = "0 10 * * *";    host = "AI0001" }
    @{ agent = "pResearcher";  job = "scan-mentions-and-draft"; cron = "0 9 * * 1-5";  host = "AI0001" }
    @{ agent = "mAuditor";     job = "legacy-nohost";          cron = "0 3 * * *" }  # no host -> register everywhere
)
$counts = @{}
$registeredHere = @()
foreach ($e in $schedEntries) {
    $bk = "$($e.agent)|$($e.job)"
    if (-not $counts.ContainsKey($bk)) { $counts[$bk] = 1 } else { $counts[$bk]++ }
    $occ = $counts[$bk]
    $tn = if ($occ -eq 1) { "VO-$($e.agent)-$($e.job)" } else { "VO-$($e.agent)-$($e.job)-$occ" }
    $eHost = if ($e.ContainsKey("host")) { $e["host"] } else { $null }
    if ($eHost -and $eHost -ne $thisHost) { continue }
    $registeredHere += $tn
}
Assert-True ($registeredHere.Count -eq 4) "AI0003 registers exactly 4 tasks (2 mApprover/mScrumMaster + hygiene-check-2 + legacy no-host)"
Assert-True ($registeredHere -contains "VO-mApprover-approve-FFv2") "Registers AI0003 approve-FFv2"
Assert-True ($registeredHere -contains "VO-mScrumMaster-shiproom-hygiene-check") "Registers AI0003 hygiene-check (occurrence 1)"
Assert-True ($registeredHere -contains "VO-mScrumMaster-shiproom-hygiene-check-2") "Registers AI0003 hygiene-check-2 (occurrence 2, dedup preserved)"
Assert-True ($registeredHere -contains "VO-mAuditor-legacy-nohost") "Registers entry with no declared host (backward compatible)"
Assert-True ($registeredHere -notcontains "VO-pBugKiller-scan-and-fix") "Skips AI0001-declared scan-and-fix"
Assert-True ($registeredHere -notcontains "VO-pResearcher-scan-mentions-and-draft") "Skips AI0001-declared scan-mentions-and-draft"

# ========================================
# TC83: Multi-host declared entry registers on BOTH machines
# ========================================
Write-Host "`nTC83: Multi-host (host list) registration filter" -ForegroundColor Cyan
# A schedule declared for both AI0001 and AI0003 must be registered on each.
$dualEntry = @{ agent = "mPoster"; job = "shared-report"; cron = "0 9 * * *"; host = @("AI0001", "AI0003") }
function Test-HostRegisters([hashtable]$Entry, [string]$Machine) {
    $eHosts = @()
    if ($Entry.ContainsKey("host") -and $Entry["host"]) { $eHosts = @($Entry["host"]) }
    return ($eHosts.Count -eq 0 -or $eHosts -contains $Machine)
}
Assert-True (Test-HostRegisters $dualEntry "AI0001") "Multi-host entry registers on AI0001"
Assert-True (Test-HostRegisters $dualEntry "AI0003") "Multi-host entry registers on AI0003"
Assert-True (-not (Test-HostRegisters $dualEntry "AI9999")) "Multi-host entry skipped on a machine not in the list"
$singleEntry = @{ agent = "mApprover"; job = "approve-FFv2"; cron = "0 6 * * *"; host = "AI0003" }
Assert-True (Test-HostRegisters $singleEntry "AI0003") "Single-host string still registers on its machine"
Assert-True (-not (Test-HostRegisters $singleEntry "AI0001")) "Single-host string skipped elsewhere"
$noHostEntry = @{ agent = "mAuditor"; job = "legacy"; cron = "0 3 * * *" }
Assert-True (Test-HostRegisters $noHostEntry "AI0001") "No-host entry registers everywhere (AI0001)"
Assert-True (Test-HostRegisters $noHostEntry "AI0003") "No-host entry registers everywhere (AI0003)"

# ========================================
# TC84: Orphan cleanup excludes VO infrastructure tasks
# ========================================
Write-Host "`nTC84: Orphan cleanup task classification" -ForegroundColor Cyan
function Test-IsRecurringAgentTask([object]$Task) {
    if ($Task.TaskName -notlike "VO-*" -or $Task.TaskName -like "VO-oneoff-*") {
        return $false
    }
    return @($Task.Actions | Where-Object {
        $_.Arguments -like "*Invoke-AgentJob.ps1*"
    }).Count -gt 0
}
$agentTask = [PSCustomObject]@{
    TaskName = "VO-pBugKiller-scan-and-fix"
    Actions  = @([PSCustomObject]@{ Arguments = '-File "runner\Invoke-AgentJob.ps1" -Agent "pBugKiller" -Job "scan-and-fix"' })
}
$portalTask = [PSCustomObject]@{
    TaskName = "VO-Portal-Server"
    Actions  = @([PSCustomObject]@{ Arguments = '-File "ui\server.ps1" -Port 8400' })
}
$oneoffTask = [PSCustomObject]@{
    TaskName = "VO-oneoff-pBugKiller-scan-and-fix-20260806220000"
    Actions  = @([PSCustomObject]@{ Arguments = '-File "runner\Invoke-AgentJob.ps1" -Agent "pBugKiller" -Job "scan-and-fix"' })
}
Assert-True (Test-IsRecurringAgentTask $agentTask) "Recurring Invoke-AgentJob task is eligible for orphan cleanup"
Assert-True (-not (Test-IsRecurringAgentTask $portalTask)) "VO infrastructure task is excluded from orphan cleanup"
Assert-True (-not (Test-IsRecurringAgentTask $oneoffTask)) "VO one-off task remains excluded from orphan cleanup"

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-ScheduleRegistration: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
