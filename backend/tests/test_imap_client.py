"""Tests for ingestion.imap_client — uses FakeIMAP, no network, keychain mocked."""

from unittest import mock

import pytest

from ingestion import imap_client
from ingestion.imap_client import GmailImapClient, ImapCursor
from tests.fakes import FakeIMAP, build_raw


@pytest.fixture(autouse=True)
def _mock_keychain():
    """Every client.connect() pulls the App Password; stub it out."""
    with mock.patch.object(imap_client, "get_gmail_app_password", return_value="pw"):
        yield


def _client(fake):
    return GmailImapClient("you@example.com", connection_factory=lambda: fake)


def test_fetch_new_returns_all_messages_first_poll():
    fake = FakeIMAP({
        1: build_raw("a@b.com", "first"),
        2: build_raw("boss@example.com", "second"),
    })
    cursor = ImapCursor()
    with _client(fake) as client:
        msgs = list(client.fetch_new(cursor))
    assert [m.subject for m in msgs] == ["first", "second"]
    assert cursor.last_uid == 2
    assert cursor.uidvalidity == 1000
    # ids are namespaced by account so they're globally unique.
    assert msgs[0].id == "you@example.com:1"


def test_fetch_new_is_incremental():
    fake = FakeIMAP({1: build_raw("a@b.com", "old"), 2: build_raw("a@b.com", "new")})
    cursor = ImapCursor(uidvalidity=1000, last_uid=1)
    with _client(fake) as client:
        msgs = list(client.fetch_new(cursor))
    assert [m.subject for m in msgs] == ["new"]
    assert cursor.last_uid == 2


def test_fetch_new_nothing_new():
    fake = FakeIMAP({1: build_raw("a@b.com", "only")})
    cursor = ImapCursor(uidvalidity=1000, last_uid=1)
    with _client(fake) as client:
        msgs = list(client.fetch_new(cursor))
    assert msgs == []
    assert cursor.last_uid == 1


def test_uidvalidity_change_resets_cursor():
    fake = FakeIMAP({1: build_raw("a@b.com", "resync")}, uidvalidity=2000)
    cursor = ImapCursor(uidvalidity=1000, last_uid=99)  # stale epoch
    with _client(fake) as client:
        msgs = list(client.fetch_new(cursor))
    assert [m.subject for m in msgs] == ["resync"]
    assert cursor.uidvalidity == 2000


def test_unfetchable_message_is_skipped_not_fatal():
    fake = FakeIMAP({1: build_raw("a@b.com", "good"), 2: None})  # uid 2 fetch → None
    cursor = ImapCursor()
    with _client(fake) as client:
        msgs = list(client.fetch_new(cursor))
    assert [m.subject for m in msgs] == ["good"]
    # cursor still advanced past the bad one so we don't loop forever (P1).
    assert cursor.last_uid == 2


# ── socket timeout + reconnect/skip (gate-defects Part B) ─────────────────────

def test_default_connection_sets_socket_timeout():
    """The real connection must carry a socket timeout — a bare blocking SSL
    read is exactly what wedged the Session-23 backfill forever."""
    client = GmailImapClient("you@example.com")
    with mock.patch.object(imap_client.imaplib, "IMAP4_SSL") as ssl_cls:
        client._default_connection()
    ssl_cls.assert_called_once_with(
        imap_client.GMAIL_IMAP_HOST, imap_client.GMAIL_IMAP_PORT,
        timeout=imap_client.IMAP_SOCKET_TIMEOUT_SECONDS,
    )


class TimeoutingIMAP(FakeIMAP):
    """FakeIMAP whose FETCH of chosen UIDs raises TimeoutError N times."""

    def __init__(self, messages, timeout_uids, times=1, **kw):
        super().__init__(messages, **kw)
        self._timeouts_left = {u: times for u in timeout_uids}
        self.login_count = 0

    def login(self, user, password):
        self.login_count += 1
        return super().login(user, password)

    def uid(self, command, *args):
        if command.upper() == "FETCH":
            uid = int(args[0])
            if self._timeouts_left.get(uid, 0) > 0:
                self._timeouts_left[uid] -= 1
                raise TimeoutError("timed out")
        return super().uid(command, *args)


def test_transient_fetch_timeout_reconnects_and_resumes():
    """One timeout mid-fetch is transient (E7): reconnect, retry the same UID,
    and finish the poll with nothing lost."""
    fake = TimeoutingIMAP(
        {1: build_raw("a@b.com", "one"),
         2: build_raw("a@b.com", "two"),
         3: build_raw("a@b.com", "three")},
        timeout_uids=[2], times=2,   # fails twice, succeeds on the 3rd attempt
    )
    cursor = ImapCursor()
    with _client(fake) as client:
        msgs = list(client.fetch_new(cursor))
    assert [m.subject for m in msgs] == ["one", "two", "three"]
    assert fake.login_count >= 3          # initial connect + 2 reconnects
    assert client.last_poll_skipped_uids == []
    assert cursor.last_uid == 3


def test_repeated_fetch_timeout_skips_uid_loudly(caplog):
    """A UID that times out on every attempt is skipped with an ERROR naming
    it — never silently dropped, never allowed to wedge the poll."""
    fake = TimeoutingIMAP(
        {1: build_raw("a@b.com", "one"),
         2: build_raw("a@b.com", "poison"),
         3: build_raw("a@b.com", "three")},
        timeout_uids=[2], times=99,   # never succeeds
    )
    cursor = ImapCursor()
    with caplog.at_level("ERROR", logger="ingestion.imap_client"):
        with _client(fake) as client:
            msgs = list(client.fetch_new(cursor))
    assert [m.subject for m in msgs] == ["one", "three"]
    assert client.last_poll_skipped_uids == [2]
    assert cursor.last_uid == 3           # advanced past the poison message
    assert any("UID 2" in rec.getMessage() for rec in caplog.records)


def test_reconnect_uidvalidity_change_fails_poll_loudly():
    """If UIDVALIDITY rolls while we're mid-poll, the in-flight UID list is
    meaningless — the poll must fail loudly (ImapError), not guess."""
    class RollingIMAP(TimeoutingIMAP):
        def status(self, mailbox, what):
            # UIDVALIDITY changes after the first reconnect's re-select.
            uv = 1000 if self.login_count <= 1 else 2000
            return ("OK", [f"{mailbox} (UIDVALIDITY {uv})".encode()])

    fake = RollingIMAP({1: build_raw("a@b.com", "one")}, timeout_uids=[1], times=1)
    from ingestion.imap_client import ImapError
    with _client(fake) as client:
        with pytest.raises(ImapError, match="UIDVALIDITY changed mid-poll"):
            list(client.fetch_new(ImapCursor()))


def test_context_manager_logs_in_and_out():
    fake = FakeIMAP({})
    with _client(fake):
        assert fake.logged_in
    assert fake.logged_out


# ── verify_login: the four onboarding connectivity branches (closes E7) ──────
# These mock the boundaries inside imap_client (keychain + the connection's
# login) so the real branch logic in verify_login runs — not the method itself.

def test_verify_login_success():
    fake = FakeIMAP({})
    ok, reason = _client(fake).verify_login()
    assert (ok, reason) == (True, "ok")
    assert fake.logged_out  # logged straight back out (P5: no side effects)


def test_verify_login_missing_credential():
    fake = FakeIMAP({})
    from ingestion.keychain import KeychainError
    with mock.patch.object(imap_client, "get_gmail_app_password",
                           side_effect=KeychainError("no password stored")):
        ok, reason = _client(fake).verify_login()
    assert (ok, reason) == (False, "missing_credential")
    assert not fake.logged_in  # never even attempted a connection


def test_verify_login_auth_failed():
    import imaplib

    class AuthRejectIMAP(FakeIMAP):
        def login(self, user, password):
            raise imaplib.IMAP4.error("[AUTHENTICATIONFAILED] Invalid credentials")

    fake = AuthRejectIMAP({})
    ok, reason = _client(fake).verify_login()
    assert (ok, reason) == (False, "auth_failed")


def test_verify_login_network_error():
    class UnreachableIMAP(FakeIMAP):
        def login(self, user, password):
            raise OSError("connection refused")

    fake = UnreachableIMAP({})
    ok, reason = _client(fake).verify_login()
    assert (ok, reason) == (False, "network_error")


# ── mark-as-read write-back (spec §3.5.3, D16/D21, P5) ────────────────────────

def _raw_with_id(subject, message_id):
    raw = build_raw("s@x.com", subject, plain="x")
    import email
    msg = email.message_from_bytes(raw)
    del msg["Message-ID"]
    msg["Message-ID"] = message_id
    return msg.as_bytes()


def test_mark_read_sets_seen_on_unique_match():
    fake = FakeIMAP({7: _raw_with_id("m", "<uniq@test>")})
    with _client(fake) as client:
        assert client.mark_read("<uniq@test>") is True
    assert 7 in fake.seen_uids
    assert fake.selected_readonly is False          # writable select, not readonly
    assert fake.store_calls == [("7", "+FLAGS", "(\\Seen)")]


def test_mark_unread_clears_seen():
    fake = FakeIMAP({7: _raw_with_id("m", "<uniq@test>")})
    fake.seen_uids.add(7)
    with _client(fake) as client:
        assert client.mark_unread("<uniq@test>") is True
    assert 7 not in fake.seen_uids
    assert fake.store_calls == [("7", "-FLAGS", "(\\Seen)")]


def test_mark_read_no_match_does_not_store():
    fake = FakeIMAP({7: _raw_with_id("m", "<present@test>")})
    with _client(fake) as client:
        assert client.mark_read("<absent@test>") is False   # 0 matches
    assert fake.store_calls == []
    assert fake.seen_uids == set()


def test_mark_read_ambiguous_match_does_not_store():
    # Two messages share a Message-ID → cannot target one safely (>1) → abort.
    dup = "<dup@test>"
    fake = FakeIMAP({7: _raw_with_id("a", dup), 8: _raw_with_id("b", dup)})
    with _client(fake) as client:
        assert client.mark_read(dup) is False
    assert fake.store_calls == []
    assert fake.seen_uids == set()


def test_mark_read_empty_message_id_skips():
    fake = FakeIMAP({7: _raw_with_id("m", "<uniq@test>")})
    with _client(fake) as client:
        assert client.mark_read("") is False
    assert fake.store_calls == []


# ── Session 34: select/status timeouts are TRANSIENT, not fatal ──────────────
# Regression for the Aug-13 alpha outage. The poller died on a TimeoutError
# raised from _select_mailbox and never came back; 141 messages sat unfetched
# for 13 days. _fetch_raw_with_retry already treated a mid-FETCH timeout as
# transient (E7), but the SELECT/STATUS pair at the top of fetch_new had no
# such handling, so a bare TimeoutError (an OSError) escaped poll_once's
# `except ImapError` and killed the account's producer thread permanently.

class SelectTimeoutIMAP(FakeIMAP):
    """Times out on the first N select() calls, then behaves normally."""

    def __init__(self, messages, fail_times=1, on="select", **kw):
        super().__init__(messages, **kw)
        self._left = fail_times
        self._on = on
        self.login_count = 0
        self.select_attempts = 0

    def login(self, user, password):
        self.login_count += 1
        return super().login(user, password)

    def select(self, mailbox, readonly=False):
        self.select_attempts += 1
        if self._on == "select" and self._left > 0:
            self._left -= 1
            raise TimeoutError("The read operation timed out")
        return super().select(mailbox, readonly=readonly)

    def status(self, mailbox, what):
        if self._on == "status" and self._left > 0:
            self._left -= 1
            raise TimeoutError("The read operation timed out")
        return super().status(mailbox, what)


@pytest.mark.parametrize("on", ["select", "status"])
def test_select_timeout_is_retried_not_fatal(on):
    """A transient timeout in SELECT or STATUS reconnects and completes the
    poll. This is the exact call that killed the alpha poller."""
    fake = SelectTimeoutIMAP(
        {1: build_raw("a@b.com", "one"), 2: build_raw("a@b.com", "two")},
        fail_times=1, on=on,
    )
    cursor = ImapCursor()
    with _client(fake) as client:
        msgs = list(client.fetch_new(cursor))
    assert [m.subject for m in msgs] == ["one", "two"]
    assert fake.login_count >= 2      # reconnected at least once
    assert cursor.last_uid == 2


def test_persistent_select_timeout_raises_imap_error_not_timeout():
    """When retries are exhausted the failure must surface as ImapError, so
    poll_once's `except ImapError` backoff owns it. A bare TimeoutError escapes
    that handler and kills the producer thread for good — the Aug-13 bug."""
    fake = SelectTimeoutIMAP({1: build_raw("a@b.com", "one")}, fail_times=99)
    cursor = ImapCursor()
    with _client(fake) as client:
        with pytest.raises(imap_client.ImapError):
            list(client.fetch_new(cursor))


# ── Retrieval-window size preview (backfill-scope §6.4) ──────────────────────
#
# Before committing to "everything", the user should be told what that means in
# messages. The work order calls this "the single most useful sentence this
# feature can show" — an adjective ("large") is not a number, and 3,311 is.
#
# Read-only by construction (P5): SELECT readonly + UID SEARCH, no FETCH, no
# STORE. The same discipline as verify_login, which this mirrors deliberately.

def test_count_since_returns_the_number_of_messages_in_the_window():
    fake = FakeIMAP({1: b"a", 2: b"b", 3: b"c"})
    client = GmailImapClient(account="a@x.example",
                             connection_factory=lambda: fake)
    with mock.patch.object(imap_client, "get_gmail_app_password", return_value="pw"):
        assert client.count_since("01-Jan-2026") == 3


def test_count_since_NONE_counts_the_whole_mailbox():
    """`everything` has no cutoff — the count must still be a real number, since
    that is precisely the case the warning exists for."""
    fake = FakeIMAP({1: b"a", 2: b"b"})
    client = GmailImapClient(account="a@x.example",
                             connection_factory=lambda: fake)
    with mock.patch.object(imap_client, "get_gmail_app_password", return_value="pw"):
        assert client.count_since(None) == 2


def test_count_since_SENDS_THE_CUTOFF_it_was_given():
    """The count must describe the window the user picked, not the whole mailbox
    — a preview that silently counts everything would overstate every window but
    'everything', which is the one case it is allowed to be big."""
    fake = FakeIMAP({1: b"a"})
    client = GmailImapClient(account="a@x.example",
                             connection_factory=lambda: fake)
    with mock.patch.object(imap_client, "get_gmail_app_password", return_value="pw"):
        client.count_since("15-Mar-2026")
    assert fake.search_calls, "no date-scoped SEARCH was issued"
    assert "SINCE" in [a.upper() for a in fake.search_calls[0]]
    assert "15-Mar-2026" in fake.search_calls[0]


def test_count_since_is_READ_ONLY_no_fetch_no_store():
    """P5 — a preview must not touch the mailbox. Selecting readonly is the
    mechanical guarantee; asserting no STORE is the behavioural one."""
    fake = FakeIMAP({1: b"a", 2: b"b"})
    client = GmailImapClient(account="a@x.example",
                             connection_factory=lambda: fake)
    with mock.patch.object(imap_client, "get_gmail_app_password", return_value="pw"):
        client.count_since(None)
    assert fake.selected_readonly is True, "mailbox was selected writable"
    assert fake.store_calls == [], "a preview wrote flags to the mailbox"
    assert fake.logged_out is True, "the preview connection was left open"


def test_count_since_reports_a_bad_credential_rather_than_guessing():
    """A count that returns 0 on an auth failure would tell the user their
    mailbox is empty — the most misleading possible answer at exactly the moment
    they are deciding how much to import."""
    from ingestion.keychain import KeychainError
    client = GmailImapClient(account="a@x.example",
                             connection_factory=lambda: None)
    with mock.patch.object(imap_client, "get_gmail_app_password",
                           side_effect=KeychainError("no password")):
        with pytest.raises(KeychainError):
            client.count_since(None)


# ── Server-side retrieval-window narrowing (2026-09-07) ──────────────────────
#
# The window used to be enforced ONLY client-side: every UID above the cursor
# was downloaded in full, then discarded if it fell outside. Measured on a real
# cold start with a 7-day window: 1,588 messages fetched to keep 15, taking 6.3
# minutes of total silence. The preview path answered the same question with
# SINCE in about a second — two implementations of one question, 400x apart.

def test_imap_date_floor_rounds_DOWN_never_up():
    """The rounding direction is a safety property, not a formatting detail.

    Rounding UP would let the server withhold mail INSIDE the window, and no
    later check can recover a message that was never downloaded. Rounding down
    costs a few redundant fetches, which `_before()` then discards.

    VERIFIED RED by using `parsed.strftime` directly (no timedelta): the
    00:30 case below returns 01-Sep, which is AFTER the cutoff date and would
    let a server in a behind-UTC timezone hide same-day mail.
    """
    from ingestion.imap_client import imap_date_floor

    # A cutoff mid-day floors to the PREVIOUS day, never the same day.
    assert imap_date_floor("2026-08-31T14:00:22+00:00") == "30-Aug-2026"
    # Just after midnight is the dangerous case: a server reckoning in a
    # behind-UTC timezone still dates that mail to the previous day.
    assert imap_date_floor("2026-09-01T00:30:00+00:00") == "31-Aug-2026"
    # Month and year boundaries must not roll incorrectly.
    assert imap_date_floor("2026-01-01T00:00:00+00:00") == "31-Dec-2025"
    assert imap_date_floor("2026-03-01T12:00:00+00:00") == "28-Feb-2026"


def test_imap_date_floor_is_locale_independent():
    """IMAP requires an English month abbreviation. strftime('%b') is
    locale-dependent and would emit e.g. 'sept' under a French locale, which
    the server rejects — silently falling back to fetching everything."""
    from ingestion.imap_client import imap_date_floor
    for month, abbr in ((1, "Jan"), (5, "May"), (9, "Sep"), (12, "Dec")):
        got = imap_date_floor(f"2026-{month:02d}-15T12:00:00+00:00")
        assert got.split("-")[1] == abbr, f"month {month} rendered as {got}"


def test_unparseable_cutoff_disables_narrowing_rather_than_guessing():
    """Fail toward fetching everything: slow, but never lossy. Returning a
    wrong date would silently skip mail inside the window."""
    from ingestion.imap_client import imap_date_floor
    assert imap_date_floor("not-a-date") is None
    assert imap_date_floor("") is None


def test_search_passes_SINCE_to_the_server_when_given():
    """The whole point: the server must do the narrowing, so the mail outside
    the window is never downloaded.

    VERIFIED RED against the pre-fix client, which issued only
    `UID <start>:*` and applied the window after downloading everything.
    """
    from ingestion.imap_client import GmailImapClient

    calls = []

    class RecordingConn:
        def uid(self, *args):
            calls.append(args)
            return "OK", [b""]

    client = GmailImapClient("a@b.com", connection_factory=lambda: None)
    client._conn = RecordingConn()

    client._search_new_uids(10, since="30-Aug-2026")
    assert calls, "no SEARCH was issued"
    args = calls[-1]
    assert "SINCE" in args and "30-Aug-2026" in args, (
        f"the date filter never reached the server: {args}")
    assert "UID 11:*" in args, "the UID range must still bound the search"

    # And without a window, the search must be unchanged — no accidental
    # narrowing for an account that chose "everything".
    calls.clear()
    client._search_new_uids(10)
    assert "SINCE" not in calls[-1], (
        f"narrowing was applied to an unwindowed account: {calls[-1]}")
