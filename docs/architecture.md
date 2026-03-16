# Virtual Office - Architecture

## Overview

Virtual Office is a Windows-based agent orchestration framework. It schedules Claude Code agents as background jobs via Windows Task Scheduler, manages job queuing and concurrency, and provides a live web dashboard for monitoring.

## Component Diagram

```
+------------------+     +------------------+     +------------------+
|  Task Scheduler  | --> |  Invoke-Agent    | --> |  Claude CLI      |
|  (Windows)       |     |  Job.ps1         |     |  --agent <name>  |
+------------------+     +--------+---------+     +------------------+
                                  |
                    +-------------+-------------+
                    |             |              |
              +-----v----+  +----v-----+  +-----v----+
              |  state/   |  | output/  |  | output/  |
              | dashboard |  | reports  |  | audit/   |
              | events    |  |          |  | logs     |
              +-----------+  +----------+  +----------+
                    |
              +-----v-----------+
              |  server.ps1     |
              |  (HTTP :8400)   |
              +-----+-----------+
                    |
              +-----v-----------+
              |  Browser UI     |
              |  (polls /api/)  |
              +-----------------+
```

## Data Flow

1. Task Scheduler fires at cron interval
2. Invoke-AgentJob.ps1 checks lock -> queue or run
3. If running: creates lock, invokes claude CLI, captures output
4. Writes: output file, audit entry, event, dashboard state
5. Drains queue if entries exist
6. UI polls dashboard.json every 2s, renders agent cards

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
{"ts": "ISO-8601", "agent": "str", "job": "str", "event": "started|completed|queued|dequeued|error|skipped", "runId": "str", "details": {}, "systemVersion": "str"}
```

### audit log (output/audit/YYYY-MM.jsonl)

```json
{"ts": "ISO-8601", "action": "str", "agent": "str", "job": "str", "runId": "str", "systemVersion": "str", "details": {}}
```

### counter.json

```json
{"count": 0, "lastRun": "ISO-8601|null", "lastRunId": "str|null"}
```

## Concurrency Model

- One lock file per agent/job combination
- Lock = exclusive run; other triggers queue
- Queue is FIFO, drained by the running instance after completion
- maxRuns is checked before each run (including queued drains)

### Error Tracking

Errors are recorded in `state/errors.jsonl` (one JSON object per line).

**Schema:**

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

### Latest Reports

Each job run records its output path in `dashboard.json` under the job's `lastOutput` and `lastOutputTime` fields.

- The dashboard UI renders "View report" links on each job card, pointing to the most recent output file.
- The card footer displays the report timestamp for quick reference.
- Reports are served to the browser via the `/api/output/*` endpoint, which maps to the `output/` directory on disk.
