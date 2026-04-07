#Requires -Version 7.0
# Test-V2Tabs.ps1 -- Structural validation of V2 tab features (TEAM, OFFICE, HISTORY, SCHEDULE)
# Run: pwsh -File tests/Test-V2Tabs.ps1

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
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $ProjectRoot "ui/index.html"))) {
    $ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

$HtmlFile = Join-Path $ProjectRoot "ui/index.html"
$AppJsFile = Join-Path $ProjectRoot "ui/app.js"
$CssFile = Join-Path $ProjectRoot "ui/styles.css"

if (-not (Test-Path $HtmlFile)) {
    Write-Host "ERROR: Cannot find index.html at $HtmlFile" -ForegroundColor Red
    exit 1
}

$HtmlContent = Get-Content -Path $HtmlFile -Raw
$AppJsContent = Get-Content -Path $AppJsFile -Raw
$CssContent = Get-Content -Path $CssFile -Raw

# --- Helper ---
function Get-CssRuleBlock {
    param([string]$Css, [string]$Selector)
    $escaped = [regex]::Escape($Selector)
    $pattern = "$escaped\s*\{([^}]*)\}"
    $match = [regex]::Match($Css, $pattern)
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Test-CssClassDefined {
    param([string]$Css, [string]$ClassName)
    $escaped = [regex]::Escape($ClassName)
    return [regex]::IsMatch($Css, "$escaped\s*[\{,\s]")
}

# ========================================
# TC90: HTML has TEAM tab button
# ========================================
Write-Host "`nTC90: HTML has TEAM tab button" -ForegroundColor Cyan

Assert-True ($HtmlContent -match 'data-tab="team"') "index.html contains team tab button (data-tab=""team"")"

# ========================================
# TC91: HTML has OFFICE tab button
# ========================================
Write-Host "`nTC91: HTML has OFFICE tab button" -ForegroundColor Cyan

Assert-True ($HtmlContent -match 'data-tab="office"') "index.html contains office tab button (data-tab=""office"")"

# ========================================
# TC92: HTML has HISTORY tab button
# ========================================
Write-Host "`nTC92: HTML has HISTORY tab button" -ForegroundColor Cyan

Assert-True ($HtmlContent -match 'data-tab="history"') "index.html contains history tab button (data-tab=""history"")"

# ========================================
# TC93: HTML has SCHEDULE tab button
# ========================================
Write-Host "`nTC93: HTML has SCHEDULE tab button" -ForegroundColor Cyan

Assert-True ($HtmlContent -match 'data-tab="schedule"') "index.html contains schedule tab button (data-tab=""schedule"")"

# ========================================
# TC94: HTML has view-team section with team-agent-list container
# ========================================
Write-Host "`nTC94: HTML has view-team section with team-agent-list container" -ForegroundColor Cyan

Assert-True ($HtmlContent -match 'id="view-team"') "index.html contains view-team section"
Assert-True ($HtmlContent -match 'id="team-agent-list"') "index.html contains team-agent-list container"

# ========================================
# TC95: HTML has view-office section with office-floor container
# ========================================
Write-Host "`nTC95: HTML has view-office section with office-floor container" -ForegroundColor Cyan

Assert-True ($HtmlContent -match 'id="view-office"') "index.html contains view-office section"
Assert-True ($HtmlContent -match 'id="office-floor"') "index.html contains office-floor container"

# ========================================
# TC96: HTML has view-history section with history-table and history-health-cards
# ========================================
Write-Host "`nTC96: HTML has view-history section with required elements" -ForegroundColor Cyan

Assert-True ($HtmlContent -match 'id="view-history"') "index.html contains view-history section"
Assert-True ($HtmlContent -match 'id="history-table"') "index.html contains history-table"
Assert-True ($HtmlContent -match 'id="history-health-cards"') "index.html contains history-health-cards"

# ========================================
# TC97: HTML has view-schedule section with schedule-v2-tbody
# ========================================
Write-Host "`nTC97: HTML has view-schedule section with schedule-v2-tbody" -ForegroundColor Cyan

Assert-True ($HtmlContent -match 'id="view-schedule"') "index.html contains view-schedule section"
Assert-True ($HtmlContent -match 'id="schedule-v2-tbody"') "index.html contains schedule-v2-tbody"

# ========================================
# TC98: V1 tabs still exist (backward compat)
# ========================================
Write-Host "`nTC98: V1 tabs still exist (backward compat)" -ForegroundColor Cyan

Assert-True ($HtmlContent -match 'data-tab="agents"') "V1 agents tab still exists"
Assert-True ($HtmlContent -match 'data-tab="queue"') "V1 queue tab still exists"
Assert-True ($HtmlContent -match 'data-tab="events"') "V1 events tab still exists"
Assert-True ($HtmlContent -match 'id="view-agents"') "V1 view-agents section still exists"
Assert-True ($HtmlContent -match 'id="view-events"') "V1 view-events section still exists"
Assert-True ($HtmlContent -match 'id="view-queue"') "V1 view-queue section still exists"

# ========================================
# TC99: Old V2 stubs removed
# ========================================
Write-Host "`nTC99: Old V2 stubs removed (no agents-v2 or schedules-v2 tab buttons)" -ForegroundColor Cyan

Assert-True (-not ($HtmlContent -match 'data-tab="agents-v2"')) "No agents-v2 tab button in HTML"
Assert-True (-not ($HtmlContent -match 'data-tab="schedules-v2"')) "No schedules-v2 tab button in HTML"

# ========================================
# TC100: app.js contains renderTeamTab function
# ========================================
Write-Host "`nTC100: app.js contains renderTeamTab function" -ForegroundColor Cyan

Assert-True ($AppJsContent -match "function renderTeamTab") "app.js has renderTeamTab function"

# ========================================
# TC101: app.js contains renderOfficeTab function
# ========================================
Write-Host "`nTC101: app.js contains renderOfficeTab function" -ForegroundColor Cyan

Assert-True ($AppJsContent -match "function renderOfficeTab") "app.js has renderOfficeTab function"

# ========================================
# TC102: app.js contains renderHistoryTab or renderHistoryTable function
# ========================================
Write-Host "`nTC102: app.js contains history render function" -ForegroundColor Cyan

$hasHistoryRender = ($AppJsContent -match "function renderHistoryTab") -or ($AppJsContent -match "function renderHistoryTable")
Assert-True $hasHistoryRender "app.js has renderHistoryTab or renderHistoryTable function"

# ========================================
# TC103: app.js contains renderScheduleV2Tab function
# ========================================
Write-Host "`nTC103: app.js contains renderScheduleV2Tab function" -ForegroundColor Cyan

Assert-True ($AppJsContent -match "function renderScheduleV2Tab") "app.js has renderScheduleV2Tab function"

# ========================================
# TC104: app.js contains click-to-copy logic (clipboard)
# ========================================
Write-Host "`nTC104: app.js contains click-to-copy logic" -ForegroundColor Cyan

Assert-True ($AppJsContent -match "clipboard") "app.js references clipboard API for click-to-copy"

# ========================================
# TC105: app.js contains office clock update logic
# ========================================
Write-Host "`nTC105: app.js contains office clock/timer update logic" -ForegroundColor Cyan

$hasTimerLogic = ($AppJsContent -match "setInterval") -or ($AppJsContent -match "elapsed") -or ($AppJsContent -match "office.*timer")
Assert-True $hasTimerLogic "app.js has timer/interval logic for office elapsed display"

# ========================================
# TC106: app.js handles team tab in tab switching logic
# ========================================
Write-Host "`nTC106: app.js handles team tab in tab switching logic" -ForegroundColor Cyan

Assert-True ($AppJsContent -match '"team"') "app.js references ""team"" tab name in switching logic"

# ========================================
# TC107: app.js handles office tab in tab switching logic
# ========================================
Write-Host "`nTC107: app.js handles office tab in tab switching logic" -ForegroundColor Cyan

Assert-True ($AppJsContent -match '"office"') "app.js references ""office"" tab name in switching logic"

# ========================================
# TC108: app.js handles history tab in tab switching logic
# ========================================
Write-Host "`nTC108: app.js handles history tab in tab switching logic" -ForegroundColor Cyan

Assert-True ($AppJsContent -match '"history"') "app.js references ""history"" tab name in switching logic"

# ========================================
# TC109: app.js handles schedule tab in tab switching logic
# ========================================
Write-Host "`nTC109: app.js handles schedule tab in tab switching logic" -ForegroundColor Cyan

Assert-True ($AppJsContent -match '"schedule"') "app.js references ""schedule"" tab name in switching logic"

# ========================================
# TC110: styles.css defines .office-floor class
# ========================================
Write-Host "`nTC110: styles.css defines .office-floor class" -ForegroundColor Cyan

Assert-True (Test-CssClassDefined -Css $CssContent -ClassName ".office-floor") "CSS defines .office-floor"

# ========================================
# TC111: styles.css defines .office-desk class
# ========================================
Write-Host "`nTC111: styles.css defines .office-desk class" -ForegroundColor Cyan

Assert-True (Test-CssClassDefined -Css $CssContent -ClassName ".office-desk") "CSS defines .office-desk"

# ========================================
# TC112: styles.css defines .team-agent-card or .team-agent-list class
# ========================================
Write-Host "`nTC112: styles.css defines team agent card/list class" -ForegroundColor Cyan

$hasTeamClass = (Test-CssClassDefined -Css $CssContent -ClassName ".team-agent-card") -or (Test-CssClassDefined -Css $CssContent -ClassName ".team-agent-list")
Assert-True $hasTeamClass "CSS defines .team-agent-card or .team-agent-list"

# ========================================
# TC113: styles.css defines .history-health-cards class
# ========================================
Write-Host "`nTC113: styles.css defines .history-health-cards class" -ForegroundColor Cyan

Assert-True (Test-CssClassDefined -Css $CssContent -ClassName ".history-health-cards") "CSS defines .history-health-cards"

# ========================================
# TC114: styles.css defines .office-desk.working variant
# ========================================
Write-Host "`nTC114: styles.css defines .office-desk.working variant" -ForegroundColor Cyan

Assert-True (Test-CssClassDefined -Css $CssContent -ClassName ".office-desk.working") "CSS defines .office-desk.working"

# ========================================
# TC115: styles.css has pulse animation (@keyframes pulse)
# ========================================
Write-Host "`nTC115: styles.css has pulse animation" -ForegroundColor Cyan

Assert-True ($CssContent -match "@keyframes\s+pulse") "CSS defines @keyframes pulse animation"

# ========================================
# TC116: HISTORY section has agent filter
# ========================================
Write-Host "`nTC116: HISTORY section has agent filter" -ForegroundColor Cyan

Assert-True ($HtmlContent -match 'id="history-agent-filter"') "HISTORY section has history-agent-filter element"

# ========================================
# TC117: HISTORY section has job filter
# ========================================
Write-Host "`nTC117: HISTORY section has job filter" -ForegroundColor Cyan

Assert-True ($HtmlContent -match 'id="history-job-filter"') "HISTORY section has history-job-filter element"

# ========================================
# TC118: HISTORY section has result filter
# ========================================
Write-Host "`nTC118: HISTORY section has result filter" -ForegroundColor Cyan

Assert-True ($HtmlContent -match 'id="history-result-filter"') "HISTORY section has history-result-filter element"

# ========================================
# TC119: SCHEDULE section has agent filter
# ========================================
Write-Host "`nTC119: SCHEDULE section has agent filter" -ForegroundColor Cyan

Assert-True ($HtmlContent -match 'id="schedule-v2-agent-filter"') "SCHEDULE section has schedule-v2-agent-filter element"

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-V2Tabs: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
