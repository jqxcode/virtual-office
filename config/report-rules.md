# VO Report Rules

All VO agent jobs MUST follow these rules when generating reports. Read this file at the start of every job run.

## 1. Fixed Template

You MUST use the fixed HTML template specified in your job prompt. Read the template file, then replace all {{PLACEHOLDER}} values with actual data. Do NOT redesign the layout, change colors, rearrange sections, or generate HTML from scratch.

## 2. VO Subtitle

Every HTML report MUST include a standard VO subtitle immediately below the main title. Replace {{VO_SUBTITLE}} with:
`Agent: <display name> | Job: <job name> | Start: <PST timestamp> | Complete: <PST timestamp>`

## 3. PST Timestamps

All timestamps in reports MUST be in Pacific Time (PST/PDT, America/Los_Angeles). Never use UTC.

## 4. Single Report

Generate exactly ONE report at the very end after ALL work is complete. Do NOT save intermediate or partial reports during the run.

## 5. No-Op Skip

If no meaningful work was done (no code changes, no fixes, no incidents, no new data), do NOT generate an HTML report. Just output a one-line summary and exit.

## 6. Clickable Links

All PR numbers, bug IDs, issue numbers, and work item IDs MUST be clickable hyperlinks to their respective pages (GitHub, ADO, etc.). Never show bare numbers without links.

## 7. ASCII Only

Use only ASCII characters in report content. No emojis, em dashes, arrows, or unicode. Use plain hyphens (-), -> for arrows, and ... for ellipsis.

## 8. No Teams Posting

NEVER post to Teams channels or send Teams messages unless the job prompt EXPLICITLY instructs you to post to a specific channel. Generating an HTML report is NOT the same as posting it. Only the poster agent has Teams posting authority. Violation of this rule is a critical failure.
