# Virtual Office - Claude Code Instructions

## Project Overview
Agent orchestration framework for scheduling and monitoring Claude Code agents as background jobs on Windows.

## Key Paths
- Config: config/ (agents.json, schedules.json, jobs/*.json)
- Runner: runner/ (PS1 scripts)
- UI: ui/ (HTML dashboard)
- State: state/ (runtime, gitignored)
- Output: output/ (reports + audit logs, gitignored)
- Tests: tests/

## Rules
- All PS1 files must be ASCII-only (no unicode characters)
- All state file writes must be atomic (write .tmp, then rename)
- Every mutation must write an audit entry
- SYSTEM_VERSION from runner/constants.ps1 must be stamped on every record
- Never modify state/ or output/ files in version control
- Run tests after any runner/ changes: Get-ChildItem tests/Test-*.ps1 | ForEach-Object { pwsh -File $_ }
