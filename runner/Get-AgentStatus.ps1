#Requires -Version 7.0
<#
.SYNOPSIS
    Displays the current status of all Virtual Office agents.
.DESCRIPTION
    Reads state/dashboard.json and prints a formatted table showing each agent's
    status, active job, queue depth, runs completed, and last completed time.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "constants.ps1")

if (-not (Test-Path $DASHBOARD_FILE)) {
    Write-Host "No state found. Run a job first."
    exit 0
}

$dashboard = @{}
try {
    $dashboard = Get-Content -Path $DASHBOARD_FILE -Raw | ConvertFrom-Json -AsHashtable
} catch {
    Write-Host "Error reading dashboard file: $_"
    exit 1
}

if (-not $dashboard.ContainsKey("agents") -or $dashboard["agents"].Count -eq 0) {
    Write-Host "No state found. Run a job first."
    exit 0
}

$rows = @()

foreach ($agentName in ($dashboard["agents"].Keys | Sort-Object)) {
    $agentData = $dashboard["agents"][$agentName]
    foreach ($jobName in ($agentData.Keys | Sort-Object)) {
        $jobData = $agentData[$jobName]

        # Skip agent-level metadata keys (errorCount, lastError, etc.)
        if ($jobData -isnot [hashtable]) { continue }

        $status = if ($jobData.ContainsKey("status")) { $jobData["status"] } else { "unknown" }
        $runId = if ($jobData.ContainsKey("run_id")) { $jobData["run_id"] } else { "-" }
        $queueDepth = if ($jobData.ContainsKey("queue_depth")) { $jobData["queue_depth"] } else { 0 }
        $runsCompleted = if ($jobData.ContainsKey("runs_completed")) { $jobData["runs_completed"] } else { 0 }
        $lastCompleted = if ($jobData.ContainsKey("last_completed")) { $jobData["last_completed"] } else { "-" }

        # Format timestamp for display
        if ($lastCompleted -ne "-") {
            try {
                $dt = [datetime]::Parse($lastCompleted)
                $lastCompleted = $dt.ToString("yyyy-MM-dd HH:mm:ss")
            } catch {
                # Keep raw value
            }
        }

        $rows += [PSCustomObject]@{
            Agent         = $agentName
            Job           = $jobName
            Status        = $status
            RunId         = $runId
            QueueDepth    = $queueDepth
            RunsCompleted = $runsCompleted
            LastCompleted = $lastCompleted
        }
    }
}

if ($rows.Count -eq 0) {
    Write-Host "No state found. Run a job first."
} else {
    Write-Host ""
    Write-Host "=== Virtual Office Agent Status ==="
    Write-Host ""
    $rows | Format-Table -AutoSize -Property Agent, Job, Status, RunId, QueueDepth, RunsCompleted, LastCompleted
}
