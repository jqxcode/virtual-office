"""Unit tests for the pinned shiproom hygiene checker.

Verifies the safety-policy primitives that prevented the 2026-05-22
1446-item cross-area incident:

  * validate_wiql_has_area_filter() catches a WIQL missing the area filter
  * area_path_allowed() rejects out-of-scope area paths (e.g. iOS, Web)
  * compute_allowed_areas() drops Notes on/after 2026-06-01
  * MutationController stops at the configured PATCH cap
"""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from datetime import date
from typing import List

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO_ROOT, "runner"))

import shiproom_hygiene_check as shc  # noqa: E402


# ---------------------------------------------------------------------------
# validate_wiql_has_area_filter
# ---------------------------------------------------------------------------


class TestValidateWiqlHasAreaFilter(unittest.TestCase):
    def test_returns_false_when_no_area_filter(self):
        wiql = (
            "SELECT [System.Id] FROM workitems "
            "WHERE [System.State] = 'Resolved'"
        )
        self.assertFalse(shc.validate_wiql_has_area_filter(wiql))

    def test_returns_false_on_empty_input(self):
        self.assertFalse(shc.validate_wiql_has_area_filter(""))

    def test_returns_true_when_area_filter_present(self):
        wiql = (
            "SELECT [System.Id] FROM workitems "
            "WHERE [System.State] = 'Resolved' "
            "AND [System.AreaPath] UNDER 'MSTeams\\Foo\\Bar'"
        )
        self.assertTrue(shc.validate_wiql_has_area_filter(wiql))

    def test_link_query_requires_source_token(self):
        wiql_workitems_token_only = (
            "SELECT [System.Id] FROM workitemLinks "
            "WHERE [System.AreaPath] UNDER 'X'"
        )
        # For link queries we expect [Source].[System.AreaPath] UNDER
        self.assertFalse(
            shc.validate_wiql_has_area_filter(wiql_workitems_token_only, is_link_query=True)
        )

        wiql_correct_link = (
            "SELECT [System.Id] FROM workitemLinks "
            "WHERE ([Source].[System.AreaPath] UNDER 'X')"
        )
        self.assertTrue(
            shc.validate_wiql_has_area_filter(wiql_correct_link, is_link_query=True)
        )

    def test_all_pinned_wiql_templates_pass_validation(self):
        # Render each constant with a placeholder so we can assert the
        # literal token is present. This guards against future edits
        # that strip the area clause.
        area = "MSTeams\\Calling Meeting Devices (CMD)\\Meetings\\Meeting Join\\Fundamentals"
        sem = "MSTeams\\2026\\H1"
        prev = sem + r"\Q2\Sprint X"
        curr = sem + r"\Q2\Sprint Y"

        link_q = shc.WIQL_CHECK1_LINKS.format(area=area)
        self.assertTrue(shc.validate_wiql_has_area_filter(link_q, is_link_query=True))

        for tmpl, kwargs in [
            (shc.WIQL_CHECK2_RESOLVED, {"area": area}),
            (shc.WIQL_CHECK2B_BLOCKED_FEATURES, {"area": area}),
            (shc.WIQL_CHECK3_PREV_SPRINT, {"prev": prev, "area": area}),
            (shc.WIQL_CHECK4_CURRENT_TASKS, {"current": curr, "area": area}),
            (shc.WIQL_CHECK5_BUGS_NOT_CURRENT, {"current": curr, "area": area}),
            (shc.WIQL_CHECK6_STALE_TASKS, {"semester": sem, "area": area}),
            (shc.WIQL_CHECK7_PROPOSED_BUGS, {"area": area}),
            (shc.WIQL_CHECK8_COMMITTED_OUTSIDE, {"semester": sem, "area": area}),
            (shc.WIQL_CHECK9_STALE_BUGS, {"area": area}),
            (shc.WIQL_CHECK10_RING_DATES, {"semester": sem, "area": area}),
            (shc.WIQL_CHECK11_SIGNOFFS, {"semester": sem, "area": area}),
            (shc.WIQL_CHECK12_RING_ORDERING, {"semester": sem, "area": area}),
            (shc.WIQL_CHECK14_FLAKY_BUGS, {"area": area}),
            (shc.WIQL_CHECK15_ROLLOUT_ACTIVE_MONTH, {"month": curr, "area": area}),
            (shc.WIQL_CHECK17_ZERO_REMAINING, {"area": area}),
            (shc.WIQL_CHECK18_STALE_REMAINING, {"area": area, "stale_days": 30}),
            (shc.WIQL_CHECK20_BACKLOG_ORDER, {"area": area}),
        ]:
            rendered = tmpl.format(**kwargs)
            self.assertTrue(
                shc.validate_wiql_has_area_filter(rendered),
                msg="template missing area filter: {0!r}".format(tmpl[:80]),
            )


# ---------------------------------------------------------------------------
# area_path_allowed
# ---------------------------------------------------------------------------


class TestAreaPathAllowed(unittest.TestCase):
    def setUp(self):
        self.allowed = [shc.AREA_MJ, shc.AREA_NOTES]

    def test_rejects_unrelated_ios_area(self):
        ap = r"MSTeams\Mobile\iOS\Search"
        self.assertFalse(shc.area_path_allowed(ap, self.allowed))

    def test_rejects_other_msteams_area(self):
        for ap in [
            r"MSTeams\Web\Authentication",
            r"MSTeams\Calling Meeting Devices (CMD)\Calling\Foo",
            r"MSTeams\Telemetry\Pipeline",
        ]:
            self.assertFalse(shc.area_path_allowed(ap, self.allowed), msg=ap)

    def test_accepts_exact_match(self):
        self.assertTrue(shc.area_path_allowed(shc.AREA_MJ, self.allowed))
        self.assertTrue(shc.area_path_allowed(shc.AREA_NOTES, self.allowed))

    def test_accepts_descendant(self):
        descendant = shc.AREA_MJ + r"\Subteam\Foo"
        self.assertTrue(shc.area_path_allowed(descendant, self.allowed))

    def test_rejects_partial_prefix_not_separated_by_backslash(self):
        # e.g. "Meeting Join\Fundamentals" + "X" must not be considered
        # a descendant of "Meeting Join\Fundamentals".
        confusing = shc.AREA_MJ + "X"
        self.assertFalse(shc.area_path_allowed(confusing, self.allowed))

    def test_rejects_empty(self):
        self.assertFalse(shc.area_path_allowed("", self.allowed))
        self.assertFalse(shc.area_path_allowed(shc.AREA_MJ, []))


# ---------------------------------------------------------------------------
# compute_allowed_areas (date-driven)
# ---------------------------------------------------------------------------


class TestComputeAllowedAreas(unittest.TestCase):
    def test_before_cutoff_includes_notes(self):
        for d in [date(2026, 5, 1), date(2026, 5, 26), date(2026, 5, 31)]:
            areas = shc.compute_allowed_areas(d)
            self.assertIn(shc.AREA_NOTES, areas, msg=d.isoformat())
            self.assertIn(shc.AREA_MJ, areas, msg=d.isoformat())
            self.assertEqual(len(areas), 2, msg=d.isoformat())

    def test_on_or_after_cutoff_excludes_notes(self):
        for d in [date(2026, 6, 1), date(2026, 6, 15), date(2027, 1, 1)]:
            areas = shc.compute_allowed_areas(d)
            self.assertIn(shc.AREA_MJ, areas, msg=d.isoformat())
            self.assertNotIn(shc.AREA_NOTES, areas, msg=d.isoformat())
            self.assertEqual(len(areas), 1, msg=d.isoformat())


# ---------------------------------------------------------------------------
# compute_semester
# ---------------------------------------------------------------------------


class TestComputeSemester(unittest.TestCase):
    def test_h1_through_june(self):
        self.assertEqual(shc.compute_semester(date(2026, 1, 5)), r"MSTeams\2026\H1")
        self.assertEqual(shc.compute_semester(date(2026, 6, 30)), r"MSTeams\2026\H1")

    def test_h2_july_onwards(self):
        self.assertEqual(shc.compute_semester(date(2026, 7, 1)), r"MSTeams\2026\H2")
        self.assertEqual(shc.compute_semester(date(2026, 12, 31)), r"MSTeams\2026\H2")


# ---------------------------------------------------------------------------
# MutationController cap
# ---------------------------------------------------------------------------


class TestAzCommandResolution(unittest.TestCase):
    """Regression: Windows az.cmd resolution (2026-05-28 WinError 2 incident).

    The pinned hygiene runner shells out to `az account get-access-token`
    via subprocess with shell=False. On Windows, `az` is `az.cmd` and
    Python does NOT consult PATHEXT when shell=False, so a bare "az"
    arg fails with [WinError 2]. We resolve via shutil.which up-front.
    """

    def test_az_cmd_is_resolvable(self):
        self.assertIsNotNone(
            shc.AZ_CMD,
            msg="AZ_CMD must resolve to a non-None path; install Azure CLI on the host.",
        )

    def test_az_cmd_ends_with_az_or_az_cmd(self):
        cmd = (shc.AZ_CMD or "").lower()
        self.assertTrue(
            cmd.endswith("az") or cmd.endswith("az.cmd") or cmd.endswith("az.exe"),
            msg="AZ_CMD should end with az / az.cmd / az.exe; got {0!r}".format(shc.AZ_CMD),
        )


class TestMutationCap(unittest.TestCase):
    def _make_controller(self, cap, dry_run=True):
        tmp = tempfile.mkdtemp(prefix="shc-test-")
        plan = os.path.join(tmp, "plan.jsonl")
        audit = os.path.join(tmp, "audit.jsonl")
        return shc.MutationController(plan, audit, cap=cap, dry_run=dry_run), plan, audit

    def test_stops_planning_after_cap(self):
        mc, plan_path, audit_path = self._make_controller(cap=5)
        approved = 0
        rejected = 0
        for i in range(20):
            ok = mc.plan({"event": "plan_patch", "check": "test", "id": i})
            if ok:
                approved += 1
                mc.record({"check": "test", "id": i, "ok": True})
            else:
                rejected += 1
        self.assertEqual(approved, 5, "exactly cap=5 plans should succeed")
        self.assertEqual(rejected, 15)
        self.assertEqual(mc.count, 5)
        # Plan log should contain a cap_reached marker
        with open(plan_path, "r", encoding="utf-8") as f:
            log_text = f.read()
        self.assertIn("cap_reached", log_text)

    def test_default_cap_is_50(self):
        mc, _, _ = self._make_controller(cap=shc.DEFAULT_MUTATION_CAP)
        approved = 0
        for i in range(60):
            if mc.plan({"event": "plan_patch", "check": "x", "id": i}):
                approved += 1
                mc.record({"check": "x", "id": i, "ok": True})
        self.assertEqual(approved, 50)
        self.assertEqual(mc.count, 50)

    def test_can_patch_reflects_count(self):
        mc, _, _ = self._make_controller(cap=2)
        self.assertTrue(mc.can_patch())
        mc.plan({"event": "plan_patch", "id": 1})
        mc.record({"id": 1})
        self.assertTrue(mc.can_patch())
        mc.plan({"event": "plan_patch", "id": 2})
        mc.record({"id": 2})
        self.assertFalse(mc.can_patch())


# ---------------------------------------------------------------------------
# Madhu requirement (2026-06-29 EM Sync) checks: 15, 17, 18, 20
# ---------------------------------------------------------------------------


class TestCurrentMonthNode(unittest.TestCase):
    def test_strips_sprint_suffix(self):
        ci = {"path": r"MSTeams\2026\H1\Q2\June\Sprint 209 22-June to 5-July"}
        self.assertEqual(shc.current_month_node(ci), r"MSTeams\2026\H1\Q2\June")

    def test_month_only_path_unchanged(self):
        ci = {"path": r"MSTeams\2026\H1\Q2\June"}
        self.assertEqual(shc.current_month_node(ci), r"MSTeams\2026\H1\Q2\June")

    def test_empty_inputs(self):
        self.assertEqual(shc.current_month_node({}), "")
        self.assertEqual(shc.current_month_node(None), "")


class TestTierFor(unittest.TestCase):
    def test_state_tiers(self):
        self.assertEqual(shc._tier_for("RollingOut", ""), 1)
        self.assertEqual(shc._tier_for("Active", ""), 2)
        self.assertEqual(shc._tier_for("Committed", ""), 3)
        self.assertEqual(shc._tier_for("Proposed", ""), 4)
        self.assertEqual(shc._tier_for("New", ""), 4)
        self.assertEqual(shc._tier_for("", ""), 4)

    def test_exception_tag_wins(self):
        self.assertEqual(shc._tier_for("Active", "Exception; foo"), 0)
        self.assertEqual(shc._tier_for("Proposed", "security-exception"), 0)

    def test_exception_type_wins(self):
        # Board interleaves Exception work-item TYPE at the top, regardless of state/tags.
        self.assertEqual(shc._tier_for("Open", "", "Exception"), 0)
        self.assertEqual(shc._tier_for("Proposed", "", "Exception"), 0)
        # Non-exception types fall through to state tiers.
        self.assertEqual(shc._tier_for("RollingOut", "", "Feature"), 1)
        self.assertEqual(shc._tier_for("Proposed", "", "Feature"), 4)

    def test_none_tags(self):
        self.assertEqual(shc._tier_for("RollingOut", None), 1)


class TestDetectOrderInversions(unittest.TestCase):
    def test_clean_order_no_flags(self):
        rows = [
            {"id": 1, "state": "RollingOut", "tags": "", "owner": "a", "stackRank": 100},
            {"id": 2, "state": "Active", "tags": "", "owner": "b", "stackRank": 200},
            {"id": 3, "state": "Committed", "tags": "", "owner": "c", "stackRank": 300},
            {"id": 4, "state": "Proposed", "tags": "", "owner": "d", "stackRank": 400},
        ]
        flagged, suggested = shc.detect_order_inversions(rows)
        self.assertEqual(flagged, [])
        self.assertEqual([r["id"] for r in suggested], [1, 2, 3, 4])

    def test_detects_inversion(self):
        # Committed (tier 3) ranked ABOVE RollingOut (tier 1): RollingOut is misplaced.
        rows = [
            {"id": 10, "state": "Committed", "tags": "", "owner": "a", "stackRank": 100},
            {"id": 11, "state": "RollingOut", "tags": "", "owner": "b", "stackRank": 200},
        ]
        flagged, suggested = shc.detect_order_inversions(rows)
        self.assertEqual(len(flagged), 1)
        self.assertEqual(flagged[0]["id"], 11)
        self.assertIn("#10", flagged[0]["below"])
        self.assertEqual([r["id"] for r in suggested], [11, 10])

    def test_exception_tier_on_top(self):
        rows = [
            {"id": 1, "state": "RollingOut", "tags": "", "owner": "a", "stackRank": 100},
            {"id": 2, "state": "Active", "tags": "exception", "owner": "b", "stackRank": 500},
        ]
        flagged, suggested = shc.detect_order_inversions(rows)
        # exception (tier 0) at rank 500 sits below RollingOut (tier 1) at 100 -> flagged.
        self.assertEqual(len(flagged), 1)
        self.assertEqual(flagged[0]["id"], 2)
        self.assertEqual([r["id"] for r in suggested], [2, 1])

    def test_exception_type_at_top_clean(self):
        # Real board layout: Exception (type) at row 1, then Features by state.
        rows = [
            {"id": 1, "state": "Open", "type": "Exception", "tags": "", "owner": "a", "stackRank": 100},
            {"id": 2, "state": "RollingOut", "type": "Feature", "tags": "", "owner": "b", "stackRank": 200},
            {"id": 3, "state": "Active", "type": "Feature", "tags": "", "owner": "c", "stackRank": 300},
        ]
        flagged, suggested = shc.detect_order_inversions(rows)
        self.assertEqual(flagged, [])
        self.assertEqual([r["id"] for r in suggested], [1, 2, 3])

    def test_exception_type_misranked_flagged(self):
        # An Exception (tier 0) ranked BELOW a Feature -> inversion, detected by type not tag.
        rows = [
            {"id": 2, "state": "RollingOut", "type": "Feature", "tags": "", "owner": "b", "stackRank": 100},
            {"id": 1, "state": "Open", "type": "Exception", "tags": "", "owner": "a", "stackRank": 900},
        ]
        flagged, suggested = shc.detect_order_inversions(rows)
        self.assertEqual(len(flagged), 1)
        self.assertEqual(flagged[0]["id"], 1)
        self.assertEqual([r["id"] for r in suggested], [1, 2])

    def test_handles_none_stackrank(self):
        rows = [
            {"id": 1, "state": "RollingOut", "tags": "", "owner": "a", "stackRank": None},
            {"id": 2, "state": "Proposed", "tags": "", "owner": "b", "stackRank": 50},
        ]
        flagged, suggested = shc.detect_order_inversions(rows)
        # None StackRank sorts last -> ordered [Proposed(50), RollingOut(None)];
        # RollingOut tier 1 < Proposed tier 4 -> inversion on id 1.
        self.assertEqual(len(flagged), 1)
        self.assertEqual(flagged[0]["id"], 1)


if __name__ == "__main__":
    unittest.main()
