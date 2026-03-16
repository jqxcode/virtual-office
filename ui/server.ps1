# Virtual Office Dashboard - HTTP Server
# Serves the dashboard UI and proxies state files as API endpoints
# Usage: powershell -File server.ps1

$Port = 8400
$UiDir = $PSScriptRoot
$StateDir = Join-Path (Split-Path $UiDir -Parent) "state"

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
            if ($urlPath -eq "/api/dashboard") {
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
                # Serve last N lines of events.jsonl as a JSON array
                $filePath = Join-Path $StateDir "events.jsonl"
                if (Test-Path $filePath) {
                    $allLines = [System.IO.File]::ReadAllLines($filePath, [System.Text.Encoding]::UTF8)
                    # Filter empty lines
                    $nonEmpty = @()
                    foreach ($line in $allLines) {
                        $trimmed = $line.Trim()
                        if ($trimmed.Length -gt 0) {
                            $nonEmpty += $trimmed
                        }
                    }
                    # Take last 50
                    $maxEvents = 50
                    if ($nonEmpty.Count -gt $maxEvents) {
                        $nonEmpty = $nonEmpty[($nonEmpty.Count - $maxEvents)..($nonEmpty.Count - 1)]
                    }
                    $jsonArray = "[" + ($nonEmpty -join ",") + "]"
                    Send-TextResponse $context 200 "application/json" $jsonArray
                } else {
                    Send-TextResponse $context 200 "application/json" "[]"
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
