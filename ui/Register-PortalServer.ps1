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

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description "Auto-start Virtual Office portal server on port $Port" `
    -Force | Out-Null

Write-Host "Registered scheduled task: $taskName (port $Port, at-logon trigger)"
