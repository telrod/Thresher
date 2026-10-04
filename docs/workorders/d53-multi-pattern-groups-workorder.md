# Work Order: D53 — multi-pattern sender groups + the project's first real migration

> Session 28, Phase 4. Drafted agent-side (authorized deviation, run prompt §Phase
> 3/4). Sources: `docs/design-gate-dogfood.md` **DG3** and the **D53** decision-log
> entry — both quoted, not paraphrased, in §1. Track this file in git at creation,
> before the first code commit.
>
> **Phase order note:** this workorder runs BEFORE the D52 workorder, swapping the
> run prompt's Phase 3/4 order. Reason (the author's call, recorded as a deviation):
> D52's `rules.updated_at` addition cannot reach the live alpha DB, because
> `init_db` uses `CREATE TABLE IF NOT EXISTS` and the `rules` table already
> exists. D52 needs migration machinery, and building that machinery IS this
> workorder's real scope. So the framework lands here and D52 becomes its second,
> much simpler migration.

## §0 Ground rules

- **DO NOT PUSH.** The three-variant deny fence stands and must not be edited.
  (Phase 1 of this run already proved it is armed.)
- Atomic commits, conventional messages, noreply identity, no Co-Authored-By.
- **Flag-don't-invent.** Adjacent issues get flagged in the run summary, not fixed.
- Report must contain a **Deviations** section (may be "none").
- Verify-by-running with pasted evidence; red-first for every guard test that
  claims to prevent a regression.

## §1 The decided contract (quoted, not paraphrased)

From **DG3 — DECIDED (the author, Session 25, against a rendered editor mockup) → D53:
Option A, child table, and the project's first real migration**:

- **Plain-language contract:** "a sender group is a named set of address patterns
  sharing ONE floor tier; a sender matching ANY pattern is in the group."
- **Storage:** `sender_group_patterns` child table (group_id, pattern). "Existing
  `email_pattern` becomes the group's first pattern row."
- **API contract:** "sender-group payloads carry `patterns: […]`; PUT replaces the
  pattern set atomically (all-or-nothing, the D44 shape). **Empty set invalid.**"
- **Migration machinery (the real scope):** "versioned schema (schema_version),
  migrations run once at startup; **OI5's legacy-CHECK debt sweeps into the same
  mechanism** — one migration system, two debts paid. This is the project's first
  migration against a live user DB (the author's alpha data) — **backup-before-migrate is
  part of the contract**."
- Rejected: B (delimited list — "delimiter becomes load-bearing"), C (shared
  name/floor across rows — "per-row floors can diverge → the sender-override
  invariant would have two answers for one group").
- **Implementation: own workorder; backend-first.** Editor UI (rendered mockup:
  name + floor + pattern list with add/remove) "can follow in the same order."

Per this run's **D55** (OI19's D-series call), one addition to the above:

- **Rules move to match-by-id in this migration.** Existing `matches_group` rules
  reference groups by NAME, so renaming a group silently orphans its rules. Map
  existing rules to group ids as part of this migration. **Any rule that cannot be
  mapped unambiguously is FLAGGED in the run summary, never guessed.**

**Explicitly OUT of scope** (run prompt Phase 4): **OI4 and OI15** — DG3 does not
sweep them in, so they are not touched. Flag, don't add.

## §2 Preconditions (check and paste BEFORE any write)

1. Backend suite green at the count this run established: **184**.
2. Frontend suite green: **35**.
3. `git status -sb` clean (or only this file staged).
4. **Back up the live DB and record the path in the run summary.** A
   `pre-session28` backup already exists from Phase 0; take a **fresh, separate
   pre-migration backup** anyway — the DB has been written to since (the Phase 0
   classification restore).
   ```
   sqlite3 "$DB" ".backup '<backups>/thresher.pre-d53-migration.db'"
   sqlite3 "<backup>" "PRAGMA integrity_check;"      # must print ok
   ```
   Record row-count parity for `messages`, `classifications`, `rules`,
   `sender_groups` between live and backup.
5. Record the live DB's starting state, which the migration must preserve exactly:
   group count, each group's name/pattern/floor, and every `matches_group` rule's
   `value`. This is the before-picture the after-picture is diffed against.

**Pre-flights already run while drafting this workorder** (read-only; each result
is used above, so the workorder is written against the real DB rather than an
assumed one):

| Check | Result |
| ----- | ------ |
| `PRAGMA user_version` on the live DB | **0** — as expected for a pre-framework DB; the framework must treat 0 as "apply everything" |
| `PRAGMA foreign_keys` in `get_connection` | **already ON** (`db/database.py:68`) |
| Groups with an empty `email_pattern` | **0 of 5** — no empty-pattern groups in live data |
| `matches_group` rules resolving to exactly one group | **5 of 6** (`Me` only via the D55 casefold) |
| `matches_group` rules resolving to zero groups | **1** — rule 10, `value='unknown'` |
| Live `rules` table carries the both-null CHECK | **No** — OI5 is live |
| Rules violating the both-null CHECK | **0** — the OI5 rebuild is safe |

## Part 1 — The migration framework (the real scope)

The framework is the deliverable; the schema change is its first customer. Build it
so D52's `rules.updated_at` is a three-line addition, not a second mechanism.

1. **Version marker.** Use SQLite's built-in `PRAGMA user_version` (no new table —
   the project's drop-the-dependency instinct: Redis → `queue.Queue`, keyring →
   `security`). Fresh DBs from `schema.sql` land at the current version; existing
   DBs report 0.
2. **A migration registry**: an ordered list of `(version, description, fn)`.
   `migrate(conn)` applies every migration whose version exceeds
   `PRAGMA user_version`, in order, **each inside its own transaction**, then
   stamps the new version. A failing migration rolls back and re-raises — a
   half-applied schema must never be committed (the D44 lesson: the
   reload-per-poll classifier must never see a half-applied state).
3. **Idempotency-guard every migration.** Each must be safe to run twice: check
   for the column/table before adding it. Prove it by running `migrate()` twice in
   a test and asserting the second run is a no-op.
4. **Runs once at startup**, called from `init_db` after the schema script, so
   both `main.py` (poller) and `api.server` get it on any entry path. Log loudly:
   version before, each migration applied, version after. (Session 27 lost time to
   a silently stale runtime; the provenance workorder in Phase 5 is the companion
   fix.)
5. **Backup-before-migrate in code, not just in this document.** Before applying
   any migration to a non-empty DB, copy the file to
   `<db>.pre-v<N>.backup` and log the path. A user's alpha data must never depend
   on an operator remembering to back it up.
6. **Tests (red-first where they guard a regression):** fresh DB reaches current
   version with no migrations run; a v0 DB built from the OLD schema migrates to
   current; double-`migrate()` is a no-op; a deliberately failing migration leaves
   the version and data untouched (rollback proof).

## Part 2 — `sender_group_patterns` (the first migration)

1. **Schema** (`schema.sql`, so fresh DBs get it directly):
   ```sql
   CREATE TABLE IF NOT EXISTS sender_group_patterns (
       id        INTEGER PRIMARY KEY AUTOINCREMENT,
       group_id  INTEGER NOT NULL REFERENCES sender_groups(id) ON DELETE CASCADE,
       pattern   TEXT NOT NULL
   );
   ```
   Decide and record: index on `group_id`; whether `(group_id, pattern)` is UNIQUE
   (recommended — a duplicate pattern in one group is meaningless).
2. **Migration v1:** create the table, then **copy each existing
   `sender_groups.email_pattern` into a pattern row** for that group. Groups whose
   `email_pattern` is empty get **no** pattern row, and must be handled by Part 3's
   empty-set rule.
   **Pre-flight result (checked against the live DB while drafting): all 5 groups
   have a non-empty pattern** — the seed's `family`/`recruiters` placeholders
   (`''`) were filled in during alpha, so the migration has zero empty-pattern
   groups to carry. The empty case still needs handling (a fresh seed DB has it,
   and the editor can create it), but it is NOT a live-data migration concern.
   Live groups at drafting time:
   ```
   1 leadership       [boss@example.com]  floor 1
   2 family           [colleague@example.com]         floor 1
   3 close_colleagues [*@example.com]                 floor 2
   4 recruiters       [*@cypresshcm.com]              floor 2
   7 Me               [*@example.org]                floor 1
   ```
3. **`email_pattern` retention:** keep the old column for one release (do not drop
   it in this migration) so a rollback to the previous binary still classifies. The
   engine stops reading it (Part 4). Record this as a deliberate two-step
   deprecation, and note the follow-up to drop it.
4. **Cascade:** deleting a group must delete its patterns. `ON DELETE CASCADE`
   requires `PRAGMA foreign_keys=ON` per connection — **pre-flight: already set, at
   `db/database.py:68` in `get_connection`**, so cascade will work on every
   connection the app opens. Still **verify by running** (a pragma that is set but
   ineffective looks identical to one that works, in review).

## Part 3 — Repo + API surface

1. **`RulesRepo`**: `all_sender_groups()` returns each group with its `patterns`
   list. Watch the N+1: one query with a join or a grouped second query, not one
   query per group (the engine loads this every poll).
2. **Create/update**: payloads carry `patterns: [...]`. **PUT replaces the pattern
   set atomically** — delete-then-insert inside ONE transaction (the D44 shape).
   The client never diffs patterns.
3. **Validation** (mirror the E12/E22 lesson — validate post-merge on update, and
   reject on BOTH sides):
   - `patterns` must be a non-empty list of non-empty strings (**empty set
     invalid**, per DG3);
   - reject a payload carrying both `patterns` and the legacy `email_pattern` with
     conflicting content, rather than silently preferring one;
   - **decide and document** whether legacy single-`email_pattern` payloads are
     still accepted (recommended: accept and normalize to a one-element
     `patterns`, so an older client is not broken mid-alpha).
4. **Serializer parity (E10):** every serializer that emits a sender group must
   emit the same group shape. Grep them all; a per-query shape difference is the
   exact E10 trap. Add a guard test that pins the shape across every endpoint that
   returns groups.

## Part 4 — Engine: match ANY pattern

1. `_match_sender_groups` iterates a group's **patterns** and matches if **any**
   matches. `_pattern_matches` itself is unchanged (exact / glob / `@domain`).
2. **The floor stays per-GROUP, never per-pattern** — this is the invariant that
   killed option C. A group has ONE floor; matching two patterns in one group is
   still one membership.
3. **Red-first tests** in `backend/tests/test_engine.py` (created this session):
   a two-pattern group matches a sender via the second pattern; a group with one
   pattern behaves exactly as before; a sender matching two patterns of the same
   group produces ONE membership and one floor application, not two.

## Part 5 — Rules match-by-id (per D55)

1. Add `sender_group_id` to `rules` (nullable), and **migrate existing
   `matches_group` rules** by resolving `value` → group id using the **D55
   case-insensitive** comparison (`strip().casefold()` on both sides — the OI19 fix
   is what makes "Me" resolvable at all).
2. **Ambiguity and misses are flagged, never guessed:**
   - a value matching NO group → leave `sender_group_id` NULL, keep the name, and
     **list the rule in the run summary**;
   - a value matching MORE THAN ONE group (possible if names differ only by case)
     → leave NULL and **flag it**.
   **Pre-flight result (live DB, case-insensitive resolution):** 6 `matches_group`
   rules; 5 resolve to exactly one group each (`leadership`, `family`, `recruiters`,
   `close_colleagues`, and **`Me` — which resolves only because of the D55 casefold
   fix**); **rule 10 (`value='unknown'`) resolves to ZERO groups.** So the miss path
   WILL fire exactly once, expectedly. Report it; do not invent an "unknown" group
   to make the number come out even. Note rule 10 is a T4 catch-all whose intent
   ("sender in no known group") the name-based matcher never actually implemented —
   worth flagging as its own question, not fixing here.
3. **Matching precedence:** the engine prefers `sender_group_id` when set and falls
   back to the name comparison when NULL. Keeping the fallback is what makes this
   migration non-breaking; record it as deliberate, with the follow-up to remove
   the fallback once every rule carries an id.
4. **Renaming a group must no longer orphan its rules** — the D55 gap. Add the test
   that proves it: create a group + a rule by id, rename the group, assert the rule
   still matches. That test is the whole point of Part 5.

## Part 6 — OI5 sweeps in (same mechanism, second debt)

Per DG3, "one migration system, two debts paid." OI5: legacy DBs keep a
constraint-free `rules` table, because the `CHECK (set_tier IS NOT NULL OR
set_category IS NOT NULL)` only lands on fresh DBs.

1. Migration: detect the missing CHECK, then rebuild — `CREATE TABLE rules_new …
   (with the CHECK); INSERT … SELECT …; DROP rules; RENAME`. Inside one
   transaction, with the priority order preserved exactly.
2. **Pre-flight the data:** if any existing row VIOLATES the constraint, the
   rebuild fails. **Pre-flight result: the live DB's `rules` table carries NO CHECK
   (OI5 confirmed live, not merely theoretical) and has 0 violating rows** — so the
   rebuild is safe to attempt. The guard stays in the code anyway: count violators
   first and **STOP and flag** if any exist. Never delete or mutate user rules to
   make a migration fit.
3. Prove it: a v0 DB built from the old schema, with the old table, ends with the
   CHECK enforced and all rules intact in the same order.
4. Close OI5 in the log only if this actually ships; otherwise say so.

## Part 7 — Editor UI (backend-first, so this follows)

Per DG3's rendered mockup: name + floor + **pattern list with add/remove**.

1. `SenderGroup` model gains `patterns: [String]`; the editor edits the list
   (add/remove rows), and Save sends the whole set (PUT replaces atomically).
2. Follow the **OI16 lesson**: add/remove are **explicit visible controls**, not
   context-menu-only.
3. Empty-set is invalid, so Save must be disabled with a visible reason — not a
   silent no-op — when the list is empty. Remember the live placeholder groups have
   zero patterns; opening one must not present a broken editor.
4. Render evidence at **real data** (the OI18 lesson): a group with several
   patterns, and a placeholder group with none.

## Part 8 — Definition of done

- [ ] Fresh pre-migration backup taken; path + `integrity_check` + row parity in
      the summary.
- [ ] Migration rehearsed **on a copy** first; only then run against the live DB.
      Both runs' logs pasted.
- [ ] Framework tests green, incl. double-run no-op and rollback-on-failure.
- [ ] Backend suite green; exact count, reconciled against **184**.
- [ ] Frontend builds; suite green, reconciled against **35**; D43/D47 layout
      guards still pass.
- [ ] Engine: multi-pattern matching + one-membership-per-group proven red-first.
- [ ] Rules match-by-id: rename-doesn't-orphan test green; unmapped/ambiguous
      rules listed in the summary.
- [ ] OI5 either closed with evidence, or explicitly reported as not-shipped.
- [ ] Live-DB after-picture diffed against the before-picture from §2.5: same
      groups, same floors, patterns preserved, rule order unchanged.
- [ ] `git ls-files docs/workorders/` includes this file.
- [ ] `git status -sb` in the report. **No push.**

## §3 Human gate items (the author at the keyboard — feeds the Phase 6 checklist)

1. Open a sender group with several patterns; add one, remove one, save; reopen and
   confirm the set persisted.
2. Open a placeholder group with **no** patterns; confirm it renders sanely and
   Save is blocked with a visible reason.
3. Rename a group that a rule targets; send/probe mail for a member sender and
   confirm the rule **still matches** in the explain panel (the D55 gap, closed).
4. Confirm classification still works end-to-end after the migration — the alpha
   DB is real data, and the migration touched the table the engine reads every
   poll.
