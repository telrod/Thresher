# Design gate — dogfood batch 1 (spec-level decisions)

> Five items routed "design-gate" from day-one alpha (`docs/dogfood-log.md`).
> Each changes the spec, the schema, or the app's side-effect surface — none is
> buildable from a friction one-liner. Per the OI10–12 lesson (the un-gated
> human seam is where late decisions surface), each gets options **rendered as
> mockups or written contracts** before any workorder is drafted. Decisions made
> here get D-numbers; until then nothing below is buildable.
>
> Suggested order: DG1 first (highest daily friction), DG5 with DG1 (same
> surfacing conversation), then DG2/DG3/DG4 as appetite allows.

## DG1 — Triage-driven list visibility

**The ask (log):** after triaging 10+ emails, the list stops distinguishing
handled from unhandled; Done/Acknowledged items the user never wants to see again
still sit there.

**Tension:** P1 says suppression = delay, never delete — everything must stay
retrievable. P2 says calm — but a list that won't clear is itself un-calm. The
triage model explicitly replaced unread-as-todo; a list that ignores triage state
re-creates the problem one level up.

**Option space to mock:**
- A. **Filter chips** on the list (New / In progress / Done / All) — state is
  visible, nothing hidden by default, one click to focus. Least spec change.
- B. **Done auto-collapses** into a disclosure section at the bottom (visible,
  demoted, still on screen).
- C. **Mode-linked:** Focus mode hides Done/Acknowledged, Catch-up shows all —
  reuses the existing operating-mode concept instead of adding a control.
- Any option: search always spans everything (P1 floor, non-negotiable).

**Decide:** default visibility per triage state × mode; where the control lives;
whether "never want to see again" is actually a *rules* problem (should have been
T5) rather than a triage problem — worth asking during the session.

**DECIDED (the author, Session 25, against rendered mockups) → D50: A + B combined.**

- Filter chips on the list: **Open (default) · Needs action · Done · All**, with
  live counts on each chip.
- **Open = New + Needs action.** Acknowledged is excluded — "seen, nothing owed"
  counts as handled (explicit sub-decision; the conservative include-Ack reading
  was offered and declined).
- **Amendment (the author, Session 26, from the build's flagged nuance):** Open also
  includes **unclassified** mail (no classification row) — a stuck classify
  failure must be visible by default, not parked under All (P1).
- **All** shows everything: Ack rows render normally; **Done additionally
  collapses** into a disclosure section at the bottom (Option B's behavior lives
  inside All).
- Selected chip persists across launches (local UserDefaults, like tutorialSeen).
- **Search always spans every state regardless of chip (P1 floor).** Tier-first
  ordering unchanged within any view. No effect on classification, notifications,
  or digest.
- Modes stay tier-only (Option C rejected — overloads the mode concept).
- Companion insight recorded, not yet actioned: much "never see again" mail is a
  RULES gap (should classify T5), not a triage gap — "create rule from this
  message" is a future idea that would shrink the residual problem.
- Implementation: own workorder AFTER polish batch 1 lands (same files move under
  polish Parts A–D; avoid crossing the streams). Spec §4.1.1 amendment rides with
  that workorder.

## DG2 — "Junk" as a triage action (server-side junk marking)

**The ask (log):** a Junk button that also tells the mail server it's junk.

**Tension:** this is a **new outward side-effect class** — write-back v2. D16/D21
scoped write-back to \Seen precisely because it's benign and reversible. Junk is
neither as benign (Gmail spam-training has consequences) nor symmetric (un-junk
exists but the training signal already fired).

**What's technically true (grounded):** Gmail over IMAP has no \Junk flag; junk =
COPY/MOVE to `[Gmail]/Spam`. Moving a message changes its UID/mailbox — which
interacts with our `{account}:{uid}` identity and the cursor. Doable, but it
touches identity assumptions, not just a flag.

**Decide:** is Junk a triage state (5th button), a separate action, or out of
scope for v1.x? If in: same P5 shape as write-back (per-account opt-in, off by
default, targeted by Message-ID, best-effort)? What happens to the local row after
a server-side junk (ties to DG1)?

**DECIDED (the author, Session 25) → D54: DEFERRED — the gate's first defer.**

- **Why:** (1) junk = MOVE to `[Gmail]/Spam` — changes UID and mailbox, cutting
  across the `{account}:{uid}` identity layer while OI15 + D53 migrations are
  actively reworking it; (2) the in-app need is covered by rules→T5 + D50, and
  the server-side need by D48 (Gmail's own Report-spam, one click away, with
  Google's undo semantics); (3) P5 trust ladder — write-back v1 is one day old;
  junk is the largest side-effect grant yet requested. Local-only Junk state
  also declined (a rules problem wearing a triage costume).
- **Revisit trigger:** after the identity layer settles (OI15 shipped, D53
  migration machinery proven) AND alpha shows a real recurring need D48+rules
  don't cover.
- **Contract sketch parked for that day:** P5 per-account opt-in, off by
  default; Message-ID-targeted, single-match-or-abort; local row KEPT (P1),
  marked junked; silent (no retro notifications).

## DG3 — Multi-pattern sender groups

**The ask (log):** one group, several email patterns (family = several addresses).

**Tension:** schema change (`sender_groups.email_pattern` is a single TEXT), plus
matcher, API payload, editor UI, and the seed format. Small in concept, wide in
touch points — exactly the kind of change that wants a written contract first.

**Option space:**
- A. Patterns child table (clean relational shape, real migration).
- B. Delimited list in the existing column (no migration, ugly, fast).
- C. Keep one-pattern groups; allow multiple groups to share a name/floor
  (zero schema change — does the UI story survive?).

**Decide:** shape + migration story + how the editor renders multiple patterns.
Note the D44 lesson: last time a contract question like this came up, plain
language first produced a better contract than either offered option — pose the
question in plain language before picking.

**DECIDED (the author, Session 25, against a rendered editor mockup) → D53: Option A,
child table, and the project's first real migration.**

- **Plain-language contract:** a sender group is a named set of address patterns
  sharing ONE floor tier; a sender matching ANY pattern is in the group.
- **Storage:** `sender_group_patterns` child table (group_id, pattern).
  Existing `email_pattern` becomes the group's first pattern row.
- **API contract:** sender-group payloads carry `patterns: […]`; PUT replaces
  the pattern set atomically (all-or-nothing, the D44 shape). Empty set invalid.
- **Migration machinery (the real scope):** versioned schema (schema_version),
  migrations run once at startup; OI5's legacy-CHECK debt sweeps into the same
  mechanism — one migration system, two debts paid. This is the project's first
  migration against a live user DB (the author's alpha data) — backup-before-migrate
  is part of the contract.
- B rejected (delimiter becomes load-bearing), C rejected (per-row floors can
  diverge — sender-override invariant would have two answers for one group).
- Implementation: own workorder; backend-first. Editor UI (rendered mockup:
  name + floor + pattern list with add/remove) can follow in the same order.

## DG4 — Reclassify on demand

**The ask (in-session):** rule edits never touch stored mail (classify-once at
ingest); user expected the new category to apply and saw "Unknown".

**Tension:** classify-once is a real design property (an audit trail is stable;
history doesn't rewrite under you — P3-adjacent), not an accident. But the rules
editor now makes rule iteration cheap, and every iteration widens the gap between
"rules as written" and "classifications as stored".

**Option space:**
- A. Per-message "Reclassify now" in the detail view (surgical, user-invoked,
  audit trail notes the re-run).
- B. "Apply to existing mail?" prompt after a rule create/edit (scoped re-run:
  only messages the changed rule could match).
- C. Bulk "reclassify all" in Settings (blunt; long-running; progress UI).
- D. Status quo + copy: label the badge "classified <date>" so the fossil is
  legible instead of confusing.

**Decide:** which shape (A and D compose well); whether reclassification
overwrites or versions the classification row; what `/explain` shows after a
re-run (P3: the audit trail must say it was reclassified and when).

**DECIDED (the author, Session 25, against rendered mockups) → D52: A + C + D; B declined.**

- **A** — "Reclassify now" in the detail view's explain panel (per-message,
  user-invoked).
- **C** — Settings bulk "Reclassify all mail" (loop over the existing engine;
  progress UI; solves the standing fossil pile — 1,386 messages classified by
  early rule drafts).
- **D** — the classification is dated in the explain panel ("Classified <date>"),
  with "N rules have changed since" staleness copy. Requires a small
  `rules.updated_at` schema addition (flagged, accepted).
- **B declined**: after-save apply-prompt's scoping problem buys little once C
  exists; may return later as sugar over C.
- **Contract invariants (pinned regardless of shape):** (1) triage state
  survives reclassification — a Done message reclassified to T1 stays Done;
  (2) reclassification is SILENT — no retroactive banners or digest entries;
  (3) overwrite with dated audit, never version — `/explain` shows
  "reclassified <date>" plus the fresh trail (P3); (4) classify-once-at-ingest
  remains the default lifecycle — reclassify is always explicit user action,
  never automatic.
- Implementation: backend + detail/Settings UI — own workorder, sequenced after
  the D50/D51 workorder (explain-panel and Settings surfaces overlap).

## DG5 — What does a missed banner leave behind?

**The ask (log, second half of the E21 entry):** the banner vanished before it
could be acted on.

**Grounding:** macOS *banners* auto-dismiss by design; *alerts* persist but that's
a per-app user choice in System Settings, not something the app sets. So the real
question isn't "make banners stay" — it's what in-app trace a notification leaves.

**Option space:**
- A. Rely on the list + DG1's visibility work (a T1 you missed is at the top
  anyway; is that enough?).
- B. Dock badge count for unseen Tier 1/2 (ambient, P2-friendly, zero windows).
- C. A small in-app "recent notifications" tray fed from `notification_log`
  (the data already exists; read-only view).
- D. Onboarding/setting hint suggesting the user switch Thresher to alert-style
  notifications in System Settings (no code beyond copy + deep link).

**Decide:** which combination; whether Tier 1 warrants a stronger floor than
Tier 2 (the Tier-1 invariant is about *surfacing* — does it extend to
*persistence of the surface*?).

**DECIDED (the author, Session 25, against rendered mockups) → D51: B + D.**

- **B — dock badge = count of untriaged (state New) T1/T2 messages**, i.e. the
  D50 Open view's urgent tail. Derived entirely from existing triage state — NO
  new "seen" concept; triaging a message (any advance past New) decrements it.
  Clears to no badge at zero. Extends the Tier-1 invariant to persistence of
  surface without new state.
- **D — alerts hint**: one line + "Open System Settings" affordance in BOTH the
  onboarding notifications step and Settings §4.3 — banners auto-dismiss by OS
  design; alert-style persistence is the user's OS choice, honestly presented.
- **C (tray) declined**: D50's Open view already answers "what did I miss";
  notification_log stays log-only. **A** noted as the floor D50 provides.
- Implementation rides in the same post-polish workorder as D50 (both touch the
  list model's state accounting; one workorder, one seam).
