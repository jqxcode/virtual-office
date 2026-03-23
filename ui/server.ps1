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
                            if ($trimmed.Length -gt 0) {
                                # Normalize audit "action" field to "event" for consistency
                                if ($trimmed -match '"action"' -and $trimmed -notmatch '"event"') {
                                    $trimmed = $trimmed -replace '"action"\s*:', '"event":'
                                }
                                $nonEmpty += $trimmed
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
                                if ($p.Length -gt 0) {
                                    $nonEmpty += $p
                                }
                            }
                        }
                    }
                }

                # Deduplicate: audit and events may have overlapping entries
                # Use a hash set on normalized keys (timestamp+agent+job+event)
                $seen = [System.Collections.Generic.HashSet[string]]::new()
                $deduped = [System.Collections.Generic.List[string]]::new()
                foreach ($line in $nonEmpty) {
                    $ts = ""; $ag = ""; $jb = ""; $ev = ""
                    $m = [regex]::Match($line, '"timestamp"\s*:\s*"([^"]+)"')
                    if ($m.Success) { $ts = $m.Groups[1].Value }
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
