"""
thresher digest scheduler
A background thread that fires the Tier 3 daily digest at the user's configured
`digest_time` (preferences, default 09:00 — spec §3.3).

Design mirrors the ingestion pipeline's threading model: a daemon thread with an
interruptible `threading.Event` for graceful shutdown. Rather than computing a
precise sleep-until-digest_time (brittle across clock changes / pref edits), we
wake on a short tick and ask "is it time yet?" — the per-day idempotency guard in
NotificationService.build_and_send_digest() ensures at most one digest per day
even though the tick may fire many times within the digest minute.

Constitution refs:
  P2 — Ambient: the digest is a single summary notification, never a sound alert.
  P4 — Configurable: digest_time is read from preferences each tick, so editing it
        takes effect without a restart.
"""

import logging
import threading
from datetime import datetime, time, timezone
from typing import Optional

from notifications.service import NotificationService

log = logging.getLogger(__name__)

DEFAULT_DIGEST_TIME = "09:00"
# How often to check whether the digest time has arrived. 60s is fine: the
# idempotency guard prevents duplicate sends within the firing minute.
TICK_SECONDS = 60.0


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _parse_hhmm(s: str) -> Optional[time]:
    try:
        h, m = s.strip().split(":")
        return time(int(h), int(m))
    except (ValueError, AttributeError):
        return None


class DigestScheduler:
    """
    Fires the daily digest at digest_time.

    Args:
        connection_factory: callable() -> sqlite3.Connection (the scheduler thread
                            gets its own; SQLite connections aren't thread-safe).
        service_factory: callable(conn) -> NotificationService. Injected for tests;
                         defaults to a real NotificationService.
        clock: callable() -> datetime (UTC, local-aware via astimezone). Injected
               for tests.
        tick_seconds: poll interval; override (small) for tests.
    """

    def __init__(self, connection_factory, *, service_factory=None, clock=None,
                 tick_seconds: float = TICK_SECONDS):
        self._connection_factory = connection_factory
        self._service_factory = service_factory or (lambda conn: NotificationService(conn))
        self._clock = clock or _now
        self._tick = tick_seconds
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        self._thread = threading.Thread(
            target=self._run, name="digest-scheduler", daemon=True)
        self._thread.start()
        log.info("Digest scheduler started")

    def stop(self, timeout: float = 10.0) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=timeout)
        log.info("Digest scheduler stopped")

    def _run(self) -> None:
        conn = self._connection_factory()
        try:
            while not self._stop.is_set():
                try:
                    self.maybe_fire(conn)
                except Exception:
                    # A digest failure must never kill the scheduler thread.
                    log.exception("Digest tick failed (ignored)")
                self._stop.wait(timeout=self._tick)
        finally:
            conn.close()

    def maybe_fire(self, conn) -> bool:
        """
        Fire the digest if the current local time has reached today's digest_time
        and it hasn't already gone out today. Returns True if a digest was sent.

        "Reached" means current time is within the same minute as digest_time, or
        later in the day — combined with the once-per-day guard, a scheduler that
        starts up after digest_time still sends today's digest (catch-up), exactly
        once. Returns False on a day where it already fired or there's nothing to send.
        """
        target = _parse_hhmm(self._digest_time_pref(conn))
        if target is None:
            log.warning("Invalid digest_time pref; skipping digest tick")
            return False

        now_t = self._clock().astimezone().time()
        if now_t < target:
            return False  # not time yet today

        service = self._service_factory(conn)
        result = service.build_and_send_digest()
        return result.sent

    def _digest_time_pref(self, conn) -> str:
        row = conn.execute(
            "SELECT value FROM preferences WHERE key = 'digest_time'"
        ).fetchone()
        return row["value"] if row else DEFAULT_DIGEST_TIME