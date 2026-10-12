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

# ── OI44: the digest goes through the app when the app owns delivery ─────────
#
# The digest always went out through osascript, so it showed as Script Editor
# even while Thresher was running and owned delivery (observed
# 2026-10-11T00:05:55Z). Tier 1/2 alerts check the app's claim; the digest did
# not. It now hands off through the same notification_log row the app already
# collects from GET /notifications, and either path logs exactly one digest row,
# which is also what the once-per-day guard reads.

import json

from notifications.service import DELIVERY_APP, DELIVERY_HEARTBEAT_KEY, DELIVERY_OSASCRIPT

# The app's own heartbeat format: ISO8601DateFormatter in UTC, a trailing "Z"
# and no fractional seconds (APIClient.claimDelivery). 16 seconds before NOW.
APP_BEAT = "2026-06-15T13:59:44Z"


def _digest_payloads(conn):
    rows = conn.execute(
        "SELECT payload FROM notification_log WHERE notification_type = 'digest' ORDER BY id"
    ).fetchall()
    return [json.loads(r["payload"]) for r in rows]


def _feed(db_path, since=0):
    """What the app reads: GET /notifications."""
    from api.app import create_app
    from db.database import get_connection
    app = create_app(connection_factory=lambda: get_connection(db_path))
    return app.test_client().get(f"/notifications?since={since}").get_json()


def _feed_digests(feed):
    return [n for n in feed["notifications"] if n["notification_type"] == "digest"]


def test_digest_is_handed_to_the_app_when_it_owns_delivery(conn, db_path):
    PreferencesRepo(conn).set(DELIVERY_HEARTBEAT_KEY, APP_BEAT)
    _seed(conn, message_id="d1", tier=3, received_at=_iso(NOW - timedelta(hours=2)))

    sender = RecordingSender()
    result = NotificationService(conn, sender=sender, clock=_clock()).build_and_send_digest()

    assert result.sent
    assert sender.sent == [], "osascript fired while the app owned delivery"
    [payload] = _digest_payloads(conn)
    assert payload["delivery"] == DELIVERY_APP
    assert payload["delivered"] is False        # the backend did not deliver it
    [item] = _feed_digests(_feed(db_path))
    assert item["message_id"] is None
    assert item["title"] == "Daily digest · 1 Tier 3 message"


def test_digest_uses_osascript_when_the_app_does_not_own_delivery(conn, db_path):
    _seed(conn, message_id="d1", tier=3, received_at=_iso(NOW - timedelta(hours=2)))

    sender = RecordingSender()
    NotificationService(conn, sender=sender, clock=_clock()).build_and_send_digest()

    assert len(sender.sent) == 1
    [payload] = _digest_payloads(conn)
    assert payload["delivery"] == DELIVERY_OSASCRIPT
    assert _feed_digests(_feed(db_path)) == [], "the app would post it a second time"


def test_a_stale_app_heartbeat_falls_back_to_osascript(conn):
    """The app's format must not make a stale claim live: 22 minutes after the
    beat the app is presumed gone, and the digest still reaches the user."""
    PreferencesRepo(conn).set(DELIVERY_HEARTBEAT_KEY, APP_BEAT)
    _seed(conn, message_id="d1", tier=3, received_at=_iso(NOW - timedelta(hours=2)))

    sender = RecordingSender()
    later = NOW + timedelta(minutes=22)
    NotificationService(conn, sender=sender, clock=_clock(later)).build_and_send_digest()

    assert len(sender.sent) == 1
    assert _digest_payloads(conn)[0]["delivery"] == DELIVERY_OSASCRIPT


def test_no_duplicate_when_the_app_stops_owning_delivery_after_the_handoff(conn, db_path):
    """Handed to the app; the app's claim then lapses before the scheduler's next
    tick. That tick must not send the digest again through osascript, and the
    app's feed must return it exactly once."""
    PreferencesRepo(conn).set(DELIVERY_HEARTBEAT_KEY, APP_BEAT)
    _seed(conn, message_id="d1", tier=3, received_at=_iso(NOW - timedelta(hours=2)))
    sender = RecordingSender()
    NotificationService(conn, sender=sender, clock=_clock()).build_and_send_digest()

    later = NOW + timedelta(minutes=10)                     # the claim is stale now
    again = NotificationService(conn, sender=sender, clock=_clock(later)).build_and_send_digest()

    assert not again.sent
    assert sender.sent == []
    assert len(_digest_payloads(conn)) == 1
    first = _feed(db_path)
    assert len(_feed_digests(first)) == 1
    assert _feed_digests(_feed(db_path, since=first["cursor"])) == []


def test_no_duplicate_when_the_app_takes_over_after_osascript(conn, db_path):
    """The other direction: sent through osascript, then the app starts and
    claims delivery. The next tick must not hand the same digest to the app."""
    _seed(conn, message_id="d1", tier=3, received_at=_iso(NOW - timedelta(hours=2)))
    sender = RecordingSender()
    NotificationService(conn, sender=sender, clock=_clock()).build_and_send_digest()

    later = NOW + timedelta(minutes=10)
    PreferencesRepo(conn).set(DELIVERY_HEARTBEAT_KEY,
                              later.strftime("%Y-%m-%dT%H:%M:%SZ"))
    NotificationService(conn, sender=sender, clock=_clock(later)).build_and_send_digest()

    assert len(sender.sent) == 1
    assert len(_digest_payloads(conn)) == 1
    assert _feed_digests(_feed(db_path)) == []


def test_the_scheduler_hands_the_digest_to_the_app(conn, db_path):
    """The path that actually runs: the scheduler's tick, not a direct call."""
    from db.database import get_connection
    _seed(conn, message_id="s1", tier=3, received_at=_iso(NOW - timedelta(hours=1)))
    PreferencesRepo(conn).set("digest_time", "09:00")
    PreferencesRepo(conn).set(DELIVERY_HEARTBEAT_KEY, APP_BEAT)
    conn.close()

    sender = RecordingSender()
    sched = DigestScheduler(
        connection_factory=lambda: get_connection(db_path),
        service_factory=lambda c: NotificationService(c, sender=sender, clock=_clock()),
        clock=_clock(),
    )
    assert sched.maybe_fire(get_connection(db_path))
    assert sender.sent == []
    assert len(_feed_digests(_feed(db_path))) == 1


# ── D89: once per LOCAL day ──────────────────────────────────────────────────
#
# `digest_time` is local ("09:00" means 9am where the user is), but the
# once-a-day guard compared UTC dates. West of Greenwich the UTC date turns
# over in the local evening, so the guard reset and the scheduler — already
# past 09:00 local — sent a second digest: observed 2026-10-09 14:39Z (10:39
# EDT) and 2026-10-10 00:00Z (20:00 EDT, the same local day).

from zoneinfo import ZoneInfo

NY = ZoneInfo("America/New_York")


class _Clock:
    """A clock the test moves. Returns UTC, as the real one does."""

    def __init__(self, at):
        self.at = at

    def __call__(self):
        return self.at


def _local(y, mo, d, h, mi=0):
    """A New York wall-clock time, as the UTC instant the clock returns."""
    return datetime(y, mo, d, h, mi, tzinfo=NY).astimezone(timezone.utc)


def _scheduler(conn, clock, sender):
    return DigestScheduler(
        connection_factory=lambda: conn,
        service_factory=lambda c: NotificationService(c, sender=sender, clock=clock, tz=NY),
        clock=clock, tz=NY)


def _seed_tier3_every(conn, start, end, hours=3):
    t, n = start, 0
    while t <= end:
        _seed(conn, message_id=f"t3-{n}", tier=3, received_at=t.isoformat())
        t += timedelta(hours=hours)
        n += 1


def _digest_local_dates(conn):
    rows = conn.execute(
        "SELECT sent_at FROM notification_log WHERE notification_type = 'digest' ORDER BY id"
    ).fetchall()
    return [datetime.fromisoformat(r["sent_at"]).astimezone(NY).date().isoformat()
            for r in rows]


def test_no_second_digest_in_the_local_evening_after_utc_midnight(conn):
    PreferencesRepo(conn).set("digest_time", "09:00")
    _seed_tier3_every(conn, _local(2026, 6, 14, 0), _local(2026, 6, 16, 0))
    clock, sender = _Clock(_local(2026, 6, 15, 9, 0)), RecordingSender()
    sched = _scheduler(conn, clock, sender)

    assert sched.maybe_fire(conn)                         # 09:00 EDT = 13:00Z
    clock.at = _local(2026, 6, 15, 21, 0)                 # 21:00 EDT = 01:00Z on the 16th
    assert clock.at.date().isoformat() == "2026-06-16"    # UTC has turned over
    assert not sched.maybe_fire(conn), "a second digest on the same local day"
    assert _digest_local_dates(conn) == ["2026-06-15"]


def test_digest_due_at_nine_is_sent_once_then_not_until_the_next_local_day(conn):
    PreferencesRepo(conn).set("digest_time", "09:00")
    _seed_tier3_every(conn, _local(2026, 6, 14, 0), _local(2026, 6, 17, 0))
    clock, sender = _Clock(_local(2026, 6, 15, 8, 59)), RecordingSender()
    sched = _scheduler(conn, clock, sender)

    fired = []
    for h, m in [(8, 59), (9, 0), (9, 1), (12, 0), (20, 0), (23, 59)]:
        clock.at = _local(2026, 6, 15, h, m)
        fired.append(sched.maybe_fire(conn))
    assert fired == [False, True, False, False, False, False]

    clock.at = _local(2026, 6, 16, 8, 59)
    assert not sched.maybe_fire(conn), "sent before digest_time on the next day"
    clock.at = _local(2026, 6, 16, 9, 0)
    assert sched.maybe_fire(conn), "the next local day's digest did not go out"
    assert _digest_local_dates(conn) == ["2026-06-15", "2026-06-16"]


@pytest.mark.parametrize("transition", [
    (2026, 3, 8),     # spring forward: 02:00 EST -> 03:00 EDT, a 23-hour day
    (2026, 11, 1),    # fall back: 02:00 EDT -> 01:00 EST, a 25-hour day
])
@pytest.mark.parametrize("digest_time", [
    "09:00",
    "01:30",          # happens twice on the fall-back day
    "02:30",          # does not happen on the spring-forward day
])
def test_exactly_one_digest_each_local_day_across_a_dst_transition(conn, transition,
                                                                   digest_time):
    y, mo, d = transition
    day = datetime(y, mo, d)
    first = (day - timedelta(days=1)).date()
    last = (day + timedelta(days=1)).date()
    start = datetime(first.year, first.month, first.day, tzinfo=NY).astimezone(timezone.utc)
    end = datetime(last.year, last.month, last.day, 23, 59,
                   tzinfo=NY).astimezone(timezone.utc)

    PreferencesRepo(conn).set("digest_time", digest_time)
    _seed_tier3_every(conn, start - timedelta(days=1), end)
    clock, sender = _Clock(start), RecordingSender()
    sched = _scheduler(conn, clock, sender)

    # Tick every 15 minutes of real (UTC) time, as the scheduler's thread does.
    while clock.at <= end:
        sched.maybe_fire(conn)
        clock.at += timedelta(minutes=15)

    dates = _digest_local_dates(conn)
    expected = [(first + timedelta(days=i)).isoformat() for i in range(3)]
    assert dates == expected, f"digests by local date: {dates}"
