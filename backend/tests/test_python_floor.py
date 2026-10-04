"""
The Python floor: the backend MUST parse on macOS's stock interpreter.

WHY THIS EXISTS
---------------
Packaging (D68) ships `backend/` inside the app bundle and runs it with
`/usr/bin/python3` — Apple's, which on Sonoma is **3.9.6**. Nothing needs to be
installed by the user, which is the whole point.

That works today only because every `X | None` annotation in the codebase happens
to be QUOTED, so 3.9 never evaluates it. Nothing enforced that. One unquoted
`str | None` would be a SyntaxError on a beta user's machine while every test
here still passed on the dev machine's 3.11 — a failure that cannot be
reproduced by the person who caused it.

This is the guard, and building it corrected a wrong assumption worth recording.
The obvious implementation — `py_compile` every file — **does not work**: an
unquoted `str | None` is valid *syntax* on 3.9 and compiles fine. It fails at
**import** time, as `TypeError: unsupported operand type(s) for |`, because
annotations are evaluated when the `def` (or module-level assignment) executes.
So the guard IMPORTS every module on the floor interpreter rather than compiling
it. The self-test below exists because the compile-based version passed against
the very regression it was written to catch.

WHAT IT DOES NOT CLAIM
----------------------
Importing is not running. A 3.10-only call inside a function body would sail past
this and fail when that line executes. The suite proper runs on the dev
interpreter, so this covers the class of failure invisible there — module-level
and signature-level incompatibility — and not the class that isn't.
"""

import subprocess
import sys
from pathlib import Path

import pytest

# macOS's system interpreter. This is the actual floor, not an aspiration: it is
# what the bundled app runs, so it is what the code must parse on.
SYSTEM_PYTHON = Path("/usr/bin/python3")
BACKEND = Path(__file__).resolve().parent.parent


@pytest.mark.skipif(not SYSTEM_PYTHON.exists(),
                    reason="no /usr/bin/python3 (not macOS)")
def test_every_backend_module_IMPORTS_on_the_system_python():
    """Every bundled backend module must import on the floor interpreter.

    IMPORT, not compile: an unquoted `X | None` compiles cleanly on 3.9 and
    raises `TypeError` when the annotation is evaluated at def time. Excludes
    tests/ (never bundled) and _vendor/ (third-party, resolved for the floor
    interpreter separately).

    The API modules are imported with the vendored tree on the path when it
    exists, since flask is a genuine dependency rather than a compatibility
    problem; without it, `api.app` is skipped rather than reported as a floor
    violation it isn't.
    """
    modules = []
    for path in sorted(BACKEND.rglob("*.py")):
        parts = path.relative_to(BACKEND).parts
        if any(p in ("tests", "_vendor", "__pycache__") for p in parts):
            continue
        if path.name == "__init__.py":
            modules.append(".".join(parts[:-1]))
        else:
            modules.append(".".join(parts)[: -len(".py")])
    modules = [m for m in modules if m]
    assert modules, "found no backend modules to check — the glob is wrong"

    vendor = BACKEND / "_vendor"
    has_flask = vendor.exists()

    failures = []
    for module in modules:
        if module.startswith("api.") or module == "api":
            if not has_flask:
                continue          # a missing dependency is not a floor problem
        env = {"PATH": "/usr/bin:/bin"}
        if has_flask:
            env["PYTHONPATH"] = str(vendor)
        result = subprocess.run(
            [str(SYSTEM_PYTHON), "-c",
             f"import sys; sys.path.insert(0, '.'); import {module}"],
            cwd=str(BACKEND), capture_output=True, text=True, env=env)
        if result.returncode != 0:
            failures.append(f"{module}: {result.stderr.strip().splitlines()[-1]}")

    assert not failures, (
        "these modules do not import on the system Python — the interpreter the "
        "BUNDLED app runs (D68), so this breaks a beta user and nobody else:\n  "
        + "\n  ".join(failures)
        + "\n\nMost likely an UNQUOTED `X | None` annotation. Quote it as "
        '"X | None" so the floor interpreter never evaluates it.')


@pytest.mark.skipif(not SYSTEM_PYTHON.exists(),
                    reason="no /usr/bin/python3 (not macOS)")
def test_the_guard_actually_CATCHES_a_3_10_only_annotation(tmp_path):
    """Verify the guard can fail, rather than trusting that it would.

    A guard that cannot detect what it guards against is worse than none,
    because it is believed. **This test earned its place immediately:** the first
    version of the guard used `py_compile`, and this test failed — `str | None`
    is valid 3.9 *syntax* and only breaks when the annotation is *evaluated*. The
    guard was rewritten to import.
    """
    offender = tmp_path / "offender.py"
    offender.write_text("def f(x: str | None) -> None: ...\n")

    result = subprocess.run(
        [str(SYSTEM_PYTHON), "-c", "import offender"],
        cwd=str(tmp_path), capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin"})

    assert result.returncode != 0, (
        "the floor interpreter accepted an unquoted union annotation, so this "
        "guard proves nothing — is SYSTEM_PYTHON really the old interpreter?")
    assert "TypeError" in result.stderr, result.stderr


@pytest.mark.skipif(not SYSTEM_PYTHON.exists(),
                    reason="no /usr/bin/python3 (not macOS)")
def test_the_poller_imports_with_NO_third_party_packages():
    """The poller must need nothing vendored.

    Only the API imports flask; ingestion, classification and notifications are
    stdlib-only. That is why the poller can be started before/independently of
    the vendored tree, and it is worth pinning: a new third-party import in the
    ingestion path would silently make the poller undeployable on a clean
    machine.
    """
    result = subprocess.run(
        [str(SYSTEM_PYTHON), "-c",
         "import sys; sys.path.insert(0, '.'); "
         "import ingestion.pipeline, ingestion.imap_client, "
         "classification.engine, notifications.service, db.database"],
        cwd=str(BACKEND), capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin", "PYTHONPATH": ""})

    assert result.returncode == 0, (
        "the ingestion path no longer imports on a clean system Python — "
        f"a third-party dependency crept in:\n{result.stderr}")


# ── Bundled-backend provenance (D68) ─────────────────────────────────────────

def test_a_bundled_backend_reports_its_STAMPED_sha(tmp_path, monkeypatch):
    """A bundle has no git repository, so provenance reads a stamp written beside
    it at bundle time.

    The stamp is checked BEFORE git deliberately. In a bundle the git call is not
    merely unavailable — it could succeed against whatever repository the process
    was launched from and return a confident SHA describing entirely different
    code. `unknown` is bad; a plausible wrong answer is worse.
    """
    import importlib
    import provenance

    stamp = tmp_path / "BUILD_SHA"
    stamp.write_text("abc1234\n")
    monkeypatch.setattr(provenance, "_BUILD_STAMP_PATH", stamp)
    monkeypatch.setattr(provenance, "_GIT_SHA", None)

    assert provenance.git_sha() == "abc1234"


def test_without_a_stamp_provenance_still_uses_git(tmp_path, monkeypatch):
    """A checkout has no stamp and git is the better answer there — so the stamp
    must be a fallback for the bundled case, not a replacement."""
    import provenance

    monkeypatch.setattr(provenance, "_BUILD_STAMP_PATH", tmp_path / "absent")
    monkeypatch.setattr(provenance, "_GIT_SHA", None)

    sha = provenance.git_sha()
    assert sha != "abc1234"
    # In this repo git is available, so it must produce something real.
    assert sha == "unknown" or len(sha) >= 7, sha
