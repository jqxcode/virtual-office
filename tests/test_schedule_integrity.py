"""Schedule-integrity test: detect missing/accidentally-removed required jobs.

Motivation: on 2026-04-14, commit 8447512 silently removed the bug-autopilot
schedule entries as a "while-we're-here" cleanup. The job definitions in
config/jobs/mScrumMaster.json were kept, the runner scripts were kept, only
the cron entries in config/schedules.json were removed. Nobody noticed for
47 days.

This test asserts that for every job in the "required" list:
  * direct_cron jobs have at least one valid 5-field cron in schedules.json
  * triggered jobs are referenced by a triggerOnComplete entry in some other
    job definition
  * every cron entry in schedules.json is a valid 5-field expression
"""
from __future__ import annotations

import json
import os
import re
import unittest
from typing import Dict, List, Optional, Tuple

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_DIR = os.path.join(REPO_ROOT, "config")
SCHEDULES_PATH = os.path.join(CONFIG_DIR, "schedules.json")
JOBS_DIR = os.path.join(CONFIG_DIR, "jobs")


# ---------------------------------------------------------------------------
# Required-job manifest
# ---------------------------------------------------------------------------
# kind = "direct_cron" -> must appear in schedules.json with valid cron
# kind = "triggered"   -> must be the target of triggerOnComplete elsewhere

REQUIRED_JOBS = [
    ("mScrumMaster", "shiproom-hygiene-check", "direct_cron"),
    ("mScrumMaster", "bug-autopilot-meeting-join", "direct_cron"),
    ("mScrumMaster", "bug-autopilot-notes", "direct_cron"),
    ("mScrumMaster", "ado-status-update", "direct_cron"),
    ("mScrumMaster", "ado-burndown-update", "direct_cron"),
    ("mPoster", "post-shiproom-hygiene-check", "triggered"),
]


# ---------------------------------------------------------------------------
# Cron validator (no croniter dependency)
# ---------------------------------------------------------------------------
# A 5-field expression: minute hour dom month dow
# Each field accepts:
#   *                  any
#   N                  single number
#   N-M                range
#   N,M,...            list
#   */N                step
#   N-M/K              range+step
#   L                  last (used in DOM for "last day of month")
#   1-5, MON-FRI       OK numeric only (we don't accept names here -- the
#                      repo's existing schedules.json uses numeric form)

_FIELD_RE = re.compile(
    r"^("
    r"\*(?:/\d+)?"               # * or */N
    r"|L"                        # L (last)
    r"|\d+(?:-\d+)?(?:/\d+)?"    # N or N-M or N-M/K or N/K
    r")"
    r"(?:,("
    r"\*(?:/\d+)?"
    r"|L"
    r"|\d+(?:-\d+)?(?:/\d+)?"
    r"))*$"
)


def is_valid_cron(expr: str) -> bool:
    """Return True if expr is a syntactically valid 5-field cron expression."""
    if not isinstance(expr, str):
        return False
    parts = expr.strip().split()
    if len(parts) != 5:
        return False
    for p in parts:
        if not _FIELD_RE.match(p):
            return False
    return True


# ---------------------------------------------------------------------------
# Loaders
# ---------------------------------------------------------------------------


def load_schedules() -> List[Dict]:
    with open(SCHEDULES_PATH, encoding="utf-8") as f:
        return json.load(f).get("schedules", [])


def load_all_jobs() -> Dict[str, Dict[str, Dict]]:
    """Return {agent_name: {job_name: job_body}}."""
    out: Dict[str, Dict[str, Dict]] = {}
    for fn in sorted(os.listdir(JOBS_DIR)):
        if not fn.endswith(".json"):
            continue
        agent = fn[:-5]
        path = os.path.join(JOBS_DIR, fn)
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        jobs = data.get("jobs", {})
        if isinstance(jobs, dict):
            out[agent] = jobs
    return out


def find_trigger_source(
    all_jobs: Dict[str, Dict[str, Dict]],
    target_agent: str,
    target_job: str,
) -> Optional[Tuple[str, str]]:
    """Return (agent, job) that fires target via triggerOnComplete, if any."""
    for src_agent, jobs in all_jobs.items():
        for src_job, body in jobs.items():
            if not isinstance(body, dict):
                continue
            trig = body.get("triggerOnComplete")
            if not isinstance(trig, dict):
                continue
            if trig.get("agent") == target_agent and trig.get("job") == target_job:
                return (src_agent, src_job)
    return None


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestCronValidator(unittest.TestCase):
    def test_accepts_typical_schedules(self):
        for expr in [
            "0 9 * * *",
            "*/15 * * * *",
            "0 7 * * 1-5",
            "45 8 * * 1-5",
            "0 6 L * *",
            "0,30 9-17 * * 1-5",
            "* * * * *",
        ]:
            self.assertTrue(is_valid_cron(expr), f"should accept: {expr!r}")

    def test_rejects_malformed(self):
        # Note: this is a syntax validator, not a range validator -- "60 9 * * *"
        # passes because the number itself parses; only structural problems fail.
        for expr in [
            "",
            "0 9 * *",          # 4 fields
            "0 9 * * * *",      # 6 fields
            "abc 9 * * *",      # letters
        ]:
            self.assertFalse(is_valid_cron(expr), f"should reject: {expr!r}")


class TestRequiredJobDefinitionsExist(unittest.TestCase):
    """Every required job must exist as a definition in config/jobs/<agent>.json."""

    @classmethod
    def setUpClass(cls):
        cls.all_jobs = load_all_jobs()

    def test_all_required_definitions_present(self):
        missing = []
        for agent, job, _kind in REQUIRED_JOBS:
            jobs = self.all_jobs.get(agent, {})
            if job not in jobs:
                missing.append(f"{agent}/{job} (no definition in config/jobs/{agent}.json)")
        self.assertEqual(
            missing, [],
            "Required job DEFINITIONS missing:\n  " + "\n  ".join(missing),
        )


class TestRequiredJobsAreScheduled(unittest.TestCase):
    """Every required job must be reachable -- either directly via cron or via triggerOnComplete."""

    @classmethod
    def setUpClass(cls):
        cls.schedules = load_schedules()
        cls.all_jobs = load_all_jobs()

    def test_direct_cron_jobs_have_schedule(self):
        missing = []
        for agent, job, kind in REQUIRED_JOBS:
            if kind != "direct_cron":
                continue
            matches = [
                s for s in self.schedules
                if s.get("agent") == agent and s.get("job") == job
            ]
            if not matches:
                missing.append(
                    f"{agent}/{job}: NO entry in config/schedules.json "
                    f"(required as direct_cron). If this job was intentionally "
                    f"removed, also remove it from REQUIRED_JOBS in this test."
                )
        self.assertEqual(
            missing, [],
            "Required direct_cron jobs are not scheduled:\n  " + "\n  ".join(missing),
        )

    def test_triggered_jobs_are_referenced(self):
        missing = []
        for agent, job, kind in REQUIRED_JOBS:
            if kind != "triggered":
                continue
            # Allowed: either someone triggers it via triggerOnComplete,
            # OR it has its own direct cron entry.
            src = find_trigger_source(self.all_jobs, agent, job)
            direct = [
                s for s in self.schedules
                if s.get("agent") == agent and s.get("job") == job
            ]
            if not src and not direct:
                missing.append(
                    f"{agent}/{job}: NO triggerOnComplete pointing at it AND "
                    f"no direct cron entry in schedules.json (required as triggered)."
                )
        self.assertEqual(
            missing, [],
            "Required triggered jobs are unreachable:\n  " + "\n  ".join(missing),
        )


class TestAllScheduledCronsAreValid(unittest.TestCase):
    """Every entry in schedules.json must have a syntactically valid cron."""

    @classmethod
    def setUpClass(cls):
        cls.schedules = load_schedules()

    def test_all_cron_expressions_valid(self):
        bad = []
        for idx, entry in enumerate(self.schedules):
            agent = entry.get("agent", "?")
            job = entry.get("job", "?")
            cron = entry.get("cron")
            if not is_valid_cron(cron):
                bad.append(f"[{idx}] {agent}/{job}: invalid cron {cron!r}")
        self.assertEqual(
            bad, [],
            "Invalid cron expressions in schedules.json:\n  " + "\n  ".join(bad),
        )


if __name__ == "__main__":
    unittest.main()
