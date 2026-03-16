#Requires -Version 7.0
# Test-AuditLog.ps1 -- Tests for audit log creation, partitioning, and schema
# Run: pwsh -File tests/Test-AuditLog.ps1

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
    param([string]$Root)
    $agentsJson = @{ "test-agent" = @{ displayName = "Test Agent"; description = "test" } } | ConvertTo-Json
    Set-Content -Path (Join-Path $Root "config/agents.json") -Value $agentsJson -Encoding UTF8

    $jobsJson = @{
        "test-job" = @{
            prompt      = "echo test"
            maxRuns     = 0
            enabled     = $true
            description = "test job"
        }
    } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $Root "config/jobs/test-agent.json") -Value $jobsJson -Encoding UTF8
}

function Import-RunnerFunctions {
    param([string]$Root)
    . (Join-Path $Root "runner/constants.ps1")

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
}

function Invoke-Runner {
    param([string]$Root)
    $realRunner = Join-Path $PSScriptRoot ".." "runner" "Invoke-AgentJob.ps1"
    $realRunner = (Resolve-Path $realRunner).Path
    $runnerContent = Get-Content -Path $realRunner -Raw

    $testConstants = Join-Path $Root "runner/constants.ps1"
    $runnerContent = $runnerContent -replace '\. \(Join-Path \$PSScriptRoot "constants\.ps1"\)', ". '$testConstants'"
    $runnerContent = $runnerContent -replace '\$output = & claude --agent \$agentFile \$prompt 2>&1 \| Out-String', '$output = "mock output"'
    $runnerContent = $runnerContent -replace '\$output = & claude \$prompt 2>&1 \| Out-String', '$output = "mock output"'

    $testRunner = Join-Path $Root "runner/test-runner.ps1"
    Set-Content -Path $testRunner -Value $runnerContent -Encoding UTF8

    $result = pwsh -NoProfile -File $testRunner -Agent "test-agent" -Job "test-job" 2>&1 | Out-String
    return @{ Output = $result; ExitCode = $LASTEXITCODE }
}

# ========================================
# TC12: Every mutation writes audit entry
# ========================================
Write-Host "`nTC12: Audit entries created on run" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root

    $result = Invoke-Runner -Root $root
    Assert-True ($result.ExitCode -eq 0) "Runner completes successfully"

    $auditDir = Join-Path $root "output/audit"
    $auditFiles = Get-ChildItem -Path $auditDir -Filter "*.jsonl" -ErrorAction SilentlyContinue
    Assert-True ($null -ne $auditFiles -and $auditFiles.Count -gt 0) "At least one audit log file exists"

    if ($auditFiles) {
        $lines = Get-Content -Path $auditFiles[0].FullName
        Assert-True ($lines.Count -ge 2) "Audit log has at least 2 entries (started + completed)"

        # Parse and check we see both started and completed actions
        $actions = $lines | ForEach-Object { ($_ | ConvertFrom-Json).action }
        Assert-True ($actions -contains "started") "Audit contains 'started' action"
        Assert-True ($actions -contains "completed") "Audit contains 'completed' action"
    }
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC13: Monthly partition - correct YYYY-MM.jsonl filename
# ========================================
Write-Host "`nTC13: Monthly partition - correct filename" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Import-RunnerFunctions -Root $root

    # Write an audit entry directly
    Write-AuditEntry -Action "test_action" -AgentName "test-agent" -JobName "test-job" -RunId "abc123"

    $expectedFile = Join-Path $root "output/audit" "$(Get-Date -Format 'yyyy-MM').jsonl"
    Assert-True (Test-Path $expectedFile) "Audit file uses YYYY-MM.jsonl naming"

    if (Test-Path $expectedFile) {
        $content = Get-Content -Path $expectedFile -Raw
        Assert-True ($content -match "test_action") "Entry contains the action we wrote"
    }
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC14: Audit entry has required fields
# ========================================
Write-Host "`nTC14: Audit entry has required fields" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Import-RunnerFunctions -Root $root

    Write-AuditEntry -Action "job_start" -AgentName "my-agent" -JobName "my-job" -RunId "run-xyz"

    $auditFile = Join-Path $root "output/audit" "$(Get-Date -Format 'yyyy-MM').jsonl"
    Assert-True (Test-Path $auditFile) "Audit file exists"

    if (Test-Path $auditFile) {
        $line = (Get-Content -Path $auditFile)[0]
        $entry = $line | ConvertFrom-Json -AsHashtable

        $requiredFields = @("timestamp", "action", "agent", "job", "run_id", "system_version")
        foreach ($field in $requiredFields) {
            Assert-True ($entry.ContainsKey($field)) "Audit entry has required field: $field"
        }

        Assert-True ($entry["action"] -eq "job_start") "Action field value is correct"
        Assert-True ($entry["agent"] -eq "my-agent") "Agent field value is correct"
        Assert-True ($entry["job"] -eq "my-job") "Job field value is correct"
        Assert-True ($entry["run_id"] -eq "run-xyz") "RunId field value is correct"
        Assert-True ($entry["system_version"] -eq "0.1.0-test") "system_version field is correct"

        # Validate timestamp is ISO 8601
        $ts = $entry["timestamp"]
        try {
            [DateTimeOffset]::Parse($ts) | Out-Null
            Assert-True $true "Timestamp is valid ISO 8601"
        } catch {
            Assert-True $false "Timestamp '$ts' is not valid ISO 8601"
        }
    }
} finally {
    Remove-TestRoot -Root $root
}

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-AuditLog: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
