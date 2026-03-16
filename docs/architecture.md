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
