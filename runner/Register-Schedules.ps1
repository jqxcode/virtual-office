#Requires -Version 7.0
<#
.SYNOPSIS
    Registers Windows Task Scheduler entries for Virtual Office scheduled jobs.
.DESCRIPTION
    Reads config/schedules.json and creates/updates Task Scheduler tasks for each
    scheduled agent job.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "constants.ps1")

# --- Cron parser ---

function ConvertFrom-CronToTrigger {
    <#
    .SYNOPSIS
        Converts a simplified cron expression to a Task Scheduler trigger.
    .DESCRIPTION
        Supports: */N in minutes, specific hours, day-of-week patterns.
        Cron format: minute hour day-of-month month day-of-week
    #>
    param([string]$Cron)

    $parts = $Cron -split '\s+'
    if ($parts.Count -ne 5) {
        Write-Error "Invalid cron expression: '$Cron'. Expected 5 fields."
        return $null
    }

    $minuteField = $parts[0]
    $hourField = $parts[1]
    # $domField = $parts[2]  # day-of-month (not fully supported)
    # $monthField = $parts[3]  # month (not fully supported)
    $dowField = $parts[4]

    # Parse day-of-week
    $dowMap = @{
        "0" = "Sunday"; "1" = "Monday"; "2" = "Tuesday"; "3" = "Wednesday"
        "4" = "Thursday"; "5" = "Friday"; "6" = "Saturday"; "7" = "Sunday"
        "SUN" = "Sunday"; "MON" = "Monday"; "TUE" = "Tuesday"; "WED" = "Wednesday"
        "THU" = "Thursday"; "FRI" = "Friday"; "SAT" = "Saturday"
    }

    # Case 1: */N minutes -- repetition interval
    if ($minuteField -match '^\*/(\d+)$') {
        $intervalMinutes = [int]$Matches[1]
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $intervalMinutes) -RepetitionDuration (New-TimeSpan -Days 365)
        return $trigger
    }

    # Case 2: Specific minute and hour, possibly with day-of-week
    $minute = 0
    if ($minuteField -match '^\d+$') {
        $minute = [int]$minuteField
    }

    $hours = @()
    if ($hourField -eq '*') {
        $hours = 0..23
    } elseif ($hourField -match '^\d+$') {
        $hours = @([int]$hourField)
    } elseif ($hourField -match ',') {
        $hours = $hourField -split ',' | ForEach-Object { [int]$_ }
    }

    $daysOfWeek = @()
    if ($dowField -ne '*') {
        $dowParts = $dowField -split ','
        foreach ($d in $dowParts) {
            $key = $d.Trim().ToUpper()
            if ($dowMap.ContainsKey($key)) {
                $daysOfWeek += $dowMap[$key]
            }
        }
    }

    $triggers = @()
    foreach ($h in $hours) {
        $at = (Get-Date).Date.AddHours($h).AddMinutes($minute)
        if ($daysOfWeek.Count -gt 0) {
            $trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $daysOfWeek -At $at
        } else {
            $trigger = New-ScheduledTaskTrigger -Daily -At $at
        }
        $triggers += $trigger
    }

    if ($triggers.Count -eq 1) { return $triggers[0] }
    return $triggers
}

# --- Main ---

$schedulesFile = Join-Path $CONFIG_DIR "schedules.json"
if (-not (Test-Path $schedulesFile)) {
    Write-Error "Schedules config not found: $schedulesFile"
    exit 1
}

$schedules = Get-Content -Path $schedulesFile -Raw | ConvertFrom-Json -AsHashtable

$invokeScript = Join-Path $PSScriptRoot "Invoke-AgentJob.ps1"
$registered = @()

foreach ($entry in $schedules["schedules"]) {
    $agentName = $entry["agent"]
    $jobName = $entry["job"]
    $cron = $entry["cron"]
    $taskName = "VirtualOffice-$agentName-$jobName"

    Write-Host "Processing: $taskName (cron: $cron)"

    $trigger = ConvertFrom-CronToTrigger -Cron $cron
    if ($null -eq $trigger) {
        Write-Warning "Skipping $taskName -- could not parse cron expression."
        continue
    }

    $actionArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$invokeScript`" -Agent `"$agentName`" -Job `"$jobName`""
    $action = New-ScheduledTaskAction -Execute "pwsh" -Argument $actionArgs -WorkingDirectory $PROJECT_ROOT

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    # Remove existing task if present
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "  Replaced existing task."
    }

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "Virtual Office: $agentName / $jobName" | Out-Null

    # Write event and audit entries
    $nowIso = Get-Date -Format "o"
    $monthFileName = "$(Get-Date -Format 'yyyy-MM').jsonl"
    $description = "Virtual Office: $agentName / $jobName"

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
        event         = "schedule_registered"
        details       = @{
            cron        = $cron
            taskName    = $taskName
            description = $description
        }
        systemVersion = $SYSTEM_VERSION
    } | ConvertTo-Json -Compress
    Add-Content -Path $EVENTS_FILE -Value $eventEntry -Encoding ASCII

    $auditEntry = @{
        ts            = $nowIso
        action        = "schedule_registered"
        agent         = $agentName
        job           = $jobName
        runId         = "N/A"
        systemVersion = $SYSTEM_VERSION
        details       = @{
            cron     = $cron
            taskName = $taskName
        }
    } | ConvertTo-Json -Compress
    $auditFile = Join-Path $AUDIT_DIR $monthFileName
    Add-Content -Path $auditFile -Value $auditEntry -Encoding ASCII

    $registered += [PSCustomObject]@{
        TaskName = $taskName
        Agent    = $agentName
        Job      = $jobName
        Cron     = $cron
    }
    Write-Host "  Registered: $taskName"
}

Write-Host ""
Write-Host "=== Registration Summary ==="
if ($registered.Count -eq 0) {
    Write-Host "No tasks registered."
} else {
    $registered | Format-Table -AutoSize
}
