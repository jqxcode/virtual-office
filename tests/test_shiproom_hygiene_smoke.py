"""End-to-end smoke test for the pinned shiproom hygiene runner.

Motivation
----------
On 2026-05-28 the scheduled hygiene job aborted with
``FileNotFoundError: [WinError 2] The system cannot find the file specified``
even though 18 unit tests passed. The root cause was that
``subprocess.check_output(["az", ...])`` does not consult ``PATHEXT`` and
therefore does not resolve ``az.cmd`` on Windows. The unit suite covered
WIQL safety primitives but never actually invoked the runner end to end,
so the integration gap was invisible.

This smoke test launches the runner as a real subprocess in --dry-run
mode and asserts:

  * exit code 0
  * ``hygiene-teams-summary.json`` is written into the output directory
  * the ``generated`` timestamp in that JSON parses as within the last
    10 minutes
  * stdout contains the runner's completion marker (``Completed:``)

The test writes to a tmp output directory so the canonical
``output/mScrumMaster/`` artefacts are never disturbed.

The test is skipped (not silently passed) when ``az`` is not authed on
the host, because the runner cannot acquire an ADO token in that case.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from typing import Optional

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNNER_PATH = os.path.join(REPO_ROOT, "runner", "shiproom_hygiene_check.py")


def _resolve_az():
    # type: () -> Optional[str]
    return shutil.which("az") or (shutil.which("az.cmd") if os.name == "nt" else None)


def has_az_token():
    # type: () -> bool
    """Return True iff `az account get-access-token` succeeds for the
    ADO resource the runner needs (499b84ac-...)."""
    az = _resolve_az()
    if not az:
        return False
    try:
        r = subprocess.run(
            [
                az, "account", "get-access-token",
                "--resource", "499b84ac-1321-427f-aa17-267ca6975798",
                "--query", "accessToken", "-o", "tsv",
            ],
            shell=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        return r.returncode == 0 and bool(r.stdout.strip())
    except Exception:
        return False


class TestShiproomHygieneSmoke(unittest.TestCase):
    """Run the pinned runner end-to-end with --dry-run."""

    @unittest.skipUnless(has_az_token(), "az not authed for ADO resource (499b84ac-...)")
    def test_dry_run_completes_and_writes_summary(self):
        self.assertTrue(
            os.path.exists(RUNNER_PATH),
            "runner not found at {0}".format(RUNNER_PATH),
        )

        with tempfile.TemporaryDirectory(prefix="hygiene-smoke-") as tmp:
            output_dir = os.path.join(tmp, "mScrumMaster")
            os.makedirs(output_dir, exist_ok=True)
            summary_path = os.path.join(output_dir, "hygiene-teams-summary.json")
            self.assertFalse(
                os.path.exists(summary_path),
                "tmp dir should not pre-contain summary",
            )

            before = datetime.now(timezone.utc)

            proc = subprocess.run(
                [
                    sys.executable,
                    RUNNER_PATH,
                    "--dry-run",
                    "--output-dir", output_dir,
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=600,
            )

            after = datetime.now(timezone.utc)

            # exit code 0
            self.assertEqual(
                proc.returncode, 0,
                "runner exited {0}\nSTDOUT:\n{1}\nSTDERR:\n{2}".format(
                    proc.returncode, proc.stdout[-4000:], proc.stderr[-4000:],
                ),
            )

            # success marker present in stdout
            self.assertIn(
                "Completed:", proc.stdout,
                "runner stdout missing 'Completed:' marker.\n"
                "STDOUT tail:\n{0}".format(proc.stdout[-2000:]),
            )

            # summary file was created during the run
            self.assertTrue(
                os.path.exists(summary_path),
                "summary not written to {0}".format(summary_path),
            )

            with open(summary_path, "r", encoding="utf-8") as f:
                summary = json.load(f)

            # generated timestamp parses and is within the last 10 minutes
            self.assertIn("generated", summary, "summary missing 'generated' field")
            gen_str = summary["generated"]
            try:
                gen_dt = datetime.fromisoformat(gen_str)
            except ValueError as exc:
                self.fail("generated timestamp not ISO-8601: {0!r} ({1})".format(
                    gen_str, exc,
                ))

            if gen_dt.tzinfo is None:
                gen_dt = gen_dt.replace(tzinfo=timezone.utc)

            now_utc = datetime.now(timezone.utc)
            age = now_utc - gen_dt
            self.assertGreaterEqual(
                age, timedelta(seconds=-60),
                "generated timestamp is in the future: {0}".format(gen_str),
            )
            self.assertLess(
                age, timedelta(minutes=10),
                "generated timestamp older than 10 min: {0} (age={1})".format(
                    gen_str, age,
                ),
            )

            # dryRun flag must be honoured -- no real mutations
            self.assertTrue(
                summary.get("dryRun"),
                "summary dryRun should be True under --dry-run",
            )

            # sanity: runner ran between before and after
            self.assertLessEqual(before - timedelta(seconds=5), gen_dt)
            self.assertLessEqual(gen_dt, after + timedelta(seconds=5))


if __name__ == "__main__":
    unittest.main()
