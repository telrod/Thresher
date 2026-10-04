"""Tests for ingestion.keychain — the `security` shell-out is mocked."""

import subprocess
from unittest import mock

import pytest

from ingestion import keychain
from ingestion.keychain import (
    KeychainError, get_gmail_app_password, get_secret,
    store_secret, delete_secret, list_accounts,
)


def _completed(returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess(args=[], returncode=returncode,
                                       stdout=stdout, stderr=stderr)


def test_get_secret_returns_password():
    with mock.patch.object(keychain.subprocess, "run",
                           return_value=_completed(stdout="app-pass-1234\n")) as run:
        secret = get_secret("you@example.com")
    assert secret == "app-pass-1234"
    # verify we asked `security` for the right service/account, password-only.
    args = run.call_args.args[0]
    assert args[:2] == ["security", "find-generic-password"]
    assert "-w" in args
    assert "you@example.com" in args


def test_get_secret_raises_when_not_found():
    with mock.patch.object(keychain.subprocess, "run",
                           return_value=_completed(returncode=44,
                                                   stderr="could not be found")):
        with pytest.raises(KeychainError) as exc:
            get_secret("missing@gmail.com")
    assert "missing@gmail.com" in str(exc.value)


def test_get_secret_raises_on_empty_value():
    with mock.patch.object(keychain.subprocess, "run",
                           return_value=_completed(stdout="\n")):
        with pytest.raises(KeychainError):
            get_secret("empty@gmail.com")


def test_get_secret_raises_when_security_binary_missing():
    with mock.patch.object(keychain.subprocess, "run", side_effect=FileNotFoundError):
        with pytest.raises(KeychainError) as exc:
            get_secret("a@b.com")
    assert "security" in str(exc.value)


def test_gmail_wrapper_delegates_to_get_secret():
    with mock.patch.object(keychain, "get_secret", return_value="pw") as gs:
        assert get_gmail_app_password("a@b.com") == "pw"
    gs.assert_called_once_with("a@b.com")


# ── store_secret (Wave 1, gap #2) ─────────────────────────────────────────────

def test_store_secret_invokes_add_with_update_flag():
    with mock.patch.object(keychain.subprocess, "run",
                           return_value=_completed(returncode=0)) as run:
        store_secret("you@example.com", "app-pass")
    args = run.call_args.args[0]
    assert args[:2] == ["security", "add-generic-password"]
    assert "-U" in args                      # update-in-place, not duplicate-error
    assert "you@example.com" in args
    assert "app-pass" in args                # passed via -w


def test_store_secret_refuses_empty():
    with pytest.raises(KeychainError):
        store_secret("you@example.com", "")


def test_store_secret_raises_on_security_failure():
    with mock.patch.object(keychain.subprocess, "run",
                           return_value=_completed(returncode=1, stderr="denied")):
        with pytest.raises(KeychainError):
            store_secret("you@example.com", "p")


def test_store_secret_never_includes_secret_in_error():
    """A failure message must not leak the password value."""
    with mock.patch.object(keychain.subprocess, "run",
                           return_value=_completed(returncode=1, stderr="denied")):
        with pytest.raises(KeychainError) as exc:
            store_secret("you@example.com", "super-secret-pw")
    assert "super-secret-pw" not in str(exc.value)


# ── delete_secret (Wave 1, gap #3) ────────────────────────────────────────────

def test_delete_secret_returns_true_on_success():
    with mock.patch.object(keychain.subprocess, "run",
                           return_value=_completed(returncode=0)):
        assert delete_secret("you@example.com") is True


def test_delete_secret_returns_false_when_absent():
    with mock.patch.object(keychain.subprocess, "run",
                           return_value=_completed(returncode=44,
                                                   stderr="could not be found")):
        assert delete_secret("missing@gmail.com") is False


def test_delete_secret_raises_on_other_failure():
    with mock.patch.object(keychain.subprocess, "run",
                           return_value=_completed(returncode=1, stderr="locked")):
        with pytest.raises(KeychainError):
            delete_secret("you@example.com")


# ── list_accounts (Wave 1, gap #3) ────────────────────────────────────────────

_DUMP = '''keychain: "/Users/x/Library/Keychains/login.keychain-db"
class: "genp"
attributes:
    "acct"<blob>="you@example.com"
    "svce"<blob>="thresher"
    "type"<uint32>=<NULL>
keychain: "/Users/x/Library/Keychains/login.keychain-db"
class: "genp"
attributes:
    "acct"<blob>="someone@example.com"
    "svce"<blob>="other-app"
keychain: "/Users/x/Library/Keychains/login.keychain-db"
class: "genp"
attributes:
    "acct"<blob>="work@example.com"
    "svce"<blob>="thresher"
'''


def test_list_accounts_filters_to_service_and_sorts():
    with mock.patch.object(keychain.subprocess, "run",
                           return_value=_completed(stdout=_DUMP)):
        accounts = list_accounts()
    # only thresher items, sorted, the other-app one excluded
    assert accounts == ["work@example.com", "you@example.com"]


def test_list_accounts_empty_when_no_items():
    with mock.patch.object(keychain.subprocess, "run",
                           return_value=_completed(stdout="")):
        assert list_accounts() == []


def test_list_accounts_raises_when_security_missing():
    with mock.patch.object(keychain.subprocess, "run", side_effect=FileNotFoundError):
        with pytest.raises(KeychainError):
            list_accounts()