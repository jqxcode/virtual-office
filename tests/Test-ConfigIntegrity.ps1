#Requires -Version 7.0
# Test-ConfigIntegrity.ps1 -- Config integrity validation tests
# Run: pwsh -File tests/Test-ConfigIntegrity.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Test harness ---
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

# --- Locate project root ---
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $ProjectRoot "config/agents.json"))) {
    $ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

$ConfigDir = Join-Path $ProjectRoot "config"
$AgentsFile = Join-Path $ConfigDir "agents.json"
$SchedulesFile = Join-Path $ConfigDir "schedules.json"
$JobsDir = Join-Path $ConfigDir "jobs"

# Load config files
$agentsRaw = Get-Content -Path $AgentsFile -Raw | ConvertFrom-Json -AsHashtable
$agents = if ($agentsRaw.ContainsKey("agents")) { $agentsRaw["agents"] } else { $agentsRaw }

$schedulesRaw = Get-Content -Path $SchedulesFile -Raw | ConvertFrom-Json -AsHashtable
$schedules = if ($schedulesRaw.ContainsKey("schedules")) { $schedulesRaw["schedules"] } else { $schedulesRaw }

# Load all job files
$jobFiles = Get-ChildItem -Path $JobsDir -Filter "*.json" -File
$allJobs = @{}
foreach ($jf in $jobFiles) {
    $agentName = [System.IO.Path]::GetFileNameWithoutExtension($jf.Name)
    $jobRaw = Get-Content -Path $jf.FullName -Raw | ConvertFrom-Json -AsHashtable
    $allJobs[$agentName] = if ($jobRaw.ContainsKey("jobs")) { $jobRaw["jobs"] } else { $jobRaw }
}

# ========================================
# TC1: All agents have corresponding job files
# ========================================
Write-Host "`nTC1: All agents in agents.json have corresponding job files in config/jobs/" -ForegroundColor Cyan

foreach ($agentName in ($agents.Keys | Sort-Object)) {
    $jobFile = Join-Path $JobsDir "$agentName.json"
    $exists = Test-Path $jobFile
    Assert-True $exists "Agent '$agentName' has job file at config/jobs/$agentName.json"
}

# ========================================
# TC2: All jobs in schedules.json exist in their agent's job config
# ========================================
Write-Host "`nTC2: All jobs referenced in schedules.json exist in their agent's job config" -ForegroundColor Cyan

foreach ($entry in $schedules) {
    $agent = $entry["agent"]
    $job = $entry["job"]
    $hasAgent = $allJobs.ContainsKey($agent)
    if ($hasAgent) {
        $hasJob = $allJobs[$agent].ContainsKey($job)
        Assert-True $hasJob "Schedule entry '$agent/$job' exists in config/jobs/$agent.json"
    } else {
        Assert-True $false "Schedule entry '$agent/$job' -- agent '$agent' has no job config file"
    }
}

# ========================================
# TC3: No orphaned job files
# ========================================
Write-Host "`nTC3: No orphaned job files (job files without matching agent in agents.json)" -ForegroundColor Cyan

foreach ($jf in $jobFiles) {
    $agentName = [System.IO.Path]::GetFileNameWithoutExtension($jf.Name)
    $hasAgent = $agents.ContainsKey($agentName)
    Assert-True $hasAgent "Job file '$($jf.Name)' has matching agent '$agentName' in agents.json"
}

# ========================================
# TC4: No duplicate schedule entries
# ========================================
Write-Host "`nTC4: No duplicate schedule entries (same agent+job+cron)" -ForegroundColor Cyan

$seen = @{}
$hasDuplicates = $false
foreach ($entry in $schedules) {
    $key = "$($entry["agent"])|$($entry["job"])|$($entry["cron"])"
    if ($seen.ContainsKey($key)) {
        $hasDuplicates = $true
        Write-Host "    Duplicate: $key" -ForegroundColor Yellow
    }
    $seen[$key] = $true
}
Assert-True (-not $hasDuplicates) "No duplicate schedule entries found"

# ========================================
# TC5: All job prompts are non-empty strings
# ========================================
Write-Host "`nTC5: All job prompts are non-empty strings" -ForegroundColor Cyan

foreach ($agentName in ($allJobs.Keys | Sort-Object)) {
    foreach ($jobName in ($allJobs[$agentName].Keys | Sort-Object)) {
        $jobDef = $allJobs[$agentName][$jobName]
        $hasPrompt = $jobDef.ContainsKey("prompt") -and $jobDef["prompt"] -is [string] -and $jobDef["prompt"].Trim().Length -gt 0
        Assert-True $hasPrompt "Job '$agentName/$jobName' has a non-empty prompt"
    }
}

# ========================================
# TC6: All agents have required fields
# ========================================
Write-Host "`nTC6: All agents have required fields (displayName, agentFile, group)" -ForegroundColor Cyan

$requiredFields = @("displayName", "agentFile", "group")
foreach ($agentName in ($agents.Keys | Sort-Object)) {
    foreach ($field in $requiredFields) {
        $hasField = $agents[$agentName].ContainsKey($field) -and $agents[$agentName][$field] -ne $null -and $agents[$agentName][$field].ToString().Trim().Length -gt 0
        Assert-True $hasField "Agent '$agentName' has required field '$field'"
    }
}

# ========================================
# TC7: Agent file paths actually exist on disk
# ========================================
Write-Host "`nTC7: Agent file paths in agentFile field actually exist on disk" -ForegroundColor Cyan

foreach ($agentName in ($agents.Keys | Sort-Object)) {
    $rawPath = $agents[$agentName]["agentFile"]
    $resolvedPath = $null
    if ($rawPath.StartsWith("~/")) {
        $resolvedPath = Join-Path $HOME $rawPath.Substring(2)
    } else {
        $resolvedPath = Join-Path $ProjectRoot $rawPath
    }
    $exists = Test-Path $resolvedPath
    Assert-True $exists "Agent '$agentName' agentFile '$rawPath' exists on disk (resolved: $resolvedPath)"
}

# ========================================
# TC8: No legacy agent names in schedules
# ========================================
Write-Host "`nTC8: No legacy agent names in schedules (memo-checker/checker should be auditor)" -ForegroundColor Cyan

$legacyNames = @("memo-checker", "checker")
$hasLegacy = $false
foreach ($entry in $schedules) {
    $agent = $entry["agent"]
    if ($legacyNames -contains $agent) {
        $hasLegacy = $true
        Write-Host "    Legacy agent name found in schedule: '$agent'" -ForegroundColor Yellow
    }
}
Assert-True (-not $hasLegacy) "No legacy agent names (memo-checker, checker) found in schedules.json"

# Also check agents.json
$hasLegacyAgent = $false
foreach ($agentName in $agents.Keys) {
    if ($legacyNames -contains $agentName) {
        $hasLegacyAgent = $true
        Write-Host "    Legacy agent name found in agents.json: '$agentName'" -ForegroundColor Yellow
    }
}
Assert-True (-not $hasLegacyAgent) "No legacy agent names (memo-checker, checker) found in agents.json"

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-ConfigIntegrity: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
