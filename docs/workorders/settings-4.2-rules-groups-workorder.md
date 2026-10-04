# Work Order — Settings §4.2: Classification Rules + Sender Groups (SwiftUI / thresher)

> **For:** Claude Code (CLI), run from the repo root.
> **Why:** Settings §4.1 (Email Accounts + reusable `AccountConnectView`) is built, human-verified,
> and committed (`565c0d5` + the E16 keyboard fix `3cffcc4`). This work order builds **§4.2** — the
> two editable config lists (P4). The model + networking layer for all of Settings §4 was built and
> signed off in `6d8fe86`, so this is a **view/VM-layer build only**.
> **Settings IA (D43 / OI10 → B, OI11 — settled, build to it):** `SettingsView` stays mounted in
> its own sheet/window destination (the toolbar sheet + the ⌘, Settings scene — committed in
> `7a415fb`). The app's MAIN window `NavigationSplitView` (Message List ↔ Message Detail) is NOT
> touched and Settings sections are NOT destinations in it. Inside `SettingsView` an *internal*
> `NavigationSplitView` runs the show: a sidebar `List` drives a detail pane, one row per area.
> **Classification rules** and **Sender groups** are two **sibling rows** in that internal sidebar
> (OI10 → B: Rules is a sidebar row, not a top-level screen; OI11: Sender Groups is its own sibling
> row, not nested under Rules) — they are NOT one combined "§4.2 section." Each builds into its own
> detail pane.
> **Scope:** `frontend/` SwiftUI only. **Do NOT touch `backend/`.** Flag-don't-invent (parent §0.5).
> **Parent work order:** `docs/workorders/settings-screen-workorder.md` — its §0 operating rules,
> §1 shape traps, §2 model layer, and §3 networking are the ground this builds on and are **not
> repeated** here except where §4.2 leans on a specific trap. Read the parent first.
> **Out of scope:** §4.3 Notification Preferences (next work order); Onboarding §4.1.4; OI4.

---

## 0. Locked decisions (settled with the author this session — build to these, don't relitigate)

1. **`field` / `operator` are enums with an explicit `.unknown` case**, not validated strings.
   This gives compile-time-exhaustive `Picker` sources in the editor and forward-compat if the
   backend vocabulary grows. The decode path already exists from the model layer; this governs how
   the editor *binds*. Vocabularies are fixed:
   - `field ∈ {sender_email, sender_domain, subject, body, sender_group}`
   - `operator ∈ {equals, contains, starts_with, ends_with, matches_group}`
   `.unknown` is render-only (show the raw string, disable save) — the editor never *writes* it.
2. **Both-effects invariant is enforced client-side** (parent trap §1.3). The rule editor holds
   "**at least one of `set_tier` / `set_category` is always set**" as an editor invariant: each
   effect is independently clearable, but the clear affordance on whichever effect is currently the
   *only* one set is **disabled**. The server `400` is still handled calmly if it ever fires, but
   the user cannot normally reach it. Do **not** ship a dumber editor that relies on the `400` alone.
3. **Editing is a sheet**, matching the §4.1 `AccountConnectView` pattern — not inline, not a
   `NavigationLink` push. Reuse the established conventions: `@FocusState`-driven field order,
   `.onSubmit` that consumes Return (advance focus / submit-when-valid), calm inline error text,
   Escape/Cancel dismiss. This keeps one interaction model across the whole Settings screen and
   inherits the E16 focus/submit fixes.
4. **`enabled` read-int / write-bool split is real** (parent trap §1.2). Decode `enabled` as `0/1`
   int on read; the toggle and the editor write a JSON **bool**. Confirm the write-DTO from the
   signed-off model layer still expresses this; if a single round-tripping type slipped in, fix it.
   A pure toggle is `PUT /rules/<id> {"enabled": <bool>}` — patch semantics leave the effects
   intact, so a toggle can never trip the both-null guard.
5. **Phase 1 is a hard stop-for-review gate.** The Rules read + toggle path is reviewed running
   against the live backend **before** the editor is built. This is where the int/bool split and
   `include_disabled` first get exercised live; prove them before layering CRUD on top.

---

## 1. The traps that bite this section (parent §1, the §4.2 subset)

- **§1.1 — `include_disabled=true` is mandatory.** `GET /rules` defaults to enabled-only. The
  editor MUST call `getRules(includeDisabled: true)` or a toggled-off rule vanishes and can never
  be re-enabled from the UI.
- **§1.2 — `enabled` int-read / bool-write** (see locked decision #4).
- **§1.3 — both-null rule guard, post-merge** (see locked decision #2). On *edit*, "remove a rule's
  tier" means sending the surviving effect, **not** blanking both — `PUT` patch semantics leave an
  omitted effect intact.
- **§1.6 — `<int:rule_id>` / `<int:group_id>` route-match.** The client only ever builds integer
  paths. If a non-integer path ever 404s, that's a route miss, not "not found" — don't render it as
  not-found copy.
- **§1.7 — edits apply to future polls, not retroactively.** The classifier reloads rules/groups
  each poll (E11/D37), so edits go live without restart, but already-stored messages are **not**
  reclassified. UI copy must not promise retroactive re-tiering.

---

## 2. Endpoint shapes (from `docs/api-contract-map.md` — the contract, not assumptions)

**Rules**
- `GET /rules?include_disabled=true` → `200 { "rules": [...], "sender_groups": [...] }`.
  `rules` ordered `priority ASC`; each element is the full row: `id:int`, `rule_name:string`,
  `priority:int` (ordinal rank; dense 1..N after any reorder — D44), `enabled:int 0/1`, `field:string`, `operator:string`, `value:string`,
  `set_tier:int? 1–5`, `set_category:string? work|personal`, `notes:string?`.
- `POST /rules` → `201` created rule (full-row shape, incl. new `id`). Required: `rule_name`,
  `field`, `operator`, `value`, **≥1 of `set_tier`/`set_category`**. Optional: `priority` (defaults to `MAX+1` — appends; D44),
  `enabled` (bool, def true→stored 1), `notes`. Invalid → `400 {"error": …}`.
- `PUT /rules/<int:rule_id>` → `200` updated rule. Patch semantics (only provided fields). Post-merge
  guard: merged result must keep ≥1 effect non-null else `400`. `404 {"error":"rule not found"}`.
- `DELETE /rules/<int:rule_id>` → `200 {"deleted": <id>}`; `404` if unknown.
- `PUT /rules/reorder` (D44) → `200 {"rules":[…]}` (full reordered set, GET shape). Body:
  `{"ordered_ids":[…]}`, position IS priority; server renumbers dense 1..N in one transaction.
  `400` malformed (missing/dup/non-int, names `duplicate`); `409` stale set (membership drift,
  names `unexpected`/`missing`). Exact-permutation-of-all-rules invariant, disabled included.

**Sender Groups**
- Read via the `sender_groups` array on `GET /rules` (ordered `urgency_floor ASC`): `id:int`,
  `group_name:string`, `email_pattern:string`, `urgency_floor:int 1–5`, `notes:string?`.
- `POST /sender-groups` → `201` created group. Required: `group_name`, `email_pattern` (non-empty
  after strip), `urgency_floor` (1–5). Optional `notes`. `400` on validation failure.
- `PUT /sender-groups/<int:group_id>` → `200` updated group; patch semantics; `404` if unknown.
- `DELETE /sender-groups/<int:group_id>` → `200 {"deleted": <id>}`; `404` if unknown.

Networking methods already exist from §3 of the parent (`getRules`, `createRule`, `updateRule`,
`deleteRule`, `createSenderGroup`, `updateSenderGroup`, `deleteSenderGroup`). **Confirm they're
present and `Sendable`-clean before Phase 1; do not re-add them.**

---

## 3. Phased build (atomic commits, gated)

**Phase 0 — Ground (no code).** Re-read the parent §0–§3 and the `GET /rules` / CRUD entries in
`api-contract-map.md`. Read `SettingsView` + `AccountConnectView` as they stand post-`3cffcc4` to
match the sheet/focus conventions. Confirm the §2 networking methods exist and are `Sendable`-clean,
and the read passes `include_disabled=true`. Confirm the `enabled` write-DTO split (decision #4).

**Phase 1 — Rules list + toggle (one commit). HARD GATE — stop after this.** ✅ **DONE** (`7a415fb`).
Rules list + `@Observable` VM. Fetch with `include_disabled=true`. Row shows `rule_name`, `priority`,
the `field`/`operator`/`value` triple, tier/category effect badges (reuse the shared `Tier`/`Category`
enums), and an **enable/disable toggle** writing `PUT /rules/<id> {"enabled": <bool>}`. The row stays
visible across enabled→disabled→enabled (proves §1.1). No editor yet. The Rules list mounts as the
**Classification rules** detail pane of the internal Settings sidebar (D43). **Stop; the author reviews this
running against the live backend before Phase 2.**

**Phase 2 — Rule editor sheet (one commit).** Add / edit / delete (delete behind a confirm).
Vocabularies bound via `Picker`s off the decision-#1 enums. The decision-#2 both-effects invariant
enforced client-side. On edit, send the surviving effect rather than blanking both (§1.3). Any `400`
renders calmly inline, no crash. Sheet follows the §4.1 focus/submit pattern.

> **OI12 pre-req — RESOLVED (D44 / Amendment 1; backend built, not pushed).** Reorder writes back
> via a single **batch endpoint** — `PUT /rules/reorder {"ordered_ids":[…]}`, position IS priority,
> server renumbers dense (1..N) in one transaction. Option (b) was chosen over (a) sequential PUTs
> (no atomicity, classifier exposure to a half-applied order). The endpoint exists, is tested, and is
> verified-by-running; the editor is now written against a real contract. See
> `docs/workorders/settings-4.2-amendment-1-reorder.md` and the `PUT /rules/reorder` entry in
> `api-contract-map.md`.
>
> **OI12 addendum (presentation).** The row still surfaces the literal stored integer `priority`, but
> post-D44 that integer reads as a **dense rank** (#1, #2, #3 …) rather than gapped values (10/20/30).
> This is *more* legible for the P3 debugging case — "this rule is #2, it runs before #3" — than
> arbitrary gaps. The drag-to-reorder + visible-integer decision is unchanged; only the presentation
> improved. **The Phase 2 editor itself remains gated** on the author's two human gates (Phase 1 hands-on
> review; re-housed Settings interaction round-trip).

**Phase 3 — Sender Groups list + editor sheet (one commit).** This is the **Sender groups** sibling
row's detail pane (OI11) — a separate internal-sidebar destination from Classification rules, not a
second part of one combined section. List (`group_name`, `email_pattern`, `urgency_floor`) read off
the `sender_groups` array. Add / edit / delete sheet, same pattern as Phase 2. Client-side validation:
non-empty `email_pattern`, `urgency_floor ∈ 1–5`; server enforces too. Surface the server `400` calmly.

**Phase 4 — Verify.** Both detail panes (Classification rules, Sender groups) already mount as sibling
rows in the internal Settings sidebar — Phase 1 landed the sidebar shell (`7a415fb`), so each phase
fills in its own pane rather than re-wiring a main-window destination. Run §4 checks; capture
screenshots via the temporary-root swap (OI-S5 — assistive access still denied on this host, so ⌘, /
the gear button can't be driven programmatically; swap the app root to `SettingsView` for the
screenshot, then revert, uncommitted).

---

## 4. Verify by running (live backend; parent §5, the §4.2 subset)

- [ ] Rules list shows a **disabled** rule (confirms `include_disabled=true`) and the toggle flips it
      enabled→disabled→enabled, the row staying visible throughout.
- [ ] Create a rule, edit it, delete it — full CRUD round-trips.
- [ ] In the editor, the only-remaining effect's clear control is disabled (decision #2); if a both-null
      `PUT` is forced through, the `400` renders calmly, no crash.
- [ ] Edit a rule to swap its effect (tier→category) and confirm the survivor is sent, not both blanked.
- [ ] Create / edit / delete a sender group; `urgency_floor` outside 1–5 is rejected client-side and,
      if forced, server-side.
- [ ] Empty `email_pattern` is rejected.
- [ ] Headless `xcodebuild clean build` green; new sources hand-wired into `project.pbxproj` (OI6);
      `Sendable`-clean, no new strict-concurrency warnings (D42).

**OI-S3 caveat:** the seed has **no** disabled rule, so the "shows a disabled rule" check requires
create-then-disable at run time via the editor — not pre-seeded. Don't read it as covered by seed data.

---

## 5. Definition of done

- [ ] Phase 1 reviewed running by the author before Phase 2 was built (hard gate honored).
- [ ] Both §4.2 sidebar rows (Classification rules, Sender groups) functional against the live backend,
      each in its own detail pane; `frontend/`-only; backend untouched.
- [ ] Every locked decision (#1–#5) and every §1 trap honored.
- [ ] §4 run-checks pass; screenshots captured (temporary-root swap, reverted).
- [ ] New source files hand-wired into `project.pbxproj`; build green; D42 clean.
- [ ] Three atomic commits (Rules read+toggle / Rule editor / Sender Groups), conventional messages,
      repo-local personal noreply identity (`you@example.com`), **no
      `Co-Authored-By` trailer, NOT pushed** — the first push stays held until §4.1–4.3 all land and
      the author has reviewed each diff.
- [ ] "Open items" below filled in with anything flagged-not-invented.

---

## Open items (Claude Code fills this in)

- **OI12 reorder write-back — RESOLVED (D44 / Amendment 1).** Option (b) chosen: batch endpoint
  `PUT /rules/reorder {"ordered_ids":[…]}`, dense server-side renumbering in one transaction. Backend
  built, tested, verified-by-running (not pushed — push gate held). See the Phase 2 pre-req note and
  `docs/workorders/settings-4.2-amendment-1-reorder.md`. Phase 2 editor still gated on the author's two
  human gates.
