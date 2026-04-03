# Virtual Office - Architecture

## System Overview

Virtual Office is a Windows-based agent orchestration framework that schedules, runs, and monitors Claude Code agents as background jobs. Config-driven via JSON files, file-based state, Windows Task Scheduler integration.

## Component Diagram

```
+------------------+     +------------------+     +------------------+
|  Task Scheduler  | --> |  Run-Hidden.vbs  | --> |  Invoke-Agent    |
|  (VO-* tasks)    |     |  (wscript, no    |     |  Job.ps1         |
|                  |     |   foreground win) |     +--------+---------+
+------------------+     +------------------+              |
                                                           v
                                                  +------------------+
                                                  |  Claude CLI      |
                                                  |  --agent <name>  |
                                                  +------------------+
                                                           |
                                     +-------------+-------+-------+
                                     |             |               |
                               +-----v----+  +----v-----+  +------v---+
                               |  state/   |  | output/  |  | output/  |
                               | dashboard |  | reports  |  | audit/   |
                               | events    |  |          |  | logs     |
                               +-----------+  +----------+  +----------+
                                     |
                               +-----v-----------------------+
                               |  server.ps1  (HTTP :8400)   |
                               |  /api/config                |
                               |  /api/dashboard             |
                               |  /api/events                |
                               |  /api/errors                |
                               |  /api/schedules             |
                               |  /api/queue/cancel  (POST)  |
                               |  /api/job/stop      (POST)  |
                               +-----+-----------------------+
                                     |
                               +-----v-----------+
                               |  Browser UI     |
                               |  (polls /api/)  |
                               +-----------------+
```

## Runner Data Flow

1. Task Scheduler fires at cron interval via `wscript Run-Hidden.vbs` wrapper
2. Invoke-AgentJob.ps1 checks lock -> queue or run
3. If running: creates lock, invokes claude CLI, captures output
4. Writes: output file, audit entry, event, dashboard state
5. Drains queue if entries exist
6. UI polls dashboard.json every 2s, renders agent cards

## Concurrency Model

- One lock file per agent/job combination
- Lock = exclusive run; other triggers queue
- Queue is FIFO, drained by the running instance after completion
- maxRuns is checked before each run (including queued drains)

## Task Scheduler Integration

All scheduled tasks use the `VO-` prefix (e.g., `VO-scrum-master-ado-status-update`).
Tasks invoke `wscript Run-Hidden.vbs "pwsh -NoProfile -File ..."` to suppress
foreground console windows. This avoids the S4U (Service for User) logon type
which requires administrator privileges. See design-decisions.md for rationale.

---

## Agent Inventory

| Agent | Display Name | Group | Description | Stale Lock (min) |
|-------|-------------|-------|-------------|-------------------|
| scrum-master | Scrum Master | Work Agents | Sprint progress, ADO autopilot, bug autopilot runs | 120 |
| bug-killer | Bug Killer | Work Agents | Scans repos for open issues, creates fix PRs, maintains open PRs | 180 |
| poster | Poster | Work Agents | Posts daily Bug-AutoPilot summary to Teams channel | 30 |
| emailer | Emailer | Other Agents | Manages Gmail inboxes -- scan, classify, digest (portal: localhost:8402) | 60 |
| auditor | Checker | Other Agents | Memory consolidation, sprint progress, compare-runs, OOF summary, report audit | 120 |
| hang-scout | Hang Scout | Other Agents | Hung job detection, py-spy diagnosis, daily 5W incident report | 15 |

### Agent Rename History

- `memo-checker` was renamed to `checker` (displayName: "Checker"). The agent now consolidates memory management, sprint progress reporting, run comparison, and report template auditing.

---

## Job Inventory

### scrum-master

| Job | Schedule | Description |
|-----|----------|-------------|
| ado-status-update | 9am + 9pm daily | ADO autopilot status tweet update (live) for Meeting Join + Notes |
| bug-autopilot-meeting-join | 8am + 8pm daily | Bug autopilot (live) for Meeting Join bugs |
| bug-autopilot-notes | On-demand | Bug autopilot (live) for Meeting Notes bugs |
| ado-burndown-update | On-demand | ADO autopilot burndown update (live) |

### bug-killer

| Job | Schedule | Description |
|-----|----------|-------------|
| scan-and-fix | 10am + 10pm daily | Scan all repos for open issues (all types), discover new repos, analyze and fix |
| open-pr-maintenance | Hourly at :03 | Resolve merge conflicts + address review comments on all open PRs |
| daily-summary | 1:30am daily | Aggregates all bug-killer activity from past 24h into single report, opens in Edge "Daily" tab group |

### emailer

| Job | Schedule | Description |
|-----|----------|-------------|
| scan-all-mailboxes | 7am daily | Scan all Gmail mailboxes, classify, generate digest |

### checker

| Job | Schedule | Description |
|-----|----------|-------------|
| consolidate-agent-memories | 3am daily | Memory consolidation, dedup with logical conflict detection, report template audit |
| TODO-sprint-progress | 7am weekdays | Sprint progress report |
| TODO-compare-runs | 11am daily | Compare run results, file GitHub issues |
| YTD-OOF-Summary | 6am last day of month | Monthly YTD OOF summary for direct reports |

### poster

| Job | Schedule | Description |
|-----|----------|-------------|
| Bug-Autopilot-Adoption-daily-summary | 7:30am daily | Queries ADO, posts formatted summary to Teams Bug-Autopilot channel |

### hang-scout

| Job | Schedule | Description |
|-----|----------|-------------|
| detect-hang | Hourly at :45 | Scans all agent lock files, classifies hangs, py-spy stack capture, kills if safe |
| detect-scrum-master | On-demand | Targeted hang detection for scrum-master only (20min hang / 60min kill) |
| daily-report | Midnight daily | 5W incident report with bug-autopilot performance analysis |

### Job Rename / Merge History

- `bug-autopilot` renamed to `bug-autopilot-meeting-join` (clarifies scope)
- `consolidate` renamed to `consolidate-agent-memories` (clearer purpose)
- `detect` renamed to `detect-hang` (consistent naming)
- `resolve-merge-conflicts` + `review-pr-comments` merged into `open-pr-maintenance` (single hourly job handles both)
- New: `detect-scrum-master` -- targeted hang detection with tighter thresholds
- New: `Bug-Autopilot-Adoption-daily-summary` -- poster agent's Teams posting job
- New: `daily-report` -- hang-scout's 5W report with bug-autopilot perf analysis
- New: `daily-summary` -- bug-killer's aggregated activity report at 1:30am

---

## Hang Detection Architecture

The hang-scout agent uses per-agent configurable thresholds stored in the
`detect-hang` job's `hangDetection` config block:

```
hangDetection:
  defaultHangThresholdMinutes: 60
  defaultKillThresholdMinutes: 120
  exclude: [hang-scout]
  perAgent:
    scrum-master:  hang=60  kill=120
    bug-killer:    hang=90  kill=180
    emailer:       hang=30  kill=60
    auditor:       hang=20  kill=30
    poster:        hang=15  kill=30
```

Detection flow:
1. Scan all lock files under state/agents/*/lock
2. Compare lock age against agent-specific hangThresholdMinutes
3. For hung jobs: walk process tree, capture py-spy stack traces
4. Classify hang pattern against known patterns DB
5. If age > killThresholdMinutes, kill the process
6. Log incident, file GitHub issue for new/unknown patterns

The daily-report job (midnight) generates a 5W incident report including:
- Executive summary of all hangs in past 24h
- Per-incident 5W details (Who/What/When/Where/Why)
- Pattern summary table
- Chart.js runtime trends
- Bug-autopilot performance analysis (step timings, outlier detection, trend alerts)

---

## Dashboard Architecture -- Mission Control Tab

### Top Navigation

Centered pill-shaped tabs: AGENTS | EVENT LOG | TASK QUEUE (extensible for future: CHAT, MEMORY).
Active tab is filled/highlighted. Selection persisted to URL `?view=`.

### Summary Stats Row (4 tiles)

Horizontal row of metric cards below nav, dark card backgrounds with teal/green left border accent.

**Tile 1 -- JOBS COMPLETED**
- Primary: count of jobs completed today (events where event=completed since midnight)
- Secondary: count completed this week (since Monday midnight)
- Data source: `state/events.jsonl` -- filter by event type "completed", aggregate by time window

**Tile 2 -- JOBS FAILED**
- Primary: count of jobs failed today (events where event=failed since midnight)
- Secondary: count failed this week
- Data source: `state/events.jsonl` -- filter by event type "failed"

**Tile 3 -- AGENTS ONLINE**
- Primary: "X active" -- count of agents currently in busy/running status
- Secondary: "Y total" -- total registered agents from config
- Data source: `state/dashboard.json` agent statuses + `config/agents.json` total count

**Tile 4 -- SYSTEM HEARTBEAT**
- Primary: "Operational" / "Degraded" / "Disconnected"
- Secondary: "Updated HH:MM AM/PM" -- timestamp of last successful poll
- Logic: All polls succeed + no unresolved errors = Operational. Poll failures or high error count = Degraded. Cannot reach server = Disconnected.

### Agent Cards View

Full-page view showing ALL agent cards (not just working -- idle agents shown too).

Each agent card:
- Agent name (bold) from `config/agents.json` displayName
- Activity line (gray): if running, "Running: {job-name}" with elapsed time. If idle, last completed job description + time ago. If never run, agent description from config.
- Status badge (right-aligned): green "Working" pill (with pulse animation) if busy, green "Idle" pill if idle, gray "Disabled" pill if disabled
- Timestamp: last activity time (started time if running, last_completed if idle)
- "View Events" link: opens Event Log tab filtered to that agent
- Data source: merged config + dashboard.json state

Note: The "Recent Activity" sidebar was removed. Activity viewing is now done via the dedicated Event Log tab.

### Event Log Tab

Full-page event viewer with filters:
- Agent dropdown (dynamic -- populated from events, filterable per-agent)
- Event type filter
- Time range filter
- Loads all events, newest first
- Filter dropdowns apply client-side

### Task Queue Tab

Third top-level tab. Two sections: Upcoming Schedule table (top) and Per-Agent Queue Cards (bottom).

**Upcoming Schedule Table**

Expands each enabled cron schedule into its next concrete fire instances (up to 10 per schedule, 20 globally), sorted chronologically. Disabled schedules appear at the bottom as a single row.

- Fire time column: human-readable date + 12-hour time (e.g., "Mon, Mar 23, 9:00 AM")
- Schedule column: human-readable cron description (e.g., "Weekdays at 9:00 AM"); tooltip shows raw cron expression
- Status badge: scheduled | running | queued | disabled
- Cross-referenced with dashboard state: the first matching schedule row for a currently running job is marked "running"; subsequent rows for jobs with queue depth > 0 are marked "queued"
- Action column: Cancel button on queued rows (single-click); Force Stop button on running rows (2-click confirmation: first click shows "Click again to stop", auto-resets after 3s)
- Click-to-copy on task identifiers (agent/job names copy to clipboard on click)
- Cron expansion and next-fire computation run client-side in JavaScript on each poll cycle

**Per-Agent Queue Cards**

One card per registered agent, colored by agent. Each card shows:
- Agent display name + Working/Idle/Disabled status badge
- Lock indicator: locked (agent has an active job) or unlocked
- If locked: the currently running job name, elapsed time, and a Force Stop button
- Per-job list with queue depth badge and Cancel button when depth > 0
- Next scheduled fire time (earliest across all enabled schedules for that agent)

### API Endpoints

| Endpoint | Method | Description |
|---|---|---|
| /api/config | GET | Agent registry + job definitions |
| /api/dashboard | GET | Runtime agent state |
| /api/events | GET | Event stream |
| /api/errors | GET | Error log |
| /api/schedules | GET | Merged schedule list + per-agent queue/lock state |
| /api/queue/cancel | POST | Decrements queue depth by 1, writes queue_cancelled event + audit entry |
| /api/job/stop | POST | Kills process by PID from lock file, removes lock, writes force_stopped event + audit entry |
| /api/output/{path} | GET | Serves report files; MD auto-rendered to styled HTML |

`/api/schedules` response shape:
```json
{
  "schedules": [{ "agent": "str", "job": "str", "cron": "str", "enabled": true, "description": "str" }],
  "queues": {
    "<agent>": {
      "lock": { "job": "str", "ts": "ISO-8601", "run_id": "str", "pid": 0 },
      "jobs": { "<job>": { "queue_depth": 0 } }
    }
  }
}
```

### Data Flow

```
config/agents.json + config/jobs/*.json
        |
        v
  /api/config  ------> UI merges with dashboard state

state/dashboard.json
        |
        v
  /api/dashboard -----> Agent cards (status, running job, last completed)

state/events.jsonl
        |
        v
  /api/events -------> Event Log tab + stats aggregation (client-side)

state/errors.jsonl
        |
        v
  /api/errors -------> Error badges on agent cards + system health

config/schedules.json + state/agents/{agent}/{job}/queue + state/agents/{agent}/lock
        |
        v
  /api/schedules -----> Task Queue tab (schedule table + queue cards)
```

### Theme

Dark mode: near-black background (#0d1117), dark slate cards (#161b22), teal/green accents (#22c55e), white/light gray text. Matches the Mission Control aesthetic from OpenClaw.

### Report Viewing

Report links use server-relative `/api/output/{path}` URLs. MD files auto-rendered to styled HTML by the server. HTML files served directly. All open in new browser tab.

### VO Subtitle Standard

All HTML reports generated by any agent/job MUST include a standard subtitle
immediately below the main title:

```html
<p style="color:#888; font-size:13px; margin-top:-10px;">
  Agent: <DisplayName> | Job: <job-name> | Start: <ISO> | Complete: <ISO>
</p>
```

This provides consistent provenance tracking across all agent outputs.
The checker's consolidate-agent-memories job includes a report template audit
that verifies all agent files and job configs enforce this standard.

---

## File Structure

| Path | Purpose |
|------|---------|
| `ui/index.html` | Page structure |
| `ui/app.js` | All dashboard logic |
| `ui/styles.css` | Dark theme styling |
| `ui/server.ps1` | HTTP server + API endpoints + MD-to-HTML rendering |
| `config/agents.json` | Agent registry (name, icon, group, description, portalUrl) |
| `config/schedules.json` | Cron schedules |
| `config/jobs/{agent}.json` | Job definitions (prompt, enabled, description) |
| `runner/Invoke-AgentJob.ps1` | Core job runner |
| `runner/Register-Schedules.ps1` | Task Scheduler registration |
| `runner/Run-Hidden.vbs` | VBScript wrapper to suppress foreground windows |
| `runner/Compare-Runs.py` | Cross-run comparison script |
| `runner/Get-JobDurations.py` | Job duration analysis for reports |
| `runner/constants.ps1` | System version and shared constants |
| `state/dashboard.json` | Runtime agent state |
| `state/events.jsonl` | Append-only event stream |
| `state/errors.jsonl` | Append-only error log |
| `state/agents/{agent}/lock` | Per-agent lock file |
| `state/agents/{agent}/{job}/queue` | Per-job queue depth file |
| `output/{agent}/` | Job output files (MD + HTML reports) |
| `output/audit/YYYY-MM.jsonl` | Monthly audit trail |

## File Formats

### dashboard.json

```json
{
  "lastUpdated": "ISO-8601",
  "agents": {
    "<agent-name>": {
      "status": "idle|busy",
      "activeJob": "<job-name>|null",
      "jobs": {
        "<job-name>": {
          "status": "idle|running|completed|disabled",
          "run": 0,
          "queueDepth": 0,
          "lastCompleted": "ISO-8601|null",
          "lastOutput": "relative-path|null"
        }
      }
    }
  }
}
```

### events.jsonl (one line per event)

```json
{"ts": "ISO-8601", "agent": "str", "job": "str", "event": "started|completed|queued|dequeued|error|skipped|force_stopped|queue_cancelled", "runId": "str", "details": {}, "systemVersion": "str"}
```

**Event type reference:**

| Event | Trigger | Notable details fields |
|---|---|---|
| started | Job begins execution | run_id |
| completed | Job exits with code 0 | duration, exit_code |
| failed | Job exits non-zero | exit_code, duration |
| queued | Trigger fires while locked | queue_depth |
| dequeued | Queued entry begins execution | |
| skipped | maxRuns limit reached | |
| stale_lock_cleared | Lock file found stale on startup | lock_age_seconds |
| schedule_registered | Schedule entry added | cron |
| schedule_removed | Schedule entry removed | |
| force_stopped | User clicked Force Stop in UI | pid, run_id, elapsed_seconds, stopped_by |
| queue_cancelled | User clicked Cancel in UI | cancelled_by, remaining_depth |

### errors.jsonl (one line per error)

```json
{
  "ts": "ISO-8601",
  "agent": "string",
  "job": "string",
  "runId": "string",
  "level": "error|warning|timeout",
  "summary": "short description",
  "detail": "first 500 chars of error output",
  "logPath": "relative path to output file",
  "exitCode": "number",
  "duration": "string (e.g. 142s)",
  "resolved": "boolean",
  "systemVersion": "string"
}
```

**Error levels:**

| Level     | Trigger                                    |
|-----------|--------------------------------------------|
| `error`   | Non-zero exit code from claude CLI         |
| `warning` | Partial failure (job completed with issues) |
| `timeout` | Job exceeded its configured max duration   |

**Resolution flow:**

- Errors are written with `resolved: false`.
- The dashboard UI provides a "Mark Resolved" action which sets `resolved: true`.
- Resolved errors remain in the file for audit purposes but do not count toward the unresolved error badge in the UI.

**Dashboard integration:**

- Agent-level fields: `errorCount` (unresolved errors across all jobs) and `lastError` (timestamp of most recent error).
- Job-level fields: `lastOutput` (relative path to most recent output file) and `lastOutputTime` (ISO-8601 timestamp of that output).

### audit log (output/audit/YYYY-MM.jsonl)

```json
{"ts": "ISO-8601", "action": "str", "agent": "str", "job": "str", "runId": "str", "systemVersion": "str", "details": {}}
```

### counter.json

```json
{"count": 0, "lastRun": "ISO-8601|null", "lastRunId": "str|null"}
```

### lock file (state/agents/{agent}/lock)

Written atomically when a job begins. Updated with pid and run_id after the claude process starts.

```json
{
  "job": "str",
  "ts": "ISO-8601",
  "run_id": "str",
  "pid": 12345
}
```

Lock files without `pid` are still parsed safely (treated as pid=0, which skips the kill step but still clears the lock).

### queue file (state/agents/{agent}/{job}/queue)

Plain text file containing a single integer: the number of pending queued triggers for this job. Absent or empty means zero. Written atomically. Decremented by one on each dequeue or cancel.
