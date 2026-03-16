# Virtual Office -- Test Suite

## Running Tests

Run a single test file:

```powershell
pwsh -File tests/Test-InvokeAgentJob.ps1
```

Run all tests:

```powershell
Get-ChildItem tests/Test-*.ps1 | ForEach-Object { pwsh -File $_ }
```

## Test Files

| File | Coverage |
|------|----------|
| Test-InvokeAgentJob.ps1 | Core runner: locking, counter, maxRuns, disabled jobs, invalid agents |
| Test-QueueDrain.ps1 | Queue increment, drain loop, maxRuns interaction |
| Test-AuditLog.ps1 | Audit entry creation, monthly partitioning, required fields |
| Test-ScheduleRegistration.ps1 | Schedule parsing, task name generation, invalid cron handling |
| Test-DashboardState.ps1 | Dashboard init, multi-agent isolation, status updates |
| Test-AtomicWrites.ps1 | Atomic file writes (.tmp rename), crash safety |

## Conventions

- Each test file is standalone (no shared test runner needed).
- Tests create an isolated temp directory and clean up after themselves.
- Helper function `Assert-True` tracks pass/fail counts per file.
- All PS1 files are ASCII-only (no em-dashes, arrows, or smart quotes).
