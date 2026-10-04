"""
thresher Gmail IMAP client
Connects to Gmail over IMAP (SSL) using an App Password from the Keychain,
and fetches new messages since the last seen UID.

Auth (CLAUDE.md / D26): IMAP + App Password (OAuth 2.0 deferred). The password
is never passed in by the caller — it is pulled from the Keychain here.

We track progress by IMAP UID (per the UIDVALIDITY/UID contract): each poll asks
the server for messages with UID greater than the last one we saw, so we never
re-fetch the whole mailbox. Gmail's UIDs are stable as long as UIDVALIDITY is
unchanged; if the server reports a new UIDVALIDITY we reset and re-sync.

Constitution refs:
  P1 — Never drop: a fetch/parse failure for one message must not abort the poll
        or skip subsequent messages.
"""

import imaplib
import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterator, Optional, Tuple

from ingestion.keychain import get_gmail_app_password, KeychainError
from ingestion.parser import parse_message
from db.database import Message

log = logging.getLogger(__name__)

GMAIL_IMAP_HOST = "imap.gmail.com"
GMAIL_IMAP_PORT = 993

# Socket timeout for the IMAP connection (gate-defects Part B). Without one, a
# dead connection blocks forever in socket.recv_into and the poll can't tell
# dead from slow (the Session-23 backfill stalled at 1,368/1,386 exactly this
# way). 60s is generous for a single large message over a slow link while still
# bounding a dead read to something a human (and a log) can see.
IMAP_SOCKET_TIMEOUT_SECONDS = 60

# Per-message fetch budget: on a timeout/connection abort we reconnect and
# retry the same UID up to this many attempts before skipping it loudly.
FETCH_ATTEMPTS_PER_MESSAGE = 3

# Per-poll SELECT/STATUS budget (Session 34). The pair that opens every poll
# gets the same transient treatment as a message fetch; on exhaustion the
# failure is raised as ImapError so the pipeline's poll-level backoff owns it
# rather than the producer thread dying. See _select_mailbox_with_retry.
SELECT_ATTEMPTS_PER_POLL = 3

# Fetch-progress cadence (gate-defects Part D): one INFO line per this many
# UIDs so a long backfill is visibly working, not one line per message.
FETCH_PROGRESS_EVERY = 50


@dataclass
class ImapCursor:
    """Where we are in the mailbox, so polls are incremental."""
    uidvalidity: Optional[int] = None
    last_uid: int = 0


class ImapError(RuntimeError):
    """Raised on connection/auth/protocol failures we can't recover from in-line."""


def imap_date_floor(cutoff_iso: str) -> Optional[str]:
    """An IMAP SINCE date for an ISO-8601 cutoff, ROUNDED DOWN to the day.

    IMAP SINCE is date-granular and matches messages on-or-after that date, in
    the server's own timezone reckoning. Our cutoff is an exact instant. Those
    two cannot align, so the rounding direction is a safety decision rather than
    a formatting detail:

      ROUND DOWN  → the server may return mail slightly OLDER than the cutoff,
                    which `_before()` then discards. Cost: a few extra fetches.
      round up    → the server may WITHHOLD mail inside the window, which no
                    later check can recover, because it was never downloaded.

    A window bug that loses mail is far worse than one that fetches a few extra
    messages, so this always errs toward fetching too much. It subtracts a
    further full day before truncating, so a cutoff at 00:30 UTC cannot exclude
    mail that the server dates to the previous day in its own timezone.

    Returns None when the cutoff is unparseable — the caller then does no
    server-side narrowing at all, which is slow but never lossy.
    """
    try:
        parsed = datetime.fromisoformat(cutoff_iso)
    except (TypeError, ValueError):
        log.warning("Unparseable retrieval cutoff %r; fetching without a "
                    "server-side date filter (slower, never lossy)", cutoff_iso)
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    floor = parsed.astimezone(timezone.utc) - timedelta(days=1)
    # IMAP wants "07-Sep-2026" with an English month abbreviation, independent
    # of locale — hence the explicit table rather than strftime("%b").
    months = ("Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
    return f"{floor.day:02d}-{months[floor.month - 1]}-{floor.year}"


class GmailImapClient:
    """
    Thin wrapper around imaplib for incremental Gmail polling.

    Usage:
        client = GmailImapClient(account="you@example.com")
        with client:
            for msg in client.fetch_new(cursor):
                ...   # cursor is mutated in place as messages are consumed
    """

    def __init__(
        self,
        account: str,
        mailbox: str = "INBOX",
        host: str = GMAIL_IMAP_HOST,
        port: int = GMAIL_IMAP_PORT,
        *,
        connection_factory=None,
    ):
        """
        Args:
            account: email address; also the keychain account for the App Password.
            mailbox: IMAP folder to poll (default INBOX).
            connection_factory: callable() -> an imaplib.IMAP4-like object. Injected
                                 for testing; defaults to a real SSL connection.
        """
        self.account = account
        self.mailbox = mailbox
        self.host = host
        self.port = port
        self._connection_factory = connection_factory or self._default_connection
        self._conn = None
        # UIDs skipped by the most recent fetch_new pass (fetch failed or timed
        # out repeatedly). Exposed so the pipeline can record skip counts.
        self.last_poll_skipped_uids: list[int] = []

    # ── connection lifecycle ────────────────────────────────────────────────

    def _default_connection(self):
        # The timeout applies to every socket operation on the connection —
        # a dead read surfaces as TimeoutError instead of hanging forever.
        return imaplib.IMAP4_SSL(self.host, self.port,
                                 timeout=IMAP_SOCKET_TIMEOUT_SECONDS)

    def connect(self) -> None:
        """Open the connection and authenticate using the Keychain App Password."""
        password = get_gmail_app_password(self.account)
        try:
            self._conn = self._connection_factory()
            self._conn.login(self.account, password)
        except imaplib.IMAP4.error as exc:
            raise ImapError(f"IMAP login failed for {self.account}: {exc}") from exc
        except OSError as exc:  # network-level failure
            raise ImapError(f"Could not connect to {self.host}:{self.port}: {exc}") from exc
        log.info("Connected to %s as %s", self.host, self.account)

    def close(self) -> None:
        if self._conn is not None:
            try:
                self._conn.logout()
            except Exception:
                log.debug("Error during IMAP logout (ignored)", exc_info=True)
            finally:
                self._conn = None

    def __enter__(self) -> "GmailImapClient":
        self.connect()
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # ── polling ──────────────────────────────────────────────────────────────

    def _select_mailbox(self) -> int:
        """Select the mailbox and return its current UIDVALIDITY."""
        typ, _ = self._conn.select(self.mailbox, readonly=True)
        if typ != "OK":
            raise ImapError(f"Could not select mailbox {self.mailbox!r}")
        typ, data = self._conn.status(self.mailbox, "(UIDVALIDITY)")
        if typ != "OK" or not data:
            raise ImapError(f"Could not read UIDVALIDITY for {self.mailbox!r}")
        # data like: [b'INBOX (UIDVALIDITY 12345)']
        text = data[0].decode() if isinstance(data[0], bytes) else str(data[0])
        try:
            return int(text.split("UIDVALIDITY")[1].split(")")[0].strip())
        except (IndexError, ValueError) as exc:
            raise ImapError(f"Malformed UIDVALIDITY response: {text!r}") from exc

    def _select_mailbox_with_retry(self) -> int:
        """
        Select the mailbox, reconnecting on socket timeout / connection abort.

        Same E7 taxonomy as _fetch_raw_with_retry, applied to the SELECT/STATUS
        pair that opens every poll: a timeout here is TRANSIENT (Gmail drops
        and throttles idle connections), so WARN + reconnect + retry.

        WHY THIS EXISTS (Session 34): _fetch_raw_with_retry covered mid-FETCH
        timeouts, but this pair had no handling at all, so a bare TimeoutError
        — an OSError, not an ImapError — escaped poll_once's `except ImapError`
        backoff, hit _run_producer's catch-all, and set the account's stop
        event PERMANENTLY. In the alpha that killed both mailboxes (2026-08-13)
        and nothing fetched mail for 13 days.

        On exhaustion this raises ImapError, NOT the underlying TimeoutError:
        the exception type is what routes the failure to the poll-level retry,
        so raising the wrong type is precisely how a recoverable blip became a
        permanent outage.

        Note the reconnect here cannot use _reconnect(): that helper re-selects
        the mailbox to compare UIDVALIDITY, which is the very operation failing.
        There is no epoch to protect yet — no UID list is in flight before the
        first successful select — so a plain close/connect is correct.
        """
        for attempt in range(1, SELECT_ATTEMPTS_PER_POLL + 1):
            try:
                return self._select_mailbox()
            except (imaplib.IMAP4.abort, OSError) as exc:
                if attempt >= SELECT_ATTEMPTS_PER_POLL:
                    raise ImapError(
                        f"Could not select {self.mailbox!r} after {attempt} "
                        f"timed-out/aborted attempts: {exc}"
                    ) from exc
                log.warning(
                    "SELECT/STATUS on %s failed (attempt %d/%d): %s; "
                    "reconnecting and retrying",
                    self.mailbox, attempt, SELECT_ATTEMPTS_PER_POLL, exc,
                )
                try:
                    self.close()
                    self.connect()
                except (imaplib.IMAP4.abort, OSError) as reconnect_exc:
                    # The reconnect itself failed — still transient (the server
                    # may be unreachable this second). Fall through to the next
                    # attempt rather than escaping as a bare OSError.
                    log.warning("Reconnect to %s failed: %s", self.host, reconnect_exc)
        raise ImapError(f"Could not select {self.mailbox!r}")  # unreachable

    def fetch_new(self, cursor: ImapCursor,
                  since: Optional[str] = None) -> Iterator[Message]:
        """
        Yield parsed Messages with UID strictly greater than cursor.last_uid.

        The cursor is updated in place after each message is yielded, so a caller
        that stops partway (or crashes) only re-fetches what it hasn't consumed.

        If UIDVALIDITY changed since the cursor was created, the cursor is reset
        (last_uid=0) and the full mailbox is re-synced — UIDs from the old session
        are no longer valid.
        """
        if self._conn is None:
            raise ImapError("Not connected; call connect() or use as a context manager.")

        uidvalidity = self._select_mailbox_with_retry()
        if cursor.uidvalidity is not None and cursor.uidvalidity != uidvalidity:
            # ERROR, not WARNING (OI15): a rolled epoch invalidates every bare
            # UID — proceeding without the reset would silently skip mail (P1).
            # The reset + full re-scan is the recovery. Re-scanned mail arrives
            # under NEW uids ({account}:{uid} PK), so a true roll DUPLICATES
            # rather than dedups — no loss, the P1-safe direction (OI17 tracks
            # Message-ID-keyed dedup if a roll is ever observed).
            log.error(
                "UIDVALIDITY changed for %s (stored/known %s → live %s); "
                "resetting cursor to 0 and re-scanning the full mailbox",
                self.mailbox, cursor.uidvalidity, uidvalidity,
            )
            cursor.last_uid = 0
        cursor.uidvalidity = uidvalidity

        uids = self._search_new_uids(cursor.last_uid, since=since)
        log.info("Found %d new message(s) in %s above UID %d",
                 len(uids), self.mailbox, cursor.last_uid)

        skipped: list[int] = []
        self.last_poll_skipped_uids = skipped
        yielded = 0
        for index, uid in enumerate(uids, start=1):
            raw = self._fetch_raw_with_retry(uid, uidvalidity)
            if raw is None:
                # Couldn't fetch this one (no data, or repeated timeouts —
                # _fetch_raw_with_retry already logged which, loudly). Advance
                # the cursor anyway so we don't wedge the poll on a single bad
                # message (P1: we surface the failure rather than silently
                # looping forever), and record the skip.
                skipped.append(uid)
                cursor.last_uid = max(cursor.last_uid, uid)
                continue
            try:
                msg = parse_message(raw, message_id=self._message_id(uid), account=self.account)
            except Exception:
                log.exception("Failed to parse UID %d in %s; advancing past it", uid, self.mailbox)
                skipped.append(uid)
                cursor.last_uid = max(cursor.last_uid, uid)
                continue
            cursor.last_uid = max(cursor.last_uid, uid)
            yielded += 1
            yield msg
            # Progress observability (Part D): a long backfill must be visibly
            # working — one line per batch, never per message.
            if index % FETCH_PROGRESS_EVERY == 0:
                log.info("Fetch progress in %s: %d/%d UIDs (yielded %d, skipped %d)",
                         self.mailbox, index, len(uids), yielded, len(skipped))
        if uids:
            log.info("Fetch complete in %s: %d UID(s) seen, %d yielded, %d skipped",
                     self.mailbox, len(uids), yielded, len(skipped))
        if skipped:
            log.error("Poll skipped %d UID(s) in %s: %s — these messages were NOT "
                      "ingested this pass", len(skipped), self.mailbox, skipped)

    def _search_new_uids(self, last_uid: int, since: Optional[str] = None) -> list[int]:
        """Return sorted UIDs greater than last_uid, optionally narrowed by date.

        `since` is an IMAP date string ("07-Sep-2026"). When given, the SERVER
        excludes older mail and we never download it.

        WHY THIS EXISTS. The retrieval window used to be applied only
        client-side: every UID above the cursor was fetched in full and then
        discarded if it fell outside the window. Measured on a real cold start
        with a 7-day window — **1,588 messages downloaded to keep 15**, taking
        6.3 minutes during which the user saw nothing. The identical question,
        asked with SINCE by the preview path, answers in about a second. Two
        implementations of one question, disagreeing by a factor of 400.

        ⚠️ THIS IS A NARROWING, NOT THE BOUNDARY. IMAP SINCE is date-granular
        (no time component) and evaluated by the server against its own notion
        of the message date, which can differ from the parsed `received_at` we
        compare against. So this deliberately fetches slightly MORE than the
        window, and `pipeline._before()` remains the exact cutoff. The caller
        must keep that check — see `imap_date_floor` for why the date is rounded
        DOWN, and never treat SINCE as sufficient on its own.
        """
        # IMAP UID ranges are inclusive; ask for (last_uid+1):* to exclude last_uid.
        start = last_uid + 1
        if since is None:
            typ, data = self._conn.uid("SEARCH", None, f"UID {start}:*")
        else:
            # Both criteria in one SEARCH: the server ANDs them, so we get
            # "new to us AND recent enough" without a second round trip.
            typ, data = self._conn.uid("SEARCH", None, f"UID {start}:*",
                                       "SINCE", since)
        if typ != "OK":
            raise ImapError(f"UID SEARCH failed: {typ}")
        if not data or not data[0]:
            return []
        raw_ids = data[0].split()
        # The (start:*) range always returns at least the highest UID even when
        # nothing is actually newer — filter to strictly-greater to be safe.
        uids = sorted(int(x) for x in raw_ids)
        return [u for u in uids if u >= start]

    def _fetch_raw(self, uid: int) -> Optional[bytes]:
        """Fetch the raw RFC822 bytes for a single UID."""
        typ, data = self._conn.uid("FETCH", str(uid), "(BODY.PEEK[])")
        if typ != "OK" or not data or data[0] is None:
            return None
        # data is like [(b'1 (UID 5 BODY[] {N}', b'<raw bytes>'), b')']
        for part in data:
            if isinstance(part, tuple) and len(part) == 2:
                return part[1]
        return None

    def _fetch_raw_with_retry(self, uid: int, uidvalidity: int) -> Optional[bytes]:
        """
        Fetch one UID, reconnecting on socket timeout / connection abort.

        E7 taxonomy: a mid-fetch timeout is TRANSIENT (unlike KeychainError) —
        Gmail drops/throttles long single-connection sessions, so the right
        response is WARN + reconnect + retry the same UID, bounded by
        FETCH_ATTEMPTS_PER_MESSAGE. On exhaustion the UID is skipped with a
        loud ERROR naming it (never a silent drop, never a wedged poll).

        Returns the raw bytes, or None when the message must be skipped
        (either the server cleanly returned no data, or retries ran out).
        Raises ImapError if a reconnect itself fails or UIDVALIDITY changes
        mid-poll — those fail the whole poll loudly (the pipeline's poll-level
        retry/backoff owns that class).
        """
        for attempt in range(1, FETCH_ATTEMPTS_PER_MESSAGE + 1):
            try:
                raw = self._fetch_raw(uid)
                if raw is None:
                    # The server answered OK but returned no data — not a
                    # timeout, so retrying won't help. Skip (logged here so
                    # the two skip causes stay distinguishable).
                    log.warning("Skipping UID %d in %s: fetch returned no data",
                                uid, self.mailbox)
                return raw
            except (imaplib.IMAP4.abort, OSError) as exc:
                # TimeoutError is an OSError; imaplib surfaces post-timeout
                # protocol wreckage as IMAP4.abort. Both mean: connection gone.
                if attempt >= FETCH_ATTEMPTS_PER_MESSAGE:
                    log.error(
                        "Skipping UID %d in %s after %d timed-out/aborted fetch "
                        "attempts: %s — message NOT ingested this pass",
                        uid, self.mailbox, attempt, exc,
                    )
                    return None
                log.warning(
                    "Fetch of UID %d in %s failed (attempt %d/%d): %s; "
                    "reconnecting and retrying",
                    uid, self.mailbox, attempt, FETCH_ATTEMPTS_PER_MESSAGE, exc,
                )
                self._reconnect(expected_uidvalidity=uidvalidity)
        return None  # unreachable; loop always returns

    def _reconnect(self, *, expected_uidvalidity: int) -> None:
        """
        Tear down and re-establish the connection mid-poll, re-selecting the
        mailbox. If UIDVALIDITY changed across the reconnect, the in-flight
        UID list is no longer valid — fail the poll loudly (ImapError); the
        next poll's fetch_new detects the change and re-syncs.
        """
        log.info("Reconnecting to %s as %s", self.host, self.account)
        self.close()
        self.connect()
        uidvalidity = self._select_mailbox()
        if uidvalidity != expected_uidvalidity:
            raise ImapError(
                f"UIDVALIDITY changed mid-poll ({expected_uidvalidity} → "
                f"{uidvalidity}); aborting this poll — next poll re-syncs"
            )

    def verify_login(self) -> Tuple[bool, str]:
        """
        Read-only connectivity check for onboarding (closes E7, honors P5): attempt
        an IMAP-SSL login with the Keychain App Password and immediately log out.
        Selects no mailbox, fetches nothing, writes nothing.

        Returns (ok, reason):
          (True,  "ok")                  — login succeeded
          (False, "missing_credential")  — no App Password in the Keychain
          (False, "auth_failed")         — credential rejected by the server
          (False, "network_error")       — could not reach the server
        """
        try:
            password = get_gmail_app_password(self.account)
        except KeychainError as exc:
            log.info("verify_login: no credential for %s: %s", self.account, exc)
            return (False, "missing_credential")

        conn = None
        try:
            conn = self._connection_factory()
            conn.login(self.account, password)
        except imaplib.IMAP4.error as exc:
            log.info("verify_login: auth failed for %s: %s", self.account, exc)
            return (False, "auth_failed")
        except OSError as exc:  # network-level failure (DNS, refused, timeout)
            log.info("verify_login: network error reaching %s: %s", self.host, exc)
            return (False, "network_error")
        else:
            return (True, "ok")
        finally:
            if conn is not None:
                try:
                    conn.logout()
                except Exception:
                    log.debug("verify_login: error during logout (ignored)", exc_info=True)

    def count_since(self, since: "str | None", *,
                    password: "str | None" = None) -> int:
        """
        Count messages in the mailbox at or after `since`, without fetching any.

        Powers the retrieval-window size preview at connect time: before the user
        commits to "everything", they are told what that means in messages. An
        adjective ("large") is not a number, and the case this exists for — a
        mailbox with thousands of messages — is exactly the one where the number
        changes the decision.

        Args:
            since: an IMAP date string ("01-Jan-2026"), or None to count the
                   whole mailbox (the `everything` window).
            password: an explicit App Password, for the connect-time preview
                   where the credential has NOT been stored yet. Supplying it
                   here means the preview needs no Keychain write — a question
                   the user asked must not leave a credential behind for an
                   account they may decide not to connect (P5). Falls back to
                   the Keychain when omitted.

        READ-ONLY (P5), and deliberately so at three levels: the mailbox is
        SELECTed readonly, only UID SEARCH is issued (never FETCH or STORE), and
        the connection is logged out in `finally`. This mirrors `verify_login`,
        which is the other place the app touches a mailbox purely to answer a
        question the user asked.

        Raises rather than returning 0 on failure. A count of 0 from a failed
        auth or an unreachable server would read as "your mailbox is empty" at
        precisely the moment the user is deciding how much to import — the most
        misleading possible answer, and one the caller cannot distinguish from a
        genuinely empty mailbox.
        """
        secret = password if password is not None else get_gmail_app_password(self.account)
        conn = None
        try:
            conn = self._connection_factory()
            conn.login(self.account, secret)
            typ, _ = conn.select(self.mailbox, readonly=True)
            if typ != "OK":
                raise ImapError(f"Could not select mailbox {self.mailbox!r}")
            if since is None:
                typ, data = conn.uid("SEARCH", None, "ALL")
            else:
                typ, data = conn.uid("SEARCH", None, "SINCE", since)
            if typ != "OK":
                raise ImapError(f"UID SEARCH for the window count failed: {typ}")
            if not data or not data[0]:
                return 0
            raw = data[0]
            text = raw.decode() if isinstance(raw, bytes) else str(raw)
            return len(text.split())
        except imaplib.IMAP4.error as exc:
            raise ImapError(f"IMAP error counting {self.mailbox!r} "
                            f"for {self.account}: {exc}") from exc
        except OSError as exc:
            raise ImapError(f"Could not reach {self.host}:{self.port}: {exc}") from exc
        finally:
            if conn is not None:
                try:
                    conn.logout()
                except Exception:
                    log.debug("count_since: error during logout (ignored)",
                              exc_info=True)

    def _message_id(self, uid: int) -> str:
        """
        Stable primary-key id for a message. Namespaced by account + UIDVALIDITY
        so UIDs reused across UIDVALIDITY epochs (or across accounts) never collide.
        """
        return f"{self.account}:{uid}"

    # ── write-back: mark read / unread (spec §3.5.3, D16, D21, P5) ─────────────
    #
    # Targeting note (why we search by RFC822 Message-ID, not the id's bare uid):
    # the synthetic PK is `{account}:{uid}`, but UIDVALIDITY is not persisted
    # anywhere (the poll cursor is in-memory and recreated per run). Per the IMAP
    # UID contract a bare uid is only meaningful WITHIN a UIDVALIDITY epoch — if
    # Gmail ever rolled UIDVALIDITY between ingest and write-back, that uid integer
    # could now address a DIFFERENT message. Marking the wrong message read would
    # violate P5 / the write-back invariant. So write-back does NOT trust the
    # embedded uid: it re-derives the CURRENT uid by searching for the immutable
    # RFC822 Message-ID header, and only acts on an unambiguous single match.

    def _set_seen(self, rfc822_message_id: str, *, seen: bool) -> bool:
        """
        Add (`seen=True`) or remove (`seen=False`) the IMAP `\\Seen` flag on the
        message whose RFC822 Message-ID header equals `rfc822_message_id`.

        Opens a WRITABLE mailbox select (unlike polling's readonly select). Targets
        by Message-ID search (see class note) and acts ONLY on an exact single
        match — 0 or >1 matches abort untouched and return False (flag-don't-guess;
        never risk mutating a message we can't uniquely identify, P5).

        Returns True iff exactly one message matched and the STORE succeeded.
        Best-effort by contract: the caller treats a False/raise as non-fatal (a
        write-back miss must never fail the triage that triggered it).
        """
        if self._conn is None:
            raise ImapError("Not connected; call connect() or use as a context manager.")
        if not rfc822_message_id:
            log.warning("write-back: empty Message-ID; skipping (no target)")
            return False

        # Writable select — we intend to change a flag.
        typ, _ = self._conn.select(self.mailbox, readonly=False)
        if typ != "OK":
            raise ImapError(f"Could not select mailbox {self.mailbox!r} for write-back")

        # UID SEARCH HEADER "Message-ID" "<id>" — the header value is quoted as an
        # IMAP astring. Message-IDs are angle-bracketed ASCII, so a plain quoted
        # string is well-formed; imaplib sends the literal as-is.
        typ, data = self._conn.uid("SEARCH", None, "HEADER", "Message-ID", rfc822_message_id)
        if typ != "OK":
            raise ImapError(f"UID SEARCH by Message-ID failed: {typ}")
        uids = data[0].split() if data and data[0] else []
        if len(uids) != 1:
            # 0 = message not in this mailbox (moved/archived/deleted); >1 = the
            # Message-ID isn't unique here. Either way we can't safely target one
            # message — abort untouched (P5).
            log.warning(
                "write-back: Message-ID %r matched %d messages in %s; not marking (need exactly 1)",
                rfc822_message_id, len(uids), self.mailbox,
            )
            return False

        uid = uids[0].decode() if isinstance(uids[0], bytes) else str(uids[0])
        op = "+FLAGS" if seen else "-FLAGS"
        typ, _ = self._conn.uid("STORE", uid, op, "(\\Seen)")
        if typ != "OK":
            raise ImapError(f"UID STORE {op} \\Seen failed for uid {uid}: {typ}")
        log.info("write-back: %s \\Seen on %s uid %s (Message-ID %r)",
                 op, self.mailbox, uid, rfc822_message_id)
        return True

    def mark_read(self, rfc822_message_id: str) -> bool:
        """Mark the source message read (`+FLAGS \\Seen`). See `_set_seen`."""
        return self._set_seen(rfc822_message_id, seen=True)

    def mark_unread(self, rfc822_message_id: str) -> bool:
        """
        Mark the source message unread (`-FLAGS \\Seen`) — the inverse of
        `mark_read`. Used to revert a write-back (e.g. during verification), and
        the natural counterpart should un-read sync ever be wired to a triage
        regression. See `_set_seen`.
        """
        return self._set_seen(rfc822_message_id, seen=False)