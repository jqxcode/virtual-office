# VO Report Rules

All VO agent jobs MUST follow these rules when generating reports. Read this file at the start of every job run.

## 0. Design System (HIGHEST PRIORITY)

All HTML reports MUST follow `${SRC_ROOT}/DESIGN.md` (Stripe-inspired design system). Use `--stripe-*` CSS custom properties exclusively. NEVER hardcode hex colors. NEVER use the old `--vo-*` dark theme variables. If a template still uses `--vo-*` tokens, you MUST convert them to `--stripe-*` equivalents from DESIGN.md before generating the report.

## 1. Fixed Template

You MUST use the fixed HTML template specified in your job prompt. Read the template file, then replace all {{PLACEHOLDER}} values with actual data. Do NOT redesign the layout, change colors, rearrange sections, or generate HTML from scratch. If the template violates Rule 0 (uses `--vo-*` instead of `--stripe-*`), fix the CSS tokens in your output while preserving the layout structure.

## 2. VO Subtitle

Every HTML report MUST include a standard VO subtitle immediately below the main title. Replace {{VO_SUBTITLE}} with:
`Agent: <display name> | Job: <job name> | Start: <PST timestamp> | Complete: <PST timestamp>`

## 3. PST Timestamps

All timestamps in reports MUST be in Pacific Time (PST/PDT, America/Los_Angeles). Never use UTC.

## 4. Single Report

Generate exactly ONE report at the very end after ALL work is complete. Do NOT save intermediate or partial reports during the run.

## 5. No-Op Skip

If no meaningful work was done (no code changes, no fixes, no incidents, no new data), do NOT generate an HTML report. Just output a one-line summary and exit.

## 6. Clickable Links (Verified)

All PR numbers, bug IDs, issue numbers, and work item IDs MUST be clickable hyperlinks to their respective pages (GitHub, ADO, etc.). Never show bare numbers without links. All URLs MUST be validated as reachable before embedding -- do not generate speculative or pattern-guessed URLs.

## 7. ASCII Only

Use only ASCII characters in report content. No emojis, em dashes, arrows, or unicode. Use plain hyphens (-), -> for arrows, and ... for ellipsis.

## 8. No Teams Posting

NEVER post to Teams channels or send Teams messages unless the job prompt EXPLICITLY instructs you to post to a specific channel. Generating an HTML report is NOT the same as posting it. Only the poster agent has Teams posting authority. Violation of this rule is a critical failure.

## 9. Teams Activity Audit Trail

Before ANY Teams Graph API call (POST message, create channel, DELETE message), you MUST append a JSONL entry to the monthly audit log at `${REPO_PERSONAL}/virtual-office/output/audit/YYYY-MM.jsonl` with this format:

```json
{"action":"teams_post","agent":"<agent>","job":"<job>","run_id":"<run_id>","timestamp":"<ISO8601-PST>","details":{"channel_id":"<channel_id>","channel_name":"<name>","message_subject":"<subject>","mentions":["<name1>","<name2>"],"http_status":<code>}}
```

For channel creation use `"action":"teams_channel_create"`. For message deletion use `"action":"teams_message_delete"`. Log AFTER the API call completes so `http_status` reflects the actual result. If the API call fails, still log it with the error status code.

## 10. Open in Edge (No Focus Steal)

After saving any HTML report, open it with ONE command:
```
python ${LOCAL_SKILLS}/open-report.py <filepath>
```

This script handles everything: close stale versions of the same report (e.g. old `hygiene-20260518-151229.html` when opening `hygiene-20260518-162000.html`), dedup exact URL tabs, %20-encode spaces, open in Edge, move to "Reports" tab group. Do NOT call open-in-edge.py or get-tabs.py separately for reports. Do NOT use `Start-Process msedge`. A PreToolUse hook will block these incorrect patterns.

NEVER steal browser focus -- do not use foreground activation, BringToFront, or similar. The user may be actively using the browser.

This behavior is controlled by the `openReportsInEdge` flag in `${REPO_PERSONAL}/virtual-office/config/report-settings.json`. If the flag is `false` or the file does not exist, skip opening.

## 11. Write HTML with Python

Use Python `open()/write()` to generate HTML files. NEVER use bash heredoc -- encoding and formatting are unreliable.

## 12. No Foreground Screenshots

NEVER take foreground screenshots for verification. Use headless CDP (port 9223) if visual validation is needed.

## 13. Verify Output

After generating a report, read back the file and confirm the content matches intent. Do not trust that the prompt produced correct output -- verify the actual artifact.

## 14. Bilingual Preferred

User prefers bilingual (Chinese + English) reports where applicable. Use plain language -- no framework jargon, first-principles expression.

## 15. No Fabrication

If the data pipeline does not exist to produce a report, say so honestly. NEVER scrape live data and assemble it into a polished report pretending to be historical. Build the pipeline first.

## 16. Reports Are Source of Truth

Generated report files are the source of truth for pending actions, not memory summaries. When checking what was reported, read the actual HTML files.

## 17. Path Encoding

All file paths passed to Edge, open-in-edge.py, or any browser tool MUST have spaces escaped as `%20` in `file:///` URLs. This applies to subagents too -- when a subagent saves a file and returns the path, the caller MUST encode it before opening. Unescaped spaces are the #1 cause of garbage tabs.
