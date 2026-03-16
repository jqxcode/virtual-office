# Virtual Office -- Design Document

- **Version**: 0.1.0
- **Last updated**: 2026-03-15

## Overview

Virtual Office is an agent orchestration framework for Windows that turns Claude Code agents into recurring background jobs. It uses Windows Task Scheduler for timing, a file-based lock-and-queue system for concurrency, and a polling dashboard for visibility. Every mutation is recorded in an append-only, monthly-partitioned audit log stamped with the framework version.

## Design Decisions

| # | Decision | Rationale | Alternatives considered |
|---|----------|-----------|------------------------|
| D1 | Config separated: registry, schedules, jobs | Agent identity, timing, and job content change independently. Schedules can vary per machine without touching job definitions. | Single monolithic config -- rejected: too many merge conflicts |
| D2 | One Task Scheduler entry per job | Task Scheduler is purpose-built for cron; don't reinvent it. Each job gets independent retry/failure handling. | Single dispatcher polling all jobs -- rejected: single point of failure, harder to debug |
| D3 | Queue instead of skip | Every scheduled trigger is honored. Long-running jobs don't lose queued work. Queue drains sequentially after current job completes. | Skip on lock (v1) -- rejected: loses work during long runs |
| D4 | Audit log: append-only, monthly partitioned | Every mutation logged with timestamp, action, entity, run_id, SYSTEM_VERSION. Monthly files prevent unbounded growth. | Single log file -- rejected: grows forever |
| D5 | Atomic writes for all state files | Write to .tmp, then rename. Prevents corruption on crash. | Direct writes -- rejected: data loss on power failure |
| D6 | SYSTEM_VERSION stamped on every record | Trace which framework version produced any given state/audit entry. | No versioning -- rejected: can't debug version-specific bugs |
| D7 | State + output gitignored | Machine-specific runtime data. Different machines have different run histories. | Version everything -- rejected: noisy diffs, large repo |
| D8 | Generic runner, agent-agnostic | Invoke-AgentJob.ps1 -Agent X -Job Y works for any agent. Adding agents requires zero runner changes. | Per-agent scripts -- rejected: duplication, drift |
| D9 | dashboard.json as UI contract | Single file is the API between runner and UI. UI polls this file only. Simple, no server-side logic needed. | WebSocket/real-time -- rejected: overkill for local use |
| D10 | PS1 with ASCII only | PowerShell on Windows misreads non-BOM UTF-8. All scripts use ASCII characters only. | UTF-8 without BOM -- rejected: causes phantom parse errors |
| D11 | All jobs go through Task Scheduler, including one-offs | Every job must flow through Invoke-AgentJob.ps1 so it appears on the dashboard, writes audit/events, and tracks errors. One-off jobs use a single-fire Task Scheduler trigger instead of session-only cron. | Session cron -- rejected: bypasses dashboard, no state tracking, no error capture |

## Audit Log Schema

Each line in the audit log is a JSON object with these fields:

```json
{
  "ts": "2026-03-15T10:30:00Z",
  "action": "job_start | job_end | job_error | queue_add | queue_drain | lock_acquire | lock_release",
  "agent": "scrum-master",
  "job": "sprint-progress",
  "run_id": "uuid-v4",
  "system_version": "0.1.0",
  "detail": "optional free-text context"
}
```

Log files are stored at `output/audit/YYYY-MM.jsonl` (one file per month, append-only).

## State File Contracts

### dashboard.json

Written atomically by the runner after every state change. The UI polls this file.

```json
{
  "system_version": "0.1.0",
  "updated_at": "2026-03-15T10:30:00Z",
  "agents": {
    "scrum-master": {
      "status": "idle | busy | error",
      "current_job": null,
      "current_run_id": null,
      "last_run": {
        "job": "sprint-progress",
        "run_id": "uuid-v4",
        "started_at": "2026-03-15T10:25:00Z",
        "ended_at": "2026-03-15T10:27:30Z",
        "result": "success | error",
        "detail": ""
      },
      "queue": []
    }
  }
}
```

### counter.json

Tracks cumulative run counts per agent per job. Written atomically.

```json
{
  "system_version": "0.1.0",
  "updated_at": "2026-03-15T10:30:00Z",
  "counts": {
    "scrum-master": {
      "sprint-progress": {
        "total": 42,
        "success": 40,
        "error": 2
      }
    }
  }
}
```

### events.jsonl

Append-only event stream in `state/events.jsonl`. Each line is a JSON object:

```json
{
  "ts": "2026-03-15T10:30:00Z",
  "event": "job_started | job_completed | job_failed | agent_queued",
  "agent": "scrum-master",
  "job": "sprint-progress",
  "run_id": "uuid-v4",
  "system_version": "0.1.0"
}
```
