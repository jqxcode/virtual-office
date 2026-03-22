#!/usr/bin/env python3
"""Compare scrum-master dry-run reports, detect problems, and create GitHub issues."""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime
from html.parser import HTMLParser
from pathlib import Path

OUTPUT_DIR = Path(__file__).resolve().parent.parent / "output" / "scrum-master"
SUMMARIES_DIR = OUTPUT_DIR / "run-summaries"
STATE_FILE = SUMMARIES_DIR / "issue-state.json"

# ── HTML parsers ──────────────────────────────────────────────────────────────

class CardParser(HTMLParser):
    """Extract summary card numbers and labels from ADO/bug autopilot HTML."""
    def __init__(self):
        super().__init__()
        self.cards = []
        self._in_num = False
        self._in_lbl = False
        self._cur = {}

    def handle_starttag(self, tag, attrs):
        cls = dict(attrs).get("class", "")
        if tag == "div" and "num" in cls.split():
            self._in_num = True
        elif tag == "div" and "lbl" in cls.split():
            self._in_lbl = True

    def handle_data(self, data):
        if self._in_num:
            self._cur["num"] = data.strip()
            self._in_num = False
        elif self._in_lbl:
            self._cur["lbl"] = data.strip()
            self._in_lbl = False
            self.cards.append(self._cur)
            self._cur = {}


class ADOFeatureParser(HTMLParser):
    """Extract feature rows from ADO autopilot HTML tables."""
    def __init__(self):
        super().__init__()
        self.features = []
        self._in_td = False
        self._td_idx = 0
        self._row = {}
        self._in_row = False
        self._buf = ""

    def handle_starttag(self, tag, attrs):
        ad = dict(attrs)
        if tag == "tr" and "style" in ad and "border-left" in ad.get("style", ""):
            self._in_row = True
            self._td_idx = 0
            self._row = {}
        elif tag == "td" and self._in_row:
            self._in_td = True
            self._buf = ""
        elif tag == "a" and self._in_td and self._td_idx == 0:
            href = ad.get("href", "")
            m = re.search(r"/(\d+)$", href)
            if m:
                self._row["id"] = m.group(1)

    def handle_data(self, data):
        if self._in_td:
            self._buf += data

    def handle_endtag(self, tag):
        if tag == "td" and self._in_td:
            self._in_td = False
            text = self._buf.strip()
            if self._td_idx == 0 and "id" not in self._row:
                self._row["id"] = text
            elif self._td_idx == 4:
                # Status column
                text_upper = text.upper()
                if "UPDATED" in text_upper:
                    self._row["status"] = "updated"
                elif "SKIPPED" in text_upper:
                    self._row["status"] = "skipped"
                elif "LOW CONFIDENCE" in text_upper:
                    self._row["status"] = "low_confidence"
                elif "NO CHANGE" in text_upper:
                    self._row["status"] = "no_change"
                else:
                    self._row["status"] = text
            self._td_idx += 1
        elif tag == "tr" and self._in_row:
            self._in_row = False
            if self._row.get("id"):
                self.features.append(self._row)


class BugRowParser(HTMLParser):
    """Extract bug investigation rows from bug autopilot HTML."""
    def __init__(self):
        super().__init__()
        self.bugs = []
        self._in_td = False
        self._td_idx = 0
        self._row = {}
        self._in_row = False
        self._buf = ""

    def handle_starttag(self, tag, attrs):
        ad = dict(attrs)
        if tag == "tr" and ad.get("id", "").startswith("row-"):
            self._in_row = True
            self._td_idx = 0
            self._row = {"id": ad["id"].replace("row-", "")}
        elif tag == "td" and self._in_row:
            self._in_td = True
            self._buf = ""

    def handle_data(self, data):
        if self._in_td:
            self._buf += data

    def handle_endtag(self, tag):
        if tag == "td" and self._in_td:
            self._in_td = False
            text = self._buf.strip()
            if self._td_idx == 2:
                text_upper = text.upper()
                if "NEEDS HUMAN" in text_upper:
                    self._row["status"] = "needs_human"
                elif "ROUTED" in text_upper:
                    self._row["status"] = "routed"
                elif "FIX IDENTIFIED" in text_upper:
                    self._row["status"] = "fix_identified"
                else:
                    self._row["status"] = text
            elif self._td_idx == 3:
                m = re.search(r"(\d+)%", text)
                if m:
                    self._row["confidence"] = int(m.group(1))
            self._td_idx += 1
        elif tag == "tr" and self._in_row:
            self._in_row = False
            if self._row.get("id"):
                self.bugs.append(self._row)


# ── Report parsing ────────────────────────────────────────────────────────────

def parse_ado_html(path):
    """Parse an ADO autopilot HTML report, return dict with cards + features."""
    html = path.read_text(encoding="utf-8", errors="replace")

    # Determine report type from title
    report_type = "unknown"
    if "Meeting Join" in html or "meeting-join" in path.name:
        report_type = "meeting-join"
    elif "Meeting Notes" in html or "meeting-notes" in path.name:
        report_type = "meeting-notes"

    # Parse cards (first cards div = tweets, second = burndown)
    cp = CardParser()
    cp.feed(html)

    cards = {}
    for c in cp.cards:
        lbl = c.get("lbl", "").lower()
        try:
            val = int(c["num"])
        except (ValueError, KeyError):
            val = 0
        # Only capture first occurrence (tweet section); burndown section comes second
        if "total" in lbl and "total" not in cards:
            cards["total"] = val
        elif "updated" in lbl and "updated" not in cards:
            cards["updated"] = val
        elif "low conf" in lbl and "low_confidence" not in cards:
            cards["low_confidence"] = val
        elif "no change" in lbl and "no_change" not in cards:
            cards["no_change"] = val
        elif "skipped" in lbl and "skipped" not in cards:
            cards["skipped"] = val

    # Parse features
    fp = ADOFeatureParser()
    fp.feed(html)

    # Extract generation date
    gen_date = None
    m = re.search(r"Generated\s+(\d{8})", html)
    if m:
        gen_date = m.group(1)

    return {
        "path": str(path),
        "report_type": report_type,
        "gen_date": gen_date,
        "cards": cards,
        "features": fp.features,
    }


def parse_bug_html(path):
    """Parse a bug autopilot HTML report."""
    html = path.read_text(encoding="utf-8", errors="replace")

    cp = CardParser()
    cp.feed(html)

    cards = {}
    for c in cp.cards:
        lbl = c.get("lbl", "").lower()
        try:
            val = int(c["num"])
        except (ValueError, KeyError):
            val = 0
        if "total" in lbl:
            cards["total"] = val
        elif "new" in lbl:
            cards["new"] = val
        elif "routed" in lbl:
            cards["routed"] = val
        elif "fix" in lbl:
            cards["fix_identified"] = val
        elif "needs human" in lbl or "human" in lbl:
            cards["needs_human"] = val
        elif "prev" in lbl:
            cards["prev_run"] = val

    bp = BugRowParser()
    bp.feed(html)

    gen_date = None
    m = re.search(r"Generated\s+([\d\-T:Z]+)", html)
    if m:
        gen_date = m.group(1)

    return {
        "path": str(path),
        "gen_date": gen_date,
        "cards": cards,
        "bugs": bp.bugs,
    }


# ── Issue detection ───────────────────────────────────────────────────────────

def detect_issues(ado_reports, bug_reports):
    """Analyze parsed reports and return list of detected issues."""
    issues = []

    # ── ADO autopilot issues ──
    all_features = []
    total_updated = 0
    total_skipped = 0
    total_low_conf = 0
    total_features = 0

    for r in ado_reports:
        c = r["cards"]
        total_features += c.get("total", 0)
        total_updated += c.get("updated", 0)
        total_skipped += c.get("skipped", 0)
        total_low_conf += c.get("low_confidence", 0)
        all_features.extend(r["features"])

    # Check: high skip rate
    if total_features > 0 and total_skipped / total_features >= 0.5:
        issues.append({
            "key": "ado-autopilot-high-skip-rate",
            "repo": "teams-microsoft/ado-autopilot",
            "title": f"[Tool Issue] {total_skipped}/{total_features} features skipped across latest reports",
            "body": (
                f"## Problem\n\n"
                f"Across the latest ADO autopilot reports, **{total_skipped} of {total_features}** features "
                f"({total_skipped*100//total_features}%) were skipped.\n\n"
                f"Most skip reasons cite **WorkIQ MCP tools unavailable** — the agent cannot "
                f"gather new signals when WorkIQ is down, so it carries forward stale tweets.\n\n"
                f"## Impact\n\n"
                f"- Status tweets become stale and lose value for stakeholders\n"
                f"- Features with real progress go unreported\n\n"
                f"## Reports analyzed\n\n"
                + "\n".join(f"- `{r['path']}`" for r in ado_reports)
                + "\n\n---\n*Auto-detected by virtual-office Compare-Runs.py*"
            ),
        })

    # Check: low confidence rate
    if total_features > 0 and total_low_conf / total_features > 0.3:
        issues.append({
            "key": "ado-autopilot-high-low-confidence",
            "repo": "teams-microsoft/ado-autopilot",
            "title": f"[Tool Issue] {total_low_conf}/{total_features} features at low confidence",
            "body": (
                f"## Problem\n\n"
                f"**{total_low_conf} of {total_features}** features ({total_low_conf*100//total_features}%) "
                f"were flagged as low confidence in the latest reports.\n\n"
                f"Low confidence means the agent found some signal but isn't sure enough "
                f"to auto-update — these need human review.\n\n"
                f"## Reports analyzed\n\n"
                + "\n".join(f"- `{r['path']}`" for r in ado_reports)
                + "\n\n---\n*Auto-detected by virtual-office Compare-Runs.py*"
            ),
        })

    # Check: zero updates
    if total_features > 0 and total_updated == 0:
        issues.append({
            "key": "ado-autopilot-zero-updates",
            "repo": "teams-microsoft/ado-autopilot",
            "title": f"[Tool Issue] Zero successful updates across latest reports",
            "body": (
                f"## Problem\n\n"
                f"No features were successfully updated across **{len(ado_reports)}** reports "
                f"({total_features} total features).\n\n"
                f"## Reports analyzed\n\n"
                + "\n".join(f"- `{r['path']}`" for r in ado_reports)
                + "\n\n---\n*Auto-detected by virtual-office Compare-Runs.py*"
            ),
        })

    # ── Bug autopilot issues ──
    for r in bug_reports:
        c = r["cards"]
        total_bugs = c.get("total", 0)
        needs_human = c.get("needs_human", 0)
        routed = c.get("routed", 0)
        fix_id = c.get("fix_identified", 0)

        # All needs human
        if total_bugs > 0 and needs_human == total_bugs:
            run_date = r['gen_date'][:10] if r.get('gen_date') else 'latest'
            issues.append({
                "key": "bug-autopilot-all-needs-human",
                "repo": "teams-microsoft/bug-autopilot",
                "title": f"[Tool Issue] All {total_bugs} bugs returned needs_human on {run_date}",
                "body": (
                    f"## All Investigations Returned needs_human\n\n"
                    f"**Run date**: {run_date}\n"
                    f"**Total bugs**: {total_bugs}\n\n"
                    f"Every bug in this run was classified as `needs_human`, meaning the tool\n"
                    f"produced zero actionable fixes or routing decisions.\n\n"
                    f"### Possible Causes\n"
                    f"- Telemetry data aged out for all bugs (>30 day retention)\n"
                    f"- BRB logs unavailable for all sessions\n"
                    f"- Bug descriptions too vague for automated investigation\n"
                    f"- Confidence threshold (0.7) may be too aggressive for current capabilities\n\n"
                    f"### Bug details\n\n"
                    + "\n".join(
                        f"- [{b['id']}](https://domoreexp.visualstudio.com/MSTeams/_workitems/edit/{b['id']}) "
                        f"— confidence: {b.get('confidence', '?')}%"
                        for b in r.get("bugs", [])
                    )
                    + f"\n\n### Report\n\n`{r['path']}`"
                    + "\n\n---\n*Generated by Virtual Office scrum-master Compare-Runs*"
                ),
            })

        # Telemetry access failure: all bugs have very low confidence
        low_conf_bugs = [b for b in r.get("bugs", []) if b.get("confidence", 100) <= 30]
        if len(r.get("bugs", [])) >= 3 and len(low_conf_bugs) == len(r.get("bugs", [])):
            issues.append({
                "key": "bug-autopilot-telemetry-access-failure",
                "repo": "teams-microsoft/bug-autopilot",
                "title": f"[Tool Error] Telemetry unavailable for 100% of bugs ({len(low_conf_bugs)}/{len(r.get('bugs', []))})",
                "body": (
                    f"## Problem\n\n"
                    f"All **{len(low_conf_bugs)}** bugs had confidence <= 30%, indicating "
                    f"the agent could not access telemetry for any of them.\n\n"
                    f"## Report\n\n`{r['path']}`"
                    + "\n\n---\n*Auto-detected by virtual-office Compare-Runs.py*"
                ),
            })

        # Stagnant investigations: bugs re-investigated with no improvement
        stagnant = [b for b in r.get("bugs", []) if b.get("status") == "needs_human" and b.get("confidence", 0) <= 30]
        if stagnant and c.get("prev_run", 0) > 0:
            issues.append({
                "key": "bug-autopilot-stagnant-investigation",
                "repo": "teams-microsoft/bug-autopilot",
                "title": f"[Tool Issue] {len(stagnant)} bugs re-investigated with no confidence gain",
                "body": (
                    f"## Problem\n\n"
                    f"**{len(stagnant)}** bugs were re-investigated from a previous run but still "
                    f"show needs_human status with low confidence.\n\n"
                    f"## Stagnant bugs\n\n"
                    + "\n".join(
                        f"- [{b['id']}](https://domoreexp.visualstudio.com/MSTeams/_workitems/edit/{b['id']}) "
                        f"— confidence: {b.get('confidence', '?')}%"
                        for b in stagnant
                    )
                    + f"\n\n## Report\n\n`{r['path']}`"
                    + "\n\n---\n*Auto-detected by virtual-office Compare-Runs.py*"
                ),
            })

    return issues


# ── State management ──────────────────────────────────────────────────────────

def load_state():
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    return {"created_issues": {}}


def save_state(state):
    SUMMARIES_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2), encoding="utf-8")
    tmp.replace(STATE_FILE)


# ── GitHub issue creation ─────────────────────────────────────────────────────

def create_github_issue(repo, title, body, dry_run=False):
    """Create a GitHub issue via gh CLI. Returns issue URL or None."""
    if dry_run:
        print(f"  [DRY RUN] Would create issue in {repo}: {title}")
        return None

    try:
        result = subprocess.run(
            ["gh", "issue", "create", "--repo", repo, "--title", title, "--body", body],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode == 0:
            url = result.stdout.strip()
            print(f"  Created: {url}")
            return url
        else:
            print(f"  ERROR creating issue: {result.stderr.strip()}")
            return None
    except Exception as e:
        print(f"  ERROR: {e}")
        return None


# ── Summary generation ────────────────────────────────────────────────────────

def generate_summary(ado_reports, bug_reports, issues, state, new_issues_created):
    """Generate markdown + HTML comparison summary."""
    now = datetime.now()
    ts = now.strftime("%Y%m%d-%H%M%S")

    # Aggregate ADO stats
    total_features = sum(r["cards"].get("total", 0) for r in ado_reports)
    total_updated = sum(r["cards"].get("updated", 0) for r in ado_reports)
    total_skipped = sum(r["cards"].get("skipped", 0) for r in ado_reports)
    total_low_conf = sum(r["cards"].get("low_confidence", 0) for r in ado_reports)
    total_no_change = sum(r["cards"].get("no_change", 0) for r in ado_reports)

    # Bug stats from latest
    bug_total = sum(r["cards"].get("total", 0) for r in bug_reports)
    bug_needs_human = sum(r["cards"].get("needs_human", 0) for r in bug_reports)
    bug_routed = sum(r["cards"].get("routed", 0) for r in bug_reports)
    bug_fix = sum(r["cards"].get("fix_identified", 0) for r in bug_reports)

    # ── Markdown summary ──
    md_lines = [
        "# Scrum-Master Run Comparison Summary",
        f"**Generated**: {now.strftime('%Y-%m-%d %H:%M')}",
        "",
        "## ADO Autopilot (Status Tweets)",
        "",
        f"**Reports analyzed**: {len(ado_reports)}",
    ]
    for r in ado_reports:
        md_lines.append(f"- `{Path(r['path']).name}` ({r['report_type']})")
    md_lines += [
        f"- Total features: {total_features}",
        f"- Updated: {total_updated}",
        f"- Skipped: {total_skipped}",
        f"- No change: {total_no_change}",
        f"- Low confidence: {total_low_conf}",
        "",
    ]

    ado_issues = [i for i in issues if "ado-autopilot" in i["key"]]
    if ado_issues:
        md_lines.append("### Tool Issues Found")
        md_lines.append("")
        for idx, i in enumerate(ado_issues, 1):
            tracked = state["created_issues"].get(i["key"])
            status = f" ([#{tracked['url'].split('/')[-1]}]({tracked['url']}))" if tracked and tracked.get("url") else " (new)" if i["key"] in new_issues_created else ""
            md_lines.append(f"{idx}. **{i['title']}**{status}")
        md_lines.append("")

    md_lines += [
        "## Bug Autopilot (Investigations)",
        "",
        f"**Reports analyzed**: {len(bug_reports)}",
        f"- Total bugs: {bug_total}",
        f"- Needs human: {bug_needs_human}",
        f"- Routed: {bug_routed}",
        f"- Fix identified: {bug_fix}",
        "",
    ]

    bug_issues = [i for i in issues if "bug-autopilot" in i["key"]]
    if bug_issues:
        md_lines.append("### Tool Issues Found")
        md_lines.append("")
        for idx, i in enumerate(bug_issues, 1):
            tracked = state["created_issues"].get(i["key"])
            status = f" ([#{tracked['url'].split('/')[-1]}]({tracked['url']}))" if tracked and tracked.get("url") else " (new)" if i["key"] in new_issues_created else ""
            md_lines.append(f"{idx}. **{i['title']}**{status}")
        md_lines.append("")

    md_lines += [
        "## Summary",
        "",
        f"- **{len(issues)}** issues detected",
        f"- **{len(new_issues_created)}** new GitHub issues created",
        f"- **{len(issues) - len(new_issues_created)}** already tracked",
    ]

    md_content = "\n".join(md_lines) + "\n"

    # ── HTML summary ──
    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Scrum-Master Run Comparison</title>
  <style>
    body {{ font-family: Segoe UI, sans-serif; max-width: 1200px; margin: 36px auto; padding: 0 24px; color: #212529; background: #f9fafb; }}
    h1 {{ font-size: 22px; margin-bottom: 4px; }}
    .meta {{ font-size: 13px; color: #6c757d; margin-bottom: 24px; }}
    .cards {{ display: flex; gap: 12px; margin-bottom: 20px; flex-wrap: wrap; }}
    .card {{ background: #fff; border: 1px solid #dee2e6; border-radius: 8px; padding: 14px 20px; min-width: 120px; text-align: center; }}
    .card .num {{ font-size: 28px; font-weight: 700; }}
    .card .lbl {{ font-size: 11px; color: #6c757d; margin-top: 2px; text-transform: uppercase; letter-spacing: .4px; }}
    h2 {{ font-size: 17px; margin-top: 28px; border-bottom: 2px solid #dee2e6; padding-bottom: 6px; }}
    .issue {{ background: #fff; border: 1px solid #e9ecef; border-radius: 8px; padding: 14px 18px; margin-bottom: 10px; }}
    .issue.new {{ border-left: 4px solid #fd7e14; }}
    .issue.tracked {{ border-left: 4px solid #198754; }}
    .issue .title {{ font-weight: 600; font-size: 14px; }}
    .issue .status {{ font-size: 12px; color: #6c757d; margin-top: 4px; }}
    .issue a {{ color: #0d6efd; text-decoration: none; }}
    .section {{ margin-bottom: 32px; }}
  </style>
</head>
<body>
  <h1>Scrum-Master Run Comparison</h1>
  <div class="meta">Generated {now.strftime('%Y-%m-%d %H:%M')} &bull; {len(ado_reports)} ADO reports, {len(bug_reports)} bug reports</div>

  <div class="cards">
    <div class="card"><div class="num">{total_features}</div><div class="lbl">Features</div></div>
    <div class="card"><div class="num" style="color:#198754">{total_updated}</div><div class="lbl">Updated</div></div>
    <div class="card"><div class="num" style="color:#fd7e14">{total_low_conf}</div><div class="lbl">Low Conf</div></div>
    <div class="card"><div class="num" style="color:#856404">{total_skipped}</div><div class="lbl">Skipped</div></div>
    <div class="card"><div class="num">{bug_total}</div><div class="lbl">Bugs</div></div>
    <div class="card"><div class="num" style="color:#856404">{bug_needs_human}</div><div class="lbl">Needs Human</div></div>
    <div class="card"><div class="num" style="color:#198754">{bug_routed + bug_fix}</div><div class="lbl">Actionable</div></div>
  </div>

  <div class="cards">
    <div class="card"><div class="num">{len(issues)}</div><div class="lbl">Issues Detected</div></div>
    <div class="card"><div class="num" style="color:#fd7e14">{len(new_issues_created)}</div><div class="lbl">New Issues</div></div>
    <div class="card"><div class="num" style="color:#198754">{len(issues) - len(new_issues_created)}</div><div class="lbl">Already Tracked</div></div>
  </div>

  <h2>ADO Autopilot</h2>
  <div class="section">
"""
    for r in ado_reports:
        name = Path(r["path"]).name
        c = r["cards"]
        html_content += f'    <div style="font-size:13px;margin-bottom:6px"><code>{name}</code> &mdash; {c.get("total",0)} features, {c.get("updated",0)} updated, {c.get("skipped",0)} skipped, {c.get("low_confidence",0)} low conf</div>\n'
    html_content += "  </div>\n\n  <h2>Bug Autopilot</h2>\n  <div class=\"section\">\n"
    for r in bug_reports:
        name = Path(r["path"]).name
        c = r["cards"]
        html_content += f'    <div style="font-size:13px;margin-bottom:6px"><code>{name}</code> &mdash; {c.get("total",0)} bugs, {c.get("needs_human",0)} needs human, {c.get("routed",0)} routed, {c.get("fix_identified",0)} fix identified</div>\n'
    html_content += "  </div>\n\n  <h2>Detected Issues</h2>\n  <div class=\"section\">\n"

    for i in issues:
        tracked = state["created_issues"].get(i["key"])
        is_new = i["key"] in new_issues_created
        css_class = "new" if is_new else "tracked"
        if tracked and tracked.get("url"):
            status_html = f'<a href="{tracked["url"]}">#{tracked["url"].split("/")[-1]}</a> &mdash; tracked'
        elif is_new and new_issues_created[i["key"]]:
            url = new_issues_created[i["key"]]
            status_html = f'<a href="{url}">#{url.split("/")[-1]}</a> &mdash; just created'
        else:
            status_html = "detected (no issue created)"
        html_content += f'    <div class="issue {css_class}"><div class="title">{i["title"]}</div><div class="status">{i["repo"]} &bull; {status_html}</div></div>\n'

    if not issues:
        html_content += '    <div style="font-size:14px;color:#198754;padding:16px">No issues detected &mdash; all reports look healthy.</div>\n'

    html_content += """  </div>
</body>
</html>
"""

    # Write files
    SUMMARIES_DIR.mkdir(parents=True, exist_ok=True)
    md_path = SUMMARIES_DIR / f"comparison-{ts}.md"
    md_latest = SUMMARIES_DIR / "comparison-latest.md"
    html_path = SUMMARIES_DIR / f"comparison-{ts}.html"
    html_latest = SUMMARIES_DIR / "comparison-latest.html"

    md_path.write_text(md_content, encoding="utf-8")
    md_latest.write_text(md_content, encoding="utf-8")
    html_path.write_text(html_content, encoding="utf-8")
    html_latest.write_text(html_content, encoding="utf-8")

    return html_path


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Compare scrum-master dry-run reports")
    parser.add_argument("--dry-run", action="store_true", help="Don't create GitHub issues")
    args = parser.parse_args()

    print("=== Scrum-Master Run Comparison ===\n")

    # Discover reports
    ado_htmls = sorted(OUTPUT_DIR.glob("dry-run-meeting-*-latest.html"))
    bug_htmls = sorted(OUTPUT_DIR.glob("dry-run-bug-autopilot-latest.html"))

    print(f"Found {len(ado_htmls)} ADO autopilot reports:")
    for p in ado_htmls:
        print(f"  - {p.name}")
    print(f"Found {len(bug_htmls)} bug autopilot reports:")
    for p in bug_htmls:
        print(f"  - {p.name}")
    print()

    # Parse
    ado_reports = [parse_ado_html(p) for p in ado_htmls]
    bug_reports = [parse_bug_html(p) for p in bug_htmls]

    for r in ado_reports:
        c = r["cards"]
        print(f"  {Path(r['path']).name}: {c.get('total',0)} features, "
              f"{c.get('updated',0)} updated, {c.get('skipped',0)} skipped, "
              f"{c.get('low_confidence',0)} low conf")
    for r in bug_reports:
        c = r["cards"]
        print(f"  {Path(r['path']).name}: {c.get('total',0)} bugs, "
              f"{c.get('needs_human',0)} needs human, {c.get('routed',0)} routed")
    print()

    # Detect issues
    issues = detect_issues(ado_reports, bug_reports)
    print(f"Detected {len(issues)} issues:")
    for i in issues:
        print(f"  - [{i['repo']}] {i['title']}")
    print()

    # Load state and create issues
    state = load_state()
    new_issues_created = {}

    for issue in issues:
        if issue["key"] in state["created_issues"]:
            existing = state["created_issues"][issue["key"]]
            print(f"  SKIP (already tracked): {issue['key']} -> {existing.get('url', 'no url')}")
            continue

        print(f"  Creating issue: {issue['key']}...")
        url = create_github_issue(issue["repo"], issue["title"], issue["body"], dry_run=args.dry_run)
        state["created_issues"][issue["key"]] = {
            "url": url,
            "created_at": datetime.now().isoformat(),
            "title": issue["title"],
        }
        new_issues_created[issue["key"]] = url

    # Save state
    save_state(state)
    print(f"\nState saved to {STATE_FILE}")

    # Generate summary
    html_path = generate_summary(ado_reports, bug_reports, issues, state, new_issues_created)
    print(f"Summary written to {html_path}")

    print(f"\n=== Done: {len(issues)} issues detected, {len(new_issues_created)} new issues created ===")
    return str(html_path)


if __name__ == "__main__":
    html_path = main()
    print(f"\nOPEN:{html_path}")
