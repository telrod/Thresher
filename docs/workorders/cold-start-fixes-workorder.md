# Work Order — Cold-Start Fixes and a Usable Default Seed

> **Origin:** planning session 2026-09-07, from the cold-start run. Four items:
> the three defects that run found, plus the finding underneath them — a fresh
> install classifies everything T4 and alerts on nothing.
>
> **Scope decision made by the author:** ship **sensible defaults** now. The other two
> onboarding directions discussed — *ask* (a first-run step collecting two or
> three always-reach-me addresses) and *propose* (suggesting rules from a sample
> of real mail) — are **deliberately deferred to become the first feature work in
> Thresher**, in the open, rather than the closing chore of the private repo. Do
> not build them here.

---

## §0 — Preconditions

1. Working tree clean, level with origin.
2. The launchd agents are uninstalled and **stay uninstalled** — the author no longer
   needs a running app before cutover. Confirm with `launchagent.sh status`.
3. The live database is **not protected**. Wipe, re-seed and re-onboard freely;
   the archive is verified at
   `~/Documents/thresher-archive/thresher.pre-cold-start-wipe.*.db`.
4. **Read `docs/workorders/cold-start-defects.md` first.** This order states a
   preferred direction for each defect. Where it disagrees with the options
   already documented there, **say so and stop** rather than silently following
   either one.

---

## §1 — Fences

- No renaming. No migration work. No PII scrubbing in this repo.
- **Do not build *ask* or *propose*.** No onboarding step that collects
  addresses; no inference of rules from the user's mail. Deferred on purpose.
- Kill processes by PID or with a pattern that cannot match a production
  process.
- ⚠️ **Do not poll a real mailbox to test.** Two accidental backfills happened
  last session. Use `--once`, a scratch database, or synthetic fixtures.
  `THRESHER_KEYCHAIN_SERVICE` **silently failed to take effect** on one
  attempt — treat that override as unreliable until proven otherwise, and record
  it with OI37: an override that fails open against a real account is its own
  hazard.
- Do not edit `project-log.md`; report corrections.

---

## §2 — Part A: the poller is permanently abandoned on first run

### The defect

Every component behaves as designed; the **composition** is broken.

```
09:58:30  app launches — Keychain EMPTY (cold start)
09:58:30  supervisor starts poller → no accounts → exit 0
+30s/+60s/+90s  three restarts, same result
+120s     gaveUp.insert(pollerID) — PERMANENTLY excluded
~10:01    user finishes onboarding, account connected
          supervisor already gave up. Never retries.
```

`main.py` returning 0 for "nothing to do is not a crash" is correct.
`maxRestarts = 3` so a broken backend cannot spin the CPU is correct. But
`restartAnythingThatDied()` cannot distinguish **exit 0 because there was nothing
to do** from **exit 0 because the work finished**, so it spends its entire
restart budget on a condition guaranteed to resolve — roughly ninety seconds
before the user finishes typing their password.

**It aligns exactly with first run**, because that is the only moment the
Keychain is empty at launch. It never reproduced on the author's alpha, where
credentials always predated the app.

### Preferred direction

**Make the not-yet-configured exit distinguishable, and treat it as *wait*
rather than *died*.** A distinct exit code from `main.py` that the supervisor
reads as "no work available yet, keep watching, do not spend a restart."

Report on, but do not implement without saying so:

- Whether account connection should additionally **notify the supervisor
  directly**, since that is the event which makes the poller viable. Belt and
  braces, or redundant complexity — your call to argue, the author's to settle.
- Whether `gaveUp` should ever be permanent for the poller at all, given the app
  now owns the backend's lifetime and the user has no way to reset it except
  quitting the app.

### Also required

`start()` currently **returns success having started one of two processes.**
That is its own defect and the same shape as several found this week — a
component reporting success while doing half its job. Fix it or report why not.

### Verification

⚠️ The obvious test is vacuous. Launching with credentials already present never
exercises this path. **The test must begin with an empty Keychain**, launch,
wait past the full restart budget, then connect an account, and assert the poller
is running afterwards. Verify it **red** against current code first.

Use a scratch Keychain service if you can prove the override works; otherwise say
so and test another way. Do not connect a real mailbox to prove this.

---

## §3 — Part B: the app-managed backend writes no logs anywhere

`launch()` sets both `standardOutput` and `standardError` to
`FileHandle.nullDevice`. The comment's reasoning is sound — an undrained pipe
blocks the child — but the fix chosen **discards the output instead of draining
it**. Every failure in the shipped configuration is invisible, to the author and to any
user. Part A was diagnosable only because there was a checkout to reproduce from;
a beta user would have nothing to send.

**Required:** drain the pipes and write to files under the app's own support
directory.

**Report as decisions, do not choose:** where the files live, how they rotate or
cap, and — the part that matters most for a source-only release — **how a user
finds them without a terminal.** A "Reveal logs in Finder" control is the obvious
candidate; there may be better.

---

## §4 — Part C: the empty-state banner

> "The mailbox has never been polled. Start the backend poller to begin
> retrieving mail."

Unactionable for someone with no terminal and no concept of a poller, and under
D67 the app is supposed to start it — so it instructs the user to do something
they should never need to do and cannot do from the UI. It is also **misleading**:
the poller ran four times and exited.

Rewrite for a person with no terminal. Once Part A lands, the honest message for
a genuinely fresh install is closer to *"Waiting for the first mail check"* than
to an error.

---

## §5 — Part D: a seed that classifies something

### The finding

The cold start ingested 15 real messages and classified **all 15 as T4/unknown**.
The seeded rules target `example.com` and groups that ship **memberless**, so
nothing could match and everything fell to the engine default. Combined with
`operating_mode = focus` (T1 only), a stranger gets an untiered list that alerts
them to nothing.

The app works and is useless. That is the real headline of the cold-start run.

### Required

1. **First, report what the rule engine can actually express.** This order
   specifies *intent*; do not invent capability. In particular, say whether rules
   can match on the **`List-Unsubscribe` header**, which is the single most
   reliable bulk-mail signal available and far better than guessing at domains.
   If the classifier does not see headers, say so — that changes the design.

2. **Seed rules that fire on a stranger's real mail**, expressed with whatever
   the engine supports:
   - **T5** — bulk and promotional: `no-reply` / `noreply` senders, list mail,
     anything carrying an unsubscribe affordance
   - **T2** — time-sensitive machine mail: password resets, security alerts,
     verification codes, calendar invitations
   - **T3** — the fallback for ordinary direct mail

3. **Reconsider the engine default of T4.** Unmatched mail from a human being is
   not archive-tier. Propose T3 as the fallback and argue it; do not change it
   silently.

4. **Recommend the seeded `operating_mode`.** Focus alerts on T1 only, and a
   fresh install has no T1 rules, so a new user gets **silence**. Catch-up plus
   the T2 rules above would give a first-run user genuine alerts on day one.
   Report a recommendation with reasoning; the author decides.

5. **Keep the groups memberless.** *Ask* and *propose* will populate them in
   Thresher. Do not invent members, and do not guess at the user's contacts.

6. **These rules ship publicly.** They must contain no real address, no real
   domain of the author's, and nothing inferred from his mailbox. Generic patterns only.

### Verification

Against a **scratch database** with synthetic fixtures spanning the categories
above: assert the seeded rules place messages across at least three distinct
tiers, and that a fresh install produces a **visibly tiered** list rather than a
flat one. ⚠️ Assert tier *distribution*, not merely that classification ran — a
seed where everything lands in one tier passes a "classification works" check,
which is exactly how this shipped.

---

## §6 — Closing

- Commit the three defect write-ups first, before any fix, while the diagnosis
  is fresh.
- Committed run summary is the artifact.
- Per part: what changed, what was verified **by running**, what was flagged.
- Every new guard states in its comment what it was verified red against.
- Push at the end; report count and range.
