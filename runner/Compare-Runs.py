#!/usr/bin/env python3
"""Compare scrum-master dry-run reports across runs and file GitHub issues.

Parses ADO autopilot HTML reports and bug autopilot investigations.json,
compares across timestamped runs, and creates GitHub issues for each
discovered problem.

Usage:
    python Compare-Runs.py                    # Compare + create issues
    python Compare-Runs.py --dry-run          # Compare only, no issue creation
    python Compare-Runs.py --since 2026-03-16 # Only consider runs after date
"""

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta
from html.parser import HTMLParser
from pathlib import Path

# --- Paths ---
OUTPUT_DIR = Path("Q:/src/personal_projects/virtual-office/output/scrum-master")
BUG_INVESTIGATIONS = Path("Q:/src/hackathon/bug-autopilot/reports/investigations.json")
ADO_REPORTS_DIR = Path("Q:/src/hackathon/ado-autopilot/reports")
SUMMARY_DIR = OUTPUT_DIR / "run-summaries"
STATE_FILE = SUMMARY_DIR / "issue-state.json"

ADO_REPO = "teams-microsoft/ado-autopilot"
BUG_REPO = "teams-microsoft/bug-autopilot"


# ============================================================
# ADO Autopilot HTML Parser
# ============================================================

class ADOReportParser(HTMLParser):
    """Parse ADO autopilot combined-report HTML into structured data."""

    def __init__(self):
        super().__init__()
        self._in_card_num = False
        self._in_card_lbl = False
        self._cards = []
        self._cur_card = {}
        self._in_td = False
        self._in_a = False
        self._td_buf = ""
        self._a_href = ""
        self._row = []
        self._rows = []
        self._in_thead = False
        self._section = ""  # "tweets" or "burndown"
        self._in_h2 = False
        self._h2_buf = ""
        self._tweet_cards = []
        self._burndown_cards = []
        self._style_stack = []

    def handle_starttag(self, tag, attrs):
        d = dict(attrs)
        cls = d.get("class", "")
        style = d.get("style", "")

        if tag == "h2":
            self._in_h2 = True
            self._h2_buf = ""
        elif tag == "div" and cls == "num":
            self._in_card_num = True
        elif tag == "div" and cls == "lbl":
            self._in_card_lbl = True
        elif tag == "thead":
            self._in_thead = True
        elif tag == "td":
            self._in_td = True
            self._td_buf = ""
            self._a_href = ""
        elif tag == "a" and self._in_td:
            self._in_a = True
            self._a_href = d.get("href", "")
        elif tag == "tr" and not self._in_thead:
            self._row = []
            # Capture row border color for status
            self._style_stack.append(style)

    def handle_endtag(self, tag):
        if tag == "h2":
            self._in_h2 = False
            t = self._h2_buf.lower()
            if "tweet" in t or "status" in t:
                self._section = "tweets"
            elif "burndown" in t:
                self._section = "burndown"
            elif "feature" in t or "detail" in t:
                self._section = "features"
        elif tag == "div" and self._in_card_num:
            self._in_card_num = False
        elif tag == "div" and self._in_card_lbl:
            self._in_card_lbl = False
            card = dict(self._cur_card)
            if self._section == "burndown":
                self._burndown_cards.append(card)
            else:
                self._tweet_cards.append(card)
            self._cards.append(card)
            self._cur_card = {}
        elif tag == "thead":
            self._in_thead = False
        elif tag == "a" and self._in_a:
            self._in_a = False
        elif tag == "td":
            self._in_td = False
            self._row.append({"text": self._td_buf.strip(), "href": self._a_href})
        elif tag == "tr" and self._row and not self._in_thead:
            if len(self._row) >= 5:
                self._rows.append({
                    "cells": self._row,
                    "style": self._style_stack[-1] if self._style_stack else "",
                })
            self._row = []
            if self._style_stack:
                self._style_stack.pop()

    def handle_data(self, data):
        if self._in_card_num:
            self._cur_card["num"] = data.strip()
        elif self._in_card_lbl:
            self._cur_card["lbl"] = data.strip()
        elif self._in_h2:
            self._h2_buf += data
        elif self._in_td:
            self._td_buf += data

    def handle_entityref(self, name):
        if self._in_td:
            self._td_buf += f"&{name};"
        elif self._in_h2:
            self._h2_buf += f"&{name};"

    def handle_charref(self, name):
        if self._in_td:
            self._td_buf += f"&#{name};"

    def parse_features(self):
        """Return list of feature dicts from parsed rows."""
        features = []
        for row in self._rows:
            cells = row["cells"]
            # Extract work item ID from first cell href or text
            wi_id = ""
            href = cells[0]["href"]
            if href:
                m = re.search(r"/(\d+)$", href)
                if m:
                    wi_id = m.group(1)
            if not wi_id:
                m = re.search(r"#?(\d+)", cells[0]["text"])
                if m:
                    wi_id = m.group(1)

            title = cells[1]["text"] if len(cells) > 1 else ""
            current_tweet = cells[2]["text"] if len(cells) > 2 else ""
            proposed_tweet = cells[3]["text"] if len(cells) > 3 else ""
            status_text = cells[4]["text"] if len(cells) > 4 else ""
            evidence = cells[8]["text"] if len(cells) > 8 else ""

            # Determine status
            status = "unknown"
            st = status_text.upper()
            if "UPDATED" in st:
                status = "updated"
            elif "SKIPPED" in st:
                status = "skipped"
            elif "NO CHANGE" in st:
                status = "no_change"
            elif "LOW" in st:
                status = "low_conf"

            # Extract confidence %
            conf_match = re.search(r"(\d+)%", status_text)
            confidence = int(conf_match.group(1)) / 100 if conf_match else None

            features.append({
                "wi_id": wi_id,
                "title": title.split("\n")[0].strip(),
                "current_tweet": current_tweet.strip(),
                "proposed_tweet": proposed_tweet.strip(),
                "status": status,
                "confidence": confidence,
                "evidence": evidence.strip(),
            })
        return features


def parse_ado_report(html_path):
    """Parse an ADO autopilot HTML report into structured data."""
    with open(html_path, encoding="utf-8") as f:
        html = f.read()
    parser = ADOReportParser()
    parser.feed(html)

    # Extract timestamp from filename or meta
    ts_match = re.search(r"(\d{8})[- _](\d{6})", html_path.name)
    timestamp = None
    if ts_match:
        timestamp = datetime.strptime(
            f"{ts_match.group(1)}{ts_match.group(2)}", "%Y%m%d%H%M%S"
        ).isoformat()

    # Extract from meta tag
    if not timestamp:
        m = re.search(r"Generated\s+(\d{8})\s+(\d+)", html)
        if m:
            timestamp = f"{m.group(1)}T{m.group(2)}"

    tweet_cards = {c.get("lbl", ""): c.get("num", "0") for c in parser._tweet_cards}
    return {
        "timestamp": timestamp,
        "file": str(html_path.name),
        "summary": {
            "total": int(tweet_cards.get("Total", 0)),
            "updated": int(tweet_cards.get("Updated (\u226575%)", tweet_cards.get("Updated", 0))),
            "low_conf": int(tweet_cards.get("Low conf", 0)),
            "no_change": int(tweet_cards.get("No change", 0)),
            "skipped": int(tweet_cards.get("Skipped", 0)),
        },
        "features": parser.parse_features(),
    }


# ============================================================
# Bug Autopilot Parser
# ============================================================

def load_bug_investigations():
    """Load and group bug investigations by run date + bug_id."""
    if not BUG_INVESTIGATIONS.exists():
        return []
    with open(BUG_INVESTIGATIONS, encoding="utf-8") as f:
        return json.load(f)


def group_investigations_by_run(investigations, team_filter="Meeting Join"):
    """Group investigations into runs (by date)."""
    runs = {}
    for inv in investigations:
        if team_filter and inv.get("team") != team_filter:
            continue
        ts = inv.get("investigated_at", "")
        if not ts:
            continue
        # Group by date
        date_key = ts[:10]
        if date_key not in runs:
            runs[date_key] = {"date": date_key, "bugs": {}}
        bug_id = str(inv["bug_id"])
        # Keep latest investigation per bug per date
        if bug_id not in runs[date_key]["bugs"] or ts > runs[date_key]["bugs"][bug_id]["investigated_at"]:
            runs[date_key]["bugs"][bug_id] = inv
    return runs


# ============================================================
# Issue Detection
# ============================================================

def detect_ado_issues(reports):
    """Detect TOOL execution problems in ADO autopilot runs (not data issues)."""
    issues = []

    if not reports:
        return issues

    # Use the latest report that actually has features
    latest = None
    for r in reversed(reports):
        if r["features"]:
            latest = r
            break
    if not latest:
        return issues

    # --- Tool Issue: Encoding errors blocking processing (scan ALL reports) ---
    encoding_errors = []
    seen_ids = set()
    for r in reports:
        for feat in r["features"]:
            ev = feat.get("evidence", "")
            if ("charmap" in ev.lower() or "codec" in ev.lower() or "encode" in ev.lower()) and feat["wi_id"] not in seen_ids:
                encoding_errors.append(feat)
                seen_ids.add(feat["wi_id"])

    if encoding_errors:
        affected_ids = [f["wi_id"] for f in encoding_errors]
        issues.append({
            "type": "ado-autopilot",
            "category": "encoding-error",
            "affected_count": len(encoding_errors),
            "affected_ids": affected_ids,
            "sample_error": encoding_errors[0].get("evidence", ""),
        })

    # --- Tool Issue: High skip rate (systemic processing failure) ---
    total = latest["summary"].get("total", 0)
    skipped = latest["summary"].get("skipped", 0)
    if total > 0 and skipped / total > 0.5:
        # Collect skip reasons to diagnose the tool problem
        skip_reasons = set()
        for feat in latest["features"]:
            if feat["status"] == "skipped":
                ev = feat.get("evidence", "").strip()
                if ev:
                    skip_reasons.add(ev[:200])
        issues.append({
            "type": "ado-autopilot",
            "category": "high-skip-rate",
            "total": total,
            "skipped": skipped,
            "rate": f"{skipped/total:.0%}",
            "latest_file": latest["file"],
            "skip_reasons": list(skip_reasons),
        })

    # --- Tool Issue: Declining update rate across runs ---
    if len(reports) >= 3:
        # Check if updated count is trending down
        recent = [r for r in reports if r["features"]][-3:]
        updated_counts = [r["summary"].get("updated", 0) for r in recent]
        if all(c == 0 for c in updated_counts):
            issues.append({
                "type": "ado-autopilot",
                "category": "zero-updates",
                "runs_checked": len(recent),
                "latest_file": latest["file"],
            })

    return issues


def detect_bug_issues(runs):
    """Detect TOOL execution problems in bug autopilot runs (not the bugs themselves)."""
    issues = []
    if not runs:
        return issues

    sorted_dates = sorted(runs.keys())
    latest_date = sorted_dates[-1]
    latest_run = runs[latest_date]

    # --- Tool Issue: Output parse failures (confidence=0 + generic root cause) ---
    parse_failures = []
    for bug_id, inv in latest_run["bugs"].items():
        rc = inv.get("root_cause", "")
        conf = inv.get("confidence", 0)
        if conf == 0 or "did not produce" in rc.lower() or "parsing failed" in inv.get("skip_reason", "").lower():
            parse_failures.append({
                "bug_id": bug_id,
                "bug_title": inv["bug_title"],
                "root_cause": rc,
                "skip_reason": inv.get("skip_reason", ""),
            })

    if parse_failures:
        issues.append({
            "type": "bug-autopilot",
            "category": "parse-failure",
            "affected_count": len(parse_failures),
            "bugs": parse_failures,
        })

    # --- Tool Issue: Repeated investigation with no confidence improvement ---
    stagnant_bugs = []
    for bug_id, inv in latest_run["bugs"].items():
        prev_investigations = []
        for d in sorted_dates[:-1]:
            if bug_id in runs[d]["bugs"]:
                prev_investigations.append(runs[d]["bugs"][bug_id])
        if len(prev_investigations) >= 2:
            prev_conf = prev_investigations[-1].get("confidence", 0)
            curr_conf = inv.get("confidence", 0)
            # Investigated 3+ times with no meaningful improvement
            if curr_conf <= prev_conf and curr_conf < 0.7:
                stagnant_bugs.append({
                    "bug_id": bug_id,
                    "bug_title": inv["bug_title"],
                    "times_investigated": len(prev_investigations) + 1,
                    "confidence": curr_conf,
                })

    if stagnant_bugs:
        issues.append({
            "type": "bug-autopilot",
            "category": "stagnant-investigation",
            "affected_count": len(stagnant_bugs),
            "bugs": stagnant_bugs,
        })

    # --- Tool Issue: All results are needs_human (tool not producing actionable output) ---
    total_bugs = len(latest_run["bugs"])
    needs_human = sum(1 for inv in latest_run["bugs"].values() if inv.get("status") == "needs_human")
    if total_bugs >= 3 and needs_human == total_bugs:
        issues.append({
            "type": "bug-autopilot",
            "category": "all-needs-human",
            "total": total_bugs,
            "run_date": latest_date,
        })

    # --- Tool Issue: Missing telemetry across all bugs (systemic data access problem) ---
    no_telemetry = sum(
        1 for inv in latest_run["bugs"].values()
        if not inv.get("telemetry_findings") or "no telemetry" in inv.get("telemetry_findings", "").lower()
        or "zero" in inv.get("telemetry_findings", "").lower()[:50]
    )
    if total_bugs >= 3 and no_telemetry / total_bugs > 0.7:
        issues.append({
            "type": "bug-autopilot",
            "category": "telemetry-access-failure",
            "total": total_bugs,
            "no_telemetry": no_telemetry,
            "rate": f"{no_telemetry/total_bugs:.0%}",
        })

    return issues


# ============================================================
# GitHub Issue Creation
# ============================================================

def load_issue_state():
    """Load previously created issue tracking state."""
    if STATE_FILE.exists():
        with open(STATE_FILE, encoding="utf-8") as f:
            return json.load(f)
    return {"created_issues": {}}


def save_issue_state(state):
    """Save issue tracking state."""
    SUMMARY_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)
    tmp.replace(STATE_FILE)


def issue_key(issue):
    """Generate a unique key for deduplication."""
    return f"{issue['type']}-{issue['category']}"


def format_bug_issue_title(issue):
    """Format GitHub issue title for a bug autopilot TOOL problem."""
    cat = issue["category"]
    if cat == "parse-failure":
        return f"[Tool Error] Output parse failures in {issue['affected_count']} bug investigations"
    elif cat == "stagnant-investigation":
        return f"[Tool Issue] {issue['affected_count']} bugs re-investigated with no confidence gain"
    elif cat == "all-needs-human":
        return f"[Tool Issue] All {issue['total']} bugs returned needs_human on {issue['run_date']}"
    elif cat == "telemetry-access-failure":
        return f"[Tool Error] Telemetry unavailable for {issue['rate']} of bugs ({issue['no_telemetry']}/{issue['total']})"
    return f"[Tool Issue] {cat}"


def format_bug_issue_body(issue):
    """Format GitHub issue body for a bug autopilot TOOL problem."""
    lines = []
    cat = issue["category"]

    if cat == "parse-failure":
        lines.append("## Output Parse Failures")
        lines.append("")
        lines.append(f"**Affected bugs**: {issue['affected_count']}")
        lines.append("")
        lines.append("The autopilot agent failed to produce structured JSON output for these investigations.")
        lines.append("This means the agent either crashed, timed out, or produced output that couldn't be parsed.")
        lines.append("")
        lines.append("### Affected Investigations")
        lines.append("")
        lines.append("| Bug ID | Title | Error |")
        lines.append("|--------|-------|-------|")
        for b in issue["bugs"]:
            reason = b.get("skip_reason", b.get("root_cause", ""))[:80]
            lines.append(f"| {b['bug_id']} | {b['bug_title'][:60]} | {reason} |")
        lines.append("")
        lines.append("### Suggested Fix")
        lines.append("- Check agent timeout settings (current runs take ~90 min/bug)")
        lines.append("- Review `src/orchestrator.py` output parsing logic")
        lines.append("- Check for prompt length issues causing truncated responses")

    elif cat == "stagnant-investigation":
        lines.append("## Stagnant Investigations (No Confidence Improvement)")
        lines.append("")
        lines.append(f"**Affected bugs**: {issue['affected_count']}")
        lines.append("")
        lines.append("These bugs have been investigated 3+ times with no meaningful confidence improvement.")
        lines.append("Re-running the same investigation is wasting compute without producing new insights.")
        lines.append("")
        lines.append("### Affected Bugs")
        lines.append("")
        lines.append("| Bug ID | Title | Times Run | Confidence |")
        lines.append("|--------|-------|-----------|------------|")
        for b in issue["bugs"]:
            lines.append(f"| {b['bug_id']} | {b['bug_title'][:60]} | {b['times_investigated']} | {b['confidence']:.0%} |")
        lines.append("")
        lines.append("### Suggested Fix")
        lines.append("- Add these bugs to a skip list after N failed attempts")
        lines.append("- Investigate why confidence stays low (missing telemetry? aged-out data?)")
        lines.append("- Consider routing these to human triage directly")

    elif cat == "all-needs-human":
        lines.append("## All Investigations Returned needs_human")
        lines.append("")
        lines.append(f"**Run date**: {issue['run_date']}")
        lines.append(f"**Total bugs**: {issue['total']}")
        lines.append("")
        lines.append("Every bug in this run was classified as `needs_human`, meaning the tool")
        lines.append("produced zero actionable fixes or routing decisions.")
        lines.append("")
        lines.append("### Possible Causes")
        lines.append("- Telemetry data aged out for all bugs (>30 day retention)")
        lines.append("- BRB logs unavailable for all sessions")
        lines.append("- Bug descriptions too vague for automated investigation")
        lines.append("- Confidence threshold (0.7) may be too aggressive for current capabilities")

    elif cat == "telemetry-access-failure":
        lines.append("## Systemic Telemetry Access Failure")
        lines.append("")
        lines.append(f"**Rate**: {issue['rate']} of bugs had no telemetry ({issue['no_telemetry']}/{issue['total']})")
        lines.append("")
        lines.append("The majority of investigations could not find telemetry data.")
        lines.append("This is likely a systemic issue rather than per-bug data gaps.")
        lines.append("")
        lines.append("### Possible Causes")
        lines.append("- Kusto cluster auth failure or connectivity issue")
        lines.append("- Bugs are too old (telemetry past 30-day retention)")
        lines.append("- Wrong cluster/database being queried")
        lines.append("- Query patterns not matching current table schemas")
        lines.append("")
        lines.append("### Suggested Fix")
        lines.append("- Verify Kusto CLI auth: `tools/net472/Kusto.Cli.exe` connection test")
        lines.append("- Filter bug queue to only include bugs from last 14 days")
        lines.append("- Check if table names have changed in the telemetry cluster")

    lines.append("")
    lines.append("---")
    lines.append("*Generated by Virtual Office scrum-master Compare-Runs*")
    return "\n".join(lines)


def format_ado_issue_title(issue):
    """Format GitHub issue title for an ADO autopilot TOOL problem."""
    cat = issue["category"]
    if cat == "encoding-error":
        return f"[Tool Error] charmap encoding error blocks {issue['affected_count']} features"
    elif cat == "high-skip-rate":
        return f"[Tool Issue] {issue['rate']} of features skipped - processing failure"
    elif cat == "zero-updates":
        return f"[Tool Issue] Zero successful updates across last {issue['runs_checked']} runs"
    return f"[Tool Issue] {cat}"


def format_ado_issue_body(issue):
    """Format GitHub issue body for an ADO autopilot TOOL problem."""
    lines = []
    cat = issue["category"]

    if cat == "encoding-error":
        lines.append("## charmap Encoding Error")
        lines.append("")
        lines.append(f"**Affected features**: {issue['affected_count']}")
        lines.append(f"**Feature IDs**: {', '.join(str(i) for i in issue['affected_ids'])}")
        lines.append("")
        lines.append("### Error")
        lines.append(f"```")
        lines.append(issue.get("sample_error", "")[:500])
        lines.append(f"```")
        lines.append("")
        lines.append("### Root Cause")
        lines.append("Windows default codec (`cp1252`) cannot encode Unicode characters (emoji like checkmarks)")
        lines.append("present in existing ADO status tweets. When the tool reads these tweets to compare/update,")
        lines.append("it crashes on the encoding step.")
        lines.append("")
        lines.append("### Fix")
        lines.append("Add `encoding='utf-8'` to all `open()` calls in `src/reporter.py` and `src/main.py`.")
        lines.append("Also set `PYTHONIOENCODING=utf-8` in the runner environment.")

    elif cat == "high-skip-rate":
        lines.append("## High Skip Rate - Systemic Processing Failure")
        lines.append("")
        lines.append(f"**Skip rate**: {issue['rate']} ({issue['skipped']}/{issue['total']} features)")
        lines.append(f"**Report**: `{issue.get('latest_file', '')}`")
        lines.append("")
        lines.append("More than half of tracked features are being skipped, indicating a systemic")
        lines.append("tool problem rather than individual feature issues.")
        lines.append("")
        if issue.get("skip_reasons"):
            lines.append("### Skip Reasons Observed")
            for reason in issue["skip_reasons"]:
                lines.append(f"- {reason}")
            lines.append("")
        lines.append("### Suggested Fix")
        lines.append("- Check if the encoding error is the root cause (fixes one, fixes many)")
        lines.append("- Review WorkIQ/citation pipeline for auth failures")
        lines.append("- Check if ADO API rate limits are being hit")

    elif cat == "zero-updates":
        lines.append("## Zero Successful Updates Across Multiple Runs")
        lines.append("")
        lines.append(f"**Runs checked**: {issue['runs_checked']}")
        lines.append(f"**Report**: `{issue.get('latest_file', '')}`")
        lines.append("")
        lines.append("The tool has not successfully updated any feature status tweets in the")
        lines.append("last several runs. It may be running but producing no useful output.")
        lines.append("")
        lines.append("### Suggested Fix")
        lines.append("- Check if encoding error is blocking all processing")
        lines.append("- Review logs for silent failures in citation gathering")
        lines.append("- Verify WorkIQ MCP server is responding")

    lines.append("")
    lines.append("---")
    lines.append("*Generated by Virtual Office scrum-master Compare-Runs*")
    return "\n".join(lines)


def create_github_issue(repo, title, body, labels=None, dry_run=False):
    """Create a GitHub issue using gh CLI. Returns issue URL or None."""
    if dry_run:
        print(f"  [DRY RUN] Would create issue in {repo}: {title}")
        return None

    cmd = ["gh", "issue", "create", "--repo", repo, "--title", title, "--body", body]
    if labels:
        for label in labels:
            cmd.extend(["--label", label])

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            url = result.stdout.strip()
            print(f"  Created: {url}")
            return url
        else:
            print(f"  ERROR: {result.stderr.strip()}")
            return None
    except Exception as e:
        print(f"  ERROR: {e}")
        return None


# ============================================================
# Summary Generation
# ============================================================

def generate_summary(ado_issues, bug_issues, ado_reports, bug_runs):
    """Generate a markdown summary of the comparison."""
    lines = []
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    lines.append(f"# Scrum-Master Run Comparison Summary")
    lines.append(f"**Generated**: {now}")
    lines.append("")

    # ADO Autopilot section
    lines.append("## ADO Autopilot (Status Tweets)")
    lines.append("")
    if ado_reports:
        lines.append(f"**Reports analyzed**: {len(ado_reports)}")
        # Use latest report with features for summary
        latest = None
        for r in reversed(ado_reports):
            if r["features"]:
                latest = r
                break
        if not latest:
            latest = ado_reports[-1]
        s = latest["summary"]
        lines.append(f"**Latest run**: {latest['file']}")
        lines.append(f"- Total features: {s['total']}")
        lines.append(f"- Updated: {s['updated']}")
        lines.append(f"- Skipped: {s['skipped']}")
        lines.append(f"- No change: {s['no_change']}")
        lines.append(f"- Low confidence: {s['low_conf']}")
        lines.append("")

    if ado_issues:
        lines.append("### Tool Issues Found")
        lines.append("")
        for i, iss in enumerate(ado_issues, 1):
            cat = iss["category"]
            if cat == "encoding-error":
                lines.append(f"{i}. **Encoding Error** - charmap codec blocks {iss['affected_count']} features")
            elif cat == "high-skip-rate":
                lines.append(f"{i}. **High Skip Rate** - {iss['rate']} features skipped ({iss['skipped']}/{iss['total']})")
            elif cat == "zero-updates":
                lines.append(f"{i}. **Zero Updates** - No successful updates in last {iss['runs_checked']} runs")
        lines.append("")
    else:
        lines.append("No tool issues detected.")
        lines.append("")

    # Bug Autopilot section
    lines.append("## Bug Autopilot (Investigations)")
    lines.append("")
    if bug_runs:
        sorted_dates = sorted(bug_runs.keys())
        lines.append(f"**Runs analyzed**: {len(sorted_dates)} ({sorted_dates[0]} to {sorted_dates[-1]})")
        latest_date = sorted_dates[-1]
        latest_run = bug_runs[latest_date]
        lines.append(f"**Latest run date**: {latest_date}")
        lines.append(f"**Bugs investigated**: {len(latest_run['bugs'])}")
        lines.append("")

    if bug_issues:
        lines.append("### Tool Issues Found")
        lines.append("")
        for i, iss in enumerate(bug_issues, 1):
            cat = iss["category"]
            if cat == "parse-failure":
                lines.append(f"{i}. **Parse Failure** - {iss['affected_count']} investigations failed to produce output")
            elif cat == "stagnant-investigation":
                lines.append(f"{i}. **Stagnant** - {iss['affected_count']} bugs re-investigated with no improvement")
            elif cat == "all-needs-human":
                lines.append(f"{i}. **All Needs Human** - {iss['total']} bugs, zero actionable results")
            elif cat == "telemetry-access-failure":
                lines.append(f"{i}. **Telemetry Failure** - {iss['rate']} of bugs had no telemetry data")
        lines.append("")
    else:
        lines.append("No tool issues detected.")
        lines.append("")

    return "\n".join(lines)


# ============================================================
# Main
# ============================================================

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Compare scrum-master runs and create GitHub issues")
    parser.add_argument("--dry-run", action="store_true", help="Don't create GitHub issues")
    parser.add_argument("--since", type=str, help="Only consider runs after this date (YYYY-MM-DD)")
    parser.add_argument("--team", type=str, default="Meeting Join", help="Bug autopilot team filter")
    args = parser.parse_args()

    since = None
    if args.since:
        since = datetime.strptime(args.since, "%Y-%m-%d")

    SUMMARY_DIR.mkdir(parents=True, exist_ok=True)

    print("=" * 60)
    print("Scrum-Master Run Comparison")
    print("=" * 60)

    # --- Parse ADO autopilot reports ---
    print("\n[1/4] Parsing ADO autopilot reports...")
    ado_reports = []

    # Parse from ado-autopilot/reports/ (combined reports)
    if ADO_REPORTS_DIR.exists():
        for html_file in sorted(ADO_REPORTS_DIR.glob("combined-report-*.html")):
            if since:
                ts_match = re.search(r"(\d{8})", html_file.name)
                if ts_match:
                    file_date = datetime.strptime(ts_match.group(1), "%Y%m%d")
                    if file_date < since:
                        continue
            try:
                report = parse_ado_report(html_file)
                ado_reports.append(report)
                print(f"  Parsed: {html_file.name} ({len(report['features'])} features)")
            except Exception as e:
                print(f"  ERROR parsing {html_file.name}: {e}")

    # Also check virtual-office output for -latest files
    for name in ["dry-run-meeting-join-latest.html", "dry-run-meeting-notes-latest.html"]:
        p = OUTPUT_DIR / name
        if p.exists() and not any(r["file"] == name for r in ado_reports):
            try:
                report = parse_ado_report(p)
                # Don't double-count if same timestamp already parsed
                if not any(r.get("timestamp") == report.get("timestamp") for r in ado_reports if report.get("timestamp")):
                    ado_reports.append(report)
                    print(f"  Parsed: {name} ({len(report['features'])} features)")
            except Exception as e:
                print(f"  ERROR parsing {name}: {e}")

    print(f"  Total ADO reports: {len(ado_reports)}")

    # --- Parse bug autopilot investigations ---
    print("\n[2/4] Parsing bug autopilot investigations...")
    investigations = load_bug_investigations()
    bug_runs = group_investigations_by_run(investigations, team_filter=args.team)

    if since:
        bug_runs = {d: r for d, r in bug_runs.items() if d >= args.since}

    for date, run in sorted(bug_runs.items()):
        print(f"  Run {date}: {len(run['bugs'])} bugs investigated")

    # --- Detect issues ---
    print("\n[3/4] Detecting issues...")
    ado_issues = detect_ado_issues(ado_reports)
    bug_issues = detect_bug_issues(bug_runs)
    print(f"  ADO issues: {len(ado_issues)}")
    print(f"  Bug issues: {len(bug_issues)}")

    # --- Generate summary ---
    summary = generate_summary(ado_issues, bug_issues, ado_reports, bug_runs)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    summary_file = SUMMARY_DIR / f"comparison-{ts}.md"
    with open(summary_file, "w", encoding="utf-8") as f:
        f.write(summary)
    print(f"\n  Summary saved: {summary_file}")

    # Also update latest
    latest_file = SUMMARY_DIR / "comparison-latest.md"
    with open(latest_file, "w", encoding="utf-8") as f:
        f.write(summary)

    # --- Create GitHub issues ---
    print("\n[4/4] Creating GitHub issues...")
    state = load_issue_state()

    created_count = 0
    skipped_count = 0

    # ADO issues
    for iss in ado_issues:
        key = issue_key(iss)
        if key in state["created_issues"]:
            skipped_count += 1
            continue
        title = format_ado_issue_title(iss)
        body = format_ado_issue_body(iss)
        url = create_github_issue(ADO_REPO, title, body, dry_run=args.dry_run)
        if url or args.dry_run:
            state["created_issues"][key] = {
                "url": url,
                "created_at": datetime.now().isoformat(),
                "title": title,
            }
            created_count += 1

    # Bug issues
    for iss in bug_issues:
        key = issue_key(iss)
        if key in state["created_issues"]:
            skipped_count += 1
            continue
        title = format_bug_issue_title(iss)
        body = format_bug_issue_body(iss)
        url = create_github_issue(BUG_REPO, title, body, dry_run=args.dry_run)
        if url or args.dry_run:
            state["created_issues"][key] = {
                "url": url,
                "created_at": datetime.now().isoformat(),
                "title": title,
            }
            created_count += 1

    save_issue_state(state)

    print(f"\n{'='*60}")
    print(f"Done! Created: {created_count} | Skipped (already exists): {skipped_count}")
    print(f"Summary: {summary_file}")
    print(f"{'='*60}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
