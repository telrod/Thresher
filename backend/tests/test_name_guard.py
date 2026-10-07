"""
No maintainer or employer name in any tracked file, except where allowlisted.

WHY THIS EXISTS
---------------
The release check that cleared this repository was a one-off search, not a
test, and its term list omitted the first name — so a name shipped in
DECISIONS.md and stayed there until someone read it. This scans EVERY tracked
file (text, and binary decoded byte-for-byte) on every run.

THE ALLOWLIST
-------------
Each entry is a file, the exact text that may contain a name there, and how
many times that text occurs. Longer entries are removed first, so an identifier
and its prefix can both be listed. The test fails on:

  - any hit left after the allowlist is applied (a new file, a new token, or
    one more occurrence of an allowed token), and
  - any allowlist entry whose count no longer matches, so stale entries cannot
    accumulate into blanket permissions.

Entries are ROT13-encoded for the reason given in `name_terms.py`.

THE SELF-TEST
-------------
`test_guard_detects_a_name_in_a_new_tracked_file` runs the scan against a
throwaway repository with a tracked file containing a listed name and asserts
it is reported. `test_guard_detects_a_stale_allowlist_entry` asserts a count
mismatch is reported.
"""

import subprocess
from pathlib import Path

import pytest

from name_terms import NAME_RE, decode

_REPO = Path(__file__).resolve().parents[2]

# file → {encoded exact text: occurrences}
_ALLOWLIST = {
    # The copyright line.
    "LICENSE": {"Gbz Ryebq": 1},
    # The bundle identifier and the launchd labels derived from it. Changing
    # them moves Keychain items, UserDefaults and launchd jobs, so they stay.
    "frontend/Thresher.xcodeproj/project.pbxproj": {
        "pbz.gbzryebq.Guerfure.qroht": 1, "pbz.gbzryebq.GuerfureHVGrfgf": 2,
        "pbz.gbzryebq.GuerfureGrfgf": 2, "pbz.gbzryebq.Guerfure": 1},
    "frontend/Thresher/Models/BackgroundPolling.swift": {
        "pbz.gbzryebq.guerfure.cvcryvar": 1, "pbz.gbzryebq.guerfure.ncv": 1},
    "frontend/ThresherTests/BackgroundPollingTests.swift": {
        "pbz.gbzryebq.guerfure.cvcryvar": 1, "pbz.gbzryebq.guerfure.ncv": 1},
    "scripts/backend.sh": {
        "pbz.gbzryebq.guerfure.cvcryvar": 1, "pbz.gbzryebq.guerfure.ncv": 1},
    "scripts/dev-run.sh": {
        "pbz.gbzryebq.guerfure.cvcryvar": 1, "pbz.gbzryebq.guerfure.ncv": 1,
        "pbz.gbzryebq.guerfure.": 1, "pbz.gbzryebq.Guerfure": 4},
    "scripts/launchagent.sh": {"pbz.gbzryebq.guerfure": 1},
    "scripts/phase3-reset-test-user.sh": {"pbz.gbzryebq.Guerfure": 1},
    "docs/workorders/migration-prep-batch-3-workorder.md": {
        "pbz.gbzryebq.Guerfure": 1, "pbz.gbzryebq": 1},
}


def _tracked(repo: Path) -> "list[str]":
    out = subprocess.run(["git", "ls-files", "-z"], cwd=repo, check=True,
                         capture_output=True).stdout.decode()
    return [p for p in out.split("\0") if p]


def _text(path: Path) -> str:
    data = path.read_bytes()
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("latin-1")     # binary: every byte maps to one char


def scan(repo: Path, allowlist: dict) -> "list[str]":
    """Every problem found: unallowed hits and allowlist count mismatches."""
    problems = []
    for rel in _tracked(repo):
        path = repo / rel
        if not path.is_file():
            continue                      # e.g. a gitlink
        text = _text(path)
        entries = {decode(k): n for k, n in allowlist.get(rel, {}).items()}
        for token in sorted(entries, key=len, reverse=True):
            found = text.count(token)
            if found != entries[token]:
                problems.append(f"{rel}: allowlisted {token!r} expected "
                                f"{entries[token]}, found {found}")
            text = text.replace(token, "\0")
        for n, line in enumerate(text.splitlines(), 1):
            for m in NAME_RE.finditer(line):
                problems.append(f"{rel}:{n}: {m.group(0)!r}")
    for rel in allowlist:
        if not (repo / rel).is_file():
            problems.append(f"{rel}: allowlisted file is not tracked")
    return problems


def _git(repo: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)


def test_no_unallowed_names_in_tracked_files():
    root = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=_REPO,
                          capture_output=True, text=True)
    if root.returncode != 0 or Path(root.stdout.strip()).resolve() != _REPO.resolve():
        pytest.skip(f"{_REPO} is not a git repository root, so there is no file list")
    problems = scan(_REPO, _ALLOWLIST)
    assert problems == [], "names found in tracked files:\n  " + "\n  ".join(problems)


def test_guard_detects_a_name_in_a_new_tracked_file(tmp_path):
    _git(tmp_path, "init", "-q")
    (tmp_path / "notes.md").write_text(f"Thanks, {decode('Gbz')}.\n")
    (tmp_path / "clean.md").write_text("tomorrow, atom, Tomcat\n")   # not whole-word
    _git(tmp_path, "add", "notes.md", "clean.md")
    assert scan(tmp_path, {}) == [f"notes.md:1: {decode('Gbz')!r}"]


def test_guard_detects_a_stale_allowlist_entry(tmp_path):
    _git(tmp_path, "init", "-q")
    (tmp_path / "LICENSE").write_text("no name here\n")
    _git(tmp_path, "add", "LICENSE")
    assert scan(tmp_path, {"LICENSE": {"Gbz Ryebq": 1}}) == [
        f"LICENSE: allowlisted {decode('Gbz Ryebq')!r} expected 1, found 0"]
