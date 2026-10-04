"""
Tests for the Tier 3 daily digest: NotificationService.build_and_send_digest
and DigestScheduler.maybe_fire.
"""

from datetime import datetime, timedelta, timezone

import pytest

from db.database import (
    Classification, ClassificationRepo, Message, MessageRepo, PreferencesRepo,
)
from notifications.service import NotificationService
from notifications.scheduler import DigestScheduler


# Fixed "now" for deterministic windows. Mid-afternoon UTC.
NOW = datetime(2026, 6, 15, 14, 0, tzinfo=timezone.utc)


def _clock(dt=NOW):
    return lambda: dt


def _seed(conn, *, message_id, tier, received_at, sender="a@b.com", subject="hi",
          category="work"):
    MessageRepo(conn).insert(Message(
        id=message_id, account="acct", sender_email=sender, sender_name=None,
        subject=subject, received_at=received_at,
        ingested_at=received_at,
    ))
    ClassificationRepo(conn).upsert(Classification(
        message_id=message_id, urgency_tier=tier, category=category,
        triage_state="new", classified_at=received_at, rule_matches=[],
    ))


class RecordingSender:
    def __init__(self):
        self.sent = []

    def __call__(self, *, title, subtitle, text, sound=False):
        self.sent.append({"title": title, "subtitle": subtitle, "text": text, "sound": sound})


def _iso(dt):
    return dt.isoformat()


# ── builder: window + tier selection ────────────────────────────────────────

def test_digest_includes_only_tier3_in_window(conn):
    _seed(conn, message_id="in1", tier=3, received_at=_iso(NOW - timedelta(hours=2)))
    _seed(conn, message_id="in2", tier=3, received_at=_iso(NOW - timedelta(hours=20)))
    _seed(conn, message_id="old", tier=3, received_at=_iso(NOW - timedelta(hours=30)))  # too old
    _seed(conn, message_id="t1", tier=1, received_at=_iso(NOW - timedelta(hours=1)))    # wrong tier
    _seed(conn, message_id="t4", tier=4, received_at=_iso(NOW - timedelta(hours=1)))    # wrong tier

    sender = RecordingSender()
    svc = NotificationService(conn, sender=sender, clock=_clock())
    result = svc.build_and_send_digest()

    assert result.sent
    assert result.message_count == 2
    assert set(result.message_ids) == {"in1", "in2"}
    assert len(sender.sent) == 1
    assert "2 Tier 3 messages" in sender.sent[0]["title"]
    assert sender.sent[0]["sound"] is False  # digest is never a sound alert (P2)


def test_empty_digest_sends_nothing(conn):
    _seed(conn, message_id="t1", tier=1, received_at=_iso(NOW))  # no Tier 3 at all
    sender = RecordingSender()
    svc = NotificationService(conn, sender=sender, clock=_clock())
    result = svc.build_and_send_digest()
    assert not result.sent
    assert result.message_count == 0
    assert sender.sent == []
    # nothing logged, so a Tier 3 arriving later today can still be digested
    assert conn.execute(
        "SELECT COUNT(*) FROM notification_log WHERE notification_type='digest'"
    ).fetchone()[0] == 0


# ── builder: idempotency ─────────────────────────────────────────────────────

def test_digest_sent_once_per_day(conn):
    _seed(conn, message_id="d1", tier=3, received_at=_iso(NOW - timedelta(hours=1)))
    sender = RecordingSender()
    svc = NotificationService(conn, sender=sender, clock=_clock())

    first = svc.build_and_send_digest()
    second = svc.build_and_send_digest()
    assert first.sent
    assert not second.sent and "already sent today" in second.reason
    assert len(sender.sent) == 1


def test_force_overrides_once_per_day(conn):
    _seed(conn, message_id="d1", tier=3, received_at=_iso(NOW - timedelta(hours=1)))
    sender = RecordingSender()
    svc = NotificationService(conn, sender=sender, clock=_clock())
    svc.build_and_send_digest()
    forced = svc.build_and_send_digest(force=True)
    assert forced.sent
    assert len(sender.sent) == 2


def test_digest_logged_with_message_ids(conn):
    _seed(conn, message_id="d1", tier=3, received_at=_iso(NOW - timedelta(hours=1)))
    svc = NotificationService(conn, sender=RecordingSender(), clock=_clock())
    svc.build_and_send_digest()
    row = conn.execute(
        "SELECT message_id, notification_type, payload FROM notification_log "
        "WHERE notification_type='digest'"
    ).fetchone()
    assert row["message_id"] is None       # digest spans many messages
    assert '"d1"' in row["payload"]
    assert '"delivered": true' in row["payload"]


# ── builder: catch-up prominence ─────────────────────────────────────────────

def test_catchup_mode_lists_more_senders(conn):
    for i in range(6):
        _seed(conn, message_id=f"m{i}", tier=3,
              received_at=_iso(NOW - timedelta(hours=1, minutes=i)),
              sender=f"person{i}@x.com")

    PreferencesRepo(conn).set("operating_mode", "focus")
    focus = NotificationService(conn, sender=RecordingSender(), clock=_clock())
    focus_text = _capture_text(focus)

    # reset the day so the second send isn't deduped
    conn.execute("DELETE FROM notification_log")
    conn.commit()

    PreferencesRepo(conn).set("operating_mode", "catch-up")
    catchup = NotificationService(conn, sender=RecordingSender(), clock=_clock())
    catchup_text = _capture_text(catchup)

    # catch-up previews more senders inline (5 vs 3) → fewer "and N more"
    assert focus_text.count(",") < catchup_text.count(",")
    assert "Catch-up" in _last_subtitle(catchup, conn)


def _capture_text(svc):
    sender = RecordingSender()
    svc._send = sender
    svc.build_and_send_digest()
    return sender.sent[0]["text"]


def _last_subtitle(svc, conn):
    # re-run forced to capture subtitle deterministically
    sender = RecordingSender()
    svc._send = sender
    svc.build_and_send_digest(force=True)
    return sender.sent[-1]["subtitle"]


# ── scheduler ─────────────────────────────────────────────────────────────────

def test_scheduler_fires_at_or_after_digest_time(conn, db_path):
    from db.database import get_connection
    _seed(conn, message_id="s1", tier=3, received_at=_iso(NOW - timedelta(hours=1)))
    PreferencesRepo(conn).set("digest_time", "09:00")
    conn.close()

    sender = RecordingSender()
    sched = DigestScheduler(
        connection_factory=lambda: get_connection(db_path),
        service_factory=lambda c: NotificationService(c, sender=sender, clock=_clock()),
        clock=_clock(),  # 14:00 — after 09:00
    )
    fired = sched.maybe_fire(get_connection(db_path))
    assert fired
    assert len(sender.sent) == 1


def test_scheduler_does_not_fire_before_digest_time(conn, db_path):
    from db.database import get_connection
    _seed(conn, message_id="s1", tier=3, received_at=_iso(NOW - timedelta(hours=1)))
    PreferencesRepo(conn).set("digest_time", "09:00")
    conn.close()

    sender = RecordingSender()
    early = datetime(2026, 6, 15, 7, 0, tzinfo=timezone.utc)  # 07:00, before 09:00
    sched = DigestScheduler(
        connection_factory=lambda: get_connection(db_path),
        service_factory=lambda c: NotificationService(c, sender=sender, clock=_clock(early)),
        clock=_clock(early),
    )
    assert not sched.maybe_fire(get_connection(db_path))
    assert sender.sent == []


def test_scheduler_invalid_digest_time_skips(conn, db_path):
    from db.database import get_connection
    PreferencesRepo(conn).set("digest_time", "not-a-time")
    conn.close()
    sched = DigestScheduler(connection_factory=lambda: get_connection(db_path),
                            clock=_clock())
    assert not sched.maybe_fire(get_connection(db_path))