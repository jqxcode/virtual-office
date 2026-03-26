#Requires -Version 7.0
<#
.SYNOPSIS
    Invokes a Virtual Office agent job.
.DESCRIPTION
    Runs a configured agent job with locking, queueing, auditing, and dashboard updates.
.PARAMETER Agent
    The agent name (must exist in config/agents.json).
.PARAMETER Job
    The job name (must exist in config/jobs/{agent}.json and be enabled).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Agent,

    [Parameter(Mandatory)]
    [string]$Job
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Source constants ---
. (Join-Path $PSScriptRoot "constants.ps1")

# --- Helper functions ---

function Write-AtomicFile {
    param(
        [string]$Path,
        [string]$Content,
        [System.Text.Encoding]$Encoding = $null
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmpPath = "$Path.tmp"
    if ($Encoding) {
        [System.IO.File]::WriteAllText($tmpPath, $Content, $Encoding)
    } else {
        [System.IO.File]::WriteAllText($tmpPath, $Content)
    }
    Move-Item -Path $tmpPath -Destination $Path -Force
}

function Write-AuditEntry {
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

function Write-Event {
    param(
        [string]$AgentName,
        [string]$JobName,
        [string]$Event,
        [hashtable]$Details = @{}
    )
    $dir = Split-Path -Parent $EVENTS_FILE
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $entry = @{
        timestamp = (Get-Date -Format "o")
        agent     = $AgentName
        job       = $JobName
        event     = $Event
        details   = $Details
    } | ConvertTo-Json -Compress
    Add-Content -Path $EVENTS_FILE -Value $entry -Encoding UTF8
}

function Update-Dashboard {
    param(
        [string]$AgentName,
        [string]$JobName,
        [string]$Status,
        [hashtable]$Details = @{},
        [hashtable]$AgentDetails = @{}
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

    # Apply agent-level details (errorCount, lastError, etc.)
    foreach ($key in $AgentDetails.Keys) {
        $dashboard["agents"][$AgentName][$key] = $AgentDetails[$key]
    }

    $json = $dashboard | ConvertTo-Json -Depth 10
    Write-AtomicFile -Path $DASHBOARD_FILE -Content $json
}

function Write-ErrorEntry {
    param(
        [string]$Agent,
        [string]$Job,
        [string]$RunId,
        [string]$Level,
        [string]$Summary,
        [string]$Detail,
        [string]$LogPath,
        [int]$ExitCode,
        [string]$Duration
    )
    $dir = Split-Path -Parent $ERRORS_FILE
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $truncatedDetail = $Detail
    if ($Detail.Length -gt 500) {
        $truncatedDetail = $Detail.Substring(0, 500)
    }
    $entry = @{
        ts            = (Get-Date -Format "o")
        agent         = $Agent
        job           = $Job
        runId         = $RunId
        level         = $Level
        summary       = $Summary
        detail        = $truncatedDetail
        logPath       = $LogPath
        exitCode      = $ExitCode
        duration      = $Duration
        resolved      = $false
        systemVersion = $SYSTEM_VERSION
    }
    $line = $entry | ConvertTo-Json -Compress
    Add-Content -Path $ERRORS_FILE -Value $line -Encoding ASCII
}

function Repair-StuckDashboard {
    # Scan dashboard for any job showing "running" and validate via lock file + PID.
    # If no lock file exists or the PID is dead, reset status to "terminated".
    # Called once at startup so stale "running" entries left by killed processes are cleared
    # before the current invocation writes its own "running" entry.
    if (-not (Test-Path $DASHBOARD_FILE)) { return }

    $dashboard = $null
    try {
        $dashboard = Get-Content -Path $DASHBOARD_FILE -Raw | ConvertFrom-Json -AsHashtable
    } catch {
        return
    }
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

            # Job is marked running -- validate the lock file
            $lockValid = $false
            if (Test-Path $agentLockFile) {
                try {
                    $lockRaw = Get-Content -Path $agentLockFile -Raw -ErrorAction SilentlyContinue
                    $lockObj = $lockRaw.Trim() | ConvertFrom-Json
                    if ($null -ne $lockObj.PSObject.Properties['pid']) {
                        $lockPid = [int]$lockObj.pid
                        $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
                        if ($null -ne $proc) {
                            $lockValid = $true
                        }
                    } else {
                        # Lock exists but has no PID yet (race between lock write and PID update)
                        # Allow a 60-second grace period for the process to start and update the lock.
                        # After that, treat the no-PID lock as stale -- the process never started.
                        $noPidGraceSeconds = 60
                        $lockTs = $null
                        try { $lockTs = [datetime]$lockObj.ts } catch { }
                        if ($null -ne $lockTs -and ((Get-Date) - $lockTs).TotalSeconds -le $noPidGraceSeconds) {
                            $lockValid = $true
                        }
                        # else: lock older than grace period with no PID -- treat as stale
                    }
                } catch {
                    # Malformed lock file -- treat as invalid
                    $lockValid = $false
                }
            }

            if (-not $lockValid) {
                # No lock file or dead PID -- reset to terminated
                $jobData["status"] = "terminated"
                $jobData["updated"] = (Get-Date -Format "o")
                $jobData["terminated_at"] = (Get-Date -Format "o")
                $agentData[$jobName] = $jobData
                $changed = $true
                Write-Host "Reconcile: '$agentName/$jobName' was stuck 'running' with no live process -- reset to 'terminated'."
            }
        }
        $dashboard["agents"][$agentName] = $agentData
    }

    if ($changed) {
        $json = $dashboard | ConvertTo-Json -Depth 10
        Write-AtomicFile -Path $DASHBOARD_FILE -Content $json
    }
}

function Get-UnresolvedErrorCount {
    param([string]$AgentName)
    if (-not (Test-Path $ERRORS_FILE)) { return 0 }
    $count = 0
    foreach ($line in (Get-Content -Path $ERRORS_FILE)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "") { continue }
        try {
            $obj = $trimmed | ConvertFrom-Json
            if ($obj.agent -eq $AgentName -and $obj.resolved -eq $false) {
                $count++
            }
        } catch {
            # Skip malformed lines
        }
    }
    return $count
}

function Ensure-StateDir {
    param(
        [string]$AgentName,
        [string]$JobName
    )
    $dir = Join-Path $STATE_DIR "agents" $AgentName $JobName
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-QueueDepth {
    param([string]$QueueFile)
    if (-not (Test-Path $QueueFile)) { return 0 }
    $val = (Get-Content -Path $QueueFile -Raw).Trim()
    if ($val -match '^\d+$') { return [int]$val }
    return 0
}

function Set-QueueDepth {
    param([string]$QueueFile, [int]$Depth)
    if ($Depth -le 0) {
        if (Test-Path $QueueFile) { Remove-Item -Path $QueueFile -Force }
    } else {
        Write-AtomicFile -Path $QueueFile -Content "$Depth"
    }
}

# --- Main flow ---

# Step 1: Reconcile any dashboard entries stuck on "running" from a prior killed process.
# Must run before agent config is loaded so it runs even for agents that have no active lock.
Repair-StuckDashboard

# Step 2: Load and validate agent config
$agentsFile = Join-Path $CONFIG_DIR "agents.json"
if (-not (Test-Path $agentsFile)) {
    Write-Error "Config file not found: $agentsFile"
    exit 1
}
$agentsConfigRaw = Get-Content -Path $agentsFile -Raw | ConvertFrom-Json -AsHashtable
$agentsConfig = if ($agentsConfigRaw.ContainsKey("agents")) { $agentsConfigRaw["agents"] } else { $agentsConfigRaw }
if (-not $agentsConfig.ContainsKey($Agent)) {
    Write-Error "Agent '$Agent' not found in agents.json. Available: $($agentsConfig.Keys -join ', ')"
    exit 1
}

# Step 3: Load and validate job config
$jobsFile = Join-Path $CONFIG_DIR "jobs" "$Agent.json"
if (-not (Test-Path $jobsFile)) {
    Write-Error "Jobs file not found: $jobsFile"
    exit 1
}
$jobsConfigRaw = Get-Content -Path $jobsFile -Raw | ConvertFrom-Json -AsHashtable
$jobsConfig = if ($jobsConfigRaw.ContainsKey("jobs")) { $jobsConfigRaw["jobs"] } else { $jobsConfigRaw }
if (-not $jobsConfig.ContainsKey($Job)) {
    Write-Error "Job '$Job' not found in $jobsFile. Available: $($jobsConfig.Keys -join ', ')"
    exit 1
}
$jobDef = $jobsConfig[$Job]
if ($jobDef.ContainsKey("enabled") -and -not $jobDef["enabled"]) {
    Write-Host "Job '$Job' for agent '$Agent' is disabled. Skipping."
    exit 0
}

$prompt = $jobDef["prompt"]
if (-not $prompt) {
    Write-Error "Job '$Job' has no prompt defined."
    exit 1
}

# Ensure state directory
$stateDir = Ensure-StateDir -AgentName $Agent -JobName $Job
$queueFile = Join-Path $stateDir "queue"
$counterFile = Join-Path $stateDir "counter.json"

# Step 4: Agent-level lock -- only one job per agent at a time
$agentStateDir = Join-Path $STATE_DIR "agents" $Agent
if (-not (Test-Path $agentStateDir)) {
    New-Item -ItemType Directory -Path $agentStateDir -Force | Out-Null
}
$lockFile = Join-Path $agentStateDir "lock"

$staleLockTimeout = $DEFAULT_STALE_LOCK_TIMEOUT_MINUTES
if ($agentsConfig[$Agent].ContainsKey("staleLockTimeoutMinutes")) {
    $staleLockTimeout = [int]$agentsConfig[$Agent]["staleLockTimeoutMinutes"]
}

if (Test-Path $lockFile) {
    $lockContent = Get-Content -Path $lockFile -Raw -ErrorAction SilentlyContinue
    $lockAge = $null
    $lockedByJob = "unknown"
    try {
        $parsed = $lockContent.Trim() | ConvertFrom-Json
        $lockTime = [DateTime]::Parse($parsed.ts)
        $lockAge = (Get-Date) - $lockTime
        $lockedByJob = $parsed.job
    } catch {
        $lockAge = [TimeSpan]::FromMinutes($staleLockTimeout + 1)
    }

    if ($lockAge -and $lockAge.TotalMinutes -gt $staleLockTimeout) {
        # Stale lock -- force clear
        Remove-Item -Path $lockFile -Force
        Write-Event -AgentName $Agent -JobName $Job -Event "stale_lock_cleared" -Details @{
            locked_by_job = $lockedByJob
            lock_age_minutes = [math]::Round($lockAge.TotalMinutes)
            timeout_minutes = $staleLockTimeout
        }
        Write-AuditEntry -Action "stale_lock_cleared" -AgentName $Agent -JobName $Job -RunId "N/A" -Details @{
            locked_by_job = $lockedByJob
            lock_age_minutes = [math]::Round($lockAge.TotalMinutes)
        }
        Write-Host "Stale lock cleared for '$Agent' (was held by '$lockedByJob', age: $([math]::Round($lockAge.TotalMinutes))m, timeout: ${staleLockTimeout}m)."
    } else {
        # Agent is busy -- queue this job
        $depth = Get-QueueDepth -QueueFile $queueFile
        $depth++
        Set-QueueDepth -QueueFile $queueFile -Depth $depth
        Write-Host "Agent '$Agent' is busy (running '$lockedByJob'). Queued '$Job' (depth: $depth)."
        Write-AuditEntry -Action "queued" -AgentName $Agent -JobName $Job -RunId "" -Details @{ queue_depth = $depth; locked_by_job = $lockedByJob }
        Write-Event -AgentName $Agent -JobName $Job -Event "queued" -Details @{ queue_depth = $depth; locked_by_job = $lockedByJob }
        Update-Dashboard -AgentName $Agent -JobName $Job -Status "queued" -Details @{ queue_depth = $depth; blocked_by = $lockedByJob }
        exit 0
    }
}

# --- Run loop (handles queue drain) ---
$keepRunning = $true
while ($keepRunning) {
    # Create agent-level lock (pid added after process starts)
    $lockContent = @{ ts = (Get-Date -Format "o"); job = $Job } | ConvertTo-Json -Compress
    Write-AtomicFile -Path $lockFile -Content $lockContent

    # Step 5: Check counter / maxRuns
    $maxRuns = 0
    if ($jobDef.ContainsKey("maxRuns")) { $maxRuns = [int]$jobDef["maxRuns"] }

    $counter = @{ count = 0 }
    if (Test-Path $counterFile) {
        try {
            $counter = Get-Content -Path $counterFile -Raw | ConvertFrom-Json -AsHashtable
        } catch {
            $counter = @{ count = 0 }
        }
    }

    if ($maxRuns -gt 0 -and $counter["count"] -ge $maxRuns) {
        Write-Host "Job '$Job' for agent '$Agent' has reached maxRuns ($maxRuns). Skipping."
        if (Test-Path $lockFile) { Remove-Item -Path $lockFile -Force }
        Write-AuditEntry -Action "skipped_max_runs" -AgentName $Agent -JobName $Job -RunId "" -Details @{ count = $counter["count"]; maxRuns = $maxRuns }
        break
    }

    # Step 6: Generate run_id
    $runId = -join ((1..8) | ForEach-Object { "{0:x}" -f (Get-Random -Maximum 16) })

    # Step 7: Write audit/event/dashboard for start
    Write-AuditEntry -Action "started" -AgentName $Agent -JobName $Job -RunId $runId
    Write-Event -AgentName $Agent -JobName $Job -Event "started" -Details @{ run_id = $runId }
    Update-Dashboard -AgentName $Agent -JobName $Job -Status "running" -Details @{ run_id = $runId; started = (Get-Date -Format "o") }

    # Step 8: Invoke claude
    $agentDef = $agentsConfig[$Agent]
    $agentFile = $null
    if ($agentDef.ContainsKey("agentFile")) {
        $rawPath = $agentDef["agentFile"]
        if ($rawPath.StartsWith("~/")) {
            $agentFile = Join-Path $HOME $rawPath.Substring(2)
        } else {
            $agentFile = Join-Path $PROJECT_ROOT $rawPath
        }
    }

    $output = ""
    $exitCode = 0
    $runStart = Get-Date
    try {
        # Build command arguments
        $claudeArgs = @()
        if ($agentFile -and (Test-Path $agentFile)) {
            $claudeArgs = @("--agent", $agentFile, $prompt)
        } else {
            $claudeArgs = @($prompt)
        }

        # Start claude process and capture PID
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = "claude"
        $pinfo.Arguments = ($claudeArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join " "
        $pinfo.RedirectStandardOutput = $true
        $pinfo.RedirectStandardError = $true
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($pinfo)

        # Update lock with PID
        $lockContent = @{ ts = (Get-Date -Format "o"); job = $Job; pid = $proc.Id; run_id = $runId } | ConvertTo-Json -Compress
        Write-AtomicFile -Path $lockFile -Content $lockContent

        $output = $proc.StandardOutput.ReadToEnd()
        $errOutput = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode

        if ($errOutput) {
            $output = $output + "`n" + $errOutput
        }
    } catch {
        $output = "ERROR: $_"
        $exitCode = 1
    }
    $runEnd = Get-Date
    $runDuration = "{0}s" -f [math]::Round(($runEnd - $runStart).TotalSeconds)

    # Step 8b: Track errors if non-zero exit
    if ($exitCode -ne 0) {
        $errorLevel = "error"
        if ($output.Length -gt 0 -and $output -notmatch "^ERROR:") {
            $errorLevel = "warning"
        }
        $relLogPath = "output/$Agent/$Job-$(Get-Date -Format 'yyyyMMdd-HHmmss').md"
        Write-ErrorEntry -Agent $Agent -Job $Job -RunId $runId `
            -Level $errorLevel `
            -Summary "Claude CLI exited with code $exitCode" `
            -Detail $output `
            -LogPath $relLogPath `
            -ExitCode $exitCode `
            -Duration $runDuration
    }

    # Step 9: Save output (skip if saveOutput is false in job config)
    $saveOutput = -not ($jobDef.ContainsKey("saveOutput") -and $jobDef["saveOutput"] -eq $false)
    $outputAgentDir = Join-Path $OUTPUT_DIR $Agent
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $outputFile = $null
    $relOutputPath = $null
    if ($saveOutput) {
        if (-not (Test-Path $outputAgentDir)) {
            New-Item -ItemType Directory -Path $outputAgentDir -Force | Out-Null
        }
        $outputFile = Join-Path $outputAgentDir "$Job-$timestamp.md"
        $latestFile = Join-Path $outputAgentDir "$Job-latest.md"
        Write-AtomicFile -Path $outputFile -Content $output -Encoding ([System.Text.Encoding]::UTF8)
        Write-AtomicFile -Path $latestFile -Content $output -Encoding ([System.Text.Encoding]::UTF8)
        $relOutputPath = "output/$Agent/$Job-$timestamp.md"
    }

    # Step 9b: Find the latest HTML report if runner output was not saved
    if (-not $relOutputPath -and (Test-Path $outputAgentDir)) {
        $latestHtml = Get-ChildItem -Path $outputAgentDir -Filter "*-latest.html" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latestHtml) {
            # Also check parent output dir (e.g. sprint-progress-latest.html)
            $latestHtml = Get-ChildItem -Path $OUTPUT_DIR -Filter "*-latest.html" -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }
        if ($latestHtml) {
            $relOutputPath = $latestHtml.FullName.Replace($PROJECT_ROOT, "").TrimStart("/\").Replace("\", "/")
            $outputFile = $latestHtml.FullName
        }
    }
    $outputWriteTime = Get-Date -Format "o"

    # Step 10: Increment counter, write audit/event
    $counter["count"] = $counter["count"] + 1
    $counter["last_run"] = (Get-Date -Format "o")
    $counter["last_run_id"] = $runId
    $counterJson = $counter | ConvertTo-Json -Compress
    Write-AtomicFile -Path $counterFile -Content $counterJson

    $completedAction = if ($exitCode -eq 0) { "completed" } else { "failed" }
    $auditOutputFile = if ($outputFile) { $outputFile } else { "(not saved)" }
    Write-AuditEntry -Action $completedAction -AgentName $Agent -JobName $Job -RunId $runId -Details @{ exit_code = $exitCode; output_file = $auditOutputFile; duration = $runDuration }
    Write-Event -AgentName $Agent -JobName $Job -Event $completedAction -Details @{ run_id = $runId; exit_code = $exitCode; duration = $runDuration }

    Write-Host "Job '$Job' for agent '$Agent' $completedAction (run: $runId, output: $auditOutputFile, duration: $runDuration)"

    # Step 11: Remove lock
    if (Test-Path $lockFile) { Remove-Item -Path $lockFile -Force }

    # Step 12: Check queues across ALL jobs for this agent, not just the current job
    $keepRunning = $false

    # First check own queue
    $depth = Get-QueueDepth -QueueFile $queueFile
    if ($depth -gt 0) {
        $depth--
        Set-QueueDepth -QueueFile $queueFile -Depth $depth
        Write-Host "Draining own queue for '$Job' (remaining: $depth). Re-running..."
        $keepRunning = $true
    } else {
        # Check other jobs for this agent that may have been queued
        $agentJobDirs = Get-ChildItem -Path (Join-Path $STATE_DIR "agents" $Agent) -Directory -ErrorAction SilentlyContinue
        foreach ($jobDir in $agentJobDirs) {
            $otherQueueFile = Join-Path $jobDir.FullName "queue"
            $otherDepth = Get-QueueDepth -QueueFile $otherQueueFile
            if ($otherDepth -gt 0) {
                $otherJobName = $jobDir.Name
                $otherDepth--
                Set-QueueDepth -QueueFile $otherQueueFile -Depth $otherDepth
                Write-Host "Draining queued job '$otherJobName' for agent '$Agent' (remaining: $otherDepth)."

                # Switch to the queued job: reload its config and prompt
                $otherJobDef = $jobsConfig[$otherJobName]
                if ($otherJobDef -and (-not $otherJobDef.ContainsKey("enabled") -or $otherJobDef["enabled"])) {
                    $Job = $otherJobName
                    $jobDef = $otherJobDef
                    $prompt = $otherJobDef["prompt"]
                    $stateDir = Ensure-StateDir -AgentName $Agent -JobName $Job
                    $queueFile = Join-Path $stateDir "queue"
                    $counterFile = Join-Path $stateDir "counter.json"
                    $keepRunning = $true
                    break
                } else {
                    Write-Host "Queued job '$otherJobName' is disabled or missing. Skipping."
                }
            }
        }
    }
}

# Step 13: Update dashboard to idle with output and error tracking
$agentErrorCount = Get-UnresolvedErrorCount -AgentName $Agent
$agentLevelDetails = @{
    errorCount = $agentErrorCount
}
if ($exitCode -ne 0) {
    $agentLevelDetails["lastError"] = (Get-Date -Format "o")
}
Update-Dashboard -AgentName $Agent -JobName $Job -Status "idle" -Details @{
    last_completed = (Get-Date -Format "o")
    runs_completed = $counter["count"]
    lastOutput     = $relOutputPath
    lastOutputTime = $outputWriteTime
} -AgentDetails $agentLevelDetails

Write-Host "Agent '$Agent' job '$Job' is now idle."
