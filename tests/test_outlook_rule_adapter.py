from __future__ import annotations

import json
import os
import subprocess
import unittest
from pathlib import Path


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

    def test_whatif_write_operations_do_not_authenticate_or_mutate(self):
        cases = [
            ["-Operation", "Delete", "-RuleId", "rule-id", "-WhatIf"],
            [
                "-Operation",
                "CreateFromEmail",
                "-RuleName",
                "Move notifications",
                "-SubjectContains",
                "Weekly Feed",
                "-RuleAction",
                "MoveToFolder",
                "-DestinationFolder",
                "archive",
                "-WhatIf",
            ],
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                completed = subprocess.run(
                    [PWSH, "-NoProfile", "-File", SCRIPT, *arguments],
                    check=True,
                    capture_output=True,
                    text=True,
                    encoding="utf-8-sig",
                )
                self.assertIn("What if:", completed.stdout)

    def test_write_contract_has_shouldprocess_readback_and_delete_verification(self):
        source = Path(SCRIPT).read_text(encoding="utf-8-sig")
        self.assertIn("[CmdletBinding(SupportsShouldProcess = $true)]", source)
        for operation in (
            "Create disabled Inbox rule",
            "Create Inbox rule",
            "Update Inbox rule",
            "Enable Inbox rule",
            "Disable Inbox rule",
            "Delete Inbox rule",
        ):
            self.assertIn(f"ShouldProcess(", source)
            self.assertIn(operation, source)
        self.assertGreaterEqual(source.count("Verify-RuleReadback"), 6)
        self.assertIn(
            'Invoke-RulesRequest -Method GET -Uri "$RulesPath/$RuleId"',
            source,
        )
        self.assertIn("Rule still exists after DELETE.", source)
        self.assertIn("Test-IsRuleNotFoundError", source)
        self.assertIn("ErrorItemNotFound", source)
        self.assertIn("if (-not (Test-IsRuleNotFoundError $_))", source)


if __name__ == "__main__":
    unittest.main()
