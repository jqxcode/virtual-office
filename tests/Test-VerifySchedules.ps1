#Requires -Version 7.0
# Test-VerifySchedules.ps1 -- Tests for runner/Verify-Schedules.ps1 (read-only reconciler)
# Run: pwsh -File tests/Test-VerifySchedules.ps1

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

# --- Locate project root ---
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $ProjectRoot "config/agents.json"))) {
    $ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

$VerifyScript = Join-Path $ProjectRoot "runner/Verify-Schedules.ps1"

# ========================================
# TC1: Verify-Schedules.ps1 exists, is ASCII-only, and parses
# ========================================
Write-Host "`nTC1: Verify-Schedules.ps1 exists, is ASCII-only, and parses cleanly" -ForegroundColor Cyan

Assert-True (Test-Path $VerifyScript) "runner/Verify-Schedules.ps1 exists"

$rawBytes = [System.IO.File]::ReadAllBytes($VerifyScript)
$nonAscii = @($rawBytes | Where-Object { $_ -gt 127 })
Assert-True ($nonAscii.Count -eq 0) "Verify-Schedules.ps1 is ASCII-only (no bytes > 127)"

$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($VerifyScript, [ref]$null, [ref]$parseErrors)
Assert-True (@($parseErrors).Count -eq 0) "Verify-Schedules.ps1 parses without syntax errors"

# ========================================
# TC2: Script is read-only -- contains no task mutation cmdlets
# ========================================
Write-Host "`nTC2: Verify-Schedules.ps1 never registers/unregisters/modifies tasks" -ForegroundColor Cyan

$scriptText = Get-Content -Path $VerifyScript -Raw
# These mutation cmdlets must not appear as live calls. (Comments referencing
# Register-Schedules.ps1 by name are fine; we look for the cmdlet invocations.)
$forbidden = @("Register-ScheduledTask", "Unregister-ScheduledTask", "Set-ScheduledTask", "Disable-ScheduledTask", "Enable-ScheduledTask")
foreach ($cmd in $forbidden) {
    $found = $scriptText -match [regex]::Escape($cmd)
    Assert-True (-not $found) "Verify-Schedules.ps1 does not call $cmd"
}
# Also must not write to state/ or output/
Assert-True (-not ($scriptText -match "Add-Content")) "Verify-Schedules.ps1 does not Add-Content (no state writes)"
Assert-True (-not ($scriptText -match "Set-Content")) "Verify-Schedules.ps1 does not Set-Content (no state writes)"

# ========================================
# TC3: Running the script does not change the set of scheduled tasks
# ========================================
Write-Host "`nTC3: Running Verify-Schedules.ps1 leaves scheduled tasks unchanged" -ForegroundColor Cyan

$tasksBefore = @(Get-ScheduledTask | Where-Object { $_.TaskName -like "VO-*" } | Select-Object -ExpandProperty TaskName | Sort-Object)
$null = & pwsh -File $VerifyScript -Quiet 2>&1
$verifyExit = $LASTEXITCODE
$tasksAfter = @(Get-ScheduledTask | Where-Object { $_.TaskName -like "VO-*" } | Select-Object -ExpandProperty TaskName | Sort-Object)

$sameTasks = (($tasksBefore -join "|") -eq ($tasksAfter -join "|"))
Assert-True $sameTasks "VO-* task set is identical before and after running Verify-Schedules.ps1"
Assert-True ($verifyExit -eq 0 -or $verifyExit -eq 1) "Verify-Schedules.ps1 exits 0 (PASS) or 1 (FAIL), got $verifyExit"

# ========================================
# TC4: Reconciliation logic correctly flags a synthetic mismatch
# ========================================
# We re-implement the exact derivation + reconciliation the script uses, then
# feed it synthetic config + synthetic live-task data to prove each drift
# condition is detected. This validates the algorithm without mutating any real
# Windows Scheduled Task.
Write-Host "`nTC4: Reconciliation logic flags dead-agent, missing, and orphan tasks" -ForegroundColor Cyan

function Get-Reconciliation {
    param(
        [object[]]$Schedules,   # array of @{ agent; job; cron }
        [hashtable]$Agents,     # agentName -> $true
        [hashtable]$LiveTasks   # taskName -> @{ agent; job }
    )
    $TASK_PREFIX = "VO-"
    $expected = @{}
    $count = @{}
    foreach ($e in $Schedules) {
        $baseKey = "$($e.agent)|$($e.job)"
        if (-not $count.ContainsKey($baseKey)) { $count[$baseKey] = 1 } else { $count[$baseKey]++ }
        $occ = $count[$baseKey]
        $name = if ($occ -eq 1) { "${TASK_PREFIX}$($e.agent)-$($e.job)" } else { "${TASK_PREFIX}$($e.agent)-$($e.job)-$occ" }
        $expected[$name] = $e
    }
    $dead = @(); $missing = @(); $orphan = @()
    foreach ($name in $LiveTasks.Keys) {
        $a = $LiveTasks[$name]["agent"]
        if ($null -eq $a -or -not $Agents.ContainsKey($a)) { $dead += $name }
    }
    foreach ($name in $expected.Keys) {
        if (-not $LiveTasks.ContainsKey($name)) { $missing += $name }
    }
    foreach ($name in $LiveTasks.Keys) {
        if (-not $expected.ContainsKey($name)) { $orphan += $name }
    }
    return [PSCustomObject]@{ Dead = $dead; Missing = $missing; Orphan = $orphan; Expected = $expected }
}

# Synthetic config: agents Foo and Bar; schedule for Foo/job1 and Bar/job2.
$synthAgents = @{ "Foo" = $true; "Bar" = $true }
$synthSchedules = @(
    @{ agent = "Foo"; job = "job1"; cron = "0 7 * * 1-5" },
    @{ agent = "Bar"; job = "job2"; cron = "0 9 * * *" }
)

# Case A: fully reconciled -- no drift.
$liveGood = @{
    "VO-Foo-job1" = @{ agent = "Foo"; job = "job1" }
    "VO-Bar-job2" = @{ agent = "Bar"; job = "job2" }
}
$rGood = Get-Reconciliation -Schedules $synthSchedules -Agents $synthAgents -LiveTasks $liveGood
Assert-True ($rGood.Dead.Count -eq 0 -and $rGood.Missing.Count -eq 0 -and $rGood.Orphan.Count -eq 0) "Reconciled set produces zero drift"

# Case B: dead-agent task (the exact rename failure) -- live task targets unknown agent.
$liveDead = @{
    "VO-Foo-job1"    = @{ agent = "Foo"; job = "job1" }
    "VO-Bar-job2"    = @{ agent = "Bar"; job = "job2" }
    "VO-OldName-job3" = @{ agent = "OldName"; job = "job3" }
}
$rDead = Get-Reconciliation -Schedules $synthSchedules -Agents $synthAgents -LiveTasks $liveDead
Assert-True ($rDead.Dead -contains "VO-OldName-job3") "Live task targeting renamed/unknown agent is flagged as dead-agent"

# Case C: missing task -- a schedule entry has no live task.
$liveMissing = @{
    "VO-Foo-job1" = @{ agent = "Foo"; job = "job1" }
}
$rMissing = Get-Reconciliation -Schedules $synthSchedules -Agents $synthAgents -LiveTasks $liveMissing
Assert-True ($rMissing.Missing -contains "VO-Bar-job2") "Schedule entry with no live task is flagged as missing"

# Case D: orphan task -- live task not represented in schedules.json.
$liveOrphan = @{
    "VO-Foo-job1"    = @{ agent = "Foo"; job = "job1" }
    "VO-Bar-job2"    = @{ agent = "Bar"; job = "job2" }
    "VO-Foo-stalejob" = @{ agent = "Foo"; job = "stalejob" }
}
$rOrphan = Get-Reconciliation -Schedules $synthSchedules -Agents $synthAgents -LiveTasks $liveOrphan
Assert-True ($rOrphan.Orphan -contains "VO-Foo-stalejob") "Live task absent from schedules.json is flagged as orphan"

# Case E: duplicate cron entries derive -2 suffix (matches Register-Schedules logic).
$dupSchedules = @(
    @{ agent = "Foo"; job = "job1"; cron = "0 7 * * 1-5" },
    @{ agent = "Foo"; job = "job1"; cron = "0 15 * * 1-5" }
)
$rDup = Get-Reconciliation -Schedules $dupSchedules -Agents $synthAgents -LiveTasks @{}
Assert-True ($rDup.Expected.ContainsKey("VO-Foo-job1") -and $rDup.Expected.ContainsKey("VO-Foo-job1-2")) "Duplicate cron entries derive VO-Foo-job1 and VO-Foo-job1-2"

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-VerifySchedules: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
