param(
    [int]$Port = 8400,
    [switch]$Unregister
)

$taskName = 'VO-Portal-Server'
$serverScript = Join-Path $PSScriptRoot 'server.ps1'

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Unregistered scheduled task: $taskName"
    return
}

if (-not (Test-Path $serverScript)) {
    Write-Error "server.ps1 not found at $serverScript"
    return
}

$action = New-ScheduledTaskAction `
    -Execute 'pwsh.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$serverScript`" -Port $Port"

# Trigger 1: start at logon.
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

# Trigger 2: self-healing watchdog. Fires every 2 minutes indefinitely; combined with
# MultipleInstances=IgnoreNew below it is a no-op while the server is alive, but restarts
# it within ~2 min if the process died (crash/kill/session-cleanup) WITHOUT waiting for the
# next logon. This is what makes the auto-start actually durable -- an at-logon-only trigger
# never recovers a mid-session death, and RestartOnFailure does not fire when the process is
# externally killed (the task ends as completed, not failed).
$watchdogTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 2) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $logonTrigger, $watchdogTrigger `
    -Settings $settings `
    -Description "Auto-start Virtual Office portal server on port $Port (at-logon + 2-min self-healing watchdog)" `
    -Force | Out-Null

Write-Host "Registered scheduled task: $taskName (port $Port, at-logon + 2-min watchdog)"
