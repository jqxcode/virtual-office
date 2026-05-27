"""Pinned shiproom hygiene checker.

Implements all 14 hygiene checks for the Meeting Join Fundamentals and
(temporarily) Meeting Notes areas under MSTeams. Replaces the previous
LLM-regenerated-each-run approach that caused the 2026-05-22 1446-item
cross-area incident.

Every mutating check enforces the SAFETY POLICY documented in
config/shiproom-hygiene-rules.md:

  1. WIQL strings are STRING CONSTANTS that literally contain
     [System.AreaPath] UNDER '<allowed-area>'. validate_wiql_has_area_filter()
     verifies this at runtime; a missing filter aborts the check.
  2. Per-item area_path_allowed() re-check before EVERY PATCH.
  3. Per-run mutation cap (default 50 PATCH calls).
  4. Plan log (output/scrum-master/hygiene-patch-plan-<ts>.jsonl) is
     written BEFORE the mutation executes.
  5. Audit log (output/scrum-master/hygiene-mutations-<YYYY-MM-DD>.jsonl)
     records every executed PATCH.
  6. Allowed areas computed at runtime: Notes is dropped on/after
     2026-06-01 (compute_allowed_areas()).

CLI:
    python runner/shiproom_hygiene_check.py [--dry-run] [--limit-checks 1,2,3]

The script never opens HTML in a browser. It writes:

    output/scrum-master/shiproom-hygiene-YYYYMMDD-HHmmss.html
    output/scrum-master/shiproom-hygiene-latest.html
    output/scrum-master/hygiene-teams-summary.json
    output/scrum-master/hygiene-full-results.json
    output/scrum-master/hygiene-patch-plan-<ts>.jsonl
    output/scrum-master/hygiene-mutations-<YYYY-MM-DD>.jsonl
"""
from __future__ import annotations

import argparse
import json
import os
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Tuple

# UTF-8 stdio reconfigure
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

ORG = "https://domoreexp.visualstudio.com"
PROJECT = "MSTeams"
TEAM_ID = "6f72ea4e-c73a-4a15-b622-46cdacc53987"

AREA_MJ = r"MSTeams\Calling Meeting Devices (CMD)\Meetings\Meeting Join\Fundamentals"
AREA_NOTES = r"MSTeams\Calling Meeting Devices (CMD)\Meetings\Notes"

AREA_SHORT = {AREA_MJ: "MeetingJoin", AREA_NOTES: "Notes"}

DEFAULT_MUTATION_CAP = 50
NOTES_CUTOFF = date(2026, 6, 1)

PST = timezone(timedelta(hours=-7))

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_DIR = os.path.join(REPO_ROOT, "output", "scrum-master")
TEMPLATE_PATH = os.path.join(REPO_ROOT, "templates", "scrum-master-shiproom-hygiene.html")

# Mutating check IDs (referenced by safety policy)
MUTATING_CHECKS = {"1", "2", "3", "5", "6"}

# Mutating checks must contain the workitems area filter literally.
# Check 1 is a workitemLinks query which uses [Source].[System.AreaPath].
AREA_FILTER_TOKEN = "[System.AreaPath] UNDER"
AREA_FILTER_LINK_TOKEN = "[Source].[System.AreaPath] UNDER"


_ssl_ctx = ssl.create_default_context()


# ---------------------------------------------------------------------------
# Pinned WIQL templates
#
# Each template is a STRING CONSTANT containing the literal area-filter
# token. Callers substitute the allowed-area into the placeholder; they
# do NOT regenerate the surrounding query. validate_wiql_has_area_filter()
# is called on the rendered string before every WIQL POST.
# ---------------------------------------------------------------------------

WIQL_CHECK1_LINKS = (
    "SELECT [System.Id], [System.Title], [System.WorkItemType] "
    "FROM workitemLinks "
    "WHERE ([Source].[System.WorkItemType] = 'Task' "
    "AND [Source].[System.AreaPath] UNDER '{area}') "
    "AND ([System.Links.LinkType] = 'System.LinkTypes.Hierarchy-Reverse') "
    "AND ([Target].[System.WorkItemType] = 'Task') "
    "MODE (MustContain)"
)

WIQL_CHECK2_RESOLVED = (
    "SELECT [System.Id], [System.Title], [System.State], [System.AreaPath] "
    "FROM workitems "
    "WHERE [System.State] = 'Resolved' "
    "AND [System.AreaPath] UNDER '{area}'"
)

WIQL_CHECK2B_BLOCKED_FEATURES = (
    "SELECT [System.Id], [System.Title], [System.State], [System.AreaPath] "
    "FROM workitems "
    "WHERE [System.WorkItemType] = 'Feature' "
    "AND [System.State] = 'Blocked' "
    "AND [System.AreaPath] UNDER '{area}'"
)

WIQL_CHECK3_PREV_SPRINT = (
    "SELECT [System.Id], [System.Title], [System.State], "
    "[System.IterationPath], [System.AreaPath] "
    "FROM workitems "
    "WHERE [System.State] <> 'Closed' AND [System.State] <> 'Removed' "
    "AND [System.IterationPath] = '{prev}' "
    "AND [System.AreaPath] UNDER '{area}'"
)

WIQL_CHECK4_CURRENT_TASKS = (
    "SELECT [System.Id], [System.Title], [System.State], [System.AreaPath] "
    "FROM workitems "
    "WHERE [System.WorkItemType] = 'Task' "
    "AND [System.State] <> 'Closed' AND [System.State] <> 'Removed' "
    "AND [System.IterationPath] = '{current}' "
    "AND [System.AreaPath] UNDER '{area}'"
)

WIQL_CHECK5_BUGS_NOT_CURRENT = (
    "SELECT [System.Id], [System.Title], [System.State], "
    "[System.IterationPath], [System.AreaPath] "
    "FROM workitems "
    "WHERE [System.WorkItemType] = 'Bug' "
    "AND [System.State] <> 'Closed' AND [System.State] <> 'Removed' "
    "AND [System.IterationPath] <> '{current}' "
    "AND [System.AreaPath] UNDER '{area}'"
)

WIQL_CHECK6_STALE_TASKS = (
    "SELECT [System.Id], [System.Title], [System.State], "
    "[System.IterationPath], [System.AssignedTo], [System.AreaPath] "
    "FROM workitems "
    "WHERE [System.WorkItemType] = 'Task' "
    "AND [System.State] <> 'Closed' AND [System.State] <> 'Removed' "
    "AND [System.IterationPath] UNDER '{semester}' "
    "AND [System.AssignedTo] <> '' "
    "AND [System.AreaPath] UNDER '{area}'"
)

WIQL_CHECK7_PROPOSED_BUGS = (
    "SELECT [System.Id], [System.Title], [System.State], [System.AreaPath] "
    "FROM workitems "
    "WHERE [System.WorkItemType] = 'Bug' "
    "AND [System.State] = 'Proposed' "
    "AND [System.ChangedDate] < @today - 1 "
    "AND [System.AreaPath] UNDER '{area}' "
    "ORDER BY [System.ChangedDate] ASC"
)

WIQL_CHECK8_COMMITTED_OUTSIDE = (
    "SELECT [System.Id], [System.Title], [System.IterationPath], [System.AreaPath] "
    "FROM workitems "
    "WHERE [System.WorkItemType] = 'Feature' "
    "AND [System.State] = 'Committed' "
    "AND NOT [System.IterationPath] UNDER '{semester}' "
    "AND [System.AreaPath] UNDER '{area}'"
)

WIQL_CHECK9_STALE_BUGS = (
    "SELECT [System.Id], [System.Title], [System.State], [System.AreaPath] "
    "FROM workitems "
    "WHERE [System.WorkItemType] = 'Bug' "
    "AND [System.State] <> 'Closed' AND [System.State] <> 'Removed' "
    "AND [System.CreatedDate] < @today - 90 "
    "AND [System.AreaPath] UNDER '{area}' "
    "ORDER BY [System.CreatedDate] ASC"
)

WIQL_CHECK10_RING_DATES = (
    "SELECT [System.Id], [System.Title], [System.AreaPath] "
    "FROM workitems "
    "WHERE [System.WorkItemType] = 'Feature' "
    "AND [System.State] = 'Active' "
    "AND [System.IterationPath] UNDER '{semester}' "
    "AND ([Microsoft.VSTS.Scheduling.TargetDate] < @today "
    "OR [MicrosoftTeamsCMMI.Ring4TargetDate] < @today) "
    "AND [System.AreaPath] UNDER '{area}'"
)

WIQL_CHECK11_SIGNOFFS = (
    "SELECT [System.Id], [System.Title], [System.AreaPath] "
    "FROM workitems "
    "WHERE [System.WorkItemType] = 'Feature' "
    "AND [System.State] = 'Active' "
    "AND [System.IterationPath] UNDER '{semester}' "
    "AND [System.AreaPath] UNDER '{area}'"
)

WIQL_CHECK12_RING_ORDERING = (
    "SELECT [System.Id], [System.Title], [System.AreaPath] "
    "FROM workitems "
    "WHERE [System.WorkItemType] = 'Feature' "
    "AND [System.State] <> 'Closed' AND [System.State] <> 'Removed' "
    "AND [System.IterationPath] UNDER '{semester}' "
    "AND [MicrosoftTeamsCMMI.Ring4TargetDate] <> '' "
    "AND [System.AreaPath] UNDER '{area}'"
)

WIQL_CHECK14_FLAKY_BUGS = (
    "SELECT [System.Id], [System.Title], [System.State], [System.AreaPath] "
    "FROM workitems "
    "WHERE [System.WorkItemType] = 'Bug' "
    "AND [System.State] <> 'Closed' AND [System.State] <> 'Removed' "
    "AND [System.Tags] CONTAINS 'cifx-jailed-tests-above-threshold' "
    "AND [System.AreaPath] UNDER '{area}'"
)


# ---------------------------------------------------------------------------
# Safety helpers (unit-tested)
# ---------------------------------------------------------------------------


def validate_wiql_has_area_filter(wiql, is_link_query=False):
    # type: (str, bool) -> bool
    """Return True if wiql contains the literal area-filter token.

    For workitemLinks queries (Check 1), [Source].[System.AreaPath] UNDER
    is required. For all other workitems queries the plain
    [System.AreaPath] UNDER must appear.
    """
    if not wiql:
        return False
    if is_link_query:
        return AREA_FILTER_LINK_TOKEN in wiql
    return AREA_FILTER_TOKEN in wiql


def area_path_allowed(area_path, allowed_areas):
    # type: (str, List[str]) -> bool
    """Return True iff area_path starts with one of the allowed prefixes."""
    if not area_path or not allowed_areas:
        return False
    for allowed in allowed_areas:
        if area_path == allowed or area_path.startswith(allowed + "\\"):
            return True
    return False


def compute_allowed_areas(today):
    # type: (date) -> List[str]
    """Pick the active area set based on the date.

    Before 2026-06-01 -> both MJ Fundamentals and Notes.
    On/after 2026-06-01 -> only MJ Fundamentals.
    """
    if today < NOTES_CUTOFF:
        return [AREA_MJ, AREA_NOTES]
    return [AREA_MJ]


def compute_semester(today):
    # type: (date) -> str
    """Return the current semester iteration prefix."""
    if today.month <= 6:
        return "MSTeams\\{0}\\H1".format(today.year)
    return "MSTeams\\{0}\\H2".format(today.year)


# ---------------------------------------------------------------------------
# Mutation controller (unit-tested)
# ---------------------------------------------------------------------------


class MutationController:
    """Owns the per-run cap, plan log and audit log.

    Every mutating check MUST call plan() before issuing the API write
    and record() after it returns. plan() returns False when the cap
    is exhausted; the check must then skip the mutation and continue
    in comment-only mode.
    """

    def __init__(self, plan_path, audit_path, cap=DEFAULT_MUTATION_CAP, dry_run=False):
        # type: (str, str, int, bool) -> None
        self.plan_path = plan_path
        self.audit_path = audit_path
        self.cap = cap
        self.dry_run = dry_run
        self.count = 0
        self.cap_reached_logged = False

    def can_patch(self):
        # type: () -> bool
        return self.count < self.cap

    def plan(self, entry):
        # type: (Dict[str, Any]) -> bool
        """Append entry to the plan log. Returns False when cap reached."""
        if not self.can_patch():
            if not self.cap_reached_logged:
                self._append(self.plan_path, {
                    "event": "cap_reached",
                    "cap": self.cap,
                    "timestamp": datetime.now(PST).isoformat(),
                })
                self.cap_reached_logged = True
            return False
        entry = dict(entry)
        entry.setdefault("timestamp", datetime.now(PST).isoformat())
        entry.setdefault("dryRun", self.dry_run)
        self._append(self.plan_path, entry)
        return True

    def record(self, entry):
        # type: (Dict[str, Any]) -> None
        """Append an executed PATCH to the audit log and bump the counter."""
        entry = dict(entry)
        entry.setdefault("timestamp", datetime.now(PST).isoformat())
        entry.setdefault("dryRun", self.dry_run)
        self._append(self.audit_path, entry)
        self.count += 1

    @staticmethod
    def _append(path, entry):
        # type: (str, Dict[str, Any]) -> None
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")


# ---------------------------------------------------------------------------
# ADO REST helpers
# ---------------------------------------------------------------------------


def get_ado_token():
    # type: () -> str
    return subprocess.check_output(
        [
            "az", "account", "get-access-token",
            "--resource", "499b84ac-1321-427f-aa17-267ca6975798",
            "--query", "accessToken", "-o", "tsv",
        ],
        shell=False, text=True,
    ).strip()


def get_pbi_token():
    # type: () -> str
    return subprocess.check_output(
        [
            "az", "account", "get-access-token",
            "--resource", "https://analysis.windows.net/powerbi/api",
            "--query", "accessToken", "-o", "tsv",
        ],
        shell=False, text=True,
    ).strip()


def ado_request(path, token, method="GET", body=None, content_type=None):
    # type: (str, str, str, Optional[Any], Optional[str]) -> Optional[Any]
    url = path if path.startswith("http") else "{0}/{1}".format(ORG, path)
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    if content_type:
        req.add_header("Content-Type", content_type)
    elif method == "PATCH":
        req.add_header("Content-Type", "application/json-patch+json")
    else:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, context=_ssl_ctx, timeout=60) as resp:
            raw = resp.read()
        if not raw:
            return None
        return json.loads(raw)
    except urllib.error.HTTPError as e:
        body_text = e.read().decode("utf-8", "replace") if e.fp else ""
        print("  HTTP {0} {1} {2}: {3}".format(e.code, method, url, body_text[:300]),
              file=sys.stderr)
        return None
    except Exception as e:
        print("  REQ {0} {1}: {2}".format(method, url, e), file=sys.stderr)
        return None


def wiql_query(wiql, token):
    # type: (str, str) -> List[int]
    resp = ado_request(
        "{0}/_apis/wit/wiql?api-version=7.1".format(PROJECT),
        token, "POST", {"query": wiql},
    )
    if not resp:
        return []
    if "workItems" in resp:
        return [w["id"] for w in resp["workItems"]]
    if "workItemRelations" in resp:
        ids = []
        seen = set()
        for r in resp["workItemRelations"]:
            for end in ("source", "target"):
                node = r.get(end)
                if node and node.get("id") not in seen:
                    seen.add(node["id"])
                    ids.append(node["id"])
        return ids
    return []


def wiql_link_query(wiql, token):
    # type: (str, str) -> List[Dict[str, int]]
    resp = ado_request(
        "{0}/_apis/wit/wiql?api-version=7.1".format(PROJECT),
        token, "POST", {"query": wiql},
    )
    pairs = []  # type: List[Dict[str, int]]
    if not resp or "workItemRelations" not in resp:
        return pairs
    for r in resp["workItemRelations"]:
        src = r.get("source")
        tgt = r.get("target")
        if src and tgt:
            pairs.append({"source": src["id"], "target": tgt["id"]})
    return pairs


def get_work_item(wid, token, expand="all"):
    # type: (int, str, str) -> Optional[Dict[str, Any]]
    return ado_request(
        "{0}/_apis/wit/workItems/{1}?$expand={2}&api-version=7.1".format(PROJECT, wid, expand),
        token,
    )


def get_work_items_batch(ids, token, fields=None):
    # type: (List[int], str, Optional[List[str]]) -> List[Dict[str, Any]]
    if not ids:
        return []
    out = []  # type: List[Dict[str, Any]]
    for i in range(0, len(ids), 200):
        chunk = ids[i:i + 200]
        url = "{0}/_apis/wit/workItems?ids={1}&api-version=7.1".format(
            PROJECT, ",".join(str(x) for x in chunk),
        )
        if fields:
            url += "&fields=" + ",".join(fields)
        resp = ado_request(url, token)
        if resp and "value" in resp:
            out.extend(resp["value"])
    return out


def patch_work_item(wid, ops, token):
    # type: (int, List[Dict[str, Any]], str) -> Optional[Dict[str, Any]]
    return ado_request(
        "{0}/_apis/wit/workItems/{1}?api-version=7.1".format(PROJECT, wid),
        token, "PATCH", ops, content_type="application/json-patch+json",
    )


def add_comment(wid, html, token):
    # type: (int, str, str) -> Optional[Dict[str, Any]]
    return ado_request(
        "{0}/_apis/wit/workItems/{1}/comments?api-version=7.1-preview.4".format(PROJECT, wid),
        token, "POST", {"text": html},
    )


def get_owner_name(wi):
    # type: (Dict[str, Any]) -> str
    a = wi.get("fields", {}).get("System.AssignedTo")
    if isinstance(a, dict):
        return a.get("displayName") or "Unassigned"
    if a:
        return str(a)
    return "Unassigned"


def get_owner_id(wi):
    # type: (Dict[str, Any]) -> str
    a = wi.get("fields", {}).get("System.AssignedTo")
    if isinstance(a, dict):
        return a.get("id") or ""
    return ""


def mention_html(wi):
    # type: (Dict[str, Any]) -> str
    name = get_owner_name(wi)
    uid = get_owner_id(wi)
    if uid:
        return '<a href="#" data-vss-mention="version:2.0,{0}">@{1}</a>'.format(uid, name)
    return "@" + name


# ---------------------------------------------------------------------------
# Iteration discovery
# ---------------------------------------------------------------------------


def get_team_iterations(token):
    # type: (str) -> List[Dict[str, Any]]
    resp = ado_request(
        "{0}/{1}/_apis/work/teamsettings/iterations?api-version=7.1".format(PROJECT, TEAM_ID),
        token,
    )
    if not resp:
        return []
    return resp.get("value", []) or []


def find_current_and_previous(iters, today):
    # type: (List[Dict[str, Any]], date) -> Tuple[Optional[Dict[str, Any]], Optional[Dict[str, Any]]]
    current = None
    for it in iters:
        if it.get("attributes", {}).get("timeFrame") == "current":
            current = it
            break
    if not current:
        return None, None
    curr_start = _parse_iter_date(current["attributes"].get("startDate"))
    if not curr_start:
        return current, None
    best = None
    best_finish = None
    for it in iters:
        fd = _parse_iter_date(it.get("attributes", {}).get("finishDate"))
        if not fd or fd >= curr_start:
            continue
        if best_finish is None or fd > best_finish:
            best_finish = fd
            best = it
    return current, best


def semester_iterations(iters, semester):
    # type: (List[Dict[str, Any]], str) -> List[Dict[str, Any]]
    norm = semester.replace("\\", "/")
    return [it for it in iters if norm in it.get("path", "").replace("\\", "/")]


def _parse_iter_date(s):
    # type: (Optional[str]) -> Optional[date]
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).date()
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Check skeleton helper
# ---------------------------------------------------------------------------


def _empty_result():
    # type: () -> Dict[str, Any]
    return {"items": [], "count": 0}


def _abort_if_no_area_filter(check_label, wiql, is_link_query, mc):
    # type: (str, str, bool, MutationController) -> bool
    if validate_wiql_has_area_filter(wiql, is_link_query=is_link_query):
        return True
    mc.plan({
        "event": "abort_check",
        "check": check_label,
        "reason": "wiql_missing_area_filter",
        "wiql": wiql,
    })
    print("  ABORT {0}: WIQL missing area filter; safety guard tripped.".format(check_label),
          file=sys.stderr)
    return False


# ---------------------------------------------------------------------------
# Check implementations
# ---------------------------------------------------------------------------


def check1(token, allowed_areas, mc, dry_run):
    # type: (str, List[str], MutationController, bool) -> Dict[str, Any]
    print("Check 1: Task-to-Task Parent Links")
    items = []  # type: List[Dict[str, Any]]
    for area in allowed_areas:
        wiql = WIQL_CHECK1_LINKS.format(area=area)
        if not _abort_if_no_area_filter("check1", wiql, True, mc):
            continue
        for pair in wiql_link_query(wiql, token):
            child_id = pair["source"]
            parent_id = pair["target"]
            child = get_work_item(child_id, token, expand="relations")
            if not child:
                continue
            child_area = child.get("fields", {}).get("System.AreaPath", "")
            if not area_path_allowed(child_area, allowed_areas):
                mc.plan({
                    "event": "skip_area_mismatch",
                    "check": "check1",
                    "id": child_id,
                    "areaPath": child_area,
                })
                continue
            parent_idx = None
            for idx, rel in enumerate(child.get("relations", []) or []):
                if (
                    rel.get("rel") == "System.LinkTypes.Hierarchy-Reverse"
                    and "/" + str(parent_id) in rel.get("url", "")
                ):
                    parent_idx = idx
                    break
            if parent_idx is None:
                continue
            parent_wi = get_work_item(parent_id, token, expand="none")
            parent_title = ""
            if parent_wi:
                parent_title = parent_wi.get("fields", {}).get("System.Title", "")
            owner = get_owner_name(child)
            child_title = child.get("fields", {}).get("System.Title", "")
            action = "planned-only"

            plan_ok = mc.plan({
                "event": "plan_patch",
                "check": "check1",
                "id": child_id,
                "areaPath": child_area,
                "ops": [
                    {"op": "remove", "path": "/relations/{0}".format(parent_idx)},
                    {"op": "add", "path": "/relations/-", "value": {
                        "rel": "System.LinkTypes.Related",
                        "url": "{0}/{1}/_apis/wit/workItems/{2}".format(ORG, PROJECT, parent_id),
                    }},
                ],
            })
            if plan_ok and not dry_run:
                remove_ops = [
                    {"op": "test", "path": "/rev", "value": child.get("rev")},
                    {"op": "remove", "path": "/relations/{0}".format(parent_idx)},
                ]
                r1 = patch_work_item(child_id, remove_ops, token)
                related_ops = [{
                    "op": "add", "path": "/relations/-",
                    "value": {
                        "rel": "System.LinkTypes.Related",
                        "url": "{0}/{1}/_apis/wit/workItems/{2}".format(ORG, PROJECT, parent_id),
                    },
                }]
                r2 = patch_work_item(child_id, related_ops, token)
                add_comment(child_id, (
                    "{0} The parent link on this task was changed to a Related link. "
                    "Tasks should not be parented under another Task; use a User Story or "
                    "Feature as the parent instead."
                ).format(mention_html(child)), token)
                mc.record({
                    "check": "check1",
                    "id": child_id,
                    "areaPath": child_area,
                    "before": {"parentId": parent_id},
                    "after": {"relatedId": parent_id},
                    "ok": bool(r1 and r2),
                })
                action = "fixed"
            elif plan_ok and dry_run:
                action = "would-fix (dry-run)"

            items.append({
                "id": child_id,
                "childId": child_id,
                "title": child_title,
                "childTitle": child_title,
                "parentId": parent_id,
                "parentTitle": parent_title,
                "owner": owner,
                "area": AREA_SHORT.get(child_area, child_area),
                "action": action,
            })
    return {"items": items, "count": len(items)}


def check2(token, allowed_areas, mc, dry_run):
    # type: (str, List[str], MutationController, bool) -> Dict[str, Any]
    print("Check 2: Close Resolved Work Items")
    items = []
    for area in allowed_areas:
        wiql = WIQL_CHECK2_RESOLVED.format(area=area)
        if not _abort_if_no_area_filter("check2", wiql, False, mc):
            continue
        ids = wiql_query(wiql, token)
        if not ids:
            continue
        wis = get_work_items_batch(ids, token, fields=[
            "System.Id", "System.Title", "System.WorkItemType", "System.AssignedTo",
            "System.State", "System.AreaPath",
        ])
        for wi in wis:
            wid = wi["id"]
            ap = wi.get("fields", {}).get("System.AreaPath", "")
            if not area_path_allowed(ap, allowed_areas):
                mc.plan({"event": "skip_area_mismatch", "check": "check2", "id": wid, "areaPath": ap})
                continue
            action = "planned-only"
            plan_ok = mc.plan({
                "event": "plan_patch",
                "check": "check2",
                "id": wid,
                "areaPath": ap,
                "ops": [{"op": "add", "path": "/fields/System.State", "value": "Closed"}],
            })
            if plan_ok and not dry_run:
                r = patch_work_item(wid, [
                    {"op": "add", "path": "/fields/System.State", "value": "Closed"},
                ], token)
                add_comment(wid, (
                    "{0} This item was Resolved and has been auto-closed by shiproom hygiene. "
                    "If this was premature, reopen and move to a more accurate state. "
                    "Questions: reach out to Josh Xu (qitxu@microsoft.com)."
                ).format(mention_html(wi)), token)
                mc.record({
                    "check": "check2", "id": wid, "areaPath": ap,
                    "before": {"state": "Resolved"},
                    "after": {"state": "Closed"},
                    "ok": bool(r),
                })
                action = "closed" if r else "patch_failed"
            elif plan_ok and dry_run:
                action = "would-close (dry-run)"
            items.append({
                "id": wid,
                "type": wi.get("fields", {}).get("System.WorkItemType", ""),
                "title": wi.get("fields", {}).get("System.Title", ""),
                "owner": get_owner_name(wi),
                "area": AREA_SHORT.get(ap, ap),
                "action": action,
            })
    return {"items": items, "count": len(items)}


def check2b(token, allowed_areas):
    # type: (str, List[str]) -> Dict[str, Any]
    print("Check 2b: Blocked Features (comment-only)")
    items = []
    for area in allowed_areas:
        wiql = WIQL_CHECK2B_BLOCKED_FEATURES.format(area=area)
        if not validate_wiql_has_area_filter(wiql, False):
            print("  ABORT check2b: missing area filter", file=sys.stderr)
            continue
        ids = wiql_query(wiql, token)
        if not ids:
            continue
        wis = get_work_items_batch(ids, token, fields=[
            "System.Id", "System.Title", "System.AssignedTo", "System.State",
            "System.ChangedDate", "System.AreaPath",
        ])
        for wi in wis:
            ap = wi.get("fields", {}).get("System.AreaPath", "")
            if not area_path_allowed(ap, allowed_areas):
                continue
            items.append({
                "id": wi["id"],
                "title": wi.get("fields", {}).get("System.Title", ""),
                "owner": get_owner_name(wi),
                "state": "Blocked",
                "changedDate": (wi.get("fields", {}).get("System.ChangedDate") or "")[:10],
                "area": AREA_SHORT.get(ap, ap),
            })
    return {"items": items, "count": len(items)}


def check3(token, allowed_areas, mc, dry_run, current_iter, prev_iter, grace_period, grace_days):
    # type: (str, List[str], MutationController, bool, Dict[str, Any], Optional[Dict[str, Any]], bool, int) -> Dict[str, Any]
    print("Check 3: Previous Sprint Leftovers (grace={0})".format(grace_period))
    if not prev_iter:
        return _empty_result()
    items = []
    prev_path = prev_iter["path"]
    curr_path = current_iter["path"]
    prev_name = prev_iter["name"]
    curr_name = current_iter["name"]
    for area in allowed_areas:
        wiql = WIQL_CHECK3_PREV_SPRINT.format(prev=prev_path, area=area)
        if not _abort_if_no_area_filter("check3", wiql, False, mc):
            continue
        ids = wiql_query(wiql, token)
        if not ids:
            continue
        wis = get_work_items_batch(ids, token, fields=[
            "System.Id", "System.Title", "System.WorkItemType", "System.State",
            "System.AssignedTo", "System.AreaPath",
        ])
        for wi in wis:
            wid = wi["id"]
            ap = wi.get("fields", {}).get("System.AreaPath", "")
            if not area_path_allowed(ap, allowed_areas):
                mc.plan({"event": "skip_area_mismatch", "check": "check3", "id": wid, "areaPath": ap})
                continue
            if grace_period:
                if not dry_run:
                    add_comment(wid, (
                        "{0} This item is still in Sprint {1} but not closed. "
                        "Please close it or move it to a more appropriate sprint."
                    ).format(mention_html(wi), prev_name), token)
                action = "commented (grace, {0}d left)".format(grace_days)
            else:
                plan_ok = mc.plan({
                    "event": "plan_patch",
                    "check": "check3",
                    "id": wid,
                    "areaPath": ap,
                    "ops": [{"op": "add", "path": "/fields/System.IterationPath", "value": curr_path}],
                })
                if plan_ok and not dry_run:
                    r = patch_work_item(wid, [
                        {"op": "add", "path": "/fields/System.IterationPath", "value": curr_path},
                    ], token)
                    add_comment(wid, (
                        "{0} This item was left over from Sprint {1} and has been auto-moved "
                        "to the current sprint ({2}). Please close it or reassign if no longer relevant."
                    ).format(mention_html(wi), prev_name, curr_name), token)
                    mc.record({
                        "check": "check3", "id": wid, "areaPath": ap,
                        "before": {"iterationPath": prev_path},
                        "after": {"iterationPath": curr_path},
                        "ok": bool(r),
                    })
                    action = "moved" if r else "move-failed"
                elif plan_ok and dry_run:
                    action = "would-move (dry-run)"
                else:
                    action = "skipped (cap)"
            items.append({
                "id": wid,
                "type": wi.get("fields", {}).get("System.WorkItemType", ""),
                "title": wi.get("fields", {}).get("System.Title", ""),
                "state": wi.get("fields", {}).get("System.State", ""),
                "owner": get_owner_name(wi),
                "action": action,
            })
    return {"items": items, "count": len(items)}


def check4(token, allowed_areas, current_iter, dry_run):
    # type: (str, List[str], Dict[str, Any], bool) -> Dict[str, Any]
    print("Check 4: Current Sprint Tasks - Estimates + Parent")
    items = []
    curr_path = current_iter["path"]
    for area in allowed_areas:
        wiql = WIQL_CHECK4_CURRENT_TASKS.format(current=curr_path, area=area)
        if not validate_wiql_has_area_filter(wiql, False):
            print("  ABORT check4: missing area filter", file=sys.stderr)
            continue
        ids = wiql_query(wiql, token)
        if not ids:
            continue
        for wid in ids:
            wi = get_work_item(wid, token, expand="all")
            if not wi:
                continue
            f = wi.get("fields", {})
            ap = f.get("System.AreaPath", "")
            if not area_path_allowed(ap, allowed_areas):
                continue
            missing = []
            if not f.get("Microsoft.VSTS.Scheduling.OriginalEstimate"):
                missing.append("OriginalEstimate")
            if not f.get("Microsoft.VSTS.Scheduling.RemainingWork"):
                missing.append("RemainingWork")
            has_parent = any(
                rel.get("rel") == "System.LinkTypes.Hierarchy-Reverse"
                for rel in (wi.get("relations") or [])
            )
            if not has_parent:
                missing.append("parent link")
            if not missing:
                continue
            issue = ", ".join(missing)
            if not dry_run:
                add_comment(wid, (
                    "{0} This Task is missing: {1}. Please update before sprint mid-point."
                ).format(mention_html(wi), issue), token)
            items.append({
                "id": wid,
                "title": f.get("System.Title", ""),
                "state": f.get("System.State", ""),
                "owner": get_owner_name(wi),
                "area": AREA_SHORT.get(ap, ap),
                "issue": issue,
                "action": "commented" if not dry_run else "would-comment (dry-run)",
            })
    return {"items": items, "count": len(items)}


def check5(token, allowed_areas, mc, dry_run, current_iter):
    # type: (str, List[str], MutationController, bool, Dict[str, Any]) -> Dict[str, Any]
    print("Check 5: Non-Closed Bugs in Current Sprint")
    items = []
    curr_path = current_iter["path"]
    curr_name = current_iter["name"]
    for area in allowed_areas:
        wiql = WIQL_CHECK5_BUGS_NOT_CURRENT.format(current=curr_path, area=area)
        if not _abort_if_no_area_filter("check5", wiql, False, mc):
            continue
        ids = wiql_query(wiql, token)
        if not ids:
            continue
        wis = get_work_items_batch(ids, token, fields=[
            "System.Id", "System.Title", "System.State", "System.IterationPath",
            "System.AssignedTo", "System.AreaPath",
        ])
        for wi in wis:
            wid = wi["id"]
            f = wi.get("fields", {})
            ap = f.get("System.AreaPath", "")
            if not area_path_allowed(ap, allowed_areas):
                mc.plan({"event": "skip_area_mismatch", "check": "check5", "id": wid, "areaPath": ap})
                continue
            prev_path = f.get("System.IterationPath", "")
            plan_ok = mc.plan({
                "event": "plan_patch",
                "check": "check5",
                "id": wid,
                "areaPath": ap,
                "ops": [{"op": "add", "path": "/fields/System.IterationPath", "value": curr_path}],
            })
            if plan_ok and not dry_run:
                r = patch_work_item(wid, [
                    {"op": "add", "path": "/fields/System.IterationPath", "value": curr_path},
                ], token)
                add_comment(wid, (
                    "{0} This Bug was open but not in the current sprint, and has been auto-moved "
                    "to {1}. Please close it if it's no longer active, or reassign if it needs "
                    "different handling."
                ).format(mention_html(wi), curr_name), token)
                mc.record({
                    "check": "check5", "id": wid, "areaPath": ap,
                    "before": {"iterationPath": prev_path},
                    "after": {"iterationPath": curr_path},
                    "ok": bool(r),
                })
                action = "moved" if r else "move-failed"
            elif plan_ok and dry_run:
                action = "would-move (dry-run)"
            else:
                action = "skipped (cap)"
            items.append({
                "id": wid,
                "title": f.get("System.Title", ""),
                "state": f.get("System.State", ""),
                "previousSprint": prev_path,
                "owner": get_owner_name(wi),
                "action": action,
            })
    return {"items": items, "count": len(items)}


def check6(token, allowed_areas, mc, dry_run, current_iter, prev_iter, sem_iters,
           grace_period, grace_days, semester, today):
    # type: (...) -> Dict[str, Any]
    print("Check 6: Stale Tasks from Past Sprints (grace={0})".format(grace_period))
    items = []
    curr_path = current_iter["path"]
    curr_name = current_iter["name"]
    iter_finish = {}  # type: Dict[str, date]
    for it in sem_iters:
        fd = _parse_iter_date(it.get("attributes", {}).get("finishDate"))
        if fd:
            iter_finish[it["path"]] = fd
    for area in allowed_areas:
        wiql = WIQL_CHECK6_STALE_TASKS.format(semester=semester, area=area)
        if not _abort_if_no_area_filter("check6", wiql, False, mc):
            continue
        ids = wiql_query(wiql, token)
        if not ids:
            continue
        wis = get_work_items_batch(ids, token, fields=[
            "System.Id", "System.Title", "System.State", "System.IterationPath",
            "System.AssignedTo", "System.AreaPath",
        ])
        for wi in wis:
            wid = wi["id"]
            f = wi.get("fields", {})
            ap = f.get("System.AreaPath", "")
            if not area_path_allowed(ap, allowed_areas):
                mc.plan({"event": "skip_area_mismatch", "check": "check6", "id": wid, "areaPath": ap})
                continue
            iter_path = f.get("System.IterationPath", "")
            if "Sprint" not in iter_path:
                continue
            finish = iter_finish.get(iter_path)
            if not finish or finish >= today:
                continue
            if grace_period:
                if not dry_run:
                    add_comment(wid, (
                        "{0} This Task is still in Sprint {1}, which has already ended. "
                        "Please close it or move it to an active sprint."
                    ).format(mention_html(wi), iter_path.split("\\")[-1]), token)
                action = "commented (grace, {0}d left)".format(grace_days)
            else:
                plan_ok = mc.plan({
                    "event": "plan_patch",
                    "check": "check6",
                    "id": wid,
                    "areaPath": ap,
                    "ops": [{"op": "add", "path": "/fields/System.IterationPath", "value": curr_path}],
                })
                if plan_ok and not dry_run:
                    r = patch_work_item(wid, [
                        {"op": "add", "path": "/fields/System.IterationPath", "value": curr_path},
                    ], token)
                    add_comment(wid, (
                        "{0} This Task was stuck in Sprint {1} (already ended) and has been "
                        "auto-moved to the current sprint ({2}). Please close it or reassign "
                        "if no longer relevant."
                    ).format(mention_html(wi), iter_path.split("\\")[-1], curr_name), token)
                    mc.record({
                        "check": "check6", "id": wid, "areaPath": ap,
                        "before": {"iterationPath": iter_path},
                        "after": {"iterationPath": curr_path},
                        "ok": bool(r),
                    })
                    action = "moved" if r else "move-failed"
                elif plan_ok and dry_run:
                    action = "would-move (dry-run)"
                else:
                    action = "skipped (cap)"
            items.append({
                "id": wid,
                "title": f.get("System.Title", ""),
                "state": f.get("System.State", ""),
                "previousSprint": iter_path,
                "owner": get_owner_name(wi),
                "action": action,
            })
    return {"items": items, "count": len(items)}


def check7(token, allowed_areas):
    print("Check 7: Proposed Bugs > 24h (report-only)")
    items = []
    for area in allowed_areas:
        wiql = WIQL_CHECK7_PROPOSED_BUGS.format(area=area)
        if not validate_wiql_has_area_filter(wiql, False):
            print("  ABORT check7: missing area filter", file=sys.stderr)
            continue
        ids = wiql_query(wiql, token)
        if not ids:
            continue
        wis = get_work_items_batch(ids, token, fields=[
            "System.Id", "System.Title", "System.AssignedTo", "System.ChangedDate",
            "System.CreatedDate", "System.AreaPath", "Microsoft.VSTS.Common.Severity",
        ])
        for wi in wis:
            f = wi.get("fields", {})
            ap = f.get("System.AreaPath", "")
            if not area_path_allowed(ap, allowed_areas):
                continue
            items.append({
                "id": wi["id"],
                "title": f.get("System.Title", ""),
                "owner": get_owner_name(wi),
                "changedDate": (f.get("System.ChangedDate") or "")[:10],
                "createdDate": (f.get("System.CreatedDate") or "")[:10],
                "severity": f.get("Microsoft.VSTS.Common.Severity", ""),
                "area": AREA_SHORT.get(ap, ap),
            })
    return {"items": items, "count": len(items)}


def check8(token, allowed_areas, semester):
    print("Check 8: Committed Features Outside Semester (report-only)")
    items = []
    for area in allowed_areas:
        wiql = WIQL_CHECK8_COMMITTED_OUTSIDE.format(semester=semester, area=area)
        if not validate_wiql_has_area_filter(wiql, False):
            print("  ABORT check8: missing area filter", file=sys.stderr)
            continue
        ids = wiql_query(wiql, token)
        if not ids:
            continue
        wis = get_work_items_batch(ids, token, fields=[
            "System.Id", "System.Title", "System.AssignedTo",
            "System.IterationPath", "System.AreaPath",
        ])
        for wi in wis:
            f = wi.get("fields", {})
            ap = f.get("System.AreaPath", "")
            if not area_path_allowed(ap, allowed_areas):
                continue
            items.append({
                "id": wi["id"],
                "title": f.get("System.Title", ""),
                "owner": get_owner_name(wi),
                "iterationPath": f.get("System.IterationPath", ""),
                "area": AREA_SHORT.get(ap, ap),
            })
    return {"items": items, "count": len(items)}


def check9(token, allowed_areas):
    print("Check 9: Stale Bugs > 90d (report-only)")
    items = []
    for area in allowed_areas:
        wiql = WIQL_CHECK9_STALE_BUGS.format(area=area)
        if not validate_wiql_has_area_filter(wiql, False):
            print("  ABORT check9: missing area filter", file=sys.stderr)
            continue
        ids = wiql_query(wiql, token)
        if not ids:
            continue
        wis = get_work_items_batch(ids, token, fields=[
            "System.Id", "System.Title", "System.State", "System.AssignedTo",
            "System.CreatedDate", "System.ChangedDate",
            "Microsoft.VSTS.Common.Severity", "System.AreaPath",
        ])
        for wi in wis:
            f = wi.get("fields", {})
            ap = f.get("System.AreaPath", "")
            if not area_path_allowed(ap, allowed_areas):
                continue
            items.append({
                "id": wi["id"],
                "title": f.get("System.Title", ""),
                "state": f.get("System.State", ""),
                "owner": get_owner_name(wi),
                "createdDate": (f.get("System.CreatedDate") or "")[:10],
                "changedDate": (f.get("System.ChangedDate") or "")[:10],
                "severity": f.get("Microsoft.VSTS.Common.Severity", ""),
                "area": AREA_SHORT.get(ap, ap),
            })
    return {"items": items, "count": len(items)}


def check10(token, allowed_areas, semester, today):
    print("Check 10: Ring Target Date Issues (report-only)")
    items = []
    today_s = today.isoformat()
    for area in allowed_areas:
        wiql = WIQL_CHECK10_RING_DATES.format(semester=semester, area=area)
        if not validate_wiql_has_area_filter(wiql, False):
            print("  ABORT check10: missing area filter", file=sys.stderr)
            continue
        ids = wiql_query(wiql, token)
        if not ids:
            continue
        wis = get_work_items_batch(ids, token, fields=[
            "System.Id", "System.Title", "System.AssignedTo",
            "Microsoft.VSTS.Scheduling.TargetDate",
            "MicrosoftTeamsCMMI.Ring4TargetDate", "System.AreaPath",
        ])
        for wi in wis:
            f = wi.get("fields", {})
            ap = f.get("System.AreaPath", "")
            if not area_path_allowed(ap, allowed_areas):
                continue
            r0 = (f.get("Microsoft.VSTS.Scheduling.TargetDate") or "")[:10]
            r4 = (f.get("MicrosoftTeamsCMMI.Ring4TargetDate") or "")[:10]
            issues = []
            if r0 and r0 < today_s:
                issues.append("R0 past due ({0})".format(r0))
            if r4 and r4 < today_s:
                issues.append("R4 past due ({0})".format(r4))
            if not issues:
                continue
            items.append({
                "id": wi["id"],
                "title": f.get("System.Title", ""),
                "owner": get_owner_name(wi),
                "ring0Date": r0,
                "ring4Date": r4,
                "issue": ", ".join(issues),
                "area": AREA_SHORT.get(ap, ap),
            })
    return {"items": items, "count": len(items)}


def check11(token, allowed_areas, semester):
    print("Check 11: Missing Sign-Offs (report-only)")
    items = []
    signoff_fields = {
        "Security": "MicrosoftTeamsCMMI.SecurityReview",
        "Accessibility": "MicrosoftTeamsCMMI-Copy.AccessibilityUsability",
        "Privacy": "Custom.1CSUserStoryStatus",
        "Compliance": "Custom.ERP_Compliance_Signoff",
    }
    for area in allowed_areas:
        wiql = WIQL_CHECK11_SIGNOFFS.format(semester=semester, area=area)
        if not validate_wiql_has_area_filter(wiql, False):
            print("  ABORT check11: missing area filter", file=sys.stderr)
            continue
        ids = wiql_query(wiql, token)
        if not ids:
            continue
        fetch = ["System.Id", "System.Title", "System.AssignedTo", "System.AreaPath"] + list(signoff_fields.values())
        wis = get_work_items_batch(ids, token, fields=fetch)
        for wi in wis:
            f = wi.get("fields", {})
            ap = f.get("System.AreaPath", "")
            if not area_path_allowed(ap, allowed_areas):
                continue
            missing = []
            for label, fname in signoff_fields.items():
                val = f.get(fname)
                if not val or val == "" or val == "None":
                    missing.append(label)
            if not missing:
                continue
            items.append({
                "id": wi["id"],
                "title": f.get("System.Title", ""),
                "owner": get_owner_name(wi),
                "missingSignoffs": missing,
                "area": AREA_SHORT.get(ap, ap),
            })
    return {"items": items, "count": len(items)}


def check12(token, allowed_areas, semester):
    print("Check 12: Invalid Ring Date Ordering (report-only)")
    items = []
    for area in allowed_areas:
        wiql = WIQL_CHECK12_RING_ORDERING.format(semester=semester, area=area)
        if not validate_wiql_has_area_filter(wiql, False):
            print("  ABORT check12: missing area filter", file=sys.stderr)
            continue
        ids = wiql_query(wiql, token)
        if not ids:
            continue
        wis = get_work_items_batch(ids, token, fields=[
            "System.Id", "System.Title", "System.AssignedTo",
            "Microsoft.VSTS.Scheduling.TargetDate",
            "MicrosoftTeamsCMMI.Ring4TargetDate", "System.AreaPath",
        ])
        for wi in wis:
            f = wi.get("fields", {})
            ap = f.get("System.AreaPath", "")
            if not area_path_allowed(ap, allowed_areas):
                continue
            r0 = (f.get("Microsoft.VSTS.Scheduling.TargetDate") or "")[:10]
            r4 = (f.get("MicrosoftTeamsCMMI.Ring4TargetDate") or "")[:10]
            issue = None
            if r4 and not r0:
                issue = "R0 missing"
            elif r4 and r0 and r4 <= r0:
                issue = "R4 before R0"
            if not issue:
                continue
            items.append({
                "id": wi["id"],
                "title": f.get("System.Title", ""),
                "owner": get_owner_name(wi),
                "ring0Date": r0,
                "ring4Date": r4,
                "issue": issue,
            })
    return {"items": items, "count": len(items)}


def _run_dax(url, dax, token, timeout=60):
    payload = {"queries": [{"query": dax}], "serializerSettings": {"includeNulls": True}}
    req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), method="POST")
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, context=_ssl_ctx, timeout=timeout) as resp:
            raw = resp.read()
        return json.loads(raw)
    except Exception as e:
        print("  DAX failed: {0}".format(e), file=sys.stderr)
        return None


def check13(pbi_token):
    print("Check 13: Required Training Compliance (DAX)")
    if not pbi_token:
        return {"items": [], "count": 0, "skipped": True, "reason": "no_token"}
    dax = (
        "EVALUATE\n"
        "VAR _cutoffKey = YEAR(TODAY() + 15) * 10000 + MONTH(TODAY() + 15) * 100 + DAY(TODAY() + 15)\n"
        "RETURN\n"
        "SELECTCOLUMNS(\n"
        "    FILTER(\n"
        "        ADDCOLUMNS(\n"
        "            'Required Training',\n"
        "            \"EmployeeName\", RELATED('Employee'[Employee Name]),\n"
        "            \"CourseTitle\", RELATED('Courses'[Course Title]),\n"
        "            \"CourseLink\", RELATED('Courses'[VivaDeepLink]),\n"
        "            \"Status\", RELATED('Completion Status'[Course Completion Status]),\n"
        "            \"ReportsTo\", RELATED('Employee'[Reports To Alias]),\n"
        "            \"DueDateKey\", 'Required Training'[CompleteByDateKey]\n"
        "        ),\n"
        "        [ReportsTo] = \"qitxu\" && [Status] <> \"Completed\" && [DueDateKey] <= _cutoffKey\n"
        "    ),\n"
        "    \"Name\", [EmployeeName],\n"
        "    \"Course\", [CourseTitle],\n"
        "    \"Link\", [CourseLink],\n"
        "    \"DueDate\", [DueDateKey],\n"
        "    \"Status\", [Status]\n"
        ")"
    )
    url = "https://api.powerbi.com/v1.0/myorg/datasets/2f72a313-a17d-4ba5-b241-c4a27586d9e8/executeQueries"
    result = _run_dax(url, dax, pbi_token)
    if not result:
        return {"items": [], "count": 0, "skipped": True, "reason": "dax_failed"}
    rows = result.get("results", [{}])[0].get("tables", [{}])[0].get("rows", []) or []
    by_person = {}  # type: Dict[str, List[Dict[str, Any]]]
    for row in rows:
        name = row.get("[Name]", "Unknown")
        due_key = row.get("[DueDate]") or 0
        due_str = ""
        if due_key:
            try:
                k = int(due_key)
                due_str = "{0}-{1:02d}-{2:02d}".format(k // 10000, (k % 10000) // 100, k % 100)
            except Exception:
                due_str = str(due_key)
        by_person.setdefault(name, []).append({
            "title": row.get("[Course]", ""),
            "url": row.get("[Link]", ""),
            "dueDate": due_str,
        })
    items = [{"name": n, "missing": c} for n, c in by_person.items()]
    return {"items": items, "count": len(items)}


def check14(token, pbi_token, allowed_areas, now):
    # type: (str, Optional[str], List[str], datetime) -> Dict[str, Any]
    print("Check 14: CiFX Test Health")
    result = {
        "dax": None,
        "ado": {"openFlakyBugs": [], "fundamentalsStatus": "healthy", "notesStatus": "healthy"},
        "cdp": {"coverageOverallPct": None, "cifxPassRate": None, "cifxJailRate": None, "screenshots": []},
        "overallStatus": "healthy",
        "count": 0,
    }

    # Part A: DAX
    dax_data = None
    if pbi_token:
        seven = now - timedelta(days=7)
        include = [
            "Meeting join", "Meeting rejoin", "Bvt join", "Anonymous Join",
            "prejoin", "Pre Join", "Scheduled meeting join", "peek meeting join",
            "E2EE meeting join", "Started Notification", "Join Meeting", "Join Launcher",
        ]
        exclude = [
            "Townhall", "Broadcast", "Webinar", "MTMA Sign-in", "Call History",
            "Streaming Attendee", "Doppler", "SLA lock", "cifx_testsets",
            "Immersive", "Production Studio", "Breakout room",
        ]
        inc = " || ".join('CONTAINSSTRING(TestResults[TESTNAME], "{0}")'.format(p) for p in include)
        exc = " && ".join('NOT(CONTAINSSTRING(TestResults[TESTNAME], "{0}"))'.format(p) for p in exclude)
        date_filt = "TestResults[DateOnly] >= DATE({0}, {1}, {2})".format(seven.year, seven.month, seven.day)
        filt = "{0} && ({1}) && {2}".format(date_filt, inc, exc)
        url = ("https://api.powerbi.com/v1.0/myorg/groups/6f77e458-234c-4bd7-9a21-710c43dbb575/"
               "datasets/64f4d901-8372-485e-98e0-5a0820443d4b/executeQueries")
        q = ("EVALUATE\nVAR _f = FILTER(TestResults, {0})\nRETURN ROW(\n"
             "  \"Runs\", SUMX(_f, TestResults[Total]),\n"
             "  \"Pass\", SUMX(_f, TestResults[TestPass]),\n"
             "  \"Fail\", SUMX(_f, TestResults[TestFail])\n)").format(filt)
        r = _run_dax(url, q, pbi_token)
        rows = (r or {}).get("results", [{}])[0].get("tables", [{}])[0].get("rows", []) if r else []
        if rows:
            row = rows[0]
            total = row.get("[Runs]") or 0
            passed = row.get("[Pass]") or 0
            failed = row.get("[Fail]") or 0
            pr = round((passed / total * 100) if total else 0, 1)
            dax_data = {
                "passRate": pr, "totalRuns": total, "passed": passed, "failed": failed,
                "brokenTests": [], "topFailures": [], "topExceptions": [], "dailyTrend": [],
            }
            # Top 20 failures
            q_top = (
                "EVALUATE\nVAR _f = FILTER(TestResults, {0})\n"
                "VAR _g = GROUPBY(_f, TestResults[TESTNAME],\n"
                "  \"Runs\", SUMX(CURRENTGROUP(), TestResults[Total]),\n"
                "  \"Pass\", SUMX(CURRENTGROUP(), TestResults[TestPass]),\n"
                "  \"Fail\", SUMX(CURRENTGROUP(), TestResults[TestFail])\n)\n"
                "RETURN TOPN(20, _g, [Fail], DESC)"
            ).format(filt)
            r2 = _run_dax(url, q_top, pbi_token)
            for row in (r2 or {}).get("results", [{}])[0].get("tables", [{}])[0].get("rows", []) or []:
                runs = row.get("[Runs]") or 0
                fail = row.get("[Fail]") or 0
                rate = round(((runs - fail) / runs * 100) if runs else 0, 1)
                dax_data["topFailures"].append({
                    "name": row.get("[TESTNAME]", ""), "runs": runs, "fail": fail, "passRate": rate,
                })

    result["dax"] = dax_data

    # Part B: ADO flaky bugs
    for area in allowed_areas:
        wiql = WIQL_CHECK14_FLAKY_BUGS.format(area=area)
        if not validate_wiql_has_area_filter(wiql, False):
            print("  ABORT check14 flaky bugs: missing area filter", file=sys.stderr)
            continue
        ids = wiql_query(wiql, token)
        if not ids:
            continue
        wis = get_work_items_batch(ids, token, fields=[
            "System.Id", "System.Title", "System.State", "System.AssignedTo", "System.AreaPath",
        ])
        for wi in wis:
            ap = wi.get("fields", {}).get("System.AreaPath", "")
            if not area_path_allowed(ap, allowed_areas):
                continue
            result["ado"]["openFlakyBugs"].append({
                "id": wi["id"],
                "title": wi.get("fields", {}).get("System.Title", ""),
                "owner": get_owner_name(wi),
                "state": wi.get("fields", {}).get("System.State", ""),
                "area": AREA_SHORT.get(ap, ap),
            })
        key = "fundamentalsStatus" if "Join" in area else "notesStatus"
        if len(result["ado"]["openFlakyBugs"]) > 1:
            result["ado"][key] = "critical"
        elif len(result["ado"]["openFlakyBugs"]) == 1:
            result["ado"][key] = "degraded"

    # Determine overall status
    overall = "healthy"
    if dax_data:
        pr = dax_data["passRate"]
        if pr < 75:
            overall = "critical"
        elif pr < 85:
            overall = "degraded"
        broken = len(dax_data.get("brokenTests", []))
        if broken > 3:
            overall = "critical"
        elif broken > 0 and overall != "critical":
            overall = "degraded"
    flaky = len(result["ado"]["openFlakyBugs"])
    if flaky > 1:
        overall = "critical"
    elif flaky == 1 and overall != "critical":
        overall = "degraded"
    result["overallStatus"] = overall
    result["count"] = 0 if overall == "healthy" else max(1, flaky)
    return result


# ---------------------------------------------------------------------------
# HTML report generation
# ---------------------------------------------------------------------------


def _html_escape(s):
    # type: (Any) -> str
    if s is None:
        return ""
    return (
        str(s)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def _wi_link(wid):
    # type: (int) -> str
    return "https://domoreexp.visualstudio.com/MSTeams/_workitems/edit/{0}".format(wid)


def _query_link(ids, label):
    # type: (List[int], str) -> str
    if not ids:
        return ""
    if len(ids) > 100:
        # Skip URL ID list; just label
        return '<span class="query-link">{0} items</span>'.format(len(ids))
    wiql = (
        "SELECT [System.Id],[System.Title],[System.State],[System.AssignedTo],"
        "[System.WorkItemType] FROM workitems WHERE [System.Id] IN ({0}) ORDER BY [System.Id]"
    ).format(",".join(str(x) for x in ids))
    href = "https://domoreexp.visualstudio.com/MSTeams/_workitems?_a=query&wiql={0}".format(
        urllib.parse.quote(wiql)
    )
    return '<a class="query-link" href="{0}">{1}</a>'.format(href, label)


def _row(*cells):
    # type: (Any) -> str
    return "<tr>" + "".join("<td>{0}</td>".format(c) for c in cells) + "</tr>"


def _build_check1_section(res):
    items = res["items"]
    if not items:
        return ""
    rows = []
    ids = [it["childId"] for it in items if it.get("childId")]
    for it in items:
        rows.append(_row(
            '<a href="{0}">{1}</a>'.format(_wi_link(it["childId"]), it["childId"]),
            _html_escape(it["childTitle"]),
            '<a href="{0}">{1}</a>'.format(_wi_link(it["parentId"]), it["parentId"]),
            _html_escape(it.get("parentTitle", "")),
            _html_escape(it.get("owner", "")),
            '<span class="badge badge-fixed">{0}</span>'.format(_html_escape(it.get("action", ""))),
        ))
    return _section_html(
        "Check 1: Task-to-Task Parent Links",
        "{0} fixed".format(len(items)),
        "Tasks should not be parented under another Task. Parent link changed to Related, owner notified.",
        ["Task ID", "Task Title", "Former Parent ID", "Former Parent Title", "Owner", "Action"],
        rows,
        _query_link(ids, "Open all {0} items in ADO query".format(len(items))),
    )


def _build_check2_section(res):
    items = res["items"]
    if not items:
        return ""
    ids = [it["id"] for it in items]
    rows = []
    for it in items:
        rows.append(_row(
            '<a href="{0}">{1}</a>'.format(_wi_link(it["id"]), it["id"]),
            _html_escape(it.get("type", "")),
            _html_escape(it.get("title", "")),
            _html_escape(it.get("owner", "")),
            '<span class="badge badge-closed">{0}</span>'.format(_html_escape(it.get("action", ""))),
        ))
    return _section_html(
        "Check 2: Resolved Items Closed",
        "{0} closed".format(len(items)),
        "Resolved items should be Closed. State changed to Closed with comment.",
        ["ID", "Type", "Title", "Owner", "Action"],
        rows,
        _query_link(ids, "Open all {0} items in ADO query".format(len(items))),
    )


def _build_check2b_section(res):
    items = res["items"]
    if not items:
        return ""
    ids = [it["id"] for it in items]
    rows = []
    for it in items:
        rows.append(_row(
            '<a href="{0}">{1}</a>'.format(_wi_link(it["id"]), it["id"]),
            _html_escape(it.get("title", "")),
            _html_escape(it.get("state", "Blocked")),
            _html_escape(it.get("owner", "")),
            _html_escape(it.get("changedDate", "")),
            '<span class="badge badge-flagged">commented</span>',
        ))
    return _section_html(
        "Check 2b: Blocked Features",
        "{0} flagged".format(len(items)),
        "Features in Blocked state need attention. Owner notified to update or unblock.",
        ["ID", "Title", "State", "Owner", "Last Changed", "Action"],
        rows,
        _query_link(ids, "Open all {0} items in ADO query".format(len(items))),
    )


def _build_check3_section(res, current_name, previous_name):
    items = res["items"]
    if not items:
        return ""
    ids = [it["id"] for it in items]
    rows = []
    for it in items:
        rows.append(_row(
            '<a href="{0}">{1}</a>'.format(_wi_link(it["id"]), it["id"]),
            _html_escape(it.get("type", "")),
            _html_escape(it.get("title", "")),
            _html_escape(it.get("state", "")),
            _html_escape(it.get("owner", "")),
            '<span class="badge badge-moved">{0}</span>'.format(_html_escape(it.get("action", ""))),
        ))
    return _section_html(
        "Check 3: Previous Sprint Leftovers",
        "{0} items".format(len(items)),
        "Non-closed items from {0} surfaced for owner review or moved to {1}.".format(
            _html_escape(previous_name), _html_escape(current_name),
        ),
        ["ID", "Type", "Title", "State", "Owner", "Action"],
        rows,
        _query_link(ids, "Open all {0} items in ADO query".format(len(items))),
    )


def _build_check4_section(res):
    items = res["items"]
    if not items:
        return ""
    ids = [it["id"] for it in items]
    rows = []
    for it in items:
        rows.append(_row(
            '<a href="{0}">{1}</a>'.format(_wi_link(it["id"]), it["id"]),
            _html_escape(it.get("title", "")),
            _html_escape(it.get("state", "")),
            _html_escape(it.get("owner", "")),
            _html_escape(it.get("issue", "")),
            '<span class="badge badge-flagged">{0}</span>'.format(_html_escape(it.get("action", ""))),
        ))
    return _section_html(
        "Check 4: Tasks Missing Estimates or Parent",
        "{0} flagged".format(len(items)),
        "Current sprint tasks must have Original Estimate, Remaining Work, and a parent work item. Owners notified.",
        ["Task ID", "Title", "State", "Owner", "Issue", "Action"],
        rows,
        _query_link(ids, "Open all {0} items in ADO query".format(len(items))),
    )


def _build_check5_section(res):
    items = res["items"]
    if not items:
        return ""
    ids = [it["id"] for it in items]
    rows = []
    for it in items:
        rows.append(_row(
            '<a href="{0}">{1}</a>'.format(_wi_link(it["id"]), it["id"]),
            _html_escape(it.get("title", "")),
            _html_escape(it.get("state", "")),
            _html_escape(it.get("previousSprint", "")),
            _html_escape(it.get("owner", "")),
            '<span class="badge badge-moved">{0}</span>'.format(_html_escape(it.get("action", ""))),
        ))
    return _section_html(
        "Check 5: Stale Bugs Moved to Current Sprint",
        "{0} moved".format(len(items)),
        "Non-closed bugs must be in the current sprint. Moved from their previous iteration.",
        ["Bug ID", "Title", "State", "Previous Sprint", "Owner", "Action"],
        rows,
        _query_link(ids, "Open all {0} items in ADO query".format(len(items))),
    )


def _build_check6_section(res):
    items = res["items"]
    if not items:
        return ""
    ids = [it["id"] for it in items]
    rows = []
    for it in items:
        rows.append(_row(
            '<a href="{0}">{1}</a>'.format(_wi_link(it["id"]), it["id"]),
            _html_escape(it.get("title", "")),
            _html_escape(it.get("state", "")),
            _html_escape(it.get("previousSprint", "")),
            _html_escape(it.get("owner", "")),
            '<span class="badge badge-moved">{0}</span>'.format(_html_escape(it.get("action", ""))),
        ))
    return _section_html(
        "Check 6: Stale Tasks Moved for Review",
        "{0} stale".format(len(items)),
        "Tasks stuck in past, ended sprints. Owner notified or task moved into current sprint.",
        ["Task ID", "Title", "State", "Previous Sprint", "Owner", "Action"],
        rows,
        _query_link(ids, "Open all {0} items in ADO query".format(len(items))),
    )


def _build_check7_section(res):
    items = res["items"]
    if not items:
        return ""
    ids = [it["id"] for it in items]
    rows = []
    for it in items:
        rows.append(_row(
            '<a href="{0}">{1}</a>'.format(_wi_link(it["id"]), it["id"]),
            _html_escape(it.get("title", "")),
            _html_escape(it.get("owner", "")),
            _html_escape(it.get("changedDate", "")),
            _html_escape(it.get("createdDate", "")),
            _html_escape(it.get("area", "")),
        ))
    return _section_html(
        "Check 7: Proposed Bugs &gt; 24 Hours",
        "{0} flagged".format(len(items)),
        "Bugs should not stay in Proposed state for more than 24 hours. Must be triaged to Active or Closed. Summary posted to Teams.",
        ["Bug ID", "Title", "Owner", "Last Changed", "Created", "Area"],
        rows,
        _query_link(ids, "Open all {0} items in ADO query".format(len(items))),
    )


def _build_check8_section(res):
    items = res["items"]
    if not items:
        return ""
    ids = [it["id"] for it in items]
    rows = []
    for it in items:
        rows.append(_row(
            '<a href="{0}">{1}</a>'.format(_wi_link(it["id"]), it["id"]),
            _html_escape(it.get("title", "")),
            _html_escape(it.get("owner", "")),
            _html_escape(it.get("iterationPath", "")),
            _html_escape(it.get("area", "")),
        ))
    return _section_html(
        "Check 8: Committed Features Outside Current Semester",
        "{0} flagged".format(len(items)),
        "Features in Committed state must belong to the current semester. Summary posted to Teams.",
        ["Feature ID", "Title", "Owner", "Iteration", "Area"],
        rows,
        _query_link(ids, "Open all {0} items in ADO query".format(len(items))),
    )


def _build_check9_section(res):
    items = res["items"]
    if not items:
        return ""
    ids = [it["id"] for it in items]
    rows = []
    for it in items:
        rows.append(_row(
            '<a href="{0}">{1}</a>'.format(_wi_link(it["id"]), it["id"]),
            _html_escape(it.get("title", "")),
            _html_escape(it.get("state", "")),
            _html_escape(it.get("owner", "")),
            _html_escape(it.get("createdDate", "")),
            _html_escape(it.get("changedDate", "")),
            _html_escape(it.get("severity", "")),
        ))
    return _section_html(
        "Check 9: Stale Bugs &gt; 90 Days",
        "{0} flagged".format(len(items)),
        "Bugs open for more than 90 days. Consider closing stale transfers and reopening as new bugs with fresh context.",
        ["Bug ID", "Title", "State", "Owner", "Created", "Last Changed", "Severity"],
        rows,
        _query_link(ids, "Open all {0} items in ADO query".format(len(items))),
    )


def _build_check10_section(res):
    items = res["items"]
    if not items:
        return ""
    ids = [it["id"] for it in items]
    rows = []
    for it in items:
        rows.append(_row(
            '<a href="{0}">{1}</a>'.format(_wi_link(it["id"]), it["id"]),
            _html_escape(it.get("title", "")),
            _html_escape(it.get("owner", "")),
            _html_escape(it.get("ring0Date", "")),
            _html_escape(it.get("ring4Date", "")),
            _html_escape(it.get("issue", "")),
        ))
    return _section_html(
        "Check 10: Ring Target Date Issues",
        "{0} flagged".format(len(items)),
        "Active Features with Ring 0 or Ring 4 target dates in the past. Rollout dates should be current.",
        ["Feature ID", "Title", "Owner", "Ring0 Date", "Ring4 Date", "Issue"],
        rows,
        _query_link(ids, "Open all {0} items in ADO query".format(len(items))),
    )


def _build_check11_section(res):
    items = res["items"]
    if not items:
        return ""
    ids = [it["id"] for it in items]
    rows = []
    for it in items:
        rows.append(_row(
            '<a href="{0}">{1}</a>'.format(_wi_link(it["id"]), it["id"]),
            _html_escape(it.get("title", "")),
            _html_escape(it.get("owner", "")),
            _html_escape(", ".join(it.get("missingSignoffs", []))),
        ))
    return _section_html(
        "Check 11: Missing Sign-Offs",
        "{0} flagged".format(len(items)),
        "Active Features missing Security, Accessibility, Privacy, or Compliance sign-offs.",
        ["Feature ID", "Title", "Owner", "Missing Sign-Offs"],
        rows,
        _query_link(ids, "Open all {0} items in ADO query".format(len(items))),
    )


def _build_check12_section(res):
    items = res["items"]
    if not items:
        return ""
    ids = [it["id"] for it in items]
    rows = []
    for it in items:
        rows.append(_row(
            '<a href="{0}">{1}</a>'.format(_wi_link(it["id"]), it["id"]),
            _html_escape(it.get("title", "")),
            _html_escape(it.get("owner", "")),
            _html_escape(it.get("ring0Date", "")),
            _html_escape(it.get("ring4Date", "")),
            _html_escape(it.get("issue", "")),
        ))
    return _section_html(
        "Check 12: Invalid Ring Date Ordering",
        "{0} flagged".format(len(items)),
        "Ring 4 target date must be after Ring 0 target date. R0 missing or R4 &lt;= R0 indicates an invalid rollout plan.",
        ["Feature ID", "Title", "Owner", "Ring0 Date", "Ring4 Date", "Issue"],
        rows,
        _query_link(ids, "Open all {0} items in ADO query".format(len(items))),
    )


def _build_check13_section(res):
    items = res["items"]
    if not items:
        return ""
    rows = []
    for it in items:
        courses = it.get("missing", [])
        course_html_parts = []
        for c in courses:
            url = c.get("url", "")
            title = _html_escape(c.get("title", ""))
            due = _html_escape(c.get("dueDate", ""))
            if url:
                course_html_parts.append('<a href="{0}">{1}</a> (due {2})'.format(
                    _html_escape(url), title, due,
                ))
            else:
                course_html_parts.append("{0} (due {1})".format(title, due))
        rows.append(_row(
            _html_escape(it.get("name", "")),
            "",
            "",
            "",
            "<br>".join(course_html_parts),
        ))
    return _section_html(
        "Check 13: Required Training Compliance",
        "{0} flagged".format(len(items)),
        "Team members with incomplete required trainings (looking 15 days ahead).",
        ["Name", "Completion %", "Required", "Completed", "Missing Courses"],
        rows,
        "",
    )


def _build_check14_section(res):
    if res.get("count", 0) == 0 or res.get("overallStatus") == "healthy":
        return ""
    dax = res.get("dax") or {}
    ado = res.get("ado") or {}
    rows = []
    if dax:
        pr = dax.get("passRate")
        runs = dax.get("totalRuns")
        if pr is not None:
            status_class = "badge-fixed" if pr >= 85 else "badge-flagged" if pr >= 75 else "badge-moved"
            rows.append(_row(
                "CI-Fx DAX (last 7d)",
                '<span class="badge {0}">{1}</span>'.format(status_class,
                    "healthy" if pr >= 85 else "degraded" if pr >= 75 else "critical"),
                "Pass rate: {0}% over {1} runs".format(pr, runs),
                "{0} broken tests".format(len(dax.get("brokenTests", []))),
            ))
    flaky = ado.get("openFlakyBugs", [])
    if flaky:
        status_class = "badge-flagged" if len(flaky) == 1 else "badge-moved"
        bug_list = ", ".join(
            '<a href="{0}">{1}</a>'.format(_wi_link(b["id"]), b["id"]) for b in flaky
        )
        rows.append(_row(
            "Flaky Threshold Bugs (ADO)",
            '<span class="badge {0}">{1}</span>'.format(
                status_class, "degraded" if len(flaky) == 1 else "critical"),
            "{0} open bug(s)".format(len(flaky)),
            bug_list,
        ))
    if not rows:
        return ""
    return _section_html(
        "Check 14: CiFX Dashboard Review",
        "{0} issues".format(res.get("count", 0)),
        "CI-Fx end-to-end test automation health for Meeting Join area.",
        ["Dashboard", "Status", "Key Metrics", "Issues"],
        rows,
        "",
    )


def _section_html(title, count_label, blurb, headers, rows, query_link):
    return (
        '<div class="section">'
        '<h2>{title} <span class="count">{count_label}</span></h2>'
        '<p style="color:var(--vo-text-tertiary); font-size:12px; margin-bottom:12px;">{blurb}</p>'
        '{query_link}'
        '<table><thead><tr>{th}</tr></thead><tbody>{rows}</tbody></table>'
        "</div>"
    ).format(
        title=title,
        count_label=count_label,
        blurb=blurb,
        query_link=query_link or "",
        th="".join("<th>{0}</th>".format(h) for h in headers),
        rows="".join(rows),
    )


def render_report(template_path, results, current_iter, prev_iter,
                  start_dt, complete_dt):
    # type: (str, Dict[str, Any], Dict[str, Any], Optional[Dict[str, Any]], datetime, datetime) -> str
    with open(template_path, "r", encoding="utf-8") as f:
        template = f.read()

    sections = {
        "{{CHECK1_SECTION}}": _build_check1_section(results.get("check1", _empty_result())),
        "{{CHECK2_SECTION}}": _build_check2_section(results.get("check2", _empty_result())),
        "{{CHECK2B_SECTION}}": _build_check2b_section(results.get("check2b", _empty_result())),
        "{{CHECK3_SECTION}}": _build_check3_section(
            results.get("check3", _empty_result()),
            current_iter["name"] if current_iter else "",
            prev_iter["name"] if prev_iter else "",
        ),
        "{{CHECK4_SECTION}}": _build_check4_section(results.get("check4", _empty_result())),
        "{{CHECK5_SECTION}}": _build_check5_section(results.get("check5", _empty_result())),
        "{{CHECK6_SECTION}}": _build_check6_section(results.get("check6", _empty_result())),
        "{{CHECK7_SECTION}}": _build_check7_section(results.get("check7", _empty_result())),
        "{{CHECK8_SECTION}}": _build_check8_section(results.get("check8", _empty_result())),
        "{{CHECK9_SECTION}}": _build_check9_section(results.get("check9", _empty_result())),
        "{{CHECK10_SECTION}}": _build_check10_section(results.get("check10", _empty_result())),
        "{{CHECK11_SECTION}}": _build_check11_section(results.get("check11", _empty_result())),
        "{{CHECK12_SECTION}}": _build_check12_section(results.get("check12", _empty_result())),
        "{{CHECK13_SECTION}}": _build_check13_section(results.get("check13", _empty_result())),
        "{{CHECK14_SECTION}}": _build_check14_section(results.get("check14", _empty_result())),
    }

    # Compute summary numbers
    check_keys = ["check1", "check2", "check2b", "check3", "check4", "check5",
                  "check6", "check7", "check8", "check9", "check10", "check11",
                  "check12", "check13", "check14"]
    total_checks = len(check_keys)
    checks_with_issues = sum(
        1 for k in check_keys
        if results.get(k, {}).get("count", 0) > 0
    )
    checks_passed = total_checks - checks_with_issues
    total_actions = sum(results.get(k, {}).get("count", 0) for k in check_keys)

    all_clear = ""
    if checks_with_issues == 0:
        all_clear = '<div class="section all-clear">All checks passed - no hygiene issues found.</div>'

    subtitle = "Agent: Scrum Master | Job: shiproom-hygiene-check | Start: {0} | Complete: {1}".format(
        start_dt.strftime("%Y-%m-%d %H:%M %Z") or start_dt.strftime("%Y-%m-%d %H:%M PST"),
        complete_dt.strftime("%Y-%m-%d %H:%M %Z") or complete_dt.strftime("%Y-%m-%d %H:%M PST"),
    )

    replacements = {
        "{{VO_SUBTITLE}}": subtitle,
        "{{DATE}}": complete_dt.strftime("%Y-%m-%d"),
        "{{CURRENT_SPRINT}}": current_iter["name"] if current_iter else "",
        "{{PREVIOUS_SPRINT}}": prev_iter["name"] if prev_iter else "",
        "{{FUTURE_SPRINT}}": current_iter["name"] if current_iter else "",
        "{{TOTAL_CHECKS}}": str(total_checks),
        "{{CHECKS_PASSED}}": str(checks_passed),
        "{{CHECKS_WITH_ISSUES}}": str(checks_with_issues),
        "{{TOTAL_ACTIONS}}": str(total_actions),
        "{{ALL_CLEAR_SECTION}}": all_clear,
    }
    replacements.update(sections)

    out = template
    for k, v in replacements.items():
        out = out.replace(k, v)
    # Strip any leftover {{...}} placeholders -- the template's comment
    # blocks include unused reference placeholders (e.g. CHECK1_QUERY_LINK)
    # that documentation rather than active substitutions.
    import re as _re
    out = _re.sub(r"\{\{[A-Za-z0-9_]+\}\}", "", out)
    return out


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------


def parse_args(argv=None):
    # type: (Optional[List[str]]) -> argparse.Namespace
    p = argparse.ArgumentParser(description="Shiproom hygiene checks (pinned).")
    p.add_argument("--dry-run", action="store_true",
                   help="No PATCH or comment writes; only plan log is written.")
    p.add_argument("--limit-checks", default="",
                   help="Comma-separated list of check IDs to run (e.g. 1,2,3). Default: all.")
    p.add_argument("--cap", type=int, default=DEFAULT_MUTATION_CAP,
                   help="Per-run PATCH cap (default {0}).".format(DEFAULT_MUTATION_CAP))
    p.add_argument("--today", default="",
                   help="Override 'today' for testing (YYYY-MM-DD).")
    p.add_argument("--output-dir", default=OUTPUT_DIR,
                   help="Output directory for reports + audit logs.")
    return p.parse_args(argv)


def _parse_limit(s):
    # type: (str) -> Optional[List[str]]
    if not s:
        return None
    return [x.strip() for x in s.split(",") if x.strip()]


def main(argv=None):
    # type: (Optional[List[str]]) -> int
    args = parse_args(argv)
    start_dt = datetime.now(PST)
    if args.today:
        today = datetime.strptime(args.today, "%Y-%m-%d").date()
    else:
        today = start_dt.date()
    print("Shiproom hygiene check starting at {0}".format(start_dt.isoformat()))
    print("Today: {0}".format(today.isoformat()))

    allowed_areas = compute_allowed_areas(today)
    semester = compute_semester(today)
    print("Allowed areas: {0}".format(allowed_areas))
    print("Semester: {0}".format(semester))

    output_dir = args.output_dir
    os.makedirs(output_dir, exist_ok=True)
    ts_label = start_dt.strftime("%Y%m%d-%H%M%S")
    plan_path = os.path.join(output_dir, "hygiene-patch-plan-{0}.jsonl".format(ts_label))
    audit_path = os.path.join(output_dir, "hygiene-mutations-{0}.jsonl".format(today.isoformat()))
    mc = MutationController(plan_path, audit_path, cap=args.cap, dry_run=args.dry_run)
    print("Plan log: {0}".format(plan_path))
    print("Audit log: {0}".format(audit_path))
    print("Mutation cap: {0}  Dry run: {1}".format(args.cap, args.dry_run))

    # Acquire tokens
    try:
        ado_token = get_ado_token()
        print("ADO token acquired.")
    except Exception as e:
        print("FATAL: cannot acquire ADO token: {0}".format(e), file=sys.stderr)
        return 2

    pbi_token = None  # type: Optional[str]
    try:
        pbi_token = get_pbi_token()
        print("PBI token acquired.")
    except Exception as e:
        print("PBI token unavailable: {0}".format(e), file=sys.stderr)

    # Resolve iterations
    iters = get_team_iterations(ado_token)
    current_iter, prev_iter = find_current_and_previous(iters, today)
    if not current_iter:
        print("FATAL: no current iteration found", file=sys.stderr)
        return 3
    sem_iters = semester_iterations(iters, semester)
    curr_start = _parse_iter_date(current_iter["attributes"].get("startDate"))
    if curr_start:
        days_in = (today - curr_start).days
        grace_period = days_in < 5
        grace_days = max(0, 5 - days_in) if grace_period else 0
    else:
        grace_period = False
        grace_days = 0
    print("Current sprint: {0} ({1})".format(current_iter.get("name"), current_iter.get("path")))
    if prev_iter:
        print("Previous sprint: {0}".format(prev_iter.get("name")))
    print("Grace period: {0} ({1}d remaining)".format(grace_period, grace_days))

    limit = _parse_limit(args.limit_checks)

    def should_run(key):
        if limit is None:
            return True
        return key in limit

    results = {}  # type: Dict[str, Any]

    if should_run("1"):
        results["check1"] = check1(ado_token, allowed_areas, mc, args.dry_run)
    if should_run("2"):
        results["check2"] = check2(ado_token, allowed_areas, mc, args.dry_run)
    if should_run("2b"):
        results["check2b"] = check2b(ado_token, allowed_areas)
    if should_run("3"):
        results["check3"] = check3(ado_token, allowed_areas, mc, args.dry_run,
                                   current_iter, prev_iter, grace_period, grace_days)
    if should_run("4"):
        results["check4"] = check4(ado_token, allowed_areas, current_iter, args.dry_run)
    if should_run("5"):
        results["check5"] = check5(ado_token, allowed_areas, mc, args.dry_run, current_iter)
    if should_run("6"):
        results["check6"] = check6(ado_token, allowed_areas, mc, args.dry_run,
                                   current_iter, prev_iter, sem_iters,
                                   grace_period, grace_days, semester, today)
    if should_run("7"):
        results["check7"] = check7(ado_token, allowed_areas)
    if should_run("8"):
        results["check8"] = check8(ado_token, allowed_areas, semester)
    if should_run("9"):
        results["check9"] = check9(ado_token, allowed_areas)
    if should_run("10"):
        results["check10"] = check10(ado_token, allowed_areas, semester, today)
    if should_run("11"):
        results["check11"] = check11(ado_token, allowed_areas, semester)
    if should_run("12"):
        results["check12"] = check12(ado_token, allowed_areas, semester)
    if should_run("13"):
        results["check13"] = check13(pbi_token)
    if should_run("14"):
        results["check14"] = check14(ado_token, pbi_token, allowed_areas, start_dt)

    complete_dt = datetime.now(PST)

    # Build flat teams summary
    summary = {
        "generated": complete_dt.isoformat(),
        "sprint": current_iter.get("name", ""),
        "currentSprintPath": current_iter.get("path", ""),
        "previousSprintName": prev_iter.get("name") if prev_iter else "",
        "previousSprintPath": prev_iter.get("path") if prev_iter else "",
        "gracePeriod": grace_period,
        "graceDaysRemaining": grace_days,
        "dryRun": args.dry_run,
        "mutationCount": mc.count,
        "mutationCap": args.cap,
    }
    for key in ["check2b", "check4", "check5", "check6", "check7", "check8",
                "check9", "check10", "check11", "check12", "check13", "check14"]:
        summary[key] = results.get(key, _empty_result())

    summary_path = os.path.join(output_dir, "hygiene-teams-summary.json")
    with open(summary_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)
    print("Teams summary: {0}".format(summary_path))

    full_path = os.path.join(output_dir, "hygiene-full-results.json")
    full = dict(summary)
    full["all"] = results
    with open(full_path, "w", encoding="utf-8") as f:
        json.dump(full, f, indent=2, ensure_ascii=False)
    print("Full results: {0}".format(full_path))

    # Render HTML report
    if os.path.exists(TEMPLATE_PATH):
        html = render_report(TEMPLATE_PATH, results, current_iter, prev_iter,
                             start_dt, complete_dt)
        ts_name = "shiproom-hygiene-{0}.html".format(ts_label)
        ts_path = os.path.join(output_dir, ts_name)
        latest_path = os.path.join(output_dir, "shiproom-hygiene-latest.html")
        for p in (ts_path, latest_path):
            with open(p, "w", encoding="utf-8") as f:
                f.write(html)
        print("HTML report: {0}".format(ts_path))
        print("HTML latest: {0}".format(latest_path))
    else:
        print("WARN: template not found at {0}; skipping HTML render.".format(TEMPLATE_PATH),
              file=sys.stderr)

    # Print summary
    total_actions = sum(r.get("count", 0) for r in results.values() if isinstance(r, dict))
    checks_with_issues = sum(1 for r in results.values() if isinstance(r, dict) and r.get("count", 0) > 0)
    print("\n=== SUMMARY ===")
    print("Checks run: {0}".format(len(results)))
    print("Checks with issues: {0}".format(checks_with_issues))
    print("Total actions/items: {0}".format(total_actions))
    print("Mutations executed: {0}/{1}".format(mc.count, args.cap))
    print("Completed: {0}".format(complete_dt.isoformat()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
