# Virtual Office

Virtual Office is an agent orchestration framework that schedules, runs, and monitors Claude Code agents as recurring background jobs on Windows. It provides a live dashboard UI showing agent status (idle/busy), job queues, event logs, and audit trails.

## Agents

| Agent | Role | Key Jobs |
|-------|------|----------|
| **Scrum Master** | ADO autopilot, bug autopilot runs | ado-status-update, bug-autopilot-meeting-join |
| **Bug Killer** | Scans repos for issues, creates fix PRs | scan-and-fix, open-pr-maintenance, daily-summary |
| **Poster** | Posts daily summaries to Teams | Bug-Autopilot-Adoption-daily-summary |
| **pEmailer** | Gmail inbox management | scan-all-mailboxes |
| **Auditor** | Memory consolidation, sprint progress, run comparison | consolidate-agent-memories, TODO-sprint-progress, TODO-compare-runs |
| **Hang Scout** | Hung job detection and diagnostics | detect-hang, daily-report |

## Quick Start

1. Register scheduled tasks with Windows Task Scheduler:

   ```powershell
   .\runner\Register-Schedules.ps1
   ```

   This creates `VO-*` tasks that use `Run-Hidden.vbs` to run without foreground windows.

2. Start the live dashboard at http://localhost:8400:

   ```powershell
   .\ui\server.ps1
   ```

3. (Optional) Trigger a job manually:

   ```powershell
   .\runner\Invoke-AgentJob.ps1 -Agent mScrumMaster -Job ado-status-update
   ```

## Dependencies

- PowerShell 7+
- Claude Code CLI (`claude`)
- Windows Task Scheduler
- py-spy (for pHangScout stack capture)

## Directory Layout

```
virtual-office/
  config/          - Agent registry, schedules, job definitions
    agents.json    - Agent registry (6 agents)
    schedules.json - Cron schedules (16 entries)
    jobs/          - Per-agent job configs (6 files)
  runner/          - Core orchestration engine (PS1 scripts)
    Run-Hidden.vbs - VBScript wrapper to suppress console windows
  ui/              - Live dashboard (HTML + JS + local server)
  state/           - Runtime state (gitignored)
  output/          - Agent outputs + audit logs (gitignored)
  tests/           - Test suite + fixtures
  docs/            - Architecture, design decisions, guides
```

## Dashboard

The Mission Control dashboard at localhost:8400 provides:

- **OFFICE tab**: Live status cards for all 6 agents (idle/working/disabled), with context budget badges (green <70%, yellow 70-90%, red >90%)
- **COSTS tab**: Per-job token cost tracking, daily cost sparklines, per-agent breakdown, and anomaly detection (highlights jobs exceeding 2x average cost)
- **BOARD tab**: Kanban-style task board with Your Turn / Claude's Turn / Done columns for tracking wish and task progress
- **Event Log tab**: Filterable event history with per-agent dropdown
- **Task Queue tab**: Upcoming schedule, queue depths, force-stop/cancel actions
- **Stats tiles**: Jobs completed/failed, agents online, system heartbeat

For full details on the dashboard upgrade, see [docs/vo-dashboard-upgrade--progress--2026-05-18.html](docs/vo-dashboard-upgrade--progress--2026-05-18.html).

## Version

See [VERSION](./VERSION) for current version. See [CHANGELOG.md](./CHANGELOG.md) for release history.
