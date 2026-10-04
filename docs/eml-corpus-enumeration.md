# What the real `.eml` corpus pinned — and what replaces it

> **Why this document exists.** The synthetic-corpus spec requires that before
> the real `.eml` files are deleted, we enumerate what behaviours they pin and
> confirm the synthetic fixtures pin the same ones — because *a fixture replaced
> by a prettier one that tests less is a regression that looks like progress.*
>
> Written 2026-09-12, alongside `scripts/generate_corpus.py`.

---

## The finding that changes the shape of this task

**The 15 real `.eml` files are not in the repository, are not on this machine,
and were never loaded by a single test.**

Three independent checks, all run rather than assumed:

| Check | Result |
| --- | --- |
| `find` for `*.eml` across the repo | **0 files** |
| `find` for `*.eml` across the whole filesystem and `$HOME` | **0 files** |
| `git log --diff-filter=D -- '*.eml'` (were they ever committed and removed?) | **no commits** |
| `grep` for `.eml`, `open(`, `read_bytes`, `glob` in `backend/tests/` | **no test loads any file as mail** |

`.gitignore` records the same conclusion from the other direction, written at
git-init time:

```
*.eml
# No .eml corpus directory exists in this repo (§1 inventory confirmed); the
# *.eml glob above stays as a defensive guard for any future corpus.
```

So there is **nothing to delete**, and no test can break by deleting it. The
requirement is still worth honouring, because the real question underneath it —
*are we about to lose coverage?* — has a real answer, below.

### What the corpus actually was

`project-log.md` §Assets: *"15 real `.eml` files provided across all three
accounts, hand-labeled by the author with his desired handling. **These are a labeled
test corpus** — strong candidate to become acceptance-criteria fixtures in the
spec/TDD work later."*

They were **input to design, not input to a test runner**. the author labeled them with
the handling he wanted; that labeling produced the E1–E6 observations that shaped
the tier model. The "strong candidate to become fixtures" step never happened.

### One correction to the inherited record

`docs/public-repo-readiness.md` says to *"ship synthetic fixtures hand-built to
exercise the same edge cases (E1–E10)."* That citation is wrong, and following
it would send the next reader to the wrong place:

- **E1–E6** are the corpus's *labeling observations* (relationship overrides
  content, sender role drives urgency, forwarded mail, reference-vs-noise,
  domain ≠ urgency). These are classification-model findings.
- **E7–E10** are unrelated *session defect notes* (a Keychain error routed
  through IMAP retry; a `--once` double-poll race; digest `message_id` NULL;
  a reused serializer breaking on a narrower query).

They are two different numbering schemes that collided. Only E1–E6 have anything
to do with the corpus.

---

## Part 1 — the classification behaviours (E1–E6)

These came *from* the corpus. They are pinned today by engine tests, not by mail
files, and the synthetic corpus additionally exercises each one end-to-end.

| # | Behaviour the real corpus surfaced | Pinned today by | Synthetic coverage |
| --- | --- | --- | --- |
| **E1** | Relationship overrides content — a known sender's mail is signal even when it reads like noise | `test_engine.py` (sender-override invariant) | Group members (`dana.whitfield@`, `ben.oyelaran@`) send ordinary-looking mail that still floors to their group tier |
| **E2** | Sender role drives urgency — leadership elevates to the top tier | `test_engine.py`, seed rules 10/11 | `leadership` group → T1; verified T1 = 2 messages in the demo profile |
| **E3** | Forwarded mail — who forwarded it may matter more than the original source | Not implemented | **DEFERRED by D73**, not a gap. No fixtures, deliberately — see below |
| **E4** | Reference-vs-noise are distinct (keep-but-never-read vs don't-care) | Tier 4 vs Tier 5 split in the seed | Bulk personas split across both: `no-reply@`/`newsletter@`/`marketing@` reach T5; `hello@`, `security@` do not |
| **E5** | Confluence page-change subscriptions | Out of scope, self-flagged | n/a — out of scope |
| **E6** | Domain ≠ urgency — a work-domain sender not in a group is T4/Work, not urgent | `test_engine.py`, seed rule 30 | Colleague personas on `example.com` who are *not* in `close_colleagues` classify T4, category work |

### E3 is a deferral, and that is a decision (D73)

**Forwarded-mail handling is out of scope for v1 — a possible future
enhancement, not an oversight.** It is stated in `README.md` under Limitations
so a user meets it as a boundary rather than as surprising behaviour.

The distinction matters for whoever reads this next. An *unimplemented
observation* invites someone to "fix" it; a *recorded decision* tells them the
scope question was asked and answered.

**Why it is a feature rather than a rule.** The naive version —
`subject startswith 'Fwd:'` — matches the mechanics and misses the point. The
signal E3 describes is the **relationship to the forwarder**, and that is
already handled: mail forwarded by someone in a sender group arrives *from*
that group member and is floored by the sender-override invariant today. What
is genuinely unhandled is the **original sender inside the forwarded body**,
and reaching it means either parsing quoted headers out of body text (no
standard format, unreliable) or opening `message/rfc822` attachments, which the
ingestion path does not currently do.

**No fixtures, deliberately.** `Fwd:` messages in the corpus would *look* like
they cover E3 while asserting nothing — precisely the "prettier fixture that
tests less" regression this document exists to prevent.

---

## Part 2 — the parsing behaviours

This is where the real risk of silent coverage loss would have been, had the
files been wired in. They were not: `backend/tests/test_parser.py` builds every
message with `EmailMessage()` in code.

The synthetic **fixtures profile** is strictly additive over that suite:

| Behaviour | `test_parser.py` | Synthetic fixture |
| --- | --- | --- |
| Well-formed message → all fields | ✅ | `001`, `002` |
| Multipart: plain + HTML both extracted | ✅ | present in demo profile |
| RFC 2047 encoded-word **subject** | ✅ | `010` — written **pre-encoded at the byte level** |
| RFC 2047 encoded-word **display name** | ❌ | `011` — **new coverage** |
| Bare address with no display name | ✅ | — |
| Missing `From` | ✅ (unit level) | `007` — **new at corpus level** |
| Missing `Date` → falls back to now (P1) | ✅ | `006` |
| Malformed `Date` does not raise | ✅ | — |
| Missing `Subject` | ❌ | `008` — **new coverage** |
| Thread id from `References` root | ✅ | `020`/`021`/`022` (3-deep thread) |
| Thread id falls back to own `Message-ID` | ✅ | `020` |
| `raw_headers` captured as dict | ✅ | all |
| **HTML-only body, no plain part** | ❌ | `012` — **new coverage** |
| **Empty body** | ❌ | `013` — **new coverage** |
| **Very long single-line body** | ❌ | `014` — **new coverage** |
| **Very long subject** (row/chip truncation) | ❌ | `015` — **new coverage** |
| **Display name containing a comma** | ❌ | `016` — **new coverage** |
| **Display name containing a quote** | ❌ | `017` — **new coverage** |
| **Duplicate `Message-ID` across two messages** | ❌ | `018`/`019` — **new coverage** |
| **Non-ASCII in subject *and* body** | ❌ | `009` — **new coverage** |
| **`List-Unsubscribe` present** (OI38) | ❌ | `004`, `012` — **new coverage**, documents the gap |
| **Band boundaries, both sides of both** | ❌ | `023`(13d) `024`(15d) `025`(89d) `026`(91d) |
| **Old Tier 1 — D57 band-0 carve-out** | engine test only | `027` at 130 days |

**Net: nothing is lost and fourteen behaviours gain coverage they did not have.**

---

## Part 3 — the honest verification numbers

Run on 2026-09-12 with `--reference-date 2026-09-12 --seed 20260912`, against
**`seed.example.sql`** — the seed a stranger actually gets.

> ⚠️ **This detail matters and was nearly got wrong.** `init_db(seed=True)`
> prefers a local `seed.sql` when one exists (a developer's real senders) and
> only falls back to the committed example. Reporting through that path measured
> a 9-rule private seed naming a real employer — a rule set that ships to nobody.
> `generate_corpus.py` seeds `seed.example.sql` **explicitly** for this reason.

### Demo profile, 150 messages

| Tier | Groups populated (what a screenshot shows) | Groups empty (what a stranger sees) |
| --- | --- | --- |
| T1 | 2 (1.3%) | 0 |
| T2 | 31 (20.7%) | 15 (10.0%) |
| T3 | 16 (10.7%) | 21 (14.0%) |
| T4 | 57 (38.0%) | 70 (46.7%) |
| T5 | 44 (29.3%) | 44 (29.3%) |
| **distinct tiers** | **5** | **4** |

The spec requires at least four distinct tiers with groups populated: **5 ✅**.

### The groups-empty number, which is the point

The spec says this number "right now is 1". **With this corpus it is 4** — and
that is not the corpus flattering the rule set. It is four tiers because the
corpus contains mail the *existing* seed rules can genuinely see:

- **T2** — subjects carrying `verification code`, `security alert`,
  `password reset`, `one-time`, `invitation:` (seed rules 52–57)
- **T3** — subjects carrying `JIRA` / `GitHub` (seed rules 60–61)
- **T5** — senders beginning `no-reply@` / `newsletter@` / `marketing@`
  (seed rules 80–86)
- **T4** — everything else, by engine default

**T1 is 0 with groups empty, and that is the finding to keep visible.** Both
Tier 1 rules target sender groups, and a fresh install ships those groups
memberless — so *a stranger cannot get a Tier 1 message at all* until they tell
the app who matters. That is exactly the trap the spec's §1 is about, and no
README caption may imply otherwise.

The "1 tier" figure in the spec came from a **real** mailbox cold-start, where
the mail was overwhelmingly list mail that the address-pattern rules cannot see
(OI38: the reliable signal is `List-Unsubscribe`, which the engine cannot match).
That remains true, and the corpus carries `List-Unsubscribe` headers on all bulk
mail so the gap is exercised the day OI38 lands rather than discovered then.

### Fixtures profile, 27 messages

| | Groups populated | Groups empty |
| --- | --- | --- |
| distinct tiers | 4 | 3 |

Lower on purpose — fixtures optimise for edge cases, not distribution.

### Other spec requirements

| Requirement | Result |
| --- | --- |
| Two runs, same seed + reference → identical | ✅ byte-identical |
| A *different* seed changes output | ✅ (so `--seed` is not decorative) |
| A *different* reference date changes output | ✅ |
| Date spread covers both boundaries, both sides | ✅ 13/15 and 89/91 days |
| Reserved domains only | ✅ only `example.com`/`.org`/`.net` |
| No real name or address from the real corpus | ✅ 0 hits for every private term |
| Triage states populated (chips not all zero) | ✅ new 125 / done 12 / ack 7 / needs_action 6 |
| Stdlib only | ✅ |

The single non-reserved address in the corpus is **`thresher.demo@gmail.com`**,
the throwaway demo identity, which appears only as the `To:` recipient.

---

## Part 4 — two guards that could not fail, caught by sabotage

The fixture tests were written, passed, and were then **deliberately sabotaged**
to check they could fail. Two of them could not. Both are the same shape the
project has hit repeatedly: *a check that tests a model of the thing rather than
the thing.*

**1. The RFC 2047 encoded-subject guard.** It accepted *any* fixture whose
Subject contained an encoded word. Fixture 009 carries a non-ASCII subject that
the email package encodes automatically, so blanking fixture 010's header
entirely still passed — the guard asserted "some encoded subject exists
somewhere", not the claim its name made. Now it names fixture 010 and additionally
requires the decoded text to contain a non-ASCII character.

The two fixtures pin **opposite directions**, which is why one cannot stand in
for the other: 009 exercises our *encoder* (non-ASCII in → valid header out),
010 exercises the *decoder* (a header written pre-encoded by hand, as a foreign
sender would emit it).

**2. The band-boundary guard.** It took **two** attempts:

| Version | Passed against the sabotage because |
| --- | --- |
| `boundary - 2 <= a < boundary` | fixture 007 (12 days, pins a missing `From`) fell in the window |
| `a == boundary - 1` on `.days` | fixture 008 (13.5 days, pins a missing `Subject`) **truncates to 13** |
| `abs(a - 13.0) < 0.01` on fractional days | ✅ fails correctly |

Unrelated fixtures kept wandering into the window. The fix was to measure age to
the fractional day: a deliberate boundary fixture is generated at a whole-number
offset, an incidental one essentially never is.

**The lesson, in the form worth carrying:** both guards were written from a
mental model of which fixture would satisfy them, and in both cases a *different*
fixture did. Deleting the fixture a guard exists to protect is the only way to
learn that — so **when writing a guard, write its sabotage too.**

---

## Conclusion

Deleting the real `.eml` files costs **no test coverage**, because no test ever
read them. Their real contribution was the E1–E6 design observations, which are
recorded in `project-log.md`, pinned by engine tests, and — apart from E3, which
is deferred by **D73** — exercised by the synthetic corpus.

The synthetic fixtures pin **everything the parser suite already pinned, plus
fourteen behaviours it did not.**
