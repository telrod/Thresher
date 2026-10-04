"""Tests for ingestion.parser — pure RFC822 → Message parsing."""

from email.message import EmailMessage

from ingestion.parser import (
    parse_message,
    parse_sender,
    parse_received_at,
)


def _build_raw(*, from_="Dana Whitfield <boss@example.com>",
               subject="Quarterly review",
               plain="Please review the deck.",
               html=None,
               date="Mon, 15 Jun 2026 09:30:00 -0400") -> bytes:
    msg = EmailMessage()
    msg["From"] = from_
    msg["Subject"] = subject
    msg["Date"] = date
    msg["Message-ID"] = "<abc123@example.com>"
    if html is not None:
        msg.set_content(plain)
        msg.add_alternative(html, subtype="html")
    else:
        msg.set_content(plain)
    return msg.as_bytes()


def test_parse_basic_message():
    msg = parse_message(_build_raw(), message_id="acct:1", account="you@example.com")
    assert msg.id == "acct:1"
    assert msg.account == "you@example.com"
    assert msg.sender_email == "boss@example.com"
    assert msg.sender_name == "Dana Whitfield"
    assert msg.subject == "Quarterly review"
    assert "review the deck" in msg.body_plain
    assert msg.received_at.startswith("2026-06-15T13:30:00")  # -0400 → UTC
    assert msg.ingested_at  # set to now


def test_parse_multipart_extracts_both_bodies():
    raw = _build_raw(plain="plain version", html="<p>html version</p>")
    msg = parse_message(raw, message_id="acct:2", account="a@b.com")
    assert msg.body_plain == "plain version"
    assert "html version" in msg.body_html


def test_parse_rfc2047_encoded_subject():
    # "Café meeting" encoded
    raw = _build_raw(subject="=?utf-8?q?Caf=C3=A9_meeting?=")
    msg = parse_message(raw, message_id="acct:3", account="a@b.com")
    assert msg.subject == "Café meeting"


def test_parse_sender_bare_address():
    name, addr = parse_sender("plainaddr@example.com")
    assert addr == "plainaddr@example.com"
    assert name is None


def test_parse_sender_missing_header():
    name, addr = parse_sender(None)
    assert name is None
    assert addr == ""


def test_parse_received_at_falls_back_when_date_missing():
    msg = EmailMessage()
    msg["From"] = "a@b.com"
    msg.set_content("hi")
    parsed = parse_message(msg.as_bytes(), message_id="acct:4", account="a@b.com")
    # No Date header → falls back to a valid ISO timestamp rather than failing (P1).
    assert parsed.received_at
    assert "T" in parsed.received_at


def test_parse_malformed_date_does_not_raise():
    raw = _build_raw(date="not a real date")
    msg = parse_message(raw, message_id="acct:5", account="a@b.com")
    assert msg.received_at  # degraded to now, not an exception


def test_thread_id_uses_references_root():
    msg = EmailMessage()
    msg["From"] = "a@b.com"
    msg["Message-ID"] = "<reply@test>"
    msg["References"] = "<root@test> <mid@test>"
    msg.set_content("re: hi")
    parsed = parse_message(msg.as_bytes(), message_id="acct:7", account="a@b.com")
    assert parsed.thread_id == "<root@test>"


def test_thread_id_falls_back_to_own_message_id():
    parsed = parse_message(_build_raw(), message_id="acct:8", account="a@b.com")
    assert parsed.thread_id == "<abc123@example.com>"


def test_raw_headers_captured_as_dict():
    msg = parse_message(_build_raw(), message_id="acct:6", account="a@b.com")
    assert isinstance(msg.raw_headers, dict)
    assert "From" in msg.raw_headers
    assert "Subject" in msg.raw_headers