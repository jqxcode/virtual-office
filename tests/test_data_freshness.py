"""Data freshness invariant -- detect scrum-master runs that exited 0 but
didn't actually refresh their output files.

CONTEXT (2026-05-26 to 2026-05-28 silent-failure pattern)
---------------------------------------------------------
The scrum-master `shiproom-hygiene-check` job is supposed to (re)write
`output/scrum-master/hygiene-teams-summary.json` every time it runs. The
downstream poster reads that file and refuses to post if it's stale.

On 2026-05-27 the poster refused to post because the data file was older
than the scheduled scrum-master run -- the scrum-master harness recorded
`completed exit_code=0` even though the underlying script aborted before
writing fresh output. The harness can't tell.

This test cross-checks every recent `completed` event against the mtime of
the file the job is supposed to produce. If the event timestamp is newer
than the file mtime by more than a small slop, the job claimed success
without producing fresh data -- FAIL.

Skips cleanly when no recent `completed` event exists for a given job.
"""
from __future__ import annotations

import json
import os
import re
import unittest
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional, Tuple

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EVENTS_PATH = os.path.join(REPO_ROOT, "state", "events.jsonl")
OUTPUT_DIR = os.path.join(REPO_ROOT, "output")

# How far back to look for the "most recent completed event".
LOOKBACK_DAYS = 7

# Tolerance: the file may be written slightly before the event timestamp
# (the runner writes events AFTER the script returns). We require the
# file to have been touched within this many seconds AFTER the `started`
# event for the same run -- i.e. during the run, not before.
#
# But because we use the simpler started/completed window check below,
# this is the slop on the "completed" comparison: file mtime must be
# >= started_at - SLOP_SECONDS.
SLOP_SECONDS = 60


# Job-name -> list of files the job is expected to refresh. The first
# existing file is used as the freshness signal; if none exist, the test
# fails with a clear "expected output missing" message.
EXPECTED_OUTPUTS: Dict[str, List[str]] = {
    "shiproom-hygiene-check": [
        os.path.join(OUTPUT_DIR, "scrum-master", "hygiene-teams-summary.json"),
        os.path.join(OUTPUT_DIR, "scrum-master", "hygiene-full-results.json"),
    ],
    # ado-status-update job copies the latest ADO autopilot report to
    # output/scrum-master/ado-status-update-YYYYMMDD.html. We resolve the
    # latest matching dated file at check time.
    "ado-status-update": [
        # sentinel handled in _resolve_expected_output
        "__ado_status_update_dated__",
    ],
}


def _parse_event_timestamp(ts: str) -> Optional[datetime]:
    """Parse a timestamp from events.jsonl.

    Format observed: '2026-05-28T08:46:10.8893915-07:00'. fromisoformat in
    Python 3.9 can't handle 7-digit microseconds, so we trim to 6 and let
    it parse the rest including the timezone.
    """
    if not ts:
        return None
    # Trim fractional seconds to 6 digits if longer
    m = re.match(r"^(.*\.\d{6})\d*(.*)$", ts)
    if m:
        ts = m.group(1) + m.group(2)
    try:
        return datetime.fromisoformat(ts)
    except ValueError:
        return None


def _load_recent_completed_events(
    job_name: str, lookback_days: int = LOOKBACK_DAYS
) -> List[dict]:
    """Return completed events for `job_name` within lookback window, newest last."""
    if not os.path.isfile(EVENTS_PATH):
        return []
    cutoff = datetime.now(timezone.utc) - timedelta(days=lookback_days)
    out: List[Tuple[datetime, dict]] = []
    with open(EVENTS_PATH, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            if evt.get("job") != job_name:
                continue
            if evt.get("event") != "completed":
                continue
            ts = _parse_event_timestamp(evt.get("timestamp", ""))
            if ts is None:
                continue
            ts_utc = ts.astimezone(timezone.utc)
            if ts_utc < cutoff:
                continue
            out.append((ts_utc, evt))
    out.sort(key=lambda x: x[0])
    return [e for _, e in out]


def _find_matching_started(
    job_name: str, run_id: str
) -> Optional[datetime]:
    """Find the `started` event timestamp for a given run_id."""
    if not os.path.isfile(EVENTS_PATH) or not run_id:
        return None
    with open(EVENTS_PATH, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            if evt.get("job") != job_name:
                continue
            if evt.get("event") != "started":
                continue
            if (evt.get("details") or {}).get("run_id") != run_id:
                continue
            ts = _parse_event_timestamp(evt.get("timestamp", ""))
            if ts is None:
                continue
            return ts.astimezone(timezone.utc)
    return None


def _resolve_expected_output(job_name: str) -> Optional[str]:
    """Return the path of the freshness-signal file for `job_name`, or None."""
    candidates = EXPECTED_OUTPUTS.get(job_name, [])
    for c in candidates:
        if c == "__ado_status_update_dated__":
            # Find newest output/scrum-master/ado-status-update-YYYYMMDD.html
            sm_dir = os.path.join(OUTPUT_DIR, "scrum-master")
            if not os.path.isdir(sm_dir):
                continue
            matches = [
                os.path.join(sm_dir, n)
                for n in os.listdir(sm_dir)
                if re.match(r"^ado-status-update-\d{8}\.html$", n)
            ]
            if matches:
                matches.sort(key=lambda p: os.path.getmtime(p), reverse=True)
                return matches[0]
            continue
        if os.path.isfile(c):
            return c
    return None


def _file_mtime_utc(path: str) -> datetime:
    return datetime.fromtimestamp(os.path.getmtime(path), tz=timezone.utc)


def _check_job_freshness(job_name: str) -> Tuple[str, Optional[str]]:
    """Return (status, failure_message_or_None).

    status:
      - "skip:no-events"    -- nothing to assert
      - "skip:no-output"    -- expected output file missing entirely
      - "ok"                -- file mtime is within the most recent run window
      - "fail"              -- job completed but output not refreshed
    """
    events = _load_recent_completed_events(job_name)
    if not events:
        return "skip:no-events", None

    last = events[-1]
    completed_ts = _parse_event_timestamp(last.get("timestamp", ""))
    if completed_ts is None:
        return "skip:no-events", None
    completed_ts = completed_ts.astimezone(timezone.utc)

    run_id = (last.get("details") or {}).get("run_id", "")
    started_ts = _find_matching_started(job_name, run_id)

    expected_path = _resolve_expected_output(job_name)
    if expected_path is None:
        msg = (
            f"job '{job_name}' completed at {completed_ts.isoformat()} "
            f"(run_id={run_id or '?'}) but expected output file is missing "
            f"entirely. Looked for: {EXPECTED_OUTPUTS.get(job_name, [])}"
        )
        return "fail", msg

    mtime = _file_mtime_utc(expected_path)

    # Window: file must be >= (started_ts - SLOP) and <= (completed_ts + SLOP).
    # The job is supposed to write the file DURING the run, so mtime should
    # land between started and completed.
    earliest_ok = (started_ts or completed_ts) - timedelta(seconds=SLOP_SECONDS)
    if mtime < earliest_ok:
        age = (completed_ts - mtime).total_seconds()
        msg = (
            f"job '{job_name}' claims to have completed at "
            f"{completed_ts.isoformat()} (run_id={run_id or '?'}) but data file "
            f"{expected_path} was last modified at {mtime.isoformat()} -- "
            f"{age/3600:.1f}h before completion. The job did NOT refresh its "
            f"data. Started at: "
            f"{started_ts.isoformat() if started_ts else '(unknown)'}."
        )
        return "fail", msg

    return "ok", None


class TestDataFreshness(unittest.TestCase):
    """Cross-check completed events vs. output-file mtimes."""

    def test_shiproom_hygiene_check_refreshed_output(self):
        status, msg = _check_job_freshness("shiproom-hygiene-check")
        print(f"\n[shiproom-hygiene-check] status={status}")
        if status.startswith("skip"):
            self.skipTest(f"shiproom-hygiene-check: {status}")
        if status == "fail":
            self.fail(msg)
        self.assertEqual(status, "ok")

    def test_ado_status_update_refreshed_output(self):
        status, msg = _check_job_freshness("ado-status-update")
        print(f"\n[ado-status-update] status={status}")
        if status.startswith("skip"):
            self.skipTest(f"ado-status-update: {status}")
        if status == "fail":
            self.fail(msg)
        self.assertEqual(status, "ok")


if __name__ == "__main__":
    unittest.main()
