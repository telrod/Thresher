"""
thresher notification service
Surfaces high-urgency messages as ambient macOS notifications.

Delivery is via `osascript -e 'display notification …'` — zero dependencies,
runs in the Python backend. (The Swift app may later supersede this using
UserNotifications.framework; this service writes a notification_log row for
every send so that handoff is possible.)

Constitution refs:
  P2 — Ambient over interruptive: banners only, never a sound by default; nothing
        blocks the user's work. (tier1_sound_enabled is an opt-in pref, default off.)
  P5 — User controls side effects: a notification is a side effect, gated by
        operating mode and quiet hours; on a fresh install nothing surprising fires.

Behavioral invariants enforced here:
  • Tier 1 invariant: a Tier 1 message ALWAYS surfaces an ambient alert, regardless
    of operating mode (no mode suppresses Tier 1). Quiet hours still defer it
    (P2: it surfaces at the next natural break) but it is never dropped (P1).
  • Dedup: a given message is notified at most once (we never re-banner on reclassify).
"""

import json
import logging
import subprocess
from dataclasses import dataclass
from datetime import datetime, time, timedelta, timezone
from typing import Optional

log = logging.getLogger(__name__)

# Which tiers trigger an *immediate* ambient alert, by operating mode.
#   Focus    → only Tier 1 (Tier 2+ are queued for the digest / "Soon")
#   Catch-up → Tier 1 and Tier 2
# Tier 1 is always present in both: the Tier 1 invariant.
_MODE_ALERT_TIERS = {
    "focus":   {1},
    "catch-up": {1, 2},
    "catch_up": {1, 2},   # tolerate either spelling
}

# How far back the daily digest looks for Tier 3 messages (spec §3.3: "last 24 hours").
DIGEST_WINDOW_HOURS = 24
DIGEST_TIER = 3


@dataclass
class NotificationDecision:
    """The outcome of evaluating whether/how to notify for a message."""
    should_notify: bool
    reason: str
    notification_type: Optional[str] = None   # 'tier1_alert' | 'tier2_alert'
    deferred: bool = False                     # held by quiet hours (will surface later)
    defer_to_app: bool = False                 # native app owns delivery (D45 handoff)


# ── D45 native-delivery handoff ───────────────────────────────────────────────
# When the SwiftUI app is running + notification-permitted, it "claims" delivery
# by writing a short-lived heartbeat pref; the backend then LOGS the notification
# but skips the osascript banner, so the app delivers it natively (from
# GET /notifications) and the two paths never double-fire. The claim is checked
# at DECISION time (not send time) so exactly one deliverer is chosen per message.
#
# The claim is a UTC ISO-8601 timestamp = "valid until". Past/absent → the app is
# not (currently) delivering, so the backend delivers as it always has. The TTL is
# short and refreshed by the app on its poll cadence: if the app quits, the claim
# lapses within one TTL and osascript resumes — the Tier-1 invariant never depends
# on the app staying up.
# Legacy key: an app-computed "valid until" instant. Still READ so an older
# build that has not been relaunched keeps working, but only ever honoured
# within CLAIM_STALE_SECONDS of now (see _app_owns_delivery).
DELIVERY_OWNER_UNTIL_KEY = "notification_delivery_owner_until"
# Current key: the instant the app last checked in. The backend decides freshness.
DELIVERY_HEARTBEAT_KEY = "notification_delivery_heartbeat"

# How recently the app must have checked in for the backend to defer to it.
#
# THE SHAPE OF THE CLAIM IS THE FIX. It used to be a "valid until" instant the
# APP computed (2 * its poll interval + 30s, D49) — which carries when trust
# expires but not when it was earned, so the backend could not tell these apart:
#
#   (a) a live app that wrote until = now + 55s   -> must defer
#   (b) a dead app that wrote until = now + 630s, 575 seconds ago -> must deliver
#
# Both present an identical 55-seconds-remaining claim. On 2026-09-06 that was
# case (b): an app launched under a 5-minute poll interval kept claiming with a
# 630s TTL after the interval was changed to 1 minute (it read the interval once
# — Part B's defect, in the app), then quit at 06:48:01 leaving a claim valid
# until 06:58:31. A Tier 1 classified at 06:57:36 was deferred to an app that had
# been gone for 9m35s. No banner fired by any path, and the log said "Notified".
#
# So the app now records WHEN IT LAST CHECKED IN and the backend owns the
# freshness window — the same direction as D65's poll heartbeat, where silence
# reads as broken rather than the reporter deciding it is still healthy.
# Crucially the heartbeat cadence is FIXED and independent of the poll interval:
# at the 15-minute maximum the old design refreshed only every 900s, so no
# freshness window could both keep a live app claiming and catch a quit one.
#
# The direction of the error is deliberate (§2.3): absent, unparseable, or stale
# -> we NOTIFY. A duplicate banner is a papercut; a lost Tier 1 is a broken promise.
CLAIM_HEARTBEAT_SECONDS = 30   # the app re-checks in this often, whatever the interval
CLAIM_STALE_SECONDS = 90       # 3 missed heartbeats before we presume the app is gone

# Marks WHO delivered (or will deliver) a logged notification, in the payload:
#   'osascript' — the backend fired the banner now (delivered=True)
#   'app'       — the backend deferred; the app delivers natively from the log
DELIVERY_OSASCRIPT = "osascript"
DELIVERY_APP = "app"


@dataclass
class DigestResult:
    """The outcome of a daily-digest run."""
    sent: bool
    reason: str
    message_count: int = 0
    message_ids: Optional[list] = None


def _now() -> datetime:
    return datetime.now(timezone.utc)


class NotificationService:
    """
    Stateless evaluator + sender. Construct with a connection and the repos it
    needs; call notify_for_message(message_id) after a message is classified.
    """

    def __init__(self, conn, *, sender=None, clock=None):
        """
        Args:
            conn: sqlite3 connection (its own per thread).
            sender: callable(title, subtitle, text) -> None that performs delivery.
                    Injected for tests; defaults to the osascript sender.
            clock: callable() -> datetime (UTC). Injected for tests (quiet hours).
        """
        self.conn = conn
        self._send = sender or send_via_osascript
        self._clock = clock or _now

    # ── public API ───────────────────────────────────────────────────────────

    def notify_for_message(self, message_id: str) -> NotificationDecision:
        """
        Evaluate notification rules for an already-classified message and, if
        warranted, deliver an ambient banner and log it. Idempotent per message.
        """
        row = self.conn.execute(
            """
            SELECT m.sender_name, m.sender_email, m.subject,
                   c.urgency_tier, c.category
            FROM classifications c
            JOIN messages m ON m.id = c.message_id
            WHERE c.message_id = ?
            """,
            (message_id,),
        ).fetchone()
        if row is None:
            return NotificationDecision(False, "message or classification not found")

        decision = self._decide(message_id, row["urgency_tier"])
        if not decision.should_notify:
            log.debug("No notification for %s: %s", message_id, decision.reason)
            return decision

        title, subtitle, text = self._format(row)
        if decision.deferred:
            # Quiet hours: do not deliver now, but record intent so it can be
            # surfaced at the next break (and so we never silently drop it, P1).
            self._log_notification(message_id, decision.notification_type,
                                   {"title": title, "text": text}, delivered=False)
            log.info("Deferred %s notification for %s (quiet hours)",
                     decision.notification_type, message_id)
            return decision

        if decision.defer_to_app:
            # D45 handoff: the native app owns delivery right now. Log the row so
            # the app picks it up from GET /notifications and delivers natively —
            # and DO NOT fire osascript, so the two paths never double-fire. Marked
            # delivered=False (the BACKEND did not deliver it) + delivery=app.
            self._log_notification(message_id, decision.notification_type,
                                   {"title": title, "text": text,
                                    "delivery": DELIVERY_APP}, delivered=False)
            # NOT "Notified": nothing has been delivered yet at this point. The
            # app collects this row from GET /notifications and posts the banner.
            # The old line said "Notified (tier1_alert) … — deferred to native
            # app", which reads as an outcome and was believed during the
            # 2026-09-06 investigation while the alert had reached nobody.
            log.info("Queued (%s) for %s — handed to the native app for delivery",
                     decision.notification_type, message_id)
            return decision

        sound = self._pref("tier1_sound_enabled", "false") == "true" and row["urgency_tier"] == 1
        try:
            self._send(title=title, subtitle=subtitle, text=text, sound=sound)
        except Exception:
            log.exception("Failed to deliver notification for %s", message_id)
            return NotificationDecision(False, "delivery failed",
                                        decision.notification_type)
        self._log_notification(message_id, decision.notification_type,
                               {"title": title, "text": text,
                                "delivery": DELIVERY_OSASCRIPT}, delivered=True)
        # Only written once _send returned — this line means a banner fired, and
        # names the path that fired it (§2.4).
        log.info("Notified (%s) for %s via %s",
                 decision.notification_type, message_id, DELIVERY_OSASCRIPT)
        return decision

    # ── daily digest (spec §3.3) ────────────────────────────────────────────────

    def build_and_send_digest(self, *, force: bool = False) -> DigestResult:
        """
        Summarize Tier 3 messages received in the last 24h into a single digest
        notification (spec §3.3). Idempotent per calendar day — won't send twice
        on the same day unless `force=True` (used by tests / a manual re-run).

        Empty digest: if no Tier 3 messages landed in the window, no notification
        is sent (we don't nag with an empty summary), and we record nothing — so
        a later message arriving before the next scheduled run is still included.
        """
        if not force and self._digest_already_sent_today():
            return DigestResult(False, "digest already sent today")

        rows = self._recent_tier3()
        if not rows:
            return DigestResult(False, "no Tier 3 messages in the last 24h", 0, [])

        ids = [r["id"] for r in rows]
        title, subtitle, text = self._format_digest(rows)
        try:
            # Digest is a summary, never a sound alert (P2: ambient).
            self._send(title=title, subtitle=subtitle, text=text, sound=False)
        except Exception:
            log.exception("Failed to deliver daily digest")
            return DigestResult(False, "delivery failed", len(ids), ids)

        self._log_notification(
            None, "digest",
            {"title": title, "text": text, "message_ids": ids, "count": len(ids)},
            delivered=True,
        )
        log.info("Sent daily digest summarizing %d Tier 3 message(s)", len(ids))
        return DigestResult(True, "sent", len(ids), ids)

    def _recent_tier3(self) -> list:
        """Tier 3 messages received within the digest window, newest first."""
        cutoff = (self._clock() - timedelta(hours=DIGEST_WINDOW_HOURS)).isoformat()
        return self.conn.execute(
            """
            SELECT m.id, m.sender_name, m.sender_email, m.subject, m.received_at,
                   c.category
            FROM messages m
            JOIN classifications c ON c.message_id = m.id
            WHERE c.urgency_tier = ? AND m.received_at >= ?
            ORDER BY m.received_at DESC
            """,
            (DIGEST_TIER, cutoff),
        ).fetchall()

    def _digest_already_sent_today(self) -> bool:
        """True if a 'digest' was already logged on the current calendar day."""
        today = self._clock().date().isoformat()
        row = self.conn.execute(
            """
            SELECT 1 FROM notification_log
            WHERE notification_type = 'digest' AND substr(sent_at, 1, 10) = ?
            LIMIT 1
            """,
            (today,),
        ).fetchone()
        return row is not None

    def _format_digest(self, rows) -> tuple:
        """
        Build the digest banner. In catch-up mode Tier 3 is surfaced more
        prominently (spec §3.4.2) — we list more senders inline; in focus mode we
        keep it terse. The full per-message detail lives in the app (spec §3.3).
        """
        count = len(rows)
        mode = (self._pref("operating_mode", "focus") or "focus").lower()
        prominent = mode in ("catch-up", "catch_up")
        preview_n = 5 if prominent else 3

        senders = []
        for r in rows[:preview_n]:
            senders.append(r["sender_name"] or r["sender_email"])
        more = count - len(senders)

        title = f"Daily digest · {count} Tier 3 message{'s' if count != 1 else ''}"
        subtitle = "Catch-up" if prominent else "Focus"
        body = ", ".join(senders)
        if more > 0:
            body += f", and {more} more"
        text = body or "(no senders)"
        return title, subtitle, text

    # ── decision logic ────────────────────────────────────────────────────────

    def _decide(self, message_id: str, tier: int) -> NotificationDecision:
        # Dedup: never notify the same message twice (e.g. on reclassification).
        if self._already_notified(message_id):
            return NotificationDecision(False, "already notified")

        mode = (self._pref("operating_mode", "focus") or "focus").lower()
        alert_tiers = _MODE_ALERT_TIERS.get(mode, {1})

        if tier not in alert_tiers:
            return NotificationDecision(
                False, f"tier {tier} not alerted in '{mode}' mode")

        ntype = "tier1_alert" if tier == 1 else "tier2_alert"

        # Quiet hours defer delivery — but NOT for Tier 1, which must always
        # surface ambiently (Tier 1 invariant). Tier 2 is held until the window ends.
        if tier != 1 and self._in_quiet_hours():
            return NotificationDecision(True, "deferred by quiet hours", ntype, deferred=True)

        # D45 handoff: if the native app currently owns delivery, decide to notify
        # but let the app deliver (backend logs only, no osascript). Checked here,
        # at decision time, so exactly one deliverer is chosen per message — no
        # double-fire in the window where both paths are live.
        if self._app_owns_delivery():
            return NotificationDecision(True, f"tier {tier} alert — deferred to native app",
                                        ntype, defer_to_app=True)

        return NotificationDecision(True, f"tier {tier} alert in '{mode}' mode", ntype)

    def _app_owns_delivery(self) -> bool:
        """True iff the native app has checked in recently enough to be presumed
        running (D45 hand-off, reshaped 2026-09-06 — see CLAIM_STALE_SECONDS).

        Preferred signal: DELIVERY_HEARTBEAT_KEY, the instant the app last checked
        in, against a freshness window the BACKEND owns. Absent, unparseable, or
        older than CLAIM_STALE_SECONDS -> the app is presumed gone and the backend
        delivers. Every failure mode fails toward delivering (§2.3).

        The legacy DELIVERY_OWNER_UNTIL_KEY is still honoured so an older app
        build that has not been relaunched is not left double-bannered, but only
        within CLAIM_STALE_SECONDS of now: a long app-computed TTL is exactly what
        outlived the quit app on 2026-09-06."""
        now = self._clock()

        beat = self._parse_claim_instant(DELIVERY_HEARTBEAT_KEY)
        if beat is not None:
            age = (now - beat).total_seconds()
            if age > CLAIM_STALE_SECONDS:
                log.warning(
                    "App delivery heartbeat is %.0fs old (> %ds) — presuming the "
                    "app is not running; delivering via osascript",
                    age, CLAIM_STALE_SECONDS)
                return False
            # A heartbeat far in the FUTURE means a clock skew or a bad write; we
            # cannot conclude the app is alive from it, so fall back to delivering.
            if age < -CLAIM_STALE_SECONDS:
                log.warning("App delivery heartbeat is %.0fs in the future — "
                            "ignoring it and delivering via osascript", -age)
                return False
            return True

        until = self._parse_claim_instant(DELIVERY_OWNER_UNTIL_KEY)
        if until is None:
            return False
        if now >= until:
            return False
        remaining = (until - now).total_seconds()
        if remaining > CLAIM_STALE_SECONDS:
            log.warning(
                "Legacy delivery claim runs %.0fs ahead (> %ds) — the app that "
                "wrote it may have quit; delivering via osascript",
                remaining, CLAIM_STALE_SECONDS)
            return False
        return True

    def _parse_claim_instant(self, key: str):
        """Read a UTC ISO-8601 pref, or None if absent/unparseable. A parse error
        is logged and treated as absent — never as a live claim."""
        raw = self._pref(key, "")
        if not raw:
            return None
        try:
            value = datetime.fromisoformat(raw)
        except (ValueError, TypeError):
            log.warning("Invalid %s pref: %r; backend keeps delivery", key, raw)
            return None
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value

    def _in_quiet_hours(self) -> bool:
        window = self._pref("quiet_hours", "")  # e.g. "22:00-07:00"; empty = disabled
        if not window or "-" not in window:
            return False
        try:
            start_s, end_s = window.split("-", 1)
            start, end = _parse_hhmm(start_s), _parse_hhmm(end_s)
        except (ValueError, TypeError):
            log.warning("Invalid quiet_hours pref: %r; ignoring", window)
            return False
        now_t = self._clock().astimezone().time()
        if start <= end:
            return start <= now_t < end
        # Wraps past midnight (e.g. 22:00-07:00).
        return now_t >= start or now_t < end

    # ── helpers ────────────────────────────────────────────────────────────────

    def _already_notified(self, message_id: str) -> bool:
        row = self.conn.execute(
            "SELECT 1 FROM notification_log WHERE message_id = ? LIMIT 1",
            (message_id,),
        ).fetchone()
        return row is not None

    def _pref(self, key: str, default: str) -> str:
        row = self.conn.execute(
            "SELECT value FROM preferences WHERE key = ?", (key,)
        ).fetchone()
        return row["value"] if row else default

    def _format(self, row) -> tuple:
        who = row["sender_name"] or row["sender_email"]
        tier = row["urgency_tier"]
        title = f"Tier {tier} · {who}"
        subtitle = row["category"].title() if row["category"] else ""
        text = row["subject"] or "(no subject)"
        return title, subtitle, text

    def _log_notification(self, message_id, ntype, payload, *, delivered: bool) -> None:
        payload = {**payload, "delivered": delivered}
        self.conn.execute(
            """
            INSERT INTO notification_log (message_id, notification_type, sent_at, payload)
            VALUES (?, ?, ?, ?)
            """,
            (message_id, ntype, self._clock().isoformat(), json.dumps(payload)),
        )
        self.conn.commit()


# ── delivery backend ────────────────────────────────────────────────────────

def send_via_osascript(*, title: str, subtitle: str, text: str, sound: bool = False) -> None:
    """
    Deliver an ambient macOS notification using osascript. No sound unless
    explicitly enabled (P2: ambient, not interruptive).
    """
    script = f'display notification {_q(text)} with title {_q(title)}'
    if subtitle:
        script += f' subtitle {_q(subtitle)}'
    if sound:
        script += ' sound name "Submarine"'
    subprocess.run(["osascript", "-e", script], check=True,
                   capture_output=True, text=True)


def _q(s: str) -> str:
    """Quote a string as an AppleScript string literal (escape backslashes/quotes)."""
    escaped = (s or "").replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _parse_hhmm(s: str) -> time:
    h, m = s.strip().split(":")
    return time(int(h), int(m))