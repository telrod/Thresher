"""
Tests for notifications.service — gating logic and delivery.

osascript delivery is replaced with a recording fake; the focus is the decision
logic (operating mode, quiet hours, Tier 1 invariant, dedup) and the
notification_log side effect.
"""

from datetime import datetime, timezone

import pytest

from db.database import (
    Classification, ClassificationRepo, Message, MessageRepo, PreferencesRepo,
)
from notifications.service import NotificationService


def _seed_message(conn, *, message_id, tier, sender="a@b.com", subject="hi",
                  category="work"):
    MessageRepo(conn).insert(Message(
        id=message_id, account="acct", sender_email=sender, sender_name="Al",
        subject=subject, received_at="2026-06-15T00:00:00+00:00",
        ingested_at="2026-06-15T00:00:00+00:00",
    ))
    ClassificationRepo(conn).upsert(Classification(
        message_id=message_id, urgency_tier=tier, category=category,
        triage_state="new", classified_at="2026-06-15T00:00:00+00:00",
        rule_matches=[{"rule_name": "x", "field": "f", "operator": "o", "value": "v"}],
    ))


class RecordingSender:
    def __init__(self):
        self.sent = []

    def __call__(self, *, title, subtitle, text, sound=False):
        self.sent.append({"title": title, "subtitle": subtitle, "text": text, "sound": sound})


def _service(conn, sender, *, clock=None):
    return NotificationService(conn, sender=sender, clock=clock)


# ── operating mode gating ──────────────────────────────────────────────────

def test_tier1_notifies_in_focus_mode(conn):
    PreferencesRepo(conn).set("operating_mode", "focus")
    _seed_message(conn, message_id="m1", tier=1)
    sender = RecordingSender()
    decision = _service(conn, sender).notify_for_message("m1")
    assert decision.should_notify
    assert decision.notification_type == "tier1_alert"
    assert len(sender.sent) == 1
    assert "Tier 1" in sender.sent[0]["title"]


def test_tier2_suppressed_in_focus_mode(conn):
    PreferencesRepo(conn).set("operating_mode", "focus")
    _seed_message(conn, message_id="m2", tier=2)
    sender = RecordingSender()
    decision = _service(conn, sender).notify_for_message("m2")
    assert not decision.should_notify
    assert sender.sent == []


def test_tier2_notifies_in_catchup_mode(conn):
    PreferencesRepo(conn).set("operating_mode", "catch-up")
    _seed_message(conn, message_id="m3", tier=2)
    sender = RecordingSender()
    decision = _service(conn, sender).notify_for_message("m3")
    assert decision.should_notify
    assert decision.notification_type == "tier2_alert"


def test_tier4_never_notifies(conn):
    PreferencesRepo(conn).set("operating_mode", "catch-up")
    _seed_message(conn, message_id="m4", tier=4)
    sender = RecordingSender()
    assert not _service(conn, sender).notify_for_message("m4").should_notify


# ── Tier 1 invariant ───────────────────────────────────────────────────────

def test_tier1_always_surfaces_regardless_of_mode(conn):
    """The Tier 1 invariant: no operating mode suppresses Tier 1."""
    for mode in ("focus", "catch-up"):
        PreferencesRepo(conn).set("operating_mode", mode)
        mid = f"t1-{mode}"
        _seed_message(conn, message_id=mid, tier=1)
        sender = RecordingSender()
        assert _service(conn, sender).notify_for_message(mid).should_notify


# ── quiet hours ─────────────────────────────────────────────────────────────

def _clock_at(hh, mm):
    # Build a fixed UTC datetime; quiet-hours compares local time, and the test
    # box's local tz is applied consistently in both code and assertion.
    return lambda: datetime(2026, 6, 15, hh, mm, tzinfo=timezone.utc).astimezone(timezone.utc)


def test_tier2_deferred_during_quiet_hours(conn):
    PreferencesRepo(conn).set("operating_mode", "catch-up")
    PreferencesRepo(conn).set("quiet_hours", "00:00-23:59")  # effectively always
    _seed_message(conn, message_id="q1", tier=2)
    sender = RecordingSender()
    decision = _service(conn, sender, clock=_clock_at(12, 0)).notify_for_message("q1")
    assert decision.should_notify and decision.deferred
    assert sender.sent == []  # not delivered now
    # but logged as intent (not dropped, P1)
    row = conn.execute(
        "SELECT payload FROM notification_log WHERE message_id = 'q1'").fetchone()
    assert row is not None and '"delivered": false' in row["payload"]


def test_tier1_not_deferred_by_quiet_hours(conn):
    """Tier 1 must surface ambiently even during quiet hours (invariant)."""
    PreferencesRepo(conn).set("operating_mode", "focus")
    PreferencesRepo(conn).set("quiet_hours", "00:00-23:59")
    _seed_message(conn, message_id="q2", tier=1)
    sender = RecordingSender()
    decision = _service(conn, sender, clock=_clock_at(3, 0)).notify_for_message("q2")
    assert decision.should_notify and not decision.deferred
    assert len(sender.sent) == 1


# ── dedup + sound + logging ──────────────────────────────────────────────────

def test_message_notified_at_most_once(conn):
    PreferencesRepo(conn).set("operating_mode", "focus")
    _seed_message(conn, message_id="d1", tier=1)
    sender = RecordingSender()
    svc = _service(conn, sender)
    first = svc.notify_for_message("d1")
    second = svc.notify_for_message("d1")
    assert first.should_notify
    assert not second.should_notify  # deduped
    assert len(sender.sent) == 1


def test_sound_only_when_enabled_and_tier1(conn):
    PreferencesRepo(conn).set("operating_mode", "focus")
    PreferencesRepo(conn).set("tier1_sound_enabled", "true")
    _seed_message(conn, message_id="s1", tier=1)
    sender = RecordingSender()
    _service(conn, sender).notify_for_message("s1")
    assert sender.sent[0]["sound"] is True


def test_no_sound_by_default(conn):
    PreferencesRepo(conn).set("operating_mode", "focus")  # tier1_sound default false
    _seed_message(conn, message_id="s2", tier=1)
    sender = RecordingSender()
    _service(conn, sender).notify_for_message("s2")
    assert sender.sent[0]["sound"] is False


def test_missing_message_returns_no_notify(conn):
    sender = RecordingSender()
    decision = _service(conn, sender).notify_for_message("does-not-exist")
    assert not decision.should_notify


def test_successful_send_logged_as_delivered(conn):
    PreferencesRepo(conn).set("operating_mode", "focus")
    _seed_message(conn, message_id="L1", tier=1)
    _service(conn, RecordingSender()).notify_for_message("L1")
    row = conn.execute(
        "SELECT notification_type, payload FROM notification_log WHERE message_id='L1'"
    ).fetchone()
    assert row["notification_type"] == "tier1_alert"
    assert '"delivered": true' in row["payload"]

# ── D45 native-delivery handoff (no double-fire) ──────────────────────────────

from datetime import timedelta
from notifications.service import (
    DELIVERY_OWNER_UNTIL_KEY, DELIVERY_HEARTBEAT_KEY, DELIVERY_APP, DELIVERY_OSASCRIPT,
)
import json as _json


def _fixed_clock(dt):
    return lambda: dt


def _log_rows(conn):
    return conn.execute(
        "SELECT message_id, notification_type, payload FROM notification_log ORDER BY id"
    ).fetchall()


def test_app_owns_delivery_skips_osascript_but_logs(conn):
    """When the app's delivery claim is live, the backend LOGS but does NOT send —
    so the app (polling the log) is the only deliverer. The core no-double-fire."""
    now = datetime(2026, 7, 12, 12, 0, 0, tzinfo=timezone.utc)
    PreferencesRepo(conn).set("operating_mode", "focus")
    # App claims delivery for the next 90s.
    PreferencesRepo(conn).set(DELIVERY_OWNER_UNTIL_KEY, (now + timedelta(seconds=90)).isoformat())
    _seed_message(conn, message_id="m1", tier=1)

    sender = RecordingSender()
    decision = _service(conn, sender, clock=_fixed_clock(now)).notify_for_message("m1")

    assert decision.should_notify
    assert decision.defer_to_app is True
    assert sender.sent == []                        # osascript did NOT fire
    rows = _log_rows(conn)
    assert len(rows) == 1                            # but it WAS logged for the app
    assert _json.loads(rows[0]["payload"])["delivery"] == DELIVERY_APP


def test_expired_claim_falls_back_to_osascript(conn):
    """A stale claim (app quit) → backend delivers as normal within one TTL."""
    now = datetime(2026, 7, 12, 12, 0, 0, tzinfo=timezone.utc)
    PreferencesRepo(conn).set("operating_mode", "focus")
    # Claim expired one second ago.
    PreferencesRepo(conn).set(DELIVERY_OWNER_UNTIL_KEY, (now - timedelta(seconds=1)).isoformat())
    _seed_message(conn, message_id="m1", tier=1)

    sender = RecordingSender()
    decision = _service(conn, sender, clock=_fixed_clock(now)).notify_for_message("m1")

    assert decision.defer_to_app is False
    assert len(sender.sent) == 1                     # osascript delivered (Tier-1 floor holds)
    assert _json.loads(_log_rows(conn)[0]["payload"])["delivery"] == DELIVERY_OSASCRIPT


def test_no_claim_delivers_via_osascript(conn):
    """Default (no claim pref) → backend owns delivery, tagged osascript."""
    now = datetime(2026, 7, 12, 12, 0, 0, tzinfo=timezone.utc)
    PreferencesRepo(conn).set("operating_mode", "focus")
    _seed_message(conn, message_id="m1", tier=1)

    sender = RecordingSender()
    _service(conn, sender, clock=_fixed_clock(now)).notify_for_message("m1")
    assert len(sender.sent) == 1
    assert _json.loads(_log_rows(conn)[0]["payload"])["delivery"] == DELIVERY_OSASCRIPT


def test_malformed_claim_fails_safe_to_osascript(conn):
    """An unparseable claim must not silence delivery — fail safe to the backend."""
    now = datetime(2026, 7, 12, 12, 0, 0, tzinfo=timezone.utc)
    PreferencesRepo(conn).set("operating_mode", "focus")
    PreferencesRepo(conn).set(DELIVERY_OWNER_UNTIL_KEY, "not-a-timestamp")
    _seed_message(conn, message_id="m1", tier=1)

    sender = RecordingSender()
    _service(conn, sender, clock=_fixed_clock(now)).notify_for_message("m1")
    assert len(sender.sent) == 1                     # delivered anyway (fail-safe)


# ── Part A: a stale claim must not silence the Tier-1 floor ───────────────────
#
# The 2026-09-06 incident, reproduced from the live evidence rather than from a
# model of it. Three Tier-1 messages logged IDENTICAL lines; the middle one
# (UID 118594, 06:57:36 local) reached nobody, because:
#
#   06:27:51  app launches while poll_interval_minutes = 5, so it claims with
#             TTL = 2*300+30 = 630s and refreshes every ~301s (log: 301,301,300,308)
#   06:37:29  the author sets the interval to 1 minute in Settings
#             -> the app had ALREADY read the interval once (ThresherApp.swift
#                :229 `.task`) and keeps using 630s. Part B's defect, in the app.
#   06:48:01  last claim refresh before the app quits -> valid until 06:58:31
#   06:57:36  Tier 1 classified. Claim is 55s from expiry, so the backend defers
#             to an app that has been GONE for ~9m35s. No banner, by any path.
#
# So the claim's expiry check was never wrong; the claim itself was written with
# an interval the app no longer used. The backend cannot verify the app's
# arithmetic, so it must not trust it unboundedly.
#
# VERIFIED RED against the pre-fix service, and the failure was the incident:
#     assert sender.sent == []  ... AssertionError: the backend deferred to a
#     claim 600s in the future and osascript never fired (0 sends).
# i.e. the Tier-1 message was logged as "Notified" and delivered to nobody.

def test_stale_heartbeat_does_not_silence_tier1(conn):
    """The live 2026-09-06 failure: the app quit, its claim outlived it, and a
    Tier 1 was deferred to nobody.

    Reproduced through the REAL mechanism, not a model of it: the app checks in,
    then stops (it quit), then a Tier 1 arrives 9m35s later — the actual gap
    between the last claim refresh (06:48:01) and the lost alert (06:57:36).
    The backend must presume the app gone and deliver via osascript.

    VERIFIED RED against the pre-fix service, and the failure WAS the incident:
        AssertionError: Tier 1 was deferred to an app that stopped checking in
        575s ago and osascript never fired
        assert 0 == 1 +  where 0 = len([])
    Pre-fix, the only signal was an app-computed "valid until" that was still
    55s from expiry at that instant, so the backend deferred — see
    CLAIM_STALE_SECONDS for why that shape could not distinguish a live app."""
    checked_in = datetime(2026, 9, 6, 10, 48, 1, tzinfo=timezone.utc)
    now = datetime(2026, 9, 6, 10, 57, 36, tzinfo=timezone.utc)   # +575s, app QUIT
    PreferencesRepo(conn).set("operating_mode", "focus")
    PreferencesRepo(conn).set(DELIVERY_HEARTBEAT_KEY, checked_in.isoformat())
    _seed_message(conn, message_id="m-stale-claim", tier=1)

    sender = RecordingSender()
    decision = _service(conn, sender, clock=_fixed_clock(now)).notify_for_message("m-stale-claim")

    assert len(sender.sent) == 1, (
        "Tier 1 was deferred to an app that stopped checking in "
        f"{(now - checked_in).total_seconds():.0f}s ago and osascript never fired "
        "— this is the lost-alert failure (constitution §3.2)")
    assert decision.defer_to_app is False
    assert _json.loads(_log_rows(conn)[0]["payload"])["delivery"] == DELIVERY_OSASCRIPT


def test_legacy_long_claim_does_not_silence_tier1(conn):
    """The same incident as the OLD app build would present it after the fix.

    An app that has not been relaunched still writes only the legacy
    "valid until" key, with the 630s TTL that caused this. Honouring it whole
    would reproduce the bug for exactly the users who have not updated, so a
    legacy claim is trusted only as far as CLAIM_STALE_SECONDS.

    VERIFIED RED by raising the legacy branch's bound to 630 (i.e. taking the
    app's TTL at face value): 0 sends, the alert lost again."""
    now = datetime(2026, 9, 6, 10, 48, 1, tzinfo=timezone.utc)
    PreferencesRepo(conn).set("operating_mode", "focus")
    # Exactly what the pre-fix app wrote at 06:48:01 under a 5-minute interval.
    PreferencesRepo(conn).set(
        DELIVERY_OWNER_UNTIL_KEY, (now + timedelta(seconds=630)).isoformat())
    _seed_message(conn, message_id="m-legacy-claim", tier=1)

    sender = RecordingSender()
    decision = _service(conn, sender, clock=_fixed_clock(now)).notify_for_message("m-legacy-claim")

    assert len(sender.sent) == 1
    assert decision.defer_to_app is False


def test_claim_within_the_trusted_window_still_defers(conn):
    """The fix must not break D45: a FRESH claim still hands delivery to the app.

    Guards the over-correction — if this passed while the test above also passed
    only because deferral was disabled outright, D45 would be dead and the
    no-double-fire property lost."""
    now = datetime(2026, 9, 6, 10, 57, 36, tzinfo=timezone.utc)
    PreferencesRepo(conn).set("operating_mode", "focus")
    PreferencesRepo(conn).set(DELIVERY_HEARTBEAT_KEY, (now - timedelta(seconds=5)).isoformat())
    _seed_message(conn, message_id="m-fresh-claim", tier=1)

    sender = RecordingSender()
    decision = _service(conn, sender, clock=_fixed_clock(now)).notify_for_message("m-fresh-claim")

    assert decision.defer_to_app is True
    assert sender.sent == []
    assert _json.loads(_log_rows(conn)[0]["payload"])["delivery"] == DELIVERY_APP
