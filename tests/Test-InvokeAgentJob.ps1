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
`$ERRORS_FILE = Join-Path `$STATE_DIR "errors.jsonl"
`$DASHBOARD_FILE = Join-Path `$STATE_DIR "dashboard.json"
`$DEFAULT_STALE_LOCK_TIMEOUT_MINUTES = 120
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
    # Promote sourced constants to global scope so global helper functions can access them
    Set-Variable -Name SYSTEM_VERSION -Value $SYSTEM_VERSION -Scope Global
    Set-Variable -Name PROJECT_ROOT -Value $PROJECT_ROOT -Scope Global
    Set-Variable -Name CONFIG_DIR -Value $CONFIG_DIR -Scope Global
    Set-Variable -Name STATE_DIR -Value $STATE_DIR -Scope Global
    Set-Variable -Name OUTPUT_DIR -Value $OUTPUT_DIR -Scope Global
    Set-Variable -Name AUDIT_DIR -Value $AUDIT_DIR -Scope Global
    Set-Variable -Name EVENTS_FILE -Value $EVENTS_FILE -Scope Global
    Set-Variable -Name ERRORS_FILE -Value $ERRORS_FILE -Scope Global
    Set-Variable -Name DASHBOARD_FILE -Value $DASHBOARD_FILE -Scope Global
    Set-Variable -Name DEFAULT_STALE_LOCK_TIMEOUT_MINUTES -Value $DEFAULT_STALE_LOCK_TIMEOUT_MINUTES -Scope Global

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
    # Copy the real runner, but mock the agent CLI via the VO_CLI_MOCK_OUTPUT env seam
    $realRunner = Join-Path $PSScriptRoot ".." "runner" "Invoke-AgentJob.ps1"
    $realRunner = (Resolve-Path $realRunner).Path
    $runnerContent = Get-Content -Path $realRunner -Raw

    # Replace the constants source line to point to our test constants
    $testConstants = Join-Path $Root "runner/constants.ps1"
    $runnerContent = $runnerContent -replace '\. \(Join-Path \$PSScriptRoot "constants\.ps1"\)', ". '$testConstants'"

    # Mock the agent CLI via the runner's VO_CLI_MOCK_OUTPUT test seam (inherited by the child pwsh).
    $env:VO_CLI_MOCK_OUTPUT = "mock agent output"

    $testRunner = Join-Path $Root "runner/test-runner.ps1"
    Set-Content -Path $testRunner -Value $runnerContent -Encoding UTF8

    $result = pwsh -NoProfile -File $testRunner -Agent $AgentName -Job $JobName 2>&1 | Out-String
    $env:VO_CLI_MOCK_OUTPUT = $null
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
    $auditFiles = @(Get-ChildItem -Path (Join-Path $root "output/audit") -Filter "*.jsonl" -ErrorAction SilentlyContinue)
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

# ========================================
# TC50: Config with wrapper key "agents" parsed correctly
# ========================================
Write-Host "`nTC50: Config with wrapper key 'agents' parsed correctly" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Import-RunnerFunctions -Root $root

    # Write agents.json with the wrapper key format: {"agents": {"test-agent": {...}}}
    $wrappedAgents = @{
        agents = @{
            "test-agent" = @{ displayName = "Test Agent"; description = "wrapped test" }
        }
    } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $root "config/agents.json") -Value $wrappedAgents -Encoding UTF8

    # Write a valid job config so the runner can proceed
    $jobsJson = @{
        "test-job" = @{
            prompt = "echo test"
            maxRuns = 0
            description = "test job"
        }
    } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $root "config/jobs/test-agent.json") -Value $jobsJson -Encoding UTF8

    $result = Invoke-Runner -Root $root -AgentName "test-agent" -JobName "test-job"
    # The runner should NOT fail with "not found" -- it should unwrap the agents key
    $hasNotFoundError = $result.Output -match "not found in agents\.json"
    Assert-True (-not $hasNotFoundError) "Wrapped agents config does not cause 'not found' error"
    Assert-True ($result.ExitCode -eq 0) "Runner exits with code 0 for wrapped agents config"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC51: Jobs config with wrapper key "jobs" parsed correctly
# ========================================
Write-Host "`nTC51: Jobs config with wrapper key 'jobs' parsed correctly" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Import-RunnerFunctions -Root $root

    # Write agents.json (flat format -- already known to work)
    $agentsJson = @{ "test-agent" = @{ displayName = "Test Agent"; description = "test" } } | ConvertTo-Json
    Set-Content -Path (Join-Path $root "config/agents.json") -Value $agentsJson -Encoding UTF8

    # Write jobs config with the wrapper key format: {"jobs": {"test-job": {...}}}
    $wrappedJobs = @{
        jobs = @{
            "test-job" = @{
                prompt = "echo test"
                maxRuns = 0
                description = "wrapped job"
            }
        }
    } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $root "config/jobs/test-agent.json") -Value $wrappedJobs -Encoding UTF8

    $result = Invoke-Runner -Root $root -AgentName "test-agent" -JobName "test-job"
    # The runner should NOT fail with "not found" -- it should unwrap the jobs key
    $hasNotFoundError = $result.Output -match "not found in .*/jobs/test-agent\.json"
    Assert-True (-not $hasNotFoundError) "Wrapped jobs config does not cause 'not found' error"
    Assert-True ($result.ExitCode -eq 0) "Runner exits with code 0 for wrapped jobs config"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC75: Stale lock older than timeout is cleared
# ========================================
Write-Host "`nTC75: Stale lock older than timeout is cleared" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root -MaxRuns 0
    Import-RunnerFunctions -Root $root

    # Pre-create lock file with a timestamp 3 hours ago
    $stateDir = Ensure-StateDir -AgentName "test-agent" -JobName "test-job"
    $lockFile = Join-Path $stateDir "lock"
    $staleTime = (Get-Date).AddHours(-3).ToString("o")
    Set-Content -Path $lockFile -Value $staleTime -Encoding ASCII

    $result = Invoke-Runner -Root $root
    Assert-True ($result.ExitCode -eq 0) "Runner exits with code 0 after stale lock cleared"
    Assert-True ($result.Output -match "Stale lock cleared" -or $result.Output -match "stale") "Output mentions stale lock"

    # Lock file should be removed (runner clears it then re-acquires then removes after run)
    Assert-True (-not (Test-Path $lockFile)) "Lock file is removed after stale lock cleared and run completed"

    # Counter should show a run happened
    $counterFile = Join-Path $stateDir "counter.json"
    if (Test-Path $counterFile) {
        $counter = Get-Content -Path $counterFile -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($counter["count"] -eq 1) "Counter shows 1 (job ran after stale lock cleared)"
    } else {
        Assert-True $false "Counter file should exist after run"
    }
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC76: Fresh lock within timeout is NOT cleared
# ========================================
Write-Host "`nTC76: Fresh lock within timeout is NOT cleared" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root -MaxRuns 0
    Import-RunnerFunctions -Root $root

    # Pre-create lock file with a timestamp 30 minutes ago (within default 120m timeout)
    $stateDir = Ensure-StateDir -AgentName "test-agent" -JobName "test-job"
    $lockFile = Join-Path $stateDir "lock"
    $freshTime = (Get-Date).AddMinutes(-30).ToString("o")
    Set-Content -Path $lockFile -Value $freshTime -Encoding ASCII

    $result = Invoke-Runner -Root $root
    Assert-True ($result.ExitCode -eq 0) "Runner exits cleanly when lock is fresh"
    Assert-True ($result.Output -match "locked" -or $result.Output -match "Queued") "Output mentions lock/queue"

    # Lock file should still exist (not cleared)
    Assert-True (Test-Path $lockFile) "Lock file still exists (fresh lock not cleared)"

    # Queue file should exist
    $queueFile = Join-Path $stateDir "queue"
    Assert-True (Test-Path $queueFile) "Queue file was created (job was queued)"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC77: Custom staleLockTimeoutMinutes from agent config
# ========================================
Write-Host "`nTC77: Custom staleLockTimeoutMinutes from agent config" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Import-RunnerFunctions -Root $root

    # Write agents.json with custom staleLockTimeoutMinutes of 30
    $agentsJson = @{
        "test-agent" = @{
            displayName = "Test Agent"
            description = "test"
            staleLockTimeoutMinutes = 30
        }
    } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $root "config/agents.json") -Value $agentsJson -Encoding UTF8

    # Write job config
    $jobsJson = @{
        "test-job" = @{
            prompt = "echo test output"
            maxRuns = 0
            description = "test job"
        }
    } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $root "config/jobs/test-agent.json") -Value $jobsJson -Encoding UTF8

    # Pre-create lock file with a timestamp 45 minutes ago (stale with 30m timeout)
    $stateDir = Ensure-StateDir -AgentName "test-agent" -JobName "test-job"
    $lockFile = Join-Path $stateDir "lock"
    $staleTime = (Get-Date).AddMinutes(-45).ToString("o")
    Set-Content -Path $lockFile -Value $staleTime -Encoding ASCII

    $result = Invoke-Runner -Root $root
    Assert-True ($result.ExitCode -eq 0) "Runner exits with code 0 after custom stale lock cleared"
    Assert-True ($result.Output -match "Stale lock cleared" -or $result.Output -match "stale") "Output mentions stale lock"

    # Lock should be gone after run
    Assert-True (-not (Test-Path $lockFile)) "Lock file removed after stale lock cleared"

    # Counter should show a run happened
    $counterFile = Join-Path $stateDir "counter.json"
    if (Test-Path $counterFile) {
        $counter = Get-Content -Path $counterFile -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($counter["count"] -eq 1) "Counter shows 1 (job ran with custom timeout)"
    } else {
        Assert-True $false "Counter file should exist after run"
    }
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC78: Invalid lock timestamp treated as stale
# ========================================
Write-Host "`nTC78: Invalid lock timestamp treated as stale" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root -MaxRuns 0
    Import-RunnerFunctions -Root $root

    # Pre-create lock file with invalid timestamp content
    $stateDir = Ensure-StateDir -AgentName "test-agent" -JobName "test-job"
    $lockFile = Join-Path $stateDir "lock"
    Set-Content -Path $lockFile -Value "invalid-timestamp" -Encoding ASCII

    $result = Invoke-Runner -Root $root
    Assert-True ($result.ExitCode -eq 0) "Runner exits with code 0 after invalid lock cleared"
    Assert-True ($result.Output -match "Stale lock cleared" -or $result.Output -match "stale") "Output mentions stale lock"

    # Lock should be gone after run
    Assert-True (-not (Test-Path $lockFile)) "Lock file removed after invalid timestamp treated as stale"

    # Counter should show a run happened
    $counterFile = Join-Path $stateDir "counter.json"
    if (Test-Path $counterFile) {
        $counter = Get-Content -Path $counterFile -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($counter["count"] -eq 1) "Counter shows 1 (job ran after invalid lock cleared)"
    } else {
        Assert-True $false "Counter file should exist after run"
    }
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC79: Write-AuditEntry retries when audit file is held FileShare::None by a concurrent writer
# ========================================
# Regression: 2026-05-29 12:00 PT mPoster/FFv2-daily-summary silent crash (job ran under
# the former mScrumReporter agent, since merged into mPoster).
# Two scheduled jobs hit Write-AuditEntry on the same audit file within the same
# millisecond. The pre-fix code opened the FileStream once with FileShare::None and
# let any IOException propagate uncaught, killing the runner before any audit entry,
# event, or dashboard write landed. Post-fix the function retries 10 x 20ms.
Write-Host "`nTC79: Write-AuditEntry retries on FileShare contention" -ForegroundColor Cyan
$blockingStream = $null
$root = New-TestRoot
try {
    Write-TestConstants -Root $root

    # Extract the production Write-AuditEntry function from the real runner so the
    # test exercises the actual deployed retry logic (not the inline test stub).
    $realRunner = (Resolve-Path (Join-Path $PSScriptRoot ".." "runner" "Invoke-AgentJob.ps1")).Path
    $runnerContent = Get-Content -Path $realRunner -Raw
    $startIdx = $runnerContent.IndexOf("function Write-AuditEntry {")
    $endIdx = $runnerContent.IndexOf("function Write-Event")
    if ($startIdx -lt 0 -or $endIdx -le $startIdx) {
        Assert-True $false "Could not extract Write-AuditEntry from production runner"
    } else {
        $writeAuditEntryFn = $runnerContent.Substring($startIdx, $endIdx - $startIdx).TrimEnd()

        # Pre-create the month audit file
        $auditDir = Join-Path $root "output/audit"
        New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
        $monthFile = Join-Path $auditDir ("$(Get-Date -Format 'yyyy-MM').jsonl")
        Set-Content -Path $monthFile -Value "" -Encoding UTF8

        # Acquire an exclusive FileShare::None handle from the test process.
        # This is exactly the contention shape that killed the 12:00 run -- the loser
        # of the race would have hit this same IOException with no retry.
        $blockingStream = [System.IO.FileStream]::new(
            $monthFile,
            [System.IO.FileMode]::Append,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )

        # Child script: imports the extracted Write-AuditEntry and calls it once with
        # the same StrictMode / ErrorActionPreference as production.
        $childScript = Join-Path $root "tc79-child.ps1"
        $auditDirFwd = ($auditDir -replace '\\','/')
        $childContent = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$AUDIT_DIR = '$auditDirFwd'
`$SYSTEM_VERSION = '0.0.0-tc79'
$writeAuditEntryFn
Write-AuditEntry -Action 'started' -AgentName 'tc79-child' -JobName 'tc79-job' -RunId 'tc79-run'
"@
        Set-Content -Path $childScript -Value $childContent -Encoding UTF8

        $childOut = Join-Path $root "tc79-child.out"
        $childErr = Join-Path $root "tc79-child.err"
        $proc = Start-Process pwsh `
            -ArgumentList @("-NoProfile", "-File", $childScript) `
            -PassThru -NoNewWindow `
            -RedirectStandardOutput $childOut `
            -RedirectStandardError $childErr

        # Hold lock 200ms (well within child's 10 x 20ms = 1100ms retry budget),
        # then release. Without the retry loop in production code the child would
        # have already thrown by now and exited non-zero.
        Start-Sleep -Milliseconds 200
        $blockingStream.Close()
        $blockingStream = $null

        if (-not $proc.WaitForExit(5000)) {
            try { $proc.Kill() } catch {}
            Assert-True $false "Child writer did not finish within 5s"
        } else {
            Assert-True ($proc.ExitCode -eq 0) "Child writer exits 0 after retry succeeds (exit code: $($proc.ExitCode))"

            $audit = Get-Content -Path $monthFile -Raw
            Assert-True ($audit -match '"agent":"tc79-child"') "Child agent name appears in audit log after retry"
            Assert-True ($audit -match '"action":"started"') "Child action appears in audit log after retry"
        }
    }
} finally {
    if ($blockingStream) { try { $blockingStream.Close() } catch {} }
    Remove-TestRoot -Root $root
}

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-InvokeAgentJob: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
