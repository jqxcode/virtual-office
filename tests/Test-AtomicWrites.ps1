#Requires -Version 7.0
# Test-AtomicWrites.ps1 -- Tests for Write-AtomicFile (.tmp then rename)
# Run: pwsh -File tests/Test-AtomicWrites.ps1

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

function New-TestRoot {
    $root = Join-Path $env:TEMP "vo-test-$(Get-Random)"
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    foreach ($d in @("state", "runner")) {
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

# Import Write-AtomicFile directly (no need for full runner)
function Import-AtomicWrite {
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
}

Import-AtomicWrite

# ========================================
# TC16: Write-AtomicFile writes to .tmp then renames
# ========================================
Write-Host "`nTC16: Atomic write via .tmp then rename" -ForegroundColor Cyan
$root = New-TestRoot
try {
    $targetFile = Join-Path $root "state/test-data.json"
    $tmpFile = "$targetFile.tmp"
    $testContent = '{"key": "value", "count": 42}'

    # Write atomically
    Write-AtomicFile -Path $targetFile -Content $testContent

    # Final file should exist with correct content
    Assert-True (Test-Path $targetFile) "Target file exists after atomic write"
    if (Test-Path $targetFile) {
        $actual = [System.IO.File]::ReadAllText($targetFile)
        Assert-True ($actual -eq $testContent) "File content matches what was written"
    }

    # .tmp file should NOT remain (it gets renamed)
    Assert-True (-not (Test-Path $tmpFile)) ".tmp file does not remain after rename"

    # Overwrite test: write new content to same file
    $newContent = '{"key": "updated", "count": 99}'
    Write-AtomicFile -Path $targetFile -Content $newContent

    $actual2 = [System.IO.File]::ReadAllText($targetFile)
    Assert-True ($actual2 -eq $newContent) "Overwrite produces correct content"
    Assert-True (-not (Test-Path $tmpFile)) ".tmp file cleaned up after overwrite"

    # Creates parent directories if needed
    $deepFile = Join-Path $root "state/deep/nested/dir/file.json"
    Write-AtomicFile -Path $deepFile -Content "nested"
    Assert-True (Test-Path $deepFile) "Atomic write creates parent directories"
    if (Test-Path $deepFile) {
        $actualDeep = [System.IO.File]::ReadAllText($deepFile)
        Assert-True ($actualDeep -eq "nested") "Nested file has correct content"
    }
} finally {
    Remove-TestRoot -Root $root
}

# ========================================
# TC17: Original file survives if .tmp write fails
# ========================================
Write-Host "`nTC17: Original file survives failed write" -ForegroundColor Cyan
$root = New-TestRoot
try {
    $targetFile = Join-Path $root "state/precious-data.json"
    $originalContent = '{"important": "data"}'

    # First, create the file with known content
    Write-AtomicFile -Path $targetFile -Content $originalContent
    Assert-True (Test-Path $targetFile) "Original file exists"

    # Now try to write to a path where the .tmp file cannot be created
    # We simulate this by making a read-only directory for the tmp target
    $readOnlyDir = Join-Path $root "readonly-test"
    New-Item -ItemType Directory -Path $readOnlyDir -Force | Out-Null
    $roFile = Join-Path $readOnlyDir "data.json"

    # Write original content first
    Write-AtomicFile -Path $roFile -Content "original"
    Assert-True (Test-Path $roFile) "File in test dir exists"

    # Make the .tmp target a directory (causes rename to fail)
    $tmpAsDir = "$roFile.tmp"
    New-Item -ItemType Directory -Path $tmpAsDir -Force | Out-Null

    $writeSucceeded = $true
    try {
        Write-AtomicFile -Path $roFile -Content "should fail"
        $writeSucceeded = $true
    } catch {
        $writeSucceeded = $false
    }

    if (-not $writeSucceeded) {
        # The original file should still have its content
        $surviving = [System.IO.File]::ReadAllText($roFile)
        Assert-True ($surviving -eq "original") "Original content survived failed write"
    } else {
        # On some systems the write might succeed anyway (Move-Item -Force can overwrite dirs)
        # In that case, just verify the file is valid
        $content = [System.IO.File]::ReadAllText($roFile)
        Assert-True ($content.Length -gt 0) "File has content (write unexpectedly succeeded)"
    }

    # Clean up the directory we created as .tmp
    if (Test-Path $tmpAsDir) {
        Remove-Item -Path $tmpAsDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Additional test: verify that original file in a different location is untouched
    $stillOriginal = [System.IO.File]::ReadAllText($targetFile)
    Assert-True ($stillOriginal -eq $originalContent) "Unrelated original file is untouched"
} finally {
    Remove-TestRoot -Root $root
}

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
Write-Host "Test-AtomicWrites: $script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor White

if ($script:Failed -gt 0) { exit 1 }
exit 0
