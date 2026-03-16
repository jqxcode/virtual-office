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
    $removed += $name
}

Write-Host ""
Write-Host "=== Removal Summary ==="
Write-Host "Removed $($removed.Count) task(s):"
foreach ($name in $removed) {
    Write-Host "  - $name"
}
