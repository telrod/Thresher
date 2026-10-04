"""
Tests for mailbox mark-as-read write-back (spec §3.5.3, D16, D21, P5).

The write-back path in POST /messages/<id>/triage is gated per-account on the
generic preference key `writeback_enabled:<account>` and only fires when triage
advances PAST `new`. These tests exercise the gating matrix and the Message-ID
targeting WITHOUT any real IMAP connection, by injecting a fake IMAP client
factory into create_app (the same seam tests use for the DB).

The cardinal P5 assertion: with write-back unset/false, NO IMAP client is ever
constructed — the opt-out mailbox is provably untouched.
"""

import json
from unittest import mock

import pytest

from db.database import (
    Classification, ClassificationRepo, Message, MessageRepo, get_connection,
    PreferencesRepo,
)
from api.app import create_app
from ingestion import imap_client
from tests.fakes import FakeIMAP, build_raw


@pytest.fixture(autouse=True)
def _mock_keychain():
    """Write-back builds a real GmailImapClient (with a fake connection); its
    connect() still pulls the App Password from the Keychain. Stub it so no real
    Keychain entry is needed for the probe account."""
    with mock.patch.object(imap_client, "get_gmail_app_password", return_value="pw"):
        yield


ACCOUNT = "probe@example.com"
RFC_ID = "<probe-writeback@test>"


class RecordingClientFactory:
    """Builds fake GmailImapClient-like objects and records whether it was called.

    Each built client wraps a FakeIMAP seeded with one message whose Message-ID is
    RFC_ID at uid 5. `constructed` stays False until the factory is invoked — the
    P5 opt-out assertion checks it never flips when write-back is disabled.
    """

    def __init__(self):
        self.constructed = False
        self.clients = []

    def __call__(self, account):
        self.constructed = True
        from ingestion.imap_client import GmailImapClient
        raw = build_raw("s@x.com", "probe", plain="x")
        # Force the Message-ID to the known value the message row will carry.
        raw = raw.replace(b"<probe@test>", RFC_ID.encode())
        fake = FakeIMAP({5: _with_message_id(raw, RFC_ID)})
        client = GmailImapClient(account=account, connection_factory=lambda: fake)
        client._fake = fake  # expose for assertions
        self.clients.append(client)
        return client


def _with_message_id(raw: bytes, message_id: str) -> bytes:
    """Ensure the raw message carries exactly `message_id` as its Message-ID."""
    import email
    msg = email.message_from_bytes(raw)
    del msg["Message-ID"]
    msg["Message-ID"] = message_id
    return msg.as_bytes()


def _seed(db_path, *, triage="new", raw_headers=None):
    conn = get_connection(db_path)
    MessageRepo(conn).insert(Message(
        id=f"{ACCOUNT}:5", account=ACCOUNT, sender_email="s@x.com",
        sender_name="S", subject="probe", body_plain="x",
        received_at="2026-07-12T10:00:00+00:00",
        ingested_at="2026-07-12T10:00:00+00:00",
        raw_headers=raw_headers if raw_headers is not None else {"Message-ID": RFC_ID},
    ))
    ClassificationRepo(conn).upsert(Classification(
        message_id=f"{ACCOUNT}:5", urgency_tier=2, category="work",
        triage_state=triage, classified_at="2026-07-12T10:00:00+00:00",
        rule_matches=[],
    ))
    conn.close()


def _app(db_path, factory):
    app = create_app(
        connection_factory=lambda: get_connection(db_path),
        imap_client_factory=factory,
    )
    app.config.update(TESTING=True)
    return app.test_client()


def _enable_writeback(db_path, account=ACCOUNT, value="true"):
    conn = get_connection(db_path)
    PreferencesRepo(conn).set(f"writeback_enabled:{account}", value)
    conn.close()


# ── P5: opt-out (default) never touches the mailbox ───────────────────────────

def test_writeback_disabled_by_default_no_imap(connection_factory, db_path):
    """No writeback pref set → advancing triage does NOT construct an IMAP client."""
    _seed(db_path, triage="new")
    factory = RecordingClientFactory()
    client = _app(db_path, factory)

    r = client.post(f"/messages/{ACCOUNT}:5/triage", json={"state": "acknowledged"})
    assert r.status_code == 200
    body = r.get_json()
    assert body["triage_state"] == "acknowledged"
    assert body["wrote_back"] is False
    # The cardinal P5 assertion: the mailbox client was never even built.
    assert factory.constructed is False


def test_writeback_explicit_false_no_imap(connection_factory, db_path):
    """writeback_enabled:<acct> = "false" is still off (only "true" enables)."""
    _seed(db_path, triage="new")
    _enable_writeback(db_path, value="false")
    factory = RecordingClientFactory()
    client = _app(db_path, factory)

    r = client.post(f"/messages/{ACCOUNT}:5/triage", json={"state": "done"})
    assert r.get_json()["wrote_back"] is False
    assert factory.constructed is False


# ── enabled: mark read on advance past new ────────────────────────────────────

def test_writeback_enabled_marks_read_on_advance(connection_factory, db_path):
    _seed(db_path, triage="new")
    _enable_writeback(db_path)
    factory = RecordingClientFactory()
    client = _app(db_path, factory)

    # D63: the account pref is necessary but no longer sufficient — the request
    # must opt in too, exactly as both bulk modes require.
    r = client.post(f"/messages/{ACCOUNT}:5/triage",
                    json={"state": "acknowledged", "write_back": True})
    assert r.status_code == 200
    assert r.get_json()["wrote_back"] is True
    assert factory.constructed is True
    fake = factory.clients[0]._fake
    # \Seen was set on uid 5 (the message whose Message-ID matched), via a
    # writable select (readonly=False).
    assert 5 in fake.seen_uids
    assert fake.selected_readonly is False
    assert fake.store_calls == [("5", "+FLAGS", "(\\Seen)")]


def test_writeback_not_triggered_on_state_new(connection_factory, db_path):
    """Setting state back to (or staying at) `new` must not write back."""
    _seed(db_path, triage="acknowledged")
    _enable_writeback(db_path)
    factory = RecordingClientFactory()
    client = _app(db_path, factory)

    # Opt-in GIVEN, so this still tests what it claims: `new` never syncs read
    # state, independently of D63's gate.
    r = client.post(f"/messages/{ACCOUNT}:5/triage",
                    json={"state": "new", "write_back": True})
    assert r.status_code == 200
    assert r.get_json()["wrote_back"] is False
    assert factory.constructed is False   # `new` never syncs read state


# ── targeting safety: only an exact single Message-ID match acts ──────────────

def test_writeback_no_match_does_not_store(connection_factory, db_path):
    """If the Message-ID isn't found in the mailbox, nothing is marked (0 matches)."""
    # Message row carries a Message-ID the fake mailbox doesn't contain.
    _seed(db_path, triage="new", raw_headers={"Message-ID": "<not-in-mailbox@test>"})
    _enable_writeback(db_path)
    factory = RecordingClientFactory()
    client = _app(db_path, factory)

    r = client.post(f"/messages/{ACCOUNT}:5/triage",
                    json={"state": "needs_action", "write_back": True})   # D63 opt-in
    assert r.status_code == 200
    # Client was built + searched, but found no unique target → no STORE, no flag.
    assert r.get_json()["wrote_back"] is False
    fake = factory.clients[0]._fake
    assert fake.store_calls == []
    assert fake.seen_uids == set()


def test_writeback_missing_message_id_header_skips(connection_factory, db_path):
    """A message with no RFC822 Message-ID header can't be targeted — skip, no IMAP."""
    _seed(db_path, triage="new", raw_headers={"Subject": "no message-id here"})
    _enable_writeback(db_path)
    factory = RecordingClientFactory()
    client = _app(db_path, factory)

    # Opt-in GIVEN, so the absent Message-ID is what stops this, not D63's gate.
    r = client.post(f"/messages/{ACCOUNT}:5/triage",
                    json={"state": "done", "write_back": True})
    assert r.get_json()["wrote_back"] is False
    # No Message-ID → we don't even open a connection.
    assert factory.constructed is False


def test_writeback_failure_is_nonfatal(connection_factory, db_path):
    """An IMAP error during write-back must not fail the triage (best-effort)."""
    _seed(db_path, triage="new")
    _enable_writeback(db_path)

    def exploding_factory(account):
        from ingestion.imap_client import GmailImapClient, ImapError

        class Boom:
            def login(self, *a): raise ImapError("boom")
            def logout(self): return ("BYE", [b""])
        return GmailImapClient(account=account, connection_factory=Boom)

    client = _app(db_path, exploding_factory)
    # Opt-in GIVEN (D63) — otherwise write-back never runs and this would pass
    # for the wrong reason, testing the gate instead of the error handling.
    r = client.post(f"/messages/{ACCOUNT}:5/triage",
                    json={"state": "acknowledged", "write_back": True})
    # Triage still succeeds and persists; write-back just reports False.
    assert r.status_code == 200
    assert r.get_json()["triage_state"] == "acknowledged"
    assert r.get_json()["wrote_back"] is False
    assert client.get(f"/messages/{ACCOUNT}:5").get_json()["triage_state"] == "acknowledged"

# ── D63: the pref is necessary but NOT sufficient, and every attempt is logged ─
#
# The defect this closes: the account pref was set once, deliberately, at alpha
# open — and then governed every triage forever after. Fourteen sessions later a
# RESTORE (moving a message back after a test) silently marked a real Gmail
# message read. Nobody asked for that; the caller was undoing something. Bulk
# already required a per-request opt-in; this path never got revisited, so the
# most-used path was the least gated.


def test_d63_enabled_pref_alone_does_NOT_write_back(connection_factory, db_path):
    """THE fix. Pref on, no opt-in in the request → the mailbox is untouched and
    no IMAP client is even constructed."""
    _seed(db_path, triage="new")
    _enable_writeback(db_path)                    # the pref IS on
    factory = RecordingClientFactory()
    client = _app(db_path, factory)

    r = client.post(f"/messages/{ACCOUNT}:5/triage", json={"state": "acknowledged"})
    assert r.status_code == 200
    body = r.get_json()
    assert body["triage_state"] == "acknowledged", "the triage itself still happens"
    assert body["wrote_back"] is False
    assert body["write_back_skipped"] is True, "and the response SAYS the mailbox was left alone"
    assert factory.constructed is False, (
        "an IMAP client was built with no per-request opt-in — the standing pref "
        "is consent to a policy, not to each act")


def test_d63_both_gates_required_matrix(connection_factory, db_path):
    """Both gates, all four combinations. Only pref AND opt-in writes back."""
    cases = [
        (False, False, False),
        (False, True,  False),   # opt-in without the pref: still nothing (P5)
        (True,  False, False),   # the case that caused this fix
        (True,  True,  True),
    ]
    for pref_on, opt_in, expected in cases:
        _seed(db_path, triage="new")
        if pref_on:
            _enable_writeback(db_path)
        else:
            _enable_writeback(db_path, value="false")
        factory = RecordingClientFactory()
        client = _app(db_path, factory)
        payload = {"state": "acknowledged"}
        if opt_in:
            payload["write_back"] = True
        got = client.post(f"/messages/{ACCOUNT}:5/triage", json=payload).get_json()
        assert got["wrote_back"] is expected, (
            f"pref={pref_on} opt_in={opt_in} → expected {expected}")


def test_d63_a_successful_write_back_is_RECORDED(connection_factory, db_path):
    """Before this, the blast radius of the app's only outward side effect was
    unbounded and unknowable: `wrote_back` went to the client and was discarded."""
    _seed(db_path, triage="new")
    _enable_writeback(db_path)
    client = _app(db_path, RecordingClientFactory())

    assert client.post(f"/messages/{ACCOUNT}:5/triage",
                       json={"state": "done", "write_back": True}
                       ).get_json()["wrote_back"] is True

    entries = client.get("/writeback-log").get_json()
    assert len(entries) == 1
    e = entries[0]
    assert e["ok"] is True
    assert e["message_id"] == f"{ACCOUNT}:5"
    assert e["account"] == ACCOUNT
    assert e["action"] == "mark_read"
    assert e["triage_state"] == "done"
    assert e["rfc822_id"], "records WHAT was targeted (D46), not just that it happened"
    assert e["attempted_at"]


def test_d63_a_FAILED_write_back_is_also_recorded(connection_factory, db_path):
    """A log of only successes would understate what was attempted against the
    real mailbox — which is the number that bounds a blast radius."""
    _seed(db_path, triage="new", raw_headers={"Message-ID": "<not-in-mailbox@test>"})
    _enable_writeback(db_path)
    client = _app(db_path, RecordingClientFactory())

    assert client.post(f"/messages/{ACCOUNT}:5/triage",
                       json={"state": "done", "write_back": True}
                       ).get_json()["wrote_back"] is False

    entries = client.get("/writeback-log").get_json()
    assert len(entries) == 1, "the ATTEMPT is recorded even though nothing was set"
    assert entries[0]["ok"] is False
    assert entries[0]["detail"], "and says why"


def test_d63_no_attempt_no_row(connection_factory, db_path):
    """The log records attempts on the mailbox, not triage events. A skipped
    write-back never reached the server, so there is nothing to record."""
    _seed(db_path, triage="new")
    _enable_writeback(db_path)
    client = _app(db_path, RecordingClientFactory())
    client.post(f"/messages/{ACCOUNT}:5/triage", json={"state": "done"})   # no opt-in
    assert client.get("/writeback-log").get_json() == []


def test_d63_log_can_be_scoped_to_one_message(connection_factory, db_path):
    """"Was THIS message ever written back?" — the query shape that bounds a
    blast radius after the fact."""
    _seed(db_path, triage="new")
    _enable_writeback(db_path)
    client = _app(db_path, RecordingClientFactory())
    client.post(f"/messages/{ACCOUNT}:5/triage",
                json={"state": "done", "write_back": True})

    hit = client.get(f"/writeback-log?message_id={ACCOUNT}:5").get_json()
    assert len(hit) == 1
    miss = client.get(f"/writeback-log?message_id={ACCOUNT}:999").get_json()
    assert miss == []
