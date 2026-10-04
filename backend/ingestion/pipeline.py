"""
thresher ingestion pipeline
Wires IMAP polling → queue.Queue → classification → SQLite persistence.

Architecture (replaces the Redis/queue design in plan.md — this is a single-user
local tool, so an in-process queue.Queue is the right weight; see project-log
Session 3 "over-engineered choices"):

    ┌────────────┐   Message    ┌─────────────┐   Classification   ┌─────────┐
    │  Producer  │ ───────────▶ │ queue.Queue │ ─────────────────▶ │Consumer │──▶ SQLite
    │ (IMAP poll)│              └─────────────┘                    │(classify)│
    └────────────┘

The producer runs the IMAP poll on an interval (preferences.poll_interval_minutes)
and enqueues parsed Messages. The consumer drains the queue, persists each Message
(insert-only, P1), runs the ClassificationEngine, and upserts the Classification
with its rule_matches audit trail (P3).

Both run on daemon threads coordinated by a threading.Event for graceful shutdown.

Constitution refs:
  P1 — Never drop: messages are persisted before classification; a classification
        failure never discards the stored message. Insert is idempotent (dedup).
  P3 — Transparent: the full rule_matches audit trail is stored with each result.
  P4 — Configurable: poll interval comes from the preferences table.
"""

import imaplib
import logging
import queue
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

from db.database import (
    Classification,
    ClassificationRepo,
    Message,
    MessageRepo,
    PreferencesRepo,
    RulesRepo,
)
from classification.engine import ClassificationEngine, MessageEnvelope
from ingestion.imap_client import GmailImapClient, imap_date_floor, ImapCursor, ImapError
from ingestion.keychain import KeychainError

log = logging.getLogger(__name__)


def _before(received_at: str, cutoff: datetime) -> bool:
    """True iff a message's timestamp is strictly older than the cutoff.

    A message whose timestamp cannot be parsed is treated as NOT older, i.e. it
    is retrieved. P1 direction: when in doubt, keep the mail. Dropping it on an
    unreadable Date header would be a silent loss with no way to notice.
    """
    try:
        dt = datetime.fromisoformat(received_at.replace("Z", "+00:00"))
    except (TypeError, ValueError, AttributeError):
        return False
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt < cutoff

# Sentinel pushed onto the queue to tell the consumer to stop after draining.
_SHUTDOWN = object()

DEFAULT_POLL_INTERVAL_MINUTES = 5
MAX_FETCH_RETRIES = 3
RETRY_BACKOFF_BASE_SECONDS = 5

# Consumer-side progress cadence (gate-defects Part D): one INFO line per this
# many processed messages, so a long backfill's store/dedup counts are visible
# from the console — "working" and "hung" must be distinguishable.
PROGRESS_LOG_EVERY = 50

# ── Per-account poll heartbeat (Session 34) ─────────────────────────────────
# Preference key holding "when did this account last complete a poll, and how
# did it go": `poll_heartbeat:<account>` → "<iso8601>|<ok|error|stopped>|<detail>".
#
# WHY A HEARTBEAT AND NOT AN ERROR FLAG: the poller and the API are separate
# processes, so the API cannot read a pipeline's in-memory `fatal_error`. More
# importantly, the failure that actually happened in the alpha wrote NOTHING —
# the process died outright. A design that only records errors stays silent in
# exactly that case. So the poller records LIVENESS and the API reports
# staleness: silence reads as broken, which is the fail-safe direction.
#
# Same idiom as D45's `notification_delivery_owner_until` short-TTL claim: a
# writer that stops writing lapses, and the reader notices without being told.
POLL_HEARTBEAT_KEY_PREFIX = "poll_heartbeat:"


# Preference key an immediate-poll request is written to (by POST /accounts) and
# read from (by the producer, below).
#
# DEFINED HERE, NOT IMPORTED FROM api.app: the poller must not import the API
# module — they are separate processes and that dependency would drag Flask into
# the poller's import graph. The store is the only thing they share, which is
# the point of using it as the channel. `backend/tests/test_pipeline.py` pins
# that both sides use the same literal.
POLL_REQUESTED_KEY = "poll_requested_at"


def poll_heartbeat_key(account: str) -> str:
    return f"{POLL_HEARTBEAT_KEY_PREFIX}{account}"


@dataclass
class PipelineStats:
    """Lightweight counters, handy for tests and logging/observability."""
    polls: int = 0
    enqueued: int = 0
    persisted: int = 0        # newly stored rows only (dedup counted separately)
    deduped: int = 0          # already-stored ids skipped by INSERT OR IGNORE
    fetch_skipped: int = 0    # UIDs the fetch pass skipped (timeout/no-data)
    backfill_silenced: int = 0  # D62/OI26: ingested during backfill, no banner
    classified: int = 0
    errors: int = 0


def to_envelope(msg: Message) -> MessageEnvelope:
    """Adapt a stored Message into the lighter envelope the engine consumes."""
    return MessageEnvelope(
        id=msg.id,
        sender_email=msg.sender_email,
        sender_name=msg.sender_name,
        subject=msg.subject,
        body_plain=msg.body_plain,
    )


class IngestionPipeline:
    """
    Orchestrates the producer and consumer threads.

    The pipeline owns its own DB connections per thread: SQLite connections are
    not safe to share across threads, so the producer and consumer each get one.
    The connection factory is injected so tests can hand in in-memory databases.
    """

    def __init__(
        self,
        account: str,
        connection_factory,
        *,
        client_factory=None,
        poll_interval_seconds: Optional[float] = None,
        on_classified=None,
    ):
        """
        Args:
            account: mailbox to poll (also the keychain account).
            connection_factory: callable() -> sqlite3.Connection. Called once per
                                thread so each thread has its own connection.
            client_factory: callable(account) -> GmailImapClient-like. Injected
                            for testing; defaults to a real GmailImapClient.
            poll_interval_seconds: override the DB-configured poll interval (mainly
                                   for tests). If None, read from preferences.
            on_classified: optional callable(conn, message_id, result) invoked on
                           the consumer thread after a message is classified+stored.
                           Used to trigger notifications without coupling the
                           pipeline to the notification service. Errors are
                           swallowed (a notification failure must not affect
                           ingestion). Runs on the consumer's own connection.
        """
        self.account = account
        self._connection_factory = connection_factory
        self._client_factory = client_factory or (lambda acct: GmailImapClient(acct))
        self._poll_interval_override = poll_interval_seconds
        # The interval this producer is ACTUALLY using, published on every
        # heartbeat so the health check derives its expectation from the
        # behaviour it is checking rather than from the stored preference. The
        # two used to be read from different places, so any interval change
        # produced a permanent false 'stale' until restart (B2, 2026-09-06).
        self._effective_interval_seconds: Optional[float] = None
        self._on_classified = on_classified

        self.queue: "queue.Queue" = queue.Queue()
        self.cursor = ImapCursor()
        # Lazily seeded from the store on the first poll (gate-defects Part C):
        # without this, every process start re-downloads the entire mailbox
        # above UID 0 and relies on dedup.
        self._cursor_seeded = False
        # D62/OI26/OI30: whether a message is part of the initial backfill
        # travels WITH the message, as a `(Message, is_backfill)` queue item —
        # it is not shared mutable state.
        #
        # It used to be a flag set by the producer and cleared by the consumer on
        # `queue.empty()`, and that could not be made correct: an empty queue
        # means "the consumer has caught up", NOT "the batch is over". A consumer
        # faster than the producer empties the queue MID-BATCH, clears the flag,
        # and every remaining message notifies — the exact burst D62 exists to
        # prevent (OI30). Tagging each item makes the invariant structural rather
        # than timing-dependent: no interleaving of the two threads can change
        # what a given message decides.
        #
        # Kept only for the log line and the completion count, never read to
        # decide whether to notify.
        self._backfill_pending = 0
        # OI15: the persisted-epoch arm happens once per process (like the
        # cursor seed); fetch_new keeps the cursor's epoch live afterwards.
        self._epoch_seeded = False
        self.stats = PipelineStats()

        self._stop = threading.Event()
        # Set whenever a new poll batch is enqueued; the consumer rebuilds its
        # ClassificationEngine from the DB before processing the next item so that
        # rule / sender-group edits made via the API take effect on the next poll
        # without a restart (P4 — config is live, not frozen at startup). See
        # _run_consumer. Set up front so the very first batch builds a fresh engine.
        self._reload_engine = threading.Event()
        self._reload_engine.set()
        self._producer_thread: Optional[threading.Thread] = None
        self._consumer_thread: Optional[threading.Thread] = None
        # Set if the pipeline self-terminated on a permanent error (e.g. a missing
        # Keychain credential). Callers can inspect this to choose an exit code.
        self.fatal_error: Optional[Exception] = None

    # ── public lifecycle ─────────────────────────────────────────────────────

    def start(self) -> None:
        """Launch the producer and consumer threads."""
        self._producer_thread = threading.Thread(
            target=self._run_producer, name="ingest-producer", daemon=True
        )
        self.start_consumer_only()
        self._producer_thread.start()
        log.info("Ingestion pipeline started for %s", self.account)

    def start_consumer_only(self) -> None:
        """
        Launch just the consumer thread, leaving polling to the caller.

        Used by single-shot mode (main.py --once), where the caller drives one
        manual poll via poll_once() rather than running the interval-based
        producer loop. Avoids a redundant second poll racing the manual one.
        """
        self._consumer_thread = threading.Thread(
            target=self._run_consumer, name="ingest-consumer", daemon=True
        )
        self._consumer_thread.start()

    def stop(self, *, drain: bool = True, timeout: float = 30.0) -> None:
        """
        Signal both threads to stop and wait for them to finish.

        Args:
            drain: if True, let the consumer finish processing whatever is already
                   queued before exiting (default). If False, stop ASAP.
            timeout: max seconds to wait per thread join.
        """
        self._stop.set()
        if self._producer_thread is not None:
            self._producer_thread.join(timeout=timeout)
        # Tell the consumer to stop after draining the current backlog.
        self.queue.put(_SHUTDOWN)
        if self._consumer_thread is not None:
            self._consumer_thread.join(timeout=timeout)
        log.info("Ingestion pipeline stopped for %s (stats=%s)", self.account, self.stats)

    def wait_until_stopped(self, timeout: Optional[float] = None) -> bool:
        """
        Block until the pipeline's stop event is set (by stop() or by the producer
        self-terminating on a fatal error). Returns True if stopped, False on
        timeout. Lets a long-lived caller wake when the pipeline dies on its own.
        """
        return self._stop.wait(timeout=timeout)

    def poll_once(self, conn) -> int:
        """
        Run a single IMAP poll synchronously and enqueue results. Returns the
        number of messages enqueued. Used by the producer loop and directly by
        tests. Retries transient IMAP failures with exponential backoff.
        """
        if not self._cursor_seeded:
            self._seed_cursor(conn)
        attempt = 0
        while True:
            try:
                client = self._client_factory(self.account)
                mailbox = getattr(client, "mailbox", "INBOX")
                # OI15: arm the cursor with the persisted epoch BEFORE fetching,
                # so fetch_new's mismatch check covers cross-run rolls too.
                self._seed_epoch(conn, mailbox)
                # ── D61: the retrieval window applies to BACKFILL ONLY ───────
                #
                # THIS ASYMMETRY IS DELIBERATE. Do not "fix" it by filtering
                # every poll.
                #
                # The window exists so connecting an account doesn't drag in
                # years of mail that stopped being actionable long ago. A gap
                # since the last poll is a different situation: recent, small,
                # and possibly still needing a response. Filtering it would mean
                # closing the app for a week could permanently hide an urgent
                # message — the exact failure this app exists to prevent — and
                # because the window cannot be widened later, that mail would be
                # unrecoverable.
                #
                # Staleness is handled where it belongs: the D57 recency-banded
                # sort ranks a nine-day-old message below today's mail rather
                # than hiding it.
                #
                # Mechanically: `cutoff` is non-None ONLY on the first fetch for
                # an account with no stored mail. Once anything is ingested,
                # `_seed_cursor` gives a non-zero UID and the window is never
                # consulted again. See docs/BEHAVIOR.md, "The retrieval window
                # applies to setup only".
                # D62/OI26: "is this a backfill?" is derived from the SAME
                # condition the retrieval window uses — an empty cursor — so
                # the window and the silence can never disagree about which
                # batch is the initial one.
                is_backfill = self.cursor.last_uid == 0
                raw_cutoff = self._backfill_cutoff(conn)
                cutoff = self._parse_cutoff(raw_cutoff)
                # Narrow SERVER-SIDE as well, so mail outside the window is never
                # downloaded. Previously the window was enforced only by the
                # `_before()` check below: on a real cold start that meant
                # fetching 1,588 messages to keep 15, and 6.3 minutes of silence.
                # `imap_date_floor` rounds DOWN, so this can only ever fetch a
                # little too much — `_before()` remains the exact boundary and
                # must not be removed.
                since = imap_date_floor(raw_cutoff) if raw_cutoff else None
                enqueued = 0
                skipped_by_window = 0
                with client:
                    for msg in client.fetch_new(self.cursor, since=since):
                        if cutoff is not None and _before(msg.received_at, cutoff):
                            # P1 note: this is "never retrieved", not "deleted".
                            # The mail is untouched on the server and readable in
                            # any other client; this app simply never copies it.
                            skipped_by_window += 1
                            continue
                        # The tag rides with the message (OI30). Whether this
                        # message notifies is decided HERE, by the producer that
                        # knows which batch it belongs to — not later, by a
                        # consumer inferring it from queue depth.
                        self.queue.put((msg, is_backfill))
                        if is_backfill:
                            self._backfill_pending += 1
                        enqueued += 1
                        self.stats.enqueued += 1
                if skipped_by_window:
                    log.info(
                        "Retrieval window for %s: %d message(s) older than %s "
                        "were not retrieved (backfill only; later polls are "
                        "never filtered)",
                        self.account, skipped_by_window, cutoff)
                # OI15: fetch_new stamped the LIVE epoch on the cursor — persist
                # it so the next process start can detect a roll.
                self._persist_epoch(conn, mailbox)
                # Record fetch-pass skips (Part B/D): UIDs the client had to
                # skip (repeated timeout / no data) — loud in its logs, counted
                # here so the poll summary carries them too.
                skipped = len(getattr(client, "last_poll_skipped_uids", []) or [])
                self.stats.fetch_skipped += skipped
                self.stats.polls += 1
                log.info("Poll complete for %s: %d enqueued, %d fetch-skipped "
                         "(cursor now at UID %d)",
                         self.account, enqueued, skipped, self.cursor.last_uid)
                # Session 34: stamp liveness for this account. Written BEFORE
                # the engine-reload signal so the extra commit stays off the
                # seam between "producer enqueued the batch" and "consumer
                # drains it" — the D62 backfill flag clears on an empty queue,
                # and latency introduced there widens that race.
                self._record_heartbeat(conn, "ok")
                # Refresh the classifier from the DB before this batch is processed,
                # so rule/sender-group edits since the last poll are applied (P4).
                self._reload_engine.set()
                return enqueued
            # OSError (TimeoutError, ConnectionReset, …) and IMAP4.abort are
            # caught ALONGSIDE ImapError deliberately (Session 34). The client
            # is expected to convert transient network faults into ImapError,
            # and now does — but a single uncovered call site raising a bare
            # OSError used to escape this handler and permanently kill the
            # account's producer thread. A network error is transient by
            # nature; this loop's bounded backoff is the right owner for ALL of
            # them, so the catch is widened rather than left to enumerate every
            # call site correctly forever. Genuinely fatal config errors
            # (KeychainError) are not OSErrors and still propagate.
            except (ImapError, imaplib.IMAP4.abort, OSError) as exc:
                attempt += 1
                self.stats.errors += 1
                if attempt >= MAX_FETCH_RETRIES:
                    log.error("IMAP poll failed after %d attempts: %s", attempt, exc)
                    # Record the failure, then keep polling. An exhausted poll
                    # is not fatal — the next tick may well succeed — but the
                    # user should be able to SEE that this mailbox is failing
                    # rather than infer it from an inbox that stopped growing.
                    self._record_heartbeat(conn, "error", f"{type(exc).__name__}: {exc}")
                    return 0
                backoff = RETRY_BACKOFF_BASE_SECONDS * (2 ** (attempt - 1))
                log.warning("IMAP poll failed (attempt %d/%d): %s; retrying in %ds",
                            attempt, MAX_FETCH_RETRIES, exc, backoff)
                # Use the stop event as an interruptible sleep.
                if self._stop.wait(timeout=backoff):
                    return 0

    def _record_heartbeat(self, conn, status: str, detail: str = "") -> None:
        """
        Stamp "<iso>|<status>|<detail>|<effective_interval_seconds>".

        The 4th field (Session 38, B2) is the interval this producer is actually
        using. The health check reads it instead of the stored preference: those
        were two different sources for one fact, so changing the setting made
        them disagree and every account went permanently 'stale' until restart.
        Older stamps have three fields and the checker falls back to the pref.

        Best-effort and never raises: a heartbeat is diagnostics, and failing a
        poll because the diagnostics write failed would be strictly worse than
        the blind spot it exists to close.
        """
        try:
            stamp = datetime.now(timezone.utc).isoformat()
            detail = " ".join(detail.split())[:200]   # one line, bounded
            interval = self._effective_interval_seconds
            if interval is None:
                # Not yet resolved (a bare poll_once, e.g. --once or a test).
                interval = self._read_poll_interval(conn)
            PreferencesRepo(conn).set(
                poll_heartbeat_key(self.account),
                f"{stamp}|{status}|{detail}|{interval:.0f}")
        except Exception:
            log.debug("Could not record poll heartbeat for %s",
                      self.account, exc_info=True)

    def _seed_cursor(self, conn) -> None:
        """
        Seed the in-memory IMAP cursor from the store (gate-defects Part C):
        start above the max ingested UID for this account instead of 0, so a
        poll fetches only genuinely new mail rather than re-downloading the
        whole mailbox and grinding through dedup.

        The UIDVALIDITY caveat this used to carry is CLOSED (OI15): the epoch
        is persisted per (account, mailbox) as preference
        `uidvalidity:<account>:<mailbox>` and armed onto the cursor before the
        first fetch (`_seed_epoch`), so fetch_new's mismatch check — reset to
        0 + full re-scan — now fires across process runs, not just within one.
        On a true roll the re-scan DUPLICATES old mail (new uids → new
        {account}:{uid} PKs) rather than deduping — no loss, the P1-safe
        direction; OI17 tracks Message-ID-keyed dedup if a roll is observed.
        """
        last = MessageRepo(conn).max_uid_for_account(self.account)
        if last > self.cursor.last_uid:
            self.cursor.last_uid = last
        self._cursor_seeded = True
        log.info("Cursor seeded from store for %s: resuming above UID %d",
                 self.account, self.cursor.last_uid)

    # ── Retrieval window (D61) ───────────────────────────────────────────────

    @staticmethod
    def _parse_cutoff(raw: Optional[str]):
        """Parse the stored cutoff to a datetime, or None.

        Compared as DATETIMES, never as strings. `parse_received_at` normalises
        every stored timestamp to UTC so a text compare would *happen* to work
        today — but D57 hit the text-compare trap twice at the SQL layer, and a
        comparison that is only accidentally correct is one refactor away from
        silently skipping mail. An unparseable stored value degrades to None
        (retrieve everything) rather than dropping mail on a bad string.
        """
        if raw is None:
            return None
        try:
            dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        except (TypeError, ValueError):
            log.warning("Unparseable retrieval cutoff %r — retrieving everything", raw)
            return None
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)

    def _backfill_cutoff(self, conn) -> Optional[str]:
        """The ISO-8601 cutoff for THIS poll, or None to retrieve everything.

        Returns a bound **only during backfill** — i.e. only when this account
        has no stored mail yet. That single condition is what implements the
        whole backfill-only rule, so it is worth stating plainly:

          - Nothing stored  ⇒ this is the first fetch after connecting ⇒ the
            user's chosen window applies.
          - Anything stored ⇒ the cursor resumes above a real UID ⇒ return None,
            and every message the server offers is retrieved regardless of age.

        Deriving "is this a backfill?" from the store rather than a flag means
        there is no state to get out of sync, and a crash mid-backfill simply
        resumes as a backfill (the cutoff is stored, not recomputed, so the
        boundary doesn't drift on a retry).

        The cutoff is resolved to a DATE at connect time and stored per account
        (`retrieval_cutoff:<account>`), never recomputed from "N days ago" —
        otherwise the boundary would slide forward on every poll and mail would
        fall out of range while sitting in the queue.

        No stored preference ⇒ None ⇒ retrieve everything. That is the historic
        behaviour and the safe default: an account connected before this feature
        existed must not suddenly start skipping mail.
        """
        if self.cursor.last_uid > 0:
            return None
        raw = PreferencesRepo(conn).get(f"retrieval_cutoff:{self.account}")
        if raw is None or not raw.strip():
            return None
        return raw.strip()

    # ── UIDVALIDITY epoch persistence (OI15) ─────────────────────────────────

    def _epoch_pref_key(self, mailbox: str) -> str:
        return f"uidvalidity:{self.account}:{mailbox}"

    def _seed_epoch(self, conn, mailbox: str) -> None:
        """
        Arm the cursor with the persisted UIDVALIDITY epoch (once per process).
        A bare max-UID cursor is only valid within the epoch it was ingested
        under; with the stored epoch on the cursor, a roll between runs makes
        fetch_new reset to 0 and re-scan (loud ERROR there) instead of silently
        skipping mail above a stale-epoch UID — the P1-class risk OI15 named.
        """
        if self._epoch_seeded:
            return
        self._epoch_seeded = True
        stored = PreferencesRepo(conn).get(self._epoch_pref_key(mailbox))
        if stored is None:
            return   # first run with epoch tracking; recorded after the poll
        try:
            self.cursor.uidvalidity = int(stored)
        except ValueError:
            log.warning("Ignoring malformed stored UIDVALIDITY %r for %s:%s",
                        stored, self.account, mailbox)

    def _persist_epoch(self, conn, mailbox: str) -> None:
        """Record the live epoch fetch_new stamped on the cursor (post-poll)."""
        live = self.cursor.uidvalidity
        if live is None:
            return
        prefs = PreferencesRepo(conn)
        key = self._epoch_pref_key(mailbox)
        stored = prefs.get(key)
        if stored == str(live):
            return
        prefs.set(key, str(live))
        if stored is None:
            log.info("Recorded UIDVALIDITY %d for %s:%s (first run with epoch "
                     "tracking; no rescan)", live, self.account, mailbox)
        else:
            log.info("Stored UIDVALIDITY for %s:%s updated %s → %d after the "
                     "roll was handled", self.account, mailbox, stored, live)

    # ── producer ───────────────────────────────────────────────────────────

    def _run_producer(self) -> None:
        conn = self._connection_factory()
        interval = self._resolve_poll_interval(conn)
        log.info("Producer polling every %.0fs", interval)

        # Clear any pending immediate-poll request BEFORE the first poll.
        #
        # This process is starting, so it is about to poll anyway — the request
        # is already satisfied by the poll below, and leaving the row set would
        # make the FIRST wait get skipped for no reason, polling twice in
        # succession.
        #
        # ⚠️ WHY THIS LINE EXISTS AT ALL: the request was previously consumed
        # only at the END of a cycle, which is wrong for exactly the case it was
        # built for. On first run the poller is NOT running when the user
        # connects (it exits EXIT_NOT_CONFIGURED while unconfigured), so there
        # is no loop waiting on the flag; the supervisor relaunches it up to 30s
        # later, and only then is the row read — after a full poll had already
        # happened. The row SURVIVED, which is what "durable" guarantees, but it
        # was not SEEN in time. Durability answers "is it lost", not "when is it
        # noticed", and those were conflated. See the decision-log entry.
        self._consume_poll_request(conn)
        try:
            while not self._stop.is_set():
                # Re-read the interval EVERY pass, the same reload-per-poll model
                # as the rules engine (E11/D37) and the account registry (OI25),
                # so "changes take effect on the next poll" stays one mental
                # model rather than three.
                #
                # Read BEFORE the poll so the heartbeat this poll writes carries
                # the interval the producer is ABOUT TO SLEEP ON. Reading after
                # would stamp the OLD value and then sleep on the new one, so
                # widening 1 min -> 15 min would leave health expecting a beat
                # every minute for the whole 15-minute sleep — the same false
                # stale, just in the other direction.
                previous, interval = interval, self._resolve_poll_interval(conn)
                if interval != previous:
                    # Logged on CHANGE, not only at startup: the one line that
                    # made the 2026-09-06 cadence bug diagnosable appeared once
                    # per process lifetime.
                    log.info("Poll interval changed %.0fs → now polling every %.0fs",
                             previous, interval)
                self.poll_once(conn)
                # A connect asks for an immediate poll rather than a wait of up
                # to `interval`. Consumed here (one-shot): the row is cleared so
                # a single connect cannot cause repeated tight polling.
                if self._consume_poll_request(conn):
                    log.info("Immediate poll requested (account connected) — "
                             "not waiting %.0fs", interval)
                    continue
                # Interruptible wait: wakes immediately on stop().
                self._stop.wait(timeout=interval)
        except KeychainError as exc:
            # Permanent config error (no/invalid App Password). Retrying can't
            # help, so record it and signal a clean shutdown rather than leaving
            # a half-running pipeline with a dead producer.
            log.error("Producer stopping — cannot authenticate to Gmail: %s", exc)
            self.fatal_error = exc
            self.stats.errors += 1
            self._record_heartbeat(conn, "stopped", f"{type(exc).__name__}: {exc}")
            self._stop.set()
        except Exception as exc:
            log.exception("Producer thread crashed")
            self.fatal_error = exc
            self.stats.errors += 1
            # Leave a marker BEFORE the thread dies. Without this an account
            # that stops polling is indistinguishable from one with no new
            # mail — which is how the alpha ran 17 hours with a dead Gmail
            # pipeline and no indication anywhere in the UI.
            self._record_heartbeat(conn, "stopped", f"{type(exc).__name__}: {exc}")
            self._stop.set()
        finally:
            conn.close()

    def _consume_poll_request(self, conn) -> bool:
        """True if a poll was explicitly requested; clears the request.

        Written by `POST /accounts` when a mailbox is connected, because a user
        who has just typed a password is watching the screen and a wait of up to
        the poll interval reads as nothing happening.

        CLEARED ON READ, so the request is one-shot. Leaving it set would make
        the producer spin: it would see the row on every pass and never wait.

        Best-effort and never raises — an immediate poll is an optimisation, and
        failing to read a preference must not stop the loop that fetches mail.
        """
        try:
            prefs = PreferencesRepo(conn)
            if not prefs.get(POLL_REQUESTED_KEY):
                return False
            prefs.set(POLL_REQUESTED_KEY, "")
            return True
        except Exception:
            log.debug("Could not read the immediate-poll request", exc_info=True)
            return False

    def _resolve_poll_interval(self, conn) -> float:
        """The interval to sleep after this pass, and the value published on the
        heartbeat so the health check and the producer cannot disagree."""
        interval = self._read_poll_interval(conn)
        self._effective_interval_seconds = interval
        return interval

    def _read_poll_interval(self, conn) -> float:
        if self._poll_interval_override is not None:
            return self._poll_interval_override
        prefs = PreferencesRepo(conn)
        raw = prefs.get("poll_interval_minutes", str(DEFAULT_POLL_INTERVAL_MINUTES))
        try:
            return float(raw) * 60.0
        except (TypeError, ValueError):
            log.warning("Invalid poll_interval_minutes=%r; using default", raw)
            return DEFAULT_POLL_INTERVAL_MINUTES * 60.0

    # ── consumer ───────────────────────────────────────────────────────────

    def _run_consumer(self) -> None:
        conn = self._connection_factory()
        msg_repo = MessageRepo(conn)
        cls_repo = ClassificationRepo(conn)
        engine = self._build_engine(conn)
        try:
            while True:
                item = self.queue.get()
                try:
                    if item is _SHUTDOWN:
                        return
                    # (Message, is_backfill) — the silence decision travels with
                    # the message (OI30), so it cannot be changed by how the two
                    # threads happen to interleave.
                    msg, is_backfill = item
                    # Reload-per-poll (P4): if a poll batch arrived since we last
                    # rebuilt, refresh the engine from the DB so rule/sender-group
                    # edits made via the API are live without a restart. The flag is
                    # checked-and-cleared so one rebuild covers the whole batch.
                    if self._reload_engine.is_set():
                        self._reload_engine.clear()
                        engine = self._build_engine(conn)
                        log.debug("Reloaded classification engine from DB (rules/groups refresh)")
                    self._process(msg, msg_repo, cls_repo, engine, conn,
                                  is_backfill=is_backfill)
                finally:
                    self.queue.task_done()
        except Exception:
            log.exception("Consumer thread crashed")
            self.stats.errors += 1
        finally:
            conn.close()

    def _build_engine(self, conn) -> ClassificationEngine:
        rules_repo = RulesRepo(conn)
        return ClassificationEngine(
            rules=rules_repo.all_enabled(),
            sender_groups=rules_repo.all_sender_groups(),
        )

    def _process(self, msg: Message, msg_repo, cls_repo, engine, conn=None,
                 *, is_backfill: bool = False) -> None:
        """
        Persist a message, classify it, and persist the classification.

        P1: the message is stored FIRST and unconditionally — even if
        classification later throws, the message is durably saved and can be
        re-classified. Insert is idempotent (INSERT OR IGNORE) so a re-delivered
        message doesn't duplicate.
        """
        try:
            if msg_repo.insert(msg):
                self.stats.persisted += 1
            else:
                self.stats.deduped += 1
        except Exception:
            log.exception("Failed to persist message %s; dropping from this pass", msg.id)
            self.stats.errors += 1
            return  # nothing classified yet, so nothing inconsistent is stored

        # Progress observability (Part D): during a big backfill (or a dedup
        # grind) show movement every N messages — one line per batch. Without
        # this, "working" and "hung" look identical from the console.
        processed = self.stats.persisted + self.stats.deduped
        if processed % PROGRESS_LOG_EVERY == 0:
            log.info("Ingest progress: %d processed — %d stored new, "
                     "%d dedup-skipped, %d classified, %d errors",
                     processed, self.stats.persisted, self.stats.deduped,
                     self.stats.classified, self.stats.errors)

        try:
            result = engine.classify(to_envelope(msg))
            cls_repo.upsert(Classification(
                message_id=msg.id,
                urgency_tier=result.urgency_tier,
                category=result.category,
                triage_state="new",
                classified_at=result.classified_at,
                rule_matches=result.rule_matches,
            ))
            self.stats.classified += 1
            log.debug("Processed %s → tier=%d category=%s",
                      msg.id, result.urgency_tier, result.category)
        except Exception:
            # Message is already safely stored (P1); classification can be retried
            # later. We log loudly rather than crash the consumer.
            log.exception("Classification failed for %s; message is stored, will retry later", msg.id)
            self.stats.errors += 1
            return

        # Fire the post-classification hook (e.g. notifications). A failure here
        # must never affect ingestion, so swallow and log.
        #
        # D62/OI26 — BACKFILL IS SILENT, AT EVERY TIER.
        #
        # The first thing a new user does is connect an account. Without this,
        # setup ends in a burst of banners: connecting `you@example.org`
        # found 3,311 messages and fired one notification per Tier 1/2 hit —
        # 214 in a single burst (Session 30).
        #
        # This is NOT a general widening of notification suppression, and the
        # distinction matters because it touches the Tier 1 invariant. A Tier 1
        # message arriving on a normal poll still fires, exactly as before.
        # Suppression is scoped to the initial backfill batch — mail the user
        # has never seen the app without, arriving all at once, none of which
        # is "new" in the sense a banner means. Nothing is lost: every
        # suppressed message is stored, classified, tiered, and sitting at the
        # top of the list when the user first opens it.
        if is_backfill:
            # OI30: decided by the tag this message carries, never by shared
            # state read at processing time. The producer knew which batch this
            # belonged to; nothing the consumer observes later can revise that.
            self.stats.backfill_silenced += 1
            self._backfill_pending -= 1
            if self._backfill_pending == 0:
                # Purely a log line now — a miscount can no longer let a message
                # notify, because the decision was already made per message.
                log.info("Backfill complete for %s: %d message(s) ingested "
                         "silently (D62/OI26 — no per-message notifications)",
                         self.account, self.stats.backfill_silenced)
        elif self._on_classified is not None:
            try:
                self._on_classified(conn, msg.id, result)
            except Exception:
                log.exception("on_classified hook failed for %s (ignored)", msg.id)