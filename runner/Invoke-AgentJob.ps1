#Requires -Version 7.0
<#
.SYNOPSIS
    Invokes a Virtual Office agent job.
.DESCRIPTION
    Runs a configured agent job with locking, queueing, auditing, and dashboard updates.
.PARAMETER Agent
    The agent name (must exist in config/agents.json).
.PARAMETER Job
    The job name (must exist in config/jobs/{agent}.json).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Agent,

    [Parameter(Mandatory)]
    [string]$Job,

    # Optional caller-supplied args. Substituted into job prompt wherever
    # the literal string "{{EXTRA_ARGS}}" appears. Empty string when omitted.
    [Parameter(Mandatory=$false)]
    [string]$ExtraArgs = ""
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
    $tmpPath = "$Path.$PID.tmp"
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
    # Use FileStream with exclusive lock to prevent concurrent write corruption.
    # Retry on IOException to survive concurrent runners colliding on the same
    # audit file within milliseconds (2026-05-29 12:00 silent-crash incident).
    $line = $entry + [Environment]::NewLine
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
    $fs = $null
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            $fs = [System.IO.FileStream]::new($monthFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            break
        } catch [System.IO.IOException] {
            if ($attempt -eq 10) { throw }
            Start-Sleep -Milliseconds (20 * $attempt)
        }
    }
    try {
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
    } finally {
        if ($fs) { $fs.Close() }
    }
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
    # Use FileStream with exclusive lock to prevent concurrent write corruption.
    # Retry on IOException to survive concurrent runners colliding on the same
    # events file within milliseconds (2026-05-29 12:00 silent-crash incident).
    $line = $entry + [Environment]::NewLine
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
    $fs = $null
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            $fs = [System.IO.FileStream]::new($EVENTS_FILE, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            break
        } catch [System.IO.IOException] {
            if ($attempt -eq 10) { throw }
            Start-Sleep -Milliseconds (20 * $attempt)
        }
    }
    try {
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
    } finally {
        if ($fs) { $fs.Close() }
    }
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

function Test-ZombieProcess {
    <#
    .SYNOPSIS
        Detect whether a PID is in an unkillable zombie state.
    .DESCRIPTION
        A zombie process appears in Get-Process but all kill methods fail and it
        consumes 0 CPU.  We detect this by sampling CPU twice 500ms apart: if
        the process is still present after both samples AND the CPU delta is 0,
        it is considered a zombie.  Returns $true if the process is a zombie.
    #>
    param(
        [Parameter(Mandatory)]
        [int]$Pid
    )
    try {
        $snap1 = Get-Process -Id $Pid -ErrorAction SilentlyContinue
        if ($null -eq $snap1) { return $false }
        $cpu1 = $snap1.TotalProcessorTime.TotalMilliseconds
        Start-Sleep -Milliseconds 500
        $snap2 = Get-Process -Id $Pid -ErrorAction SilentlyContinue
        if ($null -eq $snap2) { return $false }  # It exited -- not a zombie
        $cpu2 = $snap2.TotalProcessorTime.TotalMilliseconds
        return ($cpu2 - $cpu1) -eq 0
    } catch {
        return $false
    }
}

function Stop-RunProcessTree {
    <#
    .SYNOPSIS
        Kill a runaway PID and all of its descendants.
    .DESCRIPTION
        Used by stale-lock TTL enforcement so a process whose logical lock has
        been cleared is actually terminated -- not left alive to keep burning
        money and racing the next invocation.
        Returns a hashtable with keys:
          killed       -- $true if any process was actually terminated
          already_gone -- $true if the PID was not alive at the time we looked
          pids_killed  -- array of integer PIDs that were terminated
          zombie_pids  -- array of PIDs that are alive but unkillable (zombie state)
          errors       -- array of string error messages (non-fatal)
        The function never throws -- TTL enforcement is best-effort cleanup,
        not a critical-path operation.
        When zombie_pids is non-empty the caller should remove the lock file
        (already done before calling here) and log the zombie PIDs for manual
        cleanup.  Do NOT retry the same failing kill methods.
    #>
    param(
        [Parameter(Mandatory)]
        [int]$RootPid
    )
    $result = @{
        killed       = $false
        already_gone = $false
        pids_killed  = @()
        zombie_pids  = @()
        errors       = @()
    }

    # 1) Verify the root is still alive. If not, we still want to report
    #    success so callers can write a `force_killed` event with
    #    reason="already_exited" -- the test treats that as proof the TTL
    #    sweep actually ran.
    $rootAlive = $false
    try {
        $proc = Get-Process -Id $RootPid -ErrorAction SilentlyContinue
        if ($null -ne $proc) {
            $rootAlive = $true
        }
    } catch {
        $result.errors += "Get-Process(root) failed: $_"
    }

    if (-not $rootAlive) {
        $result.already_gone = $true
        return $result
    }

    # 2) Collect descendants via CIM (Win32_Process.ParentProcessId). Walk
    #    the tree breadth-first so we kill leaves before parents -- killing a
    #    parent first sometimes leaves zombie children re-parented to init.
    $toKill = @($RootPid)
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($RootPid)
    $seen = @{ $RootPid = $true }

    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        try {
            $children = Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$parent" -ErrorAction SilentlyContinue
            foreach ($child in $children) {
                $childPid = [int]$child.ProcessId
                if (-not $seen.ContainsKey($childPid)) {
                    $seen[$childPid] = $true
                    $toKill += $childPid
                    $queue.Enqueue($childPid)
                }
            }
        } catch {
            $result.errors += "Get-CimInstance(parent=$parent) failed: $_"
        }
    }

    # Reverse so children die before parents.
    [array]::Reverse($toKill)

    foreach ($p in $toKill) {
        $alive = Get-Process -Id $p -ErrorAction SilentlyContinue
        if ($null -eq $alive) { continue }

        $killed = $false

        # Attempt 1: Stop-Process -Force
        try {
            Stop-Process -Id $p -Force -ErrorAction Stop
            $result.pids_killed += $p
            $result.killed = $true
            $killed = $true
        } catch {
            $result.errors += "Stop-Process(pid=$p) failed: $_"
        }

        if ($killed) { continue }

        # Attempt 2: taskkill /F /T
        try {
            & taskkill.exe /F /T /PID $p 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $result.pids_killed += $p
                $result.killed = $true
                $killed = $true
            } else {
                $result.errors += "taskkill(pid=$p) exited with code $LASTEXITCODE"
            }
        } catch {
            $result.errors += "taskkill(pid=$p) failed: $_"
        }

        if ($killed) { continue }

        # Attempt 3: WMI Terminate (escalated -- works when OS handle table is broken)
        try {
            $wmiProc = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
            if ($null -ne $wmiProc) {
                $wmiResult = Invoke-CimMethod -InputObject $wmiProc -MethodName Terminate -ErrorAction SilentlyContinue
                if ($null -ne $wmiResult -and $wmiResult.ReturnValue -eq 0) {
                    $result.pids_killed += $p
                    $result.killed = $true
                    $killed = $true
                } else {
                    $rc = if ($null -ne $wmiResult) { $wmiResult.ReturnValue } else { "null" }
                    $result.errors += "WMI Terminate(pid=$p) returned $rc"
                }
            }
        } catch {
            $result.errors += "WMI Terminate(pid=$p) failed: $_"
        }

        if ($killed) { continue }

        # All kill methods failed.  Check for zombie state (alive but 0 CPU delta).
        # Do NOT retry -- the OS cannot kill this process.  Record it for manual cleanup.
        $isZombie = Test-ZombieProcess -Pid $p
        if ($isZombie) {
            $result.zombie_pids += $p
            $result.errors += "pid=$p is unkillable zombie (alive, 0 CPU delta) -- recorded for manual cleanup"
        } else {
            # Process may have exited between kill attempts -- not a zombie, just a race.
            $stillAlive = Get-Process -Id $p -ErrorAction SilentlyContinue
            if ($null -eq $stillAlive) {
                $result.pids_killed += $p
                $result.killed = $true
            } else {
                $result.errors += "pid=$p still alive after all kill attempts but not detected as zombie"
            }
        }
    }
    return $result
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

# Step 0: Startup log -- written before anything else so we know pwsh actually started.
# If the script crashes later (file contention, drive not ready), this line proves it launched.
$startupTs = Get-Date -Format "o"
try {
    $startupLine = @{ ts = $startupTs; agent = $Agent; job = $Job; event = "runner_startup"; pid = $PID } | ConvertTo-Json -Compress
    $startupLogFile = Join-Path $PSScriptRoot ".." "state" "runner-startup.log"
    $startupLogDir = Split-Path -Parent $startupLogFile
    if (-not (Test-Path $startupLogDir)) {
        New-Item -ItemType Directory -Path $startupLogDir -Force | Out-Null
    }
    Add-Content -Path $startupLogFile -Value $startupLine -Encoding ASCII -ErrorAction SilentlyContinue
} catch {
    # Best-effort -- if even this fails, the drive isn't ready; nothing we can do.
}

# Step 1: Reconcile any dashboard entries stuck on "running" from a prior killed process.
# Must run before agent config is loaded so it runs even for agents that have no active lock.
# Wrapped in try/catch: this is best-effort cleanup. File contention with concurrent runners
# (e.g. after hibernate wake when multiple tasks catch up simultaneously) must NOT crash the script.
try {
    Repair-StuckDashboard
} catch {
    Write-Host "Repair-StuckDashboard failed (non-fatal, likely file contention): $_"
}

# Diagnostic breadcrumb: append step markers to startup log so we know exactly where a crash happens
function Write-Breadcrumb { param([string]$Step)
    try {
        $line = @{ ts = (Get-Date -Format "o"); agent = $Agent; job = $Job; step = $Step; pid = $PID } | ConvertTo-Json -Compress
        Add-Content -Path $startupLogFile -Value $line -Encoding ASCII -ErrorAction SilentlyContinue
    } catch { }
}
Write-Breadcrumb "step1_done"

# Step 2: Load and validate agent config (retry once on parse failure -- file contention with concurrent runners)
$agentsFile = Join-Path $CONFIG_DIR "agents.json"
if (-not (Test-Path $agentsFile)) {
    Write-Error "Config file not found: $agentsFile"
    exit 1
}
$agentsConfigRaw = $null
for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
        $agentsConfigRaw = Get-Content -Path $agentsFile -Raw | ConvertFrom-Json -AsHashtable
        break
    } catch {
        Write-Host "Step 2: agents.json parse attempt $attempt failed: $_"
        if ($attempt -lt 3) { Start-Sleep -Milliseconds 500 }
    }
}
if ($null -eq $agentsConfigRaw) {
    Write-Error "Failed to parse agents.json after 3 attempts"
    exit 1
}
$agentsConfig = if ($agentsConfigRaw.ContainsKey("agents")) { $agentsConfigRaw["agents"] } else { $agentsConfigRaw }
if (-not $agentsConfig.ContainsKey($Agent)) {
    Write-Error "Agent '$Agent' not found in agents.json. Available: $($agentsConfig.Keys -join ', ')"
    exit 1
}
Write-Breadcrumb "step2_done"

# Step 3: Load and validate job config (retry once on parse failure)
$jobsFile = Join-Path $CONFIG_DIR "jobs" "$Agent.json"
if (-not (Test-Path $jobsFile)) {
    Write-Error "Jobs file not found: $jobsFile"
    exit 1
}
$jobsConfigRaw = $null
for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
        $jobsConfigRaw = Get-Content -Path $jobsFile -Raw | ConvertFrom-Json -AsHashtable
        break
    } catch {
        Write-Host "Step 3: $jobsFile parse attempt $attempt failed: $_"
        if ($attempt -lt 3) { Start-Sleep -Milliseconds 500 }
    }
}
if ($null -eq $jobsConfigRaw) {
    Write-Error "Failed to parse $jobsFile after 3 attempts"
    exit 1
}
$jobsConfig = if ($jobsConfigRaw.ContainsKey("jobs")) { $jobsConfigRaw["jobs"] } else { $jobsConfigRaw }
if (-not $jobsConfig.ContainsKey($Job)) {
    Write-Error "Job '$Job' not found in $jobsFile. Available: $($jobsConfig.Keys -join ', ')"
    exit 1
}
$jobDef = $jobsConfig[$Job]

$prompt = $jobDef["prompt"]
if (-not $prompt) {
    Write-Error "Job '$Job' has no prompt defined."
    exit 1
}
$prompt = $prompt.Replace("{{EXTRA_ARGS}}", $ExtraArgs)
Write-Breadcrumb "step3_done"

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
    $lockHandled = $false
    try {
        $lockContent = Get-Content -Path $lockFile -Raw -ErrorAction SilentlyContinue
        $lockAge = $null
        $lockedByJob = "unknown"
        $lockedByPid = $null
        $lockedByRunId = ""
        try {
            $parsed = $lockContent.Trim() | ConvertFrom-Json
            $lockTime = [DateTime]::Parse($parsed.ts)
            $lockAge = (Get-Date) - $lockTime
            $lockedByJob = $parsed.job
            # PID and run_id are best-effort -- older lock files (pre-PID era)
            # may not have them. The kill-on-TTL step below handles both cases.
            try { $lockedByPid = [int]$parsed.pid } catch { }
            try { $lockedByRunId = [string]$parsed.run_id } catch { }
        } catch {
            $lockAge = [TimeSpan]::FromMinutes($staleLockTimeout + 1)
        }

        if ($lockAge -and $lockAge.TotalMinutes -gt $staleLockTimeout) {
            # Stale lock -- force clear AND kill the underlying process tree.
            # Just deleting the lock file leaves the runaway process alive,
            # which is the exact bug that produced the 5/26-5/28 333-350 min
            # pBugKiller runs (see tests/test_lock_ttl_enforcement.py).
            Remove-Item -Path $lockFile -Force
            $lockAgeMin = [math]::Round($lockAge.TotalMinutes)
            Write-Event -AgentName $Agent -JobName $Job -Event "stale_lock_cleared" -Details @{
                locked_by_job = $lockedByJob
                lock_age_minutes = $lockAgeMin
                timeout_minutes = $staleLockTimeout
            }
            Write-AuditEntry -Action "stale_lock_cleared" -AgentName $Agent -JobName $Job -RunId "N/A" -Details @{
                locked_by_job = $lockedByJob
                lock_age_minutes = $lockAgeMin
            }
            Write-Host "Stale lock cleared for '$Agent' (was held by '$lockedByJob', age: ${lockAgeMin}m, timeout: ${staleLockTimeout}m)."

            # TTL enforcement: kill the process whose lock we just cleared.
            # Emit kill_initiated and force_killed events so the lock-TTL
            # invariant test (tests/test_lock_ttl_enforcement.py) sees that
            # we actually shut the runaway process down, not just deleted
            # the logical lock.
            if ($null -ne $lockedByPid -and $lockedByPid -gt 0) {
                $killReason = "ttl_exceeded duration=${lockAgeMin}min ttl=${staleLockTimeout}min"
                Write-Event -AgentName $Agent -JobName $lockedByJob -Event "kill_initiated" -Details @{
                    run_id = $lockedByRunId
                    pid = $lockedByPid
                    lock_age_minutes = $lockAgeMin
                    timeout_minutes = $staleLockTimeout
                    reason = $killReason
                }
                Write-AuditEntry -Action "kill_initiated" -AgentName $Agent -JobName $lockedByJob -RunId $lockedByRunId -Details @{
                    pid = $lockedByPid
                    reason = $killReason
                }
                Write-Host "kill_initiated: agent='$Agent' job='$lockedByJob' pid=$lockedByPid reason='$killReason'"

                $killResult = Stop-RunProcessTree -RootPid $lockedByPid

                $forceReason = if ($killResult.already_gone) {
                    "already_exited"
                } elseif ($killResult.zombie_pids.Count -gt 0) {
                    "zombie_unkillable lock_removed_for_recovery"
                } else {
                    $killReason
                }
                Write-Event -AgentName $Agent -JobName $lockedByJob -Event "force_killed" -Details @{
                    run_id = $lockedByRunId
                    pid = $lockedByPid
                    pids_killed = $killResult.pids_killed
                    zombie_pids = $killResult.zombie_pids
                    already_gone = $killResult.already_gone
                    reason = $forceReason
                    errors = $killResult.errors
                }
                Write-AuditEntry -Action "force_killed" -AgentName $Agent -JobName $lockedByJob -RunId $lockedByRunId -Details @{
                    pid = $lockedByPid
                    pids_killed = $killResult.pids_killed
                    zombie_pids = $killResult.zombie_pids
                    already_gone = $killResult.already_gone
                    reason = $forceReason
                }
                if ($killResult.zombie_pids.Count -gt 0) {
                    Write-Host "WARNING: zombie process(es) detected -- all kill methods failed. Lock removed so next run can proceed. Manual cleanup needed for PID(s): $($killResult.zombie_pids -join ',')"
                }
                Write-Host "force_killed: agent='$Agent' job='$lockedByJob' pid=$lockedByPid already_gone=$($killResult.already_gone) pids_killed=$($killResult.pids_killed -join ',') zombie_pids=$($killResult.zombie_pids -join ',')"
            } else {
                # No PID recorded on the lock -- still emit force_killed with
                # reason=no_pid so the TTL invariant test can see the sweep
                # ran. Pre-PID-era lock files are the only path that hits
                # this branch.
                Write-Event -AgentName $Agent -JobName $lockedByJob -Event "force_killed" -Details @{
                    run_id = $lockedByRunId
                    pid = 0
                    already_gone = $true
                    reason = "no_pid_in_lock ttl_exceeded duration=${lockAgeMin}min ttl=${staleLockTimeout}min"
                }
                Write-AuditEntry -Action "force_killed" -AgentName $Agent -JobName $lockedByJob -RunId $lockedByRunId -Details @{
                    pid = 0
                    already_gone = $true
                    reason = "no_pid_in_lock"
                }
                Write-Host "force_killed (no pid in lock): agent='$Agent' job='$lockedByJob'"
            }
        } else {
            $lockHandled = $true
        }
    } catch {
        Write-Host "Lock check failed (file contention): $_. Treating as busy."
        $lockHandled = $true
    }

    if ($lockHandled) {
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
# Wrap in try-finally to guarantee lock cleanup on abnormal exit (crash,
# unhandled exception, pipeline termination). Without this, a script crash
# leaves an orphaned lock file that blocks the agent until TTL expires.
# See: https://github.com/jqxcode/virtual-office/issues/61
$keepRunning = $true
# Initialize outcome vars before the loop so the maxRuns-skip path (which breaks
# out before the invocation block sets them) leaves them defined for the
# post-loop dashboard block under StrictMode. Without this, a job at its maxRuns
# limit crashes with "variable $exitCode/$relOutputPath cannot be retrieved".
$output = ""
$exitCode = 0
$costData = $null
$relOutputPath = $null
$outputWriteTime = $null
try {
while ($keepRunning) {
    # Record the lock timestamp (lock file is written atomically with PID after process starts)
    $lockTs = (Get-Date -Format "o")

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

    # Step 7: Write audit/event/dashboard for start.
    # Include the runner's own PID on the started event so pHangScout / TTL
    # enforcement can correlate run_id -> process even if the lock file has
    # already been cleared. The agent (agency.exe) child PID is recorded separately on
    # the lock file once the child is spawned in step 8.
    Write-AuditEntry -Action "started" -AgentName $Agent -JobName $Job -RunId $runId -Details @{ runner_pid = $PID }
    Write-Event -AgentName $Agent -JobName $Job -Event "started" -Details @{ run_id = $runId; runner_pid = $PID }
    Update-Dashboard -AgentName $Agent -JobName $Job -Status "running" -Details @{ run_id = $runId; runner_pid = $PID; started = (Get-Date -Format "o") }

    # Step 8: Invoke the agent via agc (agency.exe copilot)
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
    $costData = $null
    $runStart = Get-Date
    try {
        # Resolve the Copilot agent NAME from the configured agentFile basename.
        # agents.json still points at legacy ~/.claude/agents/<name>.md paths, but the
        # Copilot CLI resolves agents by NAME from ~/.copilot/agents/<name>.agent.md.
        $agentName2 = $null
        if ($agentFile) {
            $agentName2 = [System.IO.Path]::GetFileNameWithoutExtension($agentFile)  # e.g. poster.md -> poster
            $copilotAgentFile = Join-Path $HOME ".copilot/agents/$agentName2.agent.md"
            # The agent file MUST exist -- if it does not, fail loud instead of silently
            # running a bare prompt with no persona/scope (see incident: missing agent
            # file silently degraded the run).
            if (-not (Test-Path $copilotAgentFile)) {
                Write-AuditEntry -Action "failed" -AgentName $Agent -JobName $Job -RunId $runId -Details @{ reason = "agent_file_not_found"; agent = $agentName2; agent_file = $copilotAgentFile }
                Write-Event -AgentName $Agent -JobName $Job -Event "failed" -Details @{ run_id = $runId; reason = "agent_file_not_found"; agent = $agentName2; agent_file = $copilotAgentFile }
                throw "Copilot agent '$agentName2' configured for '$Agent' but not found: $copilotAgentFile"
            }
        }

        $rawOutput = ""
        $errOutput = ""
        if ($env:VO_CLI_MOCK_OUTPUT) {
            # Test seam: bypass the real agent CLI (used by Test-*.ps1). Set
            # VO_CLI_MOCK_OUTPUT (and optionally VO_CLI_MOCK_EXIT) to simulate a run.
            $rawOutput = $env:VO_CLI_MOCK_OUTPUT
            $exitCode  = if ($env:VO_CLI_MOCK_EXIT) { [int]$env:VO_CLI_MOCK_EXIT } else { 0 }
            $lockContent = @{ ts = $lockTs; job = $Job; pid = $PID; run_id = $runId } | ConvertTo-Json -Compress
            Write-AtomicFile -Path $lockFile -Content $lockContent
        } else {
            # Invoke Copilot without selecting a model. Model availability is controlled by
            # the Copilot backend and changes over time; unattended VO automation must use
            # Copilot's supported default rather than copying a personal interactive alias.
            # -p runs non-interactively; --allow-all lets the agent use tools without prompts;
            # --output-format json emits JSONL (one event per line) which we parse below.
            $copilotArgs = @("copilot", "--", "--context", "long_context", "--output-format", "json", "--allow-all")
            if ($agentName2) { $copilotArgs += @("--agent", $agentName2) }
            $copilotArgs += @("-p", $prompt)

            # Start the agency/copilot process and capture PID
            $pinfo = New-Object System.Diagnostics.ProcessStartInfo
            $pinfo.FileName = "agency.exe"
            $pinfo.Arguments = ($copilotArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join " "
            $pinfo.RedirectStandardOutput = $true
            $pinfo.RedirectStandardError = $true
            $pinfo.UseShellExecute = $false
            $pinfo.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::Start($pinfo)

            # Write lock atomically with PID -- single write, no PID-less window
            $lockContent = @{ ts = $lockTs; job = $Job; pid = $proc.Id; run_id = $runId } | ConvertTo-Json -Compress
            Write-AtomicFile -Path $lockFile -Content $lockContent

            $rawOutput = $proc.StandardOutput.ReadToEnd()
            $errOutput = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()
            $exitCode  = $proc.ExitCode
        }

        # Parse Copilot CLI JSONL output: collect assistant message text + the final result event.
        $output = $rawOutput
        try {
            $assistantParts = New-Object System.Collections.Generic.List[string]
            $outputTokensSum = 0
            $modelName = "unknown"
            $resultEvent = $null
            foreach ($line in ($rawOutput -split "`n")) {
                $t = $line.Trim()
                if ($t.Length -eq 0 -or $t[0] -ne '{') { continue }
                $obj = $null
                try { $obj = $t | ConvertFrom-Json -AsHashtable } catch { continue }
                if (-not ($obj -is [hashtable]) -or -not $obj.ContainsKey("type")) { continue }
                if ($obj["type"] -eq "session.model_change") {
                    $d = $obj["data"]
                    if ($d -and $d.ContainsKey("newModel") -and $d["newModel"]) {
                        $modelName = [string]$d["newModel"]
                    }
                } elseif ($obj["type"] -eq "assistant.message") {
                    $d = $obj["data"]
                    if ($d -and $d.ContainsKey("content") -and $d["content"]) { $assistantParts.Add([string]$d["content"]) }
                    if ($d -and $d.ContainsKey("outputTokens")) { $outputTokensSum += [int]$d["outputTokens"] }
                    if ($d -and $d.ContainsKey("model") -and $d["model"]) { $modelName = [string]$d["model"] }
                } elseif ($obj["type"] -eq "result") {
                    $resultEvent = $obj
                }
            }
            if ($assistantParts.Count -gt 0) { $output = ($assistantParts -join "`n`n") }
            # Extract cost/usage from the final result event (Copilot schema differs from Claude's).
            $costData = @{
                costUSD         = 0    # Copilot CLI does not report a USD cost
                model           = $modelName
                outputTokens    = $outputTokensSum
                inputTokens     = 0
                numTurns        = 0
                sessionId       = ""
                durationMs      = 0
                durationApiMs   = 0
                premiumRequests = 0
            }
            if ($resultEvent) {
                if ($resultEvent.ContainsKey("sessionId")) { $costData["sessionId"] = [string]$resultEvent["sessionId"] }
                if ($resultEvent.ContainsKey("exitCode"))  { $exitCode = [int]$resultEvent["exitCode"] }
                if ($resultEvent.ContainsKey("usage")) {
                    $u = $resultEvent["usage"]
                    if ($u.ContainsKey("premiumRequests"))    { $costData["premiumRequests"] = $u["premiumRequests"] }
                    if ($u.ContainsKey("sessionDurationMs"))  { $costData["durationMs"]       = $u["sessionDurationMs"] }
                    if ($u.ContainsKey("totalApiDurationMs")) { $costData["durationApiMs"]    = $u["totalApiDurationMs"] }
                    if ($u.ContainsKey("codeChanges")) {
                        $cc = $u["codeChanges"]
                        if ($cc.ContainsKey("linesAdded"))   { $costData["linesAdded"]   = $cc["linesAdded"] }
                        if ($cc.ContainsKey("linesRemoved")) { $costData["linesRemoved"] = $cc["linesRemoved"] }
                    }
                }
            }
        } catch {
            # JSON parsing failed -- use raw output as-is (e.g. CLI error before any JSON)
            Write-Host "Note: Could not parse Copilot JSON output, using raw text. Error: $_"
        }

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
            -Summary "Agent CLI (copilot) exited with code $exitCode" `
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
        # Sanitize unicode characters to ASCII equivalents before saving
        $output = $output -replace [char]0x2014, '--'   # em dash to --
        $output = $output -replace [char]0x2013, '-'    # en dash to -
        $output = $output -replace [char]0x2192, '->'   # right arrow to ->
        $output = $output -replace [char]0x2190, '<-'   # left arrow to <-
        $output = $output -replace [char]0x2019, "'"    # right single quote to '
        $output = $output -replace [char]0x2018, "'"    # left single quote to '
        $output = $output -replace [char]0x201C, '"'    # left double quote to "
        $output = $output -replace [char]0x201D, '"'    # right double quote to "
        $output = $output -replace [char]0x2026, '...'  # ellipsis to ...
        $output = $output -replace [char]0xFEFF, ''     # BOM strip
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
    $auditDetails = @{ exit_code = $exitCode; output_file = $auditOutputFile; duration = $runDuration }
    if ($costData) {
        $auditDetails["cost"] = $costData
    }
    Write-AuditEntry -Action $completedAction -AgentName $Agent -JobName $Job -RunId $runId -Details $auditDetails
    $eventDetails = @{ run_id = $runId; exit_code = $exitCode; duration = $runDuration }
    if ($costData -and $costData.ContainsKey("costUSD")) {
        $eventDetails["costUSD"] = $costData["costUSD"]
    }
    Write-Event -AgentName $Agent -JobName $Job -Event $completedAction -Details $eventDetails

    Write-Host "Job '$Job' for agent '$Agent' $completedAction (run: $runId, output: $auditOutputFile, duration: $runDuration)"

    # Post-run hook: triggerOnComplete -- chain to a dependent job on success
    if ($exitCode -eq 0 -and $jobDef.ContainsKey("triggerOnComplete")) {
        try {
            $trigger = $jobDef["triggerOnComplete"]
            $triggerAgent = $trigger["agent"]
            $triggerJob = $trigger["job"]
            $invokeScript = Join-Path $PSScriptRoot "Invoke-AgentJob.ps1"
            Write-Host "triggerOnComplete: firing $triggerAgent/$triggerJob"
            Start-Process -FilePath "pwsh" -ArgumentList @("-NoProfile", "-File", $invokeScript, "-Agent", $triggerAgent, "-Job", $triggerJob) -WindowStyle Hidden
            Write-Event -AgentName $Agent -JobName $Job -Event "trigger_fired" -Details @{ target_agent = $triggerAgent; target_job = $triggerJob }
        } catch {
            Write-Host "triggerOnComplete failed (non-fatal): $_"
        }
    }

    # Post-run hook: consolidate Edge report tabs (non-blocking)
    if ($Job -ne "TEMP-consolidate-Edge-reports") {
        try {
            $consolidateScript = "Q:\src\personal_projects\edge-tab-exporter\get-tabs.py"
            if (Test-Path $consolidateScript) {
                Write-Host "Post-run hook: consolidating Edge report tabs..."
                $hookResult = & python $consolidateScript --consolidate 2>&1
                Write-Host "Edge consolidation: $hookResult"
            }
        } catch {
            Write-Host "Edge consolidation hook failed (non-fatal): $_"
        }
    }

    # Step 11: Check queues across ALL jobs for this agent before releasing lock
    # (Hold the lock until we know there's nothing left to run, preventing race conditions
    # where queued jobs get stranded because the lock was released before checking the queue)
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

                # Switch to the queued job: reload its config and prompt.
                # Queue-drained jobs never carry caller ExtraArgs (the original
                # invocation may have had any), so substitute with empty string.
                $otherJobDef = $jobsConfig[$otherJobName]
                if ($otherJobDef) {
                    $Job = $otherJobName
                    $jobDef = $otherJobDef
                    $prompt = ([string]$otherJobDef["prompt"]).Replace("{{EXTRA_ARGS}}", "")
                    $stateDir = Ensure-StateDir -AgentName $Agent -JobName $Job
                    $queueFile = Join-Path $stateDir "queue"
                    $counterFile = Join-Path $stateDir "counter.json"
                    $keepRunning = $true
                    break
                } else {
                    Write-Host "Queued job '$otherJobName' not found in config. Skipping."
                }
            }
        }
    }

    # Step 12: Release lock only when there's nothing left to run
    if (-not $keepRunning) {
        if (Test-Path $lockFile) { Remove-Item -Path $lockFile -Force }
    }
}
} finally {
    # Guarantee lock cleanup on ANY exit path (crash, unhandled exception,
    # pipeline termination, Ctrl+C). This prevents the batch stale-lock
    # scenario where all agents exit simultaneously and leave orphaned locks.
    if (Test-Path $lockFile) {
        Remove-Item -Path $lockFile -Force -ErrorAction SilentlyContinue
        Write-Host "Lock released in finally block for '$Agent'."
        try {
            Write-AuditEntry -Action "lock_released_finally" -AgentName $Agent -JobName $Job -RunId $runId -Details @{
                reason = "abnormal_exit_cleanup"
            }
        } catch { }
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
$dashDetails = @{
    last_completed = (Get-Date -Format "o")
    runs_completed = $counter["count"]
    lastOutput     = $relOutputPath
    lastOutputTime = $outputWriteTime
}
if ($costData) {
    $dashDetails["lastCost"] = $costData
}
Update-Dashboard -AgentName $Agent -JobName $Job -Status "idle" -Details $dashDetails -AgentDetails $agentLevelDetails

Write-Host "Agent '$Agent' job '$Job' is now idle."
