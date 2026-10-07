# Workorder — Onboarding "ask" step (minimal)

**Status:** Revised after Phase 0, for the maintainer's review
**Goal:** A stranger who installs Thresher and finishes onboarding can get Tier 1 mail. Today they cannot.

---

## Why

Confirmed in `CLAUDE.md`:

- Both Tier 1 rules match sender-group membership (`leadership`, `family`).
- Those groups ship with placeholder members that match nobody: `boss@example.com` in one, nothing in the other.
- On a fresh install, measured on the 150-message demo corpus, the split across T1–T5 is **0 / 15 / 21 / 70 / 44**.

So a stranger's first experience is a list with no Tier 1, and focus mode, which alerts on Tier 1 only, stays silent.

## Scope

**In:**
- One onboarding step that asks for the people whose mail matters most and writes them into the `leadership` and `family` groups.
- It replaces the placeholder `boss@example.com`.
- Server-side pattern normalization and validation for sender groups. This is needed because the API currently accepts bare domains that silently never match.
- A skip path that is honest about what skipping costs.
- `docs/STATUS.md`: the public state pointer (see the last section).

**Out (deferred, recorded in `STATUS.md`):**
- The "propose" step, which suggests senders from fetched mail.
- Header matching (OI38).
- The T4→T3 default change.
- Group edits in Settings not raising the "rules changed" staleness hint (new open item; see Phase 0 finding 3).
- A `THRESHER_HOME` isolation mechanism (see Phase 0 finding 4). Phase 3 uses a separate macOS user instead.
- The tutorial-flag race (known limit; see Phase 1). Recovery: "Reclassify all mail" in Settings › Classification rules.

---

## Phase 0 — Investigation (done)

Findings this revision depends on:

1. **The first fetch starts within about 30 s of Connect,** while onboarding is still on later steps. Mail is classified once, at ingest. An ask step placed after Connect would race the fetch.
2. **No add-one-pattern API exists.**
   - `PUT /sender-groups/<id>` replaces a group's whole pattern set.
   - `_validate_sender_group` requires a non-empty list of strings but never checks their format.
   - Settings group editing already uses this API.
3. **Reclassify exists, but only on demand** (`POST /messages/reclassify-all` → `reclassify_all`). Group edits never trigger it, and they don't raise the staleness hint, because `sender_groups` has no `updated_at`.
4. **No isolation mechanism exists.**
   - The database, logs, Keychain service, UserDefaults and API port are all fixed.
   - A separate macOS user isolates everything except port 8765.
5. **Pattern forms** (`ClassificationEngine._pattern_matches`):
   - A full address matches case-insensitively.
   - `@domain` matches exactly on the part after the `@`, with no lookalikes and no subdomains.
   - `*` globs are full-match regexes. An unanchored glob such as `*acme.example` behaves like a substring match.
   - **A bare domain such as `acme.example` is accepted by the API and never matches anything.**

---

## Phase 1 — Backend

### Decisions (record each in `DECISIONS.md` with its rationale)

1. **The step goes before Connect.** The order becomes Welcome → Ask → Connect → Preferences → Notifications → Done.
   - Groups are global, not per-account, so they can be set before any account exists.
   - On a fresh install, membership is then in place before the first fetch, so mail is tiered correctly at ingest with no race against the poller.
   - "Connect later" users also see the step, because it comes before the branch that skips to Done.
2. **When the tutorial has been seen, onboarding starts at Ask, not Connect.**
   - Today `OnboardingView.swift:75–77` jumps straight to Connect. A returning user would never reach the step, and decision 5 would cover nobody.
   - Ask prefills each input with the group's current members, excluding `boss@example.com`.
   - If a prefilled member fails validation, the whole request is rejected and the error names that entry. Removing the entry unblocks saving.
3. **Back into Ask is disabled once an account has been connected in this onboarding run.**
   - Why: a poll pass builds its engine once. Connecting starts a fetch within about 30 s, and membership edits made while that pass runs don't reach mail it is already ingesting, even after a reclassify.
4. **A dedicated endpoint, `POST /onboarding/people`, replaces "reuse `PUT /sender-groups/<id>`".**
   - Body: `{"leadership": [...], "family": [...]}`.
   - It normalizes and validates every entry, then **replaces** each group with the submitted set, dropping `boss@example.com`. Both groups are written in one transaction, and the endpoint reclassifies if any messages are stored.
   - Replace, not merge, because Ask shows the current members (decision 2). Under merge, removing a prefilled member would silently do nothing.
   - If any entry fails validation, nothing is written, and the error names the entry.
   - An empty request writes nothing. A group whose list is empty or absent is left unchanged, since an empty pattern set is invalid.
   - Why: the alternative was a client-side read-modify-write sequence. Its behaviour would arrive only with the UI, and Phase 1's tests would re-enact a script rather than test shipped code. One endpoint makes the sequence atomic and testable, and gives the UI a single call.
5. **Reclassify after a successful membership write, when stored messages exist.** This covers a returning user who disconnected and still has stored mail. On a fresh install the store is empty, so it does nothing. It runs inside the endpoint (decision 4).
6. **Bare domains are normalized, not rejected.** A pattern with no `@` and no `*` that is shaped like a domain is stored as `@domain`.
   - This happens in shared validation, so `POST /onboarding/people`, `POST /sender-groups` and `PUT /sender-groups/<id>` all get it. It also applies to the legacy `email_pattern` body field on `POST /sender-groups`.
   - Responses return the stored form, so the UI shows what was actually saved.
   - Precedent: `CLAUDE.md` already bans rule pairings that render as live and silently never fire. An inert bare domain is the same failure.
7. **Server-side format validation.** Each pattern must be one of:
   - a full address
   - `@domain`
   - a bare domain (normalized as in decision 6)
   - a glob: contains `*` only before the `@`, contains no whitespace, and contains exactly one `@`

   Anything else is rejected with a message naming the entry.
   - Keeping `*` out of the domain means a glob can never span domains. `*@*` and `*@*.org` fail format validation, and `*@example.com` and `john*@acme.example` still work. Subdomain globs go too, which is fine because subdomain support is out of scope.
   - Validation applies on write only. Existing stored patterns are unaffected until they are next saved.
8. **Whole-consumer-domain patterns are rejected in every group.**
   - Test: a pattern covers a whole domain *d* if, after normalization, the real matcher matches two different probe addresses at *d*.
   - This catches the bare, `@` and `*@` forms with one rule, instead of string-matching each form.
   - Full addresses at consumer domains (such as a family member's Gmail address) stay allowed.
   - List: `gmail.com`, `googlemail.com`, `outlook.com`, `hotmail.com`, `live.com`, `icloud.com`, `me.com`, `yahoo.com`, `aol.com`, `proton.me`, `protonmail.com`.
   - Anyone who really wants a whole consumer domain can still write a `sender_domain` rule.

### Known limit: the tutorial-flag race

Onboarding also runs when an account is connected but the tutorial flag is unset (for example after the flag was deleted). In that case the poller is already running while Ask saves, so mail in a pass that's already under way keeps the old groups, as in decision 3. This is not handled. Recovery: "Reclassify all mail" in Settings › Classification rules. Listed as an open item in `STATUS.md`.

### Known limit: the Tier 1 copy assumes the shipped configuration

The Ask step says mail from these people "always lands in Tier 1", and that until someone is added "nothing reaches Tier 1". Both are true for the shipped rule set: a rule can only make a tier more urgent, the group floor is applied after every rule, and both groups ship with a floor of Tier 1. They can be false for a user who raised a group's tier floor in Settings › Sender groups, or added their own Tier 1 rule in Settings › Classification rules. The step does not check either. Listed as an open item in `STATUS.md`.

### Implementation

- `POST /onboarding/people` as in decision 4. Group membership is read from `sender_group_patterns`, falling back to `email_pattern` for a group with no pattern rows, the same way the engine reads it.
- Update the Settings group editor help text (`SenderGroupEditorView.swift:109`) to say a bare domain is accepted and stored as `@domain`.
- **Existing inert patterns:** provide a count-only command the maintainer runs against their own database. It prints how many stored group patterns are bare (inert today) and how many would be rejected by decisions 7–8, with domain-side globs (a `*` after the `@`) counted separately. It counts `sender_group_patterns` rows, plus `email_pattern` for groups with no pattern rows, since the engine falls back to that column. It must print no pattern text. This phase does no migration; the counts decide whether one is needed.
  - **Answered 2026-10-04: no migration needed.** The maintainer's database, the only one that predates the validation change, has 9 group patterns: 0 rejected, 0 inert. Counts only; no pattern text was recorded.
- **Report for Phase 3 safety:** does Thresher write anything back to the mail server (flags, moves, deletes)? Cite the code paths. Read-only check.

### Tests (house rule: every guard gets a self-test that proves it can fail)

All tests target `POST /onboarding/people` unless stated otherwise.

- Seed `seed.example.sql` **explicitly**, not via `init_db(seed=True)`.
- **Address positive:**
  - Add one `leadership` address. A corpus containing mail from it gives T1 > 0.
  - Self-test: the same corpus with no address added gives T1 == 0.
- **Pattern rows:** assert non-zero rows in `sender_group_patterns` after the write. Do not assert only that classification works, since the fallback can satisfy that while the groups are inert.
- **Placeholder:**
  - After a write, `boss@example.com` is gone from `leadership`.
  - Replace: a pre-existing member that is submitted again remains, and one left out of the submitted set is removed.
  - An empty request writes nothing: both groups and their pattern rows are unchanged.
- **Normalization:**
  - `acme.example` is stored as `@acme.example`, and `someone@acme.example` reaches T1.
  - `someone@notacme.example` and `someone@mail.acme.example` stay out of T1.
  - The legacy `email_pattern` field on `POST /sender-groups` is normalized the same way.
  - Self-test: with normalization disabled, the bare-domain positive test goes red.
- **Format validation:** an entry that is no recognized form (e.g. `not a pattern`, or a glob with two `@`) is rejected, and the error names it.
- **Consumer-domain guard:**
  - `gmail.com`, `@gmail.com` and `*@gmail.com` are rejected with the consumer-domain message. `*gmail.com` is rejected too: under decision 7 it has no `@`, so it fails format validation.
  - `someone@gmail.com` is accepted.
  - Self-test: remove `gmail.com` from the list and confirm the rejection tests go red.
- **Domain-side globs:**
  - `*@*` and `*@*.org` fail format validation.
  - Self-test: allow `*` after the `@` and confirm the `*@*.org` test goes red.
- **Atomicity:** a request containing one invalid entry writes nothing to either group, and the error names the entry.
- **Reclassify:**
  - A message stored *before* the request is in T1 *after* it.
  - Self-test: the same request with the endpoint's reclassify step disabled leaves it out of T1.

**Gate:** the maintainer reviews the diff at the commit seam.

---

## Phase 2 — UI

- **Placement:** after Welcome, before Connect. When the tutorial has been seen, onboarding starts here (decision 2).
- **Prefill:** each input starts with the group's current members, excluding `boss@example.com`. If a prefilled member is rejected on save, show the error inline next to it. Removing the entry unblocks saving.
- **Emptied group:** if an input that was prefilled with members is emptied, show inline text saying this step can't remove everyone and to use Settings instead. Saving with that group empty leaves it unchanged (decision 4).
- **Back:** disabled into Ask once an account has been connected in this onboarding run (decision 3).
- **Save:** one call to `POST /onboarding/people` (decision 4). Skip sends nothing.
- **The step:** two inputs.
  - "People whose mail you never want to miss at work" writes to `leadership`.
  - "Family" writes to `family`.
  - Each takes one or more entries. Each entry is a full address or a domain.
- **Helper text** under the work input: you can enter a whole domain (for example `example.com`) to cover everyone there.
- **Feedback:** show server rejections inline, next to the entry that caused them. After saving, show entries in their stored form (`@example.com`), so the user sees what will actually match.
- **Skip:** allowed. The skip confirmation says plainly that Tier 1 stays empty until people are added, and where to add them later in Settings. Per `CLAUDE.md`, no copy may imply a fresh install produces a tiered list.
- **Keyboard path:** the step must be completable with Tab, Return, and Escape alone.
- Copy is a draft for the maintainer to react to on screen, not to approve in text.

**Known test limits** (from `CLAUDE.md`):
- Synthesized clicks don't reach SwiftUI `List` rows.
- Accessibility identifiers don't surface under `NSHostingView`.

A view-model test proves the state is right. It does not prove the step is reachable or legible. That's what Phase 3 is for.

**Gate:** the maintainer reviews the diff.

---

## Phase 3 — Human verification (the maintainer runs this, not Claude Code)

Only what no test can reach: that clicks and the keyboard get to the step, that real mail lands in Tier 1, and that the words read right on screen. Normalization, the `gmail.com` rule, prefill, and all six states rendering legibly in light and dark are covered by the suites.

`<repo>` is the checkout. The test user can read it in place.

**Daily account, before switching users:**
1. Quit the daily app. Both instances use port 8765, and a running daily app would change the database fingerprinted next.
2. `scripts/db-fingerprint.py > ~/thresher-fingerprint.txt`
3. `scripts/build.sh` → `build/Thresher.app`. The bundle carries only `seed.example.sql`.

**Test user:**
1. `bash <repo>/scripts/phase3-reset-test-user.sh`. It refuses in the daily account and while any Thresher is running.
2. `open <repo>/build/Thresher.app`. ☐ Clicking through Welcome with the mouse reaches the Ask step.
3. From here on, use the keyboard only (Tab, Return, Escape). Enter `gmail.com` under Family and save. ☐ The refusal reads right, next to the entry.
4. Remove it, then enter one address you receive mail from. Save, then connect your account. This is safe: Thresher only ever sets or clears `\Seen`, and only behind an opt-in the app never sends. ☐ The step can be finished without the mouse.
5. ☐ After the first fetch (about 30 s), mail from that address shows in Tier 1.
6. Quit the app, run `bash <repo>/scripts/phase3-reset-test-user.sh` again, and switch macOS to Dark. Relaunch the app. ☐ The Ask step reads clearly in dark mode.
7. Choose Skip. ☐ The skip warning reads right. Confirm it and connect your account. ☐ After the first fetch, the main list loads with nothing in Tier 1.
8. Quit the app and log out of the test user.

**Daily account, before relaunching the daily app:**
1. `scripts/db-fingerprint.py | diff - ~/thresher-fingerprint.txt && echo unchanged`. ☐ It prints `unchanged`. If it doesn't, stop, and don't relaunch the daily app.

**Push gate:** held until every ☐ passes.

---

## Also in this workorder: `docs/STATUS.md`

Create the public state pointer:
- open items (OI list)
- current status
- what's next

Rule: **no real addresses, names, or subjects ever.** Usage findings get abstracted before they land here. Claude Code may update this file in the same commit that closes an item, and that change gets reviewed like any other diff.

## Completion criteria

- All Phase 1 tests are green, including every self-test.
- Phase 3 passes on a separate macOS user.
- `STATUS.md` exists and lists the deferred items above.
- Decisions 1–8 and the tutorial-flag known limit are recorded in `DECISIONS.md` with their rationale.
- The inert-pattern counts from the maintainer's database are reported (counts only), and the migration question is answered. **Done 2026-10-04:** 9 patterns, 0 rejected, 0 inert; no migration needed.
