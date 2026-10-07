"""
scripts/phase3-reset-test-user.sh — each refusal fires, and a refusal changes nothing.

The script deletes a user's Thresher data, Keychain items and tutorial flag, so
its refusals are the whole of its safety. Each test runs it with HOME pointed
at a throwaway directory holding a sentinel data folder, AND with
THRESHER_RESET_DRY_RUN=1, so a broken guard prints instead of deleting.

These tests run as the user who owns the checkout — that is the point: the
owner refusal must fire for them. The app-running refusal is driven by a
compiled stub named `Thresher` (a copied /bin/sleep is killed on launch, and a
symlink keeps the target's process name), killed by pid afterwards, so a real
Thresher app is never signalled.

Both proven red (2026-10-06) by deleting the matching guard block from the
script: the owner test failed with the reset proceeding (exit 0, "would run:
rm -rf …"), and the app test failed with its refusal line missing.
"""

import os
import pwd
import subprocess
import time
from pathlib import Path

import pytest

_REPO = Path(__file__).resolve().parents[2]
_SCRIPT = _REPO / "scripts" / "phase3-reset-test-user.sh"


@pytest.fixture
def fake_home(tmp_path):
    home = tmp_path / "home"
    data = home / "Library" / "Application Support" / "thresher"
    data.mkdir(parents=True)
    (data / "sentinel").write_text("must survive a refusal")
    return home


def _run(home: Path) -> subprocess.CompletedProcess:
    env = dict(os.environ, HOME=str(home), THRESHER_RESET_DRY_RUN="1")
    return subprocess.run(["bash", str(_SCRIPT)], env=env,
                          capture_output=True, text=True, timeout=30)


def _assert_refused_and_untouched(r: subprocess.CompletedProcess, home: Path):
    assert r.returncode == 2, (r.returncode, r.stdout, r.stderr)
    assert "REFUSED, nothing was changed" in r.stderr
    assert r.stdout == "", "a refusal must act on nothing, not even say it would"
    assert (home / "Library" / "Application Support" / "thresher" / "sentinel").exists()


def test_refuses_for_the_user_who_owns_the_checkout(fake_home):
    me = pwd.getpwuid(os.getuid()).pw_name
    owner = pwd.getpwuid(_REPO.stat().st_uid).pw_name
    assert me == owner, ("this test must run as the checkout's owner to exercise "
                         f"the owner refusal; running as {me}, owner is {owner}")
    r = _run(fake_home)
    _assert_refused_and_untouched(r, fake_home)
    assert "who owns the repo checkout" in r.stderr


def test_refuses_while_a_thresher_process_is_running(fake_home, tmp_path):
    src = tmp_path / "stub.c"
    src.write_text("#include <unistd.h>\nint main(void){sleep(60);return 0;}\n")
    stub = tmp_path / "bin" / "Thresher"
    stub.parent.mkdir()
    subprocess.run(["cc", "-o", str(stub), str(src)], check=True)
    proc = subprocess.Popen([str(stub)])
    try:
        # Wait until pgrep can see it, so a pass is not a race the stub lost.
        deadline = time.monotonic() + 5
        while str(proc.pid) not in subprocess.run(
                ["pgrep", "-x", "Thresher"], capture_output=True, text=True).stdout.split():
            assert time.monotonic() < deadline, "the stub never appeared to pgrep"
            time.sleep(0.05)
        r = _run(fake_home)
    finally:
        proc.kill()
        proc.wait()
    _assert_refused_and_untouched(r, fake_home)
    assert "the Thresher app is running" in r.stderr
    assert str(proc.pid) in r.stderr
