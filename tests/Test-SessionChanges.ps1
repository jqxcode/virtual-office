#Requires -Version 7.0
# Test-SessionChanges.ps1 -- Tests for changes made in current session (2026-03-26)
# Run: pwsh -File tests/Test-SessionChanges.ps1

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

$ProjectRoot = Join-Path $PSScriptRoot ".."
$ProjectRoot = (Resolve-Path $ProjectRoot).Path

# ========================================
# TC85: Sprint progress template has "Meeting Join (Fundamentals)" in section header
# ========================================
Write-Host "`nTC85: Template has 'Meeting Join (Fundamentals)' in section header" -ForegroundColor Cyan

$templateFile = Join-Path $ProjectRoot "templates" "mScrumMaster-sprint-progress.html"
Assert-True (Test-Path $templateFile) "Sprint progress template file exists"

if (Test-Path $templateFile) {
    $content = Get-Content -Path $templateFile -Raw
    Assert-True ($content -match 'Meeting Join \(Fundamentals\)') "Template contains 'Meeting Join (Fundamentals)'"
    # Ensure it is NOT just bare "Meeting Join" without the qualifier in the h2 header
    $h2Lines = ($content -split "`n") | Where-Object { $_ -match '<h2>.*Meeting Join.*</h2>' }
    $allH2HaveFundamentals = $true
    foreach ($line in $h2Lines) {
        if ($line -match '<h2>.*Meeting Join.*</h2>' -and $line -notmatch 'Fundamentals') {
            $allH2HaveFundamentals = $false
        }
    }
    Assert-True $allH2HaveFundamentals "All h2 headers with 'Meeting Join' include '(Fundamentals)'"
}

# ========================================
# TC86: Dashboard uses "mAuditor" not "checker" or "memo-checker"
# ========================================
Write-Host "`nTC86: Dashboard uses 'mAuditor' not 'checker' or 'memo-checker'" -ForegroundColor Cyan

$dashFile = Join-Path $ProjectRoot "state" "dashboard.json"
Assert-True (Test-Path $dashFile) "Dashboard state file exists"

if (Test-Path $dashFile) {
    $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($dash["agents"].ContainsKey("mAuditor")) "Dashboard has 'mAuditor' agent entry"
    Assert-True (-not $dash["agents"].ContainsKey("checker")) "Dashboard does NOT have 'checker' (old name)"
    Assert-True (-not $dash["agents"].ContainsKey("memo-checker")) "Dashboard does NOT have 'memo-checker' (old name)"
}

# ========================================
# TC87: mScrumMaster.json has "bug-autopilot-meeting-join" (not bare "bug-autopilot")
# ========================================
Write-Host "`nTC87: mScrumMaster.json job renames" -ForegroundColor Cyan

$smJobsFile = Join-Path $ProjectRoot "config" "jobs" "mScrumMaster.json"
Assert-True (Test-Path $smJobsFile) "mScrumMaster.json exists"

if (Test-Path $smJobsFile) {
    $smJobsRaw = Get-Content -Path $smJobsFile -Raw | ConvertFrom-Json -AsHashtable
    $smJobs = if ($smJobsRaw.ContainsKey("jobs")) { $smJobsRaw["jobs"] } else { $smJobsRaw }

    Assert-True ($smJobs.ContainsKey("bug-autopilot-meeting-join")) "mScrumMaster has 'bug-autopilot-meeting-join' job"
    Assert-True (-not $smJobs.ContainsKey("bug-autopilot")) "mScrumMaster does NOT have bare 'bug-autopilot' job"
    Assert-True (-not $smJobs.ContainsKey("TODO-sprint-progress")) "mScrumMaster does NOT have 'TODO-sprint-progress' (moved to mAuditor)"
    Assert-True (-not $smJobs.ContainsKey("TODO-compare-runs")) "mScrumMaster does NOT have 'TODO-compare-runs' (moved to mAuditor)"
}

# ========================================
# TC88: mAuditor.json HAS the TODO-sprint-progress and TODO-compare-runs jobs
# ========================================
Write-Host "`nTC88: mAuditor.json has the moved jobs" -ForegroundColor Cyan

$mAuditorJobsFile = Join-Path $ProjectRoot "config" "jobs" "mAuditor.json"
Assert-True (Test-Path $mAuditorJobsFile) "mAuditor.json exists"

if (Test-Path $mAuditorJobsFile) {
    $mAuditorJobsRaw = Get-Content -Path $mAuditorJobsFile -Raw | ConvertFrom-Json -AsHashtable
    $mAuditorJobs = if ($mAuditorJobsRaw.ContainsKey("jobs")) { $mAuditorJobsRaw["jobs"] } else { $mAuditorJobsRaw }

    Assert-True ($mAuditorJobs.ContainsKey("TODO-sprint-progress")) "mAuditor has 'TODO-sprint-progress' job"
    Assert-True ($mAuditorJobs.ContainsKey("TODO-compare-runs")) "mAuditor has 'TODO-compare-runs' job"
}

# ========================================
# TC89: mScrumMaster.json prompts referencing hackathon repos include "git pull"
# ========================================
Write-Host "`nTC89: Prompts referencing hackathon repos include 'git pull'" -ForegroundColor Cyan

if (Test-Path $smJobsFile) {
    $smJobsRaw = Get-Content -Path $smJobsFile -Raw | ConvertFrom-Json -AsHashtable
    $smJobs = if ($smJobsRaw.ContainsKey("jobs")) { $smJobsRaw["jobs"] } else { $smJobsRaw }

    $hackathonJobs = @()
    foreach ($jobName in $smJobs.Keys) {
        $jobPrompt = $smJobs[$jobName]["prompt"]
        if ($jobPrompt -match 'hackathon') {
            $hackathonJobs += $jobName
            $hasGitPull = $jobPrompt -match 'git pull'
            Assert-True $hasGitPull "Job '$jobName' prompt references hackathon and includes 'git pull'"
        }
    }
    Assert-True ($hackathonJobs.Count -gt 0) "At least one mScrumMaster job references hackathon repos"
}

# ========================================
# TC90: Schedule consistency - every scheduled job has a matching job definition
# ========================================
Write-Host "`nTC90: Schedule consistency - every job in schedules.json has a definition" -ForegroundColor Cyan

$schedulesFile = Join-Path $ProjectRoot "config" "schedules.json"
Assert-True (Test-Path $schedulesFile) "schedules.json exists"

if (Test-Path $schedulesFile) {
    $schedules = Get-Content -Path $schedulesFile -Raw | ConvertFrom-Json -AsHashtable
    $allFound = $true
    $missing = @()

    foreach ($entry in $schedules["schedules"]) {
        $agent = $entry["agent"]
        $job = $entry["job"]
        $agentJobFile = Join-Path $ProjectRoot "config" "jobs" "$agent.json"

        if (-not (Test-Path $agentJobFile)) {
            $allFound = $false
            $missing += "$agent/$job (no $agent.json)"
            continue
        }

        $jobsRaw = Get-Content -Path $agentJobFile -Raw | ConvertFrom-Json -AsHashtable
        $jobs = if ($jobsRaw.ContainsKey("jobs")) { $jobsRaw["jobs"] } else { $jobsRaw }

        if (-not $jobs.ContainsKey($job)) {
            $allFound = $false
            $missing += "$agent/$job (not in $agent.json)"
        }
    }

    if ($missing.Count -gt 0) {
        Write-Host "    Missing: $($missing -join ', ')" -ForegroundColor Yellow
    }
    Assert-True $allFound "All scheduled jobs have matching definitions in their agent's job config"
}

# ========================================
# TC91: Queue dispatch race fix - lock removal after queue drain check
# ========================================
Write-Host "`nTC91: Lock removal happens AFTER queue drain check in Invoke-AgentJob.ps1" -ForegroundColor Cyan

$runnerFile = Join-Path $ProjectRoot "runner" "Invoke-AgentJob.ps1"
Assert-True (Test-Path $runnerFile) "Invoke-AgentJob.ps1 exists"

if (Test-Path $runnerFile) {
    $runnerContent = Get-Content -Path $runnerFile -Raw

    # Find positions of queue drain logic and lock removal
    # The lock should only be removed when keepRunning is false (after queue check)
    $queueCheckMatch = [regex]::Match($runnerContent, 'Get-QueueDepth\s+-QueueFile\s+\$queueFile')
    $lockRemovalMatch = [regex]::Match($runnerContent, 'if\s*\(\s*-not\s+\$keepRunning\s*\)\s*\{[^}]*Remove-Item\s+-Path\s+\$lockFile')

    Assert-True ($queueCheckMatch.Success) "Runner has queue depth check"
    Assert-True ($lockRemovalMatch.Success) "Runner removes lock only when keepRunning is false"

    if ($queueCheckMatch.Success -and $lockRemovalMatch.Success) {
        Assert-True ($lockRemovalMatch.Index -gt $queueCheckMatch.Index) "Lock removal comes AFTER queue drain check (no race condition)"
    }

    # Verify that inside the run loop, the lock removal is conditional on keepRunning being false
    # (i.e., there is no unconditional Remove-Item $lockFile after the while loop body)
    $keepRunningFalseMatch = [regex]::Match($runnerContent, '\$keepRunning\s*=\s*\$false')
    if ($keepRunningFalseMatch.Success -and $lockRemovalMatch.Success) {
        # keepRunning = $false must come before the conditional lock removal
        Assert-True ($keepRunningFalseMatch.Index -lt $lockRemovalMatch.Index) "keepRunning set to false before conditional lock removal"
    }
}

# ========================================
# TC92: Config consistency - agents.json names match dashboard.json agent keys
# ========================================
Write-Host "`nTC92: agents.json names match dashboard.json agent keys" -ForegroundColor Cyan

$agentsFile = Join-Path $ProjectRoot "config" "agents.json"
Assert-True (Test-Path $agentsFile) "agents.json exists"

if ((Test-Path $agentsFile) -and (Test-Path $dashFile)) {
    $agentsRaw = Get-Content -Path $agentsFile -Raw | ConvertFrom-Json -AsHashtable
    $agents = if ($agentsRaw.ContainsKey("agents")) { $agentsRaw["agents"] } else { $agentsRaw }

    $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable
    $dashAgents = $dash["agents"]

    # Every dashboard agent should exist in agents.json (no orphaned entries)
    $orphaned = @()
    foreach ($dashAgent in $dashAgents.Keys) {
        if (-not $agents.ContainsKey($dashAgent)) {
            $orphaned += $dashAgent
        }
    }
    if ($orphaned.Count -gt 0) {
        Write-Host "    Orphaned dashboard agents: $($orphaned -join ', ')" -ForegroundColor Yellow
    }
    Assert-True ($orphaned.Count -eq 0) "No orphaned agents in dashboard.json (all match agents.json)"

    # Every agent in agents.json should exist in dashboard.json (optional, warn only)
    $missingFromDash = @()
    foreach ($agentName in $agents.Keys) {
        if (-not $dashAgents.ContainsKey($agentName)) {
            $missingFromDash += $agentName
        }
    }
    if ($missingFromDash.Count -gt 0) {
        Write-Host "    Note: agents in config but not yet in dashboard: $($missingFromDash -join ', ')" -ForegroundColor Yellow
    }
}

# ========================================
# TC93: Every agent in schedules.json exists in agents.json
# ========================================
Write-Host "`nTC93: Every agent in schedules.json exists in agents.json" -ForegroundColor Cyan

if ((Test-Path $schedulesFile) -and (Test-Path $agentsFile)) {
    $schedules = Get-Content -Path $schedulesFile -Raw | ConvertFrom-Json -AsHashtable
    $agentsRaw = Get-Content -Path $agentsFile -Raw | ConvertFrom-Json -AsHashtable
    $agents = if ($agentsRaw.ContainsKey("agents")) { $agentsRaw["agents"] } else { $agentsRaw }

    $scheduledAgents = $schedules["schedules"] | ForEach-Object { $_["agent"] } | Sort-Object -Unique
    $missingAgents = @()
    foreach ($sa in $scheduledAgents) {
        if (-not $agents.ContainsKey($sa)) {
            $missingAgents += $sa
        }
    }
    if ($missingAgents.Count -gt 0) {
        Write-Host "    Missing agents: $($missingAgents -join ', ')" -ForegroundColor Yellow
    }
    Assert-True ($missingAgents.Count -eq 0) "All scheduled agents exist in agents.json"
}

# ========================================
# TC94: pHangScout.json has closewait-tcp-hang classification with killThresholdMinutes
# ========================================
Write-Host "`nTC94: pHangScout.json has closewait-tcp-hang classification" -ForegroundColor Cyan

$hangScoutJobFile = Join-Path $ProjectRoot "config" "jobs" "pHangScout.json"
Assert-True (Test-Path $hangScoutJobFile) "pHangScout.json exists"

if (Test-Path $hangScoutJobFile) {
    $hsRaw = Get-Content -Path $hangScoutJobFile -Raw | ConvertFrom-Json -AsHashtable
    $hsJobs = if ($hsRaw.ContainsKey("jobs")) { $hsRaw["jobs"] } else { $hsRaw }

    Assert-True ($hsJobs.ContainsKey("detect-hang")) "pHangScout has detect-hang job"

    if ($hsJobs.ContainsKey("detect-hang")) {
        $detectHang = $hsJobs["detect-hang"]
        Assert-True ($detectHang.ContainsKey("hangDetection")) "detect-hang has hangDetection config"

        if ($detectHang.ContainsKey("hangDetection")) {
            $hd = $detectHang["hangDetection"]
            Assert-True ($hd.ContainsKey("perClassification")) "hangDetection has perClassification"

            if ($hd.ContainsKey("perClassification")) {
                $pc = $hd["perClassification"]
                Assert-True ($pc.ContainsKey("closewait-tcp-hang")) "perClassification has closewait-tcp-hang entry"

                if ($pc.ContainsKey("closewait-tcp-hang")) {
                    $cwEntry = $pc["closewait-tcp-hang"]
                    Assert-True ($cwEntry.ContainsKey("killThresholdMinutes")) "closewait-tcp-hang has killThresholdMinutes"
                    Assert-True ($cwEntry.ContainsKey("reason")) "closewait-tcp-hang has reason"
                    Assert-True ([int]$cwEntry["killThresholdMinutes"] -gt 0) "closewait-tcp-hang killThresholdMinutes is positive"
                }
            }
        }
    }

    # Verify the detect-hang prompt mentions the CloseWait detection logic
    if ($hsJobs.ContainsKey("detect-hang")) {
        $prompt = [string]$hsJobs["detect-hang"]["prompt"]
        Assert-True ($prompt -match "CloseWait") "detect-hang prompt includes CloseWait detection"
        Assert-True ($prompt -match "Get-NetTCPConnection") "detect-hang prompt uses Get-NetTCPConnection for TCP check"
        Assert-True ($prompt -match "closewait-tcp-hang") "detect-hang prompt references closewait-tcp-hang classification"
    }
}

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-SessionChanges: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
