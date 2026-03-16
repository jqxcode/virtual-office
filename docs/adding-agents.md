# Adding a New Agent to Virtual Office

Adding a new agent to Virtual Office is a three-step process: define the agent, configure its jobs, and register the schedules.

## Step 1: Create the Agent Definition

Create a Markdown file at `~/.claude/agents/{name}.md` with YAML frontmatter. This is the standard Claude Code agent format.

```markdown
---
name: code-reviewer
description: Reviews pull requests and provides feedback
tools:
  - Read
  - Grep
  - Glob
  - Bash
---

You are a code reviewer agent. When given a PR number, review the changes
and produce a structured report with findings.
```

## Step 2: Add to Config

Three config files need to be updated.

### config/agents.json - Register the agent

Add an entry for the new agent with its display metadata:

```json
{
  "code-reviewer": {
    "icon": "magnifying-glass",
    "description": "Reviews pull requests and provides structured feedback"
  }
}
```

### config/jobs/{name}.json - Define jobs

Create a job definition file for the agent. Each job specifies the prompt, run limits, and whether it is enabled:

```json
{
  "pr-review": {
    "prompt": "Check for open PRs assigned to me in the MSTeams project. For each unreviewed PR, produce a review report with: summary, risk assessment, and line-level comments. Save to output/reports/pr-review/.",
    "maxRuns": 2,
    "enabled": true
  }
}
```

### config/schedules.json - Add cron schedule

Add a schedule entry that maps the agent/job to a cron expression:

```json
{
  "code-reviewer/pr-review": {
    "cron": "0 9,15 * * 1-5",
    "description": "Review PRs twice daily on weekdays (9am and 3pm)"
  }
}
```

## Step 3: Register Schedules

Run the registration script to create the Windows Task Scheduler entries:

```powershell
pwsh runner/Register-Schedules.ps1
```

This reads `config/schedules.json` and creates (or updates) a scheduled task for each entry. Tasks are created under the `VirtualOffice` folder in Task Scheduler.

## Complete Example: code-reviewer Agent

Here is the full walkthrough for adding a "code-reviewer" agent with a "pr-review" job that runs twice daily on weekdays.

### 1. Agent definition

File: `~/.claude/agents/code-reviewer.md`

```markdown
---
name: code-reviewer
description: Reviews pull requests and provides feedback
tools:
  - Read
  - Grep
  - Glob
  - Bash
---

You are a code review agent for the MSTeams project. When invoked:

1. Query Azure DevOps for open PRs assigned to the current user
2. For each PR not yet reviewed, analyze the diff
3. Produce a report covering: change summary, risk level, and specific feedback
4. Save the report to the designated output directory
```

### 2. Config files

File: `config/agents.json` (add the new key):

```json
{
  "code-reviewer": {
    "icon": "magnifying-glass",
    "description": "Reviews pull requests and provides structured feedback"
  }
}
```

File: `config/jobs/code-reviewer.json`:

```json
{
  "pr-review": {
    "prompt": "Check for open PRs assigned to me in the MSTeams project. For each unreviewed PR, produce a review report. Save to output/reports/pr-review/.",
    "maxRuns": 2,
    "enabled": true
  }
}
```

File: `config/schedules.json` (add the new key):

```json
{
  "code-reviewer/pr-review": {
    "cron": "0 9,15 * * 1-5",
    "description": "Review PRs twice daily on weekdays (9am and 3pm)"
  }
}
```

### 3. Register

```powershell
pwsh runner/Register-Schedules.ps1
```

Verify in Task Scheduler (`taskschd.msc`) that the task `VirtualOffice\code-reviewer\pr-review` exists and shows the correct triggers.
