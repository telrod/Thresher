# Thresher — Architecture

For someone who wants to change the code. For using it, see
[`USER-GUIDE.md`](USER-GUIDE.md); for why things are the way they are, see
[`DECISIONS.md`](../DECISIONS.md).

---

## 1. Three processes

```
   ┌──────────────────────────┐
   │  Thresher.app (SwiftUI)  │   the only thing a user launches
   │    BackendSupervisor ────┼──── starts and stops the two below
   └────────────┬─────────────┘
                │ HTTP, localhost:8765 only
   ┌────────────▼─────────────┐     ┌────────────────────────────┐
   │  api.server (Flask)      │     │  main.py (the poller)      │
   │  REST, read + write      │     │  IMAP → parse → classify   │
   └────────────┬─────────────┘     └─────────────┬──────────────┘
                │                                 │
                └──────────► SQLite ◄─────────────┘
                   ~/Library/Application Support/thresher/thresher.db
```

**The app talks only to the API.** It never opens the database and never speaks
IMAP. That boundary is why the frontend can be tested against a fixture HTTP
server, and why the API contract is the thing to keep stable.

**The API and the poller do not talk to each other.** They are separate
processes that share a database, which is why account health is designed the way
it is (§6).

### The supervisor, and why the app owns the backend's lifetime

`BackendSupervisor` starts both processes on launch, stops them on terminate, and
restarts anything that died on a 30-second timer — launchd's `KeepAlive` in app
form, bounded to three restarts so a backend that *cannot* start is reported
rather than retried forever.

This was not the original design. The backend first ran under launchd
(**D66**), started at login and polled whether or not the app was open. That was
an outage fix, and it worked, but it was never evaluated as the thing you hand to
someone else: it asks to run continuously on a stranger's machine. **D67** chose
app lifetime instead, on measurements rather than instinct — 80 MB RSS and 0.0%
CPU idle, so the objection was consent, not cost.

The cost is real and stated plainly in the user guide: **app closed means no mail
is fetched.** The constitution's Tier 1 invariant governs operating modes, not
process lifetime, so this narrows behaviour to what was actually specified.

The supervisor **stands down entirely when launchd owns the backend**, only ever
stops what it started, and **refuses to guess** where the backend lives — it
reads `THRESHER_BACKEND_DIR` / `THRESHER_PYTHON` and throws when they are unset,
rather than searching.

### ⚠️ An endpoint's blast radius is not bounded by what the endpoint does

`POST /accounts` writes the Keychain and **nothing else** — no IMAP, no mailbox
access, not even a database write. Its docstring says so, and that is accurate:
D40 split store from verify precisely so the side-effect classes stay clean
(P5).

**Registering a credential through it nonetheless produces a real IMAP login
attempt against Gmail**, within about 30 seconds.

The chain runs through the process boundary, not through the endpoint:

```
POST /accounts  →  Keychain write
                        ↓   (the Keychain IS the account registry, D41)
     main.py's _supervise_accounts reconciles every ACCOUNT_REFRESH_SECONDS (30)
                        ↓
        a pipeline is started for the new account  →  IMAP LOGIN
```

Observed while setting up screenshots: a placeholder password was registered to
test onboarding routing, and the poller promptly failed with
`[ALERT] Invalid credentials (Failure)` against the real Gmail server. Nothing
malfunctioned — OI25's live account supervision is *supposed* to pick up an
account added in Settings without a restart, and it did.

**The general point, worth carrying beyond this endpoint:** reasoning about a
side effect from the handler alone is reasoning about one process. Anything that
writes to shared state another process watches — the Keychain here, but
preferences and the database equally — inherits that watcher's side effects. Ask
what reconciles against this, not only what this function does.

Practical consequence: **there is no way to register an account without
attempting a login**, so tests and tooling that need an account present must
either accept a real connection attempt or stop the poller first.

### What ships

`scripts/build.sh` bundles `backend/` plus a vendored Flask into
`Contents/Resources`. **No Python runtime is bundled** (**D68**): macOS's stock
`/usr/bin/python3` runs it, and Flask is the only third-party dependency the
backend has — the poller needs none.

That makes **Python 3.9 a hard floor**, which held by luck until it was pinned:
every `X | None` annotation happens to be quoted, so 3.9 never evaluates one.
`backend/tests/test_python_floor.py` **imports** every bundled module on the
floor interpreter — importing, not compiling, because `str | None` is valid 3.9
*syntax* and fails at import as `TypeError`. The compile-based first version of
that guard passed against the exact regression it existed to catch.

---

## 2. Ingestion

`backend/ingestion/` — IMAP poll → parse → `queue.Queue` → persist.

There is no external broker. A single-user local tool does not need one, and
dropping Redis is the first of the project's recurring
drop-the-dependency decisions (Pyke/Drools → plain Python, Alamofire →
`URLSession`, keyring → the `security` binary).

**A message is persisted *before* it is classified.** If classification throws,
the mail is still in the database and still reachable — the P1 invariant, applied
at the one place where losing something is easy.

### Cursors and the retrieval window

Polling is **UID-based per account**, with the cursor stored in the database.
Identity is `{account}:{uid}` throughout: cursors, UIDVALIDITY, credentials and
write-back gates are all per-account.

The **retrieval window** (**D61**) bounds the *initial backfill* only. It is
resolved to an **absolute cutoff at connect time**, never stored as "N days" — a
relative value would be re-evaluated every poll and the boundary would slide
forward, so mail could fall out of range while sitting in the queue.

**After connect, the window stops filtering.** Closing the app for two weeks
retrieves all of that mail. The asymmetry is deliberate: the window solves "don't
drag in years of dead mail at setup", while a gap since the last poll is recent
and possibly still actionable. Grounding found this was already the behaviour by
accident — polling has no date criteria — so the work was making it deliberate,
with a comment at the boundary and a test that goes red if the window is ever
applied per-poll.

### Backfill silence

Mail ingested during an initial backfill produces **no notifications** (**D62**).
Connecting one account once found 3,311 messages and fired 214 banners.

The flag is **per message, not shared state**: queue items are
`(Message, is_backfill)`. The producer decides, because it knows which batch a
message belongs to, and the tag travels with the message. The previous shared
flag was cleared on `queue.empty()` — which means "the consumer caught up", not
"the batch ended" — so a fast consumer emptied it mid-batch and the tail
notified.

### Transient failures

A timeout mid-poll is transient and must not be fatal (**D64**). The poller once
died on a `TimeoutError` from `_select_mailbox` and **nothing fetched mail for 13
days**.

Two things made that permanent rather than annoying: it raised a bare
`TimeoutError` (an `OSError`, *not* `ImapError`), so it sailed past the
poll-level backoff that already existed, and then hit a catch-all that set the
account's stop event forever. **The exception type is what routes a failure to
the retry layer** — the retry was already built; the timeout simply never reached
it.

---

## 3. Classification

`backend/classification/engine.py` — a config-driven rule evaluator. Rules live
in the database and are reloaded per poll, so an edit applies to the next poll's
mail.

**Evaluation is in priority order**, lowest number first. Priority is **ordinal
only** — nothing reads the distance between two priorities — which is why
reorder is a batch endpoint that renumbers densely (**D44**) rather than the
client computing a number.

Five fields are matchable: `sender_email`, `sender_domain`, `subject`, `body`,
`sender_group`. Operators are `equals`, `contains`, `starts_with`, `ends_with`,
and `matches_group`.

**`matches_group` pairs only with `sender_group`, and `sender_group` accepts
nothing else.** Any other combination is rejected by the API. Before that check
existed, such a rule rendered as live in Settings and silently never fired, since
the engine fell through to matching `""`.

**Sender groups are a floor, not a rule.** A message from a group member is never
classified below that group's floor tier, whatever the content says. This is the
sender override invariant, and it is the main reason the tool is useful: the user
states who matters rather than hoping keywords infer it.

### The explain payload

`GET /messages/<id>/explain` returns the human-readable reason a message got its
tier — which rules matched, in order, and what each did. It is not generated
after the fact; `rule_matches` is written at classification time and stored.

Two decoder traps worth knowing, because a non-optional decode breaks on real
data:

- `skipped_tier` is a **string** (`"2 (less urgent than current 1)"`) while
  `applied_tier` is an **int**.
- **`rule_id` is `null`** on the sender-override variant — so any message whose
  sender is in a group has a match with no rule id.

### Reclassification

Classification happens once, at ingest. **D52** added explicit re-runs — one
message, or the whole store — and four invariants hold, each pinned by a test
that names it: triage state survives, the path is silent (it never touches the
notification service), the result **overwrites with a dated audit**
(`reclassified_at`) rather than versioning, and classify-once stays the default.

It is synchronous **by measurement**: 1,592 real messages in 0.39 s, so no job
system was built.

---

## 4. Storage and migrations

`backend/db/` — schema, seed, repository layer, migrations.

`migrations.py` is **the one place a schema change reaches an existing
database.** `init_db` applies `schema.sql` with `CREATE TABLE IF NOT EXISTS`,
which does nothing to a table that already exists.

**So a schema change needs BOTH**: a migration *and* the matching DDL in
`schema.sql`. Fresh databases take the DDL path and are stamped with the current
`PRAGMA user_version`; existing databases migrate. Both paths must converge on
the same shape, and there is a test that checks they do.

Each migration runs in one transaction, every body is idempotency-guarded, and a
backup is taken before migrating **in code**, not by convention.

### ⚠️ One hazard to know before touching the schema

`sender_groups.email_pattern` is **deprecated** (**D53** moved membership to the
`sender_group_patterns` child table) and retained for one release. Dropping that
column against a database whose child table was never populated leaves every
group with zero patterns: `matches_group` matches nothing, group rules go inert,
and **mail from leadership and family silently stops being Tier 1**. Measured,
not predicted — blanking the column takes a group member from T1 to T4 with no
error anywhere.

A test asserting "classification works" does **not** catch this, because the
per-group fallback satisfies it. Assert non-zero pattern **rows**.

### The shape to watch in queries

The one memory problem this project has had was
`SELECT * … .fetchall()` over `messages` in `reclassify_all`, which loaded every
body (6 → 252 MB over six runs). A guard test now pins the streaming read.
**Grep for `fetchall()` before adding any whole-store path** — a bulk operation
is exactly where materialising the store looks harmless.

### One predicate, one filter

`message_filter_clause()` in `database.py` is the **only** place the message
filter is expressed in SQL. The list, the count, the bulk `UPDATE` and its
preview counts all call it. Two copies once made an honest count dishonest; a
third would make the set the user was *shown* differ from the set the server
*writes*.

---

## 5. Notifications

`backend/notifications/` — `osascript` banners plus a digest scheduler that ticks
and asks rather than sleeping until a target time (brittle across clock changes
and preference edits).

Two delivery paths coexist (**D45**): while the app is open it claims delivery
via a **short-TTL heartbeat preference** and posts native
`UNUserNotificationCenter` banners; the backend sees the claim and logs-but-skips
its own, so exactly one fires. `osascript` is the floor when the app is closed,
so the Tier 1 invariant never depends on the app being up.

**Known gap (OI40):** a Tier 2 notification deferred by quiet hours is logged
with `delivered=False` and **never replayed** — nothing watches for the window to
end. Two comments in `service.py` say otherwise and are wrong. This is not a
Tier 1 violation (the `tier != 1` guard is structural, verified by running it)
and the message is stored, classified and listed throughout.

---

## 6. Account health

`GET /health/accounts` reports per-account ingestion status: `ok` · `error` ·
`stopped` · `stale` · `never`.

**It is keyed on staleness, not on recorded errors, and the direction is the
design.** The API and the poller are separate processes, so the API cannot read
a pipeline's in-memory error state — and the failure that actually happened wrote
nothing at all, because the process died. A design that only warns on a
*recorded* error stays green through exactly the outage it exists to catch.

So the poller records **liveness** (a heartbeat per poll) and the API reports
**absence**. Silence reads as broken, which is the fail-safe direction. The
threshold derives from the configured poll interval, so widening the interval
does not cry wolf, and a configured-but-never-polled account reports `never`
rather than being omitted — an absent row reads as "fine" to a UI.

This was built after a 17-hour window in which one of two mailboxes was dead
while the other polled happily, with no indication anywhere.

---

## 7. The frontend

`frontend/` — SwiftUI, macOS 14 floor (**D36**), `URLSession` + `async`/`await`
(**D35**), no third-party dependencies.

- `Features/` — one directory per screen: MessageList, MessageDetail, Settings,
  Onboarding.
- `Models/` — view models and decodable types. `@Observable`, not Combine.
- `Networking/APIClient.swift` — the single seam to the backend.
  `THRESHER_API_BASE_URL` redirects it, which is how the UI tests point the app
  at a fixture server.

**Default list ordering is recency band → tier → date** (**D57**), with bands at
14 and 90 days and **Tier 1 exempt at any age**. Not tier-first: with 4,737 open
messages, tier-first ordering plus the 100-row window put *zero* messages from
the last 14 days on page one, and mail from that morning was unreachable rather
than merely buried. Age never changes the stored tier — only presentation order
decays, so classification stays auditable.

Compare dates with `julianday()`, never as text: stored timestamps carry an
offset and `datetime('now')` does not.

---

## 8. Running the test suites

```
cd backend && python3 -m pytest tests/ -q                    # 479 tests, ~22s

xcodebuild -project frontend/Thresher.xcodeproj \
  -scheme Thresher -destination 'platform=macOS' \
  -only-testing:ThresherTests test                           # 273 tests, ~92s
```

⚠️ **Do not run the two suites concurrently.** The frontend suite drives a real
app with real windows and a real run loop, and several tests are timing
sensitive. Running `pytest` alongside `xcodebuild` competes for the same cores
and makes those tests flake. Run them one at a time, and re-run a red frontend
result alone before believing it.

⚠️ **A frontend run that takes ~660s and ends with "Test runner never began
executing tests" means no tests ran at all** — `testmanagerd` has wedged. Fix
with `pkill -9 testmanagerd`. Check for an `Executed N tests` line before
believing any red result: a harness timeout and a genuine failure both print
`** TEST FAILED **`.

⚠️ **`SettingsWindowLayoutTests` needs a reachable backend *and* a connected
account.** It skips when the backend is down, but with a reachable backend and no
account the app routes to onboarding, the main window never grows its toolbar,
and the test fails as "no custom toolbar items appeared" — which reads as a
layout regression and is not one. It also needs `onboarding.tutorialSeen` set in
the app's defaults domain.

---

## 9. The honest limitations

**UI interaction testing needs a human.** Assistive access is denied to
automated agents on this machine, so `osascript`/System Events cannot drive the
app. Hosted render tests (running *inside* the app process) can open real
windows and cache them to PNG, but **synthesized mouse clicks do not reliably
reach SwiftUI `List` rows** — neither the Settings sidebar nor message rows
change selection from a posted event. A screenshot pass written for this repo
"passed" while producing four byte-identical images before a duplicate check was
added.

The practical rule, learned repeatedly here: **a view-model test proves the state
is right; it cannot prove a click reaches the state, or that the result is
legible.** Twice a green model-level suite hid a feature that a real user
correctly read as broken. Human gate checklists exist for this reason.

**The rule engine cannot match on headers** (OI38). Only the five fields in §3,
so `List-Unsubscribe` — the most reliable bulk-mail signal there is — is
unreachable. This is why a fresh install classifies real automated mail poorly:
the seeded rules fall through and it lands at Tier 4. Adding a `header` field is
the single highest-value change available to the classifier.

**A fresh install cannot produce a Tier 1.** Both Tier 1 rules target sender
groups that ship with placeholder members. Measured against a 150-message
generated corpus: 0 at T1, 15 at T2, 21 at T3, 70 at T4, 44 at T5. The
"Try with sample data" and *ask* onboarding steps that would fix this are
deferred.

**Gmail only, app password only, alpha quality.** There is no prebuilt binary,
nothing is signed or notarized, and the Apple Silicon build is untested.
