#Requires -Version 7.0
# Test-DashboardState.ps1 -- Tests for dashboard.json state management
# Run: pwsh -File tests/Test-DashboardState.ps1

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
`$global:SYSTEM_VERSION = "0.1.0-test"
`$global:PROJECT_ROOT = "$($Root -replace '\\', '\\')"
`$global:CONFIG_DIR = Join-Path `$PROJECT_ROOT "config"
`$global:STATE_DIR = Join-Path `$PROJECT_ROOT "state"
`$global:OUTPUT_DIR = Join-Path `$PROJECT_ROOT "output"
`$global:AUDIT_DIR = Join-Path `$OUTPUT_DIR "audit"
`$global:EVENTS_FILE = Join-Path `$STATE_DIR "events.jsonl"
`$global:DASHBOARD_FILE = Join-Path `$STATE_DIR "dashboard.json"
"@
    Set-Content -Path (Join-Path $Root "runner/constants.ps1") -Value $content -Encoding ASCII
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
}

# ========================================
# TC22: Dashboard reflects status after a simulated run
# ========================================
Write-Host "`nTC22: Dashboard reflects status after run" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Import-RunnerFunctions -Root $root

    # Simulate a run lifecycle: running -> idle
    Update-Dashboard -AgentName "test-agent" -JobName "test-job" -Status "running" -Details @{ run_id = "abc123"; started = (Get-Date -Format "o") }

    $dashFile = Join-Path $root "state/dashboard.json"
    Assert-True (Test-Path $dashFile) "Dashboard file created after Update-Dashboard"

    $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($dash["agents"]["test-agent"]["test-job"]["status"] -eq "running") "Status is 'running' mid-job"
    Assert-True ($dash["agents"]["test-agent"]["test-job"]["run_id"] -eq "abc123") "run_id is captured"

    # Now update to idle
    Update-Dashboard -AgentName "test-agent" -JobName "test-job" -Status "idle" -Details @{ last_completed = (Get-Date -Format "o") }

    $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($dash["agents"]["test-agent"]["test-job"]["status"] -eq "idle") "Status updated to 'idle'"
    Assert-True ($dash["agents"]["test-agent"]["test-job"].ContainsKey("last_completed")) "last_completed field present"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC23: Multi-agent - updating agent A does not affect agent B
# ========================================
Write-Host "`nTC23: Multi-agent isolation" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Import-RunnerFunctions -Root $root

    # Set up agent A
    Update-Dashboard -AgentName "agent-a" -JobName "job-1" -Status "running" -Details @{ run_id = "run-a" }

    # Set up agent B
    Update-Dashboard -AgentName "agent-b" -JobName "job-2" -Status "idle" -Details @{ run_id = "run-b" }

    $dashFile = Join-Path $root "state/dashboard.json"
    $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable

    Assert-True ($dash["agents"]["agent-a"]["job-1"]["status"] -eq "running") "Agent A is running"
    Assert-True ($dash["agents"]["agent-b"]["job-2"]["status"] -eq "idle") "Agent B is idle"

    # Now update agent A to error -- agent B should remain idle
    Update-Dashboard -AgentName "agent-a" -JobName "job-1" -Status "error" -Details @{ error = "something broke" }

    $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($dash["agents"]["agent-a"]["job-1"]["status"] -eq "error") "Agent A updated to error"
    Assert-True ($dash["agents"]["agent-b"]["job-2"]["status"] -eq "idle") "Agent B still idle (unaffected)"
    Assert-True ($dash["agents"]["agent-b"]["job-2"]["run_id"] -eq "run-b") "Agent B run_id preserved"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC24: Empty state - first run initializes dashboard.json
# ========================================
Write-Host "`nTC24: Empty state - first run initializes dashboard" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Import-RunnerFunctions -Root $root

    $dashFile = Join-Path $root "state/dashboard.json"
    Assert-True (-not (Test-Path $dashFile)) "Dashboard file does not exist initially"

    # First update creates the file from scratch
    Update-Dashboard -AgentName "fresh-agent" -JobName "first-job" -Status "running" -Details @{ run_id = "first-run" }

    Assert-True (Test-Path $dashFile) "Dashboard file was created"

    $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($dash.ContainsKey("agents")) "Root 'agents' key exists"
    Assert-True ($dash["agents"].ContainsKey("fresh-agent")) "Agent entry was created"
    Assert-True ($dash["agents"]["fresh-agent"].ContainsKey("first-job")) "Job entry was created"
    Assert-True ($dash["agents"]["fresh-agent"]["first-job"]["status"] -eq "running") "Status is running"
    Assert-True ($dash["agents"]["fresh-agent"]["first-job"]["run_id"] -eq "first-run") "run_id is correct"
    Assert-True ($dash["agents"]["fresh-agent"]["first-job"].ContainsKey("updated")) "updated timestamp present"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC52: Dashboard flat job format has status field
# ========================================
Write-Host "`nTC52: Dashboard flat job format has status field" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Import-RunnerFunctions -Root $root

    # Write dashboard.json with flat format (job data directly on agent, no "jobs" wrapper)
    $flatDash = @{
        agents = @{
            "scrum-master" = @{
                "dry-run-bug-autopilot" = @{
                    status = "running"
                    run_id = "abc123"
                    started = "2026-03-15T10:00:00Z"
                    updated = "2026-03-15T10:00:00Z"
                }
            }
        }
    }
    $dashFile = Join-Path $root "state/dashboard.json"
    $json = $flatDash | ConvertTo-Json -Depth 10
    Write-AtomicFile -Path $dashFile -Content $json

    $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable
    $jobEntry = $dash["agents"]["scrum-master"]["dry-run-bug-autopilot"]

    Assert-True ($null -ne $jobEntry) "Flat job entry exists on agent object"
    Assert-True ($jobEntry.ContainsKey("status")) "Flat job entry has 'status' field"

    $validStatuses = @("running", "idle", "completed", "error")
    $statusIsValid = $validStatuses -contains $jobEntry["status"]
    Assert-True $statusIsValid "Status value '$($jobEntry["status"])' is one of: running, idle, completed, error"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC53: Dashboard flat format includes run_id
# ========================================
Write-Host "`nTC53: Dashboard flat format includes run_id" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Import-RunnerFunctions -Root $root

    # Write dashboard.json with flat format
    $flatDash = @{
        agents = @{
            "scrum-master" = @{
                "dry-run-bug-autopilot" = @{
                    status = "running"
                    run_id = "def456"
                    started = "2026-03-15T10:00:00Z"
                    updated = "2026-03-15T10:00:00Z"
                }
            }
        }
    }
    $dashFile = Join-Path $root "state/dashboard.json"
    $json = $flatDash | ConvertTo-Json -Depth 10
    Write-AtomicFile -Path $dashFile -Content $json

    $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable
    $jobEntry = $dash["agents"]["scrum-master"]["dry-run-bug-autopilot"]

    Assert-True ($jobEntry.ContainsKey("run_id")) "Flat job entry has 'run_id' field"
    Assert-True ($jobEntry["run_id"] -eq "def456") "run_id value is correct"
} finally {
    Remove-TestRoot -Root $root
}

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-DashboardState: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
