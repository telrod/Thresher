# How this app behaves, and why

This file documents **deliberate behavior choices** — the things the app does on
purpose that might otherwise look like bugs, omissions, or surprises. If something
here isn't what you'd want, that's a legitimate disagreement rather than a defect
report: open an enhancement request, or change it yourself.

For features that were considered and *not built*, see `IDEAS.md`.

**Adding an entry:** record what the app does, why it does that, and what it means
for the user in practice. If a choice has a downside, write the downside down. An
entry that only lists benefits isn't documentation, it's marketing, and it will
mislead the next person who has to decide whether to change it.

---

## Triage is local — your mailbox is not modified

**What happens:** When you mark a message as Done or otherwise triage it, that
change is recorded in this app's own database. **By default your mailbox on the
mail server is not touched** — the message stays unread, unarchived, and exactly
where it was. Nothing is ever deleted or moved, under any setting.

**Why:** This app is a lens on your mail, not a replacement client. Keeping
triage local means it cannot damage your real mailbox, and you can stop using it
at any time and lose nothing but the triage state.

**The one exception, stated plainly:** there *is* an opt-in mark-as-read
write-back. It is off by default, and switching it on is not enough on its own —
see the entry above on the two separate yeses. It only ever sets the "read" flag;
it never deletes, moves, or relabels anything. If you have never enabled it, this
app has never modified your mailbox.

**What this means for you:** unless you opted in, triaging here and triaging in
your regular mail client are separate activities — clear your view here and your
inbox elsewhere looks unchanged.

---

## Changing your mailbox takes two separate yeses, and is always recorded

**What happens:** Marking the source message read on your mail server requires
**both** that write-back is enabled for that account **and** that the individual
request asks for it. Enabling the account setting alone does not cause anything
to be written. Every attempt — successful or not — is recorded in a local log.

**Why:** A setting you switched on once is consent to a *policy*, not to every
future act. This app learned that concretely: write-back was enabled
deliberately for one account, and months later an *undo* operation silently
marked a real message read on the server. Nobody asked for that; the person was
reversing something. Requiring the individual action to opt in as well means a
standing preference can't quietly authorise things you didn't intend.

The log exists for a related reason. Write-back is the only thing this app does
that reaches outside itself, and it used to leave no trace — so "how many of my
messages has this modified?" had no answer at all. Now it does.

**What this means for you:** Bulk actions and single-message triage behave the
same way here, which they did not before. The downside is that turning the
setting on is no longer sufficient by itself — if you want write-back to happen
routinely, the client has to ask for it every time, by design.

---

## Marking a message Done hides it — it never deletes anything

**What happens:** Done removes a message from your working view. The message
itself is retained in full and remains available in the All view and in search.

**Why:** Triage decisions are made quickly and in volume, so they need to be
non-destructive. Nothing you do in normal use of this app removes a message.

**What this means for you:** A bulk action that catches more than you intended is
recoverable — the messages are hidden, not gone. Search still finds them.

---

## Bulk actions never write back to the mail server

**What happens:** Bulk triage is local-only, without exception. The API refuses a
bulk request that asks for server-side changes.

**Why:** Applying changes to the server costs roughly three network round-trips
per message. A realistic bulk operation touches thousands of messages, and a
failure partway through leaves your real mailbox in a half-modified state with no
record of where it stopped. A local bulk action is a single database statement
that either fully succeeds or fully fails.

**What this means for you:** Clearing thousands of stale messages here is fast and
safe, and changes nothing in Gmail or wherever your mail actually lives.

---

## A single bulk action is capped at 5,000 messages

**What happens:** Bulk operations larger than 5,000 messages are rejected. Larger
cleanups are done in successive passes.

**Why:** Not performance — a bulk action is one SQL statement and the size barely
matters. The cap exists to bound the cost of a mistake. A filter that matches far
more than you expected is caught by the confirmation, which names the count; the
cap is the backstop for when the confirmation is clicked through.

---

## Every bulk action is recorded

**What happens:** Each executed bulk operation is written to an append-only log
recording the filter used, the time bound, the timestamp, and how many messages
were affected.

**Why:** So that "what did that operation actually do?" has an answer. This
information exists only at the moment of execution and cannot be reconstructed
afterwards.

**What this means for you:** There is a durable record of every bulk change. Note
that this is a record, not an undo — see `IDEAS.md`.

---

## Mail is fetched in the background, whether or not the app is open

**What happens:** The backend runs as two background processes, and **the app
starts and stops them** (D67). They come up when you launch the app and shut
down when you quit it; while the app runs, a supervisor restarts either one
within about 30 seconds if it dies. Mail is fetched whether or not the *window*
is open — closing the window is not quitting.

**The cost, stated plainly: quit the app and nothing fetches mail.** Urgent mail
waits until you next open it. This was a deliberate choice over always-on
polling: `spec.md` promises periodic polling, never polling while the app is
closed, and running two processes at login that talk to your mail server forever
is a bigger imposition than the app's promise requires. The Tier 1 invariant
governs *operating modes*, not process lifetime.

**Always-on is still available and is what alpha uses:**
`scripts/launchagent.sh install` hands both processes to macOS launchd, which
starts them at login and restarts a crash within about 40 seconds regardless of
whether the app is running. The two mechanisms are **mutually exclusive by
construction** — the app's supervisor detects launchd ownership and stands down,
so they cannot fight over port 8765.

**Why:** The app's central promise is that a genuinely urgent message surfaces.
That cannot be honoured by a poller which only runs while a window happens to be
open — you would find out about the 7am escalation when you next opened the app,
which is exactly the failure this tool exists to prevent. Background polling also
means the app opens on current mail rather than making you wait for a fetch.

The supervision specifically exists because of a real outage: on 2026-08-13 the
poller crashed on a transient network timeout and **nothing fetched mail for 13
days**. 141 messages were waiting on the server. The underlying crash was fixed,
but any crash is permanent if nothing restarts the process — so the supervisor,
not the bug fix, is what makes ingestion reliable.

**If you chose always-on (launchd), two warts remain.** Two processes run at
login and talk to your mail server on a schedule you did not set per-run, and
**dragging the app to the Trash does NOT stop them** — they keep polling. Remove
them first:

```sh
scripts/launchagent.sh uninstall
```

Settings → Email accounts also has a **Stop background polling** control that
removes the agents, so this is no longer terminal-only. On the app-lifetime
default, quitting the app is enough and none of this applies.

**What this means for you:** mail keeps arriving while the app is closed, and you
can verify it is working — `scripts/launchagent.sh status` reports both agents
and per-account ingestion health. Inside the app, a mailbox that stops polling
shows a banner in the message list, a `!` on the dock icon, and a status line in
Settings → Email accounts. Silence is treated as broken: the check is whether a
poll happened recently, not whether an error was recorded, because a process that
dies writes no error at all.

---

## Notifications are reserved for genuinely urgent mail

**What happens:** Only the top urgency tiers produce a notification. Lower-tier
mail is collected and surfaced in the app rather than interrupting you.

**Why:** A notification that fires for everything is a notification you learn to
ignore, at which point it's worse than none — the one message that mattered gets
dismissed with the rest.

---

## A new install starts in Catch-up, not Focus

**What happens:** A fresh install alerts on **Tier 1 and Tier 2** mail. You can
switch to Focus — Tier 1 only — once the app knows who matters to you.

**Why:** This was changed after running a genuine first install against a real
mailbox and watching it do **nothing**. Both Tier 1 rules match *sender groups*,
and a fresh install ships those groups **empty**, so in Focus mode there was no
rule that could fire — a new user got guaranteed silence from an app whose entire
promise is surfacing urgent mail. Catch-up reaches the seeded Tier 2 rules
(verification codes, security alerts, password resets, calendar invitations),
which fire on subject text and therefore work on day one. Focus becomes the right
default once your sender groups are populated and Tier 1 means something.

**What this means for you:** setup now starts by asking **who matters most**,
and the people you name go into those groups. If you skip that step, **nothing
can reach Tier 1** until you add people in Settings › Sender groups. That is a
property of an unconfigured install, not a fault.

---

## The first fetch tells you it is working, and tells you when it is not

**What happens:** On a first run the message list shows that a fetch is in
progress rather than an empty list. If the fetch fails, it says so — it does not
quietly settle into looking like an empty mailbox.

**Why:** "Still working" and "finished, found nothing" and "broken" are three
different states that all render as a blank list. An empty list after a failure
is the most misleading of the three, because it looks like a successful result.

---

## You can see the backend's logs from inside the app

**What happens:** Settings has a **Reveal Logs in Finder** control that opens the
directory the backend writes to.

**Why:** When mail is not arriving, the logs are the evidence, and requiring a
terminal to reach them puts the answer out of reach of the person most affected.

---

## Setting up an account is silent — the initial retrieval sends no notifications

**What happens:** When you first connect an account, the mail retrieved during
that initial backfill produces **no notifications at all**, at any urgency tier.
Once setup is done, notifications work normally: an urgent message arriving on an
ordinary check still alerts you.

**Why:** Connecting an account is the first thing you do, and it can retrieve
thousands of messages at once. Notifying per message would end setup in a burst
of hundreds of banners — which trains you to dismiss them, permanently, before
you have used the app once.

**What this means for you:** Nothing is hidden. Every message retrieved during
setup is stored, classified, and ranked; the urgent ones are at the top of your
list when you first open it. You simply read them rather than being interrupted
by them one at a time. The downside is real and worth stating: **if something
genuinely urgent arrives in the seconds while your account is first being set
up, it will not produce a banner.** It will be in the list, at the top.

---

## You choose how far back to retrieve mail, and the choice is one-way

**What happens:** When you connect an account, you pick a retrieval window — how
far back mail should be brought into the app. Anything older is never retrieved.
**This choice cannot be widened later.**

**Why:** Most mailboxes contain years of mail that is no longer actionable.
Retrieving all of it makes the app slower, noisier, and less useful at its actual
job, which is surfacing what still needs a response. Widening the window
afterwards means reconciling a new range against what's already stored without
duplicating anything or generating a flood of alerts for old mail — real work, for
a case most people encounter once.

**What this means for you:** Choose deliberately during setup. If you're unsure,
pick a wider window than you think you need — narrowing is always possible,
widening is not.

**Nothing is lost either way.** Mail outside the window is untouched on your mail
server and readable in any other client. This app simply never copies it.

**Disconnecting and re-adding the account does not recover older mail.** The
window only applies to the *initial* backfill — the first retrieval for an
account with nothing stored yet. Re-adding an account whose mail is already in
the app is not that: it resumes from where it left off and carries on from
there. The original window is not re-applied, and no new one takes effect. Mail
that was outside the window the first time stays outside it.

---

## The retrieval window applies to setup only, not to ongoing polling

**What happens:** The retrieval window governs the **initial backfill** when you
first connect an account. After that it stops filtering. If the app is closed for
two weeks, everything that arrived during those two weeks is retrieved when you
reopen it — regardless of the window you chose.

**Why:** These look like the same rule but they solve different problems. The
window exists so that connecting an account doesn't drag in years of mail that
stopped being actionable long ago. Mail that arrived while the app happened to be
closed is not that — it's recent, it's small in volume, and some of it may still
need a response. Skipping it would mean that closing the app for a week could
permanently hide an urgent message, which is the exact failure this app exists to
prevent. Because the window can't be widened later, such a gap would be
unrecoverable.

**What this means for you:** You can close the app, go on holiday, and reopen it
without losing anything. Older mail from the gap won't be treated as urgent —
sorting is by urgency first and recency second, so a nine-day-old important
message appears in your working view, ranked beneath today's mail rather than
competing with it.

