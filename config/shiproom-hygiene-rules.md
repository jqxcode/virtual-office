# Shiproom Hygiene Check — Rules & Check Definitions

## Scope

- **Areas** (run every check against BOTH):
  - `MSTeams\Calling Meeting Devices (CMD)\Meetings\Meeting Join\Fundamentals`
  - `MSTeams\Calling Meeting Devices (CMD)\Meetings\Notes`
- **Team**: CMD - Meeting Join (US) (ID: `6f72ea4e-c73a-4a15-b622-46cdacc53987`)
- **Current semester prefix**: `MSTeams\2026\H1`

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

1. Get current iteration (timeframe=current) and previous iteration (the one immediately before by finishDate).
2. WIQL: `WHERE [System.State] <> 'Closed' AND [System.State] <> 'Removed' AND [System.IterationPath] = '<previous>'`
3. PATCH iteration to current sprint, add comment explaining the move.

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

**Goal**: Non-closed tasks with an assignee stuck in **actual past sprints** need owner review. Move to FUTURE sprint (not current) to give review time. **Do NOT touch backlog items** — only tasks whose iteration path is under the semester prefix (assigned to a real sprint).

1. Get future iteration (first with timeFrame='future').
2. WIQL: `WHERE [System.WorkItemType] = 'Task' AND [System.State] <> 'Closed' AND [System.State] <> 'Removed' AND [System.IterationPath] UNDER '<semester-prefix>' AND [System.IterationPath] <> '<semester-prefix>' AND [System.IterationPath] <> '<current>' AND [System.IterationPath] <> '<future>' AND [System.AssignedTo] <> ''`
3. PATCH iteration to future sprint, comment @owner asking to review.

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
     AND NOT [System.IterationPath] UNDER 'MSTeams\2026\H1'
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

---

## Teams Summary Output

After all checks, write `Q:/src/personal_projects/virtual-office/output/scrum-master/hygiene-teams-summary.json` containing check2b, check4, check5, check6, check7, check8, and check9 results. The poster agent's `hygiene-teams-post` job picks this up. Only sections with items are posted; empty sections are omitted entirely.

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

For each check (1, 2, 2b, 3, 4, 5, 6, 7, 8, 9):
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

Open latest in Edge via `open-in-edge.py` dedup script.
