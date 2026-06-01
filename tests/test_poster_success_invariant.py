"""Poster success invariant -- detect silently-failed Teams posts.

CONTEXT (2026-05-26 to 2026-05-28 silent-failure pattern)
---------------------------------------------------------
The Virtual Office harness records job lifecycle in state/events.jsonl and
considers `completed exit_code=0` to be "success". But the mPoster agent
sometimes writes a *narrative excuse* to its output file instead of actually
posting to Teams:

  * device-code prompt left in the output (auth never completed; the post
    that the harness "completed" never happened). 5 instances over 3 days.
  * "data is stale, refusing to post" -- legitimate refusal, but the upstream
    mScrumMaster run that should have refreshed the data ALSO exited 0,
    masking the silent breakage of the data pipeline. 2 instances.

Either way, the harness exit_code cannot tell success apart from "fake
success". This test walks recent mPoster output files and classifies each
one by content, then FAILS if it sees device-code failures or any output
that doesn't match a known pattern (so new failure modes are surfaced
rather than ignored).

This test is informational, NOT a strict pre-merge gate -- failing here
indicates the live system has silently-broken automation that needs human
attention.
"""
from __future__ import annotations

import os
import re
import time
import unittest
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Tuple

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
POSTER_DIR = os.path.join(REPO_ROOT, "output", "mPoster")

# Window of files to inspect. 7 days catches the 5/26-5/28 incident and
# enough surrounding context for trend detection.
WINDOW_DAYS = 7

# Filename: post-<job>-YYYYMMDD-HHMMSS.md  OR  <job>-YYYYMMDD-HHMMSS.md
# We accept both because the actual output/mPoster directory mixes naming
# styles (post-shiproom-..., Bug-Autopilot-..., ICM-daily-summary-...).
POSTER_FILE_RE = re.compile(r"^.+-(\d{8})-(\d{6})\.md$")

# Classification markers. Order matters: success is checked first because
# a successful post can legitimately include the word "refused" in a
# narrative. Failure markers are checked only when no success marker is
# present.
SUCCESS_MARKERS = (
    "HTTP 201",
    "messageId",
    "message ID",  # mPoster narrative often writes "message ID `<id>`"
    "webUrl",
)
DEVICE_CODE_MARKERS = (
    "device code",
    "enter the code",
    "enter code",
    "microsoft.com/devicelogin",
    "login.microsoft.com/device",
)
STALE_DATA_MARKERS = (
    "is stale",
    "data is stale",
    "last modified:",
    "refused to post",
    "not today",  # "...was last modified 2026-05-26, not today (2026-05-28)"
)

CLASS_SUCCESS = "SUCCESS"
CLASS_DEVICE_CODE = "DEVICE_CODE_FAILURE"
CLASS_STALE = "STALE_DATA_REFUSAL"
CLASS_OTHER = "OTHER_FAILURE"


def _classify(content: str) -> str:
    """Return one of the CLASS_* labels based on content markers."""
    lower = content.lower()
    if any(m.lower() in lower for m in SUCCESS_MARKERS):
        return CLASS_SUCCESS
    if any(m.lower() in lower for m in DEVICE_CODE_MARKERS):
        return CLASS_DEVICE_CODE
    if any(m.lower() in lower for m in STALE_DATA_MARKERS):
        return CLASS_STALE
    return CLASS_OTHER


def _recent_mPoster_files() -> List[str]:
    """Return absolute paths of mPoster .md files modified within WINDOW_DAYS."""
    if not os.path.isdir(POSTER_DIR):
        return []
    cutoff = time.time() - WINDOW_DAYS * 86400
    out: List[str] = []
    for name in os.listdir(POSTER_DIR):
        if not name.endswith(".md"):
            continue
        if not POSTER_FILE_RE.match(name):
            continue
        path = os.path.join(POSTER_DIR, name)
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        if mtime >= cutoff:
            out.append(path)
    out.sort()
    return out


def _print_table(rows: List[Tuple[str, str, str]]) -> None:
    """Print classification table. rows = (filename, mtime_iso, classification)."""
    if not rows:
        print("  (no mPoster output files in window)")
        return
    name_w = max(len(r[0]) for r in rows)
    cls_w = max(len(r[2]) for r in rows)
    sep = "  "
    header = f"{'FILE'.ljust(name_w)}{sep}{'MTIME'.ljust(19)}{sep}{'CLASSIFICATION'.ljust(cls_w)}"
    print(header)
    print("-" * len(header))
    for name, mtime, cls in rows:
        print(f"{name.ljust(name_w)}{sep}{mtime.ljust(19)}{sep}{cls.ljust(cls_w)}")


class TestPosterSuccessInvariant(unittest.TestCase):
    """Fail if any recent mPoster output indicates a silent failure."""

    def test_recent_mPoster_outputs_are_real_posts(self):
        files = _recent_mPoster_files()
        rows: List[Tuple[str, str, str]] = []
        counts: Dict[str, int] = {
            CLASS_SUCCESS: 0,
            CLASS_DEVICE_CODE: 0,
            CLASS_STALE: 0,
            CLASS_OTHER: 0,
        }
        details: Dict[str, List[str]] = {k: [] for k in counts}

        for path in files:
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as f:
                    content = f.read()
            except OSError as e:
                cls = CLASS_OTHER
                content = f"(read error: {e})"
            else:
                cls = _classify(content)
            counts[cls] += 1
            mtime_iso = datetime.fromtimestamp(
                os.path.getmtime(path)
            ).strftime("%Y-%m-%d %H:%M:%S")
            name = os.path.basename(path)
            rows.append((name, mtime_iso, cls))
            details[cls].append(name)

        print(f"\nPoster output classification (last {WINDOW_DAYS}d, {POSTER_DIR}):")
        _print_table(rows)
        print()
        print(f"  SUCCESS              : {counts[CLASS_SUCCESS]}")
        print(f"  DEVICE_CODE_FAILURE  : {counts[CLASS_DEVICE_CODE]}")
        print(f"  STALE_DATA_REFUSAL   : {counts[CLASS_STALE]}")
        print(f"  OTHER_FAILURE        : {counts[CLASS_OTHER]}")
        print()

        problems: List[str] = []
        if counts[CLASS_DEVICE_CODE] > 0:
            problems.append(
                f"{counts[CLASS_DEVICE_CODE]} mPoster output(s) contain a device-code "
                "prompt -- the harness recorded exit_code=0 but the post NEVER reached "
                "Teams. Files: " + ", ".join(details[CLASS_DEVICE_CODE])
            )
        if counts[CLASS_OTHER] > 0:
            problems.append(
                f"{counts[CLASS_OTHER]} mPoster output(s) match no known pattern "
                "(neither HTTP 201 success nor a recognized refusal). Update the "
                "classifier or fix the failure. Files: "
                + ", ".join(details[CLASS_OTHER])
            )

        self.assertFalse(
            problems,
            "Poster silent-failure detected:\n  - " + "\n  - ".join(problems),
        )


if __name__ == "__main__":
    unittest.main()
