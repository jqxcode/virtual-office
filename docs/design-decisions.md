# Virtual Office - Design Decisions

## Run-Hidden.vbs for Task Scheduler

**Decision**: All Task Scheduler tasks invoke commands through `wscript Run-Hidden.vbs "pwsh -NoProfile -File ..."` instead of running PowerShell directly.

**Why**: Windows Task Scheduler normally opens a visible console window for each task execution. The S4U (Service for User) logon type can suppress windows but requires administrator privileges, which are not available in our DevBox environment. The VBScript wrapper uses `WScript.Shell.Run` with window style 0 (hidden), which suppresses the window without requiring elevation. This is a 4-line script that reliably prevents foreground window stealing during background agent runs.

**Trade-off**: Adds an extra process layer (wscript.exe -> pwsh.exe -> claude). The overhead is negligible. VBScript is a legacy technology but ships with every Windows installation and requires no dependencies.

## Task Scheduler VO- Prefix

**Decision**: All scheduled tasks are prefixed with `VO-` (e.g., `VO-scrum-master-ado-status-update`).

**Why**: The original prefix `VirtualOffice-` was too verbose. `VO-` is short, unique enough to avoid collisions with other scheduled tasks, and makes `Get-ScheduledTask -TaskName "VO-*"` queries fast and unambiguous. All existing tasks were renamed in a single migration.

## Job Merges: open-pr-maintenance

**Decision**: Merged `resolve-merge-conflicts` and `review-pr-comments` into a single `open-pr-maintenance` job.

**Why**: Both jobs operated on the same set of open PRs and ran hourly. Having two separate jobs meant iterating the PR list twice, with potential lock contention when both happened to schedule close together. The merged job iterates each PR once and handles both merge conflicts and unaddressed review comments in a single pass. This halves the number of scheduled triggers and eliminates redundant `gh pr list` calls.

**Trade-off**: The combined prompt is longer. If one concern fails (e.g., conflict resolution), the other (comment replies) may also be skipped for that run. In practice this has not been an issue since failures are typically at the repo/PR level, not the concern level.

## Job Renames

**Decision**: Several jobs were renamed for clarity:
- `bug-autopilot` -> `bug-autopilot-meeting-join` (clarifies which area)
- `consolidate` -> `consolidate-agent-memories` (clarifies what is consolidated)
- `detect` -> `detect-hang` (verb-noun consistency)

**Why**: As the job count grew, short generic names became ambiguous. `detect` could mean anything; `detect-hang` is self-documenting. `bug-autopilot` was ambiguous once `bug-autopilot-notes` was added for Meeting Notes. `consolidate` did not indicate the scope (memories vs. reports vs. data).

## Agent Rename: memo-checker -> checker -> auditor

**Decision**: Renamed `memo-checker` to `checker` with displayName "Checker".

**Why**: The agent's scope expanded beyond memory/memo checking to include sprint progress reporting, cross-run comparison, report template auditing, and logical conflict detection in memory dedup. The name "memo-checker" was misleadingly narrow. "Checker" reflects the agent's role as a general-purpose validation and reporting agent.

## Hang Detection: Per-Agent Thresholds

**Decision**: Hang detection thresholds are configurable per-agent in the `detect-hang` job's `hangDetection` config block, with separate hang and kill thresholds.

**Why**: Different agents have fundamentally different expected runtimes. Bug-killer routinely runs 90+ minutes for complex fixes across multiple repos. Poster should finish in under 15 minutes. A single global threshold would either miss slow hangs on fast agents or produce false positives on slow agents.

The two-tier threshold (hang vs. kill) provides graduated response:
- At hangThresholdMinutes: log the incident, capture diagnostics (py-spy stack traces)
- At killThresholdMinutes: terminate the process, clear lock, file GitHub issue

**Configuration**:
```
scrum-master:  hang=60min   kill=120min
bug-killer:    hang=90min   kill=180min
emailer:       hang=30min   kill=60min
auditor:       hang=20min   kill=30min
poster:        hang=15min   kill=30min
hang-scout:    excluded (cannot detect its own hangs)
```

**Trade-off**: Per-agent config adds complexity. Could have used a multiplier on each agent's `staleLockTimeoutMinutes` instead. Explicit thresholds were chosen because the relationship between "stale lock" (a runner concern) and "hung process" (a diagnostic concern) is not always linear.

## Hang Detection: py-spy Stack Capture

**Decision**: When a hung process is detected, hang-scout captures Python stack traces using py-spy for any Python processes in the tree.

**Why**: Many Claude CLI operations spawn Python subprocesses (pip, ADO scripts, bug-autopilot). The most common hang root cause is a Python process blocked on I/O or stuck in a loop. py-spy can attach to a running Python process without interrupting it and produce a stack trace, which is invaluable for root cause analysis.

## Hang Detection: Known Patterns DB and GitHub Issue Filing

**Decision**: Hang-scout maintains a known patterns database and files GitHub issues for new/unknown hang patterns.

**Why**: Recurring hangs from the same root cause should not generate duplicate noise. The patterns DB allows hang-scout to classify incidents and only escalate genuinely new failure modes. GitHub issues provide a persistent, searchable record that integrates with existing bug tracking workflows.

## Bug-Killer: All Issue Types

**Decision**: The scan-and-fix job scans for all issue types (bugs, feature requests, enhancements) rather than bugs only.

**Why**: The original "bug-killer" name implied bugs only, but many repos had actionable enhancements and feature requests that the agent could implement. Limiting to bugs left useful work on the table. The agent's name remains "bug-killer" for continuity, but its scope now covers all open issues.

## Bug-Killer: New Repo Discovery

**Decision**: The scan-and-fix job discovers new repos by running `find /q/src -maxdepth 4 -name ".git"` and comparing against known targets.

**Why**: As new projects are cloned, the agent should be aware of them without manual config updates. Discovery runs at the start of each scan, checks for uncommitted changes (skips dirty repos), and reports new repos in a dedicated section so the user can decide whether to add them to the target list.

## Bug-Killer: Daily Summary with Edge Tab Group

**Decision**: The daily-summary job at 1:30am aggregates all activity and opens in Edge with `--group-name=Daily`.

**Why**: Individual scan-and-fix and open-pr-maintenance reports accumulate throughout the day. The daily summary is the single report to review, linking to all individual reports. The Edge "Daily" tab group keeps it visually separated from ad-hoc browsing.

## VO Subtitle Standard

**Decision**: All HTML reports include a standard subtitle with Agent, Job, Start, and Complete timestamps.

**Why**: With multiple agents generating reports on overlapping schedules, provenance tracking is essential. The subtitle answers "which agent produced this, for which job, and when" at a glance. The checker's consolidate-agent-memories job includes a report template audit that verifies all agent files and job configs enforce this standard.

## Checker: Report Template Audit

**Decision**: The consolidate-agent-memories job scans all agent .md files and job configs to verify HTML reports have VO subtitle, dark theme, Segoe UI, and are self-contained.

**Why**: Report styling drift was a recurring issue -- agents would generate reports with inconsistent themes or missing subtitles. Automated auditing during the nightly consolidation catches deviations early.

## Checker: Logical Conflict Detection in Memory Dedup

**Decision**: Memory deduplication now detects logical conflicts (contradictory information across memory files) rather than just textual duplicates.

**Why**: Simple textual dedup missed cases where two memory files contained opposing guidance (e.g., "always use X" vs. "never use X"). Logical conflict detection surfaces these for human review rather than silently keeping one and discarding the other.

## UI: Removed Recent Activity Sidebar

**Decision**: The two-column layout (agent cards + recent activity sidebar) was replaced with a full-width agent card view. Activity viewing moved to the dedicated Event Log tab.

**Why**: The sidebar duplicated information available in the Event Log tab but with less filtering capability. Removing it gives agent cards more horizontal space and reduces visual clutter. The Event Log tab provides superior filtering (by agent, event type, time range).

## UI: Dynamic Event Log Agent Filter

**Decision**: The agent dropdown in the Event Log tab is dynamically populated from actual events rather than from the agent config.

**Why**: Shows only agents that have generated events, which is more useful than showing all registered agents (some of which may have never run).

## UI: Click-to-Copy in Task Queue

**Decision**: Agent/job identifiers in the Task Queue tab are clickable and copy to clipboard.

**Why**: Users frequently need to paste agent/job names into CLI commands (e.g., manual job triggers). Click-to-copy eliminates transcription errors.

## UI: Generic View Events on Agent Cards

**Decision**: Agent cards show a "View Events" link that navigates to the Event Log tab pre-filtered to that agent, replacing any agent-specific action buttons.

**Why**: Consistency across all agent cards regardless of type. Every agent benefits from quick access to its event history.

---

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
