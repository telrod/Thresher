#!/usr/bin/env python3
"""
Synthetic mail corpus generator — see docs/synthetic-corpus-spec.md.

Produces RFC822 `.eml` files. It does NOT write a database: the corpus is fed
through the real ingestion pipeline (`--ingest`), for the same reason no `.db`
is committed — a special demo path would rot unnoticed while the real path is
exercised constantly.

    ./scripts/generate_corpus.py --profile fixtures --out backend/tests/corpus
    ./scripts/generate_corpus.py --profile demo --out /tmp/demo --ingest /tmp/demo.db
    ./scripts/generate_corpus.py --profile dev --count 1200 --out /tmp/dev

Four profiles:

    fixtures  ~25   edge cases, malformed input, deterministic, committed
    demo      ~150  bundled with the app; has to look good
    dev       ~400  contributor volume and variety
    (--count overrides the profile's default for larger runs)

THE TRAP (spec §1), which constrains everything below: if senders are
hand-tuned so the shipped seed rules light them up, every screenshot shows a
tiered inbox that a real user does not get on a fresh install. So tier is never
stamped on a message here. Each message is authored as a *plausible piece of
mail*; the tier is whatever the engine decides. `--report` prints the resulting
distribution twice — with the demo sender groups populated and with groups
empty — because the second number is what a stranger actually sees.

Constraints (spec §Constraints):
  - stdlib only (D68: flask is the only third-party dep, and that stays true)
  - deterministic: same --seed and --reference-date produce byte-identical output
  - reserved domains only (RFC 2606: example.com/.org/.net)
"""

from __future__ import annotations

import argparse
import hashlib
import random
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from email.utils import format_datetime
from pathlib import Path
from typing import Optional

# The demo account identity, used throughout the corpus so it appears
# consistently in the message list, in Settings, and in the onboarding shots
# (spec §"Screenshots carry the README"). A real throwaway Gmail account.
DEMO_ACCOUNT = "thresher.demo@gmail.com"

# RFC 2606 reserved — cannot be registered by anyone, so nothing here can ever
# impersonate a real company or collide with a real address.
DOMAINS = ("example.com", "example.org", "example.net")

PROFILE_COUNTS = {"fixtures": 25, "demo": 150, "dev": 400}


# ── Personas ──────────────────────────────────────────────────────────────────
#
# One pool, shared by every profile — that is what makes a fixture and a
# screenshot feel like the same product rather than two applications.
#
# `kind` drives content generation and nothing else. It is deliberately NOT a
# tier: a persona is a person who sends mail, and what tier their mail lands in
# is the engine's answer, not the generator's.


@dataclass(frozen=True)
class Persona:
    name: str
    address: str
    kind: str          # matters | colleague | automated | bulk | ambiguous
    role: str
    register: str      # how they write — keeps subjects from sounding identical


PERSONAS: tuple[Persona, ...] = (
    # ── People who matter — the ones a user would put in a sender group.
    # Direct, short, often a question.
    Persona("Dana Whitfield", "dana.whitfield@example.com", "matters",
            "engineering director", "direct"),
    Persona("Priya Raghunathan", "priya.raghunathan@example.com", "matters",
            "head of product", "direct"),
    Persona("Nora Castellan", "nora.castellan@example.org", "matters",
            "sister", "warm"),

    # ── Colleagues — routine work mail, threads, replies.
    Persona("Ben Oyelaran", "ben.oyelaran@example.com", "colleague",
            "backend engineer", "casual"),
    Persona("Marta Lindqvist", "marta.lindqvist@example.com", "colleague",
            "designer", "considered"),
    Persona("Tobias Renner", "tobias.renner@example.com", "colleague",
            "data engineer", "terse"),
    Persona("Saoirse Dunleavy", "saoirse.dunleavy@example.com", "colleague",
            "project manager", "organised"),

    # ── Automated but important. Machine-written, time-sensitive.
    # Addresses read as human on purpose for two of these: the seed's Tier 5
    # rules match no-reply/noreply address patterns, and real security mail
    # often does not use one. Keeping that split honest is what stops the
    # corpus from flattering the rule set.
    Persona("Northwind Accounts", "security@example.net", "automated",
            "account security", "machine"),
    Persona("Vantage Identity", "accounts@example.net", "automated",
            "identity provider", "machine"),
    Persona("Calendar Service", "calendar-noreply@example.net", "automated",
            "calendar", "machine"),

    # ── Bulk and promotional. These carry List-Unsubscribe (OI38).
    Persona("Kestrel Books", "newsletter@example.net", "bulk",
            "bookshop", "promotional"),
    Persona("The Tuesday Dispatch", "no-reply@example.org", "bulk",
            "newsletter", "editorial"),
    Persona("Harbourline Outfitters", "marketing@example.net", "bulk",
            "retailer", "promotional"),
    Persona("Glasshouse Coffee", "hello@example.net", "bulk",
            "coffee subscription", "chatty"),

    # ── Ambiguous — human-written, unknown sender. The interesting case, and
    # the reason the tier system needs judgement at all.
    Persona("Alan Prosser", "a.prosser@example.org", "ambiguous",
            "former colleague", "rambling"),
    Persona("Imogen Sallow", "imogen.sallow@example.org", "ambiguous",
            "conference organiser", "polite"),
)

# The sender groups the demo profile ships populated with (spec §1: the demo
# corpus ships with populated groups, and the documentation says so). These
# mirror the seed's group names so the seeded rules reach them.
DEMO_SENDER_GROUPS = (
    ("leadership", 1, ("dana.whitfield@example.com", "priya.raghunathan@example.com")),
    ("family", 1, ("nora.castellan@example.org",)),
    # Only ONE colleague is in the group. Putting every colleague persona in it
    # made 20 of 27 fixtures Tier 2 by sender override, which masked every
    # subject-rule and edge-case behaviour underneath a single group match —
    # the fixtures looked classified but pinned almost nothing. Ben is in the
    # group so the override path is still covered; the others stay out so their
    # mail is classified on its own merits.
    ("close_colleagues", 2, ("ben.oyelaran@example.com",)),
)


# ── Content ───────────────────────────────────────────────────────────────────
#
# Subjects: 3–8 words, varied register, no numbering scheme. Bodies: two to
# five sentences, so the detail pane is not empty in a screenshot.
#
# Nothing here reads as a real security alert or payment notice from a real
# institution, and nothing would embarrass anyone on a conference slide.

SUBJECTS: dict[str, tuple[str, ...]] = {
    "matters": (
        "Can you look at the migration plan today",
        "Quick question about the Thornbury numbers",
        "Are you free before the board call",
        "Need your read on this before Friday",
        "Thoughts on the revised timeline",
        "Sunday lunch — does one o'clock work",
        "Mum's birthday — can you call her",
        "Pulling you into the pricing discussion",
    ),
    "colleague": (
        "Staging deploy is green again",
        "Notes from the retro",
        "Draft copy for the settings screen",
        "Pipeline backfill finished overnight",
        "Moving standup to half past nine",
        "Two small things on the review",
        "Schema change needs a second pair of eyes",
        "Who owns the onboarding copy now",
        "Rough sketches attached for comment",
        "Sprint boundary is going to slip a day",
        # These reach the seed's Tier 3 rules (subject contains JIRA / GitHub).
        # They are ordinary project mail a real developer receives constantly,
        # not keywords inserted to light the rules up — without them the corpus
        # has no T3 at all and the middle of the tier range goes undemonstrated.
        "GitHub: review requested on the ingest branch",
        "JIRA ticket moved to Ready for Pointing",
        "GitHub: build failed on main",
        "JIRA: three tickets need estimates before Friday",
    ),
    "automated": (
        "Your verification code",
        "Security alert: new sign-in attempt",
        "Password reset requested",
        "Invitation: Quarterly planning review",
        "Your one-time passcode",
        "Invitation: Design critique",
        "Security alert: password changed",
    ),
    "bulk": (
        "This week's staff picks",
        "Your order is on its way",
        "Autumn range now in stock",
        "The Tuesday Dispatch — issue forty-one",
        "Three things worth reading",
        "Your subscription renews next month",
        "Last chance for the winter pre-order",
        "A short note about our new roastery",
        "Weekend reading from the shop floor",
    ),
    "ambiguous": (
        "Long overdue catch-up",
        "Following up on our conversation",
        "Would you speak at our March event",
        "Not sure if this reached you",
        "An idea I wanted to run past you",
    ),
}

BODIES: dict[str, tuple[str, ...]] = {
    "matters": (
        "I've been through the plan and mostly it reads well. The rollback step "
        "is the part I'm unsure about — can you walk me through it before we "
        "commit to a date? I'd rather we caught it now than halfway through.",
        "Do you have twenty minutes today? I want to sanity-check the numbers "
        "before they go any further. Nothing's wrong, I just don't want to be "
        "the one presenting something I haven't understood properly.",
        "Short notice, sorry. The call moved up and I need your view on the "
        "second option. A sentence is fine — I'm not asking for a document.",
        "I said I'd send this on and then didn't, so here it is. Have a look "
        "when you get a chance and tell me if I've missed something obvious.",
    ),
    "colleague": (
        "A review has been requested. The branch touches the ingest path and "
        "two of the migration tests, so it wants a careful read rather than a "
        "skim. No rush on it today.",
        "The ticket moved columns and picked up an estimate along the way. "
        "Nothing else changed. This notification exists mostly so the board "
        "stays honest about who is holding what.",
        "Deploy went through cleanly this time. The failing check turned out to "
        "be a stale cache in the runner rather than anything we'd changed. I've "
        "left a note on the ticket so the next person doesn't lose an hour to it.",
        "Wrote up the retro while it was fresh. Two themes came out: we're "
        "estimating optimistically on anything touching the ingestion path, and "
        "nobody's sure who reviews schema changes. Worth ten minutes on Thursday.",
        "First pass at the copy is attached. I've kept it shorter than the old "
        "version — the previous screen explained three things at once and tested "
        "badly. Happy to be overruled on the heading.",
        "Backfill ran overnight and finished around four. Counts line up with "
        "what we expected, give or take the duplicates we already knew about. "
        "I'll spot-check a sample this afternoon.",
        "Two things, both small. The empty state still says 'loading' after a "
        "failure, and the date column is a pixel out on narrow windows. Neither "
        "is urgent but they're both the kind of thing that gets forgotten.",
    ),
    "automated": (
        "Your verification code is 418902. It expires in ten minutes. If you "
        "didn't request this code, you can ignore this message — no changes have "
        "been made to your account.",
        "We noticed a sign-in to your account from a new device. If this was "
        "you, no action is needed. If it wasn't, review your recent activity and "
        "change your password.",
        "Someone requested a password reset for your account. Use the link in "
        "your account settings to choose a new one. The request expires in one "
        "hour. If this wasn't you, no changes have been made.",
        "You have been invited to a meeting. Details are attached in the "
        "calendar attachment. Responding to this message will not update your "
        "calendar — use the invitation itself.",
    ),
    "bulk": (
        "This week our booksellers have been arguing about one novel in "
        "particular, so we've put it at the top. Also in: two reissues and a "
        "short book about rivers that nobody expected to enjoy as much as they did.",
        "Your order has left the warehouse and should arrive within three "
        "working days. You can track it from your account. No action is needed "
        "from you — this note is just so you know it's moving.",
        "The autumn range has landed. Heavier fabrics, mostly, and the return of "
        "the jacket that sold out twice last year. Members get first access "
        "until the weekend.",
        "Forty-one issues in and we still haven't settled on a house style. This "
        "week: why timetables are harder than they look, a short defence of "
        "paper maps, and the usual three links.",
        "We've moved the roastery two streets over. Same people, same machines, "
        "considerably better ventilation. If you're nearby, come and look at it — "
        "there's usually someone around on a Saturday morning.",
    ),
    "ambiguous": (
        "I know it's been a while. I came across something you'd mentioned years "
        "ago and it made me think I should actually write rather than keep "
        "meaning to. How are things? Still in the same part of the world?",
        "Following up on what we discussed — I don't want to be a nuisance about "
        "it, but I did say I'd come back to you and I'd rather do that than "
        "leave it hanging. Let me know either way and I'll stop asking.",
        "We're putting the March programme together and your name came up more "
        "than once. It would be a forty-minute slot, and we can be flexible on "
        "the topic. No pressure at all if the timing is wrong.",
        "I sent this a fortnight ago and I suspect it went astray, so I'm trying "
        "once more. If it's simply not something you're interested in, that's "
        "completely fine — just say and I won't chase it further.",
    ),
}

# Threads: same subject, Re: prefixed, two or three deep.
THREAD_REPLIES = (
    "Agreed — I'll pick it up in the morning and let you know where I get to.",
    "That matches what I saw. One caveat: the staging numbers were taken before "
    "the reindex, so treat them as a floor rather than a measurement.",
    "Works for me. I've moved the invite and dropped the old one.",
)


# ── Date placement ────────────────────────────────────────────────────────────
#
# Dates are relative to the reference date, never absolute. The sort bands are
# hardcoded at 14 and 90 days; a corpus with fixed dates is correct on the day
# it is generated and wrong forever after.

FRESH_DAYS = 14
RECENT_DAYS = 90

# At least one message either side of each boundary, close enough to catch an
# off-by-one. These are exact offsets in days, applied before any random spread.
BOUNDARY_OFFSETS = (
    FRESH_DAYS - 1,    # 13 — inside the fresh band, just
    FRESH_DAYS + 1,    # 15 — just outside it
    RECENT_DAYS - 1,   # 89 — inside the recent band, just
    RECENT_DAYS + 1,   # 91 — just outside it
)


def _spread_offsets(rng: random.Random, count: int) -> list[float]:
    """Day-offsets from the reference date, deliberately spread across bands.

    Returns floats so messages land at different times of day rather than all
    at midnight, which reads as generated the moment you look at a list.
    """
    offsets: list[float] = [float(d) for d in BOUNDARY_OFFSETS]
    remaining = max(0, count - len(offsets))

    # Roughly: half inside 14 days, a third in 14–90, the rest older. A real
    # mailbox is bottom-heavy in recent mail and this keeps the first page of
    # the list looking alive.
    for i in range(remaining):
        bucket = i % 6
        if bucket <= 2:
            offsets.append(rng.uniform(0.05, FRESH_DAYS - 0.1))
        elif bucket <= 4:
            offsets.append(rng.uniform(FRESH_DAYS + 0.1, RECENT_DAYS - 0.1))
        else:
            offsets.append(rng.uniform(RECENT_DAYS + 0.1, RECENT_DAYS + 220))
    rng.shuffle(offsets)
    return offsets[:count]


# ── Message construction ──────────────────────────────────────────────────────


@dataclass
class Spec:
    """Everything needed to render one .eml, decided before any bytes exist."""
    persona: Persona
    subject: str
    body: str
    offset_days: float
    seq: int
    thread_root: Optional[str] = None   # Message-ID this reply belongs under
    list_unsubscribe: bool = False
    # Edge-case switches (fixtures profile only)
    omit_date: bool = False
    omit_from: bool = False
    omit_subject: bool = False
    html_only: bool = False
    empty_body: bool = False
    force_message_id: Optional[str] = None
    raw_from: Optional[str] = None      # bypass normal From rendering
    encoded_subject: bool = False
    triage_state: str = "new"
    note: str = ""                      # why this fixture exists


def _message_id(seq: int, seed: int) -> str:
    """Stable per-message id. Derived from seq+seed so it is deterministic and
    does not leak a hostname or a clock the way make_msgid() would."""
    digest = hashlib.sha256(f"{seed}:{seq}".encode()).hexdigest()[:16]
    return f"<{digest}@example.com>"


def _render(spec: Spec, reference: datetime, seed: int) -> bytes:
    """Render one Spec to RFC822 bytes.

    Built with EmailMessage so the output is a real message rather than a
    hand-assembled string that only looks like one — the parser under test is
    the stdlib's, and feeding it something we hand-rolled would test the wrong
    thing.
    """
    msg = EmailMessage()

    if not spec.omit_from:
        if spec.raw_from is not None:
            msg["From"] = spec.raw_from
        else:
            msg["From"] = f"{spec.persona.name} <{spec.persona.address}>"
    msg["To"] = f"Thresher Demo <{DEMO_ACCOUNT}>"

    if not spec.omit_subject:
        msg["Subject"] = spec.subject

    if not spec.omit_date:
        when = reference - timedelta(days=spec.offset_days)
        msg["Date"] = format_datetime(when)

    msg["Message-ID"] = spec.force_message_id or _message_id(spec.seq, seed)

    if spec.thread_root:
        msg["In-Reply-To"] = spec.thread_root
        msg["References"] = spec.thread_root

    if spec.list_unsubscribe:
        # ⚠️ The engine cannot match headers yet (OI38). These ship anyway: when
        # header matching lands the corpus already exercises it, and in the
        # meantime the gap is documented by the data rather than hidden by it.
        domain = spec.persona.address.split("@", 1)[1]
        msg["List-Unsubscribe"] = (
            f"<mailto:unsubscribe@{domain}>, "
            f"<https://{domain}/unsubscribe>"
        )
        msg["List-Id"] = f"{spec.persona.role} <list.{domain}>"

    if spec.empty_body:
        msg.set_content("")
    elif spec.html_only:
        # No plain-text alternative at all — the fallback path.
        msg.set_content(
            f"<html><body><h1>{spec.subject}</h1><p>{spec.body}</p></body></html>",
            subtype="html",
        )
    else:
        msg.set_content(spec.body)

    # RFC 5322 line endings. `as_bytes()` defaults to bare \n, which is fine for
    # the stdlib parser but is NOT what a real message looks like coming off a
    # socket — and a fixture that differs from real mail in its line endings is
    # a fixture that cannot catch a CRLF-handling bug. policy.SMTP is the same
    # policy as default, with linesep set to \r\n.
    import email.policy
    raw = msg.as_bytes(policy=email.policy.SMTP)

    if spec.encoded_subject:
        # Rewrite the Subject line to the RAW RFC 2047 encoded-word form.
        #
        # This is done on the rendered bytes on purpose. Assigning the encoded
        # string to msg["Subject"] under policy.default makes the email package
        # re-encode it (the '=?' and '?=' get escaped), so the parser would
        # receive our encoder's output and the fixture would be testing the
        # wrong direction. The point of this fixture is to hand the parser a
        # header that ALREADY carries encoded words, exactly as a real sender
        # would emit, and only writing the bytes ourselves achieves that.
        encoded = spec.subject.encode("ascii")
        out = []
        for line in raw.split(b"\r\n"):
            if line.lower().startswith(b"subject:"):
                line = b"Subject: " + encoded
            out.append(line)
        raw = b"\r\n".join(out)

    return raw


# ── Profile builders ──────────────────────────────────────────────────────────


def _by_kind(kind: str) -> list[Persona]:
    return [p for p in PERSONAS if p.kind == kind]


def build_demo_specs(count: int, rng: random.Random) -> list[Spec]:
    """The realistic profile: demo, dev, and any --count run.

    Composition targets the spec's tier shape, but indirectly — by choosing how
    much mail of each KIND arrives, not by assigning tiers. A mailbox really is
    mostly bulk and routine colleague traffic with a thin top end, and that is
    the same shape the tier table describes.
    """
    # Shares chosen to produce the spec's distribution once the seed rules run.
    # T1 is rare by design: two or three messages from people in a group.
    plan: list[str] = []
    # T1 is rare BY DESIGN (spec: one or two messages). Group members send a
    # small fraction of the mail, not 5% of it — at 150 messages 5% was eight
    # Tier 1s, which makes the "one unread that matters" screenshot meaningless.
    plan += ["matters"] * max(2, round(count * 0.015))
    plan += ["automated"] * max(2, round(count * 0.10))
    plan += ["colleague"] * round(count * 0.42)
    plan += ["ambiguous"] * max(2, round(count * 0.05))
    plan += ["bulk"] * max(0, count - len(plan))
    plan = plan[:count]
    while len(plan) < count:
        plan.append("bulk")
    rng.shuffle(plan)

    offsets = _spread_offsets(rng, count)
    specs: list[Spec] = []

    for seq, (kind, offset) in enumerate(zip(plan, offsets), start=1):
        persona = rng.choice(_by_kind(kind))
        specs.append(Spec(
            persona=persona,
            subject=rng.choice(SUBJECTS[kind]),
            body=rng.choice(BODIES[kind]),
            offset_days=offset,
            seq=seq,
            list_unsubscribe=(kind == "bulk"),
        ))

    _add_threads(specs, rng)
    _assign_triage_states(specs, rng)
    return specs


def _add_threads(specs: list[Spec], rng: random.Random) -> None:
    """Turn a few colleague messages into two- and three-deep threads.

    Replies are placed slightly LATER than their parent (a smaller day-offset),
    so a thread reads in the right order in the detail view.
    """
    candidates = [s for s in specs if s.persona.kind == "colleague"
                  and s.offset_days > 1.0]
    rng.shuffle(candidates)
    for root in candidates[:max(1, len(specs) // 25)]:
        depth = rng.choice((1, 2))
        parent = root
        for step in range(depth):
            reply = next((s for s in specs
                          if s.thread_root is None and s is not root
                          and s.persona.kind == "colleague"
                          and s not in (parent,)), None)
            if reply is None:
                break
            reply.subject = ("Re: " + root.subject.removeprefix("Re: "))
            reply.body = THREAD_REPLIES[step % len(THREAD_REPLIES)]
            # Reply lands after the parent but before "now".
            reply.offset_days = max(0.1, parent.offset_days - rng.uniform(0.2, 0.9))
            reply.thread_root = "__root__"    # resolved to the real id at render
            reply._root_seq = root.seq        # type: ignore[attr-defined]
            parent = reply


def _assign_triage_states(specs: list[Spec], rng: random.Random) -> None:
    """A few messages in each non-new state, so the chips are not all zero.

    Only older messages get advanced — a message from an hour ago sitting in
    'done' reads as wrong in a screenshot.
    """
    older = [s for s in specs if s.offset_days > 2.0]
    rng.shuffle(older)
    n = len(specs)
    for s in older[:max(1, n // 12)]:
        s.triage_state = "done"
    for s in older[max(1, n // 12): max(2, n // 12) + max(1, n // 20)]:
        s.triage_state = "acknowledged"
    for s in older[max(2, n // 12) + max(1, n // 20):
                   max(2, n // 12) + max(1, n // 20) + max(1, n // 25)]:
        s.triage_state = "needs_action"


def build_fixture_specs(rng: random.Random) -> list[Spec]:
    """~25 messages: the edge cases, plus just enough ordinary mail to be read.

    Every entry carries a `note` saying what it pins — the manifest is
    generated from these, so the reason a fixture exists cannot drift away from
    the fixture itself.
    """
    P = {p.address: p for p in PERSONAS}
    dana = P["dana.whitfield@example.com"]
    ben = P["ben.oyelaran@example.com"]
    marta = P["marta.lindqvist@example.com"]
    security = P["security@example.net"]
    newsletter = P["newsletter@example.net"]
    alan = P["a.prosser@example.org"]

    seq = iter(range(1, 500))
    s: list[Spec] = []

    def add(**kw) -> Spec:
        spec = Spec(seq=next(seq), **kw)
        s.append(spec)
        return spec

    # ── Ordinary, well-formed mail — the baseline the edge cases deviate from.
    add(persona=dana, subject="Need your read on this before Friday",
        body=BODIES["matters"][2], offset_days=1.2,
        note="Well-formed message from a sender-group member: the sender "
             "override invariant and the happy parse path.")
    add(persona=ben, subject="Staging deploy is green again",
        body=BODIES["colleague"][0], offset_days=3.4,
        note="Ordinary colleague mail — baseline parse, no rule keywords.")
    add(persona=security, subject="Your verification code",
        body=BODIES["automated"][0], offset_days=0.3,
        note="Time-sensitive machine mail from a human-looking address; "
             "pins the subject-keyword rules (verification code -> T2).")
    add(persona=newsletter, subject="This week's staff picks",
        body=BODIES["bulk"][0], offset_days=6.5, list_unsubscribe=True,
        note="Bulk mail WITH List-Unsubscribe. The engine cannot match the "
             "header yet (OI38) — this pins the gap and is ready for the fix.")
    add(persona=alan, subject="Long overdue catch-up",
        body=BODIES["ambiguous"][0], offset_days=9.1,
        note="Human-written mail from an unknown sender — the judgement case; "
             "must fall to the engine default rather than any rule.")

    # ── Missing headers. P1: parse what we can, never fail-hard.
    add(persona=ben, subject="Notes from the retro",
        body=BODIES["colleague"][1], offset_days=11.0, omit_date=True,
        note="Missing Date header — parser falls back to now (P1), does not "
             "raise. NOTE: because the fallback is the INGESTION clock rather "
             "than the reference date, this message's age is negative when the "
             "corpus is regenerated with a past --reference-date. That is the "
             "fixture working, not a bug: its offset_days is ignored by design.")
    add(persona=ben, subject="Pipeline backfill finished overnight",
        body=BODIES["colleague"][3], offset_days=12.0, omit_from=True,
        note="Missing From header — sender_email degrades to empty, message "
             "is still stored and surfaced (P1).")
    add(persona=marta, subject="", body=BODIES["colleague"][2],
        offset_days=13.5, omit_subject=True,
        note="Missing Subject header — list row must render without one.")

    # ── Encoding.
    add(persona=marta, subject="Café meeting — décor review",
        body="Non-ASCII in the subject line and in the body: naïve, résumé, "
             "Ærø. If any of this renders as mojibake the encoding path is wrong.",
        offset_days=4.2,
        note="Non-ASCII in subject and body (UTF-8 round-trip).")
    add(persona=ben, subject="=?utf-8?q?Sp=C3=A4tschicht_handover_notes?=",
        body=BODIES["colleague"][4], offset_days=5.5, encoded_subject=True,
        note="RFC 2047 encoded-word Subject header, written pre-encoded — must "
             "decode to 'Sp\u00e4tschicht handover notes' rather than surfacing "
             "the raw =?utf-8?q?...?= form.")
    add(persona=ben, subject="Ærø field notes",
        body=BODIES["colleague"][0], offset_days=7.7,
        raw_from="=?utf-8?q?Bj=C3=B8rn_S=C3=B8rensen?= <bjorn.sorensen@example.com>",
        note="RFC 2047 encoded-word in the From display name.")

    # ── Body shapes.
    add(persona=newsletter, subject="Autumn range now in stock",
        body=BODIES["bulk"][2], offset_days=8.3, html_only=True,
        list_unsubscribe=True,
        note="HTML-only body, no plain-text part — the detail pane's HTML "
             "fallback path.")
    add(persona=ben, subject="Moving standup to half past nine",
        body="", offset_days=10.4, empty_body=True,
        note="Empty body — detail pane must not render a blank error state.")
    add(persona=marta,
        subject="Draft copy for the settings screen",
        body=("One very long single line, unbroken, to exercise wrapping in the "
              "detail pane: " + "the quick brown fox jumps over the lazy dog " * 40),
        offset_days=2.8,
        note="Very long single-line body — detail pane layout and wrapping.")
    add(persona=marta,
        subject=("A subject line that simply keeps going well past any "
                 "reasonable width so that row truncation and chip truncation "
                 "both have something real to clip against rather than a short "
                 "string that happens to fit"),
        body=BODIES["colleague"][2], offset_days=1.9,
        note="Very long subject — row and chip truncation.")

    # ── Sender display-name punctuation.
    add(persona=ben, subject="Two small things on the review",
        body=BODIES["colleague"][4], offset_days=15.5,
        raw_from='"Oyelaran, Ben" <ben.oyelaran@example.com>',
        note="Display name containing a comma — must not split into two "
             "addresses when parsed.")
    add(persona=marta, subject="Rough sketches attached for comment",
        body=BODIES["colleague"][2], offset_days=16.2,
        raw_from='"Marta \'Tosh\' Lindqvist" <marta.lindqvist@example.com>',
        note="Display name containing a quote character.")

    # ── Duplicate Message-ID (dedup path). Two messages, one id.
    dup_id = "<duplicate-message-id@example.com>"
    add(persona=ben, subject="Schema change needs a second pair of eyes",
        body=BODIES["colleague"][0], offset_days=17.0, force_message_id=dup_id,
        note="Duplicate Message-ID, first of two — dedup path.")
    add(persona=ben, subject="Schema change needs a second pair of eyes",
        body=BODIES["colleague"][0], offset_days=17.1, force_message_id=dup_id,
        note="Duplicate Message-ID, second of two — the ingest must dedup on "
             "id rather than storing both.")

    # ── Threading.
    root = add(persona=ben, subject="Who owns the onboarding copy now",
               body=BODIES["colleague"][1], offset_days=20.0,
               note="Thread root — thread_id derives from its own Message-ID.")
    r1 = add(persona=marta, subject="Re: Who owns the onboarding copy now",
             body=THREAD_REPLIES[0], offset_days=19.4,
             note="Thread reply, depth 1 — thread_id follows References root.")
    r1.thread_root = "__root__"
    r1._root_seq = root.seq            # type: ignore[attr-defined]
    r2 = add(persona=ben, subject="Re: Who owns the onboarding copy now",
             body=THREAD_REPLIES[1], offset_days=19.0,
             note="Thread reply, depth 2 — same thread, three messages total.")
    r2.thread_root = "__root__"
    r2._root_seq = root.seq            # type: ignore[attr-defined]

    # ── Band boundaries, both sides of both. These must be exact, not random.
    add(persona=ben, subject="Sprint boundary is going to slip a day",
        body=BODIES["colleague"][4], offset_days=FRESH_DAYS - 1,
        note=f"Day {FRESH_DAYS - 1}: inside the {FRESH_DAYS}-day fresh band, "
             "by one day — catches an off-by-one at the boundary.")
    add(persona=ben, subject="Notes from the retro",
        body=BODIES["colleague"][1], offset_days=FRESH_DAYS + 1,
        note=f"Day {FRESH_DAYS + 1}: outside the fresh band by one day.")
    add(persona=marta, subject="Draft copy for the settings screen",
        body=BODIES["colleague"][2], offset_days=RECENT_DAYS - 1,
        note=f"Day {RECENT_DAYS - 1}: inside the {RECENT_DAYS}-day recent "
             "band, by one day.")
    add(persona=marta, subject="Rough sketches attached for comment",
        body=BODIES["colleague"][2], offset_days=RECENT_DAYS + 1,
        note=f"Day {RECENT_DAYS + 1}: outside both bands — the oldest band.")

    # ── A Tier 1 message that is OLD, so the Tier-1-exempt carve-out in D57's
    # banding has something to sort. Without this the carve-out is untested by
    # the corpus and only luck keeps it correct.
    add(persona=dana, subject="Thoughts on the revised timeline",
        body=BODIES["matters"][3], offset_days=RECENT_DAYS + 40,
        note="An OLD message from a sender-group member: D57 bands Tier 1 at "
             "band 0 regardless of age, so this must still sort to the top.")

    _assign_triage_states(s, rng)
    return s


# ── Writing ───────────────────────────────────────────────────────────────────


def _resolve_thread_roots(specs: list[Spec], seed: int) -> None:
    """Replace the __root__ placeholder with the parent's real Message-ID."""
    by_seq = {sp.seq: sp for sp in specs}
    for sp in specs:
        if sp.thread_root == "__root__":
            root_seq = getattr(sp, "_root_seq", None)
            root = by_seq.get(root_seq) if root_seq is not None else None
            sp.thread_root = (
                root.force_message_id or _message_id(root.seq, seed)
            ) if root else None


def _filename(spec: Spec, index: int) -> str:
    """Stable, sortable, descriptive filename. Index-prefixed so directory
    listings match generation order and diffs stay readable."""
    kind = spec.persona.kind
    # Slug from the DECODED subject: fixture 010 carries a raw RFC 2047
    # encoded-word header, and slugging that verbatim yields a filename like
    # "utf-8-q-sp-c3-a4tschicht", which says nothing about what the file is.
    subject = spec.subject
    if spec.encoded_subject:
        from email.header import decode_header, make_header
        subject = str(make_header(decode_header(subject)))
    slug = "".join(
        ch.lower() if ch.isalnum() else "-"
        for ch in (subject or "no-subject")
    )[:40].strip("-")
    while "--" in slug:
        slug = slug.replace("--", "-")
    return f"{index:03d}-{kind}-{slug or 'message'}.eml"


def write_corpus(specs: list[Spec], out_dir: Path, reference: datetime,
                 seed: int) -> list[tuple[Path, Spec]]:
    _resolve_thread_roots(specs, seed)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Remove any .eml this generator previously wrote, so a smaller run does not
    # leave a larger one's leftovers behind and quietly change the corpus.
    for stale in out_dir.glob("*.eml"):
        stale.unlink()

    written: list[tuple[Path, Spec]] = []
    for index, spec in enumerate(sorted(specs, key=lambda s: s.seq), start=1):
        path = out_dir / _filename(spec, index)
        path.write_bytes(_render(spec, reference, seed))
        written.append((path, spec))
    return written


def write_manifest(written: list[tuple[Path, Spec]], out_dir: Path,
                   profile: str, seed: int, reference: datetime) -> None:
    """A human-readable index of what each fixture pins.

    Generated from the specs' own `note` fields, so the stated reason a fixture
    exists cannot drift away from the fixture. This is the artifact that answers
    "what would we lose by deleting this file?" without opening it.
    """
    lines = [
        f"# {profile} corpus — what each message pins",
        "",
        "Generated by `scripts/generate_corpus.py`. Do not edit by hand;",
        "edit the generator and regenerate.",
        "",
        f"- profile: `{profile}`",
        f"- seed: `{seed}`",
        f"- reference date: `{reference.isoformat()}`",
        f"- messages: {len(written)}",
        "",
        "Dates are stored relative to the reference date above, so regenerating",
        "with a different reference keeps every message at the same age.",
        "",
        "| File | Sender | Age (days) | Pins |",
        "| --- | --- | --- | --- |",
    ]
    for path, spec in written:
        sender = "(no From)" if spec.omit_from else spec.persona.address
        note = spec.note or f"{spec.persona.kind} mail — volume and variety."
        lines.append(
            f"| `{path.name}` | {sender} | {spec.offset_days:.1f} | {note} |"
        )
    (out_dir / "MANIFEST.md").write_text("\n".join(lines) + "\n")


# ── Ingestion + reporting ─────────────────────────────────────────────────────
#
# The corpus is fed through the REAL pipeline: the same parser the poller uses
# and the same classification engine. A bespoke DB writer here would be a second
# ingestion path that rots unnoticed, which is the reason no .db is committed.


def _import_backend(backend_dir: Path):
    if str(backend_dir) not in sys.path:
        sys.path.insert(0, str(backend_dir))
    from db import database                      # noqa: E402
    from ingestion.parser import parse_message   # noqa: E402
    from classification.engine import ClassificationEngine  # noqa: E402
    return database, parse_message, ClassificationEngine


def _init_shipped_db(database, db_path: Path):
    """Initialize a database seeded from `seed.example.sql`, ALWAYS.

    ⚠️ `init_db(seed=True)` prefers a local `seed.sql` when one exists — a
    developer's real senders — and falls back to the committed example. That is
    right for running the app and WRONG for this generator: the corpus is
    verified against what a stranger receives, and a stranger only ever gets
    `seed.example.sql`.

    Measured, not assumed: reporting against a local seed.sql showed 9 enabled
    rules with no machine-mail keywords and a work-domain rule naming a real
    employer, so 'Your verification code' scored T4 and the report described a
    rule set that ships to nobody. Seeding the example explicitly is the only
    way the two-sided tier report means what it claims.
    """
    conn = database.init_db(db_path, seed=False)
    example = Path(database.__file__).parent / "seed.example.sql"
    if not example.exists():
        raise SystemExit(f"missing {example} — cannot verify against the "
                         "seed a fresh install actually gets")
    conn.executescript(example.read_text())
    conn.commit()
    return conn


def ingest(written: list[tuple[Path, Spec]], db_path: Path, backend_dir: Path,
           *, populate_groups: bool) -> None:
    """Ingest the corpus into a fresh database through the real pipeline."""
    database, parse_message, _ = _import_backend(backend_dir)

    if db_path.exists():
        db_path.unlink()
    for suffix in ("-wal", "-shm"):
        side = Path(str(db_path) + suffix)
        if side.exists():
            side.unlink()

    conn = _init_shipped_db(database, db_path)
    if populate_groups:
        _populate_demo_groups(conn)

    msg_repo = database.MessageRepo(conn)
    cls_repo = database.ClassificationRepo(conn)
    rules_repo = database.RulesRepo(conn)
    engine = _build_engine(rules_repo)

    from ingestion.pipeline import to_envelope    # noqa: E402

    for index, (path, spec) in enumerate(written, start=1):
        message = parse_message(
            path.read_bytes(),
            message_id=f"{DEMO_ACCOUNT}:{index}",
            account=DEMO_ACCOUNT,
        )
        msg_repo.insert(message)
        result = engine.classify(to_envelope(message))
        cls_repo.upsert(database.Classification(
            message_id=message.id,
            urgency_tier=result.urgency_tier,
            category=result.category,
            triage_state=spec.triage_state,
            classified_at=result.classified_at,
            rule_matches=result.rule_matches,
        ))
    conn.close()


def _build_engine(rules_repo):
    from classification.engine import ClassificationEngine  # noqa: E402
    return ClassificationEngine(
        rules=rules_repo.all_enabled(),
        sender_groups=rules_repo.all_sender_groups(),
    )


def _populate_demo_groups(conn) -> None:
    """Give the seeded groups their demo members.

    This is the honest half of the trap's resolution (spec §1): the demo corpus
    ships with populated sender groups and the documentation says so, because
    that is the app's actual intended use. What must never happen is a
    screenshot implying a FRESH install produces this.
    """
    for group_name, floor, patterns in DEMO_SENDER_GROUPS:
        row = conn.execute(
            "SELECT id FROM sender_groups WHERE group_name = ?", (group_name,)
        ).fetchone()
        if row is None:
            cur = conn.execute(
                "INSERT INTO sender_groups (group_name, email_pattern, "
                "urgency_floor, notes) VALUES (?, '', ?, ?)",
                (group_name, floor, "Demo corpus member"),
            )
            group_id = cur.lastrowid
        else:
            group_id = row["id"]
        conn.execute("DELETE FROM sender_group_patterns WHERE group_id = ?",
                     (group_id,))
        for pattern in patterns:
            conn.execute(
                "INSERT INTO sender_group_patterns (group_id, pattern) "
                "VALUES (?, ?)", (group_id, pattern),
            )
    conn.commit()


def classify_distribution(written: list[tuple[Path, Spec]], backend_dir: Path,
                          *, populate_groups: bool) -> dict[int, int]:
    """Classify the corpus in a throwaway DB and return {tier: count}.

    Used for the two-sided report. Runs against a temporary database so it can
    be called twice — once with groups populated, once empty — without either
    run contaminating the other.
    """
    import tempfile
    database, parse_message, _ = _import_backend(backend_dir)
    from ingestion.pipeline import to_envelope    # noqa: E402

    with tempfile.TemporaryDirectory() as tmp:
        conn = _init_shipped_db(database, Path(tmp) / "report.db")
        if populate_groups:
            _populate_demo_groups(conn)
        else:
            # A fresh install's groups ship memberless. Clear BOTH the child
            # table and the deprecated column, because the engine falls back to
            # the column when the table is empty (OI36) — clearing only one
            # would report a fresh install as better than it is.
            conn.execute("DELETE FROM sender_group_patterns")
            conn.execute("UPDATE sender_groups SET email_pattern = ''")
            conn.commit()

        engine = _build_engine(database.RulesRepo(conn))
        counts: dict[int, int] = {}
        for index, (path, _spec) in enumerate(written, start=1):
            message = parse_message(path.read_bytes(),
                                    message_id=f"{DEMO_ACCOUNT}:{index}",
                                    account=DEMO_ACCOUNT)
            result = engine.classify(to_envelope(message))
            counts[result.urgency_tier] = counts.get(result.urgency_tier, 0) + 1
        conn.close()
    return counts


def _format_distribution(counts: dict[int, int], total: int) -> str:
    parts = []
    for tier in range(1, 6):
        n = counts.get(tier, 0)
        pct = (100.0 * n / total) if total else 0.0
        parts.append(f"    T{tier}: {n:4d}  ({pct:4.1f}%)")
    return "\n".join(parts)


def report(written: list[tuple[Path, Spec]], backend_dir: Path) -> int:
    """Print the two-sided tier report. Returns the groups-empty tier count.

    BOTH numbers are printed, always. The groups-populated number is what a
    screenshot shows; the groups-empty number is what a stranger gets on a
    fresh install, and keeping it visible is what stops the demo data from
    papering over OI38.
    """
    total = len(written)
    populated = classify_distribution(written, backend_dir, populate_groups=True)
    empty = classify_distribution(written, backend_dir, populate_groups=False)

    print(f"\nTier distribution over {total} messages\n")
    print("  With demo sender groups populated (what a screenshot shows):")
    print(_format_distribution(populated, total))
    print(f"    distinct tiers: {len(populated)}")
    print("\n  With sender groups EMPTY (what a fresh install produces):")
    print(_format_distribution(empty, total))
    print(f"    distinct tiers: {len(empty)}")

    if len(empty) == 1:
        print("\n  ⚠️  A fresh install puts every message in ONE tier. That is")
        print("      OI38: the seed rules cannot see List-Unsubscribe, so bulk")
        print("      mail falls through to the default. Any README caption must")
        print("      not imply a fresh install produces a tiered list.")
    return len(empty)


# ── CLI ───────────────────────────────────────────────────────────────────────


def _parse_reference(raw: Optional[str]) -> datetime:
    """The reference date. Defaults to now, so demo data stays fresh; pinned by
    --reference-date so tests stay deterministic."""
    if raw is None:
        return datetime.now(timezone.utc)
    for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try:
            parsed = datetime.strptime(raw, fmt)
        except ValueError:
            continue
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    raise SystemExit(f"unparseable --reference-date: {raw!r} "
                     "(expected YYYY-MM-DD or an ISO-8601 timestamp)")


def main(argv: Optional[list[str]] = None) -> int:
    repo_root = Path(__file__).resolve().parents[1]

    ap = argparse.ArgumentParser(
        description="Generate a synthetic mail corpus (see "
                    "docs/synthetic-corpus-spec.md).")
    ap.add_argument("--profile", choices=("fixtures", "demo", "dev"),
                    default="demo")
    ap.add_argument("--count", type=int, default=None,
                    help="override the profile's message count (ignored for "
                         "the fixtures profile, whose contents are enumerated)")
    ap.add_argument("--out", type=Path, default=None,
                    help="directory for the .eml files")
    ap.add_argument("--seed", type=int, default=20260912,
                    help="RNG seed; same seed + reference date = identical output")
    ap.add_argument("--reference-date", default=None,
                    help="treat this instant as 'now' (YYYY-MM-DD or ISO-8601)")
    ap.add_argument("--ingest", type=Path, default=None,
                    help="also ingest into this SQLite path via the real pipeline")
    ap.add_argument("--no-groups", action="store_true",
                    help="with --ingest, leave sender groups empty (what a "
                         "fresh install looks like)")
    ap.add_argument("--report", action="store_true",
                    help="print the tier distribution, both with demo sender "
                         "groups populated and with them empty")
    ap.add_argument("--backend-dir", type=Path, default=repo_root / "backend")
    args = ap.parse_args(argv)

    reference = _parse_reference(args.reference_date)
    rng = random.Random(args.seed)

    if args.profile == "fixtures":
        specs = build_fixture_specs(rng)
        default_out = repo_root / "backend" / "tests" / "corpus"
    else:
        count = args.count or PROFILE_COUNTS[args.profile]
        specs = build_demo_specs(count, rng)
        default_out = repo_root / "corpus" / args.profile

    out_dir = args.out or default_out
    written = write_corpus(specs, out_dir, reference, args.seed)
    write_manifest(written, out_dir, args.profile, args.seed, reference)

    print(f"Wrote {len(written)} .eml files to {out_dir}")
    print(f"  profile={args.profile} seed={args.seed} "
          f"reference={reference.isoformat()}")

    if args.ingest:
        ingest(written, args.ingest, args.backend_dir,
               populate_groups=not args.no_groups)
        print(f"  ingested into {args.ingest} "
              f"(sender groups {'empty' if args.no_groups else 'populated'})")

    if args.report:
        report(written, args.backend_dir)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
