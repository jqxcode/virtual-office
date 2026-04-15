# Virtual Office Dashboard - HTTP Server
# Serves the dashboard UI and proxies state files as API endpoints
# Usage: powershell -File server.ps1

param([int]$Port = 8400)
try { Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue } catch {}
$UiDir = $PSScriptRoot
$ProjectRoot = Split-Path $UiDir -Parent
$StateDir = Join-Path $ProjectRoot "state"
$ConfigDir = Join-Path $ProjectRoot "config"

$Prefix = "http://localhost:${Port}/"
$Listener = New-Object System.Net.HttpListener
$Listener.Prefixes.Add($Prefix)

$MimeTypes = @{
    ".html" = "text/html"
    ".css"  = "text/css"
    ".js"   = "application/javascript"
    ".json" = "application/json"
    ".png"  = "image/png"
    ".ico"  = "image/x-icon"
    ".md"   = "text/html"
}

function ConvertFrom-MarkdownToHtml($mdText) {
    # Convert markdown to HTML for browser viewing
    $lines = $mdText -split "`n"
    $body = [System.Text.StringBuilder]::new()
    $inCode = $false
    foreach ($rawLine in $lines) {
        $line = $rawLine.TrimEnd("`r")
        if ($line -match '^```') {
            if ($inCode) {
                [void]$body.Append('</code></pre>')
                $inCode = $false
            } else {
                [void]$body.Append('<pre><code>')
                $inCode = $true
            }
            continue
        }
        if ($inCode) {
            [void]$body.AppendLine([System.Net.WebUtility]::HtmlEncode($line))
            continue
        }
        $esc = [System.Net.WebUtility]::HtmlEncode($line)
        # Headers
        if ($esc -match '^#{1,6}\s') {
            $level = ($esc -replace '^(#+).*', '$1').Length
            $text = $esc -replace '^#+\s+', ''
            [void]$body.AppendLine("<h$level>$text</h$level>")
        }
        # Horizontal rule
        elseif ($esc -match '^---+$') {
            [void]$body.AppendLine('<hr>')
        }
        # Table row
        elseif ($esc -match '^\|') {
            # Skip separator rows like |---|---|
            if ($esc -match '^\|[\s\-\|:]+\|$') { continue }
            $cells = ($esc -split '\|' | Where-Object { $_.Trim() -ne '' })
            $tag = 'td'
            $row = '<tr>' + (($cells | ForEach-Object { "<$tag>$($_.Trim())</$tag>" }) -join '') + '</tr>'
            [void]$body.AppendLine($row)
        }
        # List item
        elseif ($esc -match '^[-*]\s+(.+)$') {
            [void]$body.AppendLine("<li>$($Matches[1])</li>")
        }
        # Empty line
        elseif ($esc.Trim() -eq '') {
            [void]$body.AppendLine('<br>')
        }
        # Normal paragraph
        else {
            # Bold
            $esc = [regex]::Replace($esc, '\*\*(.+?)\*\*', '<strong>$1</strong>')
            # Italic
            $esc = [regex]::Replace($esc, '\*(.+?)\*', '<em>$1</em>')
            # Inline code
            $esc = [regex]::Replace($esc, '`([^`]+)`', '<code>$1</code>')
            [void]$body.AppendLine("<p>$esc</p>")
        }
    }
    if ($inCode) { [void]$body.Append('</code></pre>') }
    # Wrap in HTML template
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Report</title>
<style>
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 900px; margin: 0 auto; padding: 2rem; background: #f8fafc; color: #1e293b; line-height: 1.6; }
h1,h2,h3,h4 { color: #0f172a; margin-top: 1.5rem; }
h1 { border-bottom: 2px solid #e2e8f0; padding-bottom: 0.5rem; }
pre { background: #1e293b; color: #e2e8f0; padding: 1rem; border-radius: 8px; overflow-x: auto; }
code { background: #e2e8f0; padding: 0.15rem 0.4rem; border-radius: 4px; font-size: 0.9em; }
pre code { background: none; padding: 0; }
li { margin: 0.3rem 0; margin-left: 1.5rem; }
hr { border: none; border-top: 1px solid #e2e8f0; margin: 1.5rem 0; }
p { margin: 0.5rem 0; }
strong { color: #0f172a; }
table { border-collapse: collapse; width: 100%; margin: 1rem 0; }
th, td { border: 1px solid #e2e8f0; padding: 0.5rem 0.75rem; text-align: left; }
th { background: #f1f5f9; font-weight: 600; }
</style>
</head>
<body>
$($body.ToString())
</body>
</html>
"@
    return $html
}

function Get-ContentType($path) {
    $ext = [System.IO.Path]::GetExtension($path).ToLower()
    if ($MimeTypes.ContainsKey($ext)) {
        return $MimeTypes[$ext]
    }
    return "application/octet-stream"
}

function Send-Response($context, $statusCode, $contentType, $bodyBytes) {
    $response = $context.Response
    $response.StatusCode = $statusCode
    $response.ContentType = $contentType
    $response.Headers.Set("Cache-Control", "no-cache, no-store, must-revalidate")
    $response.ContentLength64 = $bodyBytes.Length
    $response.OutputStream.Write($bodyBytes, 0, $bodyBytes.Length)
    $response.OutputStream.Close()
}

function Send-TextResponse($context, $statusCode, $contentType, $text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    Send-Response $context $statusCode $contentType $bytes
}

function Send-NotFound($context) {
    Send-TextResponse $context 404 "text/plain" "404 Not Found"
}

try {
    $Listener.Start()
    Write-Host "Virtual Office dashboard running at http://localhost:${Port}/"
    Write-Host "UI directory: $UiDir"
    Write-Host "State directory: $StateDir"
    Write-Host "Press Ctrl+C to stop."
    Write-Host ""

    while ($Listener.IsListening) {
        $contextTask = $Listener.GetContextAsync()
        while (-not $contextTask.AsyncWaitHandle.WaitOne(500)) {
            # Check every 500ms so Ctrl+C can interrupt
        }
        $context = $contextTask.GetAwaiter().GetResult()
        $request = $context.Request
        $urlPath = $request.Url.AbsolutePath

        Write-Host "$([DateTime]::Now.ToString('HH:mm:ss')) $($request.HttpMethod) $urlPath"

        try {
            if ($urlPath -eq "/api/config") {
                # Serve agents.json + jobs config merged
                $agentsFile = Join-Path $ConfigDir "agents.json"
                $jobsDir = Join-Path $ConfigDir "jobs"
                if (Test-Path $agentsFile) {
                    $agentsJson = [System.IO.File]::ReadAllText($agentsFile, [System.Text.Encoding]::UTF8)
                    $agentsObj = $agentsJson | ConvertFrom-Json
                    # Merge job definitions into each agent
                    foreach ($agentName in @($agentsObj.agents.PSObject.Properties.Name)) {
                        $jobFile = Join-Path $jobsDir "$agentName.json"
                        if (Test-Path $jobFile) {
                            $jobJson = [System.IO.File]::ReadAllText($jobFile, [System.Text.Encoding]::UTF8)
                            $jobObj = $jobJson | ConvertFrom-Json
                            $agentsObj.agents.$agentName | Add-Member -NotePropertyName "jobs" -NotePropertyValue $jobObj.jobs -Force
                        }
                    }
                    # Merge hooks config if exists
                    $hooksFile = Join-Path $ConfigDir "hooks.json"
                    if (Test-Path $hooksFile) {
                        $hooksJson = [System.IO.File]::ReadAllText($hooksFile, [System.Text.Encoding]::UTF8)
                        $hooksObj = $hooksJson | ConvertFrom-Json
                        $agentsObj | Add-Member -NotePropertyName "hooks" -NotePropertyValue $hooksObj -Force
                    }
                    $merged = $agentsObj | ConvertTo-Json -Depth 10
                    Send-TextResponse $context 200 "application/json" $merged
                } else {
                    Send-TextResponse $context 200 "application/json" '{"agents":{}}'
                }
            }
            elseif ($urlPath -eq "/api/dashboard") {
                # Serve dashboard.json
                $filePath = Join-Path $StateDir "dashboard.json"
                if (Test-Path $filePath) {
                    $content = [System.IO.File]::ReadAllText($filePath, [System.Text.Encoding]::UTF8)
                    Send-TextResponse $context 200 "application/json" $content
                } else {
                    Send-TextResponse $context 200 "application/json" '{"agents":{}}'
                }
            }
            elseif ($urlPath -eq "/api/events") {
                # Serve events as a JSON array
                # Query params: ?limit=N (default 50, "all" for everything)
                # Merges events.jsonl + audit logs for complete history
                $nonEmpty = @()

                # Read audit logs (complete historical record)
                $AuditDir = Join-Path (Join-Path (Split-Path $UiDir -Parent) "output") "audit"
                if (Test-Path $AuditDir) {
                    $auditFiles = Get-ChildItem -Path $AuditDir -Filter "*.jsonl" | Sort-Object Name
                    foreach ($af in $auditFiles) {
                        $auditLines = [System.IO.File]::ReadAllLines($af.FullName, [System.Text.Encoding]::UTF8)
                        foreach ($line in $auditLines) {
                            $trimmed = $line.Trim()
                            if ($trimmed.Length -eq 0) { continue }
                            # Split concatenated JSON objects
                            $parts = [regex]::Split($trimmed, '(?<=\})(?=\{)')
                            foreach ($part in $parts) {
                                $p = $part.Trim()
                                if ($p.Length -gt 0 -and $p.StartsWith('{') -and $p.EndsWith('}')) {
                                    # Normalize audit "action" field to "event" for consistency
                                    if ($p -match '"action"' -and $p -notmatch '"event"') {
                                        $p = $p -replace '"action"\s*:', '"event":'
                                    }
                                    $nonEmpty += $p
                                }
                            }
                        }
                    }
                }

                # Read events.jsonl (may have entries not in audit, e.g. schedule events)
                # Handle corrupted lines with multiple JSON objects concatenated
                $eventsFile = Join-Path $StateDir "events.jsonl"
                if (Test-Path $eventsFile) {
                    $evtLines = [System.IO.File]::ReadAllLines($eventsFile, [System.Text.Encoding]::UTF8)
                    foreach ($line in $evtLines) {
                        $trimmed = $line.Trim()
                        if ($trimmed.Length -gt 0) {
                            # Split concatenated JSON objects (e.g. }{  with no comma/newline)
                            $parts = [regex]::Split($trimmed, '(?<=\})(?=\{)')
                            foreach ($part in $parts) {
                                $p = $part.Trim()
                                if ($p.Length -gt 0 -and $p.StartsWith('{') -and $p.EndsWith('}')) {
                                    $nonEmpty += $p
                                }
                            }
                        }
                    }
                }

                # Deduplicate: audit and events may have overlapping entries
                # Use a hash set on normalized keys (timestamp+agent+job+event)
                # Truncate timestamp to seconds precision (first 19 chars: YYYY-MM-DDTHH:MM:SS)
                # because events.jsonl and audit log record slightly different sub-second
                # timestamps for the same logical event, causing the full timestamp key to miss
                # duplicates (e.g. "2026-03-15T23:16:23.5613337" vs "2026-03-15T23:16:23.5447693").
                $seen = [System.Collections.Generic.HashSet[string]]::new()
                $deduped = [System.Collections.Generic.List[string]]::new()
                foreach ($line in $nonEmpty) {
                    $ts = ""; $ag = ""; $jb = ""; $ev = ""
                    $m = [regex]::Match($line, '"timestamp"\s*:\s*"([^"]+)"')
                    if ($m.Success) { $ts = $m.Groups[1].Value }
                    # Truncate to seconds precision to match audit vs events.jsonl sub-second drift
                    if ($ts.Length -gt 19) { $ts = $ts.Substring(0, 19) }
                    $m = [regex]::Match($line, '"agent"\s*:\s*"([^"]+)"')
                    if ($m.Success) { $ag = $m.Groups[1].Value }
                    $m = [regex]::Match($line, '"job"\s*:\s*"([^"]+)"')
                    if ($m.Success) { $jb = $m.Groups[1].Value }
                    $m = [regex]::Match($line, '"event"\s*:\s*"([^"]+)"')
                    if ($m.Success) { $ev = $m.Groups[1].Value }
                    $key = "${ts}|${ag}|${jb}|${ev}"
                    if ($seen.Add($key)) {
                        $deduped.Add($line)
                    }
                }
                $nonEmpty = $deduped.ToArray()

                $limitParam = $request.QueryString["limit"]
                if ($limitParam -ne "all") {
                    $maxEvents = 50
                    if ($limitParam -and [int]::TryParse($limitParam, [ref]$null)) {
                        $maxEvents = [int]$limitParam
                    }
                    if ($nonEmpty.Count -gt $maxEvents) {
                        $nonEmpty = $nonEmpty[($nonEmpty.Count - $maxEvents)..($nonEmpty.Count - 1)]
                    }
                }
                $jsonArray = "[" + ($nonEmpty -join ",") + "]"
                Send-TextResponse $context 200 "application/json" $jsonArray
            }
            elseif ($urlPath -eq "/api/errors") {
                # Serve errors.jsonl as JSON array (only unresolved by default)
                $filePath = Join-Path $StateDir "errors.jsonl"
                if (Test-Path $filePath) {
                    $allLines = [System.IO.File]::ReadAllLines($filePath, [System.Text.Encoding]::UTF8)
                    $nonEmpty = @()
                    foreach ($line in $allLines) {
                        $trimmed = $line.Trim()
                        if ($trimmed.Length -gt 0) {
                            $nonEmpty += $trimmed
                        }
                    }
                    # Take last 100 errors
                    $maxErrors = 100
                    if ($nonEmpty.Count -gt $maxErrors) {
                        $nonEmpty = $nonEmpty[($nonEmpty.Count - $maxErrors)..($nonEmpty.Count - 1)]
                    }
                    $jsonArray = "[" + ($nonEmpty -join ",") + "]"
                    Send-TextResponse $context 200 "application/json" $jsonArray
                } else {
                    Send-TextResponse $context 200 "application/json" "[]"
                }
            }
            elseif ($urlPath.StartsWith("/api/output/")) {
                # Serve files from the output directory (read-only)
                $OutputDir = Join-Path (Split-Path $UiDir -Parent) "output"
                $relativePath = $urlPath.Substring("/api/output/".Length)
                $relativePath = $relativePath.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
                $filePath = Join-Path $OutputDir $relativePath
                $fullPath = [System.IO.Path]::GetFullPath($filePath)

                # Security: ensure path is within output directory
                if ($fullPath.StartsWith($OutputDir) -and (Test-Path $fullPath) -and -not (Test-Path $fullPath -PathType Container)) {
                    $ext = [System.IO.Path]::GetExtension($fullPath).ToLower()
                    if ($ext -eq ".md") {
                        # Render markdown as HTML for browser viewing
                        $mdText = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
                        $html = ConvertFrom-MarkdownToHtml $mdText
                        Send-TextResponse $context 200 "text/html" $html
                    } else {
                        $contentType = Get-ContentType $fullPath
                        $fileBytes = [System.IO.File]::ReadAllBytes($fullPath)
                        Send-Response $context 200 $contentType $fileBytes
                    }
                } else {
                    Send-NotFound $context
                }
            }
            elseif ($urlPath -eq "/api/schedules") {
                # Serve merged schedule + runtime queue state
                $schedulesFile = Join-Path $ConfigDir "schedules.json"
                $jobsDir = Join-Path $ConfigDir "jobs"
                $agentsStateDir = Join-Path $StateDir "agents"
                $schedulesList = @()
                if (Test-Path $schedulesFile) {
                    $schedulesJson = [System.IO.File]::ReadAllText($schedulesFile, [System.Text.Encoding]::UTF8)
                    $schedulesObj = $schedulesJson | ConvertFrom-Json
                    foreach ($entry in $schedulesObj.schedules) {
                        $agentName = $entry.agent
                        $jobName   = $entry.job
                        $enabled   = $false
                        $jobFile   = Join-Path $jobsDir "$agentName.json"
                        if (Test-Path $jobFile) {
                            $jobJson  = [System.IO.File]::ReadAllText($jobFile, [System.Text.Encoding]::UTF8)
                            $jobObj   = $jobJson | ConvertFrom-Json
                            # jobs is a hashtable/object with job names as keys
                            $jobEntry = $null
                            if ($jobObj.jobs.PSObject.Properties[$jobName]) {
                                $jobEntry = $jobObj.jobs.$jobName
                            }
                            if ($jobEntry) {
                                if ($jobEntry.PSObject.Properties["enabled"]) {
                                    $enabled = [bool]$jobEntry.enabled
                                } else {
                                    $enabled = $true
                                }
                            }
                        }
                        $desc = ""
                        if ($entry.PSObject.Properties["description"]) { $desc = $entry.description }
                        $schedulesList += [PSCustomObject]@{
                            agent       = $agentName
                            job         = $jobName
                            cron        = $entry.cron
                            description = $desc
                            enabled     = $enabled
                        }
                    }
                }
                # Build queues map
                $queuesMap = [PSCustomObject]@{}
                if (Test-Path $agentsStateDir) {
                    $agentDirs = Get-ChildItem -Path $agentsStateDir -Directory -ErrorAction SilentlyContinue
                    foreach ($aDir in $agentDirs) {
                        $aName    = $aDir.Name
                        $lockFile = Join-Path $aDir.FullName "lock"
                        $lockInfo = $null
                        if (Test-Path $lockFile) {
                            try {
                                $lockText = [System.IO.File]::ReadAllText($lockFile, [System.Text.Encoding]::UTF8)
                                $lockInfo = $lockText | ConvertFrom-Json
                            } catch {}
                        }
                        $jobsMap = [PSCustomObject]@{}
                        $jobDirs = Get-ChildItem -Path $aDir.FullName -Directory -ErrorAction SilentlyContinue
                        foreach ($jDir in $jobDirs) {
                            $jName     = $jDir.Name
                            $queueFile = Join-Path $jDir.FullName "queue"
                            $depth     = 0
                            if (Test-Path $queueFile) {
                                try {
                                    $qText = [System.IO.File]::ReadAllText($queueFile, [System.Text.Encoding]::UTF8).Trim()
                                    $depth = [int]$qText
                                } catch { $depth = 0 }
                            }
                            $jobsMap | Add-Member -NotePropertyName $jName -NotePropertyValue ([PSCustomObject]@{ queue_depth = $depth }) -Force
                        }
                        $agentInfo = [PSCustomObject]@{ jobs = $jobsMap }
                        if ($null -ne $lockInfo) {
                            $agentInfo | Add-Member -NotePropertyName "lock" -NotePropertyValue $lockInfo -Force
                        }
                        $queuesMap | Add-Member -NotePropertyName $aName -NotePropertyValue $agentInfo -Force
                    }
                }
                $result = [PSCustomObject]@{
                    schedules = $schedulesList
                    queues    = $queuesMap
                }
                Send-TextResponse $context 200 "application/json" ($result | ConvertTo-Json -Depth 10)
            }
            elseif ($urlPath -eq "/api/queue/cancel" -and $request.HttpMethod -eq "POST") {
                # Cancel a queued job (decrement queue depth)
                $SYSTEM_VERSION = "0.4.0"
                $AuditDir = Join-Path (Join-Path $ProjectRoot "output") "audit"
                $reader   = New-Object System.IO.StreamReader($request.InputStream)
                $bodyText = $reader.ReadToEnd()
                $body     = $bodyText | ConvertFrom-Json
                $agentName = $body.agent
                $jobName   = $body.job
                # Validate names
                if ($agentName -notmatch '^[a-zA-Z0-9_-]+$' -or $jobName -notmatch '^[a-zA-Z0-9_-]+$') {
                    Send-TextResponse $context 400 "application/json" '{"ok":false,"error":"invalid agent or job name"}'
                } else {
                    $queueFile = Join-Path (Join-Path (Join-Path (Join-Path $StateDir "agents") $agentName) $jobName) "queue"
                    if (-not (Test-Path $queueFile)) {
                        Send-TextResponse $context 400 "application/json" '{"ok":false,"error":"queue file not found"}'
                    } else {
                        $qText = [System.IO.File]::ReadAllText($queueFile, [System.Text.Encoding]::UTF8).Trim()
                        $depth = 0
                        [int]::TryParse($qText, [ref]$depth) | Out-Null
                        if ($depth -le 0) {
                            Send-TextResponse $context 400 "application/json" '{"ok":false,"error":"queue already empty"}'
                        } else {
                            $newDepth  = [Math]::Max(0, $depth - 1)
                            $tmpFile   = "$queueFile.tmp"
                            [System.IO.File]::WriteAllText($tmpFile, "$newDepth", [System.Text.Encoding]::UTF8)
                            Move-Item -Path $tmpFile -Destination $queueFile -Force
                            # Update dashboard.json
                            $dashFile = Join-Path $StateDir "dashboard.json"
                            if (Test-Path $dashFile) {
                                try {
                                    $dashText = [System.IO.File]::ReadAllText($dashFile, [System.Text.Encoding]::UTF8)
                                    $dashObj  = $dashText | ConvertFrom-Json
                                    if ($dashObj.agents.$agentName.jobs.$jobName) {
                                        $dashObj.agents.$agentName.jobs.$jobName | Add-Member -NotePropertyName "queue_depth" -NotePropertyValue $newDepth -Force
                                    }
                                    $dashTmp = "$dashFile.tmp"
                                    [System.IO.File]::WriteAllText($dashTmp, ($dashObj | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)
                                    Move-Item -Path $dashTmp -Destination $dashFile -Force
                                } catch {}
                            }
                            $now      = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
                            $eventObj = [PSCustomObject]@{
                                timestamp     = $now
                                agent         = $agentName
                                job           = $jobName
                                event         = "queue_cancelled"
                                details       = [PSCustomObject]@{ cancelled_by = "user"; remaining_depth = $newDepth }
                                systemVersion = $SYSTEM_VERSION
                            }
                            $eventLine = ($eventObj | ConvertTo-Json -Compress)
                            $eventsFile = Join-Path $StateDir "events.jsonl"
                            [System.IO.File]::AppendAllText($eventsFile, "$eventLine`n", [System.Text.Encoding]::UTF8)
                            # Audit log
                            if (-not (Test-Path $AuditDir)) { New-Item -ItemType Directory -Path $AuditDir -Force | Out-Null }
                            $auditFile = Join-Path $AuditDir ([DateTime]::UtcNow.ToString("yyyy-MM") + ".jsonl")
                            [System.IO.File]::AppendAllText($auditFile, "$eventLine`n", [System.Text.Encoding]::UTF8)
                            Send-TextResponse $context 200 "application/json" ("{`"ok`":true,`"queue_depth`":$newDepth}")
                        }
                    }
                }
            }
            elseif ($urlPath -eq "/api/job/stop" -and $request.HttpMethod -eq "POST") {
                # Force stop a running job
                $SYSTEM_VERSION = "0.4.0"
                $AuditDir = Join-Path (Join-Path $ProjectRoot "output") "audit"
                $reader   = New-Object System.IO.StreamReader($request.InputStream)
                $bodyText = $reader.ReadToEnd()
                $body     = $bodyText | ConvertFrom-Json
                $agentName = $body.agent
                $jobName   = $body.job
                # Validate names
                if ($agentName -notmatch '^[a-zA-Z0-9_-]+$' -or $jobName -notmatch '^[a-zA-Z0-9_-]+$') {
                    Send-TextResponse $context 400 "application/json" '{"ok":false,"error":"invalid agent or job name"}'
                } else {
                    $lockFile = Join-Path (Join-Path (Join-Path $StateDir "agents") $agentName) "lock"
                    if (-not (Test-Path $lockFile)) {
                        Send-TextResponse $context 400 "application/json" '{"ok":false,"error":"not running"}'
                    } else {
                        $lockText = [System.IO.File]::ReadAllText($lockFile, [System.Text.Encoding]::UTF8)
                        $lockObj  = $lockText | ConvertFrom-Json
                        $procId = 0
                        if ($lockObj.PSObject.Properties["pid"])    { $procId = [int]$lockObj.pid }
                        $runId  = ""
                        if ($lockObj.PSObject.Properties["run_id"]) { $runId  = $lockObj.run_id }
                        $lockTs = ""
                        if ($lockObj.PSObject.Properties["ts"])     { $lockTs = $lockObj.ts }
                        # Calculate elapsed seconds
                        $elapsed  = 0
                        if ($lockTs -ne "") {
                            try {
                                $startDt = [DateTime]::Parse($lockTs, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                $elapsed = [int]([DateTime]::UtcNow - $startDt).TotalSeconds
                            } catch {}
                        }
                        # Kill the process
                        if ($procId -gt 0) {
                            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                        }
                        # Also kill any claude processes in the tree
                        try {
                            $claudeProcs = Get-Process -Name "claude" -ErrorAction SilentlyContinue
                            if ($claudeProcs) {
                                $claudeProcs | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
                            }
                        } catch {}
                        # Remove lock file
                        Remove-Item -Path $lockFile -Force -ErrorAction SilentlyContinue
                        # Update dashboard.json
                        $dashFile = Join-Path $StateDir "dashboard.json"
                        if (Test-Path $dashFile) {
                            try {
                                $dashText = [System.IO.File]::ReadAllText($dashFile, [System.Text.Encoding]::UTF8)
                                $dashObj  = $dashText | ConvertFrom-Json
                                if ($dashObj.agents.$agentName.jobs.$jobName) {
                                    $dashObj.agents.$agentName.jobs.$jobName | Add-Member -NotePropertyName "status" -NotePropertyValue "idle" -Force
                                    $dashObj.agents.$agentName.jobs.$jobName | Add-Member -NotePropertyName "run_id" -NotePropertyValue $null -Force
                                    $dashObj.agents.$agentName.jobs.$jobName | Add-Member -NotePropertyName "pid"    -NotePropertyValue $null -Force
                                }
                                $dashTmp = "$dashFile.tmp"
                                [System.IO.File]::WriteAllText($dashTmp, ($dashObj | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)
                                Move-Item -Path $dashTmp -Destination $dashFile -Force
                            } catch {}
                        }
                        $now      = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
                        $eventObj = [PSCustomObject]@{
                            timestamp     = $now
                            agent         = $agentName
                            job           = $jobName
                            event         = "force_stopped"
                            details       = [PSCustomObject]@{ stopped_by = "user"; pid = $procId; run_id = $runId; elapsed_seconds = $elapsed }
                            systemVersion = $SYSTEM_VERSION
                        }
                        $eventLine = ($eventObj | ConvertTo-Json -Compress)
                        $eventsFile = Join-Path $StateDir "events.jsonl"
                        [System.IO.File]::AppendAllText($eventsFile, "$eventLine`n", [System.Text.Encoding]::UTF8)
                        # Audit log
                        if (-not (Test-Path $AuditDir)) { New-Item -ItemType Directory -Path $AuditDir -Force | Out-Null }
                        $auditFile = Join-Path $AuditDir ([DateTime]::UtcNow.ToString("yyyy-MM") + ".jsonl")
                        [System.IO.File]::AppendAllText($auditFile, "$eventLine`n", [System.Text.Encoding]::UTF8)
                        Send-TextResponse $context 200 "application/json" ("{`"ok`":true,`"pid`":$procId}")
                    }
                }
            }
            elseif ($urlPath -eq "/api/reports") {
                # Scan output/ for HTML report files, grouped by agent -> job
                $OutputDir = Join-Path (Split-Path $UiDir -Parent) "output"
                $result = @{}
                if (Test-Path $OutputDir) {
                    $htmlFiles = Get-ChildItem -Path $OutputDir -Filter "*.html" -Recurse -File -ErrorAction SilentlyContinue
                    foreach ($f in $htmlFiles) {
                        # Skip *-latest.html symlinks/copies
                        if ($f.Name -match '-latest\.html$') { continue }
                        # Determine agent and job from path
                        $relPath = $f.FullName.Substring($OutputDir.Length + 1).Replace('\', '/')
                        $parts = $relPath -split '/'
                        if ($parts.Count -ge 2) {
                            $agentName = $parts[0]
                            $jobBase = $f.BaseName -replace '-\d{8}.*$', '' -replace '-\d{4}-\d{2}-\d{2}.*$', ''
                        } else {
                            $agentName = "root"
                            $jobBase = $f.BaseName -replace '-\d{8}.*$', '' -replace '-\d{4}-\d{2}-\d{2}.*$', ''
                        }
                        if (-not $result.ContainsKey($agentName)) { $result[$agentName] = @{} }
                        if (-not $result[$agentName].ContainsKey($jobBase)) { $result[$agentName][$jobBase] = @() }
                        $filePath = $f.FullName.Replace('\', '/')
                        $result[$agentName][$jobBase] += [PSCustomObject]@{
                            name = $f.Name
                            path = "file:///$filePath"
                            url  = "/api/output/" + $relPath
                            date = $f.LastWriteTime.ToString("yyyy-MM-dd")
                            size = $f.Length
                        }
                    }
                }
                # Sort each job list by date desc and take top 5
                $agentsObj = [PSCustomObject]@{}
                foreach ($agentName in ($result.Keys | Sort-Object)) {
                    $jobsObj = [PSCustomObject]@{}
                    foreach ($jobName in ($result[$agentName].Keys | Sort-Object)) {
                        $sorted = $result[$agentName][$jobName] | Sort-Object { $_.date } -Descending | Select-Object -First 5
                        $jobsObj | Add-Member -NotePropertyName $jobName -NotePropertyValue @($sorted) -Force
                    }
                    $agentsObj | Add-Member -NotePropertyName $agentName -NotePropertyValue $jobsObj -Force
                }
                $response = [PSCustomObject]@{ agents = $agentsObj }
                Send-TextResponse $context 200 "application/json" ($response | ConvertTo-Json -Depth 10)
            }
            else {
                # Serve static files from ui/
                if ($urlPath -eq "/") {
                    $urlPath = "/index.html"
                }

                # Prevent directory traversal
                $relativePath = $urlPath.TrimStart("/").Replace("/", [System.IO.Path]::DirectorySeparatorChar)
                $filePath = Join-Path $UiDir $relativePath
                $fullPath = [System.IO.Path]::GetFullPath($filePath)

                if ($fullPath.StartsWith($UiDir) -and (Test-Path $fullPath) -and -not (Test-Path $fullPath -PathType Container)) {
                    $contentType = Get-ContentType $fullPath
                    $fileBytes = [System.IO.File]::ReadAllBytes($fullPath)
                    Send-Response $context 200 $contentType $fileBytes
                } else {
                    Send-NotFound $context
                }
            }
        }
        catch {
            Write-Host "  Error handling request: $_"
            try {
                Send-TextResponse $context 500 "text/plain" "500 Internal Server Error"
            } catch {
                # Response may already be closed
            }
        }
    }
}
catch [System.OperationCanceledException] {
    # Normal Ctrl+C
}
catch {
    Write-Host "Server error: $_"
}
finally {
    Write-Host ""
    Write-Host "Shutting down server..."
    if ($Listener -ne $null) {
        $Listener.Stop()
        $Listener.Close()
    }
    Write-Host "Server stopped."
}
