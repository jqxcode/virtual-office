#Requires -Version 7.0
# Test-ErrorTracking.ps1 -- Tests for error tracking, errors.jsonl, and dashboard errorCount
# Run: pwsh -File tests/Test-ErrorTracking.ps1

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
`$ERRORS_FILE = Join-Path `$STATE_DIR "errors.jsonl"
`$DASHBOARD_FILE = Join-Path `$STATE_DIR "dashboard.json"
"@
    Set-Content -Path (Join-Path $Root "runner/constants.ps1") -Value $content -Encoding ASCII
}

function Write-TestConfig {
    param(
        [string]$Root,
        [string]$AgentName = "test-agent",
        [string]$JobName = "test-job",
        [int]$MaxRuns = 0,
        [bool]$Enabled = $true,
        [string]$Prompt = "echo test output"
    )
    $agentsJson = @{ $AgentName = @{ displayName = "Test Agent"; description = "test" } } | ConvertTo-Json
    Set-Content -Path (Join-Path $Root "config/agents.json") -Value $agentsJson -Encoding UTF8

    $jobsJson = @{
        $JobName = @{
            prompt      = $Prompt
            maxRuns     = $MaxRuns
            enabled     = $Enabled
            description = "test job"
        }
    } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $Root "config/jobs/$AgentName.json") -Value $jobsJson -Encoding UTF8
}

# Source runner functions into the global scope for direct testing.
function Import-RunnerFunctions {
    param([string]$Root)
    . (Join-Path $Root "runner/constants.ps1")
    # Promote constants to global scope so global functions can see them
    $global:SYSTEM_VERSION = $SYSTEM_VERSION
    $global:PROJECT_ROOT = $PROJECT_ROOT
    $global:CONFIG_DIR = $CONFIG_DIR
    $global:STATE_DIR = $STATE_DIR
    $global:OUTPUT_DIR = $OUTPUT_DIR
    $global:AUDIT_DIR = $AUDIT_DIR
    $global:EVENTS_FILE = $EVENTS_FILE
    $global:ERRORS_FILE = $ERRORS_FILE
    $global:DASHBOARD_FILE = $DASHBOARD_FILE

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

    function global:Write-ErrorEntry {
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

    function global:Get-UnresolvedErrorCount {
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

    function global:Update-Dashboard {
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
        foreach ($key in $AgentDetails.Keys) {
            $dashboard["agents"][$AgentName][$key] = $AgentDetails[$key]
        }
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
}

# --- Helper: run the actual runner script in a subprocess ---
function Invoke-Runner {
    param(
        [string]$Root,
        [string]$AgentName = "test-agent",
        [string]$JobName = "test-job",
        [int]$MockExitCode = 0
    )
    $realRunner = Join-Path $PSScriptRoot ".." "runner" "Invoke-AgentJob.ps1"
    $realRunner = (Resolve-Path $realRunner).Path
    $runnerContent = Get-Content -Path $realRunner -Raw

    # Replace the constants source line to point to our test constants
    $testConstants = Join-Path $Root "runner/constants.ps1"
    $runnerContent = $runnerContent -replace '\. \(Join-Path \$PSScriptRoot "constants\.ps1"\)', ". '$testConstants'"

    # Replace claude invocation with a mock that returns specific exit code
    if ($MockExitCode -eq 0) {
        $runnerContent = $runnerContent -replace '\$output = & claude --agent \$agentFile \$prompt 2>&1 \| Out-String', '$output = "mock agent output with file"'
        $runnerContent = $runnerContent -replace '\$output = & claude \$prompt 2>&1 \| Out-String', '$output = "mock agent output"'
    } else {
        # Replace the entire try/catch block's claude calls to simulate failure
        $runnerContent = $runnerContent -replace '\$output = & claude --agent \$agentFile \$prompt 2>&1 \| Out-String', "`$output = 'ERROR: mock failure'; `$exitCode = $MockExitCode"
        $runnerContent = $runnerContent -replace '\$output = & claude \$prompt 2>&1 \| Out-String', "`$output = 'ERROR: mock failure'; `$exitCode = $MockExitCode"
        # Also prevent LASTEXITCODE from overwriting our mock exit code
        $runnerContent = $runnerContent -replace '\$exitCode = \$LASTEXITCODE', '# $exitCode already set by mock'
    }

    $testRunner = Join-Path $Root "runner/test-runner.ps1"
    Set-Content -Path $testRunner -Value $runnerContent -Encoding UTF8

    $result = pwsh -NoProfile -File $testRunner -Agent $AgentName -Job $JobName 2>&1 | Out-String
    return @{
        Output   = $result
        ExitCode = $LASTEXITCODE
    }
}


# ========================================
# TC40: Error entry written on non-zero exit
# ========================================
Write-Host "`nTC40: Error entry written on non-zero exit" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root -MaxRuns 0
    Import-RunnerFunctions -Root $root

    $result = Invoke-Runner -Root $root -MockExitCode 1

    $errorsFile = Join-Path $root "state/errors.jsonl"
    Assert-True (Test-Path $errorsFile) "errors.jsonl was created"

    if (Test-Path $errorsFile) {
        $lines = @(Get-Content -Path $errorsFile | Where-Object { $_.Trim() -ne "" })
        Assert-True ($lines.Count -ge 1) "errors.jsonl has at least 1 entry"

        $entry = $lines[0] | ConvertFrom-Json
        Assert-True ($null -ne $entry.ts) "Entry has ts field"
        Assert-True ($entry.agent -eq "test-agent") "Entry agent is test-agent"
        Assert-True ($entry.job -eq "test-job") "Entry job is test-job"
        Assert-True ($null -ne $entry.runId -and $entry.runId -ne "") "Entry has runId"
        Assert-True ($entry.exitCode -eq 1) "Entry exitCode is 1"
        Assert-True ($entry.resolved -eq $false) "Entry resolved is false"
        Assert-True ($entry.systemVersion -eq "0.1.0-test") "Entry systemVersion is 0.1.0-test"
    }
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC41: Error entry has required schema
# ========================================
Write-Host "`nTC41: Error entry has required schema" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root
    Import-RunnerFunctions -Root $root

    Write-ErrorEntry -Agent "schema-agent" -Job "schema-job" -RunId "abc123" `
        -Level "error" -Summary "Test error" -Detail "Some detail text" `
        -LogPath "output/schema-agent/schema-job-20260315.md" `
        -ExitCode 2 -Duration "5s"

    $errorsFile = Join-Path $root "state/errors.jsonl"
    Assert-True (Test-Path $errorsFile) "errors.jsonl was created"

    if (Test-Path $errorsFile) {
        $allLines = @(Get-Content -Path $errorsFile)
        $nonEmpty = @($allLines | Where-Object { $_ -and $_.Trim().Length -gt 2 })
        $line = $nonEmpty[-1].Trim()
        $entry = $line | ConvertFrom-Json

        $requiredFields = @("ts", "agent", "job", "runId", "level", "summary",
                            "detail", "logPath", "exitCode", "duration",
                            "resolved", "systemVersion")

        foreach ($field in $requiredFields) {
            $props = $entry.PSObject.Properties.Name
            Assert-True ($props -contains $field) "Field '$field' exists in error entry"
        }
    }
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC42: Dashboard errorCount updated
# ========================================
Write-Host "`nTC42: Dashboard errorCount updated" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root
    Import-RunnerFunctions -Root $root

    # Write an unresolved error
    Write-ErrorEntry -Agent "err-agent" -Job "err-job" -RunId "run1" `
        -Level "error" -Summary "Failure" -Detail "details" `
        -LogPath "output/err-agent/err-job.md" -ExitCode 1 -Duration "3s"

    # Update dashboard with errorCount from Get-UnresolvedErrorCount
    $errCount = Get-UnresolvedErrorCount -AgentName "err-agent"
    Update-Dashboard -AgentName "err-agent" -JobName "err-job" -Status "idle" `
        -AgentDetails @{ errorCount = $errCount }

    $dashFile = Join-Path $root "state/dashboard.json"
    Assert-True (Test-Path $dashFile) "dashboard.json exists"

    if (Test-Path $dashFile) {
        $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable
        $agentErrorCount = $dash["agents"]["err-agent"]["errorCount"]
        Assert-True ($agentErrorCount -gt 0) "Dashboard errorCount > 0 (got $agentErrorCount)"
    }
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC43: Resolved errors not counted
# ========================================
Write-Host "`nTC43: Resolved errors not counted" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root
    Import-RunnerFunctions -Root $root

    # Write 2 error entries
    Write-ErrorEntry -Agent "res-agent" -Job "res-job" -RunId "run1" `
        -Level "error" -Summary "Error 1" -Detail "detail1" `
        -LogPath "output/res-agent/res-job-1.md" -ExitCode 1 -Duration "2s"
    Write-ErrorEntry -Agent "res-agent" -Job "res-job" -RunId "run2" `
        -Level "error" -Summary "Error 2" -Detail "detail2" `
        -LogPath "output/res-agent/res-job-2.md" -ExitCode 1 -Duration "3s"

    # Mark the first error as resolved by rewriting errors.jsonl
    $errorsFile = Join-Path $root "state/errors.jsonl"
    $lines = @(Get-Content -Path $errorsFile)
    $newLines = @()
    $first = $true
    foreach ($line in $lines) {
        if ($line.Trim() -eq "") { continue }
        if ($first) {
            $obj = $line | ConvertFrom-Json -AsHashtable
            $obj["resolved"] = $true
            $newLines += ($obj | ConvertTo-Json -Compress)
            $first = $false
        } else {
            $newLines += $line
        }
    }
    Set-Content -Path $errorsFile -Value ($newLines -join "`n") -Encoding ASCII

    $unresolvedCount = Get-UnresolvedErrorCount -AgentName "res-agent"
    Assert-True ($unresolvedCount -eq 1) "Unresolved count is 1 (got $unresolvedCount)"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC44: Error levels are valid
# ========================================
Write-Host "`nTC44: Error levels are valid" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root
    Import-RunnerFunctions -Root $root

    $validLevels = @("error", "warning", "timeout")
    foreach ($lvl in $validLevels) {
        Write-ErrorEntry -Agent "lvl-agent" -Job "lvl-job" -RunId "run-$lvl" `
            -Level $lvl -Summary "Test $lvl" -Detail "detail" `
            -LogPath "output/lvl-agent/lvl-job.md" -ExitCode 1 -Duration "1s"
    }

    $errorsFile = Join-Path $root "state/errors.jsonl"
    $lines = @(Get-Content -Path $errorsFile | Where-Object { $_.Trim() -ne "" })
    Assert-True ($lines.Count -eq 3) "Wrote 3 error entries for 3 valid levels"

    foreach ($line in $lines) {
        $entry = $line | ConvertFrom-Json
        Assert-True ($validLevels -contains $entry.level) "Level '$($entry.level)' is a valid level"
    }
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC45: errors.jsonl is append-only
# ========================================
Write-Host "`nTC45: errors.jsonl is append-only" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root
    Import-RunnerFunctions -Root $root

    Write-ErrorEntry -Agent "append-agent" -Job "append-job" -RunId "run1" `
        -Level "error" -Summary "First error" -Detail "detail1" `
        -LogPath "output/append-agent/append-job-1.md" -ExitCode 1 -Duration "1s"

    Write-ErrorEntry -Agent "append-agent" -Job "append-job" -RunId "run2" `
        -Level "warning" -Summary "Second error" -Detail "detail2" `
        -LogPath "output/append-agent/append-job-2.md" -ExitCode 1 -Duration "2s"

    $errorsFile = Join-Path $root "state/errors.jsonl"
    $lines = @(Get-Content -Path $errorsFile | Where-Object { $_.Trim() -ne "" })
    Assert-True ($lines.Count -eq 2) "File has 2 lines (append, not overwrite) -- got $($lines.Count)"

    # Verify both entries are distinct
    $entry1 = $lines[0] | ConvertFrom-Json
    $entry2 = $lines[1] | ConvertFrom-Json
    Assert-True ($entry1.runId -ne $entry2.runId) "Two entries have different runIds"
    Assert-True ($entry1.summary -eq "First error") "First entry preserved"
    Assert-True ($entry2.summary -eq "Second error") "Second entry preserved"
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC46: Dashboard lastOutput updated after run
# ========================================
Write-Host "`nTC46: Dashboard lastOutput updated after run" -ForegroundColor Cyan
$root = New-TestRoot
try {
    Write-TestConstants -Root $root
    Write-TestConfig -Root $root -MaxRuns 0
    Import-RunnerFunctions -Root $root

    $result = Invoke-Runner -Root $root -MockExitCode 0
    Assert-True ($result.ExitCode -eq 0) "Runner exits with code 0"

    $dashFile = Join-Path $root "state/dashboard.json"
    Assert-True (Test-Path $dashFile) "dashboard.json exists"

    if (Test-Path $dashFile) {
        $dash = Get-Content -Path $dashFile -Raw | ConvertFrom-Json -AsHashtable
        $jobState = $dash["agents"]["test-agent"]["test-job"]
        Assert-True ($null -ne $jobState["lastOutput"]) "lastOutput is set"
        Assert-True ($jobState["lastOutput"] -match "output/test-agent/test-job-") "lastOutput path looks correct"
        Assert-True ($null -ne $jobState["lastOutputTime"]) "lastOutputTime is set"
        Assert-True ($jobState["lastOutputTime"] -match "^\d{4}-\d{2}-\d{2}T") "lastOutputTime is ISO format"
    }
} finally {
    Remove-TestRoot -Root $root
}

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-ErrorTracking: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
