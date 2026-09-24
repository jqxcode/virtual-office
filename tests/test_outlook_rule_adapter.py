from __future__ import annotations

import json
import os
import subprocess
import unittest


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO_ROOT, "scripts", "outlook", "Manage-InboxRules.ps1")
PWSH = os.environ.get(
    "PWSH_EXE", r"C:\Program Files\PowerShell\7\pwsh.exe"
)


class OutlookRuleAdapterTests(unittest.TestCase):
    def build(self, *args: str) -> dict:
        result = subprocess.run(
            [
                PWSH,
                "-NoProfile",
                "-File",
                SCRIPT,
                "-Operation",
                "BuildFromEmail",
                *args,
            ],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8-sig",
        )
        return json.loads(result.stdout)

    def test_sender_delete_rule_defaults_disabled(self):
        rule = self.build(
            "-RuleName",
            "Delete vendor",
            "-SenderAddress",
            "vendor@example.com",
            "-RuleAction",
            "Delete",
        )
        self.assertFalse(rule["isEnabled"])
        self.assertTrue(rule["actions"]["delete"])
        self.assertEqual(
            rule["conditions"]["fromAddresses"][0]["emailAddress"]["address"],
            "vendor@example.com",
        )

    def test_subject_move_rule_keeps_well_known_folder_for_resolution(self):
        rule = self.build(
            "-RuleName",
            "Move notifications",
            "-SubjectContains",
            "Weekly Feed",
            "-RuleAction",
            "MoveToFolder",
            "-DestinationFolder",
            "archive",
        )
        self.assertEqual(rule["actions"]["moveToFolder"], "archive")
        self.assertEqual(rule["conditions"]["subjectContains"], ["Weekly Feed"])

    def test_rule_can_be_explicitly_enabled_and_stop_processing(self):
        rule = self.build(
            "-RuleName",
            "VIP",
            "-SenderAddress",
            "vip@microsoft.com",
            "-RuleAction",
            "MarkHigh",
            "-EnableRule",
            "-StopProcessingRules",
        )
        self.assertTrue(rule["isEnabled"])
        self.assertEqual(rule["actions"]["markImportance"], "high")
        self.assertTrue(rule["actions"]["stopProcessingRules"])


if __name__ == "__main__":
    unittest.main()
