#Requires -Version 7.0
# Test-QueueDrain.ps1 -- Tests for queue drain behavior
# Run: pwsh -File tests/Test-QueueDrain.ps1

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

function New-TestRoot {
    $root = Join-Path $env:TEMP "vo-test-$(Get-Random)"
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    foreach ($d in @("config/jobs", "state/agents", "output/audit", "runner")) {
        New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null
    }
    return $root
}

function Remove-TestRoot {
    param([string]$Root)
    if ($Root -and (Test-Path $Root)) {
        Remove-Item -Path $Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-TestConstants {
    param([string]$Root)
    $content = @"
`$SYSTEM_VERSION = "0.1.0-test"
`$PROJECT_ROOT = "$($Root -replace '\\', '\\')"
`$CONFIG_DIR = Join-Path `$PROJECT_ROOT "config"
`$STATE_DIR = Join-Path `$PROJECT_ROOT "state"
`$OUTPUT_DIR = Join-Path `$PROJECT_ROOT "output"
`$AUDIT_DIR = Join-Path `$OUTPUT_DIR "audit"
`$EVENTS_FILE = Join-Path `$STATE_DIR "events.jsonl"
`$DASHBOARD_FILE = Join-Path `$STATE_DIR "dashboard.json"
"@
    Set-Content -Path (Join-Path $Root "runner/constants.ps1") -Value $content -Encoding ASCII
}

function Write-TestConfig {
    param(
        [string]$Root,
        [int]$MaxRuns = 0,
        [bool]$Enabled = $true
    )
    $agentsJson = @{ "test-agent" = @{ displayName = "Test Agent"; description = "test" } } | ConvertTo-Json
    Set-Content -Path (Join-Path $Root "config/agents.json") -Value $agentsJson -Encoding UTF8

    $jobsJson = @{
        "test-job" = @{
            prompt      = "echo test"
            maxRuns     = $MaxRuns
            enabled     = $Enabled
            description = "test job"
        }
    } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $Root "config/jobs/test-agent.json") -Value $jobsJson -Encoding UTF8
}

function Invoke-Runner {
    param(
        [string]$Root,
        [string]$AgentName = "test-agent",
        [string]$JobName = "test-job"
    )
    $realRunner = Join-Path $PSScriptRoot ".." "runner" "Invoke-AgentJob.ps1"
    $realRunner = (Resolve-Path $realRunner).Path
    $runnerContent = Get-Content -Path $realRunner -Raw

    $testConstants = Join-Path $Root "runner/constants.ps1"
    $runnerContent = $runnerContent -replace '\. \(Join-Path \$PSScriptRoot "constants\.ps1"\)', ". '$testConstants'"
    $runnerContent = $runnerContent -replace '\$output = & claude --agent \$agentFile \$prompt 2>&1 \| Out-String', '$output = "mock output"'
    $runnerContent = $runnerContent -replace '\$output = & claude \$prompt 2>&1 \| Out-String', '$output = "mock output"'

    $testRunner = Join-Path $Root "runner/test-runner.ps1"
    Set-Content -Path $testRunner -Value $runnerContent -Encoding UTF8

    $result = pwsh -NoProfile -File $testRunner -Agent $AgentName -Job $JobName 2>&1 | Out-String
    return @{
        Output   = $result
        ExitCode = $LASTEXITCODE
    }
}

# ========================================
# TC8: Queue depth 1 - drains one more (total 2 runs)
# ========================================
Write-Host "`nTC8: Queue depth 1 - drains to total 2 runs" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root -MaxRuns 0
    # Pre-create queue file with depth 1
    $stateDir = Join-Path $root "state/agents/test-agent/test-job"
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    Set-Content -Path (Join-Path $stateDir "queue") -Value "1" -Encoding UTF8

    $result = Invoke-Runner -Root $root
    Assert-True ($result.ExitCode -eq 0) "Runner exits successfully"
    Assert-True ($result.Output -match "Draining") "Output mentions draining queue"

    $counterFile = Join-Path $stateDir "counter.json"
    Assert-True (Test-Path $counterFile) "Counter file exists"
    if (Test-Path $counterFile) {
        $counter = Get-Content -Path $counterFile -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($counter["count"] -eq 2) "Counter shows 2 (initial + 1 drained)"
    }

    # Queue file should be gone after drain
    $queueFile = Join-Path $stateDir "queue"
    Assert-True (-not (Test-Path $queueFile)) "Queue file removed after drain"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC9: Queue depth 3 - drains all 3 (total 4 runs)
# ========================================
Write-Host "`nTC9: Queue depth 3 - drains all (total 4 runs)" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root -MaxRuns 0

    $stateDir = Join-Path $root "state/agents/test-agent/test-job"
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    Set-Content -Path (Join-Path $stateDir "queue") -Value "3" -Encoding UTF8

    $result = Invoke-Runner -Root $root
    Assert-True ($result.ExitCode -eq 0) "Runner exits successfully"

    $counterFile = Join-Path $stateDir "counter.json"
    if (Test-Path $counterFile) {
        $counter = Get-Content -Path $counterFile -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($counter["count"] -eq 4) "Counter shows 4 (initial + 3 drained)"
    } else {
        Assert-True $false "Counter file should exist"
    }

    $queueFile = Join-Path $stateDir "queue"
    Assert-True (-not (Test-Path $queueFile)) "Queue file removed after full drain"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC10: Queue + maxRuns - stops at maxRuns, discards remaining
# ========================================
Write-Host "`nTC10: Queue + maxRuns - stops when maxRuns hit" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root -MaxRuns 2

    $stateDir = Join-Path $root "state/agents/test-agent/test-job"
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    # Start with counter at 0, queue at 3, maxRuns at 2
    # Should run once (counter=1), drain once (counter=2), then hit maxRuns and stop
    Set-Content -Path (Join-Path $stateDir "queue") -Value "3" -Encoding UTF8

    $result = Invoke-Runner -Root $root
    Assert-True ($result.ExitCode -eq 0) "Runner exits successfully"

    $counterFile = Join-Path $stateDir "counter.json"
    if (Test-Path $counterFile) {
        $counter = Get-Content -Path $counterFile -Raw | ConvertFrom-Json -AsHashtable
        # The runner runs first, increments to 1, then drains queue.
        # Next iteration: counter=1, maxRuns=2 so it runs again (counter=2).
        # Next iteration: counter=2, maxRuns=2 so it breaks.
        Assert-True ($counter["count"] -le 2) "Counter did not exceed maxRuns (got $($counter["count"]))"
    } else {
        Assert-True $false "Counter file should exist"
    }

    Assert-True ($result.Output -match "maxRuns") "Output mentions maxRuns limit"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC11: Queue file missing - treated as 0, no drain
# ========================================
Write-Host "`nTC11: Queue file missing - no drain" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root -MaxRuns 0

    # No queue file -- should run exactly once
    $result = Invoke-Runner -Root $root
    Assert-True ($result.ExitCode -eq 0) "Runner exits successfully"

    $stateDir = Join-Path $root "state/agents/test-agent/test-job"
    $counterFile = Join-Path $stateDir "counter.json"
    if (Test-Path $counterFile) {
        $counter = Get-Content -Path $counterFile -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($counter["count"] -eq 1) "Counter is exactly 1 (no drain)"
    } else {
        Assert-True $false "Counter file should exist"
    }

    Assert-True (-not ($result.Output -match "Draining")) "No drain message in output"
} finally {
    Remove-TestRoot -Root $root
}

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-QueueDrain: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
