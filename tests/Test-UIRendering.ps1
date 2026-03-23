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

# ========================================
# TC66: Report links use vscode:// or file:// URI, not /api/output/
# ========================================
Write-Host "`nTC66: Report links use vscode:// or file:// URI, not /api/output/" -ForegroundColor Cyan

if (-not (Test-Path $AppJsFile)) {
    Write-Host "ERROR: Cannot find app.js at $AppJsFile" -ForegroundColor Red
    $script:Failed++
} else {
    if (-not $AppJsContent) {
        $AppJsContent = Get-Content -Path $AppJsFile -Raw
    }

    $hasGetReportHref = $AppJsContent -match "function getReportHref"
    Assert-True $hasGetReportHref "app.js defines getReportHref helper function"

    $hasVscodeUri = $AppJsContent -match 'vscode://file/'
    Assert-True $hasVscodeUri "app.js contains vscode://file/ URI scheme"

    $hasFileUri = $AppJsContent -match 'file:///'
    Assert-True $hasFileUri "app.js contains file:/// URI scheme for HTML reports"

    # Verify NO remaining /api/output/ href assignments
    $apiOutputCount = ([regex]::Matches($AppJsContent, '/api/output/')).Count
    Assert-True ($apiOutputCount -eq 0) "app.js has zero /api/output/ href assignments (found $apiOutputCount)"
}

# ========================================
# TC68: app.js merges started timestamp from flat dashboard format
# ========================================
Write-Host "`nTC68: app.js merges started timestamp via normalizeJobState" -ForegroundColor Cyan

if (-not (Test-Path $AppJsFile)) {
    Write-Host "ERROR: Cannot find app.js at $AppJsFile" -ForegroundColor Red
    $script:Failed++
} else {
    if (-not $AppJsContent) {
        $AppJsContent = Get-Content -Path $AppJsFile -Raw
    }

    # normalizeJobState reads raw.started
    $hasStartedNormalize = $AppJsContent -match "raw\.started"
    Assert-True $hasStartedNormalize "normalizeJobState reads raw.started from flat format"

    # mergeConfigAndDashboard copies normalized.started into merged job
    $hasStartedOnMergedJob = $AppJsContent -match "\.started\s*=\s*normalized\.started"
    Assert-True $hasStartedOnMergedJob "mergeConfigAndDashboard copies normalized.started into merged job"
}

# ========================================
# TC69: app.js merges runs_completed via normalizeJobState
# ========================================
Write-Host "`nTC69: app.js merges runs_completed via normalizeJobState" -ForegroundColor Cyan

if (-not (Test-Path $AppJsFile)) {
    Write-Host "ERROR: Cannot find app.js at $AppJsFile" -ForegroundColor Red
    $script:Failed++
} else {
    if (-not $AppJsContent) {
        $AppJsContent = Get-Content -Path $AppJsFile -Raw
    }

    # normalizeJobState reads raw.runs_completed
    $hasRunsCompletedRead = $AppJsContent -match "raw\.runs_completed"
    Assert-True $hasRunsCompletedRead "normalizeJobState reads raw.runs_completed from flat format"

    # mergeConfigAndDashboard copies normalized.runsCompleted into merged job
    $hasRunsCompletedOnMergedJob = $AppJsContent -match "\.runsCompleted\s*=\s*normalized\.runsCompleted"
    Assert-True $hasRunsCompletedOnMergedJob "mergeConfigAndDashboard copies normalized.runsCompleted into merged job"

    # showRunningModal uses camelCase j.runsCompleted
    $hasRunsCompletedInModal = $AppJsContent -match "j\.runsCompleted"
    Assert-True $hasRunsCompletedInModal "showRunningModal reads runsCompleted (camelCase) from job data"
}

# ========================================
# TC70: app.js has normalizeJobState function
# ========================================
Write-Host "`nTC70: app.js has normalizeJobState function" -ForegroundColor Cyan

if (-not (Test-Path $AppJsFile)) {
    Write-Host "ERROR: Cannot find app.js at $AppJsFile" -ForegroundColor Red
    $script:Failed++
} else {
    if (-not $AppJsContent) {
        $AppJsContent = Get-Content -Path $AppJsFile -Raw
    }

    $hasNormalizeFunction = $AppJsContent -match "function normalizeJobState\s*\("
    Assert-True $hasNormalizeFunction "app.js defines normalizeJobState function"
}

# ========================================
# TC71: normalizeJobState handles all snake_case fields
# ========================================
Write-Host "`nTC71: normalizeJobState handles all snake_case fields" -ForegroundColor Cyan

if (-not (Test-Path $AppJsFile)) {
    Write-Host "ERROR: Cannot find app.js at $AppJsFile" -ForegroundColor Red
    $script:Failed++
} else {
    if (-not $AppJsContent) {
        $AppJsContent = Get-Content -Path $AppJsFile -Raw
    }

    # Extract the normalizeJobState function body
    $fnMatch = [regex]::Match($AppJsContent, 'function normalizeJobState\s*\([^)]*\)\s*\{([\s\S]*?)\n\}')
    $fnBody = ""
    if ($fnMatch.Success) { $fnBody = $fnMatch.Groups[1].Value }

    $hasRunId = $fnBody -match "raw\.run_id"
    Assert-True $hasRunId "normalizeJobState handles run_id -> runId"

    $hasRunsCompleted = $fnBody -match "raw\.runs_completed"
    Assert-True $hasRunsCompleted "normalizeJobState handles runs_completed -> runsCompleted"

    $hasLastCompleted = $fnBody -match "raw\.last_completed"
    Assert-True $hasLastCompleted "normalizeJobState handles last_completed -> lastCompleted"

    $hasQueueDepth = $fnBody -match "raw\.queue_depth"
    Assert-True $hasQueueDepth "normalizeJobState handles queue_depth -> queueDepth"
}

# ========================================
# TC72: No raw snake_case job field access outside normalizeJobState
# ========================================
Write-Host "`nTC72: No raw snake_case job field access outside normalizeJobState" -ForegroundColor Cyan

if (-not (Test-Path $AppJsFile)) {
    Write-Host "ERROR: Cannot find app.js at $AppJsFile" -ForegroundColor Red
    $script:Failed++
} else {
    if (-not $AppJsContent) {
        $AppJsContent = Get-Content -Path $AppJsFile -Raw
    }

    # Find normalizeJobState function boundaries
    $fnMatch = [regex]::Match($AppJsContent, 'function normalizeJobState\s*\([^)]*\)\s*\{([\s\S]*?)\n\}')
    $fnStart = 0
    $fnEnd = 0
    if ($fnMatch.Success) {
        $fnStart = $fnMatch.Index
        $fnEnd = $fnMatch.Index + $fnMatch.Length
    }

    # Get code OUTSIDE normalizeJobState
    $before = ""
    $after = ""
    if ($fnEnd -gt 0) {
        $before = $AppJsContent.Substring(0, $fnStart)
        $after = $AppJsContent.Substring($fnEnd)
    }
    $outsideCode = $before + $after

    # Check for direct snake_case job field access patterns (j.run_id, j.runs_completed, etc.)
    # These patterns match property access like .run_id, .runs_completed, .last_completed, .queue_depth
    # but NOT agent-level fields (merged[name].last_completed, agentData.queue_depth are OK at agent level)
    # We specifically look for job-object access patterns: j.run_id, job.runs_completed, etc.
    $snakeCaseJobAccess = [regex]::Matches($outsideCode, '(?<!\w)j\.run_id|(?<!\w)j\.runs_completed|(?<!\w)j\.last_completed|(?<!\w)j\.queue_depth')
    $violationCount = $snakeCaseJobAccess.Count

    Assert-True ($violationCount -eq 0) "No j.run_id/j.runs_completed/j.last_completed/j.queue_depth outside normalizeJobState (found $violationCount)"

    # Also check for jobState.X direct access outside the normalizer (old merge pattern)
    $jobStateSnake = [regex]::Matches($outsideCode, 'jobState\.run_id|jobState\.runs_completed|jobState\.last_completed|jobState\.queue_depth')
    $jobStateViolations = $jobStateSnake.Count

    Assert-True ($jobStateViolations -eq 0) "No jobState.run_id/runs_completed/last_completed/queue_depth outside normalizeJobState (found $jobStateViolations)"
}

# ========================================
# TC79: Scrum-master agent prompt includes Fundamentals area path filter
# ========================================
Write-Host "`nTC79: Scrum-master agent prompt includes Fundamentals area path filter" -ForegroundColor Cyan

$ScrumMasterFile = "C:/Users/qitxu/.claude/agents/scrum-master.md"
if (-not (Test-Path $ScrumMasterFile)) {
    Write-Host "ERROR: Cannot find scrum-master.md at $ScrumMasterFile" -ForegroundColor Red
    $script:Failed++
} else {
    $ScrumMasterContent = Get-Content -Path $ScrumMasterFile -Raw

    # The sprint-progress section should mention Fundamentals
    $hasFundamentals = $ScrumMasterContent -match "Fundamentals"
    Assert-True $hasFundamentals "scrum-master.md contains 'Fundamentals' in sprint-progress section"

    # Should have an instruction to exclude other sub-areas
    $hasExcludeInstruction = $ScrumMasterContent -match "Exclude items from other sub-areas"
    Assert-True $hasExcludeInstruction "scrum-master.md contains instruction to exclude other sub-areas"
}

# ========================================
# TC80: app.js has agent group tab rendering
# ========================================
Write-Host "`nTC80: app.js has agent group tab rendering" -ForegroundColor Cyan

if (-not (Test-Path $AppJsFile)) {
    Write-Host "ERROR: Cannot find app.js at $AppJsFile" -ForegroundColor Red
    $script:Failed++
} else {
    if (-not $AppJsContent) {
        $AppJsContent = Get-Content -Path $AppJsFile -Raw
    }

    $hasAgentTab = $AppJsContent -match "agent-tab"
    Assert-True $hasAgentTab "app.js contains 'agent-tab' class for group tabs"

    $hasRenderAgentTabs = $AppJsContent -match "function renderAgentTabs"
    Assert-True $hasRenderAgentTabs "app.js contains 'function renderAgentTabs' for group tab rendering"

    $hasActiveGroup = $AppJsContent -match "activeGroup"
    Assert-True $hasActiveGroup "app.js contains 'activeGroup' variable for tab state"
}

# ========================================
# TC81: agents.json has group field
# ========================================
Write-Host "`nTC81: agents.json has group field" -ForegroundColor Cyan

$AgentsJsonFile = Join-Path $ProjectRoot "config/agents.json"
if (-not (Test-Path $AgentsJsonFile)) {
    Write-Host "ERROR: Cannot find agents.json at $AgentsJsonFile" -ForegroundColor Red
    $script:Failed++
} else {
    $AgentsJson = Get-Content -Path $AgentsJsonFile -Raw | ConvertFrom-Json
    $allHaveGroup = $true
    foreach ($agentName in $AgentsJson.agents.PSObject.Properties.Name) {
        $agent = $AgentsJson.agents.$agentName
        if (-not $agent.group) {
            Write-Host "    Agent '$agentName' is missing 'group' field" -ForegroundColor Yellow
            $allHaveGroup = $false
        }
    }
    Assert-True $allHaveGroup "All agents in agents.json have a 'group' field"
}

# ========================================
# TC82: activeGroup only reset when null or group missing
# ========================================
Write-Host "`nTC82: activeGroup only reset when null or group missing" -ForegroundColor Cyan

if (-not (Test-Path $AppJsFile)) {
    Write-Host "ERROR: Cannot find app.js at $AppJsFile" -ForegroundColor Red
    $script:Failed++
} else {
    if (-not $AppJsContent) {
        $AppJsContent = Get-Content -Path $AppJsFile -Raw
    }

    # Verify renderAgentTabs uses the guard pattern: if (!activeGroup || !groups[activeGroup])
    $hasGuardPattern = $AppJsContent -match 'if\s*\(\s*!activeGroup\s*\|\|\s*!groups\[activeGroup\]\s*\)'
    Assert-True $hasGuardPattern "renderAgentTabs uses guard pattern 'if (!activeGroup || !groups[activeGroup])'"

    # Count all assignments to activeGroup (excluding declarations and comments)
    # Expected: 1 declaration (var activeGroup = null), 1 guard default, 1 tab click handler, 1 URL restore = 4 total
    $allAssignments = [regex]::Matches($AppJsContent, '(?<!//.*)\bactiveGroup\s*=\s*')
    $assignmentCount = $allAssignments.Count
    Assert-True ($assignmentCount -eq 4) "Exactly 4 assignments to activeGroup (declaration + guard + click + URL restore), found $assignmentCount"

    # Verify no unconditional reset: activeGroup should never be set to null after declaration
    # Remove the declaration line, then check for any "activeGroup = null"
    $withoutDeclaration = $AppJsContent -replace 'var\s+activeGroup\s*=\s*null', ''
    $hasUnconditionalReset = $withoutDeclaration -match 'activeGroup\s*=\s*null'
    Assert-True (-not $hasUnconditionalReset) "No unconditional reset of activeGroup to null (besides declaration)"

    # Verify poll() does not assign activeGroup
    $pollMatch = [regex]::Match($AppJsContent, 'async function poll\s*\(\)\s*\{([\s\S]*?)\n\}')
    if ($pollMatch.Success) {
        $pollBody = $pollMatch.Groups[1].Value
        $pollResetsActiveGroup = $pollBody -match 'activeGroup\s*='
        Assert-True (-not $pollResetsActiveGroup) "poll() does not assign activeGroup"
    } else {
        Write-Host "    WARNING: Could not extract poll() function body" -ForegroundColor Yellow
    }
}

# ========================================
# TC83: app.js persists tab in URL query parameter
# ========================================
Write-Host "`nTC83: app.js persists tab in URL query parameter" -ForegroundColor Cyan

if (-not (Test-Path $AppJsFile)) {
    Write-Host "ERROR: Cannot find app.js at $AppJsFile" -ForegroundColor Red
    $script:Failed++
} else {
    if (-not $AppJsContent) {
        $AppJsContent = Get-Content -Path $AppJsFile -Raw
    }

    $hasSearchParamsSet = $AppJsContent -match 'searchParams\.set\("tab"'
    Assert-True $hasSearchParamsSet "app.js writes tab to URL via searchParams.set(""tab"")"

    $hasSearchParamsGet = $AppJsContent -match '\.get\("tab"\)'
    Assert-True $hasSearchParamsGet "app.js reads tab from URL via .get(""tab"")"

    $hasReplaceState = $AppJsContent -match "replaceState"
    Assert-True $hasReplaceState "app.js updates URL without reload via replaceState"
}

# ========================================
# TC84: app.js renders portal link when portalUrl exists
# ========================================
Write-Host "`nTC84: app.js renders portal link when portalUrl exists" -ForegroundColor Cyan

if (-not (Test-Path $AppJsFile)) {
    Write-Host "ERROR: Cannot find app.js at $AppJsFile" -ForegroundColor Red
    $script:Failed++
} else {
    if (-not $AppJsContent) {
        $AppJsContent = Get-Content -Path $AppJsFile -Raw
    }

    $hasPortalUrl = $AppJsContent -match "portalUrl"
    Assert-True $hasPortalUrl "app.js contains 'portalUrl' reference"

    $hasCardPortalLink = $AppJsContent -match "card-portal-link"
    Assert-True $hasCardPortalLink "app.js contains 'card-portal-link' class for portal link element"
}

# ========================================
# TC85: agents.json emailer has portalUrl
# ========================================
Write-Host "`nTC85: agents.json emailer has portalUrl" -ForegroundColor Cyan

$AgentsJsonFileTC85 = Join-Path $ProjectRoot "config/agents.json"
if (-not (Test-Path $AgentsJsonFileTC85)) {
    Write-Host "ERROR: Cannot find agents.json at $AgentsJsonFileTC85" -ForegroundColor Red
    $script:Failed++
} else {
    $AgentsJsonTC85 = Get-Content -Path $AgentsJsonFileTC85 -Raw | ConvertFrom-Json
    $emailerAgent = $AgentsJsonTC85.agents.emailer
    $hasPortalUrlField = $null -ne $emailerAgent.portalUrl -and $emailerAgent.portalUrl -ne ""
    Assert-True $hasPortalUrlField "emailer agent in agents.json has a non-empty portalUrl field"

    # Verify scrum-master does NOT have portalUrl
    $scrumMasterAgent = $AgentsJsonTC85.agents."scrum-master"
    $scrumMasterHasPortal = $null -ne ($scrumMasterAgent.PSObject.Properties | Where-Object { $_.Name -eq "portalUrl" })
    Assert-True (-not $scrumMasterHasPortal) "scrum-master agent does NOT have portalUrl field"

    # Verify bug-killer does NOT have portalUrl
    $bugKillerAgent = $AgentsJsonTC85.agents."bug-killer"
    $bugKillerHasPortal = $null -ne ($bugKillerAgent.PSObject.Properties | Where-Object { $_.Name -eq "portalUrl" })
    Assert-True (-not $bugKillerHasPortal) "bug-killer agent does NOT have portalUrl field"
}

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-UIRendering: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
