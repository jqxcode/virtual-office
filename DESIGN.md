# Virtual Office -- Design Document

- **Version**: 0.2.0
- **Last updated**: 2026-04-10

---

## Visual Design System (VDS)

> Based on [Linear](https://linear.app) via [awesome-design-md](https://github.com/VoltAgent/awesome-design-md), adapted with VO emerald accent.
> **All HTML output (portal + agent reports) MUST follow this spec.** No exceptions.
> **Theme version**: `vo-theme-0.2.0` -- stamp this in every generated HTML as `<!-- vo-theme-0.2.0 -->`.

### Theme Summary

Dark-mode-native. Near-black canvas where content emerges from darkness. Extreme precision: every element in a calibrated hierarchy of luminance. Semi-transparent white borders and surfaces create depth without visual noise. The only chromatic color is VO emerald green -- used sparingly for CTAs, active states, and status indicators. Inter font with OpenType features `"cv01", "ss03"`.

**Why Linear?** Evaluated Vercel (too stark, no status color system), Supabase (similar palette but less sophisticated typography/elevation), Sentry (accent mismatch), VoltAgent (untested design language). Linear is the gold standard for dark data-dense dashboards and has the most complete DESIGN.md spec (typography hierarchy, elevation system, component patterns). Adapted to keep VO's existing emerald green accent and V2 portal surface hierarchy.

**Key adaptations from pure Linear:**
1. Backgrounds use V2 portal hierarchy (`#0d1117` base) instead of Linear's `#08090a` (too dark for monitors)
2. Font weights use 500/600 (Google Fonts practical) instead of Linear's 510/590 (requires self-hosted Inter Variable)
3. Semi-transparent borders are primary, with `--vo-border-solid` as fallback for non-dark contexts

### Color Palette

#### Background Surfaces (aligned with V2 portal, not pure Linear)
| Token | Value | Origin | Use |
|-------|-------|--------|-----|
| `--vo-bg-deep` | `#0d1117` | V2 portal (kept) | Page background, deepest canvas |
| `--vo-bg-panel` | `#010409` | V2 portal header | Header, sticky nav, panel backgrounds |
| `--vo-bg-surface` | `#161b22` | V2 portal cards | Cards, dropdowns, elevated surfaces |
| `--vo-bg-hover` | `#1c2128` | V2 portal hover | Hover states, slightly elevated components |
| `--vo-bg-recessed` | `#0a0c10` | New (between deep/panel) | Inset areas, table row alternation |

#### Text
| Token | Value | Use |
|-------|-------|-----|
| `--vo-text-primary` | `#e6edf3` | Headings, primary content (V2 portal default) |
| `--vo-text-secondary` | `#d0d6e0` | Body text, descriptions (Linear upgrade -- brighter) |
| `--vo-text-tertiary` | `#8b949e` | Placeholders, metadata, muted content |
| `--vo-text-quaternary` | `#484f58` | Timestamps, disabled states |

#### Brand Accent (VO Emerald -- replaces Linear's indigo)
| Token | Value | Use |
|-------|-------|-----|
| `--vo-accent` | `#22c55e` | Primary CTAs, active states, brand elements |
| `--vo-accent-secondary` | `#10b981` | Secondary accent, success pills |
| `--vo-accent-hover` | `#16a34a` | Hover on accent elements |
| `--vo-accent-glow` | `rgba(34,197,94,0.15)` | Subtle glow behind active elements |

#### Status Colors
| Token | Value | Use |
|-------|-------|-----|
| `--vo-status-success` | `#22c55e` | Running, healthy, complete |
| `--vo-status-error` | `#ef4444` | Failed, error, critical |
| `--vo-status-warning` | `#f59e0b` | Warning, attention needed |
| `--vo-status-info` | `#3b82f6` | Informational, in-progress |
| `--vo-status-idle` | `#8b949e` | Idle, inactive, disabled |

#### Borders (Linear-style semi-transparent + solid fallback)
| Token | Value | Use |
|-------|-------|-----|
| `--vo-border-subtle` | `rgba(255,255,255,0.05)` | Default, barely visible (table row dividers) |
| `--vo-border-standard` | `rgba(255,255,255,0.08)` | Cards, inputs, code blocks |
| `--vo-border-solid` | `#30363d` | Fallback for non-dark contexts, prominent separations |
| `--vo-border-solid-light` | `#21262d` | Subtle solid alternative |

### Typography

- **Primary**: `'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif`
- **Monospace**: `'Cascadia Code', ui-monospace, 'SF Mono', Menlo, monospace`
- **OpenType**: `font-feature-settings: "cv01", "ss03"` on ALL text (requires Inter; gracefully degrades on fallback fonts)
- **Weights**: 400 (reading), 500 (emphasis/UI -- Google Fonts practical equivalent of Linear's 510), 600 (strong -- practical equivalent of 590). Never use 700.

| Role | Size | Weight | Letter Spacing | Use |
|------|------|--------|----------------|-----|
| Display | 48px | 500 | -1.056px | Page titles, hero text |
| H1 | 32px | 500 | -0.704px | Section titles |
| H2 | 24px | 500 | -0.288px | Sub-section headings |
| H3 | 20px | 600 | -0.24px | Card headers, feature titles |
| Body Large | 18px | 400 | -0.165px | Intro text, descriptions |
| Body | 16px | 400 | normal | Standard reading text |
| Body Medium | 16px | 500 | normal | Navigation, labels |
| Small | 15px | 400 | -0.165px | Secondary body text |
| Caption | 13px | 500 | -0.13px | Metadata, timestamps |
| Label | 12px | 500 | normal | Button text, small labels |
| Mono Body | 14px (Mono) | 400 | normal | Code blocks, log output |

### Component Patterns

**Buttons**: Ghost default (`rgba(255,255,255,0.02)` bg, `1px solid var(--vo-border-solid)`, 6px radius). Primary CTA: `var(--vo-accent)` bg, `#ffffff` text.

**Cards**: `var(--vo-bg-surface)` bg, `1px solid var(--vo-border-standard)`, 8px radius. Active cards get `3px solid var(--vo-accent)` left border.

**Tables**: Header `var(--vo-bg-panel)` bg, 13px uppercase weight-500 tertiary text, 0.5px letter-spacing. Rows alternate `var(--vo-bg-deep)`/`var(--vo-bg-recessed)`. Hover: `var(--vo-bg-hover)`.

**Status badges**: 9999px radius, 12px weight-500, 2px 10px padding. Status color at 15% opacity bg, full status color text. E.g. `background: rgba(34,197,94,0.15); color: #22c55e;`

**Links**: `var(--vo-accent)` color, no underline. Hover: `var(--vo-accent-hover)` + underline.

**Code**: Monospace font, 13px, `var(--vo-bg-surface)` bg, 2px 6px padding, 4px radius.

### Elevation

Luminance-based, not shadow-based. Deeper = darker bg, elevated = slightly lighter bg.
- Level 0 (Page): `var(--vo-bg-deep)` `#0d1117`
- Level 1 (Panel): `var(--vo-bg-panel)` `#010409`
- Level 2 (Surface): `var(--vo-bg-surface)` `#161b22`
- Level 3 (Hover): `var(--vo-bg-hover)` `#1c2128`
- Overlay: `rgba(0,0,0,0.7)` backdrop for modals

Semi-transparent white borders (`rgba(255,255,255,0.08)`) are the primary depth indicator, not shadows. Exception: modals/tooltips may use `box-shadow: 0 8px 24px rgba(0,0,0,0.5)` for floating effect.

### Do's and Don'ts

**Do**:
- Use `font-feature-settings: "cv01","ss03"` on all text
- Use weight 500 as default emphasis (never 700)
- Use semi-transparent white borders as primary depth cue
- Use `var(--vo-text-primary)` for headings, never pure `#ffffff`
- Use luminance stacking for elevation
- Use status colors at 15% opacity for badge backgrounds
- Stamp `<!-- vo-theme-0.2.0 -->` in every generated HTML
- Use CSS variable tokens, never hardcode hex values in templates

**Don't**:
- Pure `#ffffff` as text color
- Solid colored button backgrounds on dark surfaces (use transparency)
- Decorative use of emerald (it's for interactive/status only)
- Weight 700 (bold) anywhere
- Warm colors in UI chrome
- Drop shadows as primary depth on dark surfaces
- Skip OpenType features (cv01, ss03)
- Different design systems across portal vs reports
- `#00d4ff` cyan or `#58a6ff` blue as accents (legacy -- replace with `--vo-accent`)

### HTML Report Boilerplate

All agent HTML reports MUST inline this CSS preamble. Include `<!-- vo-theme-0.2.0 -->` after `<head>` tag.

```css
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600&display=swap');
:root {
  --vo-bg-deep: #0d1117; --vo-bg-panel: #010409; --vo-bg-surface: #161b22;
  --vo-bg-hover: #1c2128; --vo-bg-recessed: #0a0c10;
  --vo-text-primary: #e6edf3; --vo-text-secondary: #d0d6e0;
  --vo-text-tertiary: #8b949e; --vo-text-quaternary: #484f58;
  --vo-accent: #22c55e; --vo-accent-secondary: #10b981; --vo-accent-hover: #16a34a;
  --vo-border-subtle: rgba(255,255,255,0.05); --vo-border-standard: rgba(255,255,255,0.08);
  --vo-border-solid: #30363d; --vo-border-solid-light: #21262d;
  --vo-status-success: #22c55e; --vo-status-error: #ef4444;
  --vo-status-warning: #f59e0b; --vo-status-info: #3b82f6;
}
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
  font-feature-settings: "cv01", "ss03";
  background: var(--vo-bg-deep); color: var(--vo-text-secondary); line-height: 1.5;
  max-width: 1000px; margin: 0 auto; padding: 24px;
}
h1 { color: var(--vo-text-primary); font-size: 32px; font-weight: 500; letter-spacing: -0.704px; margin-bottom: 8px; }
h2 { color: var(--vo-text-primary); font-size: 24px; font-weight: 500; letter-spacing: -0.288px; margin: 24px 0 12px; }
h3 { color: var(--vo-text-primary); font-size: 20px; font-weight: 600; letter-spacing: -0.24px; margin: 16px 0 8px; }
.subtitle { color: var(--vo-text-tertiary); font-size: 15px; font-weight: 400; margin-bottom: 24px; }
table { width: 100%; border-collapse: collapse; margin: 16px 0; }
th { background: var(--vo-bg-panel); color: var(--vo-text-tertiary); font-size: 13px; font-weight: 500; text-transform: uppercase; letter-spacing: 0.5px; padding: 10px 14px; text-align: left; border-bottom: 1px solid var(--vo-border-standard); }
td { padding: 10px 14px; font-size: 14px; border-bottom: 1px solid var(--vo-border-subtle); color: var(--vo-text-secondary); }
tr:hover td { background: var(--vo-bg-hover); }
.card { background: var(--vo-bg-surface); border: 1px solid var(--vo-border-standard); border-radius: 8px; padding: 16px; margin: 8px 0; }
.badge { display: inline-block; padding: 2px 10px; border-radius: 9999px; font-size: 12px; font-weight: 500; }
.badge-success { background: rgba(34,197,94,0.15); color: var(--vo-status-success); }
.badge-error { background: rgba(239,68,68,0.15); color: var(--vo-status-error); }
.badge-warning { background: rgba(245,158,11,0.15); color: var(--vo-status-warning); }
.badge-info { background: rgba(59,130,246,0.15); color: var(--vo-status-info); }
.badge-idle { background: rgba(139,148,158,0.15); color: var(--vo-text-tertiary); }
a { color: var(--vo-accent); text-decoration: none; }
a:hover { color: var(--vo-accent-hover); text-decoration: underline; }
code { font-family: 'Cascadia Code', ui-monospace, monospace; font-size: 13px; background: var(--vo-bg-surface); padding: 2px 6px; border-radius: 4px; }
.footer { margin-top: 32px; padding-top: 16px; border-top: 1px solid var(--vo-border-subtle); color: var(--vo-text-quaternary); font-size: 12px; }
```

### Theme Lifecycle (Create / Update / Remove)

**Create** (new report or template):
1. Copy the CSS preamble above into the `<style>` tag
2. Add `<!-- vo-theme-0.2.0 -->` after `<head>`
3. Use ONLY `var(--vo-*)` tokens for all colors, never hardcode hex
4. Follow the typography hierarchy (sizes, weights, letter-spacing)
5. Use `.badge-*`, `.card`, `.footer` classes as-is

**Update** (theme version bump):
1. Bump the version string in this doc AND in the `:root` comment
2. Update the CSS preamble block here (single source of truth)
3. Find all affected files: `grep -r "vo-theme-" templates/ ui/` to locate all stamped HTML
4. Replace the CSS preamble and version stamp in each file
5. Visually verify in Edge that the update renders correctly

**Remove** (deprecate a template):
1. Delete the template file from `templates/`
2. Remove the job config that references it from `config/jobs/*.json`
3. Grep for the template name in agent definitions (`~/.claude/agents/`) and remove references
4. Old HTML reports in `output/` are kept as historical artifacts (gitignored)

**Validate** (lint compliance):
- All generated HTML should contain `vo-theme-` version stamp
- No hardcoded hex colors outside `:root` (except in the preamble itself)
- No `font-weight: 700` or `font-weight: bold`
- No `#00d4ff`, `#58a6ff`, `#1a1a2e`, `#16213e` (legacy colors -- must be replaced)
- All status badges use the 15% opacity pattern

### Scope

**Applies to:**
- VO Mission Control portal (`ui/`)
- ALL HTML reports generated by any VO agent (auditor, scrum-master, poster, bug-killer, hang-scout, emailer, dreamer)
- Any future HTML output from VO ecosystem
- Local skill HTML templates (`local_skills/`)

**Does NOT apply to:**
- Teams channel messages (ASCII only per feedback constraint)
- ADO wiki pages (use wiki markdown formatting)
- Plain text output, JSON, CSV
- Teams-embedded HTML fragments (poster ICM summaries) -- these use Teams' own styling

### Migration Status (13 templates identified)

| Template | Status | Notes |
|----------|--------|-------|
| scrum-master-sprint-progress | DONE (0.2.0) | Was Old Blue (`#00d4ff`) |
| bug-killer-scan | DONE (0.2.0) | Was Old Blue (`#00d4ff`) |
| emailer-scan | DONE (0.2.0) | Was GitHub Blue (`#58a6ff`) |
| hang-scout-daily-report | DONE (0.2.0) | Was GitHub Blue (`#58a6ff`) |
| bug-killer-pr-maintenance | DONE (0.2.0) | Was Mixed (Material + Old Blue) |
| auditor-ytd-oof-summary | DONE (0.2.0) | Was GitHub Blue (`#58a6ff`) |
| scrum-master-shiproom-hygiene | DONE (0.2.0) | Was GitHub Blue (`#58a6ff`) |
| auditor-memory-consolidation | DONE (0.2.0) | Was light mode (white bg) |
| auditor-resolve-bugs-cleanup | DONE (0.2.0) | Was GitHub Blue (`#58a6ff`) |
| bug-killer-daily-summary | DONE (0.2.0) | Was Old Blue (`#00d4ff`) |
| Portal ui/styles.css | DONE (0.2.0) | Added --vo-* vars, Inter font, weight 500/600 |
| poster-ba-perf-analysis | SKIP | Teams context (Teams own styling) |
| poster-icm-daily-summary | SKIP | Teams-embedded HTML fragment |

---

## Overview

Virtual Office is an agent orchestration framework for Windows that turns Claude Code agents into recurring background jobs. It uses Windows Task Scheduler for timing, a file-based lock-and-queue system for concurrency, and a polling dashboard for visibility. Every mutation is recorded in an append-only, monthly-partitioned audit log stamped with the framework version.

## Design Decisions

| # | Decision | Rationale | Alternatives considered |
|---|----------|-----------|------------------------|
| D1 | Config separated: registry, schedules, jobs | Agent identity, timing, and job content change independently. Schedules can vary per machine without touching job definitions. | Single monolithic config -- rejected: too many merge conflicts |
| D2 | One Task Scheduler entry per job | Task Scheduler is purpose-built for cron; don't reinvent it. Each job gets independent retry/failure handling. | Single dispatcher polling all jobs -- rejected: single point of failure, harder to debug |
| D3 | Queue instead of skip | Every scheduled trigger is honored. Long-running jobs don't lose queued work. Queue drains sequentially after current job completes. | Skip on lock (v1) -- rejected: loses work during long runs |
| D4 | Audit log: append-only, monthly partitioned | Every mutation logged with timestamp, action, entity, run_id, SYSTEM_VERSION. Monthly files prevent unbounded growth. | Single log file -- rejected: grows forever |
| D5 | Atomic writes for all state files | Write to .tmp, then rename. Prevents corruption on crash. | Direct writes -- rejected: data loss on power failure |
| D6 | SYSTEM_VERSION stamped on every record | Trace which framework version produced any given state/audit entry. | No versioning -- rejected: can't debug version-specific bugs |
| D7 | State + output gitignored | Machine-specific runtime data. Different machines have different run histories. | Version everything -- rejected: noisy diffs, large repo |
| D8 | Generic runner, agent-agnostic | Invoke-AgentJob.ps1 -Agent X -Job Y works for any agent. Adding agents requires zero runner changes. | Per-agent scripts -- rejected: duplication, drift |
| D9 | dashboard.json as UI contract | Single file is the API between runner and UI. UI polls this file only. Simple, no server-side logic needed. | WebSocket/real-time -- rejected: overkill for local use |
| D10 | PS1 with ASCII only | PowerShell on Windows misreads non-BOM UTF-8. All scripts use ASCII characters only. | UTF-8 without BOM -- rejected: causes phantom parse errors |
| D11 | All jobs go through Task Scheduler, including one-offs | Every job must flow through Invoke-AgentJob.ps1 so it appears on the dashboard, writes audit/events, and tracks errors. One-off jobs use a single-fire Task Scheduler trigger instead of session-only cron. | Session cron -- rejected: bypasses dashboard, no state tracking, no error capture |
| D12 | V2 tabs coexist with V1 for A/B comparison | Side-by-side comparison lets user evaluate UX improvement before retiring V1. V1 removal is a separate, future decision. | Immediate V1 replacement -- rejected: no fallback if V2 has issues |
| D13 | 4 V2 tabs map to 4 fundamental questions | TEAM (who are we), OFFICE (what's now), HISTORY (what happened), SCHEDULE (what's next). Each tab has exactly one purpose -- no mixing. | Single omnibus V2 tab -- rejected: same problem as V1 overloaded tabs |
| D14 | TEAM tab shows agent identity + skills + schedules | Consolidates data from agents.json, jobs/*.json, and schedules.json into a single "team directory" view. Skills (job names) are click-to-copy. | Separate identity/skills pages -- rejected: forces navigation for basic lookup |
| D15 | OFFICE tab is spatial, not a list | Grid of "desks" with live status, not a vertical list. Working agents pulse with elapsed timer. Gives ambient awareness like walking into an office. | Vertical status list -- rejected: no spatial metaphor, less glanceable |
| D16 | HISTORY tab computes job health from events | Success rate per job derived from started/completed/failed event pairs matched by run_id. No new state files needed -- events.jsonl is the source of truth. | Separate health tracking file -- rejected: duplicates event data |
| D17 | Agent cards draggable in TEAM tab | Same drag-and-drop pattern as V1 agent list. Separate localStorage key (vo-team-order). | Fixed order only -- rejected: users want to prioritize visible agents |
| D18 | V2 replaces V1 filter model with per-tab filters | V1 had one Event Log with agent/type/time filters. V2 splits this: HISTORY has agent/job/result/time, SCHEDULE has agent filter. More specific filters per context. | Global filter bar -- rejected: one-size-fits-all filters are noisy |

## Audit Log Schema

Each line in the audit log is a JSON object with these fields:

```json
{
  "ts": "2026-03-15T10:30:00Z",
  "action": "job_start | job_end | job_error | queue_add | queue_drain | lock_acquire | lock_release",
  "agent": "scrum-master",
  "job": "sprint-progress",
  "run_id": "uuid-v4",
  "system_version": "0.1.0",
  "detail": "optional free-text context"
}
```

Log files are stored at `output/audit/YYYY-MM.jsonl` (one file per month, append-only).

## State File Contracts

**V2 Note**: The V2 tabs (TEAM, OFFICE, HISTORY, SCHEDULE) do not introduce any new state files. They read from existing files: dashboard.json (agent status), events.jsonl (job history), config/agents.json (identity), config/jobs/*.json (skills/job definitions), and config/schedules.json (timing). All V2 data needs are served by existing API endpoints (/api/config, /api/dashboard, /api/events, /api/reports, /api/schedules).

### dashboard.json

Written atomically by the runner after every state change. The UI polls this file.

```json
{
  "system_version": "0.1.0",
  "updated_at": "2026-03-15T10:30:00Z",
  "agents": {
    "scrum-master": {
      "status": "idle | busy | error",
      "current_job": null,
      "current_run_id": null,
      "last_run": {
        "job": "sprint-progress",
        "run_id": "uuid-v4",
        "started_at": "2026-03-15T10:25:00Z",
        "ended_at": "2026-03-15T10:27:30Z",
        "result": "success | error",
        "detail": ""
      },
      "queue": []
    }
  }
}
```

### counter.json

Tracks cumulative run counts per agent per job. Written atomically.

```json
{
  "system_version": "0.1.0",
  "updated_at": "2026-03-15T10:30:00Z",
  "counts": {
    "scrum-master": {
      "sprint-progress": {
        "total": 42,
        "success": 40,
        "error": 2
      }
    }
  }
}
```

### events.jsonl

Append-only event stream in `state/events.jsonl`. Each line is a JSON object:

```json
{
  "ts": "2026-03-15T10:30:00Z",
  "event": "job_started | job_completed | job_failed | agent_queued",
  "agent": "scrum-master",
  "job": "sprint-progress",
  "run_id": "uuid-v4",
  "system_version": "0.1.0"
}
```
