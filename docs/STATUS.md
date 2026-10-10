# Status

The public state pointer for Thresher: what is open, where things stand, and
what comes next.

**Rule: no real addresses, names, or subjects, ever.** Findings from real use are
abstracted before they land here. This file is updated in the same commit that
closes an item, and that change is reviewed like any other diff.

## Current status

The onboarding Ask step is done (2026-10-06,
[workorder](workorders/onboarding-ask-step-workorder.md)). A stranger who
finishes onboarding can now get Tier 1 mail by naming the people who matter
most. A fresh install that skips the step still cannot (see `CLAUDE.md`, "A
fresh install cannot produce a Tier 1").

| Phase | State |
| --- | --- |
| 0 — Investigation | Done |
| 1 — Backend: `POST /onboarding/people`, pattern normalization and validation (D78–D82) | Done |
| 2 — UI: the Ask step | Done |
| 3 — Human verification on a separate macOS user | Done 2026-10-06: all eight checks passed |

## Open items

- **The "propose" step:** suggest senders from fetched mail. Deferred.
- **OI38 — header matching** ([#1](../../../issues/1)). The rule engine cannot
  match on headers, so `List-Unsubscribe` is unreachable. Deferred.
- **Apple Silicon hands-on verification** ([#2](../../../issues/2)). CI builds
  the app and passes the backend suite on arm64 (run 37875153727). Nobody has
  used the app by hand on an Apple Silicon Mac yet.
- **"Try with sample data" mode** ([#3](../../../issues/3)). Evaluating
  Thresher still requires connecting a real mailbox. Design in `docs/IDEAS.md`
  §3.
- **Frontend suite in CI** ([#4](../../../issues/4)). CI runs the build and the
  backend suite only, because the frontend suite has not been shown to pass on a
  hosted runner.
- **The T4→T3 default change.** Deferred.
- **OI41 — the bundled backend depends on macOS's built-in Python.** The app
  runs its backend on `/usr/bin/python3` (3.9.6 on Sonoma, D68). Its age has
  already hidden one defect: `fromisoformat` rejected the app's `Z` timestamps,
  so native notification delivery never took over (D84). Apple may change or
  remove this interpreter. Not addressed yet.
- **OI42 — Settings opened right after a cold launch can say "Backend
  unreachable".** The ⌘, window is not behind the launch readiness gate. It
  relies on the client's retry of refused GETs, which spans ~450ms; the
  measured cold-start gap was ~490ms. Opened within about half a second of
  launch, Settings can show "Backend unreachable" and empty panes until reopened.
- **OI43 — when the supervisor gives up on the poller, the app does not say
  so.** After 3 failed restarts it stops relaunching the poller, and mail and
  alerts stop with it. The only record is a line in `supervisor.log`;
  `hasGivenUp(on:)` is not read by any view. The user sees a warning only when
  the account heartbeat goes stale: "hasn't checked for mail in …" in the list
  and the dock badge, about 11 minutes after the last poll at the default
  interval. It does not mention alerts. A poller that dies before its first poll
  instead shows "Waiting for the first mail check", which reads as normal,
  indefinitely. Separately, `BackendSupervisorTests` write their "gave up"
  lines into the real `supervisor.log`, so every frontend suite run adds two
  false entries, one "last exit 1" and one "last exit unknown" in the same
  second. The pair at 2026-10-10T18:12:13Z matches a test run to the second;
  every earlier pair in that log has the same signature.
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

**OI38 — header matching** ([#1](../../../issues/1)). Add a `header` field to the rule engine so rules can
match on headers, starting with `List-Unsubscribe`, the most reliable bulk-mail
signal and one the classifier cannot reach today.
