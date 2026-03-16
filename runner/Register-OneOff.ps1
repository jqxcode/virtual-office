#Requires -Version 7.0
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers a one-off Windows Task Scheduler task for a Virtual Office agent job.
.DESCRIPTION
    Creates a one-time scheduled task that fires after a configurable delay,
    and logs the registration to events.jsonl and the monthly audit log.
.PARAMETER Agent
    The agent name (e.g. scrum-master).
.PARAMETER Job
    The job name (e.g. dry-run-bug-autopilot).
.PARAMETER DelayMinutes
    Minutes from now until the task fires. Default: 1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Agent,

    [Parameter(Mandatory)]
    [string]$Job,

    [int]$DelayMinutes = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "constants.ps1")

# --- Calculate fire time and task name ---

$now = Get-Date
$fireTime = $now.AddMinutes($DelayMinutes)
$timestamp = $now.ToString("yyyyMMddHHmmss")
$taskName = "VirtualOffice-oneoff-$Agent-$Job-$timestamp"

# --- Register Task Scheduler entry ---

$invokeScript = Join-Path $PSScriptRoot "Invoke-AgentJob.ps1"
$actionArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$invokeScript`" -Agent `"$Agent`" -Job `"$Job`""
$action = New-ScheduledTaskAction -Execute "pwsh" -Argument $actionArgs -WorkingDirectory $PROJECT_ROOT

$trigger = New-ScheduledTaskTrigger -Once -At $fireTime
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -DeleteExpiredTaskAfter (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "Virtual Office one-off: $Agent / $Job" | Out-Null

# --- Write event to events.jsonl ---

$nowIso = Get-Date -Format "o"
$fireTimeIso = $fireTime.ToString("o")

if (-not (Test-Path $STATE_DIR)) {
    New-Item -ItemType Directory -Path $STATE_DIR -Force | Out-Null
}
if (-not (Test-Path $AUDIT_DIR)) {
    New-Item -ItemType Directory -Path $AUDIT_DIR -Force | Out-Null
}

$eventEntry = @{
    ts            = $nowIso
    agent         = $Agent
    job           = $Job
    event         = "schedule_registered"
    details       = @{
        oneoff      = $true
        taskName    = $taskName
        fireTime    = $fireTimeIso
        delayMinutes = $DelayMinutes
        description = "Virtual Office one-off: $Agent / $Job"
    }
    systemVersion = $SYSTEM_VERSION
} | ConvertTo-Json -Compress
Add-Content -Path $EVENTS_FILE -Value $eventEntry -Encoding ASCII

# --- Write audit entry ---

$monthFileName = "$(Get-Date -Format 'yyyy-MM').jsonl"
$auditEntry = @{
    ts            = $nowIso
    action        = "schedule_registered"
    agent         = $Agent
    job           = $Job
    runId         = "N/A"
    systemVersion = $SYSTEM_VERSION
    details       = @{
        oneoff       = $true
        taskName     = $taskName
        fireTime     = $fireTimeIso
        delayMinutes = $DelayMinutes
    }
} | ConvertTo-Json -Compress
$auditFile = Join-Path $AUDIT_DIR $monthFileName
Add-Content -Path $auditFile -Value $auditEntry -Encoding ASCII

# --- Confirmation ---

Write-Host "One-off task registered:" -ForegroundColor Green
Write-Host "  Task name : $taskName"
Write-Host "  Agent     : $Agent"
Write-Host "  Job       : $Job"
Write-Host "  Fire time : $fireTimeIso"
