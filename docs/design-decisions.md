# Virtual Office - Design Decisions

## v0.4.0 - Task Queue Tab

### Cron expansion to concrete fire times
**Decision**: Expand each cron schedule into its next N concrete instances rather than showing one row per schedule.
**Why**: For daily schedules, users want to see which specific days are coming up. A flat chronological list is more actionable than abstract cron patterns.
**Trade-off**: Hourly schedules generate many rows, so we cap per-schedule at 10 and globally at 20 items.

### Client-side cron parsing
**Decision**: Parse cron expressions and compute next-fire times in JavaScript, not on the server.
**Why**: Avoids adding cron parsing to PowerShell. The 5-field cron expressions used are simple enough for a ~60-line JS parser. Recomputed on each poll cycle so always fresh.

### Force stop with 2-click confirmation
**Decision**: Force Stop requires two clicks (first shows "Click again to stop", auto-resets after 3s).
**Why**: Force-stopping kills the Claude process mid-work. It is destructive enough to warrant confirmation but not so dangerous as to need a full modal dialog.

### PID in lock file
**Decision**: Store the claude process PID in the lock file after process start.
**Why**: Enables reliable force-stop. The lock is initially written without PID (before process start), then updated with PID immediately after. Backward-compatible: old lock files without PID still parse fine.

### Queue cancel writes events
**Decision**: Queue cancellation writes both an event and an audit entry.
**Why**: Consistency with all other state mutations in the system. The `queue_cancelled` event shows up in the activity feed and event log, maintaining full auditability.
