#Requires -Version 7.0
# Test-UIAssets.ps1 -- UI asset validation tests
# Run: pwsh -File tests/Test-UIAssets.ps1

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

# --- Locate project root ---
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $ProjectRoot "ui/index.html"))) {
    $ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

$UiDir = Join-Path $ProjectRoot "ui"
$HtmlFile = Join-Path $UiDir "index.html"
$AppJsFile = Join-Path $UiDir "app.js"
$CssFile = Join-Path $UiDir "styles.css"

# ========================================
# TC1: index.html exists and contains required tab elements
# ========================================
Write-Host "`nTC1: index.html exists and contains required elements (tabs for agents, events, queue)" -ForegroundColor Cyan

Assert-True (Test-Path $HtmlFile) "index.html exists"

if (Test-Path $HtmlFile) {
    $htmlContent = Get-Content -Path $HtmlFile -Raw

    $hasTeamTab = $htmlContent -match 'data-tab="team"'
    Assert-True $hasTeamTab "index.html contains team tab (data-tab=""team"")"

    $hasHistoryTab = $htmlContent -match 'data-tab="history"'
    Assert-True $hasHistoryTab "index.html contains history tab (data-tab=""history"")"

    $hasOfficeTab = $htmlContent -match 'data-tab="office"'
    Assert-True $hasOfficeTab "index.html contains office tab (data-tab=""office"")"

    $hasAgentGrid = $htmlContent -match 'id="agent-grid"'
    Assert-True $hasAgentGrid "index.html contains agent-grid element"

    $linksAppJs = $htmlContent -match 'src="app\.js'
    Assert-True $linksAppJs "index.html links to app.js"

    $linksCss = $htmlContent -match 'href="styles\.css'
    Assert-True $linksCss "index.html links to styles.css"
}

# ========================================
# TC2: app.js has no reference to hardcoded "memo-checker"
# ========================================
Write-Host "`nTC2: app.js has no reference to hardcoded 'memo-checker' (should be 'mAuditor')" -ForegroundColor Cyan

Assert-True (Test-Path $AppJsFile) "app.js exists"

if (Test-Path $AppJsFile) {
    $appJsContent = Get-Content -Path $AppJsFile -Raw

    # The LEGACY_AGENT_NAMES mapping is allowed to reference "memo-checker" -- it maps old to new.
    # Check that "memo-checker" is NOT used outside the legacy mapping block.
    $outsideLegacy = $appJsContent -replace '(?s)var LEGACY_AGENT_NAMES\s*=\s*\{[^}]*\};', ''
    $hasMemoCheckerOutsideLegacy = $outsideLegacy -match "memo-checker"
    Assert-True (-not $hasMemoCheckerOutsideLegacy) "app.js does NOT use 'memo-checker' outside LEGACY_AGENT_NAMES mapping"
}

# ========================================
# TC3: styles.css exists
# ========================================
Write-Host "`nTC3: styles.css exists" -ForegroundColor Cyan

Assert-True (Test-Path $CssFile) "styles.css exists at $CssFile"

# ========================================
# TC4: No duplicate function definitions in app.js
# ========================================
Write-Host "`nTC4: No duplicate function definitions in app.js" -ForegroundColor Cyan

if (Test-Path $AppJsFile) {
    if (-not $appJsContent) {
        $appJsContent = Get-Content -Path $AppJsFile -Raw
    }

    # Extract all top-level function names (function foo(...))
    $funcMatches = [regex]::Matches($appJsContent, '(?m)^function\s+(\w+)\s*\(')
    $funcNames = @{}
    $duplicates = @()
    foreach ($m in $funcMatches) {
        $name = $m.Groups[1].Value
        if ($funcNames.ContainsKey($name)) {
            $duplicates += $name
        } else {
            $funcNames[$name] = $true
        }
    }

    $hasDuplicates = $duplicates.Count -gt 0
    if ($hasDuplicates) {
        Write-Host "    Duplicate functions: $($duplicates -join ', ')" -ForegroundColor Yellow
    }
    Assert-True (-not $hasDuplicates) "No duplicate top-level function definitions in app.js"
}

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-UIAssets: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
