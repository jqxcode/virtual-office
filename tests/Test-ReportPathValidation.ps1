#Requires -Version 7.0
# Test-ReportPathValidation.ps1 -- Report path validation tests
# Validates that audit log output_file entries point to correct agent-owned reports.
# Run: pwsh -File tests/Test-ReportPathValidation.ps1

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

# ========================================
# Reusable validation function
# ========================================

# Agent-to-report-type mapping. Each agent lists the report prefixes it may produce.
# poster has no reports (posts to Teams, not local HTML).
$script:AgentReportTypes = @{
    "bug-killer"   = @("daily-summary", "pr-maintenance", "open-pr-maintenance", "scan", "merge-conflicts")
    "hang-scout"   = @("daily-report", "incident")
    "auditor"      = @("failure-review", "sprint-progress")
    "scrum-master" = @("sprint-progress", "shiproom-hygiene", "comparison", "run-summaries")
    "poster"       = @()
    "pEmailer"     = @("scan-all-mailboxes", "digest")
    "dreamer"      = @("wish")
}

function Test-ReportPathBelongsToAgent {
    <#
    .SYNOPSIS
        Validates that an output_file path is a legitimate report for the given agent and job.
    .PARAMETER AgentName
        The agent name (e.g. "bug-killer").
    .PARAMETER JobName
        The job name (e.g. "daily-scan").
    .PARAMETER OutputFile
        The output_file path from the audit log (e.g. "output/bug-killer/daily-summary-20260401.html").
    .OUTPUTS
        [bool] $true if the path passes all validation checks, $false otherwise.
    #>
    param(
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)][string]$JobName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$OutputFile
    )

    # Empty or whitespace-only path is always invalid
    if ([string]::IsNullOrWhiteSpace($OutputFile)) {
        return $false
    }

    # Normalize path separators to forward slashes
    $normalized = $OutputFile.Replace("\", "/")

    # Rule 1: poster should have no report file
    if ($AgentName -eq "poster") {
        return $false
    }

    # Rule 2: Path must contain the agent's own directory
    if ($normalized -notmatch "(/|\\)$([regex]::Escape($AgentName))(/|\\)") {
        if ($normalized -notmatch "^$([regex]::Escape($AgentName))(/|\\)") {
            return $false
        }
    }

    # Rule 3: Must not be a -latest.html file
    if ($normalized -match "-latest\.html$") {
        return $false
    }

    # Rule 4: Report type must match agent
    if ($script:AgentReportTypes.ContainsKey($AgentName)) {
        $allowedPrefixes = $script:AgentReportTypes[$AgentName]
        if ($allowedPrefixes.Count -gt 0) {
            $filename = [System.IO.Path]::GetFileName($normalized)
            $matchesAny = $false
            foreach ($prefix in $allowedPrefixes) {
                if ($filename -match "^$([regex]::Escape($prefix))") {
                    $matchesAny = $true
                    break
                }
            }
            if (-not $matchesAny) {
                return $false
            }
        }
    }

    return $true
}

# ========================================
# TC1: Report path must contain agent name
# ========================================
Write-Host "`nTC1: Report path must contain agent name in directory" -ForegroundColor Cyan

# Valid paths
Assert-True (Test-ReportPathBelongsToAgent -AgentName "bug-killer" -JobName "daily-scan" `
    -OutputFile "output/bug-killer/daily-summary-20260401.html") `
    "Valid: output/bug-killer/daily-summary-20260401.html contains /bug-killer/"

Assert-True (Test-ReportPathBelongsToAgent -AgentName "auditor" -JobName "sprint-review" `
    -OutputFile "output/auditor/sprint-progress-20260401.html") `
    "Valid: output/auditor/sprint-progress-20260401.html contains /auditor/"

Assert-True (Test-ReportPathBelongsToAgent -AgentName "hang-scout" -JobName "daily" `
    -OutputFile "output/hang-scout/daily-report-20260401.html") `
    "Valid: output/hang-scout/daily-report-20260401.html contains /hang-scout/"

# Invalid paths -- file sitting in parent output/ dir without agent subdir
Assert-True (-not (Test-ReportPathBelongsToAgent -AgentName "bug-killer" -JobName "daily-scan" `
    -OutputFile "output/sprint-progress-latest.html")) `
    "Invalid: output/sprint-progress-latest.html has no /bug-killer/ directory"

Assert-True (-not (Test-ReportPathBelongsToAgent -AgentName "bug-killer" -JobName "daily-scan" `
    -OutputFile "output/daily-summary-20260401.html")) `
    "Invalid: output/daily-summary-20260401.html has no /bug-killer/ directory"

# Wrong agent directory
Assert-True (-not (Test-ReportPathBelongsToAgent -AgentName "bug-killer" -JobName "daily-scan" `
    -OutputFile "output/auditor/daily-summary-20260401.html")) `
    "Invalid: output/auditor/daily-summary-20260401.html is wrong agent dir for bug-killer"

# ========================================
# TC2: Report path must not be a -latest.html file
# ========================================
Write-Host "`nTC2: Report path must not be a -latest.html file (symlink pointers, not real outputs)" -ForegroundColor Cyan

Assert-True (-not (Test-ReportPathBelongsToAgent -AgentName "bug-killer" -JobName "daily-scan" `
    -OutputFile "output/bug-killer/daily-summary-latest.html")) `
    "Invalid: daily-summary-latest.html is a symlink pointer, not a dated report"

Assert-True (-not (Test-ReportPathBelongsToAgent -AgentName "auditor" -JobName "sprint-review" `
    -OutputFile "output/auditor/sprint-progress-latest.html")) `
    "Invalid: sprint-progress-latest.html is a symlink pointer"

Assert-True (-not (Test-ReportPathBelongsToAgent -AgentName "scrum-master" -JobName "shiproom" `
    -OutputFile "output/scrum-master/shiproom-hygiene-latest.html")) `
    "Invalid: shiproom-hygiene-latest.html is a symlink pointer"

# Dated files should pass
Assert-True (Test-ReportPathBelongsToAgent -AgentName "bug-killer" -JobName "daily-scan" `
    -OutputFile "output/bug-killer/daily-summary-20260401.html") `
    "Valid: daily-summary-20260401.html is a dated report"

Assert-True (Test-ReportPathBelongsToAgent -AgentName "scrum-master" -JobName "shiproom" `
    -OutputFile "output/scrum-master/shiproom-hygiene-2026-04-01.html") `
    "Valid: shiproom-hygiene-2026-04-01.html is a dated report"

# ========================================
# TC3: Report file type matches agent
# ========================================
Write-Host "`nTC3: Report file type matches agent's allowed report types" -ForegroundColor Cyan

# bug-killer valid types
Assert-True (Test-ReportPathBelongsToAgent -AgentName "bug-killer" -JobName "scan" `
    -OutputFile "output/bug-killer/scan-20260401.html") `
    "Valid: bug-killer can produce 'scan' reports"

Assert-True (Test-ReportPathBelongsToAgent -AgentName "bug-killer" -JobName "pr-maint" `
    -OutputFile "output/bug-killer/pr-maintenance-20260401.html") `
    "Valid: bug-killer can produce 'pr-maintenance' reports"

Assert-True (Test-ReportPathBelongsToAgent -AgentName "bug-killer" -JobName "merge" `
    -OutputFile "output/bug-killer/merge-conflicts-20260401.html") `
    "Valid: bug-killer can produce 'merge-conflicts' reports"

# bug-killer invalid type
Assert-True (-not (Test-ReportPathBelongsToAgent -AgentName "bug-killer" -JobName "daily-scan" `
    -OutputFile "output/bug-killer/sprint-progress-20260401.html")) `
    "Invalid: bug-killer cannot produce 'sprint-progress' reports"

# hang-scout valid/invalid
Assert-True (Test-ReportPathBelongsToAgent -AgentName "hang-scout" -JobName "daily" `
    -OutputFile "output/hang-scout/incident-20260401.html") `
    "Valid: hang-scout can produce 'incident' reports"

Assert-True (-not (Test-ReportPathBelongsToAgent -AgentName "hang-scout" -JobName "daily" `
    -OutputFile "output/hang-scout/daily-summary-20260401.html")) `
    "Invalid: hang-scout cannot produce 'daily-summary' reports"

# scrum-master valid types
Assert-True (Test-ReportPathBelongsToAgent -AgentName "scrum-master" -JobName "compare" `
    -OutputFile "output/scrum-master/comparison-20260401.html") `
    "Valid: scrum-master can produce 'comparison' reports"

Assert-True (Test-ReportPathBelongsToAgent -AgentName "scrum-master" -JobName "summaries" `
    -OutputFile "output/scrum-master/run-summaries-20260401.html") `
    "Valid: scrum-master can produce 'run-summaries' reports"

# poster should have NO reports
Assert-True (-not (Test-ReportPathBelongsToAgent -AgentName "poster" -JobName "daily-post" `
    -OutputFile "output/poster/daily-summary-20260401.html")) `
    "Invalid: poster should never have a report file (posts to Teams)"

Assert-True (-not (Test-ReportPathBelongsToAgent -AgentName "poster" -JobName "daily-post" `
    -OutputFile "output/poster/anything-20260401.html")) `
    "Invalid: poster should never have any report file"

# pEmailer valid types
Assert-True (Test-ReportPathBelongsToAgent -AgentName "pEmailer" -JobName "scan" `
    -OutputFile "output/pEmailer/scan-all-mailboxes-20260401.html") `
    "Valid: pEmailer can produce 'scan-all-mailboxes' reports"

Assert-True (Test-ReportPathBelongsToAgent -AgentName "pEmailer" -JobName "digest" `
    -OutputFile "output/pEmailer/digest-20260401.html") `
    "Valid: pEmailer can produce 'digest' reports"

# dreamer valid type
Assert-True (Test-ReportPathBelongsToAgent -AgentName "dreamer" -JobName "wish-gen" `
    -OutputFile "output/dreamer/wish-20260401.html") `
    "Valid: dreamer can produce 'wish' reports"

Assert-True (-not (Test-ReportPathBelongsToAgent -AgentName "dreamer" -JobName "wish-gen" `
    -OutputFile "output/dreamer/daily-summary-20260401.html")) `
    "Invalid: dreamer cannot produce 'daily-summary' reports"

# ========================================
# TC4: Report date must be within 1 day of audit timestamp
# ========================================
Write-Host "`nTC4: Report date extracted from filename must be within 1 day of audit timestamp" -ForegroundColor Cyan

function Test-ReportDateWithinRange {
    <#
    .SYNOPSIS
        Checks that the date in the report filename is within 1 day of the audit timestamp.
    .PARAMETER OutputFile
        The output_file path containing a date (YYYYMMDD or YYYY-MM-DD).
    .PARAMETER AuditTimestamp
        The audit entry timestamp as a [datetime].
    .OUTPUTS
        [bool] $true if dates are within 24 hours, $false otherwise.
    #>
    param(
        [Parameter(Mandatory)][string]$OutputFile,
        [Parameter(Mandatory)][datetime]$AuditTimestamp
    )

    $filename = [System.IO.Path]::GetFileName($OutputFile)

    # Try YYYYMMDD pattern first
    if ($filename -match '(\d{4})(\d{2})(\d{2})') {
        $year = [int]$Matches[1]
        $month = [int]$Matches[2]
        $day = [int]$Matches[3]
    }
    # Try YYYY-MM-DD pattern
    elseif ($filename -match '(\d{4})-(\d{2})-(\d{2})') {
        $year = [int]$Matches[1]
        $month = [int]$Matches[2]
        $day = [int]$Matches[3]
    }
    else {
        # No date found in filename
        return $false
    }

    try {
        $fileDate = [datetime]::new($year, $month, $day)
    } catch {
        return $false
    }

    $diff = [Math]::Abs(($AuditTimestamp.Date - $fileDate).TotalDays)
    return ($diff -le 1)
}

# Same day
Assert-True (Test-ReportDateWithinRange `
    -OutputFile "output/bug-killer/daily-summary-20260401.html" `
    -AuditTimestamp ([datetime]"2026-04-01T08:30:00")) `
    "Valid: report date 20260401 matches audit date 2026-04-01"

# Next day (job ran at 11pm, report stamped next day after midnight)
Assert-True (Test-ReportDateWithinRange `
    -OutputFile "output/bug-killer/daily-summary-20260402.html" `
    -AuditTimestamp ([datetime]"2026-04-01T23:45:00")) `
    "Valid: report date 20260402 is within 1 day of audit 2026-04-01T23:45"

# YYYY-MM-DD format
Assert-True (Test-ReportDateWithinRange `
    -OutputFile "output/scrum-master/shiproom-hygiene-2026-04-01.html" `
    -AuditTimestamp ([datetime]"2026-04-01T05:00:00")) `
    "Valid: YYYY-MM-DD format date matches audit timestamp"

# Too far apart -- 3 days off
Assert-True (-not (Test-ReportDateWithinRange `
    -OutputFile "output/bug-killer/daily-summary-20260401.html" `
    -AuditTimestamp ([datetime]"2026-04-04T08:30:00"))) `
    "Invalid: report date 20260401 is 3 days from audit date 2026-04-04"

# No date in filename
Assert-True (-not (Test-ReportDateWithinRange `
    -OutputFile "output/bug-killer/daily-summary-latest.html" `
    -AuditTimestamp ([datetime]"2026-04-01T08:30:00"))) `
    "Invalid: no date found in filename 'daily-summary-latest.html'"

# Previous day (job ran early morning, report from yesterday's data)
Assert-True (Test-ReportDateWithinRange `
    -OutputFile "output/auditor/failure-review-20260331.html" `
    -AuditTimestamp ([datetime]"2026-04-01T00:15:00")) `
    "Valid: report date 20260331 is within 1 day of audit 2026-04-01T00:15"

# ========================================
# TC5: Test-ReportPathBelongsToAgent function is importable and reusable
# ========================================
Write-Host "`nTC5: Test-ReportPathBelongsToAgent function validates correctly across edge cases" -ForegroundColor Cyan

# Backslash path separators (Windows)
Assert-True (Test-ReportPathBelongsToAgent -AgentName "bug-killer" -JobName "daily-scan" `
    -OutputFile "output\bug-killer\daily-summary-20260401.html") `
    "Valid: backslash paths are normalized correctly"

# Agent name as first directory (relative path without output/ prefix)
Assert-True (Test-ReportPathBelongsToAgent -AgentName "bug-killer" -JobName "daily-scan" `
    -OutputFile "bug-killer/daily-summary-20260401.html") `
    "Valid: relative path bug-killer/daily-summary-20260401.html accepted"

# Full absolute path
Assert-True (Test-ReportPathBelongsToAgent -AgentName "auditor" -JobName "sprint-review" `
    -OutputFile "Q:/src/personal_projects/virtual-office/output/auditor/sprint-progress-20260401.html") `
    "Valid: full absolute path with /auditor/ directory accepted"

# Empty-ish edge cases
Assert-True (-not (Test-ReportPathBelongsToAgent -AgentName "bug-killer" -JobName "daily-scan" `
    -OutputFile "")) `
    "Invalid: empty string path rejected"

Assert-True (-not (Test-ReportPathBelongsToAgent -AgentName "bug-killer" -JobName "daily-scan" `
    -OutputFile "output/bug-killer-extra/daily-summary-20260401.html")) `
    "Invalid: partial agent name match 'bug-killer-extra' rejected for 'bug-killer'"

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-ReportPathValidation: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
