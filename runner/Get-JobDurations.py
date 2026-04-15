"""
Generate HTML snippet for Agent Job Run Durations section.
Reads audit logs and outputs an HTML fragment that can be inserted into any report template.

Usage:
    python Get-JobDurations.py [--agent <name>] [--month YYYY-MM]

    --agent: Filter to a specific agent (default: all agents)
    --month: Which month's audit log to read (default: current month)

Output: HTML to stdout (the content for {{DURATION_BARS}} and {{DURATION_TABLE}})
"""
import json
import sys
import os
import argparse
from datetime import datetime
from pathlib import Path
from collections import defaultdict

sys.stdout.reconfigure(encoding="utf-8")

PROJECT_ROOT = Path(__file__).parent.parent
AUDIT_DIR = PROJECT_ROOT / "output" / "audit"

# VDS vo-theme-0.2.0 aligned colors
AGENT_COLORS = {
    "scrum-master": "#3b82f6",   # --vo-status-info
    "bug-killer": "#ef4444",     # --vo-status-error
    "emailer": "#22c55e",        # --vo-status-success
    "auditor": "#a855f7",        # purple (consistent with app.js)
    "poster": "#f59e0b",         # --vo-status-warning
    "hang-scout": "#06b6d4",     # cyan
}

def parse_duration(s):
    """Parse duration string like '346s' or '42m' to seconds."""
    s = s.strip()
    if s.endswith("s"):
        return int(s[:-1])
    if s.endswith("m"):
        return int(s[:-1]) * 60
    try:
        return int(s)
    except ValueError:
        return 0

def format_duration(seconds):
    """Format seconds to human-readable string."""
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        m = seconds // 60
        s = seconds % 60
        return f"{m}m {s}s" if s else f"{m}m"
    h = seconds // 3600
    m = (seconds % 3600) // 60
    return f"{h}h {m}m" if m else f"{h}h"

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--agent", default=None)
    parser.add_argument("--month", default=datetime.now().strftime("%Y-%m"))
    parser.add_argument("--format", choices=["bars", "table", "both"], default="both")
    args = parser.parse_args()

    audit_file = AUDIT_DIR / f"{args.month}.jsonl"
    if not audit_file.exists():
        print(f"<!-- No audit data for {args.month} -->")
        return

    # Collect durations per agent/job
    stats = defaultdict(list)
    for line in audit_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue

        action = d.get("action") or d.get("details", {}).get("action", "")
        if action not in ("completed", "failed"):
            continue

        details = d.get("details", {})
        duration_str = details.get("duration", "")
        if not duration_str:
            continue

        agent = d.get("agent", "")
        job = d.get("job", "")
        if args.agent and agent != args.agent:
            continue

        seconds = parse_duration(duration_str)
        if seconds > 0:
            ts = d.get("timestamp", "")
            exit_code = details.get("exit_code", 0)
            stats[(agent, job)].append({
                "seconds": seconds,
                "ts": ts,
                "exit_code": exit_code,
            })

    if not stats:
        print(f"<!-- No completed runs found for {args.month} -->")
        return

    # Compute aggregates
    rows = []
    for (agent, job), runs in stats.items():
        durations = [r["seconds"] for r in runs]
        avg = sum(durations) // len(durations)
        rows.append({
            "agent": agent,
            "job": job,
            "runs": len(runs),
            "avg": avg,
            "min": min(durations),
            "max": max(durations),
            "last_ts": max(r["ts"] for r in runs),
            "success": sum(1 for r in runs if r["exit_code"] == 0),
        })

    rows.sort(key=lambda r: r["avg"], reverse=True)
    max_avg = max(r["avg"] for r in rows) if rows else 1

    output_parts = []

    # Bar chart
    if args.format in ("bars", "both"):
        bars = []
        for r in rows:
            pct = max(1, int(100 * r["avg"] / max_avg)) if max_avg > 0 else 1
            agent_class = f"agent-{r['agent']}"
            color = AGENT_COLORS.get(r["agent"], "#888")
            bars.append(
                f'<div class="bar-row">'
                f'<div class="bar-label">{r["agent"]} / {r["job"]}</div>'
                f'<div class="bar-track"><div class="bar-fill {agent_class}" style="width:{pct}%;background:{color}"></div></div>'
                f'<div class="bar-value">{format_duration(r["avg"])} avg</div>'
                f'</div>'
            )
        output_parts.append("\n".join(bars))

    # Table
    if args.format in ("table", "both"):
        if args.format == "both":
            output_parts.append("<!-- TABLE_SEPARATOR -->")
        table_rows = []
        for r in rows:
            last_ts = r["last_ts"][:16].replace("T", " ") if r["last_ts"] else "-"
            success_rate = f'{r["success"]}/{r["runs"]}'
            table_rows.append(
                f'<tr>'
                f'<td>{r["agent"]}</td>'
                f'<td>{r["job"]}</td>'
                f'<td>{success_rate}</td>'
                f'<td>{format_duration(r["avg"])}</td>'
                f'<td>{format_duration(r["min"])}</td>'
                f'<td>{format_duration(r["max"])}</td>'
                f'<td>{last_ts}</td>'
                f'</tr>'
            )
        output_parts.append("\n".join(table_rows))

    # Max label
    max_row = rows[0]
    max_label = f'{max_row["agent"]} / {max_row["job"]} ({format_duration(max_row["avg"])})'
    print(f"<!-- MAX_DURATION_LABEL: {max_label} -->")
    print("\n".join(output_parts))

if __name__ == "__main__":
    main()
