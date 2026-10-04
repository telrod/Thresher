"""
Build provenance — "which code am I actually running?" as a displayed fact.

Session 27 opened with BOTH runtime artifacts stale: the running backend process and
the installed /Applications binary each predated the D50+D51 batch, and the only tell
was inference ("do I see chips?"). A gate pass against the wrong binary is a false
PASS recorded with full confidence — the OI14 occlusion arc already showed
wrong-artifact verification re-closing a real bug. So provenance stops being something
you infer.

Design constraints (from the workorder, and each one is load-bearing):

- **No manual bumping.** Anything a human must remember to update will drift
  (the Session 16 lesson: durability claimed by convention isn't enforced durability).
  The stamp comes from git + the clock, needing zero discipline.
- **Dirty-tree honesty.** A build from an uncommitted tree says `-dirty`. A stamp
  claiming a clean SHA for a dirty build is worse than no stamp — it is the
  artifacts-mislead pattern, at build time.
- **Graceful degradation.** No git (an exported tree, say) reads `unknown`. Never
  crash, never block startup, never fabricate a SHA.
"""

from __future__ import annotations

import logging
import subprocess
from datetime import datetime, timezone
from pathlib import Path

log = logging.getLogger("thresher.provenance")

_REPO_ROOT = Path(__file__).resolve().parent.parent

# Resolved once per process: the SHA cannot change under a running process, and the
# start time is by definition fixed. Also keeps `/version` free of subprocess cost.
_STARTED_AT = datetime.now(timezone.utc).isoformat()
_GIT_SHA: str | None = None


def _run_git(*args: str) -> str | None:
    """Run a git command in the repo, or return None on any failure.

    Deliberately broad: a missing binary, a non-repo directory, and a timeout are all
    the same answer to the caller — "git can't tell us", which becomes "unknown".
    """
    try:
        out = subprocess.run(("git", *args), cwd=_REPO_ROOT, capture_output=True,
                             text=True, timeout=5, check=True)
        return out.stdout.strip()
    except Exception:                       # noqa: BLE001 — degradation, not failure
        return None


# Written by scripts/bundle-backend.sh into the bundled copy. Absent in a
# checkout, where git itself is the better answer.
_BUILD_STAMP_PATH = Path(__file__).parent / "BUILD_SHA"


def git_sha() -> str:
    """`<short-sha>` , `<short-sha>-dirty`, or `unknown`. Computed once per process."""
    global _GIT_SHA
    if _GIT_SHA is not None:
        return _GIT_SHA

    # D68: a BUNDLED backend has no git repository to ask, so it reports the SHA
    # stamped beside it at bundle time. Checked FIRST because in a bundle the git
    # call is not merely unavailable — it could succeed against whatever
    # repository the process happens to be launched from, and report a SHA that
    # has nothing to do with the code actually running. A stamp that exists is
    # always more trustworthy than a git call from an unknown working directory.
    stamp = _BUILD_STAMP_PATH
    if stamp.exists():
        try:
            recorded = stamp.read_text().strip()
            if recorded:
                _GIT_SHA = recorded
                return _GIT_SHA
        except OSError:
            pass                            # fall through to git

    sha = _run_git("rev-parse", "--short", "HEAD")
    if not sha:
        _GIT_SHA = "unknown"
        return _GIT_SHA

    # `git status --porcelain` is empty exactly when the tree is clean. If the status
    # call itself fails we do NOT claim clean — an unverifiable tree is reported dirty,
    # because the failure mode of over-claiming cleanliness is the one that misleads.
    porcelain = _run_git("status", "--porcelain")
    if porcelain is None or porcelain:
        sha = f"{sha}-dirty"

    _GIT_SHA = sha
    return _GIT_SHA


def started_at() -> str:
    """ISO-8601 UTC process start time."""
    return _STARTED_AT


def payload() -> dict:
    """The `GET /version` body."""
    return {"git_sha": git_sha(), "started_at": started_at()}


def log_startup_line(component: str = "backend") -> None:
    """One line at startup, so a stale process is visible in the log too — not only
    by asking the endpoint (which requires already suspecting something)."""
    log.info("thresher %s %s started %s", component, git_sha(), started_at())
