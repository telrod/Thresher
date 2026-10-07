# Status

The public state pointer for Thresher: what is open, where things stand, and
what comes next.

**Rule: no real addresses, names, or subjects, ever.** Findings from real use are
abstracted before they land here. This file is updated in the same commit that
closes an item, and that change is reviewed like any other diff.

## Current status

The onboarding Ask step is in progress
([workorder](workorders/onboarding-ask-step-workorder.md)). Goal: a stranger who
finishes onboarding can get Tier 1 mail. Today a fresh install cannot (see
`CLAUDE.md`, "A fresh install cannot produce a Tier 1").

| Phase | State |
| --- | --- |
| 0 — Investigation | Done |
| 1 — Backend: `POST /onboarding/people`, pattern normalization and validation (D78–D82) | Done |
| 2 — UI: the Ask step | Done |
| 3 — Human verification on a separate macOS user | Next |

## Open items

- **The "propose" step:** suggest senders from fetched mail. Deferred.
- **OI38 — header matching.** The rule engine cannot match on headers, so
  `List-Unsubscribe` is unreachable. Deferred.
- **The T4→T3 default change.** Deferred.
- **Group edits don't raise the staleness hint.** The "rules changed" hint
  counts only the `rules` table; `sender_groups` has no `updated_at`, so editing
  a group in Settings never tells the user that stored mail is out of date.
- **No isolated-install mechanism** (`THRESHER_HOME`). The database, logs,
  Keychain service, UserDefaults and API port are all fixed. Verification uses a
  separate macOS user instead.
- **The tutorial-flag race (known limit, D77).** Onboarding also runs when an
  account is connected but the tutorial flag is unset. The poller is then
  already running while Ask saves, so mail in a pass already under way keeps the
  old groups. Recovery: "Reclassify all mail" in Settings › Classification rules.
- **The Ask step's Tier 1 copy assumes the shipped configuration (known
  limit).** "Always lands in Tier 1" and "nothing reaches Tier 1" are true for
  the shipped rules and group floors. They can be false for a user who raised a
  group's tier floor or added their own Tier 1 rule in Settings.

## Resolved

- **Migration for existing group patterns: not needed** (2026-10-04). Validation
  applies on write only (D81). The only database that predates the change has
  9 group patterns: 0 rejected, 0 inert. Measured with
  `scripts/count_group_patterns.py`, which prints counts only.

## What's next

Phase 3 of the onboarding workorder: the maintainer checks by hand, on a
separate macOS user, what no test can reach — mouse and keyboard reach the Ask
step, real mail from an entered address lands in Tier 1 after a real fetch, the
refusal and skip messages read right on screen, and the step reads clearly in
dark mode. The daily database is fingerprinted before and after
(`scripts/db-fingerprint.py`). The push is held until every check passes.
