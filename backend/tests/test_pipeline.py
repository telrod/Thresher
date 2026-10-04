"""
Integration tests for ingestion.pipeline — IMAP poll → queue → classify → SQLite.

Uses the seeded test database (via the connection_factory fixture) so the real
ClassificationEngine and seeded rules run end-to-end. IMAP is faked.
"""

import time
from unittest import mock

import pytest

from db.database import ClassificationRepo, MessageRepo
from ingestion import imap_client
from ingestion.imap_client import GmailImapClient
from ingestion.pipeline import IngestionPipeline, to_envelope
from db.database import Message
from tests.fakes import FakeIMAP, build_raw


@pytest.fixture(autouse=True)
def _mock_keychain():
    with mock.patch.object(imap_client, "get_gmail_app_password", return_value="pw"):
        yield


def _pipeline(connection_factory, fake):
    client_factory = lambda acct: GmailImapClient(acct, connection_factory=lambda: fake)
    return IngestionPipeline(
        account="you@example.com",
        connection_factory=connection_factory,
        client_factory=client_factory,
        poll_interval_seconds=0.01,
    )


def test_poll_once_enqueues_messages(connection_factory):
    fake = FakeIMAP({
        1: build_raw("a@b.com", "hello"),
        2: build_raw("boss@example.com", "boss msg"),
    })
    pipe = _pipeline(connection_factory, fake)
    n = pipe.poll_once(connection_factory())
    assert n == 2
    assert pipe.queue.qsize() == 2


def test_end_to_end_persists_and_classifies(connection_factory):
    """A leadership sender should be persisted and classified at Tier 1 (sender floor)."""
    fake = FakeIMAP({
        1: build_raw("boss@example.com", "Quarterly numbers"),
        2: build_raw("randomstranger@example.com", "Buy now!!!"),
    })
    pipe = _pipeline(connection_factory, fake)

    pipe.start()
    # Wait until both messages have been classified, then stop.
    _wait_for(lambda: pipe.stats.classified >= 2, pipe)
    pipe.stop()

    conn = connection_factory()
    msg_repo = MessageRepo(conn)
    cls_repo = ClassificationRepo(conn)

    boss = cls_repo.get("you@example.com:1")
    stranger = cls_repo.get("you@example.com:2")

    assert msg_repo.exists("you@example.com:1")
    assert boss["urgency_tier"] == 1          # leadership sender override
    assert boss["category"] == "work"         # @example.com → work
    assert stranger["urgency_tier"] == 4      # unknown sender default
    assert boss["triage_state"] == "new"
    # P3: rule_matches audit trail is stored.
    assert boss["rule_matches"] and boss["rule_matches"] != "[]"
    conn.close()


def test_message_stored_even_when_classification_fails(connection_factory):
    """P1: a classification exception must not lose the stored message."""
    fake = FakeIMAP({1: build_raw("a@b.com", "hi")})
    pipe = _pipeline(connection_factory, fake)

    # Build the pipeline's consumer with an engine that always throws.
    conn = connection_factory()
    msg_repo = MessageRepo(conn)
    cls_repo = ClassificationRepo(conn)
    boom = mock.Mock()
    boom.classify.side_effect = RuntimeError("engine kaboom")

    msg = Message(
        id="you@example.com:1", account="you@example.com",
        sender_email="a@b.com", received_at="2026-06-15T00:00:00+00:00",
        ingested_at="2026-06-15T00:00:00+00:00", subject="hi",
    )
    pipe._process(msg, msg_repo, cls_repo, boom)

    assert msg_repo.exists("you@example.com:1")    # message survived
    assert cls_repo.get("you@example.com:1") is None  # no classification row
    assert pipe.stats.persisted == 1
    assert pipe.stats.errors == 1
    conn.close()


def test_duplicate_messages_are_idempotent(connection_factory):
    """Re-processing the same message id must not duplicate (insert OR ignore)."""
    fake = FakeIMAP({1: build_raw("a@b.com", "dup")})
    pipe = _pipeline(connection_factory, fake)
    conn = connection_factory()
    msg_repo = MessageRepo(conn)
    cls_repo = ClassificationRepo(conn)
    engine = pipe._build_engine(conn)

    msg = Message(
        id="you@example.com:1", account="you@example.com",
        sender_email="a@b.com", received_at="2026-06-15T00:00:00+00:00",
        ingested_at="2026-06-15T00:00:00+00:00", subject="dup",
    )
    pipe._process(msg, msg_repo, cls_repo, engine)
    pipe._process(msg, msg_repo, cls_repo, engine)

    count = conn.execute(
        "SELECT COUNT(*) FROM messages WHERE id = ?", ("you@example.com:1",)
    ).fetchone()[0]
    assert count == 1
    conn.close()


def test_consumer_only_drains_without_producer(connection_factory):
    """start_consumer_only + a manual poll_once processes the queue with no
    interval producer running (single-shot mode used by `main.py --once`)."""
    fake = FakeIMAP({1: build_raw("a@b.com", "single")})
    pipe = _pipeline(connection_factory, fake)
    pipe.start_consumer_only()
    assert pipe._producer_thread is None  # no polling producer started
    n = pipe.poll_once(connection_factory())
    pipe.queue.join()
    pipe.stop()
    assert n == 1
    assert pipe.stats.classified == 1


def test_producer_self_terminates_on_keychain_error(connection_factory):
    """A permanent credential error stops the pipeline and records fatal_error
    rather than leaving a dead producer / hung process."""
    from ingestion.keychain import KeychainError

    def boom_factory(_acct):
        raise KeychainError("no app password stored")

    pipe = IngestionPipeline(
        account="you@example.com",
        connection_factory=connection_factory,
        client_factory=boom_factory,
        poll_interval_seconds=0.01,
    )
    pipe.start()
    # The producer should set the stop event on its own; wait briefly for it.
    assert pipe.wait_until_stopped(timeout=2.0) is True
    pipe.stop()
    assert isinstance(pipe.fatal_error, KeychainError)


def test_on_classified_hook_fires(connection_factory):
    """The post-classification hook runs once per classified message.

    D62 note: the hook is deliberately silent during an INITIAL backfill
    (OI26), and a poll against an empty store IS a backfill — so this test
    seeds a stored message first to establish the account, putting the poll on
    the ordinary path where the hook is expected to fire. The suppression
    itself is covered by the two `d62_` tests below.
    """
    # Establish the account. The cursor seeds from max_uid_for_account, which
    # parses the NUMERIC suffix of `{account}:{uid}` — so the seed needs a real
    # uid, and one BELOW the message being fetched or the poll would skip it.
    _conn = connection_factory()
    MessageRepo(_conn).insert(Message(
        id="you@example.com:1", account="you@example.com",
        sender_email="seed@b.com", received_at="2026-01-01T00:00:00+00:00",
        ingested_at="2026-01-01T00:00:00+00:00"))
    fake = FakeIMAP({2: build_raw("a@b.com", "hook me")})
    seen = []
    client_factory = lambda acct: GmailImapClient(acct, connection_factory=lambda: fake)
    pipe = IngestionPipeline(
        account="you@example.com",
        connection_factory=connection_factory,
        client_factory=client_factory,
        poll_interval_seconds=0.01,
        on_classified=lambda conn, mid, result: seen.append((mid, result.urgency_tier)),
    )
    pipe.start_consumer_only()
    pipe.poll_once(connection_factory())
    pipe.queue.join()
    pipe.stop()
    assert seen == [("you@example.com:2", 4)]  # unknown sender → tier 4


def test_on_classified_hook_failure_does_not_break_ingestion(connection_factory):
    """A throwing hook must not stop the message from being stored/classified."""
    fake = FakeIMAP({1: build_raw("a@b.com", "boom")})
    client_factory = lambda acct: GmailImapClient(acct, connection_factory=lambda: fake)
    def boom(conn, mid, result):
        raise RuntimeError("notification kaboom")
    pipe = IngestionPipeline(
        account="you@example.com",
        connection_factory=connection_factory,
        client_factory=client_factory,
        poll_interval_seconds=0.01,
        on_classified=boom,
    )
    pipe.start_consumer_only()
    pipe.poll_once(connection_factory())
    pipe.queue.join()
    pipe.stop()
    assert pipe.stats.classified == 1  # ingestion unaffected by hook failure


def test_to_envelope_maps_fields():
    msg = Message(
        id="x", account="a", sender_email="a@b.com", sender_name="Al",
        subject="s", body_plain="b", received_at="t", ingested_at="t",
    )
    env = to_envelope(msg)
    assert env.id == "x"
    assert env.sender_email == "a@b.com"
    assert env.sender_name == "Al"
    assert env.subject == "s"
    assert env.body_plain == "b"


def test_reload_per_poll_applies_rule_edits_to_next_batch(connection_factory):
    """E11/D37 regression: a rule/sender-group edit made via the DB takes effect
    on the *next* poll's batch (the consumer rebuilds the engine when a poll
    arrives). Guards against E11 silently returning — i.e. the engine being built
    once and never refreshed, so API edits would require a restart."""
    from db.database import RulesRepo

    # First batch: an unknown sender → default Tier 4.
    fake1 = FakeIMAP({1: build_raw("vendor@acme.com", "first")})
    client_factory = lambda acct: GmailImapClient(acct, connection_factory=lambda: fake1)
    pipe = IngestionPipeline(
        account="you@example.com",
        connection_factory=connection_factory,
        client_factory=client_factory,
        poll_interval_seconds=0.01,
    )
    pipe.start_consumer_only()
    pipe.poll_once(connection_factory())
    pipe.queue.join()

    conn = connection_factory()
    cls_repo = ClassificationRepo(conn)
    assert cls_repo.get("you@example.com:1")["urgency_tier"] == 4  # default

    # Now add a sender group via the DB that floors acme.com senders to Tier 1.
    RulesRepo(conn).create_sender_group({
        "group_name": "vip_vendor", "email_pattern": "*@acme.com",
        "urgency_floor": 1, "notes": None,
    })
    conn.close()

    # Second batch: a NEW message from the same domain. The next poll must rebuild
    # the engine and apply the freshly-added group → Tier 1.
    fake1._messages[2] = build_raw("vendor@acme.com", "second")
    pipe.poll_once(connection_factory())
    pipe.queue.join()
    pipe.stop()

    conn = connection_factory()
    assert ClassificationRepo(conn).get("you@example.com:2")["urgency_tier"] == 1
    # And the original message keeps its old classification — edits apply to new
    # mail next poll, not retroactively (the documented E11/D37 behavior).
    assert ClassificationRepo(conn).get("you@example.com:1")["urgency_tier"] == 4
    conn.close()


# ── cursor seeding from the store (gate-defects Part C) ──────────────────────

def _stored(account, uid, subject="s"):
    return Message(
        id=f"{account}:{uid}", account=account, sender_email="a@b.com",
        received_at="2026-06-15T00:00:00+00:00",
        ingested_at="2026-06-15T00:00:00+00:00", subject=subject,
    )


def test_max_uid_for_account_empty_db(connection_factory):
    conn = connection_factory()
    assert MessageRepo(conn).max_uid_for_account("you@example.com") == 0
    conn.close()


def test_max_uid_for_account_scoped_to_the_right_account(connection_factory):
    conn = connection_factory()
    repo = MessageRepo(conn)
    repo.insert(_stored("you@example.com", 7))
    repo.insert(_stored("you@example.com", 41))
    repo.insert(_stored("other@example.com", 99))  # must not bleed across accounts
    assert repo.max_uid_for_account("you@example.com") == 41
    assert repo.max_uid_for_account("other@example.com") == 99
    assert repo.max_uid_for_account("absent@gmail.com") == 0
    conn.close()


def test_poll_cursor_seeded_from_store_skips_already_ingested(connection_factory):
    """A fresh pipeline over a populated store must resume above the max
    ingested UID — not re-download the whole mailbox above UID 0 (Part C:
    both Session-23 --once runs re-fetched all 1,386 messages)."""
    conn = connection_factory()
    repo = MessageRepo(conn)
    repo.insert(_stored("you@example.com", 1))
    repo.insert(_stored("you@example.com", 2))
    conn.close()

    fake = FakeIMAP({
        1: build_raw("a@b.com", "already stored one"),
        2: build_raw("a@b.com", "already stored two"),
        3: build_raw("a@b.com", "genuinely new"),
    })
    pipe = _pipeline(connection_factory, fake)
    n = pipe.poll_once(connection_factory())
    assert pipe.cursor.last_uid == 3
    assert n == 1                      # only uid 3 was fetched/enqueued
    assert pipe.queue.get_nowait()[0].subject == "genuinely new"


# ── helpers ──────────────────────────────────────────────────────────────────

def _wait_for(predicate, pipe, timeout=5.0):
    """Spin until predicate() is true or timeout; fail loudly otherwise."""
    import time
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    pipe.stop(drain=False)
    raise AssertionError(f"condition not met within {timeout}s (stats={pipe.stats})")


# ── OI15: UIDVALIDITY persisted per (account, mailbox) ────────────────────────


def test_first_poll_records_uidvalidity_no_rescan_OI15(connection_factory, caplog):
    """Absent stored epoch (first run post-upgrade): record the live epoch with
    an INFO line; no reset, no rescan."""
    import logging
    from db.database import PreferencesRepo

    fake = FakeIMAP({1: build_raw("a@b.com", "hello")}, uidvalidity=1000)
    pipe = _pipeline(connection_factory, fake)
    with caplog.at_level(logging.INFO):
        assert pipe.poll_once(connection_factory()) == 1

    conn = connection_factory()
    stored = PreferencesRepo(conn).get("uidvalidity:you@example.com:INBOX")
    conn.close()
    assert stored == "1000"
    assert any("Recorded UIDVALIDITY 1000" in r.message and r.levelno == logging.INFO
               for r in caplog.records)
    assert not any(r.levelno >= logging.ERROR for r in caplog.records)


def test_stable_epoch_across_runs_no_rescan_OI15(connection_factory, caplog):
    """Stored epoch matches live: the seeded max-UID cursor stands — the second
    process's poll searches ABOVE it (no full re-scan) and stays quiet."""
    import logging

    fake = FakeIMAP({1: build_raw("a@b.com", "one"),
                     2: build_raw("b@b.com", "two")}, uidvalidity=1000)
    first = _pipeline(connection_factory, fake)
    first.start()
    _wait_for(lambda: first.stats.classified >= 2, first)
    first.stop()

    # Fresh pipeline = fresh process (in-memory cursor gone, store + pref remain).
    fake2 = FakeIMAP({1: build_raw("a@b.com", "one"),
                      2: build_raw("b@b.com", "two"),
                      3: build_raw("c@b.com", "three")}, uidvalidity=1000)
    second = _pipeline(connection_factory, fake2)
    with caplog.at_level(logging.INFO):
        enqueued = second.poll_once(connection_factory())

    assert enqueued == 1, "stable epoch: only the genuinely new UID is fetched"
    assert second.cursor.last_uid == 3
    assert not any("UIDVALIDITY changed" in r.message for r in caplog.records)


def test_epoch_roll_across_runs_resets_and_rescans_OI15(connection_factory, caplog):
    """THE OI15 case: the epoch rolls BETWEEN process runs. The persisted epoch
    arms the fresh cursor, so the mismatch is detected on the first poll —
    loud ERROR naming both epochs, cursor reset to 0, full re-scan (dedup
    absorbs the re-download), and the new epoch is stored."""
    import logging
    from db.database import PreferencesRepo

    fake = FakeIMAP({5: build_raw("a@b.com", "old-epoch mail")}, uidvalidity=1000)
    first = _pipeline(connection_factory, fake)
    first.start()
    _wait_for(lambda: first.stats.classified >= 1, first)
    first.stop()

    # New process, ROLLED epoch: same mailbox re-numbered from UID 1. Without
    # the persisted epoch, the max-UID cursor (5) would silently skip both.
    fake2 = FakeIMAP({1: build_raw("a@b.com", "old-epoch mail"),
                      2: build_raw("d@b.com", "new after roll")}, uidvalidity=2000)
    second = _pipeline(connection_factory, fake2)
    with caplog.at_level(logging.INFO):
        enqueued = second.poll_once(connection_factory())

    assert enqueued == 2, "roll: full re-scan from UID 0, nothing skipped"
    errors = [r for r in caplog.records
              if r.levelno == logging.ERROR and "UIDVALIDITY changed" in r.message]
    assert len(errors) == 1, "the roll must be an ERROR, loudly"
    assert "1000" in errors[0].getMessage() and "2000" in errors[0].getMessage(), \
        "the ERROR must name BOTH epochs"

    conn = connection_factory()
    assert PreferencesRepo(conn).get("uidvalidity:you@example.com:INBOX") == "2000"
    conn.close()


# ── D61: the retrieval window ────────────────────────────────────────────────
#
# The window bounds the INITIAL BACKFILL only. After an account is connected it
# stops filtering, and everything the server offers is retrieved regardless of
# age. These look like the same rule and are not; see the gap test below, which
# is the one that fails if someone later "corrects" the asymmetry.

from datetime import datetime, timedelta, timezone  # noqa: E402
from db.database import PreferencesRepo             # noqa: E402


def _rfc822(days_ago: float) -> str:
    """An RFC-2822 Date header N days in the past (what a mail server sends)."""
    dt = datetime.now(timezone.utc) - timedelta(days=days_ago)
    return dt.strftime("%a, %d %b %Y %H:%M:%S +0000")


def _set_cutoff(conn, account, days_ago: float) -> None:
    PreferencesRepo(conn).set(
        f"retrieval_cutoff:{account}",
        (datetime.now(timezone.utc) - timedelta(days=days_ago)).isoformat())


def test_d61_backfill_skips_mail_older_than_the_cutoff(connection_factory):
    conn = connection_factory()
    _set_cutoff(conn, "you@example.com", 7)
    fake = FakeIMAP({
        1: build_raw("old@b.com", "ancient", date=_rfc822(400)),
        2: build_raw("old@b.com", "stale", date=_rfc822(30)),
        3: build_raw("new@b.com", "recent", date=_rfc822(2)),
    })
    pipe = _pipeline(connection_factory, fake)
    n = pipe.poll_once(conn)

    assert n == 1, "only the message inside the window is enqueued"
    subjects = []
    while not pipe.queue.empty():
        # Queue items are (Message, is_backfill) since OI30.
        subjects.append(pipe.queue.get()[0].subject)
    assert subjects == ["recent"]


def test_d61_backfill_retrieves_mail_newer_than_the_cutoff(connection_factory):
    conn = connection_factory()
    _set_cutoff(conn, "you@example.com", 30)
    fake = FakeIMAP({
        1: build_raw("a@b.com", "just inside", date=_rfc822(29)),
        2: build_raw("a@b.com", "today", date=_rfc822(0.1)),
    })
    pipe = _pipeline(connection_factory, fake)
    assert pipe.poll_once(conn) == 2


def test_d61_NO_cutoff_stored_retrieves_everything(connection_factory):
    """The safe default. An account connected before this feature existed must
    not suddenly start skipping mail."""
    conn = connection_factory()
    fake = FakeIMAP({
        1: build_raw("a@b.com", "ancient", date=_rfc822(2000)),
        2: build_raw("a@b.com", "today", date=_rfc822(0.1)),
    })
    pipe = _pipeline(connection_factory, fake)
    assert pipe.poll_once(conn) == 2


def test_d61_THE_GAP_CASE_mail_from_a_lapse_IS_retrieved(connection_factory):
    """**The test that fails if someone "fixes" the asymmetry.**

    Someone sets a one-week window, closes the app for two weeks, reopens it.
    ALL of that mail is retrieved — it is not skipped for being older than a
    week.

    Why this must hold: the window solves "don't drag in years of dead mail at
    setup". A gap since the last poll is a different situation — recent, small,
    possibly still actionable. Filtering it would mean closing the app for a
    week could permanently hide an urgent message, which is the exact failure
    this app exists to prevent. And because the window cannot be widened, that
    mail would be unrecoverable.
    """
    conn = connection_factory()
    account = "you@example.com"
    _set_cutoff(conn, account, 7)          # a ONE-WEEK window

    # Backfill: one message inside the window establishes the account as
    # connected (a non-zero cursor), which is what ends backfill mode.
    fake = FakeIMAP({1: build_raw("a@b.com", "at setup", date=_rfc822(1))})
    pipe = _pipeline(connection_factory, fake)
    assert pipe.poll_once(conn) == 1
    while not pipe.queue.empty():          # drain; the consumer isn't running
        m, _is_backfill = pipe.queue.get()
        MessageRepo(conn).insert(m)        # store it, so the cursor can seed

    # …two weeks pass with the app closed. A fresh process = a fresh pipeline,
    # cursor seeded from the store rather than carried in memory.
    gap = _pipeline(connection_factory, FakeIMAP({
        1: build_raw("a@b.com", "at setup", date=_rfc822(1)),
        2: build_raw("a@b.com", "during the gap", date=_rfc822(12)),
        3: build_raw("a@b.com", "also the gap", date=_rfc822(9)),
    }))
    n = gap.poll_once(conn)

    got = []
    while not gap.queue.empty():
        got.append(gap.queue.get()[0].subject)
    assert sorted(got) == ["also the gap", "during the gap"], (
        "mail from the lapse was skipped for being older than the window — the "
        "backfill-only asymmetry has been broken")
    assert n == 2


def test_d61_cutoff_is_stored_per_account_and_survives_a_restart(connection_factory):
    """Stored as an absolute date, not 'N days' — so the boundary cannot slide
    forward on every poll, and a new process reads the same line."""
    conn = connection_factory()
    _set_cutoff(conn, "you@example.com", 7)
    stored = PreferencesRepo(conn).get("retrieval_cutoff:you@example.com")

    # A different account is unaffected — the key is per-account.
    assert PreferencesRepo(conn).get("retrieval_cutoff:other@x.com") is None

    # A "restart": a brand-new connection to the same store reads the same value.
    again = PreferencesRepo(connection_factory()).get(
        "retrieval_cutoff:you@example.com")
    assert again == stored
    datetime.fromisoformat(stored)     # a real absolute timestamp, not "7d"


def test_d61_unparseable_cutoff_retrieves_everything(connection_factory):
    """Degrade toward keeping mail (P1), never toward dropping it silently."""
    conn = connection_factory()
    PreferencesRepo(conn).set("retrieval_cutoff:you@example.com", "not-a-date")
    fake = FakeIMAP({1: build_raw("a@b.com", "ancient", date=_rfc822(999))})
    pipe = _pipeline(connection_factory, fake)
    assert pipe.poll_once(conn) == 1


def test_d61_backfill_emits_no_per_message_notifications(connection_factory):
    """C5: retrieving the window must not fire a banner per message.

    NOTE — this asserts the ENQUEUE path is silent, which it is: notification
    dispatch happens in the consumer, not the fetch. **It does not close OI26**
    (the backfill notification burst), which is flagged and deliberately out of
    scope for this work order. See §8.
    """
    conn = connection_factory()
    _set_cutoff(conn, "you@example.com", 30)
    fake = FakeIMAP({i: build_raw("a@b.com", f"m{i}", date=_rfc822(1))
                     for i in range(1, 6)})
    pipe = _pipeline(connection_factory, fake)
    before = conn.execute("SELECT COUNT(*) FROM notification_log").fetchone()[0]
    assert pipe.poll_once(conn) == 5
    after = conn.execute("SELECT COUNT(*) FROM notification_log").fetchone()[0]
    assert after == before, "the fetch path itself must not notify"


# ── D62 / OI26: backfill is silent, live polling is not ──────────────────────

def _notify_recorder():
    """A stand-in for the notification hook that records what it was asked to
    fire for. Counting CALLS is the right assertion — asserting on
    notification_log would pass even if the hook fired and the service happened
    to defer."""
    fired = []
    def hook(conn, message_id, result):
        fired.append(message_id)
    return fired, hook


def _pipeline_with_hook(connection_factory, fake, hook):
    client_factory = lambda acct: GmailImapClient(acct, connection_factory=lambda: fake)
    return IngestionPipeline(
        account="you@example.com",
        connection_factory=connection_factory,
        client_factory=client_factory,
        poll_interval_seconds=0.01,
        on_classified=hook,
    )


def test_d62_backfill_fires_NO_notifications_at_any_tier(connection_factory):
    """OI26. Connecting an account found 3,311 messages and fired 214 banners in
    one burst (Session 30). Setup must not end in a flood."""
    conn = connection_factory()
    fired, hook = _notify_recorder()
    # A boss address the seeded rules classify as Tier 1/2 — so this asserts
    # silence for the tiers that WOULD have notified, not merely for T4 noise.
    fake = FakeIMAP({
        1: build_raw("boss@example.com", "urgent one", date=_rfc822(1)),
        2: build_raw("boss@example.com", "urgent two", date=_rfc822(2)),
        3: build_raw("random@newsletter.com", "noise", date=_rfc822(1)),
    })
    pipe = _pipeline_with_hook(connection_factory, fake, hook)
    pipe.start_consumer_only()
    try:
        assert pipe.poll_once(conn) == 3
        deadline = time.time() + 5
        while pipe.stats.classified < 3 and time.time() < deadline:
            time.sleep(0.02)
    finally:
        pipe.stop(drain=True, timeout=5)

    assert pipe.stats.classified == 3, "precondition: all three were classified"
    assert fired == [], (
        f"backfill fired {len(fired)} notification(s) — setup would end in a "
        f"burst of banners")
    assert pipe.stats.backfill_silenced == 3


def test_d62_backfill_stays_silent_when_the_consumer_OUTRUNS_the_producer(connection_factory):
    """OI30 — the race the shared `_in_backfill` flag could not close.

    The flag was set by the PRODUCER and cleared by the CONSUMER on
    `self.queue.empty()`. But "the queue is empty right now" does not mean "the
    batch is over" — it means the consumer has caught up. If the consumer drains
    faster than the producer enqueues (a slow mailbox, a fast classifier, or any
    added latency at the seam), the queue reads empty MID-BATCH, the flag clears,
    and every remaining message notifies. That is exactly the burst D62 exists to
    prevent, and it made the sibling test a latency-sensitive flake.

    This forces the interleaving instead of hoping for it: the producer is slowed
    so the consumer is guaranteed to empty the queue between messages. Under the
    old shared-flag design the tail of the batch notifies; with the batch tag
    travelling per-message, silence is a property of the message rather than of
    when it happened to be processed.
    """
    conn = connection_factory()
    fired, hook = _notify_recorder()
    fake = FakeIMAP({
        i: build_raw("boss@example.com", f"urgent {i}", date=_rfc822(i))
        for i in range(1, 7)
    })
    pipe = _pipeline_with_hook(connection_factory, fake, hook)

    # Slow the ENQUEUE so the consumer drains to empty between messages — the
    # precise condition the empty-queue check misread as "batch finished".
    real_put = pipe.queue.put
    def _slow_put(item, *a, **kw):
        real_put(item, *a, **kw)
        time.sleep(0.05)
    pipe.queue.put = _slow_put

    pipe.start_consumer_only()
    try:
        assert pipe.poll_once(conn) == 6
        deadline = time.time() + 10
        while pipe.stats.classified < 6 and time.time() < deadline:
            time.sleep(0.02)
    finally:
        pipe.queue.put = real_put
        pipe.stop(drain=True, timeout=5)

    assert pipe.stats.classified == 6, "precondition: all six were classified"
    assert fired == [], (
        f"backfill fired {len(fired)} notification(s) — the consumer outran the "
        f"producer and the tail of the batch notified (OI30)")
    assert pipe.stats.backfill_silenced == 6


def test_d62_a_normal_poll_STILL_notifies(connection_factory):
    """The other half, and the one that matters for the Tier 1 invariant: this
    is scoped suppression, not a general silencing. A Tier 1 message arriving on
    an ordinary poll must still fire."""
    conn = connection_factory()
    fired, hook = _notify_recorder()

    # Backfill first, so the account is established (non-zero cursor).
    fake = FakeIMAP({1: build_raw("a@b.com", "at setup", date=_rfc822(1))})
    pipe = _pipeline_with_hook(connection_factory, fake, hook)
    pipe.start_consumer_only()
    try:
        assert pipe.poll_once(conn) == 1
        deadline = time.time() + 5
        while pipe.stats.classified < 1 and time.time() < deadline:
            time.sleep(0.02)
        assert fired == [], "the backfill message itself is silent"

        # Now a NEW message arrives on an ordinary poll.
        fake._messages[2] = build_raw("boss@example.com",
                                      "live urgent", date=_rfc822(0))
        assert pipe.poll_once(conn) == 1
        deadline = time.time() + 5
        while pipe.stats.classified < 2 and time.time() < deadline:
            time.sleep(0.02)
    finally:
        pipe.stop(drain=True, timeout=5)

    assert len(fired) == 1, (
        "a message arriving on a normal poll must still notify — suppression is "
        "scoped to the backfill batch, not to the app")
    assert fired[0].endswith(":2")


# ── Session 34: poll heartbeat + transient-timeout survival ──────────────────

def _heartbeat(connection_factory, account="you@example.com"):
    from db.database import PreferencesRepo
    from ingestion.pipeline import poll_heartbeat_key
    return PreferencesRepo(connection_factory()).get(poll_heartbeat_key(account))


def test_successful_poll_records_ok_heartbeat(connection_factory):
    fake = FakeIMAP({1: build_raw("a@b.com", "hello")})
    p = _pipeline(connection_factory, fake)
    p.poll_once(connection_factory())
    raw = _heartbeat(connection_factory)
    assert raw is not None and raw.split("|")[1] == "ok"


def test_producer_crash_records_stopped_heartbeat(connection_factory):
    """A dying producer must leave a marker. Without one, a dead account is
    indistinguishable from a quiet one — the 17-hour alpha blind spot."""
    fake = FakeIMAP({1: build_raw("a@b.com", "hello")})
    p = _pipeline(connection_factory, fake)
    with mock.patch.object(p, "poll_once", side_effect=RuntimeError("boom")):
        p._run_producer()
    raw = _heartbeat(connection_factory)
    assert raw is not None
    _, status, detail = raw.split("|", 2)
    assert status == "stopped"
    assert "RuntimeError" in detail and "boom" in detail


def test_poll_survives_transient_select_timeout(connection_factory):
    """End-to-end guard for the Aug-13 outage: a timeout on the poll's opening
    SELECT must be retried inside the client, not kill the producer."""
    class FlakySelect(FakeIMAP):
        def __init__(self, messages, **kw):
            super().__init__(messages, **kw)
            self._fail = 1
        def select(self, mailbox, readonly=False):
            if self._fail > 0:
                self._fail -= 1
                raise TimeoutError("The read operation timed out")
            return super().select(mailbox, readonly=readonly)

    fake = FlakySelect({1: build_raw("a@b.com", "survives")})
    p = _pipeline(connection_factory, fake)
    assert p.poll_once(connection_factory()) == 1
    assert p.fatal_error is None
    assert _heartbeat(connection_factory).split("|")[1] == "ok"


def test_oi26_a_GENUINE_COLD_START_is_silent_at_scale(connection_factory):
    """OI26, the cutover rehearsal: connect a mailbox with a real backlog and
    assert the user is not buried.

    WHY THIS EXISTS BESIDE THE TWO D62 TESTS ABOVE. Those prove the mechanism
    with three messages. This proves the SCENARIO — a first connect against a
    full inbox, which is what actually happened (3,311 messages, 214 banners in
    one burst, Session 30) and what the author is about to do again on his real mail at
    the public-repo cutover. Three messages cannot show that nothing scales
    wrong: a per-message flag error, a batching seam, or a queue that empties
    mid-run all need volume and interleaving to appear.

    Scale is 120 messages, most of them Tier 1/2 — deliberately the tiers that
    WOULD notify. A silent run of 120 T4 newsletters would prove nothing.

    VERIFIED RED (2026-09-02), by neutering the suppression at its one seam
    (`if is_backfill:` → `if False:` in `pipeline._classify_and_store`):
    **all 120 of 120 fired**. Re-running with the seam restored gives 0. So the
    silence is really being produced here, not merely observed — the failure
    mode where a test passes because nothing would have notified anyway is
    ruled out, and the count is the whole mailbox rather than a subset because
    the notification hook is called for every classified message and the tier
    decision happens downstream of it.
    """
    conn = connection_factory()
    fired, hook = _notify_recorder()

    urgent = "boss@example.com"   # seeded rules put this at Tier 1/2
    mailbox = {}
    for uid in range(1, 121):
        # 5 in 6 from the urgent sender, so the silent set is dominated by mail
        # that would otherwise fire.
        sender = urgent if uid % 6 else "random@newsletter.com"
        mailbox[uid] = build_raw(sender, f"backlog {uid}", date=_rfc822(uid % 90))

    pipe = _pipeline_with_hook(connection_factory, FakeIMAP(mailbox), hook)
    # A cold start IS an empty cursor (`last_uid == 0`) — the same condition D61
    # uses to pick the retrieval window, so the two cannot disagree about which
    # batch is the first. Asserted rather than assumed: if a fixture ever seeds
    # a cursor, this stops being a cold-start test and would still pass silently.
    assert pipe.cursor.last_uid == 0, \
        "precondition: this must be a COLD start, not a resumed poll"
    pipe.start_consumer_only()
    try:
        assert pipe.poll_once(conn) == 120
        deadline = time.time() + 30
        while pipe.stats.classified < 120 and time.time() < deadline:
            time.sleep(0.02)
    finally:
        pipe.stop(drain=True, timeout=10)

    assert pipe.stats.classified == 120, (
        f"precondition: all 120 must be classified, got {pipe.stats.classified} "
        f"— a short run would make the silence assertion meaningless")
    assert fired == [], (
        f"a cold start fired {len(fired)} notification(s) of 120. This is the "
        f"OI26 burst: connecting a mailbox trains the user to dismiss banners "
        f"before they have used the app once.")
    assert pipe.stats.backfill_silenced == 120, (
        f"only {pipe.stats.backfill_silenced} of 120 were tagged as backfill — "
        f"silence must come from the batch tag, not from nothing having matched")

    # P1: silent is not the same as dropped. Every message must still be stored
    # and classified — the whole point is that the mail arrives without shouting.
    stored = conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
    assert stored == 120, f"backfill stored only {stored} of 120 messages"
    classified = conn.execute("SELECT COUNT(*) FROM classifications").fetchone()[0]
    assert classified == 120, f"only {classified} of 120 got a classification row"

    # And the silenced set really did contain mail that would have notified,
    # or this test would pass against a mailbox of pure noise.
    urgent_count = conn.execute(
        "SELECT COUNT(*) FROM classifications WHERE urgency_tier <= 2").fetchone()[0]
    assert urgent_count >= 90, (
        f"only {urgent_count} messages landed at Tier 1/2 — this test is not "
        f"exercising the notifying tiers and its silence proves little")


# ── Part B: the poll interval must be re-read, and health must agree ──────────
#
# Observed live 2026-09-06 with the interval set to 1 minute in Settings:
#     06:27:26 INFO ingestion.pipeline: Producer polling every 300s
#     06:27:27 … 06:32:28 … 06:37:29 … 06:42:29 … 06:47:30 … 06:52:34 … 06:57:36
# The producer polled reliably every 300s and was idle (not hung) between polls.
# Nothing was broken; the setting never reached the running producer.


def test_producer_rereads_the_interval_on_each_pass(connection_factory):
    """B1: a running producer must pick up a changed interval on its next pass.

    `_resolve_poll_interval` was called ONCE before the while loop, so changing
    the setting did nothing until a restart while the UI said "Takes effect at
    the next check". The OI25 shape (a value read once at startup) in the
    cadence layer — same reload-per-poll precedent as E11/D37 for rules.

    VERIFIED RED against the pre-fix producer:
        assert [300.0, 60.0] == [300.0, 300.0]  — the second wait still used the
        startup value, i.e. the changed setting never reached the loop.
    """
    from db.database import PreferencesRepo
    prefs = PreferencesRepo(connection_factory())
    prefs.set("poll_interval_minutes", "5")

    fake = FakeIMAP({})
    client_factory = lambda acct: GmailImapClient(acct, connection_factory=lambda: fake)
    p = IngestionPipeline(
        account="you@example.com",
        connection_factory=connection_factory,
        client_factory=client_factory,
    )   # NO override — we want the DB-configured interval

    waits = []
    real_wait = p._stop.wait

    def record_wait(timeout=None):
        waits.append(timeout)
        if len(waits) == 1:
            # Between pass 1 and pass 2, the user changes the setting.
            prefs.set("poll_interval_minutes", "1")
            return False          # keep looping
        p._stop.set()             # end the loop on the second pass
        return True

    with mock.patch.object(p._stop, "wait", side_effect=record_wait):
        p._run_producer()

    assert waits == [300.0, 60.0], (
        f"producer did not re-read the interval between passes: {waits}")


def test_interval_change_is_logged_not_only_at_startup(connection_factory, caplog):
    """B3: `Producer polling every 300s` is what made this diagnosable, and it
    appeared once per process lifetime. A change must say so.

    VERIFIED RED against the pre-fix producer: only the startup line was
    emitted, so `[r for r in caplog … if "now polling" in r]` was empty."""
    import logging
    from db.database import PreferencesRepo
    prefs = PreferencesRepo(connection_factory())
    prefs.set("poll_interval_minutes", "5")

    fake = FakeIMAP({})
    client_factory = lambda acct: GmailImapClient(acct, connection_factory=lambda: fake)
    p = IngestionPipeline(
        account="you@example.com",
        connection_factory=connection_factory,
        client_factory=client_factory,
    )

    calls = {"n": 0}

    def record_wait(timeout=None):
        calls["n"] += 1
        if calls["n"] == 1:
            prefs.set("poll_interval_minutes", "1")
            return False
        p._stop.set()
        return True

    with caplog.at_level(logging.INFO, logger="ingestion.pipeline"):
        with mock.patch.object(p._stop, "wait", side_effect=record_wait):
            p._run_producer()

    changed = [r.getMessage() for r in caplog.records if "now polling every" in r.getMessage()]
    assert changed, "an interval change was not logged"
    assert "60s" in changed[0] and "300s" in changed[0]


def test_heartbeat_publishes_the_interval_actually_in_use(connection_factory):
    """B2 (producer half): the heartbeat carries the EFFECTIVE interval.

    The health check derived its expectation from the stored preference while
    the producer used its startup value, so every interval change produced a
    permanent false 'stale' until restart — degrading the one surface that can
    catch a process that is alive and not working. If the two can disagree they
    will drift again, so the producer publishes what it is actually using.

    VERIFIED RED against the pre-fix heartbeat: the stamp had 3 fields, so
    `len(parts) >= 4` failed — there was nothing for the checker to read."""
    from db.database import PreferencesRepo
    PreferencesRepo(connection_factory()).set("poll_interval_minutes", "5")

    fake = FakeIMAP({1: build_raw("a@b.com", "hello")})
    client_factory = lambda acct: GmailImapClient(acct, connection_factory=lambda: fake)
    p = IngestionPipeline(
        account="you@example.com",
        connection_factory=connection_factory,
        client_factory=client_factory,
    )
    p.poll_once(connection_factory())

    raw = _heartbeat(connection_factory)
    parts = raw.split("|")
    assert len(parts) >= 4, f"heartbeat does not publish the interval: {raw!r}"
    assert float(parts[3]) == 300.0


def test_widening_the_interval_does_not_leave_a_stale_looking_heartbeat(connection_factory):
    """B5, the 1 min -> 15 min direction.

    The heartbeat a poll writes must carry the interval the producer is about to
    SLEEP ON, not the one it woke up with. Otherwise widening the interval stamps
    '60' and then sleeps 900s, and the health check spends 14 of those 15 minutes
    reporting a false 'stale' — the same defect as B2, just in the other
    direction, and on the same surface whose whole value is being believed.

    VERIFIED RED by moving the re-read back after `poll_once` (the obvious
    ordering): the second beat carried 60.0 while the producer slept 900s.
    """
    from db.database import PreferencesRepo
    prefs = PreferencesRepo(connection_factory())
    prefs.set("poll_interval_minutes", "1")

    fake = FakeIMAP({})
    client_factory = lambda acct: GmailImapClient(acct, connection_factory=lambda: fake)
    p = IngestionPipeline(
        account="you@example.com",
        connection_factory=connection_factory,
        client_factory=client_factory,
    )

    waits, beats = [], []

    def record_wait(timeout=None):
        waits.append(timeout)
        beats.append(_heartbeat(connection_factory))
        if len(waits) == 1:
            prefs.set("poll_interval_minutes", "15")   # user widens it
            return False
        p._stop.set()
        return True

    with mock.patch.object(p._stop, "wait", side_effect=record_wait):
        p._run_producer()

    assert waits == [60.0, 900.0]
    # The beat written by the pass that is about to sleep 900s must say 900.
    assert float(beats[1].split("|")[3]) == 900.0, (
        f"heartbeat says {beats[1]!r} while the producer sleeps {waits[1]}s — "
        "health would call this account stale for the rest of the sleep")


# ── Immediate poll on connect (2026-09-07) ───────────────────────────────────

def test_the_poll_request_key_is_the_SAME_on_both_sides():
    """The API writes this key and the producer reads it. They are separate
    processes that share only the store, so the key IS the contract — and it is
    defined twice on purpose (the poller must not import the Flask app).

    VERIFIED RED by changing either literal: this fails naming both values.
    """
    from ingestion.pipeline import POLL_REQUESTED_KEY as producer_key
    from api.app import POLL_REQUESTED_KEY as api_key
    assert producer_key == api_key, (
        f"the API writes {api_key!r} but the producer reads {producer_key!r} — "
        "a connect would never trigger an immediate poll")


def test_a_poll_request_is_consumed_ONCE(connection_factory):
    """One-shot by design: the row is cleared on read.

    Leaving it set would make the producer spin — it would see the request on
    every pass and never wait, hammering IMAP for the life of the process.

    VERIFIED RED by removing the `prefs.set(POLL_REQUESTED_KEY, "")` clear:
    the second call returns True and the assertion below fails.
    """
    from db.database import PreferencesRepo
    from ingestion.pipeline import POLL_REQUESTED_KEY

    fake = FakeIMAP({})
    client_factory = lambda acct: GmailImapClient(acct, connection_factory=lambda: fake)
    p = IngestionPipeline(account="you@example.com",
                          connection_factory=connection_factory,
                          client_factory=client_factory)
    conn = connection_factory()
    PreferencesRepo(conn).set(POLL_REQUESTED_KEY, "2026-09-07T12:00:00+00:00")

    assert p._consume_poll_request(conn) is True, "the request was not seen"
    assert p._consume_poll_request(conn) is False, (
        "the request was not cleared — the producer would never wait again")


def test_no_poll_request_means_the_producer_waits_normally(connection_factory):
    """The over-correction guard: absent a request, nothing changes."""
    fake = FakeIMAP({})
    client_factory = lambda acct: GmailImapClient(acct, connection_factory=lambda: fake)
    p = IngestionPipeline(account="you@example.com",
                          connection_factory=connection_factory,
                          client_factory=client_factory)
    assert p._consume_poll_request(connection_factory()) is False
