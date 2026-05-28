"""Schedule-diff guardrail: fail loudly whenever config/schedules.json changes.

Motivation: on 2026-04-14, commit 8447512 silently deleted the bug-autopilot
schedule entries as a "while-we're-here" cleanup inside a larger commit.
The change went unnoticed for 47 days. This test makes that pattern
impossible by forcing every schedules.json edit to also bump
tests/fixtures/schedules.sha256.txt -- which a reviewer can't miss.

If this test fails:
  1. Confirm the schedules.json change was intentional.
  2. Re-generate the fixture with:
       python -c "import hashlib,pathlib; \
         p=pathlib.Path('config/schedules.json'); \
         print(hashlib.sha256(p.read_bytes()).hexdigest())" \
         > tests/fixtures/schedules.sha256.txt
  3. Document the schedule change in the commit message.
"""
from __future__ import annotations

import hashlib
import os
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEDULES_PATH = os.path.join(REPO_ROOT, "config", "schedules.json")
FIXTURE_PATH = os.path.join(
    REPO_ROOT, "tests", "fixtures", "schedules.sha256.txt"
)


def sha256_of_file(path: str) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


class TestScheduleDiffGuard(unittest.TestCase):
    def test_schedules_json_matches_expected_sha(self):
        self.assertTrue(
            os.path.exists(SCHEDULES_PATH),
            f"config/schedules.json missing at {SCHEDULES_PATH}",
        )
        self.assertTrue(
            os.path.exists(FIXTURE_PATH),
            f"Expected SHA fixture missing at {FIXTURE_PATH}. "
            f"Create it by running:\n"
            f"  python -c \"import hashlib,pathlib;"
            f"print(hashlib.sha256(pathlib.Path("
            f"'config/schedules.json').read_bytes()).hexdigest())\" "
            f"> tests/fixtures/schedules.sha256.txt",
        )

        actual = sha256_of_file(SCHEDULES_PATH)
        with open(FIXTURE_PATH, encoding="utf-8") as f:
            expected = f.read().strip().split()[0]  # tolerate trailing newline / whitespace

        self.assertEqual(
            actual,
            expected,
            (
                "\n\nschedules.json changed -- if intentional, update "
                "tests/fixtures/schedules.sha256.txt and document the change "
                "in the commit message.\n"
                f"  expected: {expected}\n"
                f"  actual:   {actual}\n"
                "Regenerate fixture with:\n"
                "  python -c \"import hashlib,pathlib;"
                "print(hashlib.sha256(pathlib.Path("
                "'config/schedules.json').read_bytes()).hexdigest())\" "
                "> tests/fixtures/schedules.sha256.txt"
            ),
        )


if __name__ == "__main__":
    unittest.main()
