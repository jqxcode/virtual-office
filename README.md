# Virtual Office

Virtual Office is an agent orchestration framework that schedules, runs, and monitors Claude Code agents as recurring background jobs on Windows. It provides a live dashboard UI showing agent status (idle/busy), job queues, and audit trails.

## Quick Start

1. Register scheduled jobs with Windows Task Scheduler:

   ```powershell
   .\runner\Register-Schedules.ps1
   ```

2. Start the live dashboard at http://localhost:8400:

   ```powershell
   .\ui\server.ps1
   ```

## Dependencies

- PowerShell 7+
- Claude Code CLI (`claude`)
- Windows Task Scheduler

## Directory Layout

```
virtual-office/
├── config/          - Agent registry, schedules, job definitions
├── runner/          - Core orchestration engine (PS1 scripts)
├── ui/              - Live dashboard (HTML + JS + local server)
├── state/           - Runtime state (gitignored)
├── output/          - Agent outputs + audit logs (gitignored)
├── tests/           - Test suite + fixtures
└── docs/            - Architecture, guides, troubleshooting
```

## Version

See [VERSION](./VERSION) for current version. See [CHANGELOG.md](./CHANGELOG.md) for release history.
