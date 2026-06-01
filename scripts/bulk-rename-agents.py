"""
Bulk rename VO agents with category prefixes.

Renames across all layers:
- config/agents.json
- config/jobs/*.json (file renames + content updates)
- config/schedules.json
- ui/app.js (color map + legacy names)
- runner/Get-JobDurations.py (color map)
- templates/ (file renames + content)
- README.md, DESIGN.md, docs/*
- tests/*.ps1
- .copilot/agents/ (file renames)
- config/jobs/pHangScout.json perAgent references
"""
import json
import os
import re
import shutil
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent
COPILOT_AGENTS = Path.home() / ".copilot" / "agents"

# Rename map: old_name -> new_name
RENAMES = {
    "mScrumMaster": "mScrumMaster",
    "pBugKiller": "pBugKiller",
    "mScrumReporter": "mScrumReporter",
    "pHarnessMonitor": "pHarnessMonitor",
    "mPoster": "mPoster",
    "pHangScout": "pHangScout",
    "pDreamer": "pDreamer",
    "pResearcher": "pResearcher",
    "mApprover": "mApprover",
    "pConnector": "pConnector",
    "mAuditor": "mAuditor",
}

# Display names for agents.json
DISPLAY_NAMES = {
    "mScrumMaster": "mScrumMaster",
    "pBugKiller": "pBugKiller",
    "mScrumReporter": "mScrumReporter",
    "pHarnessMonitor": "pHarnessMonitor",
    "mPoster": "mPoster",
    "pHangScout": "pHangScout",
    "pDreamer": "pDreamer",
    "pResearcher": "pResearcher",
    "mApprover": "mApprover",
    "pConnector": "pConnector",
    "mAuditor": "mAuditor",
}

# Group assignments
GROUPS = {
    "mScrumMaster": "Work Agents",
    "pBugKiller": "Personal Agents",
    "mScrumReporter": "Work Agents",
    "pHarnessMonitor": "Personal Agents",
    "mPoster": "Work Agents",
    "pHangScout": "Personal Agents",
    "pDreamer": "Personal Agents",
    "pResearcher": "Personal Agents",
    "mApprover": "Work Agents",
    "pConnector": "Personal Agents",
    "mAuditor": "Work Agents",
}


def rename_agents_json():
    """Rename keys in config/agents.json."""
    path = PROJECT_ROOT / "config" / "agents.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    agents = data["agents"]
    new_agents = {}
    for key, val in agents.items():
        if key in RENAMES:
            new_key = RENAMES[key]
            val["displayName"] = DISPLAY_NAMES[new_key]
            val["agentFile"] = f"~/.claude/agents/{new_key}.md"
            if new_key in GROUPS:
                val["group"] = GROUPS[new_key]
            new_agents[new_key] = val
        else:
            new_agents[key] = val
    data["agents"] = new_agents
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"  ✓ config/agents.json - renamed {len(RENAMES)} agents")


def rename_job_files():
    """Rename config/jobs/<old>.json -> <new>.json and update content."""
    jobs_dir = PROJECT_ROOT / "config" / "jobs"
    for old_name, new_name in RENAMES.items():
        old_file = jobs_dir / f"{old_name}.json"
        new_file = jobs_dir / f"{new_name}.json"
        if old_file.exists():
            content = old_file.read_text(encoding="utf-8")
            # Replace references to old name in content
            content = content.replace(f'"{old_name}"', f'"{new_name}"')
            content = content.replace(f"/{old_name}", f"/{new_name}")
            content = content.replace(f"{old_name}-", f"{new_name}-")
            new_file.write_text(content, encoding="utf-8")
            old_file.unlink()
            print(f"  ✓ config/jobs/{old_name}.json -> {new_name}.json")
        else:
            print(f"  - config/jobs/{old_name}.json not found (skip)")

    # Update perAgent references in all job files
    for job_file in jobs_dir.glob("*.json"):
        content = job_file.read_text(encoding="utf-8")
        changed = False
        for old_name, new_name in RENAMES.items():
            if old_name in content:
                content = content.replace(old_name, new_name)
                changed = True
        if changed:
            job_file.write_text(content, encoding="utf-8")
            print(f"  ✓ Updated references in config/jobs/{job_file.name}")


def rename_schedules():
    """Update agent references in config/schedules.json."""
    path = PROJECT_ROOT / "config" / "schedules.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    for entry in data["schedules"]:
        if entry["agent"] in RENAMES:
            old = entry["agent"]
            entry["agent"] = RENAMES[old]
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"  ✓ config/schedules.json - updated agent references")


def rename_ui_app_js():
    """Update color map and legacy names in ui/app.js."""
    path = PROJECT_ROOT / "ui" / "app.js"
    content = path.read_text(encoding="utf-8")

    # Update AGENT_COLORS keys
    for old_name, new_name in RENAMES.items():
        content = content.replace(f'"{old_name}"', f'"{new_name}"')

    # Add new legacy mappings (old -> new) to LEGACY_AGENT_NAMES
    # Find the LEGACY_AGENT_NAMES block and add entries
    legacy_additions = ",\n".join(
        f'  "{old}": "{new}"' for old, new in RENAMES.items()
    )
    # Replace the closing brace of LEGACY_AGENT_NAMES with additions
    content = re.sub(
        r'(var LEGACY_AGENT_NAMES = \{[^}]*)',
        lambda m: m.group(1) + ",\n" + legacy_additions,
        content,
        count=1
    )

    path.write_text(content, encoding="utf-8")
    print(f"  ✓ ui/app.js - updated color map + legacy names")


def rename_get_job_durations():
    """Update color map in runner/Get-JobDurations.py."""
    path = PROJECT_ROOT / "runner" / "Get-JobDurations.py"
    content = path.read_text(encoding="utf-8")
    for old_name, new_name in RENAMES.items():
        content = content.replace(f'"{old_name}"', f'"{new_name}"')
    path.write_text(content, encoding="utf-8")
    print(f"  ✓ runner/Get-JobDurations.py - updated color map")


def rename_templates():
    """Rename template files and update content."""
    tmpl_dir = PROJECT_ROOT / "templates"
    if not tmpl_dir.exists():
        print("  - templates/ dir not found")
        return

    for old_name, new_name in RENAMES.items():
        # Find templates starting with old name
        for f in list(tmpl_dir.glob(f"{old_name}*")):
            new_fname = f.name.replace(old_name, new_name)
            new_path = tmpl_dir / new_fname
            content = f.read_text(encoding="utf-8")
            for o, n in RENAMES.items():
                content = content.replace(o, n)
            new_path.write_text(content, encoding="utf-8")
            f.unlink()
            print(f"  ✓ templates/{f.name} -> {new_fname}")

    # Also update content in remaining templates (partials, etc.)
    for f in tmpl_dir.rglob("*.html"):
        content = f.read_text(encoding="utf-8")
        changed = False
        for old_name, new_name in RENAMES.items():
            if old_name in content:
                content = content.replace(old_name, new_name)
                changed = True
        if changed:
            f.write_text(content, encoding="utf-8")
            print(f"  ✓ Updated references in templates/{f.relative_to(tmpl_dir)}")


def rename_docs():
    """Update references in README.md, DESIGN.md, docs/*."""
    doc_files = [
        PROJECT_ROOT / "README.md",
        PROJECT_ROOT / "DESIGN.md",
    ]
    docs_dir = PROJECT_ROOT / "docs"
    if docs_dir.exists():
        doc_files.extend(docs_dir.glob("*.md"))

    for path in doc_files:
        if not path.exists():
            continue
        content = path.read_text(encoding="utf-8")
        changed = False
        for old_name, new_name in RENAMES.items():
            if old_name in content:
                content = content.replace(old_name, new_name)
                changed = True
        if changed:
            path.write_text(content, encoding="utf-8")
            print(f"  ✓ {path.relative_to(PROJECT_ROOT)} - updated references")


def rename_tests():
    """Update references in test files."""
    tests_dir = PROJECT_ROOT / "tests"
    if not tests_dir.exists():
        return
    for f in tests_dir.rglob("*"):
        if f.is_file() and f.suffix in (".ps1", ".py", ".json"):
            content = f.read_text(encoding="utf-8")
            changed = False
            for old_name, new_name in RENAMES.items():
                if old_name in content:
                    content = content.replace(old_name, new_name)
                    changed = True
            if changed:
                f.write_text(content, encoding="utf-8")
                print(f"  ✓ tests/{f.name} - updated references")


def rename_copilot_agents():
    """Rename .copilot/agents/ files and update internal name field."""
    if not COPILOT_AGENTS.exists():
        print(f"  - {COPILOT_AGENTS} not found")
        return

    for old_name, new_name in RENAMES.items():
        old_file = COPILOT_AGENTS / f"{old_name}.agent.md"
        new_file = COPILOT_AGENTS / f"{new_name.lower()}.agent.md"

        if old_file.exists():
            content = old_file.read_text(encoding="utf-8")
            # Update name field in frontmatter
            content = re.sub(
                r'^(name:\s*).*$',
                f'\\1{new_name}',
                content,
                count=1,
                flags=re.MULTILINE
            )
            new_file.write_text(content, encoding="utf-8")
            old_file.unlink()
            print(f"  ✓ .copilot/agents/{old_file.name} -> {new_file.name}")
        else:
            # Check if lowercase version exists
            alt_file = COPILOT_AGENTS / f"{old_name.lower()}.agent.md"
            if alt_file.exists() and alt_file != new_file:
                content = alt_file.read_text(encoding="utf-8")
                content = re.sub(
                    r'^(name:\s*).*$',
                    f'\\1{new_name}',
                    content,
                    count=1,
                    flags=re.MULTILINE
                )
                new_file.write_text(content, encoding="utf-8")
                alt_file.unlink()
                print(f"  ✓ .copilot/agents/{alt_file.name} -> {new_file.name}")
            else:
                print(f"  - .copilot/agents/{old_name}.agent.md not found (skip)")


def rename_scripts():
    """Update references in scripts/."""
    scripts_dir = PROJECT_ROOT / "scripts"
    if not scripts_dir.exists():
        return
    for f in scripts_dir.rglob("*"):
        if f.is_file() and f.suffix in (".py", ".ps1", ".sh"):
            content = f.read_text(encoding="utf-8")
            changed = False
            for old_name, new_name in RENAMES.items():
                if old_name in content:
                    content = content.replace(old_name, new_name)
                    changed = True
            if changed:
                f.write_text(content, encoding="utf-8")
                print(f"  ✓ scripts/{f.name} - updated references")


def rename_runner_scripts():
    """Update references in runner/ PS1 scripts."""
    runner_dir = PROJECT_ROOT / "runner"
    if not runner_dir.exists():
        return
    for f in runner_dir.rglob("*"):
        if f.is_file() and f.suffix in (".ps1", ".py"):
            content = f.read_text(encoding="utf-8")
            changed = False
            for old_name, new_name in RENAMES.items():
                if old_name in content:
                    content = content.replace(old_name, new_name)
                    changed = True
            if changed:
                f.write_text(content, encoding="utf-8")
                print(f"  ✓ runner/{f.name} - updated references")


if __name__ == "__main__":
    print("=== Virtual Office Bulk Agent Rename ===\n")

    print("[1/10] config/agents.json")
    rename_agents_json()

    print("\n[2/10] config/jobs/ (file renames + content)")
    rename_job_files()

    print("\n[3/10] config/schedules.json")
    rename_schedules()

    print("\n[4/10] ui/app.js")
    rename_ui_app_js()

    print("\n[5/10] runner/Get-JobDurations.py")
    rename_get_job_durations()

    print("\n[6/10] templates/")
    rename_templates()

    print("\n[7/10] README.md, DESIGN.md, docs/")
    rename_docs()

    print("\n[8/10] tests/")
    rename_tests()

    print("\n[9/10] scripts/")
    rename_scripts()
    rename_runner_scripts()

    print("\n[10/10] .copilot/agents/")
    rename_copilot_agents()

    print("\n=== Done! Run tests and review changes. ===")
