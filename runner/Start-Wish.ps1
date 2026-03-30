param(
    [string]$Id,
    [switch]$List
)

$wishFile = "Q:\src\personal_projects\virtual-office\state\wish-list.json"

if (-not (Test-Path $wishFile)) {
    Write-Error "Wish list not found at $wishFile"
    exit 1
}

$wishes = (Get-Content $wishFile -Raw | ConvertFrom-Json).wishes

# Inventory mode
if ($List) {
    Write-Host "`n  Wish List Inventory`n  -------------------" -ForegroundColor Cyan
    $i = 0
    foreach ($w in $wishes) {
        $i++
        $statusColor = switch ($w.status) {
            "idea"      { "DarkYellow" }
            "exploring" { "Green" }
            "paused"    { "Gray" }
            "blocked"   { "Red" }
            "done"      { "DarkGreen" }
            default     { "White" }
        }
        Write-Host "  $i. " -NoNewline
        Write-Host "[$($w.status)]" -ForegroundColor $statusColor -NoNewline
        Write-Host " $($w.title)" -NoNewline
        Write-Host "  (id: $($w.id))" -ForegroundColor DarkGray
    }
    Write-Host "`n  Usage: Start-Wish.ps1 -Id <wish-id>`n" -ForegroundColor DarkGray
    exit 0
}

if (-not $Id) {
    Write-Error "Specify -Id <wish-id> or use -List to see all wishes"
    exit 1
}

$wish = $wishes | Where-Object { $_.id -eq $Id }
if (-not $wish) {
    Write-Error "Wish '$Id' not found. Use -List to see available wishes."
    exit 1
}

$name = $wish.conversationName
$nextSteps = ($wish.nextSteps | ForEach-Object { "- $_" }) -join "`n"

$context = @"
I'm working on wish-list item: $($wish.title)

Description: $($wish.description)
Status: $($wish.status)
Next Steps:
$nextSteps
Notes: $($wish.notes)

Wish list file: Q:/src/personal_projects/virtual-office/state/wish-list.json
Wish ID: $($wish.id)

When we make progress, update the wish-list.json with new status and next steps.
Please name this session now: /name $name
"@

# Try resume first
Write-Host "Trying to resume session '$name'..." -ForegroundColor DarkGray
$resumeResult = & claude --resume $name 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "No existing session. Starting new session for: $($wish.title)" -ForegroundColor Cyan
    & claude $context
}
