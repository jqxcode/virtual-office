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

## Check 13: Upcoming Required Training Compliance by Due Date (DAX API)

**Goal**: Flag team members with incomplete required trainings due within the next 15 days. Uses DAX API for precise course-level data (no CDP needed).

**Data source**: Power BI DAX API
- Token: `az account get-access-token --resource https://analysis.windows.net/powerbi/api --query accessToken -o tsv`
- Endpoint: `POST https://api.powerbi.com/v1.0/myorg/datasets/2f72a313-a17d-4ba5-b241-c4a27586d9e8/executeQueries`
- Tables: `'Required Training'` (fact), `'Employee'` (dim), `'Courses'` (dim), `'Completion Status'` (dim)

**DAX Query**:
```dax
EVALUATE
VAR _cutoffKey = YEAR(TODAY() + 15) * 10000 + MONTH(TODAY() + 15) * 100 + DAY(TODAY() + 15)
RETURN
SELECTCOLUMNS(
    FILTER(
        ADDCOLUMNS(
            'Required Training',
            "EmployeeName", RELATED('Employee'[Employee Name]),
            "CourseTitle", RELATED('Courses'[Course Title]),
            "CourseLink", RELATED('Courses'[VivaDeepLink]),
            "Status", RELATED('Completion Status'[Course Completion Status]),
            "ReportsTo", RELATED('Employee'[Reports To Alias]),
            "DueDateKey", 'Required Training'[CompleteByDateKey]
        ),
        [ReportsTo] = "qitxu" && [Status] <> "Completed" && [DueDateKey] <= _cutoffKey
    ),
    "Name", [EmployeeName],
    "Course", [CourseTitle],
    "Link", [CourseLink],
    "DueDate", [DueDateKey],
    "Status", [Status]
)
```

**Steps**:
1. Get PBI token via `az account get-access-token`.
2. Run the DAX query above.
3. Parse `DueDateKey` (YYYYMMDD integer) into readable date (e.g. 20260531 → 2026-05-31).
4. Group results by person. For each person, list their incomplete courses with title, link, due date.
5. If 0 rows returned, all training is complete — skip this section.

**check13 JSON format**:
```json
{
  "items": [
    {
      "name": "Brent Weatherall",
      "missing": [
        {"title": "Security Foundations: Safeguarding Data", "url": "https://vivalearning.microsoft.com/...", "dueDate": "2026-05-31"}
      ]
    }
  ],
  "count": 6
}
```

**If DAX token fails**: Skip this check. Output "Check 13 skipped: DAX token unavailable" and continue.

## Check 14: CiFX Test Health (DAX API + ADO + CDP)

**Goal**: Monitor CiFX end-to-end test automation health for Meeting Join Fundamentals and Notes areas. Two data sources: DAX API for precise test metrics, ADO for flaky threshold bugs, and CDP screenshots for Coverage/Health dashboards (no DAX permission).

### Data Sources

**A. DAX REST API** (CI-Fx test results — precise numbers):
- Token: `az account get-access-token --resource https://analysis.windows.net/powerbi/api --query accessToken -o tsv`
- Endpoint: `POST https://api.powerbi.com/v1.0/myorg/groups/6f77e458-234c-4bd7-9a21-710c43dbb575/datasets/64f4d901-8372-485e-98e0-5a0820443d4b/executeQueries`
- Table: `TestResults` with columns: TESTNAME, RESULT, DateOnly, Ring, Experience_T, Cloud, SuiteName, TestPass, TestFail, TestError, Total, EXCEPTION, FrootLink

**B. ADO Work Item Search** (flaky threshold bugs):
- Search for tag `cifx-jailed-tests-above-threshold` under both area paths
- Check for non-Closed bugs

**C. CDP Screenshots** (Coverage + CI-Fx Health dashboards — no DAX Build permission):
- Coverage: `https://msit.powerbi.com/groups/20c32c44-8c53-4170-8f86-af6bf197dad1/reports/396a474e-3593-40ed-9ce5-0cfa132cbf8b/2e0fc615bdd2e0acb735?experience=power-bi`
- CI-Fx Health: `https://msit.powerbi.com/groups/6f77e458-234c-4bd7-9a21-710c43dbb575/reports/1c6ea5bc-2607-4330-9e80-a941ebf948b1/2b99a1918f6763784949?experience=power-bi`

### Area paths to monitor
- `MSTeams\Calling Meeting Devices (CMD)\Meetings\Meeting Join\Fundamentals`
- `MSTeams\Calling Meeting Devices (CMD)\Meetings\Notes`

### IMPORTANT: TESTNAME filtering

The TestResults table has **no AreaPath column**. Filter by TESTNAME patterns using `CONTAINSSTRING`:

**Include** (Meeting Join scenarios):
- `"Meeting join"`, `"Meeting rejoin"`, `"Bvt join"`, `"Anonymous Join"`, `"prejoin"`, `"Pre Join"`, `"Scheduled meeting join"`, `"peek meeting join"`, `"E2EE meeting join"`, `"Started Notification"`, `"Join Meeting"`, `"Join Launcher"`

**Exclude** (not Meeting Join Fundamentals/Notes area):
- `"Townhall"`, `"Broadcast"`, `"Webinar"`, `"MTMA Sign-in"`, `"Call History"`, `"Streaming Attendee"`, `"Doppler"`, `"SLA lock"`, `"cifx_testsets"`, `"Immersive"`, `"Production Studio"`, `"Breakout room"`

### Steps

**Part A — DAX Queries (last 7 days):**

1. Get PBI token via `az account get-access-token`.
2. Run DAX: **Overall Meeting Join pass rate** (summary of included TESTNAME patterns, excluding the Exclude list).
3. Run DAX: **Top 20 failing tests** — `GROUPBY` on TESTNAME, sort by Fail descending.
4. Run DAX: **Daily trend** — `GROUPBY` on DateOnly.
5. Run DAX: **By Ring** — `GROUPBY` on Ring.
6. Run DAX: **Completely broken tests** (0% pass rate, >= 10 runs).
7. Run DAX: **Top exceptions** — `GROUPBY` on EXCEPTION where RESULT = "Failed".

DAX pattern for filtered queries:
```dax
EVALUATE
VAR _filtered = FILTER(TestResults,
    TestResults[DateOnly] >= DATE(<year>, <month>, <day>) &&
    (CONTAINSSTRING(TestResults[TESTNAME], "Meeting join") || ... ) &&
    NOT(CONTAINSSTRING(TestResults[TESTNAME], "Townhall")) && ...
)
RETURN GROUPBY(_filtered, TestResults[TESTNAME],
    "Runs", SUMX(CURRENTGROUP(), TestResults[Total]),
    "Pass", SUMX(CURRENTGROUP(), TestResults[TestPass]),
    "Fail", SUMX(CURRENTGROUP(), TestResults[TestFail])
)
```

**Part B — ADO Flaky Bug Check:**

8. Search ADO for non-Closed bugs with tag `cifx-jailed-tests-above-threshold` under:
   - `MSTeams\Calling Meeting Devices (CMD)\Meetings\Meeting Join\Fundamentals`
   - `MSTeams\Calling Meeting Devices (CMD)\Meetings\Notes`
9. If any open bugs found, include Bug ID, Title, AssignedTo, jailed %, and state in report.

**Part C — CDP Screenshots (Coverage + Health):**

10. Open Coverage dashboard and CI-Fx Health dashboard via Edge CDP (background tab, 1920x1080 viewport).
11. Wait 15 seconds. Take screenshot. Close tab.
12. Use Claude Vision to extract: Coverage overall %, CI-Fx pass rate gauges, jail rate trends.
13. Save screenshots to `output/scrum-master/cifx-screenshots/`.
14. **Do NOT attempt to interact with Power BI slicers** — CDP keyDown/insertText does not trigger Power BI internal filtering. Screenshot default view only.

### Health Thresholds

| Metric | Healthy | Degraded | Critical |
|--------|---------|----------|----------|
| Meeting Join Pass Rate (DAX) | >= 85% | 75%-84% | < 75% |
| Broken Tests (0% pass) | 0 | 1-3 | > 3 |
| Open Flaky Threshold Bugs | 0 | 1 | > 1 |
| Overall CI-Fx Pass Rate (CDP) | >= 85% | 80%-84% | < 80% |
| CI-Fx Jail Rate (CDP) | < 5% | 5%-10% | > 10% |

### Output

15. Collect: DAX metrics, ADO bug status, CDP screenshot analysis.
16. **Report-only** (no auto-fix). Include in Teams post and hygiene-teams-summary.json as `check14`.

**check14 JSON format**:
```json
{
  "dax": {
    "passRate": 78.0,
    "totalRuns": 380990,
    "passed": 297250,
    "failed": 56231,
    "brokenTests": ["test name 1", "test name 2"],
    "topFailures": [
      {"name": "2P: Meeting join from Started Notification (c2-c2)", "runs": 6953, "fail": 1996, "passRate": 64.4}
    ],
    "topExceptions": [
      {"exception": "Requesting APM accounts failed", "count": 10537}
    ],
    "dailyTrend": [
      {"date": "2026-05-12", "passRate": 69.3},
      {"date": "2026-05-13", "passRate": 78.4}
    ]
  },
  "ado": {
    "openFlakyBugs": [],
    "fundamentalsStatus": "healthy",
    "notesStatus": "healthy"
  },
  "cdp": {
    "coverageOverallPct": 93.01,
    "cifxPassRate": 85.85,
    "cifxJailRate": 13.76,
    "screenshots": ["output/scrum-master/cifx-screenshots/coverage.png", "output/scrum-master/cifx-screenshots/health.png"]
  },
  "overallStatus": "degraded",
  "count": 1
}
```

**Overall status**: worst of (DAX pass rate threshold, open flaky bugs, CDP metrics).

**If DAX token fails**: Fall back to CDP-only for all 3 dashboards. Output "DAX unavailable, using CDP screenshots only."
**If CDP fails**: Skip CDP portion. Output "CDP unavailable, DAX data only."

---

## Teams Summary Output

**CRITICAL**: Write `${REPO_PERSONAL}/virtual-office/output/scrum-master/hygiene-teams-summary.json` with the **exact** top-level structure below. The poster agent reads these exact keys. Do NOT use any other structure (no `meta`, `summary`, `checks` wrapper — flat top-level keys only).

```json
{
  "generated": "2026-05-19T07:35:00-07:00",
  "sprint": "Sprint 206 11-May to 24-May",
  "check2b": { "items": [...], "count": N },
  "check4":  { "items": [...], "count": N },
  "check5":  { "items": [...], "count": N },
  "check6":  { "items": [...], "count": N },
  "check7":  { "items": [...], "count": N },
  "check8":  { "items": [...], "count": N },
  "check9":  { "items": [...], "count": N },
  "check10": { "items": [...], "count": N },
  "check11": { "items": [...], "count": N },
  "check12": { "items": [...], "count": N },
  "check13": { "items": [...], "count": N },
  "check14": { "dashboards": [...], "overallStatus": "...", "count": N }
}
```

Each check key MUST exist even if empty (`{ "items": [], "count": 0 }`). The poster reads `check2b`, `check4`, ..., `check13`, `check14` directly — if these keys are missing or nested inside another object, the poster will see empty data and skip posting.

---

## HTML Report Output Rules

- **Template**: `${REPO_PERSONAL}/virtual-office/templates/scrum-master-shiproom-hygiene.html`
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
