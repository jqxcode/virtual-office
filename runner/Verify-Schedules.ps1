#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only reconciler for Virtual Office scheduled tasks.
.DESCRIPTION
    Loads config/schedules.json + config/agents.json, enumerates live VO-*
    Windows Scheduled Tasks (excluding VO-oneoff-*), and reports a PASS/FAIL
    table. Exits non-zero if ANY of these drift conditions are detected:

      1. A live VO-* task's -Agent "<x>" value is NOT a key in agents.json
         (the exact failure mode where an agent rename left tasks launching
         dead agent names that silently no-ran).
      2. A schedules.json entry has NO matching live task (job will not run).
      3. A live non-oneoff VO-* task is NOT represented in schedules.json
         (orphan -- left over from a removed/renamed schedule entry).

    This script is STRICTLY READ-ONLY. It NEVER registers, unregisters, or
    modifies any scheduled task and it NEVER writes to state/ or output/.
    Use Register-Schedules.ps1 to actually reconcile.

    Task name derivation mirrors Register-Schedules.ps1:
      VO-<agent>-<job>            for the first occurrence of an agent+job
      VO-<agent>-<job>-<N>        for the Nth (N>=2) duplicate cron entry
.PARAMETER Quiet
    Suppress the per-row detail tables; print only the summary and verdict.
.EXAMPLE
    pwsh -File runner/Verify-Schedules.ps1
.NOTES
    Exit 0 = PASS (live tasks fully reconciled with config).
    Exit 1 = FAIL (one or more drift conditions detected).
    Exit 2 = could not run (missing config / Task Scheduler unavailable).
#>
[CmdletBinding()]
param(
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "constants.ps1")

$TASK_PREFIX = "VO-"
$ONEOFF_PREFIX = "VO-oneoff-"
$INVOKE_SCRIPT_MARKER = "Invoke-AgentJob.ps1"

# --- Load config ---

$schedulesFile = Join-Path $CONFIG_DIR "schedules.json"
$agentsFile = Join-Path $CONFIG_DIR "agents.json"

if (-not (Test-Path $schedulesFile)) {
    Write-Error "Schedules config not found: $schedulesFile"
    exit 2
}
if (-not (Test-Path $agentsFile)) {
    Write-Error "Agents config not found: $agentsFile"
    exit 2
}

$schedulesRaw = Get-Content -Path $schedulesFile -Raw | ConvertFrom-Json -AsHashtable
$schedules = if ($schedulesRaw.ContainsKey("schedules")) { $schedulesRaw["schedules"] } else { $schedulesRaw }

$agentsRaw = Get-Content -Path $agentsFile -Raw | ConvertFrom-Json -AsHashtable
$agents = if ($agentsRaw.ContainsKey("agents")) { $agentsRaw["agents"] } else { $agentsRaw }

# --- Derive expected task names from schedules.json (mirror Register logic) ---

$expectedTaskNames = @{}   # taskName -> @{ agent; job; cron }
$taskNameCount = @{}

foreach ($entry in $schedules) {
    $agentName = $entry["agent"]
    $jobName = $entry["job"]
    $cron = $entry["cron"]
    $baseKey = "$agentName|$jobName"
    if (-not $taskNameCount.ContainsKey($baseKey)) {
        $taskNameCount[$baseKey] = 1
    } else {
        $taskNameCount[$baseKey]++
    }
    $occurrence = $taskNameCount[$baseKey]
    if ($occurrence -eq 1) {
        $taskName = "${TASK_PREFIX}$agentName-$jobName"
    } else {
        $taskName = "${TASK_PREFIX}$agentName-$jobName-$occurrence"
    }
    $expectedTaskNames[$taskName] = @{
        agent = $agentName
        job   = $jobName
        cron  = $cron
    }
}

# --- Enumerate live VO-* agent-job tasks ---
#
# An "agent-job task" is one whose action actually launches Invoke-AgentJob.ps1.
# We deliberately exclude:
#   - VO-oneoff-* (transient manual runs), and
#   - any VO-* task that is NOT an agent job (e.g. VO-Portal-Server, which runs
#     ui/server.ps1). Those are infrastructure, not schedules.json entries, so
#     they are not orphans and must not be flagged.
# Filtering on the Invoke-AgentJob.ps1 marker (rather than a name blocklist) is
# robust to future infra tasks being added under the VO- prefix.

$liveTasks = @{}   # taskName -> @{ agent; job }   (agent/job parsed from action)
$skippedNonAgent = @()
$liveTaskList = @()

# Enumerate live tasks via a background job with a hard timeout.
# Get-ScheduledTask can hang indefinitely when the Task Scheduler service is
# slow or starting up, which caused 38+ stuck subprocess retries (issue #50).
$SCHTASK_TIMEOUT_SEC = 30
$taskPrefix   = $TASK_PREFIX
$oneoffPrefix = $ONEOFF_PREFIX
$enumJob = Start-Job -ScriptBlock {
    param($tp, $op)
    @(Get-ScheduledTask | Where-Object {
        $_.TaskName -like "${tp}*" -and $_.TaskName -notlike "${op}*"
    })
} -ArgumentList $taskPrefix, $oneoffPrefix

$jobFinished = Wait-Job -Job $enumJob -Timeout $SCHTASK_TIMEOUT_SEC

if ($null -eq $jobFinished) {
    # Timed out -- kill the job and continue with degraded (empty) task list.
    Stop-Job  -Job $enumJob
    Remove-Job -Job $enumJob -Force
    Write-Warning "Get-ScheduledTask timed out after ${SCHTASK_TIMEOUT_SEC}s (Task Scheduler may be slow). Continuing with empty task list -- live-task checks will show all expected tasks as missing."
} else {
    if ($enumJob.State -eq "Failed") {
        $err = $enumJob.ChildJobs[0].JobStateInfo.Reason
        Remove-Job -Job $enumJob -Force
        Write-Error "Could not enumerate scheduled tasks: $err"
        exit 2
    }
    try {
        $liveTaskList = @(Receive-Job -Job $enumJob)
    } catch {
        Write-Error "Could not enumerate scheduled tasks: $_"
        Remove-Job -Job $enumJob -Force
        exit 2
    }
    Remove-Job -Job $enumJob -Force
}

foreach ($task in $liveTaskList) {
    $parsedAgent = $null
    $parsedJob = $null
    $isAgentJob = $false
    foreach ($action in @($task.Actions)) {
        $argText = ""
        if ($action.PSObject.Properties.Name -contains "Arguments" -and $action.Arguments) {
            $argText = [string]$action.Arguments
        }
        if ($argText -like "*$INVOKE_SCRIPT_MARKER*") {
            $isAgentJob = $true
        }
        if ($argText -match '-Agent\s+"([^"]+)"') {
            $parsedAgent = $Matches[1]
        }
        if ($argText -match '-Job\s+"([^"]+)"') {
            $parsedJob = $Matches[1]
        }
    }
    if (-not $isAgentJob) {
        $skippedNonAgent += $task.TaskName
        continue
    }
    $liveTasks[$task.TaskName] = @{
        agent = $parsedAgent
        job   = $parsedJob
    }
}

# --- Reconcile ---

# Failure 1: live task -Agent value not a key in agents.json
$deadAgentTasks = @()
foreach ($name in ($liveTasks.Keys | Sort-Object)) {
    $a = $liveTasks[$name]["agent"]
    if ($null -eq $a) {
        # Could not parse an -Agent value at all -- treat as dead/unknown.
        $deadAgentTasks += [PSCustomObject]@{
            TaskName = $name
            Agent    = "<unparsed>"
            Reason   = "no -Agent argument found in task action"
        }
    } elseif (-not $agents.ContainsKey($a)) {
        $deadAgentTasks += [PSCustomObject]@{
            TaskName = $name
            Agent    = $a
            Reason   = "agent '$a' is not a key in agents.json"
        }
    }
}

# Failure 2: schedules.json entry with no matching live task
$missingTasks = @()
foreach ($name in ($expectedTaskNames.Keys | Sort-Object)) {
    if (-not $liveTasks.ContainsKey($name)) {
        $missingTasks += [PSCustomObject]@{
            TaskName = $name
            Agent    = $expectedTaskNames[$name]["agent"]
            Job      = $expectedTaskNames[$name]["job"]
            Cron     = $expectedTaskNames[$name]["cron"]
        }
    }
}

# Failure 3: live non-oneoff VO-* task not represented in schedules.json (orphan)
$orphanTasks = @()
foreach ($name in ($liveTasks.Keys | Sort-Object)) {
    if (-not $expectedTaskNames.ContainsKey($name)) {
        $orphanTasks += [PSCustomObject]@{
            TaskName = $name
            Agent    = $liveTasks[$name]["agent"]
            Job      = $liveTasks[$name]["job"]
        }
    }
}

# --- Report ---

Write-Host ""
Write-Host "=== Verify-Schedules (READ-ONLY reconciler) ===" -ForegroundColor White
Write-Host "Schedule entries (config): $(@($schedules).Count)"
Write-Host "Expected task names:       $($expectedTaskNames.Count)"
Write-Host "Live VO-* agent-job tasks: $($liveTasks.Count)"
Write-Host "Known agents:              $($agents.Count)"
if ($skippedNonAgent.Count -gt 0) {
    Write-Host "Skipped non-agent VO-* tasks: $($skippedNonAgent.Count) ($($skippedNonAgent -join ', '))" -ForegroundColor DarkGray
}

function Show-Check {
    param(
        [string]$Title,
        [object[]]$Items,
        [string[]]$Columns
    )
    Write-Host ""
    if ($Items.Count -eq 0) {
        Write-Host "[PASS] $Title" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $Title ($($Items.Count))" -ForegroundColor Red
        if (-not $Quiet) {
            $Items | Format-Table -Property $Columns -AutoSize | Out-String | Write-Host
        }
    }
}

Show-Check -Title "Check 1: every live VO-* task targets a known agent" `
    -Items $deadAgentTasks -Columns @("TaskName", "Agent", "Reason")

Show-Check -Title "Check 2: every schedules.json entry has a live task" `
    -Items $missingTasks -Columns @("TaskName", "Agent", "Job", "Cron")

Show-Check -Title "Check 3: no orphan live VO-* tasks (all are in schedules.json)" `
    -Items $orphanTasks -Columns @("TaskName", "Agent", "Job")

# --- Verdict ---

$totalFailures = $deadAgentTasks.Count + $missingTasks.Count + $orphanTasks.Count

Write-Host ""
Write-Host "========================================" -ForegroundColor White
if ($totalFailures -eq 0) {
    Write-Host "RESULT: PASS -- live tasks fully reconciled with config." -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor White
    exit 0
} else {
    Write-Host "RESULT: FAIL -- $totalFailures drift issue(s) detected." -ForegroundColor Red
    Write-Host "  dead-agent tasks:   $($deadAgentTasks.Count)" -ForegroundColor Red
    Write-Host "  missing tasks:      $($missingTasks.Count)" -ForegroundColor Red
    Write-Host "  orphan tasks:       $($orphanTasks.Count)" -ForegroundColor Red
    Write-Host "Run: pwsh -File runner/Register-Schedules.ps1   to reconcile." -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor White
    exit 1
}
