#Requires -Version 7.0
#Requires -Modules Pester
# Test-TaskQueue.ps1 -- Pester tests for Task Queue feature
# Covers: /api/schedules logic, /api/queue/cancel logic, lock file PID format,
#         and /api/job/stop logic
# Run: pwsh -File tests/Test-TaskQueue.ps1
#   or: Invoke-Pester tests/Test-TaskQueue.ps1

Set-StrictMode -Version Latest

Describe "Task Queue Feature" {

    BeforeAll {

        # ----------------------------------------------------------------
        # Shared temp-directory factory
        # ----------------------------------------------------------------
        function New-TestRoot {
            $root = Join-Path $env:TEMP "vo-test-$(Get-Random)"
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            foreach ($d in @("config/jobs", "state/agents", "output/audit")) {
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

        # ----------------------------------------------------------------
        # Replicate /api/schedules endpoint logic for file-system testing
        # (no HTTP server required)
        # ----------------------------------------------------------------
        function Invoke-SchedulesLogic {
            param(
                [string]$ConfigDir,
                [string]$StateDir
            )
            $schedulesFile  = Join-Path $ConfigDir "schedules.json"
            $jobsDir        = Join-Path $ConfigDir "jobs"
            $agentsStateDir = Join-Path $StateDir  "agents"
            $schedulesList  = @()

            if (Test-Path $schedulesFile) {
                $schedulesObj = [System.IO.File]::ReadAllText($schedulesFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                foreach ($entry in $schedulesObj.schedules) {
                    $agentName = $entry.agent
                    $jobName   = $entry.job
                    $schedulesList += [PSCustomObject]@{
                        agent       = $agentName
                        job         = $jobName
                        cron        = $entry.cron
                        description = if ($entry.PSObject.Properties["description"]) { $entry.description } else { "" }
                    }
                }
            }

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
                        $jobsMap | Add-Member -NotePropertyName $jName `
                            -NotePropertyValue ([PSCustomObject]@{ queue_depth = $depth }) -Force
                    }
                    $agentInfo = [PSCustomObject]@{ jobs = $jobsMap }
                    if ($null -ne $lockInfo) {
                        $agentInfo | Add-Member -NotePropertyName "lock" -NotePropertyValue $lockInfo -Force
                    }
                    $queuesMap | Add-Member -NotePropertyName $aName -NotePropertyValue $agentInfo -Force
                }
            }

            return [PSCustomObject]@{
                schedules = $schedulesList
                queues    = $queuesMap
            }
        }

        # ----------------------------------------------------------------
        # Replicate /api/queue/cancel endpoint logic
        # Returns hashtable: @{ ok=$true; queue_depth=N } or @{ ok=$false; error="..." }
        # ----------------------------------------------------------------
        function Invoke-QueueCancelLogic {
            param(
                [string]$StateDir,
                [string]$AgentName,
                [string]$JobName
            )
            if ($AgentName -notmatch '^[a-zA-Z0-9_-]+$' -or $JobName -notmatch '^[a-zA-Z0-9_-]+$') {
                return @{ ok = $false; error = "invalid agent or job name" }
            }
            $queueFile = Join-Path $StateDir "agents" $AgentName $JobName "queue"
            if (-not (Test-Path $queueFile)) {
                return @{ ok = $false; error = "queue file not found" }
            }
            $qText = [System.IO.File]::ReadAllText($queueFile, [System.Text.Encoding]::UTF8).Trim()
            $depth = 0
            [int]::TryParse($qText, [ref]$depth) | Out-Null
            if ($depth -le 0) {
                return @{ ok = $false; error = "queue already empty" }
            }
            $newDepth = [Math]::Max(0, $depth - 1)
            $tmpFile  = "$queueFile.tmp"
            [System.IO.File]::WriteAllText($tmpFile, "$newDepth", [System.Text.Encoding]::UTF8)
            Move-Item -Path $tmpFile -Destination $queueFile -Force

            # Update dashboard.json if present
            $dashFile = Join-Path $StateDir "dashboard.json"
            if (Test-Path $dashFile) {
                try {
                    $dashObj = [System.IO.File]::ReadAllText($dashFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                    if ($dashObj.agents.$AgentName.jobs.$JobName) {
                        $dashObj.agents.$AgentName.jobs.$JobName | Add-Member `
                            -NotePropertyName "queue_depth" -NotePropertyValue $newDepth -Force
                    }
                    $dashTmp = "$dashFile.tmp"
                    [System.IO.File]::WriteAllText($dashTmp, ($dashObj | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)
                    Move-Item -Path $dashTmp -Destination $dashFile -Force
                } catch {}
            }

            # Write event
            $now      = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            $eventObj = [PSCustomObject]@{
                timestamp     = $now
                agent         = $AgentName
                job           = $JobName
                event         = "queue_cancelled"
                details       = [PSCustomObject]@{ cancelled_by = "user"; remaining_depth = $newDepth }
                systemVersion = "0.3.0"
            }
            $eventLine  = ($eventObj | ConvertTo-Json -Compress)
            $eventsFile = Join-Path $StateDir "events.jsonl"
            [System.IO.File]::AppendAllText($eventsFile, "$eventLine`n", [System.Text.Encoding]::UTF8)

            return @{ ok = $true; queue_depth = $newDepth }
        }

        # ----------------------------------------------------------------
        # Replicate /api/job/stop endpoint logic
        # SkipKill switch suppresses Stop-Process (safe for unit tests)
        # Returns hashtable: @{ ok=$true; pid=N } or @{ ok=$false; error="..." }
        # ----------------------------------------------------------------
        function Invoke-JobStopLogic {
            param(
                [string]$StateDir,
                [string]$AgentName,
                [string]$JobName,
                [switch]$SkipKill
            )
            if ($AgentName -notmatch '^[a-zA-Z0-9_-]+$' -or $JobName -notmatch '^[a-zA-Z0-9_-]+$') {
                return @{ ok = $false; error = "invalid agent or job name" }
            }
            $lockFile = Join-Path $StateDir "agents" $AgentName "lock"
            if (-not (Test-Path $lockFile)) {
                return @{ ok = $false; error = "not running" }
            }
            $lockText = [System.IO.File]::ReadAllText($lockFile, [System.Text.Encoding]::UTF8)
            $lockObj  = $lockText | ConvertFrom-Json
            $pidVal   = if ($lockObj.PSObject.Properties["pid"])    { [int]$lockObj.pid }    else { 0 }
            $runId    = if ($lockObj.PSObject.Properties["run_id"]) { $lockObj.run_id }      else { "" }
            $lockTs   = if ($lockObj.PSObject.Properties["ts"])     { $lockObj.ts }          else { "" }

            $elapsed = 0
            if ($lockTs -ne "") {
                try {
                    $startDt = [DateTime]::Parse($lockTs, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                    $elapsed = [int]([DateTime]::UtcNow - $startDt).TotalSeconds
                } catch {}
            }

            if (-not $SkipKill -and $pidVal -gt 0) {
                Stop-Process -Id $pidVal -Force -ErrorAction SilentlyContinue
            }

            Remove-Item -Path $lockFile -Force -ErrorAction SilentlyContinue

            # Update dashboard if present
            $dashFile = Join-Path $StateDir "dashboard.json"
            if (Test-Path $dashFile) {
                try {
                    $dashObj = [System.IO.File]::ReadAllText($dashFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                    if ($dashObj.agents.$AgentName.jobs.$JobName) {
                        $dashObj.agents.$AgentName.jobs.$JobName | Add-Member `
                            -NotePropertyName "status" -NotePropertyValue "idle" -Force
                        $dashObj.agents.$AgentName.jobs.$JobName | Add-Member `
                            -NotePropertyName "run_id" -NotePropertyValue $null -Force
                        $dashObj.agents.$AgentName.jobs.$JobName | Add-Member `
                            -NotePropertyName "pid" -NotePropertyValue $null -Force
                    }
                    $dashTmp = "$dashFile.tmp"
                    [System.IO.File]::WriteAllText($dashTmp, ($dashObj | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)
                    Move-Item -Path $dashTmp -Destination $dashFile -Force
                } catch {}
            }

            $now      = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            $eventObj = [PSCustomObject]@{
                timestamp     = $now
                agent         = $AgentName
                job           = $JobName
                event         = "force_stopped"
                details       = [PSCustomObject]@{
                    stopped_by      = "user"
                    pid             = $pidVal
                    run_id          = $runId
                    elapsed_seconds = $elapsed
                }
                systemVersion = "0.3.0"
            }
            $eventLine  = ($eventObj | ConvertTo-Json -Compress)
            $eventsFile = Join-Path $StateDir "events.jsonl"
            [System.IO.File]::AppendAllText($eventsFile, "$eventLine`n", [System.Text.Encoding]::UTF8)

            return @{ ok = $true; pid = $pidVal }
        }

    } # end BeforeAll

    # =======================================================================
    Context "Schedule API" {

        It "Returns schedules list from job config" {
            $root = New-TestRoot
            try {
                $schedJson = @{
                    schedules = @(
                        @{ agent = "test-agent"; job = "test-job"; cron = "0 7 * * *"; description = "Daily at 7am" }
                    )
                } | ConvertTo-Json -Depth 5
                Set-Content -Path (Join-Path $root "config/schedules.json") -Value $schedJson -Encoding UTF8

                $jobsJson = @{
                    jobs = @(
                        @{ name = "test-job"; prompt = "echo test" }
                    )
                } | ConvertTo-Json -Depth 5
                Set-Content -Path (Join-Path $root "config/jobs/test-agent.json") -Value $jobsJson -Encoding UTF8

                $result = Invoke-SchedulesLogic -ConfigDir (Join-Path $root "config") -StateDir (Join-Path $root "state")

                $result.schedules.Count      | Should -Be 1
                $result.schedules[0].agent   | Should -Be "test-agent"
                $result.schedules[0].job     | Should -Be "test-job"
                $result.schedules[0].cron    | Should -Be "0 7 * * *"
                $result.schedules[0].description | Should -Be "Daily at 7am"
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Returns empty queues map when state agents dir does not exist" {
            $root = New-TestRoot
            try {
                $schedJson = @{ schedules = @() } | ConvertTo-Json
                Set-Content -Path (Join-Path $root "config/schedules.json") -Value $schedJson -Encoding UTF8

                Remove-Item -Path (Join-Path $root "state/agents") -Recurse -Force

                $result = Invoke-SchedulesLogic -ConfigDir (Join-Path $root "config") -StateDir (Join-Path $root "state")

                # PSCustomObject with no properties returns $null for Count; either 0 or $null is correct
                $count = $result.queues.PSObject.Properties.Count
                ($count -eq 0 -or $null -eq $count) | Should -Be $true
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Includes lock info in queues when lock file exists" {
            $root = New-TestRoot
            try {
                $schedJson = @{ schedules = @() } | ConvertTo-Json
                Set-Content -Path (Join-Path $root "config/schedules.json") -Value $schedJson -Encoding UTF8

                $agentStateDir = Join-Path $root "state/agents/test-agent"
                New-Item -ItemType Directory -Path $agentStateDir -Force | Out-Null
                $lockContent = @{ ts = "2026-01-01T00:00:00Z"; job = "test-job"; pid = 9999; run_id = "abc12345" } | ConvertTo-Json -Compress
                Set-Content -Path (Join-Path $agentStateDir "lock") -Value $lockContent -Encoding UTF8

                $result = Invoke-SchedulesLogic -ConfigDir (Join-Path $root "config") -StateDir (Join-Path $root "state")

                $agentQueues = $result.queues."test-agent"
                $agentQueues             | Should -Not -BeNullOrEmpty
                $agentQueues.lock        | Should -Not -BeNullOrEmpty
                $agentQueues.lock.pid    | Should -Be 9999
                $agentQueues.lock.run_id | Should -Be "abc12345"
                $agentQueues.lock.job    | Should -Be "test-job"
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Includes queue_depth in jobs map when queue file exists" {
            $root = New-TestRoot
            try {
                $schedJson = @{ schedules = @() } | ConvertTo-Json
                Set-Content -Path (Join-Path $root "config/schedules.json") -Value $schedJson -Encoding UTF8

                $jobStateDir = Join-Path $root "state/agents/test-agent/my-job"
                New-Item -ItemType Directory -Path $jobStateDir -Force | Out-Null
                Set-Content -Path (Join-Path $jobStateDir "queue") -Value "3" -Encoding UTF8

                $result = Invoke-SchedulesLogic -ConfigDir (Join-Path $root "config") -StateDir (Join-Path $root "state")

                $jobEntry = $result.queues."test-agent".jobs."my-job"
                $jobEntry             | Should -Not -BeNullOrEmpty
                $jobEntry.queue_depth | Should -Be 3
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Reports queue_depth 0 when no queue file exists for a job" {
            $root = New-TestRoot
            try {
                $schedJson = @{ schedules = @() } | ConvertTo-Json
                Set-Content -Path (Join-Path $root "config/schedules.json") -Value $schedJson -Encoding UTF8

                $jobStateDir = Join-Path $root "state/agents/test-agent/my-job"
                New-Item -ItemType Directory -Path $jobStateDir -Force | Out-Null

                $result = Invoke-SchedulesLogic -ConfigDir (Join-Path $root "config") -StateDir (Join-Path $root "state")

                $result.queues."test-agent".jobs."my-job".queue_depth | Should -Be 0
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Handles missing job config for a schedule entry gracefully" {
            $root = New-TestRoot
            try {
                $schedJson = @{
                    schedules = @(
                        @{ agent = "ghost-agent"; job = "ghost-job"; cron = "0 1 * * *" }
                    )
                } | ConvertTo-Json -Depth 5
                Set-Content -Path (Join-Path $root "config/schedules.json") -Value $schedJson -Encoding UTF8
                # No config/jobs/ghost-agent.json created intentionally

                $result = Invoke-SchedulesLogic -ConfigDir (Join-Path $root "config") -StateDir (Join-Path $root "state")

                $result.schedules.Count      | Should -Be 1
            } finally {
                Remove-TestRoot -Root $root
            }
        }

    } # end Context "Schedule API"

    # =======================================================================
    Context "Queue Cancel" {

        It "Decrements queue depth from 3 to 2" {
            $root = New-TestRoot
            try {
                $jobStateDir = Join-Path $root "state/agents/test-agent/test-job"
                New-Item -ItemType Directory -Path $jobStateDir -Force | Out-Null
                Set-Content -Path (Join-Path $jobStateDir "queue") -Value "3" -Encoding UTF8

                $res = Invoke-QueueCancelLogic -StateDir (Join-Path $root "state") `
                    -AgentName "test-agent" -JobName "test-job"

                $res.ok          | Should -Be $true
                $res.queue_depth | Should -Be 2
                $stored = [System.IO.File]::ReadAllText((Join-Path $jobStateDir "queue")).Trim()
                $stored | Should -Be "2"
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Decrements queue depth from 2 to 1 on second cancel" {
            $root = New-TestRoot
            try {
                $jobStateDir = Join-Path $root "state/agents/test-agent/test-job"
                New-Item -ItemType Directory -Path $jobStateDir -Force | Out-Null
                Set-Content -Path (Join-Path $jobStateDir "queue") -Value "2" -Encoding UTF8

                $res = Invoke-QueueCancelLogic -StateDir (Join-Path $root "state") `
                    -AgentName "test-agent" -JobName "test-job"

                $res.ok          | Should -Be $true
                $res.queue_depth | Should -Be 1
                $stored = [System.IO.File]::ReadAllText((Join-Path $jobStateDir "queue")).Trim()
                $stored | Should -Be "1"
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Returns error when queue is already at 0" {
            $root = New-TestRoot
            try {
                $jobStateDir = Join-Path $root "state/agents/test-agent/test-job"
                New-Item -ItemType Directory -Path $jobStateDir -Force | Out-Null
                Set-Content -Path (Join-Path $jobStateDir "queue") -Value "0" -Encoding UTF8

                $res = Invoke-QueueCancelLogic -StateDir (Join-Path $root "state") `
                    -AgentName "test-agent" -JobName "test-job"

                $res.ok    | Should -Be $false
                $res.error | Should -Be "queue already empty"
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Returns error when queue file does not exist" {
            $root = New-TestRoot
            try {
                $res = Invoke-QueueCancelLogic -StateDir (Join-Path $root "state") `
                    -AgentName "test-agent" -JobName "test-job"

                $res.ok    | Should -Be $false
                $res.error | Should -Be "queue file not found"
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Writes queue_cancelled event to events.jsonl after cancel" {
            $root = New-TestRoot
            try {
                $jobStateDir = Join-Path $root "state/agents/test-agent/test-job"
                New-Item -ItemType Directory -Path $jobStateDir -Force | Out-Null
                Set-Content -Path (Join-Path $jobStateDir "queue") -Value "2" -Encoding UTF8

                Invoke-QueueCancelLogic -StateDir (Join-Path $root "state") `
                    -AgentName "test-agent" -JobName "test-job" | Out-Null

                $eventsFile = Join-Path $root "state/events.jsonl"
                Test-Path $eventsFile | Should -Be $true

                $lines = @([System.IO.File]::ReadAllLines($eventsFile, [System.Text.Encoding]::UTF8) |
                    Where-Object { $_.Trim() -ne "" })
                $lines.Count | Should -BeGreaterOrEqual 1

                $last = $lines[$lines.Count - 1] | ConvertFrom-Json
                $last.event                | Should -Be "queue_cancelled"
                $last.agent                | Should -Be "test-agent"
                $last.job                  | Should -Be "test-job"
                $last.details.cancelled_by | Should -Be "user"
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Updates dashboard.json queue_depth after cancel" {
            $root = New-TestRoot
            try {
                $jobStateDir = Join-Path $root "state/agents/test-agent/test-job"
                New-Item -ItemType Directory -Path $jobStateDir -Force | Out-Null
                Set-Content -Path (Join-Path $jobStateDir "queue") -Value "3" -Encoding UTF8

                $dashContent = @{
                    agents = @{
                        "test-agent" = @{
                            jobs = @{
                                "test-job" = @{
                                    status      = "queued"
                                    queue_depth = 3
                                }
                            }
                        }
                    }
                } | ConvertTo-Json -Depth 10
                $dashFile = Join-Path $root "state/dashboard.json"
                Set-Content -Path $dashFile -Value $dashContent -Encoding UTF8

                Invoke-QueueCancelLogic -StateDir (Join-Path $root "state") `
                    -AgentName "test-agent" -JobName "test-job" | Out-Null

                $dash = [System.IO.File]::ReadAllText($dashFile) | ConvertFrom-Json
                $dash.agents."test-agent".jobs."test-job".queue_depth | Should -Be 2
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Returns error for invalid agent name containing path traversal chars" {
            $root = New-TestRoot
            try {
                $res = Invoke-QueueCancelLogic -StateDir (Join-Path $root "state") `
                    -AgentName "../evil" -JobName "test-job"

                $res.ok    | Should -Be $false
                $res.error | Should -Be "invalid agent or job name"
            } finally {
                Remove-TestRoot -Root $root
            }
        }

    } # end Context "Queue Cancel"

    # =======================================================================
    Context "Lock File Format" {

        It "New lock file format contains ts, job, pid, and run_id fields" {
            $root = New-TestRoot
            try {
                $agentStateDir = Join-Path $root "state/agents/test-agent"
                New-Item -ItemType Directory -Path $agentStateDir -Force | Out-Null

                # Write lock file directly as a string to preserve exact field types
                $lockFile = Join-Path $agentStateDir "lock"
                $lockContent = '{"ts":"2026-03-23T10:00:00Z","job":"test-job","pid":12345,"run_id":"abc12345"}'
                Set-Content -Path $lockFile -Value $lockContent -Encoding UTF8

                $parsed = [System.IO.File]::ReadAllText($lockFile) | ConvertFrom-Json

                # ts may come back as DateTime or string depending on PS version; check all 4 fields exist
                $parsed.PSObject.Properties["ts"]     | Should -Not -BeNullOrEmpty
                $parsed.PSObject.Properties["job"]    | Should -Not -BeNullOrEmpty
                $parsed.PSObject.Properties["pid"]    | Should -Not -BeNullOrEmpty
                $parsed.PSObject.Properties["run_id"] | Should -Not -BeNullOrEmpty
                $parsed.job    | Should -Be "test-job"
                $parsed.pid    | Should -Be 12345
                $parsed.run_id | Should -Be "abc12345"
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Old lock file format (no pid, no run_id) parses without error" {
            $root = New-TestRoot
            try {
                $agentStateDir = Join-Path $root "state/agents/test-agent"
                New-Item -ItemType Directory -Path $agentStateDir -Force | Out-Null

                # Write the old format directly as JSON string
                $lockFile = Join-Path $agentStateDir "lock"
                $oldLockContent = '{"ts":"2026-01-01T00:00:00Z","job":"old-job"}'
                Set-Content -Path $lockFile -Value $oldLockContent -Encoding UTF8

                # Parse directly; Should -Not -Throw cannot capture return values from inner scope
                $threw  = $false
                $parsed = $null
                try {
                    $parsed = [System.IO.File]::ReadAllText($lockFile) | ConvertFrom-Json
                } catch {
                    $threw = $true
                }
                $threw | Should -Be $false

                # ts may be parsed as DateTime by PS; verify job field and ts presence
                $parsed.PSObject.Properties["ts"]  | Should -Not -BeNullOrEmpty
                $parsed.job | Should -Be "old-job"
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Old lock file format has no pid field (server treats absent pid as 0)" {
            $root = New-TestRoot
            try {
                $agentStateDir = Join-Path $root "state/agents/test-agent"
                New-Item -ItemType Directory -Path $agentStateDir -Force | Out-Null

                $oldLockContent = @{ ts = "2026-01-01T00:00:00Z"; job = "old-job" } | ConvertTo-Json -Compress
                Set-Content -Path (Join-Path $agentStateDir "lock") -Value $oldLockContent -Encoding UTF8

                $parsed = [System.IO.File]::ReadAllText((Join-Path $agentStateDir "lock")) | ConvertFrom-Json

                # Mirrors the defensive access pattern used in server.ps1
                $pidVal = if ($parsed.PSObject.Properties["pid"]) { [int]$parsed.pid } else { 0 }
                $pidVal | Should -Be 0
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "New lock file pid field is accessible as integer" {
            $root = New-TestRoot
            try {
                $agentStateDir = Join-Path $root "state/agents/test-agent"
                New-Item -ItemType Directory -Path $agentStateDir -Force | Out-Null

                $lockContent = @{
                    ts     = "2026-03-23T12:00:00Z"
                    job    = "my-job"
                    pid    = 55555
                    run_id = "ff001122"
                } | ConvertTo-Json -Compress
                Set-Content -Path (Join-Path $agentStateDir "lock") -Value $lockContent -Encoding UTF8

                $parsed = [System.IO.File]::ReadAllText((Join-Path $agentStateDir "lock")) | ConvertFrom-Json
                $pidVal = if ($parsed.PSObject.Properties["pid"]) { [int]$parsed.pid } else { 0 }

                $pidVal           | Should -Be 55555
                $pidVal -is [int] | Should -Be $true
            } finally {
                Remove-TestRoot -Root $root
            }
        }

    } # end Context "Lock File Format"

    # =======================================================================
    Context "Force Stop" {

        It "Removes lock file when stop is called" {
            $root = New-TestRoot
            try {
                $agentStateDir = Join-Path $root "state/agents/test-agent"
                New-Item -ItemType Directory -Path $agentStateDir -Force | Out-Null

                $lockContent = @{ ts = "2026-03-23T10:00:00Z"; job = "test-job"; pid = 0; run_id = "dead0001" } | ConvertTo-Json -Compress
                $lockFile = Join-Path $agentStateDir "lock"
                Set-Content -Path $lockFile -Value $lockContent -Encoding UTF8

                $res = Invoke-JobStopLogic -StateDir (Join-Path $root "state") `
                    -AgentName "test-agent" -JobName "test-job" -SkipKill

                $res.ok | Should -Be $true
                Test-Path $lockFile | Should -Be $false
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Returns error when no lock file exists (agent not running)" {
            $root = New-TestRoot
            try {
                $res = Invoke-JobStopLogic -StateDir (Join-Path $root "state") `
                    -AgentName "test-agent" -JobName "test-job" -SkipKill

                $res.ok    | Should -Be $false
                $res.error | Should -Be "not running"
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Writes force_stopped event to events.jsonl after stop" {
            $root = New-TestRoot
            try {
                $agentStateDir = Join-Path $root "state/agents/test-agent"
                New-Item -ItemType Directory -Path $agentStateDir -Force | Out-Null

                $lockContent = @{ ts = "2026-03-23T10:00:00Z"; job = "test-job"; pid = 0; run_id = "feed0001" } | ConvertTo-Json -Compress
                Set-Content -Path (Join-Path $agentStateDir "lock") -Value $lockContent -Encoding UTF8

                Invoke-JobStopLogic -StateDir (Join-Path $root "state") `
                    -AgentName "test-agent" -JobName "test-job" -SkipKill | Out-Null

                $eventsFile = Join-Path $root "state/events.jsonl"
                Test-Path $eventsFile | Should -Be $true

                $lines = @([System.IO.File]::ReadAllLines($eventsFile, [System.Text.Encoding]::UTF8) |
                    Where-Object { $_.Trim() -ne "" })
                $lines.Count | Should -BeGreaterOrEqual 1

                $last = $lines[$lines.Count - 1] | ConvertFrom-Json
                $last.event              | Should -Be "force_stopped"
                $last.agent              | Should -Be "test-agent"
                $last.job                | Should -Be "test-job"
                $last.details.stopped_by | Should -Be "user"
                $last.details.run_id     | Should -Be "feed0001"
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Updates dashboard status to idle after stop" {
            $root = New-TestRoot
            try {
                $agentStateDir = Join-Path $root "state/agents/test-agent"
                New-Item -ItemType Directory -Path $agentStateDir -Force | Out-Null

                $lockContent = @{ ts = "2026-03-23T10:00:00Z"; job = "test-job"; pid = 0; run_id = "cafe0001" } | ConvertTo-Json -Compress
                Set-Content -Path (Join-Path $agentStateDir "lock") -Value $lockContent -Encoding UTF8

                $dashContent = @{
                    agents = @{
                        "test-agent" = @{
                            jobs = @{
                                "test-job" = @{
                                    status = "running"
                                    run_id = "cafe0001"
                                    pid    = 0
                                }
                            }
                        }
                    }
                } | ConvertTo-Json -Depth 10
                $dashFile = Join-Path $root "state/dashboard.json"
                Set-Content -Path $dashFile -Value $dashContent -Encoding UTF8

                Invoke-JobStopLogic -StateDir (Join-Path $root "state") `
                    -AgentName "test-agent" -JobName "test-job" -SkipKill | Out-Null

                $dash = [System.IO.File]::ReadAllText($dashFile) | ConvertFrom-Json
                $dash.agents."test-agent".jobs."test-job".status | Should -Be "idle"
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Returns the pid from the lock file in the response" {
            $root = New-TestRoot
            try {
                $agentStateDir = Join-Path $root "state/agents/test-agent"
                New-Item -ItemType Directory -Path $agentStateDir -Force | Out-Null

                $lockContent = @{ ts = "2026-03-23T10:00:00Z"; job = "test-job"; pid = 0; run_id = "babe0002" } | ConvertTo-Json -Compress
                Set-Content -Path (Join-Path $agentStateDir "lock") -Value $lockContent -Encoding UTF8

                $res = Invoke-JobStopLogic -StateDir (Join-Path $root "state") `
                    -AgentName "test-agent" -JobName "test-job" -SkipKill

                $res.ok  | Should -Be $true
                $res.pid | Should -Be 0
            } finally {
                Remove-TestRoot -Root $root
            }
        }

        It "Force stop with old lock format (no pid) returns pid 0 and does not throw" {
            $root = New-TestRoot
            try {
                $agentStateDir = Join-Path $root "state/agents/test-agent"
                New-Item -ItemType Directory -Path $agentStateDir -Force | Out-Null

                $oldLock = @{ ts = "2026-03-23T10:00:00Z"; job = "test-job" } | ConvertTo-Json -Compress
                Set-Content -Path (Join-Path $agentStateDir "lock") -Value $oldLock -Encoding UTF8

                # Call directly; Should -Not -Throw cannot capture return values
                $threw = $false
                $res   = $null
                try {
                    $res = Invoke-JobStopLogic -StateDir (Join-Path $root "state") `
                        -AgentName "test-agent" -JobName "test-job" -SkipKill
                } catch {
                    $threw = $true
                }
                $threw   | Should -Be $false
                $res.ok  | Should -Be $true
                $res.pid | Should -Be 0
            } finally {
                Remove-TestRoot -Root $root
            }
        }

    } # end Context "Force Stop"

} # end Describe "Task Queue Feature"
