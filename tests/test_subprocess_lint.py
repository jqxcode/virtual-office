"""AST lint: forbid literal command-name strings in subprocess calls.

Motivation
----------
The 2026-05-28 hygiene-runner crash was caused by
``subprocess.check_output(["az", ...])``. On Windows, ``az`` is a CMD
shim (``az.cmd``) and Python's subprocess does NOT consult ``PATHEXT``
when ``shell=False``. The crash surfaced only at scheduled run time --
unit tests passed. Fix in commit fbeeb42 introduced a module-level
``AZ_CMD = shutil.which("az") or ("az.cmd" if os.name == "nt" else "az")``
constant.

This lint catches that whole class of bug at test time: for every
``subprocess.{run,call,check_output,check_call,Popen}`` call under
``runner/`` and ``scripts/`` whose first positional argument is a
list literal, the first element of that list MUST be a ``Name``
(variable reference) -- NOT an ``ast.Constant`` string equal to a
known disallowed command. Allowed commands: see
``DISALLOWED_LITERALS``.

If the test fails it points at file and line so the fix is obvious:
move the literal to a module-level ``AZ_CMD`` / ``GIT_CMD`` / etc.
constant resolved via ``shutil.which``.
"""
from __future__ import annotations

import ast
import os
import unittest
from typing import List, Tuple

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNNER_DIR = os.path.join(REPO_ROOT, "runner")
SCRIPTS_DIR = os.path.join(REPO_ROOT, "scripts")

# Commands whose Windows resolution is fragile (CMD shims, .cmd / .ps1
# extensions, multiple Node installs, etc.). For each, the first arg of
# the subprocess args list must be a Name (variable) holding a resolved
# absolute path, not a bare string literal.
DISALLOWED_LITERALS = {"az", "git", "pwsh", "powershell", "node"}

SUBPROCESS_FUNCS = {"run", "call", "check_output", "check_call", "Popen"}

# Exclude vendored / virtualenv dirs and __pycache__ from the scan.
EXCLUDED_DIR_NAMES = {".venv", ".venv-wechat", "venv", "env",
                      "__pycache__", "node_modules", "site-packages",
                      ".git", "templates"}

# Known pre-existing violations grandfathered in. Add an entry with a
# JIRA / GitHub issue ref when grandfathering; DO NOT add new entries
# without a tracked cleanup ticket. Path is repo-relative with forward
# slashes; line is the 1-based line number of the offending call.
KNOWN_VIOLATIONS = {
    # (removed: wechat_pywin_collect.py was deleted)
    # post-hygiene-to-teams.py wraps `az` inside a `powershell -Command`
    # invocation rather than calling subprocess directly. The wrapper
    # works because powershell.exe is on PATH; the inner `az` runs under
    # cmd's PATHEXT resolution. Pre-existing pattern -- track separately.
    ("scripts/post-hygiene-to-teams.py", 23),
}


def _iter_python_files(root):
    # type: (str) -> List[str]
    out = []  # type: List[str]
    if not os.path.isdir(root):
        return out
    for dirpath, dirnames, filenames in os.walk(root):
        # prune excluded dirs in-place
        dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIR_NAMES]
        for fn in filenames:
            if fn.endswith(".py"):
                out.append(os.path.join(dirpath, fn))
    return out


def _is_subprocess_call(node):
    # type: (ast.AST) -> bool
    """Detect `subprocess.<func>(...)` and `from subprocess import <func>`
    bare-name calls."""
    if not isinstance(node, ast.Call):
        return False
    func = node.func
    if isinstance(func, ast.Attribute):
        if func.attr not in SUBPROCESS_FUNCS:
            return False
        return isinstance(func.value, ast.Name) and func.value.id == "subprocess"
    if isinstance(func, ast.Name):
        return func.id in SUBPROCESS_FUNCS
    return False


def _violation_for_call(node):
    # type: (ast.Call) -> str
    """Return the offending literal command name if this call uses one,
    else empty string."""
    if not node.args:
        return ""
    first = node.args[0]
    if not isinstance(first, ast.List) or not first.elts:
        return ""
    head = first.elts[0]
    if isinstance(head, ast.Constant) and isinstance(head.value, str):
        cmd = head.value
        # Only flag the leading component (basename without extension).
        base = os.path.basename(cmd).lower()
        if base.endswith(".exe") or base.endswith(".cmd") or base.endswith(".ps1"):
            base = base.rsplit(".", 1)[0]
        if base in DISALLOWED_LITERALS:
            return cmd
    return ""


def _scan_file(path):
    # type: (str) -> List[Tuple[int, str]]
    """Return list of (line, literal) violations in this file."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            src = f.read()
    except (OSError, UnicodeDecodeError):
        return []
    try:
        tree = ast.parse(src, filename=path)
    except SyntaxError:
        return []
    out = []  # type: List[Tuple[int, str]]
    for node in ast.walk(tree):
        if not _is_subprocess_call(node):
            continue
        literal = _violation_for_call(node)
        if literal:
            out.append((node.lineno, literal))
    return out


def _rel(path):
    # type: (str) -> str
    return os.path.relpath(path, REPO_ROOT).replace(os.sep, "/")


class TestSubprocessLiteralLint(unittest.TestCase):
    """Enforce: subprocess first-arg list[0] must reference a Name
    (variable) not a Constant string for disallowed commands."""

    def test_no_literal_disallowed_commands_in_subprocess_calls(self):
        scanned = 0
        new_violations = []  # type: List[str]
        seen_known = set()  # type: set
        for root in (RUNNER_DIR, SCRIPTS_DIR):
            for path in _iter_python_files(root):
                scanned += 1
                for line, literal in _scan_file(path):
                    rel = _rel(path)
                    if (rel, line) in KNOWN_VIOLATIONS:
                        seen_known.add((rel, line))
                        continue
                    new_violations.append(
                        "{0}:{1} uses literal {2!r} in subprocess -- must use "
                        "AZ_CMD/GIT_CMD/etc. resolved via shutil.which".format(
                            rel, line, literal,
                        )
                    )

        self.assertGreater(scanned, 0, "lint scanned 0 files; check paths")

        # Fail loudly with a diff-like list if new violations exist.
        self.assertEqual(
            new_violations, [],
            "Forbidden literal commands in subprocess calls:\n  - {0}\n\n"
            "Fix by introducing a module-level constant resolved via "
            "shutil.which(), e.g.:\n"
            "    AZ_CMD = shutil.which(\"az\") or "
            "(\"az.cmd\" if os.name == \"nt\" else \"az\")\n"
            "    subprocess.check_output([AZ_CMD, ...])".format(
                "\n  - ".join(new_violations),
            ),
        )

        # If a grandfathered entry is no longer present, surface that so
        # the allowlist can be trimmed.
        stale = KNOWN_VIOLATIONS - seen_known
        if stale:
            self.fail(
                "KNOWN_VIOLATIONS entries no longer detected -- remove from "
                "the allowlist:\n  - {0}".format(
                    "\n  - ".join("{0}:{1}".format(p, l) for p, l in sorted(stale)),
                )
            )

    def test_hygiene_runner_has_no_literal_az(self):
        """Targeted regression for the 2026-05-28 [WinError 2] crash."""
        path = os.path.join(RUNNER_DIR, "shiproom_hygiene_check.py")
        self.assertTrue(os.path.exists(path), "hygiene runner not found")
        violations = _scan_file(path)
        self.assertEqual(
            violations, [],
            "shiproom_hygiene_check.py must not use literal command names "
            "in subprocess calls; found: {0}".format(violations),
        )


if __name__ == "__main__":
    unittest.main()
