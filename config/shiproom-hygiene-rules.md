# Shiproom Hygiene Check — Rules & Check Definitions

## Scope

- **Areas** (run every check against BOTH):
  - `MSTeams\Calling Meeting Devices (CMD)\Meetings\Meeting Join\Fundamentals`
  - `MSTeams\Calling Meeting Devices (CMD)\Meetings\Notes`
- **Team**: CMD - Meeting Join (US) (ID: `6f72ea4e-c73a-4a15-b622-46cdacc53987`)
- **Current semester prefix**: Compute dynamically based on today's date:
  - If today <= June 30 of this year → `MSTeams\{year}\H1`
  - If today > June 30 → `MSTeams\{year}\H2`
  - Example: 2026-05-11 → `MSTeams\2026\H1`; 2026-07-01 → `MSTeams\2026\H2`
  - Use `<current_semester>` as placeholder in all WIQL queries below — resolve it at runtime

## ADO API Patterns

- **Token**: `az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv`
- **@mention HTML**: `<a href="#" data-vss-mention="version:2.0,{identity_id}">@{name}</a>`
- **Identity lookup**: `https://domoreexp.vssps.visualstudio.com/_apis/identities?searchFilter=General&filterValue={email}`
- **Comments API**: `_apis/wit/workItems/{id}/comments?api-version=7.1-preview.4`
- **WIQL link queries** (`FROM workitemLinks`) are efficient for relationship analysis
- **Batch GET** (`?ids=...`) does NOT support `$expand=relations` — use individual fetches

---

## Check 1: Task-to-Task Parent Links

**Goal**: Tasks should be parented under User Stories or Features, never under other Tasks.

1. WIQL link query per area:
   ```
   SELECT [System.Id], [System.Title], [System.WorkItemType]
   FROM workitemLinks
   WHERE ([Source].[System.WorkItemType] = 'Task'
     AND [Source].[System.AreaPath] UNDER '<area-path>')
     AND ([System.Links.LinkType] = 'System.LinkTypes.Hierarchy-Reverse')
     AND ([Target].[System.WorkItemType] = 'Task')
   MODE (MustContain)
   ```
2. For each child→parent Task pair:
   a. GET child with `$expand=relations`, find parent relation index
   b. PATCH remove parent link (`op: remove, path: /relations/{idx}`)
   c. PATCH add Related link to former parent
   d. Comment @mentioning owner: "The parent link on this task was changed to a Related link. Tasks should not be parented under another Task; use a User Story or Feature as the parent instead."

## Check 2: Close Resolved Work Items

**Goal**: Resolved items should be Closed, not left hanging.

1. WIQL per area: `WHERE [System.State] = 'Resolved' AND [System.AreaPath] UNDER '<area>'`
2. PATCH state to Closed, add comment: "Item should be closed instead of left Resolved. If there are any questions, reach out to Josh Xu (qitxu@microsoft.com)."

## Check 2b: Blocked Features

**Goal**: Features in Blocked state need attention. Proposed/RollingOut are valid backlog/deployment states — only Blocked is flagged.

1. WIQL per area:
   ```
   WHERE [System.WorkItemType] = 'Feature'
     AND [System.State] = 'Blocked'
     AND [System.AreaPath] UNDER '<area>'
   ```
2. Comment @mentioning owner: "This Feature is in Blocked state. Please update with a reason or unblock if the blocker is resolved."

## Check 3: Move Non-Closed Items from Previous Sprint

**Goal**: All items in the completed sprint should be Closed. Leftovers move to current sprint.

**Grace period (5 days)**: During the first 5 days of a new sprint, do NOT auto-move items. Instead, comment @mention the owner to remind them to close out or move their work. After the grace period, auto-move.

1. Get current iteration (timeframe=current) and previous iteration (the one immediately before by finishDate).
2. Calculate days since previous sprint ended (use the current sprint's startDate). If <= 5 days, set `grace_period = true`.
3. WIQL: `WHERE [System.State] <> 'Closed' AND [System.State] <> 'Removed' AND [System.IterationPath] = '<previous>'`
4. If `grace_period` is true: **comment @mention owner** — do NOT PATCH iteration. Add comment: "This item is still in Sprint {prev}. Please close it or move to Sprint {current} within {days_remaining} days, or it will be auto-moved." Include "(grace period — X days remaining)" in the summary.
5. If `grace_period` is false: PATCH iteration to current sprint, add comment explaining the move.

## Check 4: Current Sprint Tasks — Estimates and Parent

**Goal**: Every active Task in current sprint needs Original Estimate, Remaining Work, and a parent.

1. WIQL: `WHERE [System.WorkItemType] = 'Task' AND [System.State] <> 'Closed' AND [System.State] <> 'Removed' AND [System.IterationPath] = '<current>'`
2. Fetch each with `$expand=all`.
3. If missing OriginalEstimate or RemainingWork: comment @owner with which fields are missing.
4. If no `System.LinkTypes.Hierarchy-Reverse` relation: comment @owner about missing parent.

## Check 5: Non-Closed Bugs Must Be in Current Sprint

**Goal**: Active bugs should not sit in old or default iterations.

1. WIQL: `WHERE [System.WorkItemType] = 'Bug' AND [System.State] <> 'Closed' AND [System.State] <> 'Removed' AND [System.IterationPath] <> '<current>'`
2. PATCH iteration to current sprint, add comment.

## Check 6: Stale Tasks from Past Sprints

**Goal**: Non-closed tasks with an assignee stuck in **past** sprints (sprints that have already ended) need owner review.

**Critical scope rule**: Only flag tasks whose sprint has already ended (finishDate < today). Tasks in the current sprint or ANY future sprint are intentionally scheduled there — do NOT touch them.

**Important exclusions**:
- **Backlog items**: Only target tasks in actual sprint iterations (path must contain "Sprint" and be `UNDER <current_semester>`). Items at root/backlog iteration paths are not stale — they're just backlog.
- **Future sprints**: Tasks in sprints that haven't ended yet are NOT stale. The owner scheduled them there intentionally.

**Grace period (5 days)**: Same as Check 3. During the first 5 days of the current sprint, do NOT auto-move tasks from the previous sprint. Instead, comment @mention the owner. After grace period, auto-move to current sprint.

1. Get all iterations under `<current_semester>` with their start/finish dates. Identify current sprint and previous sprint.
2. Calculate days since current sprint started. If <= 5 days, set `grace_period = true`.
3. WIQL:
   ```
   WHERE [System.WorkItemType] = 'Task'
     AND [System.State] <> 'Closed'
     AND [System.State] <> 'Removed'
     AND [System.IterationPath] UNDER '<current_semester>'
     AND [System.AssignedTo] <> ''
   ```
4. For each result:
   a. Skip if iteration path doesn't contain "Sprint" (backlog).
   b. **Skip if the task's sprint finishDate >= today** — it's in a current or future sprint, not stale.
   c. Only tasks in sprints that have already ended proceed to step 5/6.
5. If in previous sprint and `grace_period` is true: **comment @mention owner** — do NOT PATCH. Add comment: "This task is still in Sprint {prev}. Please close or move within {days_remaining} days, or it will be auto-moved."
6. If `grace_period` is false or item is from an older sprint (not just previous): PATCH to current sprint, comment @owner asking to review.

## Check 7: Proposed Bugs > 24 Hours

**Goal**: Bugs must not stay in Proposed state for more than 24 hours. Must be triaged to Active or Closed.

1. WIQL per area:
   ```
   WHERE [System.WorkItemType] = 'Bug'
     AND [System.State] = 'Proposed'
     AND [System.ChangedDate] < @today - 1
     AND [System.AreaPath] UNDER '<area>'
   ORDER BY [System.ChangedDate] ASC
   ```
2. Collect: ID, Title, Owner, ChangedDate, CreatedDate, AreaPath.
3. **Report-only** (no auto-fix). Results written to `hygiene-teams-summary.json` for poster agent to post to Teams.

## Check 8: Committed Features Outside Current Semester

**Goal**: Features in Committed state must belong to the current semester (H1 2026).

1. WIQL per area:
   ```
   WHERE [System.WorkItemType] = 'Feature'
     AND [System.State] = 'Committed'
     AND NOT [System.IterationPath] UNDER '<current_semester>'
     AND [System.AreaPath] UNDER '<area>'
   ```
2. Collect: ID, Title, Owner, IterationPath, AreaPath.
3. **Report-only** (no auto-fix). Results written to same `hygiene-teams-summary.json`.

## Check 9: Stale Bugs > 90 Days

**Goal**: Bugs open > 90 days are likely stale transfers. Flag for review — close and reopen as new bug with fresh context.

1. WIQL per area:
   ```
   WHERE [System.WorkItemType] = 'Bug'
     AND [System.State] <> 'Closed'
     AND [System.State] <> 'Removed'
     AND [System.CreatedDate] < @today - 90
     AND [System.AreaPath] UNDER '<area>'
   ORDER BY [System.CreatedDate] ASC
   ```
2. Collect: ID, Title, State, Owner, CreatedDate, ChangedDate, Severity, AreaPath.
3. **Report-only** (no auto-fix).

## Check 10: Ring Target Date Issues

**Goal**: Active Features with Ring 0 or Ring 4 target dates in the past need attention — rollout dates should be current.

1. WIQL per area:
   ```
   WHERE [System.WorkItemType] = 'Feature'
     AND [System.State] = 'Active'
     AND [System.IterationPath] UNDER '<current_semester>'
     AND ([Microsoft.VSTS.Scheduling.TargetDate] < @today
       OR [MicrosoftTeamsCMMI.Ring4TargetDate] < @today)
     AND [System.AreaPath] UNDER '<area>'
   ```
2. Collect: ID, Title, Owner, TargetDate (=Ring0), Ring4TargetDate, AreaPath.
3. Flag which dates are past due (R0/TargetDate, Ring4, or both).

**Field mapping**: Ring 0 = `Microsoft.VSTS.Scheduling.TargetDate` (the standard "Target Date" field). Ring 4 = `MicrosoftTeamsCMMI.Ring4TargetDate`.
4. **Report-only** (no auto-fix). Results included in Teams post.

## Check 11: Missing Sign-Offs

**Goal**: Active Features missing required governance sign-offs (Security, Accessibility, Privacy, Compliance).

**ADO field reference names**:
- Security: `MicrosoftTeamsCMMI.SecurityReview`
- Accessibility: `MicrosoftTeamsCMMI-Copy.AccessibilityUsability`
- Privacy: `Custom.1CSUserStoryStatus`
- Compliance: `Custom.ERP_Compliance_Signoff`

A sign-off is "missing" if the field is empty/null. Features that have all four filled are fine.

1. Query active Features **in the current semester** (`[System.IterationPath] UNDER '<current_semester>'`) in both areas, fetch all 4 sign-off fields.
2. For each Feature, check which sign-off fields are empty.
3. Only flag Features missing at least one sign-off.
4. Collect: ID, Title, Owner, list of missing sign-offs.
5. **Report-only** (no auto-fix). Results included in Teams post.

## Check 12: Invalid Ring Date Ordering (R4 <= R0)

**Goal**: Ring 4 target date must be after Ring 0 target date. If R4 <= R0 (or R4 is set but R0 is empty), the rollout plan is invalid.

1. Query Features **in the current semester** (any state except Closed/Removed) in both areas where R4 exists:
   ```
   WHERE [System.WorkItemType] = 'Feature'
     AND [System.State] <> 'Closed'
     AND [System.State] <> 'Removed'
     AND [System.IterationPath] UNDER '<current_semester>'
     AND [MicrosoftTeamsCMMI.Ring4TargetDate] <> ''
     AND [System.AreaPath] UNDER '<area>'
   ```
2. For each Feature, check:
   a. If R4 is set but R0 is empty → flag "R0 missing"
   b. If both set and R4 <= R0 → flag "R4 before R0"
3. Collect: ID, Title, Owner, Ring0Date, Ring4Date, Issue.
4. **Report-only** (no auto-fix). Results included in Teams post.

## Check 13: Required Training Compliance (Power BI)

**Goal**: All team members must complete required trainings before their due dates. Flag anyone below 100% completion when looking 15 days ahead.

**Data source**: Power BI dashboard (NOT ADO). Requires Edge CDP to extract data.
- URL: `https://msit.powerbi.com/groups/me/reports/c2390d89-5de8-474a-aa2d-fb29b2998d65/ReportSection607c7fe0d8afd1ba9d6f?experience=power-bi`
- Tab: "Myself and My Directs"

**Steps**:
1. Open the Power BI URL via Edge CDP (`Target.createTarget` with `background:True`). Set viewport to 1920x1080.
2. Wait 12 seconds for page load and auth.
3. The "Complete by Date" end-date field defaults to today. Change it to **today + 15 days** (format: M/D/YYYY). Use triple-click to select the field, then type the new date + Enter.
4. Wait 3 seconds for the report to refresh.
5. **Summary view**: Take a screenshot of the Summary tab. Extract: Employee Name, Required Course #, Completed #, Completion %. Flag anyone < 100%.
6. **Detail view**: For each person below 100%, click the expand arrow (⊞) next to their name OR click the "Detail" tab to see individual courses. Extract each incomplete course:
   - Course Title
   - Completion Status (should be "Not Started" or "In Progress")
   - Url (the course link from the "Url" column — this is clickable in the Power BI table)
7. Close the CDP tab after extraction.
8. Collect per person: Name, Completion %, list of incomplete courses with title + URL.
9. **Report-only** (no auto-fix). Include in Teams post and hygiene-teams-summary.json as `check13`.

**check13 JSON format**:
```json
{
  "items": [
    {
      "name": "Josh Xu",
      "completionPct": 71,
      "required": 7,
      "completed": 5,
      "missing": [
        {"title": "Course Name Here", "url": "https://..."},
        {"title": "Another Course", "url": "https://..."}
      ]
    }
  ],
  "count": 9
}
```

**If CDP fails** (Edge not running, auth expired, page doesn't load): Skip this check gracefully. Output "Check 13 skipped: CDP unavailable" and continue with other checks.

## Check 14: CiFX Dashboard Review (Power BI)

**Goal**: Review 3 CiFX (CI-Fx end-to-end test automation) Power BI dashboards for Meeting Join area health. Flag regressions, low coverage areas, and failing tests.

**Data source**: Power BI dashboards (NOT ADO). Requires Edge CDP to extract data via screenshots + Claude Vision analysis.

### Dashboards

1. **Coverage Management System** (Coverage Overview + Test Insights)
   - URL: `https://msit.powerbi.com/groups/20c32c44-8c53-4170-8f86-af6bf197dad1/reports/396a474e-3593-40ed-9ce5-0cfa132cbf8b/2e0fc615bdd2e0acb735?experience=power-bi`
   - What to look for: Test coverage % by scenario/area path, gaps in coverage for Meeting Join scenarios, newly uncovered areas

2. **CI-Fx Health Dashboard** (Overview)
   - URL: `https://msit.powerbi.com/groups/6f77e458-234c-4bd7-9a21-710c43dbb575/reports/1c6ea5bc-2607-4330-9e80-a941ebf948b1/2b99a1918f6763784949?experience=power-bi`
   - What to look for: Overall CI-Fx pipeline health, failure trends, infrastructure issues affecting test runs

3. **CI-Fx Automation** (Test Results Visualization)
   - URL: `https://msit.powerbi.com/groups/6f77e458-234c-4bd7-9a21-710c43dbb575/reports/d3ff0862-0dfb-4846-86d7-9a6305872233/d7db79f44effd71e6996?experience=power-bi`
   - What to look for: Individual test pass/fail rates, flaky tests, regressions in Meeting Join area paths

### Area paths to focus on
- `MSTeams\Calling Meeting Devices (CMD)\Meetings\Meeting Join\Fundamentals`
- `MSTeams\Calling Meeting Devices (CMD)\Meetings\Notes`
- When Mobile scenario rows appear in these dashboards, include those area paths too

### Steps

1. Open each dashboard URL via Edge CDP (`Target.createTarget` with `background:True`). Set viewport to 1920x1080.
2. Wait 12 seconds for page load and auth.
3. Take a full-page screenshot of each dashboard's default view.
4. If the dashboard has filters for area path or scenario, apply filters for Meeting Join and Meeting Notes areas. Take another screenshot after filtering.
5. Use Claude Vision to analyze each screenshot and extract:
   - **Coverage dashboard**: Coverage %, uncovered scenarios, trend direction (improving/declining)
   - **Health dashboard**: Pipeline pass rate, failure count, top failure reasons, trend
   - **Automation dashboard**: Test pass rate, failing test names, flaky test count, regressions vs previous period
6. Close all CDP tabs after extraction.

### Health Thresholds

| Metric | Healthy | Degraded | Critical |
|--------|---------|----------|----------|
| Test Coverage % | >= 80% | 60%-79% | < 60% |
| Pipeline Pass Rate | >= 95% | 85%-94% | < 85% |
| Test Pass Rate | >= 90% | 80%-89% | < 80% |
| Flaky Test Count | 0-2 | 3-5 | > 5 |

### Output

7. Collect per dashboard: name, health status (healthy/degraded/critical), key metrics, list of issues found.
8. Save screenshots to `output/scrum-master/cifx-screenshots/` (overwrite each run).
9. **Report-only** (no auto-fix). Include in Teams post and hygiene-teams-summary.json as `check14`.

**check14 JSON format**:
```json
{
  "dashboards": [
    {
      "name": "Coverage Management System",
      "status": "degraded",
      "metrics": {"coveragePct": 72, "uncoveredScenarios": 5},
      "issues": ["Meeting Join Browser coverage dropped from 85% to 72%", "No Mobile scenario coverage yet"],
      "screenshotPath": "output/scrum-master/cifx-screenshots/coverage.png"
    },
    {
      "name": "CI-Fx Health Dashboard",
      "status": "healthy",
      "metrics": {"pipelinePassRate": 97, "failureCount": 2},
      "issues": [],
      "screenshotPath": "output/scrum-master/cifx-screenshots/health.png"
    },
    {
      "name": "CI-Fx Automation",
      "status": "critical",
      "metrics": {"testPassRate": 78, "flakyTests": 8, "regressions": 3},
      "issues": ["8 flaky tests in Meeting Join area", "3 new regressions since last week"],
      "screenshotPath": "output/scrum-master/cifx-screenshots/automation.png"
    }
  ],
  "overallStatus": "critical",
  "count": 3
}
```

**Overall status**: worst status across the 3 dashboards (critical > degraded > healthy).

**If CDP fails** (Edge not running, auth expired, page doesn't load): Skip this check gracefully. Output "Check 14 skipped: CDP unavailable" and continue with other checks.

---

## Teams Summary Output

After all checks, write `Q:/src/personal_projects/virtual-office/output/scrum-master/hygiene-teams-summary.json` containing check2b, check4, check5, check6, check7, check8, check9, check10, check11, check12, check13, and check14 results. The poster agent's `hygiene-teams-post` job picks this up. Only sections with items are posted; empty sections are omitted entirely.

---

## HTML Report Output Rules

- **Template**: `Q:/src/personal_projects/virtual-office/templates/scrum-master-shiproom-hygiene.html`
- Read the template, replace `{{PLACEHOLDER}}` values. Do NOT redesign layout/colors/sections.

### Placeholder rules:

| Placeholder | Value |
|---|---|
| `{{VO_SUBTITLE}}` | `Agent: Scrum Master \| Job: shiproom-hygiene-check \| Start: <PST> \| Complete: <PST>` |
| `{{DATE}}` | Today's date (YYYY-MM-DD) |
| `{{CURRENT_SPRINT}}` / `{{PREVIOUS_SPRINT}}` | Actual sprint names |
| `{{TOTAL_CHECKS}}` | Number of checks run (10 including 2b) |
| `{{CHECKS_PASSED}}` | Checks with 0 issues |
| `{{CHECKS_WITH_ISSUES}}` | Checks that found issues |
| `{{TOTAL_ACTIONS}}` | Sum of all items fixed/moved/flagged |

### Section visibility:

For each check (1, 2, 2b, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14):
- If 0 issues: replace `{{CHECKn_SECTION}}` with **empty string**
- If issues found: replace with the full HTML block from the template comments, filling in table rows

If ALL checks passed: replace `{{ALL_CLEAR_SECTION}}` with `<div class="section all-clear">All checks passed - no hygiene issues found.</div>`. Otherwise empty string.

### Links:

- Work item IDs link to: `https://domoreexp.visualstudio.com/MSTeams/_workitems/edit/{id}`
- Query links: `<a class="query-link" href="...wiql={URL-encoded}">Open all N items in ADO query</a>`
- WIQL for query links: `SELECT [System.Id],[System.Title],[System.State],[System.AssignedTo],[System.WorkItemType] FROM workitems WHERE [System.Id] IN (id1,id2,...) ORDER BY [System.Id]`
- For >100 items, use date+area filter instead of ID list

### Output files:

1. Timestamped: `output/scrum-master/shiproom-hygiene-YYYYMMDD-HHmmss.html`
2. Latest: `output/scrum-master/shiproom-hygiene-latest.html`

Do NOT open in Edge — this job runs as a background agent. Save to disk only.
