# Work Order — Retrieval Window, Bulk Audit Log, and Housekeeping (thresher)

> **For:** Claude Code (CLI), run from the repo root.
> **Why:** Four settled decisions from the 8/9 planning session, plus the
> bookkeeping backlog that has been accumulating since Session 28.
> **Scope:** `backend/` + `frontend/` + docs. Five parts, run in order.
>
> **Destination file:** `docs/workorders/retrieval-window-workorder.md`. Commit it
> in the **first** commit, before any code.
>
> **Decision numbering:** do **not** assume the next free number. Run
> `grep -o 'D[0-9]\+' project-log.md CLAUDE.md | grep -o 'D[0-9]\+' | sort -V -u | tail -5`
> and allocate from what you find. (The previous work order assumed D58 was free;
> Session 31 had already used it, and 40 references needed renumbering.)

---

## 0. Operating rules

Same discipline as the previous work orders. In brief:

1. **Read before you write.** Ground yourself in the source, not the docs.
2. **Honor the invariants.** **P1** — nothing in this work order deletes a message.
   **P2** — no modal interruption for new mail. **P3** — stored tier and
   `rule_matches` are not recomputed by anything here. **P5** — no mailbox side
   effects.
3. **Docs-as-code.** Documentation ships in the same commit as the code it
   describes.
4. **Verify by running.** Suite green *and* exercised against the live store.
5. **Flag, don't invent.** §6 lists what to escalate rather than decide.
6. **Automate what has a correct answer.** See §0.1 — this is a standing change to
   how gates are built, not a one-off.

### 0.1 STANDING RULE — the human gate is for judgment only

From here on, a human gate item must require an **opinion**. Anything with a
correct answer belongs in an automated test.

- "Does the confirmation name the right number?" → correct answer → **test**.
- "Do the two select-all controls look different enough to tell apart?" →
  judgment → **human**.

If a check seems hard to automate, the task is to make it automatable — not to
hand it to the reviewer. Reviewer time is for using the app and finding things no
checklist anticipated, which is where the last two work orders came from.

Apply this rule when writing §5.

---

## 1. Part A — housekeeping (do this first, it is cheap and it is blocking)

### A1. Locate and consolidate the database backups

Three snapshots exist from recent sessions, at least one in `/tmp`:

- `/tmp/thresher.backup-20260807-215258.db` (pre-D59 bulk, 1,594 messages)
- `pre-gate-20260809-081431.db`
- `pre-gate2-20260809-085103.db`

`/tmp` is cleared on reboot and swept for untouched files. Find all three, move
them somewhere durable outside the repo, and **do not commit them** — they are the
real store and contain personal mail. Report the directory, the three filenames,
and their sizes. Establish that location as the standing convention and record it
in `CLAUDE.md`.

### A2. Stop the version stamp reading dirty

`docs/punch-list.md` is untracked, and the version stamp has been reporting
`-dirty` because of it. A dirty flag that is always on is indistinguishable from
no flag, which defeats the purpose of having one.

Add it to `.gitignore` (it is a session artifact, regenerated as needed, not a
project artifact). Then confirm `git status --porcelain` is empty and the version
stamp no longer reports dirty.

### A3. Commit the two new public-facing documents

Both are written in public-repo voice — no personal detail, no project history —
and port to the public repo unchanged:

- `IDEAS.md` — features considered and deliberately not built, with reasoning and
  consequences.
- `BEHAVIOR.md` — deliberate behavior choices users should expect, with downsides
  stated.

Place them at repo root unless there is a reason not to; flag if you disagree.
Both are now **live documents**: Parts B and C below add to them, and future work
orders will too.

> **STOP — commit seam 1.** Report backup location, clean status, and stamp.

---

## 2. Part B — executed-bulk audit log

**Decision:** build the log. Do **not** build undo.

### B1. What it records

An append-only record of every executed bulk operation:

- the filter that selected the set (as stored JSON, not a rendered string)
- the frozen `until` bound
- the target triage state
- timestamp
- affected row count, and rows skipped as already-in-state
- account, if the filter was account-scoped

The reason this is being built now rather than later: **the filter and the `until`
bound exist only at execute time and are not reconstructable afterwards.** Every
other part of an undo feature can be added whenever; this part cannot.

### B2. Where it lives

New table. Append-only — nothing updates or deletes rows. It is a log, not state:
no other code path may read it to make decisions. Add a schema comment saying so,
because the first person to want a shortcut will reach for it.

Write it **inside the same transaction as the bulk update**, so a recorded
operation and an applied operation cannot diverge.

### B3. Reading it

A minimal `GET` endpoint returning recent entries, newest first, with a limit. No
UI in this work order. Enough to answer "what did that operation do?" from the
command line.

### B4. Retention

Rows are small and bounded by how often a human runs a bulk action — no retention
policy needed now. Note the constraint in the schema comment: this stays true only
while the log records *operations*, not per-message state. If someone later adds
per-message prior state for undo, growth becomes unbounded and retention becomes
mandatory. This is already flagged in `IDEAS.md`.

### B5. Cap bulk operations at 5,000

Reject a bulk request whose resolved set exceeds 5,000 with a clear 400 naming the
count and the limit. Not a performance measure — one SQL statement handles far
more — but a bound on the cost of a filter that matched more than intended.

The count check and the update must resolve the **same set** via the shared
predicate builder, or the cap guards a different set than it counts.

### B6. Tests

- The log row is written, with correct filter, bound, state, and counts.
- A failed bulk writes **no** log row (same transaction).
- Nothing in the codebase reads the log to make a decision — assert by inspection
  and state the finding.
- 5,001 rejected; 5,000 accepted.
- The cap counts the same set the update would affect.

> **STOP — commit seam 2.** Backend complete, exercised against the live store.

---

## 3. Part C — retrieval window

**The product reasoning**, because it determines the shape: this app exists to
surface mail that still needs a response. Most mailboxes hold years of mail that
stopped being actionable long ago. Rather than retrieving everything and giving
the user tools to hide it, the user says at setup how far back matters, and older
mail is never brought in.

### C1. Establish current behavior before writing anything

Report on these before proposing an implementation:

1. **Is there an existing onboarding flow to hang a picker on?** A work order for
   one exists (`onboarding-screen-workorder.md`) and was dependent on the Settings
   screens. Determine whether it was ever run and what exists today.
2. **What does ingestion currently do at the boundary?** Is there any date filter
   on initial fetch, or does it take everything the server offers?
3. **What does ongoing polling do?** Specifically, is it UID-based ("everything
   since UID N") or date-based? This matters for C3.

If C3's required behavior is already what the code does, say so — that part
becomes a test and a documentation entry rather than new code.

### C2. The window is chosen at setup and is one-way

- Offered during account setup. Suggested options: 2 days, 1 week, 1 month,
  3 months, everything. Flag if you think the set is wrong.
- Resolves to a **cutoff date at connect time**, stored per account.
- Mail older than the cutoff is never retrieved.
- **Narrowing later is fine. Widening is not supported** — deliberately deferred to
  reach beta sooner; already written up in `IDEAS.md`. Do not build widening. Do
  not build a half-version of it.
- If no onboarding flow exists to host the picker, **flag and stop** rather than
  inventing one. A sensible default plus a Settings control may be the right
  interim shape, but that is a decision, not an implementation detail.

### C3. The window applies to backfill ONLY — this is the part to get right

After an account is connected, the window **stops filtering.** Everything that
arrives from then on is retrieved, regardless of age, including mail that arrived
while the app was closed.

Concretely: someone sets a one-week window, closes the app for two weeks, and
reopens it. **All of that mail is retrieved.** It is not skipped for being older
than a week.

The reason, since a future reader will otherwise "fix" this: the window solves
*"don't drag in years of dead mail at setup."* A gap since the last poll is a
different situation — recent, small, and possibly still actionable. Skipping it
would mean closing the app for a week could permanently hide an urgent message,
which is the exact failure this app exists to prevent. And because the window
cannot be widened, that gap would be unrecoverable.

Staleness is handled where it belongs — by the tier-first, recency-second sort. A
nine-day-old important message appears in the working view, ranked below today's
mail rather than competing with it.

**Put a comment at the ingestion boundary stating that this asymmetry is
deliberate**, with a one-line reason. Both entries are already in `BEHAVIOR.md`.

### C4. Backfill must not produce a notification flood

Retrieving the initial window must not fire a banner per message — the known
hazard (a restart once replayed thousands of messages as individual banners). If
the existing suppression does not already cover this path, flag it; do not widen
notification suppression as a side effect of this work order.

### C5. Tests

- A message older than the cutoff is not ingested at connect.
- A message newer than the cutoff is.
- **The gap case, explicitly:** simulate a lapse longer than the window, then
  poll. Assert mail from the gap **is** retrieved. This is the test that fails if
  someone later "corrects" the asymmetry.
- The cutoff is stored per account and is stable across restarts.
- Backfill does not emit per-message notifications.

> **STOP — commit seam 3.** Report C1 findings before implementing C2/C3.

---

## 4. Part D — documentation

In the same commits as the code:

- `BEHAVIOR.md` — verify the two window entries and the bulk-log entry match what
  was built. If the code differs from the document, **the document is what was
  decided** — flag the discrepancy rather than quietly amending it.
- `CLAUDE.md` — the log table and endpoint, the 5,000 cap, the retrieval window
  and its backfill-only scope, the backup location convention (A1).
- `docs/api-contract-map.md` — the new endpoint and the cap's 400.
- `project-log.md` — session entry; the newly allocated decision numbers; and the
  five state-pointer corrections if any remain outstanding.
- `docs/dogfood-log.md` — entry 25 (font scale) is still open and out of scope
  here; confirm it is still listed as open and not silently dropped.

---

## 5. Part E — convert the Session 28–31 gate to tests

Sessions 28–31 were never keyboard-verified, and the D59 gate did not cover them
(`session-28-human-gate-checklist.md`, OI27, the D49 day-2 check).

Per §0.1, **do not hand that checklist back to the reviewer.** Work through it and
sort each item:

- **Has a correct answer** → write an automated test. Most of it will land here.
- **Requires judgment** → collect into a short list, no more than a handful of
  items, each phrased as a question about whether something *reads* right rather
  than whether it works.
- **Already covered** → say which existing test covers it and drop it.

Report the three lists with counts before writing the tests.

**OI27 (banner icon) is the likely judgment item** — it needs someone to look at a
banner and say whether the icon is right. Note that the diagnosis question comes
first: establish which delivery path produces the banner before touching the asset
catalog.

---

## 6. Flag, don't invent — escalate rather than decide

1. **No onboarding flow to host the window picker** (C2). Flag and stop.
2. **The window set** — if 2 days / 1 week / 1 month / 3 months / everything is
   wrong, say so rather than silently choosing differently.
3. **Backfill notification suppression not already covered** (C4). Flag; do not
   widen suppression as a side effect.
4. **Any item in Part E that resists both automation and judgment framing** — that
   usually means the underlying behavior is unclear, which is worth surfacing.

---

## 7. Definition of done

- [ ] Work order committed to `docs/workorders/` in the first commit.
- [ ] Decision numbers allocated from a **verified** grep, not assumption.
- [ ] Backups consolidated somewhere durable; location reported and recorded.
- [ ] `git status --porcelain` empty; version stamp no longer reports dirty.
- [ ] `IDEAS.md` and `BEHAVIOR.md` committed.
- [ ] Bulk log written inside the update transaction; nothing reads it for
      decisions.
- [ ] 5,000 cap enforced against the same set the update affects.
- [ ] C1 findings reported **before** C2/C3 implementation.
- [ ] The gap-retrieval test exists and was verified red against the skip-the-gap
      behavior.
- [ ] Part E reports three lists with counts; judgment list is short.
- [ ] All three stop gates honored.
- [ ] Suite counts reported both sides (current: backend 296, frontend 126 + 8
      XCUITests — verify by measurement, do not trust this number).
- [ ] §8 filled in.

---

## 8. Open items (Claude Code fills this in)

**Decision numbers** allocated from a verified grep, per §0: **D60** (bulk log +
cap), **D61** (retrieval window), **D62** (silent backfill). D59 was the highest
previously allocated.

### Owed to the author — decisions, not work

1. **PART F — the write-back finding.** Investigated, not fixed, as instructed.
   `writeback_enabled:you@example.com` is `true`, set deliberately at alpha
   open (Session 25) and recorded in the log — **so this is not a P5 violation**.
   But three things around it are wrong and want a decision:
   - **The single-message path has no per-request opt-in.** Bulk requires
     `write_back: true`; the single path fires on the pref alone. That asymmetry
     is why a *restore* silently marked a real message read. **This is the actual
     defect.**
   - **No write-back is recorded anywhere.** No audit row, no success log line.
     The blast radius is unbounded and unknowable — the only bound available is
     "≤ 292 triage POSTs in the access log", and the true count is not
     recoverable.
   - **The setting is invisible in the UI.** The frontend reads the *global*
     `writeback_enabled` key; the per-account key that actually governs behaviour
     has no UI at all. It is editable only via `PUT /preferences/…` or SQL.

   Proposed, in priority order: (a) require `write_back: true` on the single path
   too, (b) log every `\Seen`, (c) then decide the pref itself. Not implemented.
2. **PART I — OI27.** Diagnosed: banners are **BLANK**, matching neither
   predicted cause. The last 8 delivered notifications were the **osascript**
   path, while native bundle identity and icon assets all verify good (valid
   256×256 icns, `AppIcon` in `Assets.car`, all ten sizes present). **The
   question to chase is why the D45 delivery claim lapsed**, not what is in the
   asset catalog. Fix proposed, not applied.
3. **PART J — Tier 1 persistence.** Entry 16's conclusion ("not app-controllable")
   is **too strong**. `interruptionLevel` is never set (defaults to `.active`);
   `.timeSensitive` is available on macOS 14, needs only a non-approval
   entitlement, and is unused. `.critical` needs Apple approval and is not
   appropriate. True persistence is still the user's alert-style setting, but
   there is a real unused lever. Likely one small change plus a `BEHAVIOR.md`
   entry.

### Flagged deviations from this work order

4. **"2 days" dropped from the window set** (§6.2) — approved in the addendum.
   Reasoning recorded at the constant and in D61.
5. **`IDEAS.md`/`BEHAVIOR.md` kept in `docs/`**, not moved to repo root (§A3
   said root "unless there is a reason not to"). Asked; root is the SDD artifact
   set, every other explanatory doc is in `docs/`.
6. **C3 needed no new mechanism.** The backfill-only asymmetry was *already* the
   behaviour, by accident — polling is UID-based with no date criteria anywhere.
   The work was making it deliberate: a comment at the boundary and a test
   verified red against "correcting" it.
7. **The bulk cap applies to the id mode too**, which §B5 did not specify. An id
   list is as capable of being larger than intended as a filter is.

### Deferred with reasons

8. **Python bundling into the .app — NOT done**, per §H. It is the delivery
   shape and belongs with public-repo distribution work (runtime embedding,
   process lifecycle, port conflicts, crash recovery). Worth noting it would make
   the **entire version-mismatch class impossible by construction**, which is
   what `dev-run.sh` currently guards against by assertion.
9. **Undo — still not built**, deliberately (D60). The log now captures the one
   part that could not be added later.
10. **Dogfood entry 25 (font scale)** confirmed still open and untouched.

### Notes for whoever runs this next

11. **The live store was migrated to schema version 6** (rehearsed on a copy
    first; 5,181 messages and 4,922 done intact). Backups are in the standing
    location recorded in `CLAUDE.md`.
12. **One live-exercise correction:** reverting a test bulk with an inverse
    filter caught 11 messages rather than 10 — one pre-existing `acknowledged`
    message was swept in. Detected by diffing against the snapshot and restored;
    the store ended byte-equivalent in triage state. **The inverse of a filter is
    not the inverse of an operation**, which is an argument for any future undo
    being id-based.
