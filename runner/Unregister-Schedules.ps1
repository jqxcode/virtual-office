#Requires -Version 7.0
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes all Virtual Office scheduled tasks from Windows Task Scheduler.
.DESCRIPTION
    Finds and unregisters all tasks matching the pattern VirtualOffice-*.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "constants.ps1")

$tasks = Get-ScheduledTask -TaskName "VirtualOffice-*" -ErrorAction SilentlyContinue

if (-not $tasks -or $tasks.Count -eq 0) {
    Write-Host "No VirtualOffice tasks found in Task Scheduler."
    exit 0
}

$removed = @()

foreach ($task in $tasks) {
    $name = $task.TaskName
    Write-Host "Removing: $name"
    Unregister-ScheduledTask -TaskName $name -Confirm:$false

    # Parse agent and job from task name pattern VirtualOffice-{agent}-{job}
    $agentName = "unknown"
    $jobName = "unknown"
    if ($name -match '^VirtualOffice-(.+)-([^-]+)$') {
        $agentName = $Matches[1]
        $jobName = $Matches[2]
    }

    # Write event and audit entries
    $nowIso = Get-Date -Format "o"
    $monthFileName = "$(Get-Date -Format 'yyyy-MM').jsonl"

    if (-not (Test-Path $STATE_DIR)) {
        New-Item -ItemType Directory -Path $STATE_DIR -Force | Out-Null
    }
    if (-not (Test-Path $AUDIT_DIR)) {
        New-Item -ItemType Directory -Path $AUDIT_DIR -Force | Out-Null
    }

    $eventEntry = @{
        ts            = $nowIso
        agent         = $agentName
        job           = $jobName
        event         = "schedule_removed"
        details       = @{ taskName = $name }
        systemVersion = $SYSTEM_VERSION
    } | ConvertTo-Json -Compress
    Add-Content -Path $EVENTS_FILE -Value $eventEntry -Encoding ASCII

    $auditEntry = @{
        ts            = $nowIso
        action        = "schedule_removed"
        agent         = $agentName
        job           = $jobName
        runId         = "N/A"
        systemVersion = $SYSTEM_VERSION
        details       = @{ taskName = $name }
    } | ConvertTo-Json -Compress
    $auditFile = Join-Path $AUDIT_DIR $monthFileName
    Add-Content -Path $auditFile -Value $auditEntry -Encoding ASCII

    $removed += $name
}

Write-Host ""
Write-Host "=== Removal Summary ==="
Write-Host "Removed $($removed.Count) task(s):"
foreach ($name in $removed) {
    Write-Host "  - $name"
}
