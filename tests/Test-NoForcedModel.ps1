#Requires -Version 7.0
# Test-NoForcedModel.ps1 -- Regression guard for model-agnostic VO launchers
# Run: pwsh -File tests/Test-NoForcedModel.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

$projectRoot = Split-Path $PSScriptRoot -Parent
$runnerDir = Join-Path $projectRoot "runner"
$runnerFiles = Get-ChildItem $runnerDir -File -Filter "*.ps1"

Write-Host "`nTC1: No VO PowerShell launcher selects a concrete model" -ForegroundColor Cyan
$modelFlagFiles = @($runnerFiles | Where-Object {
    (Get-Content $_.FullName -Raw) -match '(?<![\w-])--model(?:\s|["''])'
})
$concreteModelFiles = @($runnerFiles | Where-Object {
    (Get-Content $_.FullName -Raw) -match '(?i)\b(?:claude|gpt|gemini|mai|grok)-[a-z0-9.-]+'
})
Assert-True ($modelFlagFiles.Count -eq 0) "No runner script contains a --model override"
Assert-True ($concreteModelFiles.Count -eq 0) "No runner script contains a concrete top-level model ID"

Write-Host "`nTC2: Start-Wish delegates model and effort to Copilot" -ForegroundColor Cyan
$startWish = Get-Content (Join-Path $runnerDir "Start-Wish.ps1") -Raw
Assert-True ($startWish -notmatch '(?<![\w-])--model(?:\s|["''])') "Start-Wish has no model override"
Assert-True ($startWish -notmatch '(?<![\w-])--effort(?:\s|["''])') "Start-Wish has no effort override"
Assert-True ($startWish -match 'agency\.exe\s+copilot') "Start-Wish still launches Copilot via Agency"
Assert-True ($startWish -match '--context\s+long_context') "Start-Wish retains long-context capacity"

Write-Host "`nTC3: Main unattended runner retains required operational flags" -ForegroundColor Cyan
$invokeRunner = Get-Content (Join-Path $runnerDir "Invoke-AgentJob.ps1") -Raw
foreach ($required in @("--output-format", "--allow-all", "--agent", "-p", "--context")) {
    Assert-True ($invokeRunner.Contains($required)) "Invoke-AgentJob retains required flag: $required"
}
Assert-True ($invokeRunner -match 'session\.model_change') "Invoke-AgentJob parses model-change events"
Assert-True ($invokeRunner -match '\$modelName\s*=\s*"unknown"') "Unknown is the honest pre-resolution model value"

Write-Host "`nTC4: All scheduled/one-off/chained paths use the common runner" -ForegroundColor Cyan
$registerSchedules = Get-Content (Join-Path $runnerDir "Register-Schedules.ps1") -Raw
$registerOneOff = Get-Content (Join-Path $runnerDir "Register-OneOff.ps1") -Raw
Assert-True ($registerSchedules.Contains("Invoke-AgentJob.ps1")) "Recurring schedules route through Invoke-AgentJob"
Assert-True ($registerOneOff.Contains("Invoke-AgentJob.ps1")) "One-off schedules route through Invoke-AgentJob"
Assert-True ($invokeRunner.Contains("triggerOnComplete")) "Chained jobs are handled by Invoke-AgentJob"

Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-NoForcedModel: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
