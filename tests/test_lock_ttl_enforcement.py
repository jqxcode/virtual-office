"""Invariant test: lock TTL must be enforced by killing the process.

Background
==========

Virtual Office uses per-agent lock files to guarantee single-writer
semantics. The runner (runner/Invoke-AgentJob.ps1) and the pHangScout
agent both look for "stale" locks held past
``staleLockTimeoutMinutes`` and emit a ``stale_lock_cleared`` event
when they delete the LOGICAL lock file.

However, clearing the lock file does NOT terminate the process that
held it. If the underlying Claude run is still alive, two failure
modes appear in the wild:

1. The runaway process continues to spend money / write reports /
   mutate state long after its TTL.
2. A NEW invocation of the same job sees the cleared lock and
   queues / starts a second copy, racing the first.

Observed on 5/26-5/28 for ``pBugKiller`` (TTL = 180 min):

   2026-05-26  daily-summary           21014s (350 min)
   2026-05-27  open-pr-maintenance     19981s (333 min)
   2026-05-28  open-pr-maintenance     20164s (336 min)

In each case ``stale_lock_cleared`` fires at the right moment
(around 07:28-07:29) but no ``kill_initiated`` / ``force_killed``
event is ever written, and the process self-exits minutes later.
Queued events behind these runs prove the race did happen.

This test fails when ANY (started, completed) pair in the last 14
days exceeded its configured TTL without a matching kill event. It
intentionally fails today so the gap is visible.

Fixing pHangScout is a separate task -- this test only EXPOSES the
missing behavior.
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
JOBS_DIR = os.path.join(REPO_ROOT, "config", "jobs")
AGENTS_PATH = os.path.join(REPO_ROOT, "config", "agents.json")

# Spec: "look at config/jobs/*.json for any lockTtlMinutes field, or fall
# back to a global default of 180". The runner reads
# staleLockTimeoutMinutes from config/agents.json today, so we also
# consult that as a secondary source when a job-level value is absent.
GLOBAL_DEFAULT_TTL_MIN = 180
LOOKBACK_DAYS = 14

# ISO-8601 with optional fractional seconds (1-9 digits) and an
# offset like "-07:00" or "-0700". Python 3.9 stdlib fromisoformat
# rejects offsets with colons AND >6-digit fractions, so we parse by
# hand.
_TS_RE = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})"
    r"(?:\.(\d+))?"
    r"(Z|[+-]\d{2}):?(\d{2})?$"
)


def parse_ts(s: str) -> datetime:
    """Parse a Virtual Office event timestamp into an aware UTC datetime."""
    m = _TS_RE.match(s)
    if not m:
        raise ValueError("unparseable timestamp: {0!r}".format(s))
    yr, mo, dy, hh, mm, ss, frac, off_h, off_m = m.groups()
    micro = 0
    if frac:
        # Truncate or pad to 6 digits for microseconds.
        frac6 = (frac + "000000")[:6]
        micro = int(frac6)
    if off_h == "Z":
        tz = timezone.utc
    else:
        sign = 1 if off_h[0] == "+" else -1
        hours = int(off_h[1:])
        minutes = int(off_m or "0")
        tz = timezone(sign * timedelta(hours=hours, minutes=minutes))
    return datetime(
        int(yr), int(mo), int(dy), int(hh), int(mm), int(ss), micro, tz
    ).astimezone(timezone.utc)


def load_ttl_minutes_by_job() -> Dict[Tuple[str, str], int]:
    """Build a (agent, job) -> TTL minutes map.

    Source of truth, in priority order:
      1. ``lockTtlMinutes`` in config/jobs/<agent>.json under
         ``jobs.<job>``.
      2. ``staleLockTimeoutMinutes`` in config/agents.json under
         ``agents.<agent>`` (the value the runner actually enforces
         today).
      3. ``GLOBAL_DEFAULT_TTL_MIN`` (180).
    """
    # Agent-level fallback from agents.json.
    agent_ttl: Dict[str, int] = {}
    if os.path.exists(AGENTS_PATH):
        with open(AGENTS_PATH, "r", encoding="utf-8") as f:
            agents_cfg = json.load(f)
        for agent_name, info in (agents_cfg.get("agents") or {}).items():
            if isinstance(info, dict) and "staleLockTimeoutMinutes" in info:
                try:
                    agent_ttl[agent_name] = int(info["staleLockTimeoutMinutes"])
                except (TypeError, ValueError):
                    pass

    job_ttl: Dict[Tuple[str, str], int] = {}
    if os.path.isdir(JOBS_DIR):
        for fname in os.listdir(JOBS_DIR):
            if not fname.endswith(".json"):
                continue
            agent_name = fname[: -len(".json")]
            fpath = os.path.join(JOBS_DIR, fname)
            try:
                with open(fpath, "r", encoding="utf-8") as f:
                    cfg = json.load(f)
            except (OSError, ValueError):
                continue
            jobs = cfg.get("jobs") or {}
            for job_name, job_info in jobs.items():
                if isinstance(job_info, dict) and "lockTtlMinutes" in job_info:
                    try:
                        job_ttl[(agent_name, job_name)] = int(
                            job_info["lockTtlMinutes"]
                        )
                    except (TypeError, ValueError):
                        pass
                else:
                    # Fall back to agent-level.
                    if agent_name in agent_ttl:
                        job_ttl[(agent_name, job_name)] = agent_ttl[agent_name]
    return job_ttl


def get_ttl(
    job_ttl: Dict[Tuple[str, str], int], agent: str, job: str
) -> int:
    if (agent, job) in job_ttl:
        return job_ttl[(agent, job)]
    return GLOBAL_DEFAULT_TTL_MIN


def load_events(path: str) -> List[dict]:
    events: List[dict] = []
    if not os.path.exists(path):
        return events
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except ValueError:
                # Tolerate one bad line rather than masking the
                # invariant we care about.
                continue
    return events


def find_violations(
    events: List[dict],
    job_ttl: Dict[Tuple[str, str], int],
    now_utc: datetime,
    lookback_days: int = LOOKBACK_DAYS,
) -> List[dict]:
    """Return one row per (started, completed) pair that exceeded TTL.

    Each row contains:
      run_id, agent, job, started_at, completed_at, duration_min,
      ttl_min, lock_cleared_at, killed_at
    """
    cutoff = now_utc - timedelta(days=lookback_days)
    started: Dict[str, dict] = {}
    completed: Dict[str, dict] = {}
    lock_cleared_by_agent_job: List[Tuple[str, str, datetime]] = []
    kills_by_run: Dict[str, datetime] = {}
    kills_by_agent_job: List[Tuple[str, str, datetime]] = []

    for ev in events:
        ts_raw = ev.get("timestamp")
        if not ts_raw:
            continue
        try:
            ts = parse_ts(str(ts_raw))
        except ValueError:
            continue
        if ts < cutoff:
            continue
        event = ev.get("event")
        agent = ev.get("agent") or ""
        job = ev.get("job") or ""
        details = ev.get("details") or {}
        run_id = details.get("run_id") if isinstance(details, dict) else None

        if event == "started" and run_id:
            started[run_id] = {
                "ts": ts,
                "agent": agent,
                "job": job,
            }
        elif event == "completed" and run_id:
            completed[run_id] = {
                "ts": ts,
                "agent": agent,
                "job": job,
                "details": details,
            }
        elif event == "stale_lock_cleared":
            lock_cleared_by_agent_job.append((agent, job, ts))
        elif event in ("kill_initiated", "force_killed"):
            if run_id:
                kills_by_run[run_id] = ts
            kills_by_agent_job.append((agent, job, ts))

    violations: List[dict] = []
    for run_id, c in completed.items():
        s = started.get(run_id)
        if not s:
            continue
        duration_s = (c["ts"] - s["ts"]).total_seconds()
        if duration_s <= 0:
            continue
        ttl_min = get_ttl(job_ttl, s["agent"], s["job"])
        if duration_s <= ttl_min * 60:
            continue
        # Lock-cleared event for the same agent+job between started
        # and completed.
        lock_ts: Optional[datetime] = None
        for ag, jb, ts in lock_cleared_by_agent_job:
            if ag == s["agent"] and jb == s["job"] and s["ts"] <= ts <= c["ts"]:
                if lock_ts is None or ts < lock_ts:
                    lock_ts = ts
        kill_ts: Optional[datetime] = kills_by_run.get(run_id)
        if kill_ts is None:
            # Fall back to any kill for the same agent+job inside
            # the run window (kill events may omit run_id).
            for ag, jb, ts in kills_by_agent_job:
                if ag == s["agent"] and jb == s["job"] and s["ts"] <= ts <= c["ts"]:
                    if kill_ts is None or ts < kill_ts:
                        kill_ts = ts
        violations.append({
            "run_id": run_id,
            "agent": s["agent"],
            "job": s["job"],
            "started_at": s["ts"],
            "completed_at": c["ts"],
            "duration_min": round(duration_s / 60.0, 1),
            "ttl_min": ttl_min,
            "lock_cleared_at": lock_ts,
            "killed_at": kill_ts,
        })
    violations.sort(key=lambda r: r["started_at"])
    return violations


def format_markdown_table(rows: List[dict]) -> str:
    headers = [
        "run_id",
        "agent",
        "job",
        "started_at",
        "completed_at",
        "duration_min",
        "ttl_min",
        "lock_cleared_at",
        "killed_at",
    ]
    lines = ["| " + " | ".join(headers) + " |"]
    lines.append("| " + " | ".join(["---"] * len(headers)) + " |")
    for r in rows:
        lines.append("| " + " | ".join([
            str(r["run_id"]),
            str(r["agent"]),
            str(r["job"]),
            r["started_at"].isoformat(),
            r["completed_at"].isoformat(),
            "{0:.1f}".format(r["duration_min"]),
            str(r["ttl_min"]),
            r["lock_cleared_at"].isoformat() if r["lock_cleared_at"] else "no",
            r["killed_at"].isoformat() if r["killed_at"] else "no",
        ]) + " |")
    return "\n".join(lines)


class TestLockTtlEnforcement(unittest.TestCase):
    """Every run that blew past its lock TTL must have been killed.

    The Markdown table is included in the failure message so CI logs
    name the exact violating runs.
    """

    def test_no_runaway_processes_survived_their_ttl(self):
        events = load_events(EVENTS_PATH)
        # Guard against an empty / missing log so we never produce a
        # falsely-green run.
        self.assertTrue(
            events,
            msg="state/events.jsonl is empty or missing -- nothing to check",
        )
        job_ttl = load_ttl_minutes_by_job()
        now_utc = datetime.now(timezone.utc)
        rows = find_violations(events, job_ttl, now_utc, LOOKBACK_DAYS)
        unkilled = [r for r in rows if r["killed_at"] is None]
        if unkilled:
            table = format_markdown_table(rows)
            msg = (
                "{0} run(s) exceeded their lock TTL but were never "
                "killed (last {1} days). pHangScout cleared the "
                "logical lock but the process kept running. The "
                "right behavior is to kill the PID AND write a "
                "kill_initiated / force_killed event.\n\n{2}"
            ).format(len(unkilled), LOOKBACK_DAYS, table)
            self.fail(msg)


if __name__ == "__main__":
    unittest.main()
