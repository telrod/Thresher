# Ideas — deliberately deferred

This file collects features that were **considered and consciously not built**, as
distinct from bugs, or from work that is merely unfinished. Each entry explains
what the feature is, why it wasn't built, what it would cost, and what to watch
out for if you decide to build it.

If you're looking for somewhere to contribute, this is a good place to start —
these are real ideas with real reasoning behind them, not a wishlist. Nothing here
was skipped because it was hard. Each was skipped because the tradeoff wasn't
worth it *yet*, and the reasoning is written down so you can disagree with it on
the merits.

**Adding an entry:** only add something you actually considered and decided
against. Record the reasoning and the consequences, not just the idea — an idea
without its tradeoff is a wish, and it will get re-litigated by whoever reads it
next. If you build one of these, delete the entry and describe the feature in the
docs instead.

---

## 1. Write-back to the mail server on bulk actions

**Status:** Not built. Bulk actions are local-only, by design.

### What it is

When you mark a message Done in this app, that's a local change — it updates this
app's own database and nothing else. Your actual mailbox on the server is
untouched.

"Write-back" is the optional behavior where a triage action *also* reaches out to
the mail server and changes the message there — marking it read, archiving it,
moving it, or applying a label. For single-message actions this is reasonable.
For bulk actions it is not currently offered, and the API refuses it.

### Why it isn't built

**Cost.** Write-back is roughly **three IMAP round-trips per message**. A
realistic bulk operation on a mature mailbox — clearing everything older than a
month — can easily touch one to five thousand messages. At three round-trips
each, that's several thousand network calls behind a single button press.

**Failure mode.** That's not just slow. Mail servers throttle, connections drop,
and sessions time out. A bulk write-back that fails halfway leaves your **real
mailbox** in a partially-modified state, with no record of where it stopped. The
local-only version has no such problem: it's a single database statement that
either fully succeeds or fully fails.

**Asymmetry of consequences.** A mistake in a local bulk action hides messages
inside this app; they remain searchable here and are completely untouched on the
server. A mistake in a bulk write-back modifies thousands of real messages in your
actual mailbox. Those are not the same category of mistake, and the second one is
much harder to undo.

### If you build it

Make it a **per-operation choice, not a global setting.** The user should decide
at the moment of the action — a checkbox in the bulk confirmation dialog reading
something like *"Also apply this to my mailbox on the server"* — defaulted off,
with the message count and a plain warning that this modifies real mail.

A global preference is the wrong shape here. Bulk operations vary enormously in
what they mean: clearing three-year-old newsletters is very different from
clearing last week's mail, and a setting the user configured once and forgot will
eventually be wrong for the operation in front of them.

Suggested implementation notes:

- **Run it in the background with progress and a stop button.** A synchronous
  request that blocks for four minutes will be killed by something — a timeout, a
  proxy, an impatient user. Anything at this scale needs to be resumable.
- **Record what was actually applied**, not just what was requested, so a partial
  failure is recoverable rather than mysterious. The executed-bulk log (see below)
  is the natural place for this.
- **Do the local change first and the server change second.** If the server phase
  fails, the local state is still correct and the operation can be retried. The
  reverse order can leave the mailbox changed with no local record of it.
- **Consider a size threshold** above which the option is unavailable or requires
  a second confirmation — not because a large operation is wrong, but because a
  large *accidental* one is very expensive.

### Watch out for

The bulk endpoint resolves its target set from a **filter**, not from a list of
message ids, and freezes that set with an upper time bound captured before the
user confirms. If you add write-back, it must operate on that same frozen set —
re-running the filter at write-back time would apply server changes to messages
the user never saw or approved.

---

## 2. Undo for bulk operations

**Status:** Not built. The groundwork for it is.

### What it is

A bulk action can change thousands of messages at once. There is currently no way
to reverse one.

### Why it isn't built

Reversing a bulk action requires knowing what it *was* — the filter that selected
the messages, the time bound that froze the set, and what state each message was
in beforehand. Prior triage states are not retained, so "put it back exactly as it
was" is not expressible today.

The partial answer is cheaper: because bulk operations are filter-scoped and
time-frozen, the **inverse operation** is expressible for as long as you still
have the filter. That's not a true undo, but it covers the common case of "I
didn't mean that one."

### What exists to build on

Each executed bulk operation is recorded in an append-only log: the filter, the
frozen time bound, the timestamp, and the number of rows affected. This was built
specifically because it is **cheap at execute time and impossible to reconstruct
afterwards** — the filter and the bound exist only in that moment.

That log makes a real undo feasible without changing anything about how bulk
operations work. Building it is a matter of deciding what "undo" should mean:
reverting to a recorded prior state (requires also storing per-message prior
state, which is more expensive) or replaying the inverse filter (cheap, but
imprecise if anything changed in between).

### Watch out for

If you extend the log to store per-message prior state, remember that a single
operation can affect thousands of rows — storing a row per message per operation
will grow faster than the message table itself. Consider retention limits before
you consider the feature complete.

---

## 3. "Try with sample data" — evaluate Thresher without a mailbox

**Status:** Not built. The generator and corpus exist; the mode does not.

### What it is

An onboarding path that loads a bundled synthetic corpus into a **separate
database** instead of asking for a Gmail app password, so someone can see what
Thresher does before deciding whether to point it at their mail.

### Why it isn't built

It was deferred as a convenience — a nicety for evaluators, behind features that
served the one real user. That reasoning was incomplete, and the evidence
arrived while building this repository.

**Evaluating Thresher currently requires connecting a real mailbox.** There is
no other path. That asks a stranger to hand an unsigned, unnotarized alpha an
app password for an account containing their actual mail, before they have seen
a single screen of it working.

The obvious workaround — create a throwaway Gmail account — **does not reliably
work.** The account made for this project's screenshots was **disabled by Google
one day after signup**, flagged as likely bot-created. A fresh account used
immediately for IMAP automation fits that pattern, so this is a predictable
outcome rather than bad luck. The two onboarding screenshots that needed a live
IMAP connection were cancelled for this reason, and that is why the repository's
setup narrative is prose rather than pictures.

So the honest statement of the gap is not "evaluation is inconvenient" but
**there is no safe way to evaluate this at all**: either expose a mailbox you
care about, or use a throwaway account that may be disabled before you finish.

### What exists to build on

Most of the work is already done, which is what makes the omission awkward:

- **`scripts/generate_corpus.py`** produces the corpus, including a `demo`
  profile (~150 messages) sized and written to be looked at rather than tested
  against. Stdlib only, deterministic under a fixed seed.
- **The corpus ingests through the real pipeline** (`--ingest`), so a demo path
  exercises production code rather than a parallel implementation that would rot
  unnoticed.
- **`docs/synthetic-corpus-spec.md` already settles the design.** Demo mode gets
  **its own database file** rather than tagged rows in the real one, so exiting
  deletes a file and there is no code path where demo and real data can meet.

The remaining work is the UI, the entry and exit paths, and the guard rails.

### Watch out for

- **Make it permanently visible.** A persistent banner, not a one-time dialog.
  The failure to avoid is someone evaluating for ten minutes, forgetting, and
  later wondering why their real mail never arrives.
- **No network at all in demo mode.** The poller must *refuse to start* rather
  than start and find nothing — a clean exit that looks identical to success is
  precisely the shape this project has been bitten by before.
- **Exit is one-way and explicit.** Leaving deletes the demo database and begins
  real onboarding. No "switch back", because that is where pressure to mix the
  two comes from.
- **Say what the sample data cannot show.** The corpus is classified with sender
  groups populated; a real fresh install cannot reach Tier 1 until the user adds
  members. A demo that quietly implies otherwise would oversell the thing this
  repository is careful to state plainly everywhere else.
- Whether demo mode should fire notifications is **undecided**. It demonstrates
  the core feature, but banners from fake mail during an evaluation could as
  easily read as the app misbehaving.
