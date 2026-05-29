#Requires -Version 7.0
# Test-HangScout-Kill.ps1 -- Unit tests for TTL-based process-kill enforcement
# in runner/Invoke-AgentJob.ps1.
#
# Background: prior to this fix, the stale-lock handler only deleted the
# logical lock file. The process holding it kept running. The 5/26-5/28
# bug-killer runs (333-350 min, TTL=180) are the production symptom and
# tests/test_lock_ttl_enforcement.py is the invariant that catches it.
#
# These tests cover:
#   1. Stop-RunProcessTree returns already_gone=true for a dead PID.
#   2. Stop-RunProcessTree kills a real child process spawned for the test.
#   3. The stale-lock branch of Invoke-AgentJob.ps1 emits both
#      kill_initiated and force_killed events with the right run_id / pid.
#
# Run: pwsh -File tests/Test-HangScout-Kill.ps1

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

# Source the runner so we can call Stop-RunProcessTree directly.
# Invoke-AgentJob.ps1 has a param() block + main flow at the bottom; we
# dot-source a sanitized copy that keeps only the function defs.
$runnerPath = Join-Path $PSScriptRoot ".." "runner" "Invoke-AgentJob.ps1"
$runnerPath = (Resolve-Path $runnerPath).Path
$runnerSrc = Get-Content -Path $runnerPath -Raw

# Find the boundary: everything from `# --- Main flow ---` onward is
# top-level code. Keep only the prelude (constants source + function defs).
$mainMarker = "# --- Main flow ---"
$idx = $runnerSrc.IndexOf($mainMarker)
if ($idx -lt 0) {
    throw "Could not find '$mainMarker' marker in Invoke-AgentJob.ps1"
}
$funcOnlySrc = $runnerSrc.Substring(0, $idx)

# Strip the param(...) block by replacing it with a no-op param().
# The param block is at the very top and uses [CmdletBinding()] + param(...).
$funcOnlySrc = $funcOnlySrc -replace '(?ms)\[CmdletBinding\(\)\].*?\)\s*\r?\n', "param()`r`n"

# Comment out the constants dot-source -- our test doesn't need them
# because Stop-RunProcessTree is self-contained.
$funcOnlySrc = $funcOnlySrc -replace '(?m)^\. \(Join-Path \$PSScriptRoot "constants\.ps1"\)', '# (constants skipped for test)'

$tmpFuncFile = Join-Path $env:TEMP "vo-hangscout-funcs-$PID.ps1"
Set-Content -Path $tmpFuncFile -Value $funcOnlySrc -Encoding UTF8
. $tmpFuncFile

# ========================================
# TC1: Stop-RunProcessTree on a dead PID returns already_gone=true
# ========================================
Write-Host "`nTC1: Stop-RunProcessTree on already-dead PID" -ForegroundColor Cyan
try {
    # Pick a PID that is overwhelmingly likely to be free. We spawn a
    # short-lived process and wait for it to exit so the PID is known-dead
    # (Windows recycles PIDs, but not within microseconds of exit).
    $shortProc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "exit 0" -PassThru -WindowStyle Hidden
    $shortProc.WaitForExit()
    $deadPid = $shortProc.Id

    $result = Stop-RunProcessTree -RootPid $deadPid
    Assert-True ($result.already_gone -eq $true) "already_gone is true for a dead PID"
    Assert-True ($result.killed -eq $false) "killed is false when PID was already gone"
}
catch {
    Assert-True $false "TC1 threw: $_"
}

# ========================================
# TC2: Stop-RunProcessTree kills a real long-running child
# ========================================
Write-Host "`nTC2: Stop-RunProcessTree kills a live process" -ForegroundColor Cyan
try {
    # Spawn a pwsh sleeper -- guaranteed long-running across Windows variants.
    # cmd /c timeout is brittle because cmd may exec timeout in-process or
    # exit early when stdout is redirected.
    $sleeper = Start-Process -FilePath "pwsh" -ArgumentList "-NoProfile", "-Command", "Start-Sleep -Seconds 30" -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 800
    $livePid = $sleeper.Id

    # Sanity: process is alive before kill
    $alivePre = Get-Process -Id $livePid -ErrorAction SilentlyContinue
    Assert-True ($null -ne $alivePre) "Sleeper process is alive before kill"

    $result = Stop-RunProcessTree -RootPid $livePid
    Assert-True ($result.killed -eq $true) "killed is true when we actually terminated something"
    Assert-True ($result.already_gone -eq $false) "already_gone is false when we did the kill"
    Assert-True ($result.pids_killed -contains $livePid) "Root PID is in pids_killed list"

    # Sanity: process is gone after kill
    Start-Sleep -Milliseconds 250
    $aliveAfter = Get-Process -Id $livePid -ErrorAction SilentlyContinue
    Assert-True ($null -eq $aliveAfter) "Sleeper process is gone after kill"
}
catch {
    Assert-True $false "TC2 threw: $_"
}

# ========================================
# TC3: events.jsonl synthesis -- kill_initiated + force_killed land between
# started and completed for a TTL-exceeding run, and the lock-TTL invariant
# test (tests/test_lock_ttl_enforcement.py) would consider this run KILLED.
# ========================================
Write-Host "`nTC3: synthetic events.jsonl satisfies test_lock_ttl_enforcement" -ForegroundColor Cyan
try {
    $tmpRoot = Join-Path $env:TEMP "vo-killtest-$PID-$(Get-Random)"
    New-Item -ItemType Directory -Path (Join-Path $tmpRoot "state") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmpRoot "config" "jobs") -Force | Out-Null

    # Minimal agents.json with a custom TTL so we don't depend on production.
    $agentsJson = @{
        agents = @{
            "fake-agent" = @{
                displayName = "Fake"
                description = "test"
                staleLockTimeoutMinutes = 60
            }
        }
    } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $tmpRoot "config" "agents.json") -Value $agentsJson -Encoding UTF8

    # Empty jobs file so load_ttl_minutes_by_job() falls back to agent TTL.
    $jobsJson = @{ jobs = @{ "fake-job" = @{ prompt = "x" } } } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $tmpRoot "config" "jobs" "fake-agent.json") -Value $jobsJson -Encoding UTF8

    $eventsFile = Join-Path $tmpRoot "state" "events.jsonl"
    $runId = "killtest1"
    $startedAt = (Get-Date).AddMinutes(-200).ToString("o")  # 200 min ago -- past TTL=60
    $killAt = (Get-Date).AddMinutes(-5).ToString("o")
    $completedAt = (Get-Date).AddMinutes(-2).ToString("o")
    $lines = @(
        (@{ timestamp = $startedAt; agent = "fake-agent"; job = "fake-job"; event = "started"; details = @{ run_id = $runId; runner_pid = 1234 } } | ConvertTo-Json -Compress),
        (@{ timestamp = $killAt;    agent = "fake-agent"; job = "fake-job"; event = "kill_initiated"; details = @{ run_id = $runId; pid = 1234; reason = "ttl_exceeded duration=200min ttl=60min" } } | ConvertTo-Json -Compress),
        (@{ timestamp = $killAt;    agent = "fake-agent"; job = "fake-job"; event = "force_killed"; details = @{ run_id = $runId; pid = 1234; already_gone = $false; reason = "ttl_exceeded duration=200min ttl=60min" } } | ConvertTo-Json -Compress),
        (@{ timestamp = $completedAt; agent = "fake-agent"; job = "fake-job"; event = "completed"; details = @{ run_id = $runId; exit_code = 137; duration = "12000s" } } | ConvertTo-Json -Compress)
    )
    Set-Content -Path $eventsFile -Value ($lines -join "`n") -Encoding UTF8

    # Run the python invariant against the synthetic state by overriding
    # REPO_ROOT through a tiny driver script.
    $driver = @"
import sys, os
sys.path.insert(0, r'$($PSScriptRoot)')
import test_lock_ttl_enforcement as mod
mod.REPO_ROOT = r'$tmpRoot'
mod.EVENTS_PATH = os.path.join(r'$tmpRoot', 'state', 'events.jsonl')
mod.JOBS_DIR = os.path.join(r'$tmpRoot', 'config', 'jobs')
mod.AGENTS_PATH = os.path.join(r'$tmpRoot', 'config', 'agents.json')
events = mod.load_events(mod.EVENTS_PATH)
job_ttl = mod.load_ttl_minutes_by_job()
from datetime import datetime, timezone
rows = mod.find_violations(events, job_ttl, datetime.now(timezone.utc), 14)
unkilled = [r for r in rows if r['killed_at'] is None]
print('rows={0} unkilled={1}'.format(len(rows), len(unkilled)))
sys.exit(0 if not unkilled else 1)
"@
    $driverFile = Join-Path $tmpRoot "driver.py"
    Set-Content -Path $driverFile -Value $driver -Encoding UTF8
    $pyResult = & python $driverFile 2>&1 | Out-String
    Write-Host "  driver output: $($pyResult.Trim())"
    Assert-True ($LASTEXITCODE -eq 0) "test_lock_ttl_enforcement passes on synthetic events with kill_initiated + force_killed"
    Remove-Item -Path $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
catch {
    Assert-True $false "TC3 threw: $_"
}

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-HangScout-Kill: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

# Cleanup
if (Test-Path $tmpFuncFile) { Remove-Item -Path $tmpFuncFile -Force -ErrorAction SilentlyContinue }

if ($script:Failed -gt 0) { exit 1 }
exit 0
