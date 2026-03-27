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

# ========================================
# TC79: Get-AgentStatus skips non-job agent-level metadata
# ========================================
Write-Host "`nTC79: Get-AgentStatus skips errorCount and other agent metadata" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Import-RunnerFunctions -Root $root

    # Write dashboard.json with agent-level metadata (errorCount, lastError)
    # alongside real job entries -- mirrors production dashboard format
    $dashWithMeta = @{
        agents = @{
            "scrum-master" = @{
                "sprint-progress" = @{
                    status = "idle"
                    run_id = "abc123"
                    updated = "2026-03-22T10:00:00Z"
                    runs_completed = 5
                    last_completed = "2026-03-22T10:00:00Z"
                }
                "errorCount" = 0
                "lastError" = "2026-03-21T09:00:00Z"
            }
        }
    }
    $dashFile = Join-Path $root "state/dashboard.json"
    $json = $dashWithMeta | ConvertTo-Json -Depth 10
    Write-AtomicFile -Path $dashFile -Content $json

    # Source Get-AgentStatus.ps1 logic: iterate keys and skip non-hashtable values
    $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable
    $rows = @()
    $errorOccurred = $false

    foreach ($agentName in ($dash["agents"].Keys | Sort-Object)) {
        $agentData = $dash["agents"][$agentName]
        foreach ($jobName in ($agentData.Keys | Sort-Object)) {
            $jobData = $agentData[$jobName]
            # This is the fix under test: skip non-hashtable values
            if ($jobData -isnot [hashtable]) { continue }
            try {
                $status = if ($jobData.ContainsKey("status")) { $jobData["status"] } else { "unknown" }
                $rows += [PSCustomObject]@{
                    Agent  = $agentName
                    Job    = $jobName
                    Status = $status
                }
            } catch {
                $errorOccurred = $true
            }
        }
    }

    Assert-True (-not $errorOccurred) "No errors when iterating dashboard with agent-level metadata"
    Assert-True ($rows.Count -eq 1) "Only 1 job row returned (errorCount and lastError skipped)"
    if ($rows.Count -ge 1) {
        Assert-True ($rows[0].Job -eq "sprint-progress") "Row is for sprint-progress job"
        Assert-True ($rows[0].Status -eq "idle") "Status is idle"
    }
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC80: Repair-StuckDashboard resets "running" entry when lock file is missing
# ========================================
Write-Host "`nTC80: Repair-StuckDashboard resets stuck 'running' entry (no lock file)" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Import-RunnerFunctions -Root $root

    # Inject Repair-StuckDashboard into global scope using the same constants from the test root
    function global:Repair-StuckDashboard {
        if (-not (Test-Path $DASHBOARD_FILE)) { return }
        $dashboard = $null
        try {
            $dashboard = Get-Content -Path $DASHBOARD_FILE -Raw | ConvertFrom-Json -AsHashtable
        } catch { return }
        if ($null -eq $dashboard -or -not $dashboard.ContainsKey("agents")) { return }
        $changed = $false
        foreach ($agentName in @($dashboard["agents"].Keys)) {
            $agentData = $dashboard["agents"][$agentName]
            if ($agentData -isnot [hashtable]) { continue }
            $agentLockFile = Join-Path $STATE_DIR "agents" $agentName "lock"
            foreach ($jobName in @($agentData.Keys)) {
                $jobData = $agentData[$jobName]
                if ($jobData -isnot [hashtable]) { continue }
                if (-not $jobData.ContainsKey("status")) { continue }
                if ($jobData["status"] -ne "running") { continue }
                $lockValid = $false
                if (Test-Path $agentLockFile) {
                    try {
                        $lockRaw = Get-Content -Path $agentLockFile -Raw -ErrorAction SilentlyContinue
                        $lockObj = $lockRaw.Trim() | ConvertFrom-Json
                        if ($null -ne $lockObj.PSObject.Properties['pid']) {
                            $lockPid = [int]$lockObj.pid
                            $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
                            if ($null -ne $proc) { $lockValid = $true }
                        } else {
                            $lockValid = $true
                        }
                    } catch { $lockValid = $false }
                }
                if (-not $lockValid) {
                    $jobData["status"] = "terminated"
                    $jobData["updated"] = (Get-Date -Format "o")
                    $jobData["terminated_at"] = (Get-Date -Format "o")
                    $agentData[$jobName] = $jobData
                    $changed = $true
                }
            }
            $dashboard["agents"][$agentName] = $agentData
        }
        if ($changed) {
            $json = $dashboard | ConvertTo-Json -Depth 10
            Write-AtomicFile -Path $DASHBOARD_FILE -Content $json
        }
    }

    # Set up dashboard with a stuck "running" job (no lock file present)
    Update-Dashboard -AgentName "ghost-agent" -JobName "ghost-job" -Status "running" -Details @{ run_id = "dead123"; started = (Get-Date -Format "o") }

    $dashFile = Join-Path $root "state/dashboard.json"
    $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($dash["agents"]["ghost-agent"]["ghost-job"]["status"] -eq "running") "Pre-condition: status is 'running'"

    # Call Repair-StuckDashboard -- no lock file exists so it should flip to terminated
    Repair-StuckDashboard

    $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($dash["agents"]["ghost-agent"]["ghost-job"]["status"] -eq "terminated") "Status reset to 'terminated' when no lock file"
    Assert-True ($dash["agents"]["ghost-agent"]["ghost-job"].ContainsKey("terminated_at")) "terminated_at field added"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC81: Repair-StuckDashboard does not touch "idle" entries
# ========================================
Write-Host "`nTC81: Repair-StuckDashboard leaves non-running entries alone" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Import-RunnerFunctions -Root $root

    # Re-define Repair-StuckDashboard with the same logic as TC80 above
    function global:Repair-StuckDashboard {
        if (-not (Test-Path $DASHBOARD_FILE)) { return }
        $dashboard = $null
        try {
            $dashboard = Get-Content -Path $DASHBOARD_FILE -Raw | ConvertFrom-Json -AsHashtable
        } catch { return }
        if ($null -eq $dashboard -or -not $dashboard.ContainsKey("agents")) { return }
        $changed = $false
        foreach ($agentName in @($dashboard["agents"].Keys)) {
            $agentData = $dashboard["agents"][$agentName]
            if ($agentData -isnot [hashtable]) { continue }
            $agentLockFile = Join-Path $STATE_DIR "agents" $agentName "lock"
            foreach ($jobName in @($agentData.Keys)) {
                $jobData = $agentData[$jobName]
                if ($jobData -isnot [hashtable]) { continue }
                if (-not $jobData.ContainsKey("status")) { continue }
                if ($jobData["status"] -ne "running") { continue }
                $lockValid = $false
                if (Test-Path $agentLockFile) {
                    try {
                        $lockRaw = Get-Content -Path $agentLockFile -Raw -ErrorAction SilentlyContinue
                        $lockObj = $lockRaw.Trim() | ConvertFrom-Json
                        if ($null -ne $lockObj.PSObject.Properties['pid']) {
                            $lockPid = [int]$lockObj.pid
                            $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
                            if ($null -ne $proc) { $lockValid = $true }
                        } else {
                            $lockValid = $true
                        }
                    } catch { $lockValid = $false }
                }
                if (-not $lockValid) {
                    $jobData["status"] = "terminated"
                    $jobData["updated"] = (Get-Date -Format "o")
                    $jobData["terminated_at"] = (Get-Date -Format "o")
                    $agentData[$jobName] = $jobData
                    $changed = $true
                }
            }
            $dashboard["agents"][$agentName] = $agentData
        }
        if ($changed) {
            $json = $dashboard | ConvertTo-Json -Depth 10
            Write-AtomicFile -Path $DASHBOARD_FILE -Content $json
        }
    }

    # Set up dashboard with an idle job
    Update-Dashboard -AgentName "stable-agent" -JobName "stable-job" -Status "idle" -Details @{ last_completed = (Get-Date -Format "o"); runs_completed = 3 }

    $dashFile = Join-Path $root "state/dashboard.json"
    Repair-StuckDashboard

    $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($dash["agents"]["stable-agent"]["stable-job"]["status"] -eq "idle") "Idle status unchanged by Repair-StuckDashboard"
    Assert-True ($dash["agents"]["stable-agent"]["stable-job"]["runs_completed"] -eq 3) "runs_completed field preserved"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC82: Repair-StuckDashboard keeps "running" when lock file has live PID
# ========================================
Write-Host "`nTC82: Repair-StuckDashboard keeps 'running' when lock file has live PID" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Import-RunnerFunctions -Root $root

    function global:Repair-StuckDashboard {
        if (-not (Test-Path $DASHBOARD_FILE)) { return }
        $dashboard = $null
        try {
            $dashboard = Get-Content -Path $DASHBOARD_FILE -Raw | ConvertFrom-Json -AsHashtable
        } catch { return }
        if ($null -eq $dashboard -or -not $dashboard.ContainsKey("agents")) { return }
        $changed = $false
        foreach ($agentName in @($dashboard["agents"].Keys)) {
            $agentData = $dashboard["agents"][$agentName]
            if ($agentData -isnot [hashtable]) { continue }
            $agentLockFile = Join-Path $STATE_DIR "agents" $agentName "lock"
            foreach ($jobName in @($agentData.Keys)) {
                $jobData = $agentData[$jobName]
                if ($jobData -isnot [hashtable]) { continue }
                if (-not $jobData.ContainsKey("status")) { continue }
                if ($jobData["status"] -ne "running") { continue }
                $lockValid = $false
                if (Test-Path $agentLockFile) {
                    try {
                        $lockRaw = Get-Content -Path $agentLockFile -Raw -ErrorAction SilentlyContinue
                        $lockObj = $lockRaw.Trim() | ConvertFrom-Json
                        if ($null -ne $lockObj.PSObject.Properties['pid']) {
                            $lockPid = [int]$lockObj.pid
                            $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
                            if ($null -ne $proc) { $lockValid = $true }
                        } else {
                            $noPidGraceSeconds = 60
                            $lockTs = $null
                            try { $lockTs = [datetime]$lockObj.ts } catch { }
                            if ($null -ne $lockTs -and ((Get-Date) - $lockTs).TotalSeconds -le $noPidGraceSeconds) {
                                $lockValid = $true
                            }
                        }
                    } catch { $lockValid = $false }
                }
                if (-not $lockValid) {
                    $jobData["status"] = "terminated"
                    $jobData["updated"] = (Get-Date -Format "o")
                    $jobData["terminated_at"] = (Get-Date -Format "o")
                    $agentData[$jobName] = $jobData
                    $changed = $true
                }
            }
            $dashboard["agents"][$agentName] = $agentData
        }
        if ($changed) {
            $json = $dashboard | ConvertTo-Json -Depth 10
            Write-AtomicFile -Path $DASHBOARD_FILE -Content $json
        }
    }

    # Use the current process PID -- it is definitely alive
    $livePid = $PID
    $agentStateDir = Join-Path $root "state/agents/live-agent"
    New-Item -ItemType Directory -Path $agentStateDir -Force | Out-Null
    $lockFile = Join-Path $agentStateDir "lock"
    $lockContent = @{ ts = (Get-Date -Format "o"); job = "live-job"; pid = $livePid; run_id = "abc999" } | ConvertTo-Json -Compress
    Set-Content -Path $lockFile -Value $lockContent -Encoding ASCII

    Update-Dashboard -AgentName "live-agent" -JobName "live-job" -Status "running" -Details @{ run_id = "abc999" }

    $dashFile = Join-Path $root "state/dashboard.json"
    Repair-StuckDashboard

    $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($dash["agents"]["live-agent"]["live-job"]["status"] -eq "running") "Status stays 'running' when lock file has live PID"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC83: Repair-StuckDashboard keeps "running" when lock has no PID but is recent (within grace)
# ========================================
Write-Host "`nTC83: Repair-StuckDashboard keeps 'running' when no-PID lock is within 60s grace" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Import-RunnerFunctions -Root $root

    function global:Repair-StuckDashboard {
        if (-not (Test-Path $DASHBOARD_FILE)) { return }
        $dashboard = $null
        try {
            $dashboard = Get-Content -Path $DASHBOARD_FILE -Raw | ConvertFrom-Json -AsHashtable
        } catch { return }
        if ($null -eq $dashboard -or -not $dashboard.ContainsKey("agents")) { return }
        $changed = $false
        foreach ($agentName in @($dashboard["agents"].Keys)) {
            $agentData = $dashboard["agents"][$agentName]
            if ($agentData -isnot [hashtable]) { continue }
            $agentLockFile = Join-Path $STATE_DIR "agents" $agentName "lock"
            foreach ($jobName in @($agentData.Keys)) {
                $jobData = $agentData[$jobName]
                if ($jobData -isnot [hashtable]) { continue }
                if (-not $jobData.ContainsKey("status")) { continue }
                if ($jobData["status"] -ne "running") { continue }
                $lockValid = $false
                if (Test-Path $agentLockFile) {
                    try {
                        $lockRaw = Get-Content -Path $agentLockFile -Raw -ErrorAction SilentlyContinue
                        $lockObj = $lockRaw.Trim() | ConvertFrom-Json
                        if ($null -ne $lockObj.PSObject.Properties['pid']) {
                            $lockPid = [int]$lockObj.pid
                            $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
                            if ($null -ne $proc) { $lockValid = $true }
                        } else {
                            $noPidGraceSeconds = 60
                            $lockTs = $null
                            try { $lockTs = [datetime]$lockObj.ts } catch { }
                            if ($null -ne $lockTs -and ((Get-Date) - $lockTs).TotalSeconds -le $noPidGraceSeconds) {
                                $lockValid = $true
                            }
                        }
                    } catch { $lockValid = $false }
                }
                if (-not $lockValid) {
                    $jobData["status"] = "terminated"
                    $jobData["updated"] = (Get-Date -Format "o")
                    $jobData["terminated_at"] = (Get-Date -Format "o")
                    $agentData[$jobName] = $jobData
                    $changed = $true
                }
            }
            $dashboard["agents"][$agentName] = $agentData
        }
        if ($changed) {
            $json = $dashboard | ConvertTo-Json -Depth 10
            Write-AtomicFile -Path $DASHBOARD_FILE -Content $json
        }
    }

    # Lock written just now, no PID (process is still starting)
    $agentStateDir = Join-Path $root "state/agents/starting-agent"
    New-Item -ItemType Directory -Path $agentStateDir -Force | Out-Null
    $lockFile = Join-Path $agentStateDir "lock"
    $recentTs = (Get-Date).AddSeconds(-5).ToString("o")
    $lockContent = @{ ts = $recentTs; job = "start-job" } | ConvertTo-Json -Compress
    Set-Content -Path $lockFile -Value $lockContent -Encoding ASCII

    Update-Dashboard -AgentName "starting-agent" -JobName "start-job" -Status "running" -Details @{ run_id = "grace01" }

    $dashFile = Join-Path $root "state/dashboard.json"
    Repair-StuckDashboard

    $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($dash["agents"]["starting-agent"]["start-job"]["status"] -eq "running") "Status stays 'running' when no-PID lock is recent (within grace)"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC84: Repair-StuckDashboard resets "running" when lock has no PID and is older than grace
# ========================================
Write-Host "`nTC84: Repair-StuckDashboard resets to 'terminated' when no-PID lock is stale (over 60s)" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Import-RunnerFunctions -Root $root

    function global:Repair-StuckDashboard {
        if (-not (Test-Path $DASHBOARD_FILE)) { return }
        $dashboard = $null
        try {
            $dashboard = Get-Content -Path $DASHBOARD_FILE -Raw | ConvertFrom-Json -AsHashtable
        } catch { return }
        if ($null -eq $dashboard -or -not $dashboard.ContainsKey("agents")) { return }
        $changed = $false
        foreach ($agentName in @($dashboard["agents"].Keys)) {
            $agentData = $dashboard["agents"][$agentName]
            if ($agentData -isnot [hashtable]) { continue }
            $agentLockFile = Join-Path $STATE_DIR "agents" $agentName "lock"
            foreach ($jobName in @($agentData.Keys)) {
                $jobData = $agentData[$jobName]
                if ($jobData -isnot [hashtable]) { continue }
                if (-not $jobData.ContainsKey("status")) { continue }
                if ($jobData["status"] -ne "running") { continue }
                $lockValid = $false
                if (Test-Path $agentLockFile) {
                    try {
                        $lockRaw = Get-Content -Path $agentLockFile -Raw -ErrorAction SilentlyContinue
                        $lockObj = $lockRaw.Trim() | ConvertFrom-Json
                        if ($null -ne $lockObj.PSObject.Properties['pid']) {
                            $lockPid = [int]$lockObj.pid
                            $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
                            if ($null -ne $proc) { $lockValid = $true }
                        } else {
                            $noPidGraceSeconds = 60
                            $lockTs = $null
                            try { $lockTs = [datetime]$lockObj.ts } catch { }
                            if ($null -ne $lockTs -and ((Get-Date) - $lockTs).TotalSeconds -le $noPidGraceSeconds) {
                                $lockValid = $true
                            }
                        }
                    } catch { $lockValid = $false }
                }
                if (-not $lockValid) {
                    $jobData["status"] = "terminated"
                    $jobData["updated"] = (Get-Date -Format "o")
                    $jobData["terminated_at"] = (Get-Date -Format "o")
                    $agentData[$jobName] = $jobData
                    $changed = $true
                }
            }
            $dashboard["agents"][$agentName] = $agentData
        }
        if ($changed) {
            $json = $dashboard | ConvertTo-Json -Depth 10
            Write-AtomicFile -Path $DASHBOARD_FILE -Content $json
        }
    }

    # Lock written 90 minutes ago, no PID (process never started)
    $agentStateDir = Join-Path $root "state/agents/stuck-agent"
    New-Item -ItemType Directory -Path $agentStateDir -Force | Out-Null
    $lockFile = Join-Path $agentStateDir "lock"
    $staleTs = (Get-Date).AddMinutes(-90).ToString("o")
    $lockContent = @{ ts = $staleTs; job = "stuck-job" } | ConvertTo-Json -Compress
    Set-Content -Path $lockFile -Value $lockContent -Encoding ASCII

    Update-Dashboard -AgentName "stuck-agent" -JobName "stuck-job" -Status "running" -Details @{ run_id = "stale01" }

    $dashFile = Join-Path $root "state/dashboard.json"
    Repair-StuckDashboard

    $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($dash["agents"]["stuck-agent"]["stuck-job"]["status"] -eq "terminated") "Status reset to 'terminated' when no-PID lock is stale"
    Assert-True ($dash["agents"]["stuck-agent"]["stuck-job"].ContainsKey("terminated_at")) "terminated_at field added for stale no-PID lock"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC85: Live dashboard.json is valid JSON
# ========================================
Write-Host "`nTC85: Live dashboard.json is valid JSON" -ForegroundColor Cyan

$LiveProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $LiveProjectRoot "config/agents.json"))) {
    $LiveProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$LiveDashboardFile = Join-Path $LiveProjectRoot "state/dashboard.json"
$LiveAgentsFile = Join-Path $LiveProjectRoot "config/agents.json"

if (Test-Path $LiveDashboardFile) {
    $dashParseOk = $true
    $liveDash = $null
    try {
        $liveDash = Get-Content -Path $LiveDashboardFile -Raw | ConvertFrom-Json -AsHashtable
    } catch {
        $dashParseOk = $false
    }
    Assert-True $dashParseOk "dashboard.json is valid JSON"
} else {
    Write-Host "  [SKIP] dashboard.json not found (no live state)" -ForegroundColor Yellow
}

# ========================================
# TC86: No stale agent keys in dashboard that don't exist in agents.json
# ========================================
Write-Host "`nTC86: No stale agent keys in dashboard" -ForegroundColor Cyan

if ((Test-Path $LiveDashboardFile) -and (Test-Path $LiveAgentsFile)) {
    if ($null -eq $liveDash) {
        $liveDash = Get-Content -Path $LiveDashboardFile -Raw | ConvertFrom-Json -AsHashtable
    }
    $liveAgentsRaw = Get-Content -Path $LiveAgentsFile -Raw | ConvertFrom-Json -AsHashtable
    $liveAgents = if ($liveAgentsRaw.ContainsKey("agents")) { $liveAgentsRaw["agents"] } else { $liveAgentsRaw }

    $staleFound = $false
    if ($liveDash.ContainsKey("agents")) {
        foreach ($dashAgent in $liveDash["agents"].Keys) {
            if (-not $liveAgents.ContainsKey($dashAgent)) {
                $staleFound = $true
                Write-Host "    Stale agent in dashboard: '$dashAgent'" -ForegroundColor Yellow
            }
        }
    }
    Assert-True (-not $staleFound) "No agent keys in dashboard.json that are missing from agents.json"
} else {
    Write-Host "  [SKIP] dashboard.json or agents.json not found" -ForegroundColor Yellow
}

# ========================================
# TC87: All "running" entries have valid lock files with live PIDs (or should be "terminated")
# ========================================
Write-Host "`nTC87: All 'running' entries have valid lock files" -ForegroundColor Cyan

if ((Test-Path $LiveDashboardFile)) {
    if ($null -eq $liveDash) {
        $liveDash = Get-Content -Path $LiveDashboardFile -Raw | ConvertFrom-Json -AsHashtable
    }
    $LiveStateDir = Join-Path $LiveProjectRoot "state"
    $runningWithoutLock = $false

    if ($liveDash.ContainsKey("agents")) {
        foreach ($agentName in $liveDash["agents"].Keys) {
            $agentData = $liveDash["agents"][$agentName]
            if ($agentData -isnot [hashtable]) { continue }
            foreach ($jobName in $agentData.Keys) {
                $jobData = $agentData[$jobName]
                if ($jobData -isnot [hashtable]) { continue }
                if (-not $jobData.ContainsKey("status")) { continue }
                if ($jobData["status"] -ne "running") { continue }

                # Check lock file
                $lockFile = Join-Path $LiveStateDir "agents" $agentName "lock"
                if (-not (Test-Path $lockFile)) {
                    $runningWithoutLock = $true
                    Write-Host "    Running entry '$agentName/$jobName' has no lock file" -ForegroundColor Yellow
                } else {
                    # Validate PID in lock file
                    try {
                        $lockRaw = Get-Content -Path $lockFile -Raw -ErrorAction SilentlyContinue
                        $lockObj = $lockRaw.Trim() | ConvertFrom-Json
                        if ($null -ne $lockObj.PSObject.Properties['pid']) {
                            $lockPid = [int]$lockObj.pid
                            $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
                            if ($null -eq $proc) {
                                $runningWithoutLock = $true
                                Write-Host "    Running entry '$agentName/$jobName' has dead PID $lockPid in lock file" -ForegroundColor Yellow
                            }
                        }
                    } catch {
                        # Lock file is malformed but exists -- not necessarily invalid during startup
                    }
                }
            }
        }
    }
    Assert-True (-not $runningWithoutLock) "All 'running' dashboard entries have valid lock files with live PIDs"
} else {
    Write-Host "  [SKIP] dashboard.json not found" -ForegroundColor Yellow
}

# ========================================
# TC88: No legacy agent names (memo-checker) in dashboard state
# ========================================
Write-Host "`nTC88: No legacy agent names in dashboard state" -ForegroundColor Cyan

if ((Test-Path $LiveDashboardFile)) {
    if ($null -eq $liveDash) {
        $liveDash = Get-Content -Path $LiveDashboardFile -Raw | ConvertFrom-Json -AsHashtable
    }
    $legacyFound = $false
    $legacyNames = @("memo-checker")
    if ($liveDash.ContainsKey("agents")) {
        foreach ($agentName in $liveDash["agents"].Keys) {
            if ($legacyNames -contains $agentName) {
                $legacyFound = $true
                Write-Host "    Legacy agent name in dashboard: '$agentName'" -ForegroundColor Yellow
            }
        }
    }
    Assert-True (-not $legacyFound) "No legacy agent names (memo-checker) in dashboard.json"
} else {
    Write-Host "  [SKIP] dashboard.json not found" -ForegroundColor Yellow
}

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-DashboardState: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
