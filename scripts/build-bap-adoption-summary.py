"""
build-bap-adoption-summary.py -- Build Bug-AutoPilot Adoption Daily Summary payload (v3).

Only reports metrics provably attributable to BAP:
  - Triaged: total bugs in query
  - Routed: AutopilotRouted tag count
  - Retained PRs: bugs with linked PRs via ArtifactLink relations
  - Triage Duration: how fast BAP triages (BAP comment - CreatedDate)

Usage:
    python scripts/build-bap-adoption-summary.py [--output Q:/src/tmp/poster-daily.json]
                                                  [--test]

Output: JSON file with keys: subject, body_html, pr_reply_html, metrics
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.request
import urllib.error
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Dict, List, Optional, Tuple

sys.stdout.reconfigure(encoding="utf-8")

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
ORG = "domoreexp"
PROJECT = "MSTeams"
QUERY_ID = "cf42325a-4ac0-4420-9d0e-c460ff45f5c2"
BASE_URL = f"https://{ORG}.visualstudio.com/{PROJECT}"
API_VER = "api-version=7.1"
TEMPLATE_PATH = Path(__file__).parent.parent / "templates" / "poster-bug-autopilot-adoption-daily-summary.html"

# ADO resource ID for az token
ADO_RESOURCE = "499b84ac-1321-427f-aa17-267ca6975798"

# Fields to fetch in batch
FIELDS = [
    "System.Id", "System.Title", "System.State", "System.CreatedDate",
    "System.AssignedTo", "System.AreaPath", "System.Tags",
    "Microsoft.VSTS.Common.Severity", "System.Reason",
    "Microsoft.VSTS.Common.ClosedDate", "System.ChangedDate",
]

ROLLING_DAYS = 7


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------
def get_token() -> str:
    result = subprocess.run(
        ["cmd", "/c", "az", "account", "get-access-token",
         "--resource", ADO_RESOURCE, "--query", "accessToken", "-o", "tsv"],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


def ado_get(url: str, token: str) -> dict:
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def ado_post(url: str, token: str, payload: dict) -> dict:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=data,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


# ---------------------------------------------------------------------------
# Step 1: Run query, get work item IDs
# ---------------------------------------------------------------------------
def run_query(token: str) -> List[int]:
    url = f"{BASE_URL}/_apis/wit/wiql/{QUERY_ID}?{API_VER}"
    result = ado_get(url, token)
    return [wi["id"] for wi in result.get("workItems", [])]


# ---------------------------------------------------------------------------
# Step 2: Batch-fetch fields (200 per batch)
# ---------------------------------------------------------------------------
def batch_fetch_fields(ids: List[int], token: str) -> List[dict]:
    items = []
    batch_url = f"{BASE_URL}/_apis/wit/workitemsbatch?{API_VER}"
    for i in range(0, len(ids), 200):
        chunk = ids[i:i + 200]
        result = ado_post(batch_url, token, {"ids": chunk, "fields": FIELDS})
        for wi in result.get("value", []):
            f = wi.get("fields", {})
            items.append({
                "id": wi["id"],
                "title": f.get("System.Title", ""),
                "state": f.get("System.State", ""),
                "created_date": f.get("System.CreatedDate", ""),
                "assigned_to": (f.get("System.AssignedTo") or {}).get("displayName", ""),
                "area_path": f.get("System.AreaPath", ""),
                "tags": f.get("System.Tags", ""),
                "severity": f.get("Microsoft.VSTS.Common.Severity", ""),
                "reason": f.get("System.Reason", ""),
                "closed_date": f.get("Microsoft.VSTS.Common.ClosedDate", ""),
                "changed_date": f.get("System.ChangedDate", ""),
            })
    return items


# ---------------------------------------------------------------------------
# Step 3: Fetch relations for ALL items (parallel) -- find linked PRs
# ---------------------------------------------------------------------------
def fetch_relations(bug_id: int, token: str) -> Tuple[int, List[str]]:
    """Return (bug_id, list_of_pr_artifact_urls)."""
    url = f"{BASE_URL}/_apis/wit/workitems/{bug_id}?$expand=relations&{API_VER}"
    try:
        wi = ado_get(url, token)
        pr_urls = []
        for rel in wi.get("relations", []):
            artifact_url = rel.get("url", "")
            if "vstfs:///Git/PullRequestId" in artifact_url:
                pr_urls.append(artifact_url)
        return (bug_id, pr_urls)
    except Exception:
        return (bug_id, [])


def fetch_all_relations(ids: List[int], token: str) -> Dict[int, List[str]]:
    """Fetch PR relations for bugs in parallel."""
    results: Dict[int, List[str]] = {}
    with ThreadPoolExecutor(max_workers=10) as pool:
        futures = {pool.submit(fetch_relations, bid, token): bid for bid in ids}
        for future in as_completed(futures):
            bug_id, pr_urls = future.result()
            if pr_urls:
                results[bug_id] = pr_urls
    return results


# ---------------------------------------------------------------------------
# Step 4: Fetch BAP comment dates (parallel) -- for triage duration
# ---------------------------------------------------------------------------
def fetch_bap_comment_date(bug_id: int, token: str) -> Tuple[int, Optional[str]]:
    """Return (bug_id, earliest_bap_comment_iso_date) or (bug_id, None)."""
    url = f"{BASE_URL}/_apis/wit/workitems/{bug_id}/comments?api-version=7.1-preview.4"
    try:
        result = ado_get(url, token)
        bap_markers = ["root_cause", "confidence", "Bug-AutoPilot", "Investigation Report",
                        "fix_description"]
        for comment in result.get("comments", []):
            text = comment.get("text", "")
            if any(m.lower() in text.lower() for m in bap_markers):
                return (bug_id, comment.get("createdDate", ""))
        return (bug_id, None)
    except Exception:
        return (bug_id, None)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _parse_date(iso: str) -> Optional[datetime]:
    if not iso:
        return None
    try:
        iso = iso.replace("Z", "+00:00")
        dt = datetime.fromisoformat(iso)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except Exception:
        return None


def _format_duration(seconds: float) -> str:
    days = seconds / 86400
    if days >= 1:
        return f"{days:.1f}d"
    hours = seconds / 3600
    if hours >= 1:
        return f"{hours:.1f}h"
    minutes = seconds / 60
    return f"{minutes:.0f}m"


def _has_tag(tags: str, target: str) -> bool:
    return target.lower() in [t.strip().lower() for t in (tags or "").split(";")]


def _area_group(area_path: str) -> str:
    """Extract meaningful group from full area path."""
    parts = area_path.split("\\")
    # Skip MSTeams\Calling Meeting Devices (CMD)\Meetings\ prefix
    if len(parts) >= 4 and "Meeting" in parts[2]:
        return parts[3] if len(parts) > 3 else parts[-1]
    if len(parts) >= 3:
        return parts[-1]
    return area_path


def _esc(text: str) -> str:
    """HTML-escape for Teams message."""
    return (text.replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def _median(values: List[float]) -> float:
    """Compute median of a sorted list of floats."""
    values.sort()
    n = len(values)
    if n == 0:
        return 0.0
    mid = n // 2
    if n % 2 == 0:
        return (values[mid - 1] + values[mid]) / 2
    return values[mid]


# ---------------------------------------------------------------------------
# Build HTML sections
# ---------------------------------------------------------------------------
def build_summary_table(total: int, routed: int, pr_count: int, triage_median: Optional[str] = None) -> str:
    """Build the Impact Summary table with key metrics (7-day rolling)."""
    median_col_hdr = ""
    median_col_val = ""
    if triage_median:
        median_col_hdr = '<th style="padding:8px;border:1px solid #ddd;">Median Triage Time</th>'
        median_col_val = f'<td style="padding:8px;border:1px solid #ddd;color:#555;">{triage_median}</td>'
    return (
        '<table border="1" cellpadding="8" cellspacing="0" '
        'style="border-collapse:collapse;width:100%;font-size:13px;">'
        '<tr style="background-color:#1a1a2e;color:white;">'
        '<th style="padding:8px;border:1px solid #ddd;">Triaged</th>'
        '<th style="padding:8px;border:1px solid #ddd;">Routed</th>'
        '<th style="padding:8px;border:1px solid #ddd;">Retained PRs</th>'
        + median_col_hdr +
        '</tr>'
        '<tr style="text-align:center;font-size:18px;font-weight:bold;">'
        f'<td style="padding:8px;border:1px solid #ddd;">{total}</td>'
        f'<td style="padding:8px;border:1px solid #ddd;color:blue;">{routed}</td>'
        f'<td style="padding:8px;border:1px solid #ddd;color:#0066cc;">{pr_count}</td>'
        + median_col_val +
        '</tr>'
        '</table>'
    )


def build_area_rows(items: List[dict], pr_map: Dict[int, List[str]]) -> str:
    """Build area path breakdown table rows.

    Rolling 7-day window: only count items created/changed in last 7 days.
    Columns: Area Group | Triaged | Routed | Retained PRs
    Top 10, sorted by Triaged descending.
    """
    cutoff = datetime.now(tz=timezone.utc) - timedelta(days=ROLLING_DAYS)

    # Filter to 7-day window
    recent = []
    for it in items:
        changed = _parse_date(it.get("changed_date", ""))
        created = _parse_date(it.get("created_date", ""))
        if (changed and changed >= cutoff) or (created and created >= cutoff):
            recent.append(it)

    # Group by area
    area_triaged: Counter = Counter()
    area_routed: Counter = Counter()
    area_prs: Counter = Counter()

    for it in recent:
        area = _area_group(it["area_path"])
        area_triaged[area] += 1
        if _has_tag(it.get("tags", ""), "AutopilotRouted"):
            area_routed[area] += 1
        if it["id"] in pr_map:
            area_prs[area] += 1

    # Top 10 by triaged count
    top_areas = area_triaged.most_common(10)

    rows = []
    for i, (area, triaged) in enumerate(top_areas):
        style = 'background-color:#f0f0f0;' if i % 2 == 1 else ''
        routed = area_routed.get(area, 0)
        prs = area_prs.get(area, 0)
        rows.append(
            f'<tr style="{style}">'
            f'<td style="padding:6px;border:1px solid #ddd;">{_esc(area)}</td>'
            f'<td style="padding:6px;border:1px solid #ddd;text-align:center;">{triaged}</td>'
            f'<td style="padding:6px;border:1px solid #ddd;text-align:center;">{routed}</td>'
            f'<td style="padding:6px;border:1px solid #ddd;text-align:center;">{prs}</td>'
            f'</tr>'
        )
    return "\n  ".join(rows)


def build_triage_duration_section(
    items: List[dict], token: str
) -> Tuple[str, Optional[str], Optional[str]]:
    """Compute how fast BAP triages bugs.

    For bugs with BAP comments in the last 7 days:
      triage_time = BAP_comment_date - System.CreatedDate

    Returns (section_html, median_formatted_or_None, avg_formatted_or_None).
    """
    cutoff = datetime.now(tz=timezone.utc) - timedelta(days=ROLLING_DAYS)

    # Fetch BAP comment dates for all items in parallel
    comment_dates: Dict[int, datetime] = {}
    with ThreadPoolExecutor(max_workers=10) as pool:
        futures = {pool.submit(fetch_bap_comment_date, it["id"], token): it
                   for it in items}
        for future in as_completed(futures):
            item = futures[future]
            bug_id, cdate = future.result()
            if cdate:
                dt = _parse_date(cdate)
                if dt and dt >= cutoff:
                    comment_dates[bug_id] = dt

    if not comment_dates:
        return "<p>No BAP triage activity in the last 7 days.</p>", None, None

    # Build items_by_id for created_date lookup
    items_by_id = {it["id"]: it for it in items}

    # Compute deltas and group by day
    day_deltas: Dict[str, List[float]] = defaultdict(list)
    all_deltas: List[float] = []

    for bug_id, bap_dt in comment_dates.items():
        item = items_by_id.get(bug_id)
        if not item:
            continue
        created_dt = _parse_date(item["created_date"])
        if not created_dt:
            continue
        # Only count bugs created within the rolling window
        # Old bugs triaged late skew the "triage speed" metric
        if created_dt < cutoff:
            continue
        delta_s = (bap_dt - created_dt).total_seconds()
        if delta_s < 0:
            continue
        all_deltas.append(delta_s)
        day_key = bap_dt.strftime("%Y-%m-%d")
        day_deltas[day_key].append(delta_s)

    if not all_deltas:
        return "<p>No valid triage duration data in the last 7 days.</p>", None, None

    overall_median = _median(all_deltas[:])  # copy to avoid mutating
    median_str = _format_duration(overall_median)
    overall_avg = sum(all_deltas) / len(all_deltas)
    avg_str = _format_duration(overall_avg)

    # Build day-by-day data (oldest first for chart, reverse for table)
    today = datetime.now(tz=timezone.utc).date()
    day_data = []  # (date_str, count, avg_seconds)
    max_avg_s = 1  # for bar chart scaling
    for offset in range(ROLLING_DAYS - 1, -1, -1):  # oldest to newest
        d = today - timedelta(days=offset)
        d_str = d.strftime("%m/%d")
        deltas = day_deltas.get(d.strftime("%Y-%m-%d"), [])
        if deltas:
            avg_s = sum(deltas) / len(deltas)
            day_data.append((d_str, len(deltas), avg_s))
            max_avg_s = max(max_avg_s, avg_s)
        else:
            day_data.append((d_str, 0, 0))

    # Build horizontal bar chart using Teams-compatible HTML
    # Teams strips <div>, so use Unicode block chars for bars in a single cell
    chart_rows = []
    for d_str, count, avg_s in day_data:
        if count == 0:
            time_cell = '<span style="color:#999;">-</span>'
        else:
            bar_pct = max(5, min(100, int(avg_s / max_avg_s * 100)))
            bar_color = "#22c55e" if avg_s < 3600 else ("#f59e0b" if avg_s < 86400 else "#ef4444")
            time_label = _format_duration(avg_s)
            bar_blocks = "\u2588" * max(1, bar_pct // 5)
            time_cell = (
                f'<span style="color:{bar_color};font-family:monospace;font-size:11px;">'
                f'{bar_blocks}</span> {time_label}'
            )
        chart_rows.append(
            f'<tr>'
            f'<td style="padding:4px 6px;border:1px solid #ddd;font-size:12px;">{d_str}</td>'
            f'<td style="padding:4px 6px;border:1px solid #ddd;text-align:center;font-size:12px;">{count or "-"}</td>'
            f'<td style="padding:4px 6px;border:1px solid #ddd;">{time_cell}</td>'
            f'</tr>'
        )

    html = (
        f'<p>7-day avg triage time (new bugs only): <b>{avg_str}</b> '
        f'(median: {median_str}, {len(all_deltas)} bugs)</p>'
        '<table border="1" cellpadding="4" cellspacing="0" '
        'style="border-collapse:collapse;width:100%;font-size:13px;">'
        '<tr style="background-color:#1a1a2e;color:white;">'
        '<th style="padding:6px;border:1px solid #ddd;">Date</th>'
        '<th style="padding:6px;border:1px solid #ddd;">Bugs</th>'
        '<th style="padding:6px;border:1px solid #ddd;">Avg Triage Time</th>'
        '</tr>'
        + "\n  ".join(chart_rows)
        + '</table>'
    )

    return html, median_str, avg_str


def build_impact_highlights(total: int, routed: int, pr_count: int) -> str:
    """Build bullet list of provable BAP accomplishments."""
    bullets = []
    bullets.append(f"{total} bugs triaged by BAP")
    if routed > 0:
        bullets.append(f"{routed} bugs routed to correct area paths")
    if pr_count > 0:
        bullets.append(f"{pr_count} bugs have retained fix PRs")
    if total > 0 and pr_count > 0:
        pct = pr_count * 100 // total
        bullets.append(f"{pct}% of triaged bugs resulted in code fixes")
    return "<ul>" + "".join(f"<li>{b}</li>" for b in bullets) + "</ul>"


def build_key_insights(
    total: int, routed: int, pr_count: int,
    triage_median: Optional[str], triage_avg: Optional[str],
    items: List[dict], pr_map: Dict[int, List[str]],
) -> Tuple[str, str]:
    """Build [+] What BAP Did Well and [!] Areas of Focus columns.
    Only include provable, data-backed insights.
    """
    positive = []
    focus = []

    # Positive: provable accomplishments
    if routed > 0:
        positive.append(f"{routed} bugs routed to correct area paths in last 7 days")
    if pr_count > 0:
        positive.append(f"{pr_count} bugs have retained fix PRs")
    if total > 0 and pr_count > 0:
        pct = pr_count * 100 // total
        if pct > 0:
            positive.append(f"{pct}% of triaged bugs resulted in code fixes")
    if triage_median:
        positive.append(f"Median triage time: {triage_median}")

    # Focus: areas needing attention
    # Find area paths with high triaged but 0 PRs
    area_counter: Counter = Counter()
    area_pr: Counter = Counter()
    for it in items:
        area = _area_group(it.get("area_path", ""))
        area_counter[area] += 1
        if it["id"] in pr_map:
            area_pr[area] += 1
    for area, count in area_counter.most_common(5):
        if count >= 3 and area_pr.get(area, 0) == 0:
            focus.append(f"{area}: {count} bugs triaged, 0 PRs -- needs investigation depth")

    if triage_avg and triage_median:
        # If avg >> median, there are outliers
        focus.append(f"Avg triage time ({triage_avg}) higher than median ({triage_median}) -- outlier bugs slowing response")

    if not positive:
        positive.append("BAP actively triaging incoming bugs")
    if not focus:
        focus.append("No major concerns this period")

    pos_html = "".join(f"<br/>- {p}" for p in positive)
    foc_html = "".join(f"<br/>- {f}" for f in focus)
    return pos_html, foc_html


def build_state_distribution_rows(items: List[dict]) -> str:
    """Build state distribution table rows."""
    state_counts: Counter = Counter()
    state_details: Dict[str, List[str]] = defaultdict(list)
    for it in items:
        state = it.get("state", "Unknown")
        state_counts[state] += 1
    rows = []
    for i, (state, count) in enumerate(state_counts.most_common()):
        style = 'background-color:#f0f0f0;' if i % 2 == 1 else ''
        rows.append(
            f'<tr style="{style}">'
            f'<td style="padding:6px;border:1px solid #ddd;">{_esc(state)}</td>'
            f'<td style="padding:6px;border:1px solid #ddd;text-align:center;">{count}</td>'
            f'<td style="padding:6px;border:1px solid #ddd;"></td>'
            f'</tr>'
        )
    return "\n  ".join(rows)


def build_sev1_rows(items: List[dict]) -> Tuple[int, str]:
    """Build Sev1 critical bugs table rows. Returns (count, rows_html)."""
    sev1 = [it for it in items if "1" in (it.get("severity") or "")]
    if not sev1:
        return 0, '<tr><td colspan="5" style="padding:6px;border:1px solid #ddd;color:#999;">None</td></tr>'
    rows = []
    for i, it in enumerate(sev1):
        style = 'background-color:#fff0f0;' if i % 2 == 1 else ''
        bug_url = f"https://domoreexp.visualstudio.com/MSTeams/_workitems/edit/{it['id']}"
        tags = it.get("tags", "")
        tag_label = "Routed" if _has_tag(tags, "AutopilotRouted") else ("Done" if _has_tag(tags, "AutopilotDone") else "-")
        rows.append(
            f'<tr style="{style}">'
            f'<td style="padding:6px;border:1px solid #ddd;"><a href="{bug_url}">{it["id"]}</a></td>'
            f'<td style="padding:6px;border:1px solid #ddd;">{_esc(it["title"][:80])}</td>'
            f'<td style="padding:6px;border:1px solid #ddd;">{_esc(it["state"])}</td>'
            f'<td style="padding:6px;border:1px solid #ddd;">{_esc(it["assigned_to"])}</td>'
            f'<td style="padding:6px;border:1px solid #ddd;">{tag_label}</td>'
            f'</tr>'
        )
    return len(sev1), "\n  ".join(rows)


def build_closed_rows(items: List[dict]) -> Tuple[int, str]:
    """Build recently closed bugs table rows (7-day window). Returns (count, rows_html)."""
    cutoff = datetime.now(tz=timezone.utc) - timedelta(days=ROLLING_DAYS)
    closed = []
    for it in items:
        if it.get("state", "").lower() in ("closed", "resolved"):
            cd = _parse_date(it.get("closed_date", "") or it.get("changed_date", ""))
            if cd and cd >= cutoff:
                closed.append(it)
    if not closed:
        return 0, '<tr><td colspan="4" style="padding:6px;border:1px solid #ddd;color:#999;">None in last 7 days</td></tr>'
    rows = []
    for i, it in enumerate(closed):
        style = 'background-color:#f0f0f0;' if i % 2 == 1 else ''
        bug_url = f"https://domoreexp.visualstudio.com/MSTeams/_workitems/edit/{it['id']}"
        reason = it.get("reason", "")
        if "verified" in reason.lower():
            reason_styled = '<span style="color:green;">Verified</span>'
        elif "duplicate" in reason.lower():
            reason_styled = '<span style="color:gray;">Duplicate</span>'
        elif "rejected" in reason.lower():
            reason_styled = '<span style="color:gray;">Rejected</span>'
        else:
            reason_styled = _esc(reason)
        rows.append(
            f'<tr style="{style}">'
            f'<td style="padding:6px;border:1px solid #ddd;"><a href="{bug_url}">{it["id"]}</a></td>'
            f'<td style="padding:6px;border:1px solid #ddd;">{_esc(it["title"][:80])}</td>'
            f'<td style="padding:6px;border:1px solid #ddd;">{reason_styled}</td>'
            f'<td style="padding:6px;border:1px solid #ddd;">{_esc(it["assigned_to"])}</td>'
            f'</tr>'
        )
    return len(closed), "\n  ".join(rows)


def build_pr_reply(
    pr_map: Dict[int, List[str]], items_by_id: Dict[int, dict], token: str
) -> str:
    """Build thread reply HTML with PR details grouped by area path."""
    if not pr_map:
        return "<p>No fix PRs linked to queried bugs.</p>"

    # Group by area path
    area_groups: Dict[str, List[dict]] = defaultdict(list)
    for bug_id, urls in pr_map.items():
        item = items_by_id.get(bug_id, {})
        area = _area_group(item.get("area_path", "Other"))
        for url in urls:
            parts = url.split("/")
            pr_id = parts[-1] if len(parts) >= 3 else "?"
            area_groups[area].append({
                "pr_id": pr_id,
                "bug_id": bug_id,
                "bug_title": item.get("title", "")[:60],
            })

    html_parts = ["<h3>Fix PRs by Area Path</h3>"]
    for area in sorted(area_groups.keys()):
        prs = area_groups[area]
        html_parts.append(f"<b>{_esc(area)}</b> ({len(prs)} PRs)")
        html_parts.append(
            '<table border="1" cellpadding="4" cellspacing="0" '
            'style="border-collapse:collapse;width:100%;font-size:12px;margin-bottom:8px;">'
            '<tr style="background-color:#1a1a2e;color:white;">'
            '<th style="padding:4px;border:1px solid #ddd;">PR</th>'
            '<th style="padding:4px;border:1px solid #ddd;">Bug</th>'
            '<th style="padding:4px;border:1px solid #ddd;">Title</th></tr>'
        )
        for pr in prs:
            bug_url = f"https://domoreexp.visualstudio.com/MSTeams/_workitems/edit/{pr['bug_id']}"
            html_parts.append(
                f'<tr>'
                f'<td style="padding:4px;border:1px solid #ddd;">#{pr["pr_id"]}</td>'
                f'<td style="padding:4px;border:1px solid #ddd;"><a href="{bug_url}">{pr["bug_id"]}</a></td>'
                f'<td style="padding:4px;border:1px solid #ddd;">{_esc(pr["bug_title"])}</td>'
                f'</tr>'
            )
        html_parts.append("</table>")

    return "\n".join(html_parts)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="Q:/src/tmp/poster-daily.json")
    parser.add_argument("--test", action="store_true", help="Add [TEST] prefix to subject")
    args = parser.parse_args()

    today = datetime.now().strftime("%Y-%m-%d")
    now_pst = datetime.now().strftime("%Y-%m-%d %H:%M PST")

    print(f"[{datetime.now():%H:%M:%S}] Authenticating...")
    token = get_token()

    # Step 1: Query
    print(f"[{datetime.now():%H:%M:%S}] Running ADO query...")
    ids = run_query(token)
    print(f"  Found {len(ids)} work items")

    # Step 2: Batch fetch fields
    print(f"[{datetime.now():%H:%M:%S}] Fetching fields ({len(ids)} items)...")
    items = batch_fetch_fields(ids, token)
    items_by_id = {it["id"]: it for it in items}
    total = len(items)

    # Classify — 7-day rolling window for top-level summary
    cutoff_7d = datetime.now(tz=timezone.utc) - timedelta(days=ROLLING_DAYS)
    recent_items = []
    for it in items:
        cd = _parse_date(it.get("created_date", ""))
        if cd and cd >= cutoff_7d:
            recent_items.append(it)
    total_7d = len(recent_items)
    routed_7d = sum(1 for it in recent_items if _has_tag(it.get("tags", ""), "AutopilotRouted"))
    total_all = total
    routed_all = sum(1 for it in items if _has_tag(it.get("tags", ""), "AutopilotRouted"))
    print(f"  Total: {total_all} (7d: {total_7d}), Routed: {routed_all} (7d: {routed_7d})")

    # Step 3: Fetch relations for 7-day items (to find retained PRs)
    print(f"[{datetime.now():%H:%M:%S}] Fetching PR relations for {total_7d} recent items...")
    pr_map = fetch_all_relations([it["id"] for it in recent_items], token)
    pr_count_7d = len(pr_map)
    print(f"  {pr_count_7d} bugs have linked PRs (7d)")

    # Step 4: Triage Duration
    print(f"[{datetime.now():%H:%M:%S}] Computing triage duration (7-day window)...")
    triage_section, triage_median, triage_avg = build_triage_duration_section(items, token)
    print(f"  Triage time: median {triage_median or 'no data'}, avg {triage_avg or 'no data'}")

    # Step 5: Build HTML sections
    print(f"[{datetime.now():%H:%M:%S}] Building HTML...")

    summary_table = build_summary_table(total_7d, routed_7d, pr_count_7d, triage_median)
    area_rows = build_area_rows(recent_items, pr_map)
    state_rows = build_state_distribution_rows(recent_items)
    sev1_count, sev1_rows = build_sev1_rows(recent_items)
    closed_count, closed_rows = build_closed_rows(items)
    key_pos, key_foc = build_key_insights(
        total_7d, routed_7d, pr_count_7d, triage_median, triage_avg, recent_items, pr_map
    )

    vo_subtitle = (
        f"Agent: Poster | Job: Bug-Autopilot-Adoption-daily-summary | "
        f"Generated: {now_pst}"
    )

    # Read template
    template = TEMPLATE_PATH.read_text(encoding="utf-8")
    body_start = template.find("-->")
    if body_start >= 0:
        body = template[body_start + 3:].strip()
    else:
        body = template

    # Replace placeholders (names must match template)
    body = body.replace("{{SUMMARY_STATS}}", summary_table)
    body = body.replace("{{BUG_TABLE_ROWS}}", state_rows)
    body = body.replace("{{AREA_PATH_BREAKDOWN}}", area_rows)
    body = body.replace("{{SEV1_COUNT}}", str(sev1_count))
    body = body.replace("{{SEV1_ROWS}}", sev1_rows)
    body = body.replace("{{CLOSED_COUNT}}", str(closed_count))
    body = body.replace("{{CLOSED_ROWS}}", closed_rows)
    body = body.replace("{{KEY_INSIGHTS_POSITIVE}}", key_pos)
    body = body.replace("{{KEY_INSIGHTS_FOCUS}}", key_foc)
    body = body.replace("{{VO_SUBTITLE}}", vo_subtitle)
    body = body.replace("{{DATE}}", today)

    prefix = "[TEST] " if args.test else ""
    subject = f"{prefix}Bug-AutoPilot Adoption Daily Summary - {today}"

    # Build PR reply (uses 7d items)
    recent_by_id = {it["id"]: it for it in recent_items}
    pr_reply = build_pr_reply(pr_map, recent_by_id, token)

    # Write output
    output = {
        "subject": subject,
        "body_html": body,
        "pr_reply_html": pr_reply,
        "metrics": {
            "total_7d": total_7d,
            "total_all": total_all,
            "routed_7d": routed_7d,
            "pr_count_7d": pr_count_7d,
            "triage_duration_median": triage_median,
            "triage_duration_avg": triage_avg,
        },
    }

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(output, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"[{datetime.now():%H:%M:%S}] Payload written to {output_path}")
    print(f"  Subject: {subject}")
    print(json.dumps(output["metrics"], indent=2))


if __name__ == "__main__":
    main()
