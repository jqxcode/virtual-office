"""Fix corrupted output_file paths in VO audit logs.

A runner bug caused many audit entries to record output_file as the
*-latest.html symlink (e.g. sprint-progress-latest.html) instead of the
actual dated report for that agent/job run.  This script finds the correct
report by matching agent, job name, and timestamp date, then rewrites the
JSONL atomically.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import sys
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

sys.stdout.reconfigure(encoding="utf-8")

OUTPUT_DIR = Path(r"Q:\src\personal_projects\virtual-office\output")
AUDIT_DIR = OUTPUT_DIR / "audit"

# ── Job-to-filename mapping ──────────────────────────────────────────
# Some jobs produce reports with different base names than the job itself.
# Map: (agent, job) -> list of filename prefixes to search for.
# If not listed here, we derive prefixes automatically from the job name.
JOB_FILE_PREFIXES: Dict[Tuple[str, str], List[str]] = {
    ("bug-killer", "open-pr-maintenance"): ["pr-maintenance"],
    ("bug-killer", "scan-and-fix"): ["scan", "daily-summary"],
    ("bug-killer", "resolve-merge-conflicts"): ["merge-conflicts"],
    ("scrum-master", "ado-status-update"): ["ado-status-update"],
    ("scrum-master", "ado-burndown-update"): ["ado-burndown-update"],
    ("scrum-master", "bug-autopilot-meeting-join"): ["meeting-join-report", "meeting-join"],
    ("scrum-master", "shiproom-hygiene-check"): ["shiproom-hygiene"],
    ("scrum-master", "dry-run-ado-status-update"): ["dry-run-ado-status-update"],
    ("scrum-master", "compare-runs"): ["compare-runs", "run"],
    ("pEmailer", "scan-all-mailboxes"): ["scan"],
    ("auditor", "resolve-bugs-cleanup"): ["resolve-bugs-cleanup"],
    ("auditor", "TODO-sprint-progress"): ["sprint-progress", "todo-sprint-progress"],
    ("auditor", "consolidate-agent-memories"): ["consolidate-agent-memories"],
    ("auditor", "FFv2-daily-summary"): ["ffv2-daily-summary", "ffv2"],
    ("auditor", "YTD-OOF-Summary"): ["ytd-oof-summary"],
}

# Jobs known to NOT produce local report files (they post to Teams, update ADO, etc.)
NO_LOCAL_REPORT: Set[Tuple[str, str]] = {
    ("poster", "AAP-report-posting"),
    ("poster", "BAP-Perf-Analysis-posting"),
    ("poster", "Bug-Autopilot-Adoption-daily-summary"),
    ("poster", "ICM-daily-summary-Join"),
    ("poster", "ICM-daily-summary-Notes"),
}


def parse_entries(path: Path) -> List[dict]:
    """Parse a JSONL file, handling concatenated JSON objects on a single line."""
    entries: List[dict] = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            # Handle concatenated JSON: split on }{ boundary
            if "}{" in line:
                parts = line.replace("}{", "}\n{").split("\n")
            else:
                parts = [line]
            for part in parts:
                part = part.strip()
                if not part:
                    continue
                try:
                    entries.append(json.loads(part))
                except json.JSONDecodeError:
                    entries.append({"__raw__": part})
    return entries


def build_file_index() -> Dict[str, List[Tuple[str, float]]]:
    """Build index: directory_key -> list of (filepath, mtime).

    Agent subdirs use their name as key; root output/ uses '__root__'.
    Excludes *-latest.* symlinks.
    """
    index: Dict[str, List[Tuple[str, float]]] = {}

    for agent_dir in OUTPUT_DIR.iterdir():
        if not agent_dir.is_dir() or agent_dir.name == "audit":
            continue
        files = []
        for f in agent_dir.iterdir():
            if f.is_file() and f.suffix in (".html", ".md") and "-latest" not in f.name:
                files.append((str(f), f.stat().st_mtime))
        index[agent_dir.name] = files

    root_files = []
    for f in OUTPUT_DIR.iterdir():
        if f.is_file() and f.suffix in (".html", ".md") and "-latest" not in f.name:
            root_files.append((str(f), f.stat().st_mtime))
    index["__root__"] = root_files

    return index


def extract_date_from_timestamp(ts: str) -> Optional[str]:
    """Extract YYYYMMDD from an ISO timestamp string."""
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})", ts)
    if m:
        return f"{m.group(1)}{m.group(2)}{m.group(3)}"
    return None


def extract_date_from_filename(fname: str) -> Optional[str]:
    """Extract YYYYMMDD from a filename. Handles YYYYMMDD and YYYY-MM-DD."""
    m = re.search(r"(\d{8})", fname)
    if m:
        candidate = m.group(1)
        if candidate.startswith("20"):
            return candidate
    m = re.search(r"(\d{4})-(\d{2})-(\d{2})", fname)
    if m:
        return f"{m.group(1)}{m.group(2)}{m.group(3)}"
    return None


def get_file_prefixes(agent: str, job: str) -> List[str]:
    """Get the filename prefixes to search for a given agent/job combo."""
    key = (agent, job)
    if key in JOB_FILE_PREFIXES:
        return JOB_FILE_PREFIXES[key]

    # Auto-derive: the job name itself is the primary prefix
    job_norm = job.lower().replace("_", "-")
    prefixes = [job_norm]

    # Also try stripping common verb prefixes
    for prefix in ("open-", "dry-run-", "todo-"):
        if job_norm.startswith(prefix):
            prefixes.append(job_norm[len(prefix):])

    return prefixes


def filename_matches_job(fname: str, agent: str, job: str) -> bool:
    """Check if a filename plausibly matches an agent/job combo."""
    fname_lower = fname.lower()
    prefixes = get_file_prefixes(agent, job)

    for prefix in prefixes:
        if fname_lower.startswith(prefix):
            return True
        # Also check containment for compound names
        if prefix in fname_lower:
            return True

    return False


def find_correct_file(
    agent: str,
    job: str,
    timestamp: str,
    file_index: Dict[str, List[Tuple[str, float]]],
) -> Optional[str]:
    """Find the correct output file for an audit entry."""
    date_str = extract_date_from_timestamp(timestamp)
    if not date_str:
        return None

    try:
        ts_dt = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        ts_dt = None

    def score_candidates(
        files: List[Tuple[str, float]], penalty: float = 0
    ) -> List[Tuple[str, float]]:
        results: List[Tuple[str, float]] = []
        for fpath, mtime in files:
            fname = os.path.basename(fpath)
            if not filename_matches_job(fname, agent, job):
                continue
            fdate = extract_date_from_filename(fname)
            if fdate == date_str:
                diff = 0.0
                if ts_dt:
                    try:
                        file_dt = datetime.fromtimestamp(mtime, tz=ts_dt.tzinfo)
                        diff = abs((file_dt - ts_dt).total_seconds())
                    except (OSError, TypeError):
                        pass
                results.append((fpath, diff + penalty))
        return results

    candidates: List[Tuple[str, float]] = []

    # 1. Agent directory
    candidates.extend(score_candidates(file_index.get(agent, []), penalty=0))

    # 2. Root output/ (penalized)
    if not candidates:
        candidates.extend(
            score_candidates(file_index.get("__root__", []), penalty=100000)
        )

    # 3. Adjacent dates (+/- 1 day) in agent dir only
    if not candidates and date_str:
        try:
            base_date = datetime.strptime(date_str, "%Y%m%d")
            adjacent = {
                (base_date + timedelta(days=d)).strftime("%Y%m%d")
                for d in (-1, 1)
            }
        except ValueError:
            adjacent = set()

        for fpath, mtime in file_index.get(agent, []):
            fname = os.path.basename(fpath)
            if not filename_matches_job(fname, agent, job):
                continue
            fdate = extract_date_from_filename(fname)
            if fdate in adjacent:
                candidates.append((fpath, 200000))

        # Also adjacent dates in root
        if not candidates:
            for fpath, mtime in file_index.get("__root__", []):
                fname = os.path.basename(fpath)
                if not filename_matches_job(fname, agent, job):
                    continue
                fdate = extract_date_from_filename(fname)
                if fdate in adjacent:
                    candidates.append((fpath, 300000))

    if candidates:
        candidates.sort(key=lambda x: x[1])
        return candidates[0][0]

    return None


def is_corrupted(entry: dict) -> bool:
    """Determine if an audit entry has a corrupted output_file.

    ALL *-latest.html paths are corrupted -- the runner should have recorded
    the actual dated report, not the -latest symlink/copy.  Even when the
    base name matches the job, the path is wrong because it points to a
    generic symlink rather than the specific run's output.
    """
    details = entry.get("details", {})
    output_file = details.get("output_file", "")
    if not output_file or output_file == "(not saved)":
        return False

    agent = entry.get("agent", "")
    job = entry.get("job", "")
    if not agent or not job:
        return False

    fname = output_file.replace("\\", "/").split("/")[-1]

    # Any -latest file is corrupted
    if "-latest." in fname:
        return True

    # Root sprint-progress-latest without agent dir in path
    norm_path = output_file.replace("\\", "/")
    if "sprint-progress-latest" in fname and "/" + agent + "/" not in norm_path:
        return True

    return False


def main() -> None:
    jsonl_files = sorted(AUDIT_DIR.glob("*.jsonl"))
    if not jsonl_files:
        print("No JSONL files found in", AUDIT_DIR)
        return

    # Skip .bak files
    jsonl_files = [f for f in jsonl_files if not f.name.endswith(".bak")]

    print(f"Building file index from {OUTPUT_DIR} ...")
    file_index = build_file_index()
    total_files = sum(len(v) for v in file_index.values())
    print(f"  Indexed {total_files} report files across {len(file_index)} directories")

    grand_fixed = 0
    grand_skipped = 0
    grand_nulled = 0
    grand_total = 0

    for jsonl_path in jsonl_files:
        print(f"\nProcessing {jsonl_path.name} ...")
        entries = parse_entries(jsonl_path)
        print(f"  {len(entries)} entries")

        fixed = 0
        skipped = 0
        nulled = 0
        modified = False

        for entry in entries:
            if "__raw__" in entry:
                skipped += 1
                continue

            if not is_corrupted(entry):
                skipped += 1
                continue

            grand_total += 1
            agent = entry.get("agent", "")
            job = entry.get("job", "")
            timestamp = entry.get("timestamp", "")
            old_path = entry["details"]["output_file"]

            # Known no-local-report jobs -> null immediately
            if (agent, job) in NO_LOCAL_REPORT:
                entry["details"]["output_file"] = None
                nulled += 1
                modified = True
                continue

            correct = find_correct_file(agent, job, timestamp, file_index)
            if correct:
                entry["details"]["output_file"] = correct
                fixed += 1
                modified = True
                print(
                    f"  FIXED: [{agent}/{job}] "
                    f"{os.path.basename(old_path)} -> {os.path.basename(correct)}"
                )
            else:
                entry["details"]["output_file"] = None
                nulled += 1
                modified = True
                print(
                    f"  NULL:  [{agent}/{job}] "
                    f"{os.path.basename(old_path)} -> null (no matching report)"
                )

        grand_fixed += fixed
        grand_skipped += skipped
        grand_nulled += nulled

        if modified:
            # Back up original (only if .bak doesn't already exist)
            bak_path = jsonl_path.with_suffix(".jsonl.bak")
            if not bak_path.exists():
                shutil.copy2(jsonl_path, bak_path)
                print(f"  Backed up to {bak_path.name}")
            else:
                print(f"  Backup {bak_path.name} already exists, preserving it")

            # Write atomically via .tmp
            tmp_path = jsonl_path.with_suffix(".jsonl.tmp")
            with open(tmp_path, "w", encoding="utf-8") as f:
                for entry in entries:
                    if "__raw__" in entry:
                        f.write(entry["__raw__"] + "\n")
                    else:
                        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
            os.replace(str(tmp_path), str(jsonl_path))
            print(f"  Written {len(entries)} entries")

        print(f"  Summary: fixed={fixed}, skipped={skipped}, nulled={nulled}")

    print(f"\n{'='*60}")
    print(f"GRAND TOTAL: {grand_total} corrupted entries found")
    print(f"  Fixed:   {grand_fixed}")
    print(f"  Nulled:  {grand_nulled}")
    print(f"  Skipped: {grand_skipped} (already correct or no output_file)")


if __name__ == "__main__":
    main()
