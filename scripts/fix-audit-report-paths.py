"""
fix-audit-report-paths.py -- Fix historical audit entries with wrong output_file paths.

The VO runner had a bug where it searched parent output/ dir for *-latest.html,
causing all jobs to record sprint-progress-latest.html as their report.

This script:
1. Scans all audit JSONL files
2. For each completed entry with an output_file, validates it belongs to the agent
3. If invalid, searches output/<agent>/ for a report matching the run timestamp
4. Rewrites the audit JSONL with corrected paths

Usage:
    python scripts/fix-audit-report-paths.py [--dry-run]
"""
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Optional, Tuple

sys.stdout.reconfigure(encoding="utf-8")

PROJECT_ROOT = Path(__file__).parent.parent
AUDIT_DIR = PROJECT_ROOT / "output" / "audit"
OUTPUT_DIR = PROJECT_ROOT / "output"

# Agent -> allowed report filename prefixes
AGENT_REPORT_TYPES: Dict[str, List[str]] = {
    "bug-killer": ["daily-summary", "pr-maintenance", "open-pr-maintenance", "scan", "merge-conflicts"],
    "hang-scout": ["daily-report", "incident"],
    "auditor": ["failure-review", "sprint-progress", "TODO-sprint-progress"],
    "scrum-master": ["sprint-progress", "shiproom-hygiene", "comparison", "run-summaries", "run-", "meeting-notes", "ado-status"],
    "poster": [],  # poster posts to Teams, no local HTML reports
    "pEmailer": ["scan-all-mailboxes", "digest"],
    "dreamer": ["wish"],
    "researcher": [],
}


def path_belongs_to_agent(agent: str, job: str, output_file: str) -> bool:
    """Check if output_file path is valid for the given agent/job.

    Valid if:
    1. Path is in the agent's own output dir (output/<agent>/...), OR
    2. Path is a root-level file whose name starts with the job name or agent name
    Invalid: path is in a DIFFERENT agent's dir, or is a generic file like sprint-progress-latest.html
    """
    if not output_file or output_file == "(not saved)":
        return True  # nothing to validate
    normalized = output_file.replace("\\", "/").lower()
    agent_lower = agent.lower()
    job_lower = job.lower().lstrip("todo-")

    # Case 1: in agent's own subdir
    if f"/{agent_lower}/" in normalized:
        return True

    # Case 2: root-level file matching job or agent name
    filename = normalized.split("/")[-1]
    if filename.startswith(job_lower) or filename.startswith(agent_lower + "-"):
        # But reject -latest files
        if "-latest" not in filename:
            return True

    return False


def find_report_for_run(agent: str, job: str, run_ts: str) -> Optional[str]:
    """Find the correct report file for a given agent/job/timestamp.

    Matches by: (1) job name prefix in filename, (2) closest timestamp.
    Both must match -- a report for a different job is not valid even if close in time.
    """
    agent_dir = OUTPUT_DIR / agent
    if not agent_dir.exists():
        return None

    # Parse run timestamp
    run_dt = _parse_timestamp(run_ts)
    if not run_dt:
        return None

    # Normalize job name to filename prefix patterns
    # e.g. "open-pr-maintenance" -> look for "open-pr-maintenance-*" or "pr-maintenance-*"
    job_lower = job.lower()
    job_prefixes = [job_lower]
    # Also try without common prefixes like "TODO-"
    if job_lower.startswith("todo-"):
        job_prefixes.append(job_lower[5:])

    # Collect all HTML files in agent dir (not -latest)
    all_files = []
    for f in agent_dir.glob("*.html"):
        if "-latest" in f.name:
            continue
        all_files.append(f)
    for subdir in agent_dir.iterdir():
        if subdir.is_dir():
            for f in subdir.glob("*.html"):
                if "-latest" in f.name:
                    continue
                all_files.append(f)
    # Also check root output/ for stray files with agent-prefixed or job-prefixed names
    for f in OUTPUT_DIR.glob("*.html"):
        if "-latest" in f.name:
            continue
        fname_lower = f.name.lower()
        if fname_lower.startswith(agent.lower() + "-") or any(fname_lower.startswith(p) for p in job_prefixes):
            all_files.append(f)

    # Filter to files matching the job name
    candidates = []
    for f in all_files:
        fname_lower = f.name.lower()
        # Check if any job prefix matches the start of the filename
        matches_job = any(fname_lower.startswith(p) for p in job_prefixes)
        if not matches_job:
            continue
        file_dt = _extract_date_from_filename(f.name)
        if file_dt:
            delta = abs((run_dt - file_dt).total_seconds())
            candidates.append((delta, f))

    if not candidates:
        return None

    # Sort by closest timestamp match
    candidates.sort(key=lambda x: x[0])
    best_delta, best_file = candidates[0]

    # Only match if within 24 hours
    if best_delta > 86400:
        return None

    return str(best_file)


def _parse_timestamp(ts: str) -> Optional[datetime]:
    """Parse various timestamp formats from audit entries."""
    if not ts:
        return None
    # Try ISO format
    for fmt in [
        "%Y-%m-%dT%H:%M:%S.%f%z",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%dT%H:%M:%S.%f",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M:%S.%f-07:00",
        "%Y-%m-%dT%H:%M:%S.%f-08:00",
    ]:
        try:
            return datetime.strptime(ts, fmt)
        except (ValueError, TypeError):
            continue
    # Fallback: extract date portion
    m = re.search(r"(\d{4}-\d{2}-\d{2})", ts)
    if m:
        try:
            return datetime.strptime(m.group(1), "%Y-%m-%d")
        except ValueError:
            pass
    return None


def _extract_date_from_filename(name: str) -> Optional[datetime]:
    """Extract date from report filename patterns."""
    # Pattern: YYYYMMDD-HHMMSS
    m = re.search(r"(\d{8})-(\d{6})", name)
    if m:
        try:
            return datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S")
        except ValueError:
            pass
    # Pattern: YYYYMMDD
    m = re.search(r"(\d{8})", name)
    if m:
        try:
            return datetime.strptime(m.group(1), "%Y%m%d")
        except ValueError:
            pass
    # Pattern: YYYY-MM-DD
    m = re.search(r"(\d{4}-\d{2}-\d{2})", name)
    if m:
        try:
            return datetime.strptime(m.group(1), "%Y-%m-%d")
        except ValueError:
            pass
    return None


def process_audit_file(path: Path, dry_run: bool) -> Tuple[int, int, int]:
    """Process one audit JSONL file. Returns (total, fixed, cleared)."""
    lines = path.read_text(encoding="utf-8").splitlines()
    new_lines = []
    total = 0
    fixed = 0
    cleared = 0

    for line in lines:
        line = line.strip()
        if not line:
            new_lines.append("")
            continue

        # Handle concatenated JSON objects
        parts = re.split(r'(?<=\})(?=\{)', line)
        new_parts = []
        for part in parts:
            part = part.strip()
            if not part:
                continue
            try:
                evt = json.loads(part)
            except json.JSONDecodeError:
                new_parts.append(part)
                continue

            total += 1
            agent = (evt.get("agent") or "").lower()
            job = evt.get("job") or ""
            details = evt.get("details")
            event_type = evt.get("event") or evt.get("action") or ""
            ts = evt.get("timestamp") or ""

            if not details or not isinstance(details, dict):
                new_parts.append(json.dumps(evt, ensure_ascii=False))
                continue

            output_file = details.get("output_file")
            if not output_file or output_file == "(not saved)":
                new_parts.append(json.dumps(evt, ensure_ascii=False))
                continue

            # Check if path belongs to agent/job
            if path_belongs_to_agent(agent, job, output_file):
                new_parts.append(json.dumps(evt, ensure_ascii=False))
                continue

            # Invalid path -- try to find the correct one
            correct_path = find_report_for_run(agent, job, ts)
            if correct_path:
                old_path = details["output_file"]
                details["output_file"] = correct_path
                evt["details"] = details
                fixed += 1
                print(f"  FIXED: {agent}/{job} @ {ts[:19]}")
                print(f"    OLD: {old_path}")
                print(f"    NEW: {correct_path}")
            else:
                # No matching report found -- clear the bogus path
                # Poster jobs legitimately have no reports
                if agent in AGENT_REPORT_TYPES and not AGENT_REPORT_TYPES.get(agent):
                    details["output_file"] = "(not saved)"
                else:
                    details["output_file"] = "(not saved)"
                evt["details"] = details
                cleared += 1
                print(f"  CLEARED: {agent}/{job} @ {ts[:19]} (no matching report found)")

            new_parts.append(json.dumps(evt, ensure_ascii=False))

        new_lines.append("".join(new_parts))

    if not dry_run and (fixed > 0 or cleared > 0):
        path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")

    return total, fixed, cleared


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", help="Show changes without writing")
    args = parser.parse_args()

    if not AUDIT_DIR.exists():
        print(f"Audit dir not found: {AUDIT_DIR}")
        return

    total_all = 0
    fixed_all = 0
    cleared_all = 0

    audit_files = sorted(AUDIT_DIR.glob("*.jsonl"))
    print(f"Processing {len(audit_files)} audit files...")
    if args.dry_run:
        print("(DRY RUN -- no files will be modified)\n")

    for af in audit_files:
        print(f"\n--- {af.name} ---")
        total, fixed, cleared = process_audit_file(af, args.dry_run)
        total_all += total
        fixed_all += fixed
        cleared_all += cleared
        if fixed == 0 and cleared == 0:
            print("  (no changes needed)")

    print(f"\n{'='*60}")
    print(f"Total entries:  {total_all}")
    print(f"Fixed:          {fixed_all} (matched to correct report)")
    print(f"Cleared:        {cleared_all} (no match, set to '(not saved)')")
    if args.dry_run:
        print("\nDRY RUN -- rerun without --dry-run to apply changes")


if __name__ == "__main__":
    main()
