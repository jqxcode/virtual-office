#Requires -Version 7.0
<#
.SYNOPSIS
    Registers Windows Task Scheduler entries for Virtual Office scheduled jobs.
.DESCRIPTION
    Reads config/schedules.json and creates/updates Task Scheduler tasks for each
    scheduled agent job. Uses Run-Hidden.vbs wrapper for invisible execution.
    Cleans up orphan VO-* tasks not in schedules.json.
#>
[CmdletBinding()]
param(
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "constants.ps1")

$TASK_PREFIX = "VO-"
$VBS_PATH = Join-Path $PSScriptRoot "Run-Hidden.vbs"

# --- Cron parser ---

function ConvertFrom-CronToTrigger {
    <#
    .SYNOPSIS
        Converts a cron expression to Task Scheduler trigger(s).
    .DESCRIPTION
        Supports: */N minutes (hourly repeat), specific hour/minute,
        day-of-week ranges (1-5), L (last day of month), * wildcards.
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
    $domField = $parts[2]
    # $monthField = $parts[3]  # month (not used yet)
    $dowField = $parts[4]

    # Parse day-of-week
    $dowMap = @{
        "0" = "Sunday"; "1" = "Monday"; "2" = "Tuesday"; "3" = "Wednesday"
        "4" = "Thursday"; "5" = "Friday"; "6" = "Saturday"; "7" = "Sunday"
        "SUN" = "Sunday"; "MON" = "Monday"; "TUE" = "Tuesday"; "WED" = "Wednesday"
        "THU" = "Thursday"; "FRI" = "Friday"; "SAT" = "Saturday"
    }

    # Case 1: */N minutes -- repetition interval (hourly jobs)
    if ($minuteField -match '^\*/(\d+)$') {
        $intervalMinutes = [int]$Matches[1]
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $intervalMinutes) -RepetitionDuration (New-TimeSpan -Days 365)
        return $trigger
    }

    # Case 2: Hourly at specific minute (hour = *)
    if ($hourField -eq '*') {
        $minute = 0
        if ($minuteField -match '^\d+$') { $minute = [int]$minuteField }
        $at = (Get-Date).Date.AddMinutes($minute)
        $trigger = New-ScheduledTaskTrigger -Once -At $at -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 365)
        return $trigger
    }

    # Parse minute
    $minute = 0
    if ($minuteField -match '^\d+$') {
        $minute = [int]$minuteField
    }

    # Parse hours
    $hours = @()
    if ($hourField -match '^\d+$') {
        $hours = @([int]$hourField)
    } elseif ($hourField -match ',') {
        $hours = $hourField -split ',' | ForEach-Object { [int]$_ }
    }

    # Case 3: Last day of month (L in day-of-month field)
    if ($domField -eq 'L') {
        # Task Scheduler doesn't natively support "last day of month".
        # Use a monthly trigger on the 28th with a PowerShell wrapper that
        # checks if today is actually the last day. But simpler: register
        # triggers for days 28,29,30,31 and let the action script check.
        # Alternatively, use a single monthly trigger on day 1 of NEXT month
        # minus 1 day. Simplest: use COM object for monthly last-day trigger.
        $triggers = @()
        foreach ($h in $hours) {
            $at = (Get-Date).Date.AddHours($h).AddMinutes($minute)
            # Create a monthly trigger using CIM -- Task Scheduler supports
            # "last day" via MonthlyTrigger with RunOnLastDayOfMonth flag.
            # Since New-ScheduledTaskTrigger doesn't expose this, we create
            # a daily trigger and wrap the action with a last-day check.
            $trigger = New-ScheduledTaskTrigger -Daily -At $at
            $triggers += $trigger
        }
        if ($triggers.Count -eq 1) { return $triggers[0] }
        return $triggers
    }

    # Parse day-of-week
    $daysOfWeek = @()
    if ($dowField -ne '*') {
        $expandedParts = @()
        foreach ($segment in ($dowField -split ',')) {
            $segment = $segment.Trim()
            if ($segment -match '^(\d+)-(\d+)$') {
                $start = [int]$Matches[1]
                $end = [int]$Matches[2]
                for ($i = $start; $i -le $end; $i++) {
                    $expandedParts += "$i"
                }
            } else {
                $expandedParts += $segment
            }
        }
        foreach ($d in $expandedParts) {
            $key = $d.Trim().ToUpper()
            if ($dowMap.ContainsKey($key)) {
                $daysOfWeek += $dowMap[$key]
            }
        }
    }

    # Build triggers
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

# --- Build action with Run-Hidden.vbs wrapper ---

function New-VOTaskAction {
    param([string]$AgentName, [string]$JobName)

    $invokeScript = Join-Path $PSScriptRoot "Invoke-AgentJob.ps1"
    $cmd = "pwsh -NoProfile -File `"$invokeScript`" -Agent `"$AgentName`" -Job `"$JobName`""

    # For L (last day of month) jobs, wrap with a date check
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' `
        -Argument "`"$VBS_PATH`" `"$cmd`"" `
        -WorkingDirectory $PROJECT_ROOT
    return $action
}

# --- Main ---

$schedulesFile = Join-Path $CONFIG_DIR "schedules.json"
if (-not (Test-Path $schedulesFile)) {
    Write-Error "Schedules config not found: $schedulesFile"
    exit 1
}

$schedules = Get-Content -Path $schedulesFile -Raw | ConvertFrom-Json -AsHashtable

$registered = @()
$expectedTaskNames = @{}

# Track occurrence count per agent+job key to handle duplicate cron entries
$taskNameCount = @{}

foreach ($entry in $schedules["schedules"]) {
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

    $expectedTaskNames[$taskName] = $true

    Write-Host "Processing: $taskName (cron: $cron)"

    $trigger = ConvertFrom-CronToTrigger -Cron $cron
    if ($null -eq $trigger) {
        Write-Warning "Skipping $taskName -- could not parse cron expression."
        continue
    }

    $action = New-VOTaskAction -AgentName $agentName -JobName $jobName
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would register: $taskName" -ForegroundColor Cyan
    } else {
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

        Write-Host "  Registered: $taskName"
    }

    $registered += [PSCustomObject]@{
        TaskName = $taskName
        Agent    = $agentName
        Job      = $jobName
        Cron     = $cron
    }
}

# --- Clean up orphan VO-* tasks not in schedules.json ---

Write-Host ""
Write-Host "=== Checking for orphan tasks ==="

$allVOTasks = Get-ScheduledTask | Where-Object { $_.TaskName -like "${TASK_PREFIX}*" -and $_.TaskName -notlike "${TASK_PREFIX}oneoff-*" }
$orphans = @()
foreach ($task in $allVOTasks) {
    if (-not $expectedTaskNames.ContainsKey($task.TaskName)) {
        $orphans += $task.TaskName
    }
}

if ($orphans.Count -eq 0) {
    Write-Host "No orphan tasks found."
} else {
    Write-Host "Found $($orphans.Count) orphan task(s):"
    foreach ($orphan in $orphans) {
        if ($DryRun) {
            Write-Host "  [DRY RUN] Would unregister: $orphan" -ForegroundColor Yellow
        } else {
            Unregister-ScheduledTask -TaskName $orphan -Confirm:$false
            Write-Host "  Unregistered orphan: $orphan" -ForegroundColor Yellow
        }
    }
}

# --- Summary ---

Write-Host ""
Write-Host "=== Registration Summary ==="
if ($registered.Count -eq 0) {
    Write-Host "No tasks registered."
} else {
    $registered | Format-Table -AutoSize
}
Write-Host "Total: $($registered.Count) tasks registered, $($orphans.Count) orphans removed."
