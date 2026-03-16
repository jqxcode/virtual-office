#Requires -Version 7.0
# Test-InvokeAgentJob.ps1 -- Tests for the core Invoke-AgentJob runner logic
# Run: pwsh -File tests/Test-InvokeAgentJob.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Test harness ---
$script:Passed = 0
$script:Failed = 0
$script:TestName = ""

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
    # Create directory structure
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

# Write a minimal constants.ps1 that uses the test root
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

# Write config files for the test agent/job
function Write-TestConfig {
    param(
        [string]$Root,
        [string]$AgentName = "test-agent",
        [string]$JobName = "test-job",
        [int]$MaxRuns = 0,
        [bool]$Enabled = $true,
        [string]$Prompt = "echo test output"
    )
    # agents.json -- runner reads top-level keys as agent names
    $agentsJson = @{ $AgentName = @{ displayName = "Test Agent"; description = "test" } } | ConvertTo-Json
    Set-Content -Path (Join-Path $Root "config/agents.json") -Value $agentsJson -Encoding UTF8

    # jobs/{agent}.json -- runner reads top-level keys as job names
    $jobsJson = @{
        $JobName = @{
            prompt  = $Prompt
            maxRuns = $MaxRuns
            enabled = $Enabled
            description = "test job"
        }
    } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $Root "config/jobs/$AgentName.json") -Value $jobsJson -Encoding UTF8
}

# Source the runner functions without executing the main flow.
# We copy the runner and strip the main flow, keeping only function defs.
function Import-RunnerFunctions {
    param([string]$Root)
    # Source constants
    . (Join-Path $Root "runner/constants.ps1")

    # Define helper functions inline (copied from runner) so tests can call them directly.
    # This avoids executing the param() / main flow of Invoke-AgentJob.ps1.

    function global:Write-AtomicFile {
        param([string]$Path, [string]$Content)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $tmpPath = "$Path.tmp"
        [System.IO.File]::WriteAllText($tmpPath, $Content)
        Move-Item -Path $tmpPath -Destination $Path -Force
    }

    function global:Write-AuditEntry {
        param(
            [string]$Action,
            [string]$AgentName,
            [string]$JobName,
            [string]$RunId,
            [hashtable]$Details = @{}
        )
        if (-not (Test-Path $AUDIT_DIR)) {
            New-Item -ItemType Directory -Path $AUDIT_DIR -Force | Out-Null
        }
        $now = Get-Date -Format "o"
        $monthFile = Join-Path $AUDIT_DIR ("$(Get-Date -Format 'yyyy-MM').jsonl")
        $entry = @{
            timestamp      = $now
            action         = $Action
            agent          = $AgentName
            job            = $JobName
            run_id         = $RunId
            system_version = $SYSTEM_VERSION
            details        = $Details
        } | ConvertTo-Json -Compress
        Add-Content -Path $monthFile -Value $entry -Encoding UTF8
    }

    function global:Update-Dashboard {
        param(
            [string]$AgentName,
            [string]$JobName,
            [string]$Status,
            [hashtable]$Details = @{}
        )
        $dashboard = @{}
        if (Test-Path $DASHBOARD_FILE) {
            try {
                $dashboard = Get-Content -Path $DASHBOARD_FILE -Raw | ConvertFrom-Json -AsHashtable
            } catch {
                $dashboard = @{}
            }
        }
        if (-not $dashboard.ContainsKey("agents")) {
            $dashboard["agents"] = @{}
        }
        if (-not $dashboard["agents"].ContainsKey($AgentName)) {
            $dashboard["agents"][$AgentName] = @{}
        }
        if (-not $dashboard["agents"][$AgentName].ContainsKey($JobName)) {
            $dashboard["agents"][$AgentName][$JobName] = @{}
        }
        $jobState = $dashboard["agents"][$AgentName][$JobName]
        $jobState["status"] = $Status
        $jobState["updated"] = (Get-Date -Format "o")
        foreach ($key in $Details.Keys) {
            $jobState[$key] = $Details[$key]
        }
        $dashboard["agents"][$AgentName][$JobName] = $jobState
        $json = $dashboard | ConvertTo-Json -Depth 10
        Write-AtomicFile -Path $DASHBOARD_FILE -Content $json
    }

    function global:Ensure-StateDir {
        param([string]$AgentName, [string]$JobName)
        $dir = Join-Path $STATE_DIR "agents" $AgentName $JobName
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        return $dir
    }

    function global:Get-QueueDepth {
        param([string]$QueueFile)
        if (-not (Test-Path $QueueFile)) { return 0 }
        $val = (Get-Content -Path $QueueFile -Raw).Trim()
        if ($val -match '^\d+$') { return [int]$val }
        return 0
    }

    function global:Set-QueueDepth {
        param([string]$QueueFile, [int]$Depth)
        if ($Depth -le 0) {
            if (Test-Path $QueueFile) { Remove-Item -Path $QueueFile -Force }
        } else {
            Write-AtomicFile -Path $QueueFile -Content "$Depth"
        }
    }
}

# --- Helper: run the actual runner script in a subprocess ---
function Invoke-Runner {
    param(
        [string]$Root,
        [string]$AgentName = "test-agent",
        [string]$JobName = "test-job"
    )
    # Copy the real runner, but replace the claude invocation with a mock
    $realRunner = Join-Path $PSScriptRoot ".." "runner" "Invoke-AgentJob.ps1"
    $realRunner = (Resolve-Path $realRunner).Path
    $runnerContent = Get-Content -Path $realRunner -Raw

    # Replace the constants source line to point to our test constants
    $testConstants = Join-Path $Root "runner/constants.ps1"
    $runnerContent = $runnerContent -replace '\. \(Join-Path \$PSScriptRoot "constants\.ps1"\)', ". '$testConstants'"

    # Replace claude invocation with a mock that just writes output
    $runnerContent = $runnerContent -replace '\$output = & claude --agent \$agentFile \$prompt 2>&1 \| Out-String', '$output = "mock agent output with file"'
    $runnerContent = $runnerContent -replace '\$output = & claude \$prompt 2>&1 \| Out-String', '$output = "mock agent output"'

    $testRunner = Join-Path $Root "runner/test-runner.ps1"
    Set-Content -Path $testRunner -Value $runnerContent -Encoding UTF8

    $result = pwsh -NoProfile -File $testRunner -Agent $AgentName -Job $JobName 2>&1 | Out-String
    return @{
        Output   = $result
        ExitCode = $LASTEXITCODE
    }
}

# ========================================
# TC1: Happy path - no lock, counter at 0
# ========================================
Write-Host "`nTC1: Happy path - no lock, counter at 0" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root -MaxRuns 0
    Import-RunnerFunctions -Root $root

    $result = Invoke-Runner -Root $root
    Assert-True ($result.ExitCode -eq 0) "Runner exits with code 0"

    $stateDir = Join-Path $root "state/agents/test-agent/test-job"
    $counterFile = Join-Path $stateDir "counter.json"
    Assert-True (Test-Path $counterFile) "counter.json was created"

    if (Test-Path $counterFile) {
        $counter = Get-Content -Path $counterFile -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($counter["count"] -eq 1) "Counter shows 1 after first run"
    }

    $lockFile = Join-Path $stateDir "lock"
    Assert-True (-not (Test-Path $lockFile)) "Lock file is removed after run"

    # Check audit entry exists
    $auditFiles = Get-ChildItem -Path (Join-Path $root "output/audit") -Filter "*.jsonl" -ErrorAction SilentlyContinue
    Assert-True ($null -ne $auditFiles -and $auditFiles.Count -gt 0) "Audit log file was created"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC2: Lock exists - queue file incremented
# ========================================
Write-Host "`nTC2: Lock exists - job queued" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root -MaxRuns 0
    Import-RunnerFunctions -Root $root

    # Pre-create lock file to simulate a running job
    $stateDir = Ensure-StateDir -AgentName "test-agent" -JobName "test-job"
    $lockFile = Join-Path $stateDir "lock"
    $queueFile = Join-Path $stateDir "queue"
    Set-Content -Path $lockFile -Value (Get-Date -Format "o") -Encoding UTF8

    $result = Invoke-Runner -Root $root
    Assert-True ($result.ExitCode -eq 0) "Runner exits cleanly when locked"
    Assert-True ($result.Output -match "locked" -or $result.Output -match "Queued") "Output mentions lock/queue"

    Assert-True (Test-Path $queueFile) "Queue file was created"
    if (Test-Path $queueFile) {
        $depth = [int](Get-Content -Path $queueFile -Raw).Trim()
        Assert-True ($depth -ge 1) "Queue depth is at least 1"
    }
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC3: maxRuns reached - job skipped
# ========================================
Write-Host "`nTC3: maxRuns reached - job skipped" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root -MaxRuns 3
    Import-RunnerFunctions -Root $root

    # Pre-set counter to 3 (maxRuns limit)
    $stateDir = Ensure-StateDir -AgentName "test-agent" -JobName "test-job"
    $counterFile = Join-Path $stateDir "counter.json"
    $counterJson = @{ count = 3; last_run = (Get-Date -Format "o") } | ConvertTo-Json -Compress
    Set-Content -Path $counterFile -Value $counterJson -Encoding UTF8

    $result = Invoke-Runner -Root $root
    Assert-True ($result.ExitCode -eq 0) "Runner exits cleanly at maxRuns"
    Assert-True ($result.Output -match "maxRuns" -or $result.Output -match "Skipping") "Output mentions maxRuns skip"

    # Counter should still be 3 (no run happened)
    $counter = Get-Content -Path $counterFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($counter["count"] -eq 3) "Counter stays at 3 (not incremented)"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC4: maxRuns = 0 means unlimited
# ========================================
Write-Host "`nTC4: maxRuns = 0 - unlimited runs" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root -MaxRuns 0
    Import-RunnerFunctions -Root $root

    # Pre-set counter to a high number
    $stateDir = Ensure-StateDir -AgentName "test-agent" -JobName "test-job"
    $counterFile = Join-Path $stateDir "counter.json"
    $counterJson = @{ count = 999 } | ConvertTo-Json -Compress
    Set-Content -Path $counterFile -Value $counterJson -Encoding UTF8

    $result = Invoke-Runner -Root $root
    Assert-True ($result.ExitCode -eq 0) "Runner exits with code 0"

    $counter = Get-Content -Path $counterFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($counter["count"] -eq 1000) "Counter incremented to 1000 (unlimited)"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC5: Disabled job - exits without action
# ========================================
Write-Host "`nTC5: Disabled job - skipped" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root -Enabled $false
    Import-RunnerFunctions -Root $root

    $result = Invoke-Runner -Root $root
    Assert-True ($result.ExitCode -eq 0) "Runner exits cleanly for disabled job"
    Assert-True ($result.Output -match "disabled" -or $result.Output -match "Skipping") "Output mentions disabled"

    # No counter file should be created
    $stateDir = Join-Path $root "state/agents/test-agent/test-job"
    $counterFile = Join-Path $stateDir "counter.json"
    Assert-True (-not (Test-Path $counterFile)) "No counter file created for disabled job"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC6: Invalid agent name - errors gracefully
# ========================================
Write-Host "`nTC6: Invalid agent name - graceful error" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root
    Import-RunnerFunctions -Root $root

    $result = Invoke-Runner -Root $root -AgentName "nonexistent-agent"
    Assert-True ($result.ExitCode -ne 0) "Runner exits with non-zero code"
    Assert-True ($result.Output -match "not found" -or $result.Output -match "Error") "Output contains error message"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC7: Counter file missing - initializes to 0
# ========================================
Write-Host "`nTC7: Counter file missing - initializes to 0" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root -MaxRuns 0
    Import-RunnerFunctions -Root $root

    # Ensure NO counter file exists
    $stateDir = Join-Path $root "state/agents/test-agent/test-job"
    $counterFile = Join-Path $stateDir "counter.json"
    if (Test-Path $counterFile) { Remove-Item $counterFile -Force }

    $result = Invoke-Runner -Root $root
    Assert-True ($result.ExitCode -eq 0) "Runner succeeds without pre-existing counter"

    Assert-True (Test-Path $counterFile) "Counter file was created"
    if (Test-Path $counterFile) {
        $counter = Get-Content -Path $counterFile -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($counter["count"] -eq 1) "Counter initialized and incremented to 1"
    }
} finally {
    Remove-TestRoot -Root $root
}

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-InvokeAgentJob: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
