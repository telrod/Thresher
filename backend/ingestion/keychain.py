"""
thresher keychain accessor
Retrieves secrets (the Gmail App Password) from the macOS Keychain at runtime.

Per CLAUDE.md / D26:
  - v1 auth is IMAP + App Password (OAuth 2.0 deferred to a later phase)
  - The App Password is stored in the macOS Keychain; never hardcoded or in env files
  - Config key: `gmail_app_password`

We shell out to the system `security` binary rather than taking a dependency on
a third-party keyring wrapper — it is always present on macOS and keeps the
ingestion module's dependency surface at zero (stdlib only).
"""

import logging
import subprocess
from typing import Optional

log = logging.getLogger(__name__)

# Service name under which the App Password is stored in the login keychain.
# Stored once (by the user / onboarding flow) with, e.g.:
#   security add-generic-password -s "thresher" -a "<account>" -w "<app-password>"
KEYCHAIN_SERVICE = "thresher"

# The config key referenced in CLAUDE.md. Kept as a named constant so callers
# refer to it symbolically rather than by string literal.
GMAIL_APP_PASSWORD_KEY = "gmail_app_password"


class KeychainError(RuntimeError):
    """Raised when a secret cannot be retrieved from the Keychain."""


def get_secret(account: str, service: str = KEYCHAIN_SERVICE) -> str:
    """
    Retrieve a generic-password secret from the macOS login Keychain.

    Args:
        account: the account name the password is stored under (typically the
                 email address, e.g. "you@example.com").
        service: the keychain service name (defaults to "thresher").

    Returns:
        The secret as a string.

    Raises:
        KeychainError: if the item is not found or `security` fails.
    """
    try:
        proc = subprocess.run(
            [
                "security",
                "find-generic-password",
                "-s", service,
                "-a", account,
                "-w",                       # print only the password to stdout
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError as exc:  # not on macOS / `security` missing
        raise KeychainError(
            "The macOS `security` tool is not available; cannot read the Keychain."
        ) from exc

    if proc.returncode != 0:
        # `security` writes a human-readable reason to stderr (e.g. item not found).
        reason = proc.stderr.strip() or f"exit code {proc.returncode}"
        raise KeychainError(
            f"Could not read secret for service={service!r} account={account!r}: {reason}. "
            f"Store it with:\n"
            f'  security add-generic-password -s "{service}" -a "{account}" -w "<app-password>"'
        )

    # `-w` emits the password followed by a trailing newline.
    secret = proc.stdout.rstrip("\n")
    if not secret:
        raise KeychainError(
            f"Keychain item for service={service!r} account={account!r} is empty."
        )
    log.debug("Retrieved secret for account=%s from keychain service=%s", account, service)
    return secret


def store_secret(account: str, secret: str, service: str = KEYCHAIN_SERVICE) -> None:
    """
    Store (or replace) a generic-password secret in the macOS login Keychain.

    Backs the onboarding "connect account" step (frontend gap #2). This is a
    real side effect, but a tightly scoped one (P5): it writes ONLY to the
    Keychain — no IMAP connection, no mailbox access, no DB write. Verifying the
    credential against the server is a separate concern (see verify_login / the
    read-only /accounts/verify endpoint); the two side-effect classes are kept
    cleanly split (D40).

    Uses `-U` so an existing item for the same service+account is updated in
    place rather than erroring on a duplicate.

    The secret value is passed via `-w <value>` and is NEVER logged or echoed.

    Args:
        account: the account name to store under (typically the email address).
        secret:  the App Password to store.
        service: the keychain service name (defaults to "thresher").

    Raises:
        KeychainError: if the secret is empty or `security` fails.
    """
    if not secret:
        raise KeychainError("Refusing to store an empty secret.")
    try:
        proc = subprocess.run(
            [
                "security",
                "add-generic-password",
                "-s", service,
                "-a", account,
                "-w", secret,
                "-U",                       # update the item if it already exists
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError as exc:  # not on macOS / `security` missing
        raise KeychainError(
            "The macOS `security` tool is not available; cannot write the Keychain."
        ) from exc

    if proc.returncode != 0:
        reason = proc.stderr.strip() or f"exit code {proc.returncode}"
        # Note: `security` does not echo the password on failure, but we still
        # only surface service/account/reason here — never the secret value.
        raise KeychainError(
            f"Could not store secret for service={service!r} account={account!r}: {reason}."
        )
    log.debug("Stored secret for account=%s in keychain service=%s", account, service)


def delete_secret(account: str, service: str = KEYCHAIN_SERVICE) -> bool:
    """
    Remove a generic-password secret from the macOS login Keychain.

    Backs the Settings "disconnect account" step (frontend gap #3). Side-effect
    scope is the Keychain only (P5): it removes a credential and touches no
    mailbox and no DB.

    Args:
        account: the account whose secret to delete.
        service: the keychain service name (defaults to "thresher").

    Returns:
        True if an item was deleted, False if no matching item existed.

    Raises:
        KeychainError: if `security` is unavailable or fails for a reason other
                       than "item not found".
    """
    try:
        proc = subprocess.run(
            [
                "security",
                "delete-generic-password",
                "-s", service,
                "-a", account,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError as exc:
        raise KeychainError(
            "The macOS `security` tool is not available; cannot modify the Keychain."
        ) from exc

    if proc.returncode == 0:
        log.debug("Deleted secret for account=%s from keychain service=%s", account, service)
        return True
    # `security` returns a non-zero code (44 / SecItemNotFound) when the item is
    # absent. Treat that as "nothing to delete" (idempotent), not an error — the
    # caller maps it to a 404. Any other failure is a real error.
    stderr = proc.stderr.lower()
    if "could not be found" in stderr or "secitemnotfound" in stderr or proc.returncode == 44:
        return False
    reason = proc.stderr.strip() or f"exit code {proc.returncode}"
    raise KeychainError(
        f"Could not delete secret for service={service!r} account={account!r}: {reason}."
    )


def list_accounts(service: str = KEYCHAIN_SERVICE) -> list[str]:
    """
    List the accounts that have a stored secret under `service` — i.e. the set of
    "connected" accounts (frontend gap #3).

    The Keychain is the single source of truth for connected accounts (D41): an
    account is connected iff it has a stored App Password. There is no separate
    accounts table to drift out of sync.

    Implemented by parsing `security dump-keychain`, which lists item attributes
    including the service ("svce") and account ("acct"). We filter to our service
    and return the unique account names, sorted. Read-only; no secret values are
    requested or returned.

    Returns:
        A sorted list of unique account names (may be empty).

    Raises:
        KeychainError: if `security` is unavailable.
    """
    try:
        proc = subprocess.run(
            ["security", "dump-keychain"],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError as exc:
        raise KeychainError(
            "The macOS `security` tool is not available; cannot list accounts."
        ) from exc

    if proc.returncode != 0:
        reason = proc.stderr.strip() or f"exit code {proc.returncode}"
        raise KeychainError(f"Could not list keychain items: {reason}.")

    return _parse_dump_for_service(proc.stdout, service)


def _parse_dump_for_service(dump: str, service: str) -> list[str]:
    """
    Parse `security dump-keychain` output, returning the unique `acct` values of
    items whose `svce` equals `service`, sorted.

    dump-keychain prints one item as a block of attribute lines; the service and
    account appear as:
        "svce"<blob>="thresher"
        "acct"<blob>="you@example.com"
    Attributes whose value is null print as `<NULL>` (no `=`), which we skip.
    Items are separated by `keychain: ...` header lines, so we group on those.
    """
    accounts: set[str] = set()
    cur_service: Optional[str] = None
    cur_account: Optional[str] = None

    def flush():
        if cur_service == service and cur_account is not None:
            accounts.add(cur_account)

    for line in dump.splitlines():
        stripped = line.strip()
        if stripped.startswith("keychain:"):
            flush()
            cur_service = None
            cur_account = None
            continue
        val = _dump_attr_value(stripped)
        if val is None:
            continue
        key, value = val
        if key == "svce":
            cur_service = value
        elif key == "acct":
            cur_account = value
    flush()
    return sorted(accounts)


def _dump_attr_value(line: str) -> Optional[tuple]:
    """
    Extract (attr_key, value) from a dump-keychain attribute line, or None.

    Lines look like: `    "svce"<blob>="thresher"` — a quoted key, then a
    `<type>` tag, then `=` and either a quoted value or `<NULL>`. We return the
    quoted key and the quoted value; lines with a null/non-quoted value yield None.
    """
    if not line.startswith('"'):
        return None
    try:
        key_end = line.index('"', 1)
    except ValueError:
        return None
    key = line[1:key_end]
    eq = line.find("=", key_end)
    if eq == -1:
        return None
    rest = line[eq + 1:]
    if len(rest) < 2 or not rest.startswith('"') or not rest.endswith('"'):
        return None  # e.g. `=<NULL>` or a non-string value
    value = rest[1:-1]
    return (key, value)


def get_gmail_app_password(account: str) -> str:
    """
    Convenience wrapper: fetch the Gmail App Password for the given account.

    This is the single entry point the IMAP client uses, so the config key
    (`gmail_app_password`) and storage convention live in exactly one place.
    """
    return get_secret(account)