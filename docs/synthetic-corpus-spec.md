# Spec — The Synthetic Corpus

> **Why this exists:** the 15 hand-labeled `.eml` files are real third-party
> mail and can never be published. Everything that depends on them — tests,
> screenshots, and a contributor's first run — needs a synthetic replacement.
>
> **Three consumers, one generator.** They want different things, so this is a
> generator with parameters, not a flat pile of files.

---

## The trap, before anything else

**If the demo mail is designed to match the shipped seed rules, every screenshot
shows a beautifully tiered inbox that a real user will not get.**

We know this precisely, because it has now happened three times: a real mailbox
cold-started twice and produced **15 of 15 at T4**, then **15 of 15 again**. The
seeded rules cannot see `List-Unsubscribe` (OI38), so real automated mail falls
straight through. If we hand-tune synthetic senders so the seed rules light them
up, the README will advertise a product that does not exist yet.

**Resolution: the demo corpus ships with populated sender groups, and the
documentation says so.** Screenshots show the app *after* the user has told it
who matters — which is honest, is the actual intended use, and is exactly what
the deferred *ask* onboarding step will automate in Thresher.

**What the screenshots must not do** is imply a fresh install produces a tiered
list with no configuration. Whatever the README shows, its caption has to be
true on the day someone downloads it.

---

## Three consumers

| Consumer | Wants | Hates |
| --- | --- | --- |
| **Test fixtures** | Edge cases, malformed input, determinism, small | Volume; pretty content |
| **Screenshots** | Plausible, attractive, all tiers visible, ~40 rows | Ugly edge cases; lorem ipsum |
| **Contributor dev data** | Volume, variety, realistic date spread | Hand-editing; a fixed corpus that goes stale |

One generator, one shared persona pool, three profiles. Sharing the pool is what
makes a fixture and a screenshot feel like the same product.

---

## Architecture

A single script — Python, stdlib only, matching the D68 constraint — producing:

- **`fixtures/`** — small, deterministic, edge-case heavy. Committed.
- **`demo/`** — a seeded database plus its `.eml` sources, generated on demand
  by count. Committed at a default size; regenerable.

Both from the same personas, subjects and generators, so the two never drift into
looking like different applications.

---

## Dates: the part most likely to be got wrong

⚠️ **Dates must be relative to generation time, not absolute.**

The sort bands are hardcoded at 14 and 90 days. A corpus with fixed dates is
correct on the day it is generated and wrong forever after — within a month every
message is "recent", within a quarter everything falls outside both bands, and
the feature the screenshot was demonstrating stops working.

- Generate offsets from *now*, not timestamps
- Accept a `--reference-date` override so **tests stay deterministic** while demo
  data stays fresh
- Spread deliberately across the boundaries: some inside 14 days, some between 14
  and 90, some beyond — so band behaviour is visible and testable
- Include at least one message either side of each boundary, close enough to
  catch an off-by-one

---

## Personas

Ten to fifteen, reused across all profiles. Each needs a name, an address, a
role, and a writing register — because a screenshot where every subject sounds
the same reads as generated.

**Categories to cover**, since these are what the tier system exists to separate:

- **Two or three people who matter** — the ones a user would put in a group.
  Direct, short, often a question.
- **Colleagues** — routine work mail, threads, replies.
- **Automated but important** — password resets, security alerts, verification
  codes, calendar invitations. Machine-written, time-sensitive.
- **Bulk and promotional** — newsletters, order confirmations, marketing.
  ⚠️ Include `List-Unsubscribe` headers on these even though the engine cannot
  match them yet. When OI38 lands, the corpus should already exercise it — and
  in the meantime it documents the gap rather than hiding it.
- **One or two ambiguous** — a human-written message from an unknown sender. This
  is the interesting case and the reason the tier system needs judgement.

### Address rules

- Domains: `example.com`, `example.org`, `example.net` only — these are reserved
  by RFC 2606 and cannot be registered by anyone
- **No real domains at all**, including plausible-looking ones. A synthetic
  message from `noreply@amazon.com` is a fake message impersonating a real
  company, and it will end up in a public repo and in screenshots.
- **Nothing derived from the author's mailbox** — not a name, not a subject, not a
  sender. The batch 3 sweep found two addresses that a term list missed; do not
  reintroduce the problem from the other direction.
- Ordinary invented names. Not celebrities, not obvious jokes, not `Foo Bar`.

---

## Content

**Subjects and bodies must read like mail**, not like test data. `Test 91` is
what the real corpus is full of and it is why the current screenshots look like a
debugging session rather than a product.

- Subjects: 3–8 words, varied register, no numbering scheme
- Bodies: two to five sentences, plain text. Enough that the detail pane is not
  empty in a screenshot.
- A few threads — same subject with `Re:`, two or three deep
- Nothing that reads as a real security alert or payment notice from a real
  institution. Plausible, not impersonating.
- No content that would embarrass anyone if it appeared in a conference slide

---

## Tier distribution

Aim for a shape that is **realistic first, demonstrative second**:

| Tier | Share | Notes |
| --- | --- | --- |
| T1 | 1–2 messages | Rare by design. One unread in a screenshot is the point. |
| T2 | ~10% | Time-sensitive machine mail |
| T3 | ~25% | Ordinary human mail |
| T4 | ~40% | The bulk of anything |
| T5 | ~25% | Newsletters, promotional |

⚠️ **Assert the distribution, not merely that classification ran.** A corpus
where everything lands in one tier passes a "classification works" check — which
is precisely how the current seed shipped.

Also include a few messages in each triage state — acknowledged, needs action,
done — so those chips are not all zero in a screenshot.

---

## Edge cases (fixtures profile only)

Keep these out of the demo profile; they exist to break things, not to be
photographed.

- Missing `Date`, missing `From`, missing `Subject`
- Non-ASCII in names and subjects, and an RFC 2047 encoded-word header
- HTML-only body with no plain-text part
- Duplicate `Message-ID` across two messages (dedup path)
- A very long subject (chip and row truncation)
- A very long single-line body (detail pane layout)
- Empty body
- A sender whose display name contains a comma or a quote
- Timestamps either side of both the 14- and 90-day boundaries

Whatever the real 15 `.eml` files were pinning, **the synthetic set must pin the
same behaviours.** Enumerate what they covered before deleting them; a fixture
replaced by a prettier one that tests less is a regression that looks like
progress.

---

## Volume

- **fixtures**: ~25 messages. Enough for the edge cases, small enough to read.
- **demo default**: ~400. Enough for realistic chip counts, paging past the
  first page, and a populated date spread.
- `--count` parameter for larger runs — a contributor reproducing the
  100-message truncation bug needs more than 400.

---

## Constraints

- **Deterministic under a fixed seed.** Same seed and reference date produce
  byte-identical output, or screenshots cannot be reproduced and tests will flake.
- Stdlib only. No new third-party dependency — flask being the only one is what
  makes the 12 MB self-contained app possible.
- The generator is committed and documented. A contributor regenerating the demo
  data is a supported action, not a maintainer-only step.

---

## Verification

- Generated corpus classifies into **at least four distinct tiers** with the
  demo sender groups populated
- Generated corpus classifies into **the tiers a real fresh install would
  produce** with groups empty — and **report that number**, because it is the
  honest measure of what a stranger sees, and right now it is 1
- Date spread covers both band boundaries on both sides
- Two runs with the same seed produce identical output
- No `example`-adjacent-but-real domain anywhere; no name from the real corpus
- Fixtures still pin every behaviour the real `.eml` files pinned

---

## Resolved decisions

### What ships in the repo

**Commit the generator and the fixtures. Never commit a demo database.**

| Artifact | Size | Committed? |
| --- | --- | --- |
| Generator script | a few KB | Yes |
| `fixtures/` — ~25 `.eml` | ~60 KB | Yes — tests must not depend on a generation step |
| `demo/` — ~400 `.eml` | ~1 MB | No — generated on demand |
| Generated `.db` | ~2–4 MB | **Never** |

A committed database is a binary blob that cannot be diffed or reviewed, and it
goes stale the moment the schema changes. Generating on demand also exercises the
real ingestion path rather than bypassing it. Total repo cost is well under
100 KB.

### Demo mode — a fourth consumer, deferred but design-relevant

the author has decided the **"Try with sample data" button ships**, in Thresher, with
*ask* and *propose*. The generator must account for it now, because a corpus that
ships **inside the app** has different constraints from a dev-only one.

**The separation mechanism, decided:** demo mode uses **its own database file**
(`demo.db`) alongside the real store — not tagged rows in one database. Exiting
demo mode deletes a file. There is no code path where demo and real data can
meet, and no surgical row-removal step to get wrong. Messages, classifications,
rules, groups, preferences and triage state are all separate by construction.

The app bundles the `.eml` corpus and runs it through the **real ingestion
pipeline** on first entry, for the same reason no `.db` is committed: a special
demo path would rot unnoticed, while the real path is exercised constantly.

Three constraints, cheap now and expensive to retrofit:

- **Permanently visible.** A persistent banner, not a one-time dialog. The
  failure to avoid is a user evaluating for ten minutes, forgetting, and
  wondering why their real mail never arrives.
- **No network.** No IMAP, no polling, no write-back. The poller must *refuse to
  start* rather than start and find nothing — a clean exit that looks identical
  to success is the exact shape this project has repeatedly been bitten by.
- **Exit is one-way and explicit.** Leaving deletes `demo.db` and begins real
  onboarding. No "switch back", because that is where mixing pressure comes from.

**Open decision:** should demo mode fire notifications? It demonstrates the core
feature; banners from fake mail during an evaluation could equally read as the
app misbehaving.

**Consequence for this spec:** the bundled demo corpus wants to be **smaller than
the dev corpus** — around 150 messages, roughly 400 KB inside the app bundle —
and it has to *look good*, because it is a stranger's first impression of the
product rather than test data. Add it as a fourth profile.

### Sample-data mode

Two different things, previously conflated:

- **Pointing the app at a generated demo database** is a maintainer action — run
  the generator, place the result, launch, screenshot. No feature, nothing
  shipped. **This is in scope now**, because screenshots need it.
- **A "Try with sample data" button in onboarding** is a product feature, for a
  stranger evaluating Thresher without supplying a Gmail app password. Needs UI,
  an exit path to real mail, and protection against a user forgetting they are in
  demo mode. **Deferred to Thresher**, alongside *ask* and *propose*.

### Screenshots carry the README

the author's answer: heavily, covering three narratives — how easy setup is, how it is
used, and how it is configured. That raises the bar on personas and subjects, and
it creates one problem that needs solving before any screenshot is taken.

⚠️ **Onboarding screenshots need a real IMAP connection.** The retrieval-window
screen shows a live "about N messages" preview, which cannot be faked. Using
the author's own mailbox would put a personal address on the repo's front page.

**Create a throwaway Gmail account** — e.g. `thresher.demo@gmail.com` — and use
its address as the demo account identity **throughout the generated corpus**, so
it appears consistently in the message list, in Settings, and in the onboarding
shots. Then:

- Onboarding screenshots are genuine rather than mocked
- No personal address appears anywhere
- Cold-start testing stops running against the author's real mailbox, which it has now
  done five times

**Screenshot set to plan for** (8–12 rather than 4–6):

- Onboarding: connect, retrieval window with its preview, completion
- Message list with a visible tier spread and populated chips
- Message detail with the "why this tier" explanation — the differentiator
- Classification rules
- Sender groups
- Notification settings, and a notification banner

Every caption must be true on the day someone downloads the repo. In particular,
nothing may imply a fresh install produces a tiered list with no configuration.

---

## Open questions remaining

1. **Who creates the throwaway account** — it needs a real Gmail signup with 2FA
   and an app password, which is the author's to do, not an agent's.
2. **Light or dark appearance for screenshots?** Pick one and use it throughout.
   ⚠️ Light mode currently renders tier 3 yellow at roughly 1.4:1 contrast, well
   under the 4.5:1 threshold, so dark is the safer choice until that is fixed.
