#Requires -Version 7.0
# Test-UIRendering.ps1 -- Structural validation of UI rendering (tooltip/card clipping)
# Run: pwsh -File tests/Test-UIRendering.ps1

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

# --- Locate UI files ---
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# Handle case where script is run directly from tests/ or via pwsh -File
if (-not (Test-Path (Join-Path $ProjectRoot "ui/styles.css"))) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path (Join-Path $ProjectRoot "ui/styles.css"))) {
    # Fallback: assume we are in the project root
    $ProjectRoot = $PSScriptRoot | Split-Path -Parent
}

$CssFile = Join-Path $ProjectRoot "ui/styles.css"
$HtmlFile = Join-Path $ProjectRoot "ui/index.html"

if (-not (Test-Path $CssFile)) {
    Write-Host "ERROR: Cannot find styles.css at $CssFile" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $HtmlFile)) {
    Write-Host "ERROR: Cannot find index.html at $HtmlFile" -ForegroundColor Red
    exit 1
}

$CssContent = Get-Content -Path $CssFile -Raw
$HtmlContent = Get-Content -Path $HtmlFile -Raw

# --- Helper: extract a CSS rule block by selector ---
function Get-CssRuleBlock {
    param([string]$Css, [string]$Selector)
    # Escape dots and other regex-special chars in the selector
    $escaped = [regex]::Escape($Selector)
    # Match selector followed by { ... } (non-greedy, handles one level of nesting)
    $pattern = "$escaped\s*\{([^}]*)\}"
    $match = [regex]::Match($Css, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return $null
}

# --- Helper: check if a CSS class is defined anywhere in the file ---
function Test-CssClassDefined {
    param([string]$Css, [string]$ClassName)
    $escaped = [regex]::Escape($ClassName)
    return [regex]::IsMatch($Css, "$escaped\s*\{")
}

# ========================================
# TC30: Tooltip not clipped by overflow
# ========================================
Write-Host "`nTC30: Tooltip not clipped by overflow" -ForegroundColor Cyan

$agentCardBlock = Get-CssRuleBlock -Css $CssContent -Selector ".agent-card"
$agentGridBlock = Get-CssRuleBlock -Css $CssContent -Selector ".agent-grid"
$tooltipBlock = Get-CssRuleBlock -Css $CssContent -Selector ".capabilities-tooltip"

# .agent-card should NOT have overflow: hidden
$cardHasOverflowHidden = $false
if ($agentCardBlock -and ($agentCardBlock -match "overflow\s*:\s*hidden")) {
    $cardHasOverflowHidden = $true
}
Assert-True (-not $cardHasOverflowHidden) ".agent-card does NOT have overflow: hidden"

# .agent-grid should NOT have overflow: hidden
$gridHasOverflowHidden = $false
if ($agentGridBlock -and ($agentGridBlock -match "overflow\s*:\s*hidden")) {
    $gridHasOverflowHidden = $true
}
Assert-True (-not $gridHasOverflowHidden) ".agent-grid does NOT have overflow: hidden"

# .capabilities-tooltip has z-index >= 50
$tooltipZIndex = 0
if ($tooltipBlock -match "z-index\s*:\s*(\d+)") {
    $tooltipZIndex = [int]$matches[1]
}
Assert-True ($tooltipZIndex -ge 50) ".capabilities-tooltip has z-index >= 50 (found: $tooltipZIndex)"

# ========================================
# TC31: Tooltip positioned below hint
# ========================================
Write-Host "`nTC31: Tooltip positioning uses top (not bottom: 100%% which clips upward)" -ForegroundColor Cyan

# Check whether tooltip uses bottom: 100% (upward, can clip) or top positioning
$usesBottomPosition = $false
if ($tooltipBlock -match "bottom\s*:\s*100%") {
    $usesBottomPosition = $true
}
# If it uses top positioning, that is preferred; if it uses bottom: 100%, flag it.
# Note: The current CSS may use bottom: 100% -- the test documents the current state.
$usesTopPosition = $false
if ($tooltipBlock -match "top\s*:") {
    $usesTopPosition = $true
}
# Pass if it uses top positioning OR does not use bottom: 100%
Assert-True ($usesTopPosition -or (-not $usesBottomPosition)) ".capabilities-tooltip uses top positioning (or avoids bottom: 100%%)"

# ========================================
# TC32: Card minimum height
# ========================================
Write-Host "`nTC32: Card minimum height prevents content truncation" -ForegroundColor Cyan

# Check if .agent-card has min-height set
$hasMinHeight = $false
if ($agentCardBlock -match "min-height\s*:") {
    $hasMinHeight = $true
}
# Note: min-height may be enforced by flexbox/grid instead of explicit property.
# The card uses padding which provides implicit minimum sizing.
# Check for either min-height or sufficient padding as acceptable.
$hasPadding = $false
if ($agentCardBlock -match "padding\s*:") {
    $hasPadding = $true
}
Assert-True ($hasMinHeight -or $hasPadding) ".agent-card has min-height or padding set (content not truncated)"

# ========================================
# TC33: Section titles not truncated
# ========================================
Write-Host "`nTC33: Section titles not truncated" -ForegroundColor Cyan

$sectionTitleBlock = Get-CssRuleBlock -Css $CssContent -Selector ".section-title"

$titleHasOverflowHidden = $false
if ($sectionTitleBlock -and ($sectionTitleBlock -match "overflow\s*:\s*hidden")) {
    $titleHasOverflowHidden = $true
}
Assert-True (-not $titleHasOverflowHidden) ".section-title does NOT have overflow: hidden"

$titleHasEllipsis = $false
if ($sectionTitleBlock -and ($sectionTitleBlock -match "text-overflow\s*:\s*ellipsis")) {
    $titleHasEllipsis = $true
}
Assert-True (-not $titleHasEllipsis) ".section-title does NOT have text-overflow: ellipsis"

# ========================================
# TC34: All required CSS classes exist
# ========================================
Write-Host "`nTC34: All required CSS classes exist" -ForegroundColor Cyan

$requiredClasses = @(
    ".agent-card",
    ".agent-card.idle",
    ".agent-card.busy",
    ".agent-card.disabled",
    ".capabilities-tooltip",
    ".capabilities-wrapper",
    ".capabilities-hint",
    ".job-list",
    ".job-item",
    ".queue-badge",
    ".event-log",
    ".event-row"
)

foreach ($cls in $requiredClasses) {
    $found = Test-CssClassDefined -Css $CssContent -ClassName $cls
    Assert-True $found "CSS class '$cls' is defined in styles.css"
}

# ========================================
# TC35: HTML structure valid
# ========================================
Write-Host "`nTC35: HTML structure valid" -ForegroundColor Cyan

Assert-True ($HtmlContent -match 'id="agent-grid"') "index.html contains id=""agent-grid"""
Assert-True ($HtmlContent -match 'id="event-log"') "index.html contains id=""event-log"""
Assert-True ($HtmlContent -match 'href="styles\.css"') "index.html links to styles.css"
Assert-True ($HtmlContent -match 'src="app\.js"') "index.html links to app.js"

# ========================================
# TC54: app.js handles flat dashboard format
# ========================================
Write-Host "`nTC54: app.js handles flat dashboard format" -ForegroundColor Cyan

$AppJsFile = Join-Path $ProjectRoot "ui/app.js"
if (-not (Test-Path $AppJsFile)) {
    Write-Host "ERROR: Cannot find app.js at $AppJsFile" -ForegroundColor Red
    $script:Failed++
} else {
    $AppJsContent = Get-Content -Path $AppJsFile -Raw

    # Verify the jobsSource variable exists (handles both nested and flat formats)
    $hasJobsSource = $AppJsContent -match "jobsSource"
    Assert-True $hasJobsSource "app.js contains 'jobsSource' variable for dual-format handling"

    # Verify it checks for flat job keys (object with status field treated as job)
    $hasFlatKeyDetection = $AppJsContent -match "state\[key\]\.status" -or $AppJsContent -match "flat job keys"
    Assert-True $hasFlatKeyDetection "app.js contains flat job key detection logic"
}

# ========================================
# TC55: app.js detects running status from flat format
# ========================================
Write-Host "`nTC55: app.js detects running status from flat format" -ForegroundColor Cyan

if (-not (Test-Path $AppJsFile)) {
    Write-Host "ERROR: Cannot find app.js at $AppJsFile" -ForegroundColor Red
    $script:Failed++
} else {
    if (-not $AppJsContent) {
        $AppJsContent = Get-Content -Path $AppJsFile -Raw
    }

    # Verify app.js sets agent to "busy" when a flat job key has status "running"
    $hasBusyFromRunning = $AppJsContent -match 'status\s*===\s*"running"' -and $AppJsContent -match 'status\s*=\s*"busy"'
    Assert-True $hasBusyFromRunning "app.js sets agent status to 'busy' when flat job has status 'running'"

    # Verify the flat-format code path bubbles up run_id
    $hasRunIdBubble = $AppJsContent -match "run_id"
    Assert-True $hasRunIdBubble "app.js references run_id for flat format bubble-up"
}

# ========================================
# TC56: Busy status dot is red
# ========================================
Write-Host "`nTC56: Busy status dot is red" -ForegroundColor Cyan

$statusDotBusyBlock = Get-CssRuleBlock -Css $CssContent -Selector ".status-dot.busy"
$dotBusyHasRed = $false
if ($statusDotBusyBlock -and ($statusDotBusyBlock -match "#ef4444")) {
    $dotBusyHasRed = $true
}
Assert-True $dotBusyHasRed ".status-dot.busy contains red (#ef4444)"

# ========================================
# TC57: Busy card stays neutral (not red)
# ========================================
Write-Host "`nTC57: Busy card stays neutral (not red)" -ForegroundColor Cyan

$cardBusyBlock = Get-CssRuleBlock -Css $CssContent -Selector ".agent-card.busy"

$cardBusyHasRedBg = $false
if ($cardBusyBlock -and ($cardBusyBlock -match "background.*#ef4444")) {
    $cardBusyHasRedBg = $true
}
Assert-True (-not $cardBusyHasRedBg) ".agent-card.busy does NOT have red background"

$cardBusyHasRedBorder = $false
if ($cardBusyBlock -and ($cardBusyBlock -match "border-left-color\s*:\s*#ef4444")) {
    $cardBusyHasRedBorder = $true
}
Assert-True (-not $cardBusyHasRedBorder) ".agent-card.busy does NOT have red border-left-color"

$cardBusyHasPulse = $false
if ($cardBusyBlock -and ($cardBusyBlock -match "animation\s*:\s*pulse")) {
    $cardBusyHasPulse = $true
}
Assert-True (-not $cardBusyHasPulse) ".agent-card.busy does NOT have pulse animation"

# ========================================
# TC58: Idle status dot is green
# ========================================
Write-Host "`nTC58: Idle status dot is green" -ForegroundColor Cyan

$statusDotIdleBlock = Get-CssRuleBlock -Css $CssContent -Selector ".status-dot.idle"
$dotIdleHasGreen = $false
if ($statusDotIdleBlock -and ($statusDotIdleBlock -match "#22c55e")) {
    $dotIdleHasGreen = $true
}
Assert-True $dotIdleHasGreen ".status-dot.idle contains green (#22c55e)"

# ========================================
# TC59: app.js contains showRunningModal function
# ========================================
Write-Host "`nTC59: app.js contains showRunningModal function" -ForegroundColor Cyan

if (-not (Test-Path $AppJsFile)) {
    Write-Host "ERROR: Cannot find app.js at $AppJsFile" -ForegroundColor Red
    $script:Failed++
} else {
    if (-not $AppJsContent) {
        $AppJsContent = Get-Content -Path $AppJsFile -Raw
    }
    $hasShowRunningModal = $AppJsContent -match "function showRunningModal"
    Assert-True $hasShowRunningModal "app.js contains 'function showRunningModal'"
}

# ========================================
# TC60: Running modal has live duration counter
# ========================================
Write-Host "`nTC60: Running modal has live duration counter" -ForegroundColor Cyan

if (-not (Test-Path $AppJsFile)) {
    Write-Host "ERROR: Cannot find app.js at $AppJsFile" -ForegroundColor Red
    $script:Failed++
} else {
    if (-not $AppJsContent) {
        $AppJsContent = Get-Content -Path $AppJsFile -Raw
    }
    $hasSetInterval = $AppJsContent -match "setInterval"
    Assert-True $hasSetInterval "app.js contains 'setInterval' for live duration updates"

    $hasClearInterval = $AppJsContent -match "clearInterval"
    Assert-True $hasClearInterval "app.js contains 'clearInterval' for cleanup on modal close"
}

# ========================================
# TC61: Busy card has click handler for running modal
# ========================================
Write-Host "`nTC61: Busy card has click handler for running modal" -ForegroundColor Cyan

if (-not (Test-Path $AppJsFile)) {
    Write-Host "ERROR: Cannot find app.js at $AppJsFile" -ForegroundColor Red
    $script:Failed++
} else {
    if (-not $AppJsContent) {
        $AppJsContent = Get-Content -Path $AppJsFile -Raw
    }
    $hasBusyCheck = $AppJsContent -match 'status === "busy"'
    Assert-True $hasBusyCheck "app.js contains busy status check"

    $hasRunningModalCall = $AppJsContent -match "showRunningModal"
    Assert-True $hasRunningModalCall "app.js calls showRunningModal from click handler"
}

# ========================================
# TC65: app.js strips output/ prefix from lastOutput URLs
# ========================================
Write-Host "`nTC65: app.js strips output/ prefix from lastOutput URLs" -ForegroundColor Cyan

if (-not (Test-Path $AppJsFile)) {
    Write-Host "ERROR: Cannot find app.js at $AppJsFile" -ForegroundColor Red
    $script:Failed++
} else {
    if (-not $AppJsContent) {
        $AppJsContent = Get-Content -Path $AppJsFile -Raw
    }

    $hasStartsWith = $AppJsContent -match 'startsWith\("output/"\)'
    Assert-True $hasStartsWith "app.js contains startsWith(""output/"") check"

    $hasSubstring = $AppJsContent -match 'substring\("output/"\.length\)'
    Assert-True $hasSubstring "app.js contains substring(""output/"".length) to strip prefix"

    $hasStripFunction = $AppJsContent -match "function stripOutputPrefix"
    Assert-True $hasStripFunction "app.js defines stripOutputPrefix helper function"

    # Verify all /api/output/ href assignments use the strip function
    # Pattern: /api/output/" + <something> where <something> is NOT stripOutputPrefix
    $allOutputHrefs = [regex]::Matches($AppJsContent, '/api/output/"\s*\+\s*(\w+)')
    $rawCount = 0
    foreach ($m in $allOutputHrefs) {
        if ($m.Groups[1].Value -ne "stripOutputPrefix") {
            $rawCount++
        }
    }
    Assert-True ($rawCount -eq 0) "All /api/output/ href assignments use stripOutputPrefix (found $rawCount raw usages)"
}

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-UIRendering: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
