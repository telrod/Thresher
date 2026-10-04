# Workorder — Onboarding "ask" step (minimal)

**Status:** Draft for the maintainer's review
**Goal:** A stranger who installs Thresher and finishes onboarding can get Tier 1 mail. Today they cannot.

---

## Why

Confirmed in `CLAUDE.md`:

- Both Tier 1 rules match sender-group membership (`leadership`, `family`).
- Those groups ship with placeholder members that match nobody: `boss@example.com` in one, nothing in the other.
- On a fresh install, measured on the 150-message demo corpus, the split across T1–T5 is **0 / 15 / 21 / 70 / 44**.

So a stranger's first experience is a list with no Tier 1, and focus mode, which alerts on Tier 1 only, stays silent. That is the first impression the posts would drive people into.

## Scope

**In:**
- One onboarding step that asks for the people whose mail matters most and writes them into the `leadership` and `family` groups.
- It replaces the placeholder `boss@example.com`.
- A skip path that is honest about what skipping costs.
- `docs/STATUS.md`: the public state pointer (see the last section).

**Out (deferred):**
- The "propose" step, which suggests senders from fetched mail.
- Header matching (OI38).
- The T4→T3 default change.
- Any rule editing beyond group membership.

---

## Phase 0 — Investigation (read-only, no commits)

Report each item with the code path cited. Report no sender addresses or subjects.

1. **Onboarding flow order.** List the current steps in order. Mark where account connection happens and where the first fetch starts and finishes relative to the other steps.
2. **Group membership write path.** Find the existing API that adds a pattern to `sender_group_patterns`, if one exists. Does Settings already offer group editing, and does it go through that API?
3. **Reclassify path.** Is there one? When group membership changes, do already-stored messages get re-tiered, or only new mail?
4. **Isolated test install.** How can the app run against a separate data directory, so a fresh-install onboarding test doesn't touch the maintainer's daily-driver database and local `seed.sql`? If no mechanism exists, say so and propose the smallest one. Do not build it yet.
5. **Pattern format.** Do group patterns accept full addresses only, or also domains or wildcards? What does the matcher do with each? Specifically: does a domain pattern match by exact equality on the part after the `@`, or by substring? A substring match would let `acme.example` also match `notacme.example`.

**Gate:** The maintainer reviews the report. Phases 1–2 below are the intended shape and get revised against what Phase 0 finds.

---

## Phase 1 — Backend

- If no group-membership write API exists, add one. Reuse the existing one if it does.
- **Placeholder replacement:** when the user supplies at least one real address for `leadership`, remove `boss@example.com`. If the user skips, leave it in place. It matches nobody either way, and removing it on skip would change shipped data for no benefit.
- **Reclassify:** if Phase 0 shows the first fetch can finish before this step completes, already-stored messages must be re-tiered after membership is saved. Otherwise the user enters their people and still sees zero Tier 1. If the step always runs before the first fetch, there's no reclassify requirement. Record which case applies, with the reason, as a D-series decision.
- If the isolated-install mechanism from Phase 0 item 4 is approved, build it here.
- **Domain entries are accepted** (decided by the maintainer, 2026-10-04). Each entry is either a full address or a bare domain such as `acme.example`. If Phase 0 shows group patterns can't hold domains, add that support here.
  - A domain matches **exactly** on the part after the `@`. `acme.example` does not match `notacme.example`, and does not match subdomains such as `mail.acme.example`. Subdomain support is out of scope.
  - **Reject shared consumer mail domains** such as `gmail.com`, `outlook.com`, `icloud.com`, and `yahoo.com`. Entering one would put a large share of all mail in Tier 1. Keep a short, explicit list, and show a message telling the user to enter the full address instead.
  - Record the domain-matching rule and the consumer-domain list as a D-series decision.

### Tests (house rule: every guard gets a self-test that proves it can fail)

- Seed `seed.example.sql` **explicitly**, not via `init_db(seed=True)`, which prefers a local `seed.sql` when one exists.
- **Positive:** add one `leadership` address through the API, classify a corpus containing mail from that address, and assert T1 > 0.
- **Self-test:** the same corpus with no address added must give T1 == 0. If it doesn't, the positive test proves nothing.
- Assert non-zero **pattern rows** in `sender_group_patterns` after the write. Do not assert only that classification works, since `CLAUDE.md` documents a fallback that can satisfy that while the groups are inert.
- If reclassify is in scope: assert that a message stored *before* the membership write moves to T1 *after* it.
- **Domain positive:** add `acme.example`, and mail from `someone@acme.example` reaches T1.
- **Domain self-tests** (each must stay out of T1): `someone@notacme.example`, and `someone@mail.acme.example`. If either reaches T1, the domain match is substring-based and the positive test proves nothing.
- **Consumer-domain guard:** the API rejects `gmail.com`. Self-test: temporarily remove `gmail.com` from the list and confirm the rejection test goes red.

**Gate:** The maintainer reviews the diff at the commit seam.

---

## Phase 2 — UI

- **The step:** two short inputs. "People whose mail you never want to miss at work" writes to `leadership` (wording approved by the maintainer). "Family" writes to `family`. Each takes one or more entries, and each entry is a full address or a domain. Validate format plainly, and show the consumer-domain rejection message inline, next to the entry that caused it.
- Helper text under the work input: you can enter a whole domain (for example `example.com`) to cover everyone there.
- **Skip:** allowed. The skip confirmation says plainly that Tier 1 stays empty until people are added, and where to add them later in Settings. Per `CLAUDE.md`, no copy may imply a fresh install produces a tiered list.
- **Keyboard path:** the step must be completable with Tab, Return, and Escape alone.
- Copy is a draft for the maintainer to react to on screen, not to approve in text.

**Known test limits** (from `CLAUDE.md`):
- Synthesized clicks don't reach SwiftUI `List` rows.
- Accessibility identifiers don't surface under `NSHostingView`.

A view-model test proves the state is right. It does not prove the step is reachable or legible. That's what Phase 3 is for.

**Gate:** The maintainer reviews the diff.

---

## Phase 3 — Human verification (The maintainer runs this, not Claude Code)

On the isolated install from Phase 0 item 4, never on the daily-driver data:

1. Fresh onboarding, entering one real address you receive mail from. After the first fetch, mail from that address shows as Tier 1.
2. Fresh onboarding, skipping the step. The skip message appears, the main list loads, and Tier 1 is empty, as expected.
3. The keyboard-only pass through the step.
3a. Enter your work domain, and confirm mail from a colleague you didn't list individually reaches Tier 1. Enter `gmail.com`, and confirm it's refused with a readable message.
4. Confirm the daily-driver database is unchanged.

**Push gate:** held until all four pass.

---

## Also in this workorder: `docs/STATUS.md`

Create the public state pointer:
- open items (OI list)
- current status
- what's next

Rule: **no real addresses, names, or subjects ever.** Usage findings get abstracted before they land here. Claude Code may update this file in the same commit that closes an item, and that change gets reviewed like any other diff.

## Completion criteria

- All of Phase 1's tests are green, including the self-test.
- Phase 3 passes on an isolated install.
- `STATUS.md` exists and lists the deferred items: propose step, OI38, T3 default.
- The reclassify decision is recorded in `DECISIONS.md` with its rationale.
