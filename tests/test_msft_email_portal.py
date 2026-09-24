from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
GENERATOR = Path(
    r"C:\Users\qitxu\.copilot\session-state"
    r"\244f18cc-6067-434f-a320-412ada5fc3bd\files"
    r"\generate_unread_triage.py"
)
THREAD_PREPARER = GENERATOR.with_name("prepare_thread_summary_input.py")
SERVER = Path(
    r"C:\Users\qitxu\OneDrive - Microsoft\2-AI\email-triage"
    r"\email-triage-server.py"
)
STATE_DIR = REPO_ROOT / "state" / "email-triage"

sys.path.insert(0, str(REPO_ROOT / "scripts"))
from email_triage_rules import (
    is_global_noise,
    is_meeting_noise,
    ndr_noise_reason,
    normalized_thread_key,
)


def load_generator():
    spec = importlib.util.spec_from_file_location("generate_unread_triage", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


EXTERNAL_PORTAL_ASSETS_AVAILABLE = all(
    path.exists() for path in (GENERATOR, THREAD_PREPARER, SERVER)
)
GEN = load_generator() if EXTERNAL_PORTAL_ASSETS_AVAILABLE else None


def load_server():
    spec = importlib.util.spec_from_file_location("email_triage_server", SERVER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module

BOFA_EXPECTED_SUMMARY = {
    "currentStatus": "最新 BofA 测试显示，禁用后 CAPTCHA 仍然处于启用状态。",
    "latestDecision": "尚未确认停用日期；10/5 只是提议日期，并未确认。",
    "requestOwner": "Zoran / engineering",
    "joshAction": "无需你直接回复；跟踪工程调查和修复进度。",
    "deadline": "10/5（提议，未确认）",
    "nextStep": "Zoran / engineering 调查为何禁用未生效并修复，然后由 BofA 重新验证。",
    "risk": "CAPTCHA 验证和停用进度延迟。",
    "evidence": [
        "最新 BofA 测试明确说明 CAPTCHA 仍然 active。",
        "线程要求 Zoran / engineering 调查并修复。",
        "10/5 被描述为 proposed date，而不是 confirmed date。",
    ],
}

WELLS_EXPECTED_SUMMARY = {
    "currentStatus": "Wells Fargo 的最新未读请求已明确交给 Scott Sanders 和 Microsoft Team。",
    "latestDecision": "未明确",
    "requestOwner": "Scott Sanders",
    "joshAction": "无需你回复；由 Scott Sanders 跟进该请求。",
    "deadline": "未明确",
    "nextStep": "Scott Sanders 与 Microsoft Team 评估并回复 Wells Fargo。",
    "risk": "无明确风险",
    "evidence": ["最新消息正文明确写给 @Scott Sanders and Microsoft Team。"],
}


def message(
    identifier,
    subject,
    preview,
    received,
    sender="sender@microsoft.com",
    sender_name="Sender",
    to=None,
    **extra,
):
    payload = {
        "id": identifier,
        "subject": subject,
        "bodyPreview": preview,
        "receivedDateTime": received,
        "importance": "normal",
        "isRead": False,
        "from": {
            "emailAddress": {
                "name": sender_name,
                "address": sender,
            }
        },
        "toRecipients": [
            {"emailAddress": {"name": name, "address": address}}
            for name, address in (to or [])
        ],
        "ccRecipients": [],
        "webLink": (
            "https://outlook.office.com/mail/deeplink/read/"
            + identifier
        ),
    }
    payload.update(extra)
    return payload


def synthetic_messages():
    return [
        message(
            "wells-new",
            "RE: Wells Fargo Teams CAPTCHA follow up",
            "@Scott Sanders and Microsoft Team, please investigate and respond "
            "with the latest status.",
            "2026-09-24T20:00:00Z",
            sender="jorge.francke@wellsfargo.com",
            sender_name="Francke, Jorge",
            to=[("Josh Xu", "josh.xu@microsoft.com")],
        ),
        message(
            "wells-old",
            "Re: Wells Fargo Teams CAPTCHA follow up",
            "Prior customer context for the CAPTCHA rollout.",
            "2026-09-24T19:00:00Z",
            sender="vivek.mohan@microsoft.com",
            sender_name="Vivek Mohan",
        ),
        message(
            "bofa-new",
            "RE: Teams Captcha decommission update / AI Suspicious Threat Lobby OTP Update",
            "Latest BofA testing shows CAPTCHA remains active despite disablement. "
            "Zoran and engineering need to investigate and fix this before BofA "
            "can validate. 10/5 was proposed, not confirmed.",
            "2026-09-24T18:00:00Z",
            sender="valerie.little@bofa.com",
            sender_name="Little, Valerie",
        ),
        message(
            "bofa-old",
            "FW: Teams Captcha decommission update / AI Suspicious Threat Lobby OTP Update",
            "Earlier plan proposed decommission on 10/5.",
            "2026-09-23T18:00:00Z",
            sender="zoranc@microsoft.com",
            sender_name="Zoran Cvetkovic",
        ),
        message(
            "jessie",
            "Teams Meeting Join: Jessie has requested billing Account for Microsoft internal purposes",
            "Jessie requested a billing account. Review the request before taking action.",
            "2026-09-24T17:00:00Z",
            sender="microsoft-noreply@microsoft.com",
            sender_name="Microsoft",
        ),
        message(
            "single",
            "Engineering weekly status",
            "Current engineering status; no action requested.",
            "2026-09-24T16:00:00Z",
        ),
        message(
            "meeting-noise",
            "Plain meeting object",
            "Join https://teams.microsoft.com/meet/123 Meeting ID: 123 Passcode: 456",
            "2026-09-24T15:00:00Z",
        ),
        message(
            "autoreply-noise",
            "Automatic reply: Josh:Naveen",
            "I am out of office until Oct 9.",
            "2026-09-24T14:30:00Z",
            sender="navshri@microsoft.com",
            sender_name="Naveen",
        ),
        message(
            "oof-noise",
            "Out of Office: Wells Fargo Teams CAPTCHA follow up",
            "I am away from the office.",
            "2026-09-24T14:15:00Z",
            sender="partner@example.com",
            sender_name="Partner",
        ),
        message(
            "ndr-noise",
            "Undeliverable: Bot Protection Shiproom",
            "Your message couldn't be delivered because the recipient wasn't found. "
            "Recipient Unknown.",
            "2026-09-24T14:00:00Z",
            sender="MicrosoftExchange329e71ec88ae4615bbc36ab6ce41109e@service.microsoft.com",
            sender_name="Microsoft Outlook",
        ),
    ]


class TestMeetingNoiseClassifier(unittest.TestCase):
    def test_canonical_noise_cases_and_quoted_history_limit(self):
        positives = [
            {"@odata.type": "#microsoft.graph.eventMessageResponse"},
            {"subject": "Canceled: Customer sync"},
            {"subject": "Meeting Forward Notification: Customer sync"},
            {"subject": "Automatic reply: Bot Protection Shiproom"},
            {
                "subject": "Automatic reply: Josh:Naveen",
                "from": {
                    "emailAddress": {
                        "name": "Naveen",
                        "address": "navshri@microsoft.com",
                    }
                },
                "bodyPreview": "OOF until Oct 9.",
            },
            {"subject": "Out of Office: Customer sync"},
            {
                "subject": "Customer sync",
                "bodyPreview": (
                    "Join https://teams.microsoft.com/meet/123 "
                    "Meeting ID: 123 Passcode: 456"
                ),
            },
            {
                "subject": "Customer sync",
                "bodyPreview": (
                    "________________________________ Join "
                    "https://teams.microsoft.com/l/meetup-join/123 "
                    "Meeting ID: 123 Passcode: 456"
                ),
            },
        ]
        for fixture in positives:
            with self.subTest(fixture=fixture):
                self.assertTrue(is_meeting_noise(fixture))

        substantive_with_quoted_meeting = {
            "subject": "CAPTCHA investigation update",
            "bodyPreview": (
                "The customer reproduced the issue and engineering is investigating. "
                "-----Original Message----- Join "
                "https://teams.microsoft.com/meet/123 Meeting ID: 123 Passcode: 456"
            ),
        }
        self.assertFalse(is_meeting_noise(substantive_with_quoted_meeting))


class TestNdrNoiseClassifier(unittest.TestCase):
    def test_verified_exchange_ndr_is_global_noise(self):
        fixture = synthetic_messages()[-1]
        self.assertEqual(
            ndr_noise_reason(fixture),
            "verified Microsoft Exchange NDR / bounce",
        )
        self.assertTrue(is_global_noise(fixture))

    def test_undeliverable_requires_sender_and_failure_evidence(self):
        base = message(
            "ndr-negative",
            "Undeliverable: Project update",
            "Your message couldn't be delivered.",
            "2026-09-24T14:00:00Z",
            sender="person@example.com",
            sender_name="External Sender",
        )
        self.assertIsNone(ndr_noise_reason(base))

        outlook_without_evidence = dict(base)
        outlook_without_evidence["from"] = {
            "emailAddress": {
                "name": "Microsoft Outlook",
                "address": "MicrosoftExchange123@service.microsoft.com",
            }
        }
        outlook_without_evidence["bodyPreview"] = "Routine project status."
        self.assertIsNone(ndr_noise_reason(outlook_without_evidence))

        outlook_display_name = dict(outlook_without_evidence)
        outlook_display_name["from"] = {
            "emailAddress": {
                "name": "Microsoft Outlook",
                "address": "postmaster@contoso.invalid",
            }
        }
        outlook_display_name["bodyPreview"] = "Recipient Unknown."
        self.assertIsNotNone(ndr_noise_reason(outlook_display_name))

    def test_skill_and_job_use_canonical_ndr_rule(self):
        skill = (REPO_ROOT / "skills" / "MSFT-email.md").read_text(
            encoding="utf-8"
        )
        jobs = json.loads(
            (REPO_ROOT / "config" / "jobs" / "pEmailer.json").read_text(
                encoding="utf-8"
            )
        )
        job_prompt = jobs["jobs"]["MSFT-email"]["prompt"]
        for content in (skill, job_prompt):
            self.assertIn("global_noise_reason", content)
            self.assertIn("Undeliverable:", content)
            self.assertIn("MicrosoftExchange*@service.microsoft.com", content)
            self.assertIn("Recipient Unknown", content)
            self.assertIn("Automatic reply: Josh:Naveen", content)
            self.assertIn("navshri@microsoft.com", content)

    def test_deployment_requires_idle_server_reload(self):
        skill = (REPO_ROOT / "skills" / "MSFT-email.md").read_text(
            encoding="utf-8"
        )
        jobs = json.loads(
            (REPO_ROOT / "config" / "jobs" / "pEmailer.json").read_text(
                encoding="utf-8"
            )
        )
        job_prompt = jobs["jobs"]["MSFT-email"]["prompt"]
        for content in (skill, job_prompt):
            self.assertIn("/api/status", content)
            self.assertIn("queued", content)
            self.assertIn("running", content)
            self.assertRegex(content, r"(?i)idle")
            self.assertRegex(content, r"(?i)restart")


@unittest.skipUnless(
    EXTERNAL_PORTAL_ASSETS_AVAILABLE,
    "Personal email-triage portal assets are not installed on this machine.",
)
class TestThreadClassification(unittest.TestCase):
    def test_no_action_required_negates_action_required_substring(self):
        fixture = message(
            "no-action",
            "[No Action Required] Security Group FFv2 Flight",
            "No action needed — this is an FYI only.",
            "2026-09-24T20:00:00Z",
        )
        self.assertNotEqual(GEN.classify_semantic(fixture), "action")
        self.assertFalse(GEN.requires_reply(fixture))

    def test_normalization_global_uniqueness_and_scott_not_josh(self):
        messages = [
            item for item in synthetic_messages() if not is_global_noise(item)
        ]
        categorized, _ = GEN.categorize_threads(messages)
        occurrences = {}
        for category, records in categorized.items():
            for record in records:
                occurrences.setdefault(record["key"], []).append(category)
        self.assertTrue(all(len(categories) == 1 for categories in occurrences.values()))

        wells_key = normalized_thread_key("Wells Fargo Teams CAPTCHA follow up")
        self.assertEqual(occurrences[wells_key], ["customer"])
        wells = next(
            record
            for record in categorized["customer"]
            if record["key"] == wells_key
        )
        self.assertEqual(len(wells["messages"]), 2)
        self.assertFalse(GEN.requires_reply(wells["messages"][0]))

        josh_request = message(
            "josh-request",
            "Review needed",
            "@Josh, please review and reply.",
            "2026-09-24T21:00:00Z",
        )
        self.assertTrue(GEN.requires_reply(josh_request))

    def test_action_precedes_bulk(self):
        fixture = message(
            "bulk-action",
            "Action required: renew access",
            "Newsletter recipients must renew by Friday. Unsubscribe here.",
            "2026-09-24T21:00:00Z",
            sender="no-reply@example.com",
        )
        categorized, _ = GEN.categorize_threads([fixture])
        self.assertEqual([r["key"] for r in categorized["action"]], [
            normalized_thread_key(fixture["subject"])
        ])
        self.assertEqual(categorized["bulk_low"], [])

    def test_duplicate_thread_invariant_rejects_split_categories(self):
        record = {"key": "same-thread", "messages": []}
        categorized = {key: [] for key in GEN.CATEGORIES}
        categorized["customer"].append(record)
        categorized["engineering"].append(record)
        with self.assertRaisesRegex(ValueError, "appears in both"):
            GEN.assert_unique_thread_categories(categorized)

    def test_action_hook_candidate_and_safe_link(self):
        fixture = synthetic_messages()[4]
        self.assertTrue(GEN.has_action_hook_candidate(fixture))
        self.assertEqual(GEN.safe_message_web_link(fixture), fixture["webLink"])
        fixture["webLink"] = "javascript:approve()"
        self.assertEqual(GEN.safe_message_web_link(fixture), "")


@unittest.skipUnless(
    EXTERNAL_PORTAL_ASSETS_AVAILABLE,
    "Personal email-triage portal assets are not installed on this machine.",
)
class TestStructuredSummaryPipeline(unittest.TestCase):
    def test_required_summary_fields(self):
        key = normalized_thread_key("Example")
        GEN.validate_thread_summaries({key: BOFA_EXPECTED_SUMMARY}, {key})
        broken = dict(BOFA_EXPECTED_SUMMARY)
        broken.pop("risk")
        with self.assertRaisesRegex(ValueError, "missing fields: risk"):
            GEN.validate_thread_summaries({key: broken}, {key})

    def test_server_refresh_prompt_uses_canonical_pipeline(self):
        server = load_server()
        prompt = server.make_prompt(
            Path("plan.json"),
            Path("thread-input.json"),
            Path("thread-summaries.json"),
        )
        self.assertIn("scripts/email_triage_rules.py", prompt)
        self.assertIn("quoted history", prompt)
        self.assertIn("Undeliverable:", prompt)
        self.assertIn("MicrosoftExchange*@service.microsoft.com", prompt)
        self.assertIn("Automatic reply:/Auto reply:/Autoreply:/Out of Office:", prompt)
        self.assertIn("prepare_thread_summary_input.py", prompt)
        self.assertIn("--click-events", prompt)
        self.assertIn("owa-clicks.jsonl", prompt)
        self.assertIn("--thread-summaries", prompt)
        self.assertIn("thread-summary-prompt.md", prompt)

    def test_cli_pipeline_generates_verified_fixture_html(self):
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix="portal-test-", dir=str(STATE_DIR)
        ) as directory:
            root = Path(directory)
            page_path = root / "page.json"
            thread_input = root / "thread-input.json"
            summaries_path = root / "thread-summaries.json"
            output_path = root / "report.html"
            click_events = root / "owa-clicks.jsonl"
            messages = synthetic_messages()
            page_path.write_text(
                json.dumps(
                    {
                        "results": [
                            {
                                "data": {
                                    "totalItemCount": len(messages),
                                    "unreadItemCount": len(messages),
                                }
                            },
                            {"data": {"value": messages}},
                        ]
                    }
                ),
                encoding="utf-8",
            )
            wells_key = normalized_thread_key(
                "Wells Fargo Teams CAPTCHA follow up"
            )
            click_events.write_text(
                "\n".join(
                    json.dumps(
                        {
                            "timestamp": timestamp,
                            "messageId": "wells-new",
                            "normalizedThread": wells_key,
                            "category": "customer",
                            "subject": "RE: Wells Fargo Teams CAPTCHA follow up",
                            "sender": "jorge.francke@wellsfargo.com",
                            "linkType": "owa",
                            "reportSnapshot": "fixture-v1",
                        }
                    )
                    for timestamp in (
                        "2026-09-24T12:00:00-07:00",
                        "2026-09-24T13:30:00-07:00",
                    )
                )
                + "\n",
                encoding="utf-8",
            )

            subprocess.run(
                [
                    sys.executable,
                    str(THREAD_PREPARER),
                    "--output",
                    str(thread_input),
                    "--click-events",
                    str(click_events),
                    str(page_path),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            prepared = json.loads(thread_input.read_text(encoding="utf-8"))
            prepared_keys = {thread["threadKey"] for thread in prepared}
            bofa_key = normalized_thread_key(
                "Teams Captcha decommission update / "
                "AI Suspicious Threat Lobby OTP Update"
            )
            self.assertEqual(prepared_keys, {wells_key, bofa_key})
            wells_input = next(
                thread for thread in prepared if thread["threadKey"] == wells_key
            )
            self.assertEqual(wells_input["owaClickStats"]["count"], 2)
            self.assertEqual(
                wells_input["owaClickStats"]["lastClickAt"],
                "2026-09-24T13:30:00-07:00",
            )
            clicked_message = next(
                item
                for item in wells_input["messages"]
                if item["messageId"] == "wells-new"
            )
            self.assertEqual(clicked_message["owaClickStats"]["count"], 2)
            self.assertEqual(
                clicked_message["owaClickStats"]["lastClickAt"],
                "2026-09-24T13:30:00-07:00",
            )

            summaries_path.write_text(
                json.dumps(
                    {
                        wells_key: WELLS_EXPECTED_SUMMARY,
                        bofa_key: BOFA_EXPECTED_SUMMARY,
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(GENERATOR),
                    "--output",
                    str(output_path),
                    "--thread-summaries",
                    str(summaries_path),
                    str(page_path),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            result = json.loads(completed.stdout)
            self.assertEqual(result["suppressedMeetingNoise"], 3)
            self.assertEqual(result["suppressedNdrNoise"], 1)
            self.assertEqual(result["suppressedGlobalNoise"], 4)
            html = output_path.read_text(encoding="utf-8")

            self.assertEqual(
                html.count("<h3>Wells Fargo Teams CAPTCHA follow up</h3>"), 1
            )
            self.assertEqual(html.count('data-id="wells-new"'), 1)
            self.assertEqual(html.count('data-id="wells-old"'), 1)
            self.assertNotRegex(
                html,
                r'data-category="reply_required"[^>]*data-subject="RE: Wells',
            )
            self.assertIn(BOFA_EXPECTED_SUMMARY["currentStatus"], html)
            self.assertIn(BOFA_EXPECTED_SUMMARY["nextStep"], html)
            self.assertIn(BOFA_EXPECTED_SUMMARY["risk"], html)
            self.assertIn("10/5（提议，未确认）", html)
            for label in (
                "当前状态",
                "最新决定",
                "请求对象",
                "Josh 的 Action",
                "截止时间",
                "下一步",
                "风险",
            ):
                self.assertIn(label, html)
            self.assertIn("Scott Sanders", html)
            self.assertEqual(html.count('data-id="single"'), 1)
            self.assertNotIn('data-id="meeting-noise"', html)
            self.assertNotIn('data-id="autoreply-noise"', html)
            self.assertNotIn('data-id="oof-noise"', html)
            self.assertNotIn('data-id="ndr-noise"', html)
            self.assertNotIn("Automatic reply: Josh:Naveen", html)
            self.assertNotIn("Out of Office: Wells Fargo", html)
            self.assertNotIn("Undeliverable: Bot Protection Shiproom", html)
            self.assertIn('id="execute"', html)
            self.assertIn("fetch('/api/execute'", html)
            self.assertIn("state.status === 'running' || state.status === 'queued'", html)
            self.assertIn("document.getElementById('execute').disabled = true", html)
            self.assertNotIn("outlooktriage://", html)
            self.assertIn(
                '<button type="button" class="btn primary open-outlook"',
                html,
            )
            self.assertIn("fetch('/api/open-outlook'", html)
            self.assertIn("navigator.sendBeacon(", html)
            self.assertIn("'/api/track-click'", html)
            self.assertIn("window.open(link.href", html)
            self.assertLess(
                html.index("navigator.sendBeacon("),
                html.index("window.open(link.href"),
            )
            self.assertNotIn("fetch('/api/click-stats'", html)
            self.assertNotIn("网页打开 0 次", html)
            self.assertIn('data-normalized-thread="', html)
            self.assertIn('data-report-snapshot="', html)
            self.assertIn('id="category-reply_required"', html)
            self.assertIn('id="category-bulk_low"', html)
            self.assertIn('class="single-message-thread"', html)

            jessie_card = re.search(
                r'<article class="message"[^>]*data-id="jessie".*?</article>',
                html,
                re.S,
            )
            self.assertIsNotNone(jessie_card)
            self.assertIn("审批 / 操作入口", jessie_card.group(0))
            self.assertIn(
                "https://outlook.office.com/mail/deeplink/read/jessie",
                jessie_card.group(0),
            )


@unittest.skipUnless(
    EXTERNAL_PORTAL_ASSETS_AVAILABLE,
    "Personal email-triage portal assets are not installed on this machine.",
)
class TestLocalServerApis(unittest.TestCase):
    def test_open_request_validation_and_safe_helper_invocation(self):
        server = load_server()
        with self.assertRaisesRegex(ValueError, "sender"):
            server.validate_open_outlook(
                {"id": "message-1", "subject": "Exact subject"}
            )
        with self.assertRaisesRegex(ValueError, "control character"):
            server.validate_open_outlook(
                {
                    "id": "message-1",
                    "subject": "Exact subject\nInjected",
                    "sender": "sender@example.com",
                }
            )

        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix="portal-helper-test-", dir=str(STATE_DIR)
        ) as directory:
            helper = Path(directory) / "helper.ps1"
            helper.write_text("# test helper", encoding="utf-8")
            server.OUTLOOK_HELPER = helper
            server.POWERSHELL = "pwsh-test.exe"
            completed = mock.Mock(
                returncode=0,
                stdout='{"ok":true,"detail":"verified"}\n',
                stderr="",
            )
            with mock.patch.object(
                server.subprocess, "run", return_value=completed
            ) as run:
                result = server.open_outlook_message(
                    {
                        "id": "message-1",
                        "subject": 'Exact "quoted" subject',
                        "sender": "sender@example.com",
                    }
                )
            self.assertTrue(result["ok"])
            command = run.call_args.args[0]
            self.assertEqual(command[0], "pwsh-test.exe")
            self.assertIn("-Sta", command)
            self.assertEqual(command[-4:], [
                "-Subject",
                'Exact "quoted" subject',
                "-Sender",
                "sender@example.com",
            ])
            self.assertFalse(run.call_args.kwargs["shell"])

    def test_isolated_http_click_tracking_and_invalid_open(self):
        server = load_server()
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix="portal-server-test-", dir=str(STATE_DIR)
        ) as directory:
            root = Path(directory)
            server.STATE_DIR = root
            server.STATE_FILE = root / "server-state.json"
            server.CLICK_EVENTS = root / "owa-clicks.jsonl"
            httpd = server.ThreadingHTTPServer(
                ("127.0.0.1", 0), server.Handler
            )
            thread = threading.Thread(target=httpd.serve_forever, daemon=True)
            thread.start()
            base = f"http://127.0.0.1:{httpd.server_address[1]}"
            try:
                invalid = urllib.request.Request(
                    base + "/api/open-outlook",
                    data=json.dumps(
                        {"id": "message-1", "subject": "Exact subject"}
                    ).encode(),
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                with self.assertRaises(urllib.error.HTTPError) as raised:
                    urllib.request.urlopen(invalid, timeout=5)
                self.assertEqual(raised.exception.code, 400)
                error = json.loads(raised.exception.read().decode())
                self.assertTrue(error["owaFallback"])

                payload = {
                    "messageId": "message-1",
                    "normalizedThread": "normalized thread",
                    "category": "customer",
                    "subject": "Exact subject",
                    "sender": "sender@example.com",
                    "linkType": "owa",
                    "reportSnapshot": "fixture-v1",
                }
                for _ in range(2):
                    request = urllib.request.Request(
                        base + "/api/track-click",
                        data=json.dumps(payload).encode(),
                        headers={"Content-Type": "application/json"},
                        method="POST",
                    )
                    with urllib.request.urlopen(request, timeout=5) as response:
                        self.assertEqual(response.status, 202)
                with urllib.request.urlopen(
                    base + "/api/click-stats", timeout=5
                ) as response:
                    stats = json.load(response)
                self.assertEqual(stats["messages"]["message-1"]["count"], 2)
                self.assertEqual(
                    stats["threads"]["normalized thread"]["count"], 2
                )
                self.assertTrue(
                    stats["messages"]["message-1"]["lastClickAt"]
                )
                events = [
                    json.loads(line)
                    for line in server.CLICK_EVENTS.read_text(
                        encoding="utf-8"
                    ).splitlines()
                ]
                self.assertEqual(len(events), 2)
                self.assertEqual(events[0]["reportSnapshot"], "fixture-v1")
            finally:
                httpd.shutdown()
                httpd.server_close()
                thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
