"""
Nothing under `local/` is ever tracked.

WHY THIS EXISTS
---------------
`local/` at the repo root holds material that never ships: its own nested
repository of working notes. `.gitignore` excludes it (`/local/`), but an
ignore rule only stops `git add .`. It does not stop `git add -f`, and it does
not remove a file that was tracked before the rule was written. This guard
checks the index itself: `git ls-files local` must be empty.

It reads the index, not HEAD, so a file that is *staged* under `local/` already
fails, before it is committed.

THE SELF-TEST
-------------
A guard that cannot fail tells you nothing (see CLAUDE.md, "Writing a check that
can actually fail"). `test_guard_detects_a_tracked_local_file` runs the same
check against a throwaway repository with a file force-added under `local/` and
asserts that it is reported. It also checks that a lookalike path (`localx/`) is
NOT reported, so the guard cannot pass just because it flags everything or
flags nothing. `test_guard_detects_local_as_a_gitlink` covers the other way in:
`local/` is a nested repository, so `git add local` stages one submodule entry
named `local`, not the files inside it.

OUTSIDE A WORK TREE
-------------------
A source ZIP has no `.git`, and there is no index to check, so the guard skips
there rather than failing. It also skips if the nearest repository is some
*enclosing* one rather than this repo's own root, because that repository's
index says nothing about this tree.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

_REPO = Path(__file__).resolve().parents[2]


def _tracked_under_local(repo: Path) -> "list[str]":
    """Index entries at or under `local/` in `repo`.

    Also reports a gitlink at `local` itself: `local/` is a nested repository,
    and `git add local` stages it as a submodule entry rather than its files.
    """
    out = subprocess.run(
        ["git", "ls-files", "-z", "--", "local"],
        cwd=repo, check=True, capture_output=True,
    ).stdout.decode()
    return [p for p in out.split("\0") if p]


def _git(repo: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)


def _require_git():
    if shutil.which("git") is None:
        pytest.skip("git is not installed")


def _work_tree_root(path: Path) -> "Path | None":
    """The root of the git work tree containing `path`, or None if there is none."""
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=path, capture_output=True, text=True,
    )
    if result.returncode != 0:
        return None
    return Path(result.stdout.strip()).resolve()


def test_nothing_under_local_is_tracked():
    _require_git()
    root = _work_tree_root(_REPO)
    if root is None:
        pytest.skip(f"{_REPO} is not inside a git work tree, so there is no index to check")
    if root != _REPO.resolve():
        pytest.skip(f"{_REPO} is not a repository root (the enclosing work tree is {root})")
    tracked = _tracked_under_local(_REPO)
    assert tracked == [], (
        "local/ must never be tracked, but the index contains:\n  "
        + "\n  ".join(tracked)
        + "\nUnstage with: git rm -r --cached local")


def test_guard_detects_a_tracked_local_file(tmp_path):
    _require_git()
    _git(tmp_path, "init", "-q")
    (tmp_path / ".gitignore").write_text("/local/\n")
    (tmp_path / "local").mkdir()
    (tmp_path / "local" / "notes.md").write_text("private\n")
    (tmp_path / "localx").mkdir()
    (tmp_path / "localx" / "keep.md").write_text("public\n")
    _git(tmp_path, "add", ".gitignore", "localx/keep.md")

    # Ignored and not forced: the guard must stay quiet.
    assert _tracked_under_local(tmp_path) == []

    # Forced past the ignore rule: the guard must report exactly that file.
    _git(tmp_path, "add", "-f", "local/notes.md")
    assert _tracked_under_local(tmp_path) == ["local/notes.md"]


def test_guard_detects_local_as_a_gitlink(tmp_path):
    _require_git()
    _git(tmp_path, "init", "-q")
    (tmp_path / "local").mkdir()
    _git(tmp_path / "local", "init", "-q")
    (tmp_path / "local" / "notes.md").write_text("private\n")
    _git(tmp_path / "local", "add", "notes.md")
    _git(tmp_path / "local", "-c", "user.name=t", "-c", "user.email=t@example.com",
         "commit", "-q", "-m", "notes")

    assert _tracked_under_local(tmp_path) == []

    # A nested repository is staged as one gitlink entry, not as its files.
    _git(tmp_path, "add", "local")
    staged = subprocess.run(
        ["git", "ls-files", "-s", "--", "local"],
        cwd=tmp_path, check=True, capture_output=True, text=True,
    ).stdout
    assert staged.startswith("160000 "), f"expected a gitlink, got: {staged!r}"
    assert _tracked_under_local(tmp_path) == ["local"]
