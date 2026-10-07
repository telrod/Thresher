# CLAUDE.md — Thresher

Conventions for anyone working in this repo, human or agent. Everything here is
checkable, and was checked against the code rather than written from memory.

For what Thresher does, see [`README.md`](README.md). For how it is built, see
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). For why it is built that way,
see [`DECISIONS.md`](DECISIONS.md).

---

## Build and run

```
scripts/build.sh            # → build/Thresher.app
```

**The app owns the backend's lifetime.** `BackendSupervisor` starts the Flask
API and the poller on launch and stops them on terminate
(`ThresherApp.swift`, `applicationDidFinishLaunching` /
`applicationWillTerminate`). Do not start them separately and expect the app to
cooperate — it stops what it started, and stands down entirely when launchd owns
them instead.

Consequence worth stating: **app closed means no mail is fetched.**

---

## Testing

**Do not run the two suites concurrently.** The frontend suite drives a real app
with real windows and a real run loop, and several tests are timing sensitive.
Running `pytest` alongside `xcodebuild` competes for the same cores and makes
them flake. Run one at a time; re-run a red frontend result alone before
believing it.

```
cd backend && python3 -m pytest tests/ -q                   # 485 tests, ~27s

xcodebuild -project frontend/Thresher.xcodeproj \
  -scheme Thresher -destination 'platform=macOS' \
  -only-testing:ThresherTests test                          # 274 tests, ~92s
```

**Check for an `Executed N tests` line before believing a red result.** A wedged
`testmanagerd` and a genuine failure both print `** TEST FAILED **`; the harness
failure takes ~660s and says "Test runner never began executing tests". Fix with
`pkill -9 testmanagerd`.

**`SettingsWindowLayoutTests` needs a reachable backend AND a connected account
AND `onboarding.tutorialSeen` set.** Its skip guard only checks reachability, so
with a reachable-but-accountless backend the app routes to onboarding, the main
window never grows its toolbar, and it fails as "no custom toolbar items
appeared" — which reads as a layout regression and is not one.

### UI interaction testing needs a human

**Assistive access is denied to agents** (`osascript` → `-1728`), so the app
cannot be driven from outside.

Hosted render tests run *inside* the app process and can open real windows and
cache them to PNG. But **synthesized mouse clicks do not reach SwiftUI `List`
rows** — verified against both the Settings sidebar and message rows, at the
rows' own window coordinates, with the mouse-up-before-mouse-down ordering that
does work for toolbar buttons. To photograph or exercise a specific pane, host
the view directly; its view model still talks to the real backend.

Two further traps when asserting on a rendered window:

- **`.accessibilityIdentifier` does not surface as `NSView.accessibilityIdentifier()`**
  under `NSHostingView`. Walking the tree for it finds nothing, and SwiftUI
  `List` rows expose empty labels.
- **`bitmapImageRepForCachingDisplay` is premultiplied.** Divide by alpha before
  comparing colours, or you are measuring alpha rather than hue.
- **In dark mode a hosted render loses its text.** Primary text draws white onto a
  transparent bitmap, so a PNG shows only coloured text and borders — and two
  such renders still differ byte-for-byte. Set `window.appearance` to `.aqua`,
  give the root an opaque background, and assert dark-ink pixels exist, not just
  that renders differ (`AskPeopleStepTests`).

**A view-model test proves the state is right. It cannot prove a click reaches
the state, or that the result is legible on screen.** This has now hidden a
shipped feature twice behind a green suite.

---

## Writing a check that can actually fail

The recurring failure in this project is a check that tests the *model* of a
thing rather than the thing. It has appeared often enough to be the house rule:

**When you write a guard, write its self-test too — verify it can fail, rather
than trusting that it would.**

- A `--account` guard test passed with the guard deleted.
- A Python-floor guard passed against the exact regression it existed to catch,
  because it compiled rather than imported (`str | None` is valid 3.9 *syntax*
  and fails at import).
- A screenshot pass wrote four byte-identical PNGs and reported success, because
  nothing compared them.

**When a test parameterises something, assert that different parameters produce
different results before trusting either.** And **when a property cannot be
measured reliably at test scale, assert the SHAPE that guarantees it** rather
than tuning a threshold until the sabotage fails.

---

## Geometry specs must name their coordinate system in the first line

Four words — "y-down from the top-left, SVG convention" — and the app icon would
not have shipped mirrored. The spec was precise to four decimal places and still
wrong, because every number was right in a frame nobody named: a y-down spec met
a y-up API, both load-bearing details inverted silently and together, and
nothing errored.

`design/appicon/RenderIcon.swift` follows this: it states its origin up front and
converts y in exactly one place, marked as the coordinate boundary.

---

## Classification

**The rule engine exposes five fields and cannot match on headers.**

| Field | Matches |
| --- | --- |
| `sender_email` | full sender address |
| `sender_domain` | the part after the `@` |
| `subject` | subject line |
| `body` | plain-text body |
| `sender_group` | membership of a named group |

Operators: `equals`, `contains`, `starts_with`, `ends_with`, `matches_group`.
**`matches_group` pairs only with `sender_group`, and `sender_group` accepts
nothing else** — the API rejects any other pairing, because such a rule renders
as live and silently never fires.

Because there is no header field, **`List-Unsubscribe` is unreachable** — the
most reliable bulk-mail signal there is. Adding a `header` field is the
highest-value change available to the classifier.

### ⚠️ A fresh install cannot produce a Tier 1

Both Tier 1 rules match on sender-group membership (`leadership`, `family`), and
those groups ship with **placeholder members that match nobody** —
`boss@example.com`, and nothing at all for `family`. Until real addresses are
added, **no message can reach Tier 1.**

Measured on a 150-message generated corpus against a freshly seeded install:
**0 / 15 / 21 / 70 / 44** across T1–T5. Reproduce with:

```
python3 scripts/generate_corpus.py --profile demo --report
```

which prints the distribution twice — groups populated and groups empty. **The
second number is the honest one.** No caption, README line or screenshot may
imply a fresh install produces a tiered list.

This is also why `operating_mode` defaults to **catch-up**, not focus: focus
alerts on Tier 1 only, which on a fresh install is guaranteed silence.

---

## Database

**A schema change needs BOTH a migration and the matching DDL in `schema.sql`.**
`init_db` applies `schema.sql` with `CREATE TABLE IF NOT EXISTS`, which does
nothing to a table that already exists; `migrations.py` is the only thing that
reaches an existing database. Fresh databases take the DDL path and are stamped;
existing ones migrate. Both paths must converge on the same shape.

**Grep for `fetchall()` before adding any whole-store path.** The one memory
problem this project has had was `SELECT * … .fetchall()` over `messages`,
which loaded every body (6 → 252 MB over six runs). A guard test pins the
streaming read.

**Compare dates with `julianday()`, never as text.** Stored timestamps carry an
offset and `datetime('now')` does not, so a string compare misjudges the band
boundary.

**`message_filter_clause()` in `database.py` is the only place the message
filter is expressed in SQL.** A second copy once made an honest count dishonest;
a third would make the set the user is *shown* differ from the set the server
*writes*.

### ⚠️ Do not drop `sender_groups.email_pattern` without converting both seeds

It is deprecated (membership moved to `sender_group_patterns`) and retained one
release. Dropping it against a database whose child table was never populated
leaves every group with zero patterns: group rules go inert and **mail from
leadership and family silently stops being Tier 1**. Measured, not predicted.

A test asserting "classification works" does **not** catch this — the per-group
fallback satisfies it. Assert non-zero pattern **rows**.

---

## Logs

Two locations, depending on who started the backend:

| Started by | Logs |
| --- | --- |
| The app (normal use) | `~/Library/Application Support/thresher/logs/` |
| `scripts/backend.sh` (development) | `backend/.run/` |

In the app, **Settings → "Reveal Logs in Finder"** opens the first with the
newest file selected.

---

## Data that must never be committed

- **No real mail.** `*.eml` is ignored by default; the *only* exception is
  `backend/tests/corpus/`, which is synthetic — invented personas on RFC 2606
  reserved domains, asserted by `backend/tests/test_corpus.py`.
- **No databases**, generated or otherwise, and no generated corpora.
- **`backend/db/seed.sql`** is local-only and holds real contacts.
  `seed.example.sql` is the committed template and is what a stranger gets.

⚠️ **Measuring "what a stranger sees" means seeding `seed.example.sql`
explicitly.** `init_db(seed=True)` prefers a local `seed.sql` when one exists, so
a measurement taken the obvious way reports a rule set that ships to nobody.
