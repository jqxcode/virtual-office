# Virtual Office - Troubleshooting

## Job Not Running

Check that the task exists and is enabled in Task Scheduler:

1. Open `taskschd.msc`
2. Navigate to the `VirtualOffice` folder
3. Verify the task is present and its status is "Ready"
4. Check the "History" tab for recent execution attempts and error codes

If the task exists but never fires, confirm the trigger schedule matches what you expect in `config/schedules.json`.

## Stale Lock File

If a job crashed or was killed mid-run, the lock file persists and blocks future runs. Symptoms: the job status shows "running" in the dashboard but no claude process is active.

**Automatic cleanup**: Stale locks are now auto-cleared after a configurable timeout (default 2 hours). When the runner detects a lock file older than the timeout, it removes the lock, logs a `stale_lock_cleared` event, and proceeds with the job as normal.

The timeout can be configured per-agent via `staleLockTimeoutMinutes` in `config/agents.json`:

```json
{
  "agents": {
    "my-agent": {
      "staleLockTimeoutMinutes": 60
    }
  }
}
```

If not specified, the default timeout of 120 minutes (2 hours) is used.

When a stale lock is cleared, a `stale_lock_cleared` event is written to both the events log and the audit log with the lock age and configured timeout.

To clear a lock manually, delete the lock file:

```
state/agents/{agent}/{job}/lock
```

## Queue Growing Unbounded

This happens when the job takes longer to complete than the schedule interval. Each trigger adds another entry to the queue, and the queue never drains fast enough.

Fixes:
- Increase the schedule interval in `config/schedules.json`
- Optimize the agent prompt to reduce execution time
- Reduce `maxRuns` in the job config to cap how many queued runs are drained per cycle

Check the current queue depth in `state/agents/{agent}/{job}/queue/` or in `state/dashboard.json`.

## Dashboard Not Updating

1. Verify `server.ps1` is running: check for a PowerShell process listening on port 8400
2. Open browser dev tools and check the Console tab for fetch errors
3. Confirm `state/dashboard.json` exists and is valid JSON
4. If the file is missing, trigger any job manually to regenerate it

If the UI loads but shows stale data, the issue is likely that no jobs have run recently. Check the `lastUpdated` timestamp in `state/dashboard.json`.

## Task Scheduler Permission Errors

`Register-Schedules.ps1` needs permission to create scheduled tasks. Run it as administrator:

```powershell
Start-Process pwsh -ArgumentList "runner/Register-Schedules.ps1" -Verb RunAs
```

If you see "Access Denied" errors even as admin, check that your Group Policy allows task creation.

## Claude CLI Not Found

The runner invokes `claude` directly. Ensure it is in your PATH:

```powershell
claude --version
```

If this fails, find the installed location and add it to your system PATH, or set the full path in `runner/constants.ps1`.

## Audit Log Missing Entries

The runner creates the audit directory on first run. If `output/audit/` does not exist, either:
- No job has ever completed successfully, or
- The output directory was deleted

Create it manually if needed:

```powershell
New-Item -ItemType Directory -Path output/audit -Force
```

Then trigger a job to confirm entries are written. Each run should produce one line in `output/audit/YYYY-MM.jsonl`.
