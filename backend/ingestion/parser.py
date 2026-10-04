"""
thresher message parser
Pure functions that turn a raw RFC822 byte string into a Message dataclass.

Kept free of any network/IMAP concerns so it can be unit-tested in isolation
against canned message bytes.

Constitution refs:
  P1 — Never drop: we never fail-hard on a malformed message; we parse what we
        can and fall back to safe defaults so the message is still stored and
        surfaced rather than silently lost.
"""

import email
import email.policy
import logging
from datetime import datetime, timezone
from email.header import decode_header, make_header
from email.message import EmailMessage
from email.utils import getaddresses, parsedate_to_datetime
from typing import Optional, Tuple

# database.py lives in a sibling package; both are imported as top-level modules
# (the project has no __init__.py packaging — modules are flat on sys.path).
from db.database import Message

log = logging.getLogger(__name__)


def _decode_str(value: Optional[str]) -> Optional[str]:
    """Decode an RFC2047-encoded header (=?utf-8?...?=) into a plain string."""
    if value is None:
        return None
    try:
        return str(make_header(decode_header(value)))
    except Exception:  # malformed encoding — return the raw value rather than drop it
        log.debug("Failed to RFC2047-decode header value; using raw: %r", value)
        return value


def parse_sender(from_header: Optional[str]) -> Tuple[Optional[str], str]:
    """
    Parse a From: header into (display_name, email_address).

    Returns ("", "") email as "" only when no address can be extracted, so the
    caller can decide on a fallback. Display name may be None.
    """
    if not from_header:
        return None, ""
    decoded = _decode_str(from_header) or ""
    addrs = getaddresses([decoded])
    if not addrs:
        return None, ""
    name, addr = addrs[0]
    return (name or None), addr.lower().strip()


def parse_received_at(msg: EmailMessage) -> str:
    """
    Return the message's Date as an ISO-8601 string (UTC).
    Falls back to 'now' if the header is missing or unparseable (P1: still store it).
    """
    raw = msg.get("Date")
    if raw:
        try:
            dt = parsedate_to_datetime(raw)
            if dt is not None:
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                return dt.astimezone(timezone.utc).isoformat()
        except (TypeError, ValueError):
            log.debug("Unparseable Date header: %r; falling back to now", raw)
    return datetime.now(timezone.utc).isoformat()


def _extract_bodies(msg: EmailMessage) -> Tuple[Optional[str], Optional[str]]:
    """
    Extract (body_plain, body_html) from a (possibly multipart) message.
    Uses the email package's get_body() which understands multipart/alternative.
    """
    plain: Optional[str] = None
    html: Optional[str] = None

    # get_body() picks the best display part; we also walk for the counterpart.
    try:
        plain_part = msg.get_body(preferencelist=("plain",))
        if plain_part is not None:
            plain = plain_part.get_content()
    except Exception:
        log.debug("Failed to extract plain body", exc_info=True)

    try:
        html_part = msg.get_body(preferencelist=("html",))
        if html_part is not None:
            html = html_part.get_content()
    except Exception:
        log.debug("Failed to extract html body", exc_info=True)

    # Non-multipart plain message: get_body may return None above for some shapes.
    if plain is None and html is None and not msg.is_multipart():
        try:
            content = msg.get_content()
            if msg.get_content_type() == "text/html":
                html = content
            else:
                plain = content
        except Exception:
            log.debug("Failed to extract single-part body", exc_info=True)

    return _strip(plain), _strip(html)


def _strip(s: Optional[str]) -> Optional[str]:
    if s is None:
        return None
    s = s.strip()
    return s or None


def _collect_headers(msg: EmailMessage) -> dict:
    """Flatten all headers into a dict (decoded). Duplicates are joined with ', '."""
    headers: dict = {}
    for key, value in msg.items():
        decoded = _decode_str(value)
        if key in headers:
            headers[key] = f"{headers[key]}, {decoded}"
        else:
            headers[key] = decoded
    return headers


def _derive_thread_id(msg: EmailMessage) -> Optional[str]:
    """
    Derive a stable thread identifier from RFC822 threading headers.

    The root of a conversation is the first Message-ID in the References chain;
    for a reply with no References we fall back to In-Reply-To; for an original
    message (neither header) the message's own Message-ID anchors the thread.
    All values are normalized to plain strings (header objects → str).
    """
    references = msg.get("References")
    if references:
        # References is a space-separated list of Message-IDs, oldest first.
        ids = str(references).split()
        if ids:
            return ids[0]
    in_reply_to = msg.get("In-Reply-To")
    if in_reply_to:
        return _strip(str(in_reply_to))
    own = msg.get("Message-ID")
    return _strip(str(own)) if own else None


def parse_message(raw_bytes: bytes, *, message_id: str, account: str) -> Message:
    """
    Parse raw RFC822 bytes into a Message dataclass.

    Args:
        raw_bytes: the raw message as returned by an IMAP FETCH (RFC822 / BODY[]).
        message_id: stable unique id for this message (the IMAP/Gmail id). Used as
                    the primary key — the caller owns id assignment so dedup works.
        account: the mailbox this was pulled from (e.g. "you@example.com").

    Returns:
        A fully-populated Message. Never raises on malformed content (P1) — it
        degrades to safe defaults so the message is still persisted.
    """
    msg: EmailMessage = email.message_from_bytes(
        raw_bytes, policy=email.policy.default
    )

    sender_name, sender_email = parse_sender(msg.get("From"))
    subject = _decode_str(msg.get("Subject"))
    body_plain, body_html = _extract_bodies(msg)
    received_at = parse_received_at(msg)

    return Message(
        id=message_id,
        account=account,
        thread_id=_derive_thread_id(msg),
        sender_name=sender_name,
        sender_email=sender_email,
        subject=subject,
        body_plain=body_plain,
        body_html=body_html,
        received_at=received_at,
        ingested_at=datetime.now(timezone.utc).isoformat(),
        raw_headers=_collect_headers(msg),
    )