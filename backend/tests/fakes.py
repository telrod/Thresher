"""
Test doubles: a fake imaplib.IMAP4-like server so the IMAP client and pipeline
can be exercised without a network connection.

The fake implements just the surface GmailImapClient uses: login, select,
status, uid(SEARCH/FETCH), and logout.
"""

from email.message import EmailMessage


def build_raw(from_, subject, plain="body text",
              date="Mon, 15 Jun 2026 09:30:00 -0400") -> bytes:
    msg = EmailMessage()
    msg["From"] = from_
    msg["Subject"] = subject
    msg["Date"] = date
    msg["Message-ID"] = f"<{subject.replace(' ', '')}@test>"
    msg.set_content(plain)
    return msg.as_bytes()


class FakeIMAP:
    """
    A minimal in-memory IMAP server.

    messages: dict of {uid (int): raw bytes}, in ascending UID order.
    """

    def __init__(self, messages, uidvalidity=1000):
        self._messages = dict(messages)
        self._uidvalidity = uidvalidity
        self.logged_in = False
        self.logged_out = False
        self.selected = None
        self.selected_readonly = None
        # write-back test surface: which uids currently carry \Seen, and a log of
        # STORE ops so a test can assert exactly what was (or wasn't) flipped.
        self.seen_uids = set()
        self.store_calls = []   # list of (uid:str, op:str, flags:str)
        # Date-scoped SEARCH args, so a test can assert the cutoff the client sent.
        self.search_calls = []

    # -- auth / lifecycle --
    def login(self, user, password):
        self.logged_in = True
        return ("OK", [b"authenticated"])

    def logout(self):
        self.logged_out = True
        return ("BYE", [b"logout"])

    # -- mailbox --
    def select(self, mailbox, readonly=False):
        self.selected = mailbox
        self.selected_readonly = readonly
        return ("OK", [str(len(self._messages)).encode()])

    def status(self, mailbox, what):
        return ("OK", [f"{mailbox} (UIDVALIDITY {self._uidvalidity})".encode()])

    # -- uid commands --
    def uid(self, command, *args):
        cmd = command.upper()
        if cmd == "SEARCH":
            # Two shapes:
            #   polling:     (None, "UID 3:*")
            #   write-back:  (None, "HEADER", "Message-ID", "<id>")
            if len(args) >= 3 and str(args[1]).upper() == "HEADER":
                header_name, wanted = args[1], args[3] if len(args) > 3 else args[2]
                # Only Message-ID search is used by write-back; match by scanning
                # each stored message's Message-ID header.
                hits = [u for u, raw in self._messages.items()
                        if _message_id_of(raw) == wanted]
                return ("OK", [b" ".join(str(u).encode() for u in sorted(hits))])
            # Date-scoped count (retrieval-window preview). The real call is
            # conn.uid("SEARCH", None, "SINCE", date) — imaplib's charset slot is
            # the leading None — so skip it before reading the criterion.
            criteria = [a for a in args if a is not None]
            head = str(criteria[0]).upper() if criteria else ""
            if head == "ALL":
                return ("OK", [b" ".join(str(u).encode()
                                         for u in sorted(self._messages))])
            if head == "SINCE":
                # The fake stores no dates, so SINCE matches everything it has;
                # tests that care about the cutoff assert on the ARGUMENTS sent
                # (search_calls), which is the part the client is responsible for.
                self.search_calls.append(tuple(str(a) for a in criteria))
                return ("OK", [b" ".join(str(u).encode()
                                         for u in sorted(self._messages))])
            # The real client may send "UID <n>:*" alone, or combined with a
            # server-side date narrowing: `UID <n>:* SINCE <date>` (2026-09-07).
            # Record the full criteria either way — the date filter is the
            # client's responsibility and tests assert on what was SENT, since
            # this fake stores no dates to filter by.
            self.search_calls.append(tuple(str(a) for a in criteria))
            spec = next((a for a in args if str(a).startswith("UID ")), args[-1])
            start = int(str(spec).split()[1].split(":")[0])
            hits = sorted(u for u in self._messages if u >= start)
            return ("OK", [b" ".join(str(u).encode() for u in hits)])
        if cmd == "FETCH":
            uid = int(args[0])
            raw = self._messages.get(uid)
            if raw is None:
                return ("OK", [None])
            header = f"1 (UID {uid} BODY[] {{{len(raw)}}}".encode()
            return ("OK", [(header, raw), b")"])
        if cmd == "STORE":
            # args like ("5", "+FLAGS", "(\\Seen)")
            uid, op, flags = args[0], args[1], args[2]
            self.store_calls.append((str(uid), op, flags))
            if "\\Seen" in flags:
                if op == "+FLAGS":
                    self.seen_uids.add(int(uid))
                elif op == "-FLAGS":
                    self.seen_uids.discard(int(uid))
            return ("OK", [f"{uid} (UID {uid} FLAGS (\\Seen))".encode()])
        raise AssertionError(f"unexpected uid command {command}")


def _message_id_of(raw: bytes) -> str:
    """Extract the Message-ID header from raw RFC822 bytes (test helper)."""
    import email
    return email.message_from_bytes(raw).get("Message-ID", "")