# Work Order — Filter-Scoped Bulk Triage (thresher)

> **For:** Claude Code (CLI), run from the repo root.
> **Why:** Dogfood entry 24 (8/4/26). Bulk triage is capped at the page window —
> "Select all 100 loaded" selects only what is loaded, so clearing thousands of
> stale messages means Load-more → select 100 → Done, repeated dozens of times.
> **The ceiling is not a UI limit; it is the endpoint shape.**
> `POST /messages/triage-bulk` takes an explicit id list, so "everything matching
> this filter" is not expressible in the contract at all.
> **Scope:** `backend/` + `frontend/`, both sides of the seam. Docs in Phase D.
>
> **Destination file:** `docs/workorders/bulk-cap-workorder.md`. Commit it in the
> **first** commit of this work order, before any code. (Four of five workorders
> were once discovered untracked; `git ls-files docs/workorders/` is part of the
> clean check now.)

---

## 0. Operating rules for this task (read before doing anything)

1. **Read before you write.** Ground yourself in the *source*, not in the docs —
   `CLAUDE.md` and `docs/api-contract-map.md` are **stale by one session** and do
   not describe Session 31's work at all (no `triage-bulk`, no `X-Total-Count`,
   no `since`/`until`). Phase D fixes that. Until then the source is the contract:
   - `backend/db/database.py` — the list query's WHERE construction,
     `count_matching`, `FRESH_DAYS` / `RECENT_DAYS` (D57).
   - `backend/api/app.py` — `GET /messages` param parsing (including the E24 `+`
     restoration and the 400-on-malformed-bound path) and the existing
     `POST /messages/triage-bulk`.
   - `backend/tests/` — existing style; match it.
   - Frontend: the filter bar, the "Showing N of M" / Load more control, and the
     select-all affordance added in Session 31.
2. **Honor the invariants.** **P1** — bulk Done is *suppression, not deletion*;
   every affected message stays retrievable in All and in search. Nothing in this
   work order may delete a message row. **P3** — the stored tier and
   `rule_matches` are untouched; only `triage_state` changes. **P5** — no
   mailbox side effect unless explicitly requested per request.
3. **Docs-as-code.** Phase D ships in the same commit as the code it describes.
4. **Verify by running.** After each phase: suite green, Flask booted, the new
   endpoint `curl`'d against the **live alpha store** (~4,900 messages) and the
   output pasted into the run summary. A green test over a 20-row fixture is not
   evidence about a 3,000-row update.
5. **Flag, don't invent.** §8 lists decisions that are **the author's, not yours**. If
   you hit one, stop and record it — do not pick a default and build it.

---

## 1. CRITICAL — one predicate, three callers (this work order's E10 trap)

There are currently **two** places that build the message-filter WHERE clause: the
list query and `count_matching`. Session 31 deliberately made the second reuse the
first so that rows and totals could not drift. This work order adds a **third**
caller — the bulk update — and a third independent copy of that predicate is the
single most likely way to ship a wrong-set bug.

**Requirement:** extract the predicate into **one** builder (e.g.
`_message_filter_clause(filters) -> (sql_fragment, params)`) and have **all three**
call it — list, count, bulk. No caller may append its own filter condition.

**Corollary, and it is not optional:** the bulk endpoint parses the *same* ISO
bound strings as `GET /messages`, so it must reuse the **same parsing path** —
including the E24 `+`-restoration and the malformed-bound 400. A second parser
means E24 recurs on a new endpoint, where the failure mode is not "returns
everything" but "updates the wrong set". Route both endpoints through one
`parse_bound()`.

Add a comment at the builder stating the invariant and naming its three callers.

---

## 2. Phase A — backend: filter-scoped bulk triage

### A1. Extract the shared predicate (`database.py`)

Per §1. Pure refactor — the suite must stay green with **no test changes** before
you add anything. Commit this separately.

> **STOP — commit seam 1.** Refactor only, suite green, no behaviour change.
> Report the diff and wait.

### A2. New request shape on `POST /messages/triage-bulk` (`app.py`)

Keep the existing explicit-id mode; **add** a filter-scoped mode. Exactly one of
the two must be present (400 if both, 400 if neither):

```
{
  "triage_state": "done",
  "filter": {                     // filter-scoped mode
    "state": "open",              // same vocabulary as GET /messages
    "tier": 4,
    "since": "...",               // optional
    "until": "2026-08-07T14:03:11+00:00",   // REQUIRED (see A3)
    "account": "..."              // optional
  },
  "writeback": false              // default false; see A5
}
```

The update is **one transaction, all-or-nothing** — a single
`UPDATE classifications SET triage_state = ? WHERE message_id IN (SELECT … <shared
predicate>)`, not a loop over resolved ids. D44's lesson holds: intermediate
states are observable by the reload-per-poll classifier (E11/D37), so there must
be no intermediate state.

### A3. `until` is REQUIRED in filter-scoped mode — this is the race guard

A poll can land between the user reading "this will mark 3,204 messages Done" and
the execute. Without an upper bound, mail that arrived in that window is marked
Done **having never been seen** — not a P1 violation (nothing is deleted) but a
close cousin, and silent.

Freeze the set by construction: the client captures `until = now` at **preview**
time and sends **that same value** on execute. Anything ingested afterwards has
`received_at > until` and is excluded.

**Reject a filter-scoped request with no `until` — 400, with a message naming the
reason.** Do not default it server-side; a server-side `now` is evaluated at
execute time and defeats the entire guard.

### A4. Preview and response both report counts

- `GET /messages` already returns `X-Total-Count` for a filter set — the client
  uses that as the preview count. No new preview endpoint.
- The bulk response returns the **actual affected row count**, plus the count of
  rows skipped because they were already in the target state.
- If affected ≠ what the client previewed, that is *reportable*, not silent — the
  client surfaces it (B3). Divergence should be near-zero once `until` is frozen;
  a nonzero value means concurrent triage, which is worth seeing.

### A5. Write-back stays OFF by default, and gets louder here

Session 31 measured a realistic bulk Done at ≈12,450 IMAP round-trips — a mailbox
rewrite hiding inside a list action, which is why bulk write-back defaults off.
Filter-scoped selection makes that far easier to fire, so:

- `writeback` defaults to `false`. Unchanged.
- The response states which happened. Unchanged.
- **See §8.1 — whether to *refuse* write-back above a row threshold is the author's
  call, not yours.** Build the default-off behaviour; do not add a threshold.

---

## 3. Phase B — frontend

### B1. "Select all N matching" (not "select all loaded")

Replace / supplement the current select-all affordance. When a filter is active
and `X-Total-Count` exceeds the loaded window, offer the honest option: *Select
all 3,204 matching this filter* — distinct from *Select all 100 loaded*. Both
should be reachable; the loaded-only one is still correct for small sets.

Capture `until = now` at the moment the user makes this selection and hold it for
the confirmation and the execute (§A3).

### B2. Confirmation is mandatory and states the number

No filter-scoped bulk executes without a confirmation naming the count, the target
state, and whether write-back is on. This is the one place a modal is correct —
P2 forbids modal alerts *for new mail*, not for a user-initiated destructive-shaped
action.

### B3. Report the result

After execute, show the affected count. If it differs from the previewed count,
say so plainly rather than swallowing it.

### B4. "Older than 2 weeks" preset (entry 24a)

Add the preset to the date dropdown. **Bind it to D57's `FRESH_DAYS`, not to a
literal 14** — the preset and the recency band are the same number expressed twice,
and OI29 flags those constants as pref candidates. One constant means they can
never drift apart, and promoting them to a preference later moves both at once.
If the frontend cannot read the constant directly, expose it in an existing
preferences payload rather than hardcoding a second 14; flag if neither is clean.

> **STOP — commit seam 2.** Backend complete and curl-verified before frontend
> work begins. Report and wait.

---

## 4. Phase C — tests

Red-first where the test pins a defect (§1 and A3 especially).

**Backend**
- The shared predicate: list, count, and bulk return/affect the **same set** for
  the same filter — asserted directly, not via three independent expectations.
  This is the §1 guard.
- E24 regression **on the new endpoint**: a bound arriving with `+` degraded to a
  space is restored, and a genuinely malformed bound 400s. (The existing E24 test
  covers `GET /messages` only.)
- `until` missing in filter-scoped mode → 400.
- Both `ids` and `filter` → 400. Neither → 400.
- **The race guard, explicitly:** insert a message with `received_at` after the
  frozen `until`, run the bulk, assert it was **not** touched. This is the test
  that would fail if someone later "helpfully" defaults `until` server-side.
- Atomicity: a forced failure mid-update leaves **zero** rows changed.
- Scale: build a ≥3,000-row fixture and assert one statement, correct count, and
  that it completes. Report wall time.
- P1: after a bulk Done, every affected message is still returned by search and
  by the All view.
- Write-back defaults off; response reports which happened.

**Frontend**
- Select-all-matching sends the filter, not an id list.
- The `until` captured at selection is the one sent at execute (not re-derived).
- Confirmation cannot be bypassed in filter-scoped mode.
- The 2-week preset resolves from the shared constant.

Report before/after suite counts both sides (baseline: backend 276, frontend 84).

---

## 5. Phase D — artifact reconciliation (same commit as the code)

**This is larger than usual because Session 31 shipped undocumented.** Verify each
claim against the source rather than trusting this list:

- **`CLAUDE.md` — The API section is missing all of Session 31.** Add:
  `POST /messages/triage-bulk` (both modes), the `X-Total-Count` / `X-Offset`
  headers on `GET /messages`, and the `since` / `until` / `tier` filter params.
- **`docs/api-contract-map.md`** — same gap; add the S31 endpoints *and* this
  work order's filter-scoped mode.
- **`project-log.md`** — session entry; log **D58** (filter-scoped bulk triage:
  send the filter not the ids, `until`-frozen set, one shared predicate); note the
  E24-parser reuse as an explicit reuse-not-reimplement decision.
- **`dogfood-log.md`** — entry 24 disposition (currently blank) and its ledger
  row. Entry 24b → this work order. Entry 24a → §B4. **Do not touch entry 25**
  (font coverage) — it needs a keyboard diagnosis first and is not in scope.
- **`docs/public-repo-readiness.md`** — no change expected; confirm.

---

## 6. Definition of done

- [ ] This file committed to `docs/workorders/` in the first commit.
- [ ] §1 satisfied: one predicate builder, three callers, one bound parser.
- [ ] Both stop gates honored; diffs reported and approved before proceeding.
- [ ] `until` required in filter-scoped mode; race-guard test present and was red
      against an implementation that defaults it.
- [ ] Curl'd against the **live store**, not just fixtures; output pasted into the
      run summary with row counts and wall time.
- [ ] P1 verified by running: after a real bulk Done, pick three affected message
      ids and show them still returned by search.
- [ ] Suite counts reported both sides.
- [ ] Phase D complete in the same commit.
- [ ] §7 filled in.

---

## 7. Open items (Claude Code fills this in)

**Numbering:** this decision shipped as **D59**, not D58 — Session 31 had already
taken D58 (bulk write-back default + column floor). Caught during Phase D and
renumbered across all 39 references before commit.

**Baselines in this work order were stale.** §4 says "backend 276, frontend 84";
the actual baselines were **282** and **104**. Final: backend **296** (+14),
frontend **122** (+18), plus 8 XCUITests. Reported against what was measured.

**Reserved for the author — still unresolved, deliberately not built (§8):**

1. **Write-back threshold.** Built default-off only, as instructed. No refusal
   threshold exists. The measured cost is ~3 IMAP round-trips per message, so a
   filter-scoped bulk with `write_back: true` over 1,594 messages would be ~4,800
   round-trips. Nothing stops that today except the default.
2. **Undo / executed-bulk log.** Not built. **My read, for what it's worth:** the
   log is cheap now and impossible to retrofit — it needs the filter and `until`
   at execute time, which nothing else persists. Without it, "undo" can only ever
   mean "re-run the inverse while you still have the filter," and after a reload
   the scope is gone (by design). If it is ever wanted, wanting it later costs
   strictly more than wanting it now.
3. **Hard cap.** No cap built; confirmation-with-an-honest-count is the only
   guard, per the work order's stated current plan.

**Decisions I made solo that the author may want to revisit:**

4. **The D49 background refresh is suppressed while a scope is armed.** Not in the
   work order — found by reasoning about the seam. `reload()` drops the frozen
   scope, so a quiet tick landing between "Select all 1,594 matching" and the user
   pressing Mark Done would have **disarmed the action under them**: button
   pressed, nothing happens, no error. One deferred tick costs nothing and the
   frozen `until` (not the refresh) is what keeps the count honest meanwhile.
5. **An unknown `filter` key is a 400, not ignored.** Also not in the work order.
   A silently-dropped `tierr=4` *widens* the update set — the opposite of what the
   typo intended. Loud seemed the only safe reading on an endpoint this shaped.
6. **`already_in_state` was added to the response.** §A4 asked for "rows skipped
   because they were already in the target state", but SQLite counts a no-op
   UPDATE as changed, so it cannot be derived from `updated` — it needed its own
   counted query against the same predicate.
7. **`fresh_days` is a DERIVED preference key, not a stored one.** §B4 said to
   expose the constant "in an existing preferences payload rather than hardcoding
   a second 14". It is served from `GET /preferences` but computed, so a
   `PUT /preferences/fresh_days` would write a row this key then shadows.
   Clean enough for now; **OI29** resolves it properly by making it genuinely
   stored, at which point the client needs no change.

**Not done, and why:**

8. **No keyboard verification of any D59 UI.** The backend is proven against the
   live store; the frontend is proven only by 122 unit tests. The installed app
   binary is older than this session's code — **rebuild before the human gate** or
   none of this will be there. Gate items are in the run summary.
9. **Dogfood entry 25 (font sizes) deliberately untouched**, per §5. Worth noting
   for whoever picks it up: the string it names — "Select all 100 loaded" — was
   *rewritten* by this work order, so re-read the complaint against the current UI
   before diagnosing.

**A real mutation to be aware of:** the live verification marked **1,594 real
messages Done** in the author's alpha store (`done` 3,135 → 4,729). That was the point of
the exercise and P1 holds — nothing deleted, everything still searchable — but it
is a genuine change to his mail state. Pre-run backup:
`/tmp/thresher.backup-20260807-215258.db`.

---

## 8. Decisions reserved for the author — do NOT resolve these yourself

1. **Write-back threshold.** Should filter-scoped bulk *refuse* `writeback: true`
   above some row count (500? 1,000?), rather than merely defaulting it off? The
   measured cost is ~3 IMAP round-trips per message. Build default-off only.
2. **Undo.** There is no undo, and prior triage states are not retained, so
   "restore what it was" is not expressible today. The *inverse* operation is
   expressible while the user still has the filter. Recording each executed bulk
   (filter + `until` + timestamp + affected count) would make a real undo cheap
   later. **Do not build it** — flag whether the executed-bulk log is wanted now.
3. **Hard cap.** Should any single bulk be bounded at all, or is "confirmation
   with an honest count" sufficient? Current plan: no cap, mandatory count.
