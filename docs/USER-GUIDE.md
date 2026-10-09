# Thresher — User Guide

Thresher routes every message to an **urgency tier** and a **category**, instead
of the read/unread binary. It runs entirely on your Mac: your mail is fetched
over IMAP, classified locally, and stored in a local SQLite database. Nothing is
sent anywhere else.

---

## 1. Build and install

Thresher is distributed as source. There is no prebuilt binary and nothing is
signed or notarized.

```
git clone <repo-url> thresher
cd thresher
scripts/build.sh
```

That produces `build/Thresher.app`. Move it where you want it and open it:

```
mv build/Thresher.app /Applications/
open /Applications/Thresher.app
```

**You do not need to install Python, Flask, or anything else.** The app bundles
its own backend and runs it on the `/usr/bin/python3` that ships with macOS.

**Requirements:** macOS 14 (Sonoma) or later, Xcode (to build), and a Gmail
account with an app password.

---

## 2. Connecting a mailbox

### 2.1 First: who matters most

After the welcome screen, and before it connects to anything, Thresher asks
**"Who matters most?"** — the people whose mail should always land in
**Tier 1**, at the top of your list. There are two lists:

- **Work** — people whose mail you never want to miss at work. These go into
  the `leadership` sender group.
- **Family** — these go into the `family` sender group.

Enter one address per row. You can also enter a whole domain (`example.com`),
which is stored as `@example.com` and matches everyone at that domain. When you
choose **Continue**, any entry that is not a usable address or domain is flagged
on its own row, and the step stays open until you fix or remove it.

If you go through this step again after mail has already been fetched, that mail
is not re-sorted automatically. To apply your changes to it, use
**Settings → Classification rules → Reclassify all mail**.

**This step is the only thing that lets a new install produce Tier 1 mail**
(see §4). You can choose **Skip**, and Thresher will ask you to confirm: without
anyone here, nothing reaches Tier 1 and Focus mode stays silent. You can add
people at any time later in **Settings → Sender groups**.

### 2.2 You do not need to turn IMAP on

Gmail no longer has an IMAP enable/disable setting. **IMAP is always on, and
there is no switch to find.** If you go looking for one in Gmail's settings you
will not find it, and nothing is wrong.

### 2.3 Getting a Gmail app password

Thresher signs in with an **app password**, not your normal Google password and
not OAuth.

1. Your Google account must have **2-Step Verification enabled**. App passwords
   are not available without it.
2. Go to your Google Account → **Security** → **App passwords**
   (<https://myaccount.google.com/apppasswords>).
3. Create one, naming it something you will recognise — "Thresher".
4. Google shows you **16 characters**. Copy them.

**Three things that catch people out:**

- **The 16 characters are shown once.** Close that dialog without copying and
  you cannot retrieve it — you have to delete the app password and make another.
- **Changing your Google account password revokes every app password**, for
  every app, not just this one. After a password change you will need a new one.
- **Google Advanced Protection disables app passwords entirely.** If your account
  is enrolled in Advanced Protection there is no way to make this work; Thresher
  cannot connect to that account at all until OAuth support lands.

### 2.4 Connecting

After the who-matters step, Thresher walks you through connecting. Enter the address and the app
password; Thresher stores the password in the **macOS Keychain** and never writes
it to a file.

You are then asked **how far back to retrieve**: one week, one month, three
months, or everything. Thresher shows you roughly how many messages each option
would fetch, asked live against your actual mailbox.

⚠️ **This choice is one-way.** You can narrow what you retrieve at setup, but you
cannot widen it afterwards — mail older than the cutoff is never fetched. Pick
wider than you think you need. Three months is the default.

Once connected, the window stops applying. If you close Thresher for two weeks,
all of that mail is retrieved when you reopen it — the window is about not
dragging in years of dead mail at setup, not about permanently hiding anything.

---

## 3. What the tiers mean

| Tier | Meaning |
| --- | --- |
| **1 — Immediate** | Needs attention now. Always surfaces, in every mode. |
| **2 — Today** | Within the next 1–4 hours. Time-sensitive machine mail lives here. |
| **3 — Digest** | Today, but it can wait. Collected into the daily digest. |
| **4 — Low** | Not time-sensitive. The bulk of most mailboxes. |
| **5 — Archive** | Reference only; no action needed. |

Alongside the tier, each message gets a category: **Work** or **Personal**.

### Why a message landed where it did

Select any message and open the explanation. Thresher shows you **which rules
matched, in which order, and what each one did** — including rules that matched
but were outranked. This is not a summary generated after the fact; it is the
actual evaluation record stored when the message was classified.

If a message is in the wrong tier, that panel tells you which rule to change.

---

## 4. ⚠️ Without real people in your groups, nothing reaches Tier 1

**This is the most important thing to know as a new user, and it is the
difference between Thresher looking broken and looking unconfigured.**

Both shipped Tier 1 rules match on **sender group membership** — "leadership" and
"family". Those groups ship with **placeholder members only**
(`boss@example.com`), because Thresher cannot know who matters to you. Until you
put real addresses in them, **no message can ever be classified Tier 1.**

The "Who matters most?" step during setup (§2.1) exists to fill them. If you
skipped it, this section describes your install.

This is measured, not theoretical. Running a 150-message sample mailbox through a
freshly seeded install with no one added produces:

| Tier | Messages |
| --- | --- |
| 1 | **0** |
| 2 | 15 |
| 3 | 21 |
| 4 | 70 |
| 5 | 44 |

If you skipped the setup step, your first task after connecting is **Settings →
Sender groups**: add the handful of people whose mail you must not miss. Then run
**Settings → Classification rules → Reclassify all mail** so that mail already
fetched is re-sorted. Everything else is tuning.

Thresher does still do useful work before you configure anything — the seeded
subject rules catch verification codes, password resets, security alerts and
calendar invitations as Tier 2, which is why the default operating mode is
Catch-up rather than Focus. But the top tier stays empty until you fill the
groups.

---

## 5. Rules and sender groups

### The concepts

**A sender group is a named set of addresses with a floor tier.** Putting someone
in a group with floor Tier 1 means their mail is *never* classified below Tier 1,
whatever the content says. This is the sender override invariant, and it is the
main reason the tool works: you are telling it who matters, rather than hoping
keyword matching guesses.

**A rule is one condition and one effect**, evaluated in priority order. Each rule
matches one field against one operator:

| Field | What it matches |
| --- | --- |
| `sender_email` | The full sender address |
| `sender_domain` | The part after the `@` |
| `subject` | The subject line |
| `body` | The plain-text body |
| `sender_group` | Membership of a named sender group |

Operators are `equals`, `contains`, `starts_with`, `ends_with` — and
`matches_group`, which pairs **only** with `sender_group`. Thresher rejects any
other combination rather than saving a rule that would silently never match.

**Priority is ordinal.** Lower numbers are evaluated first, and the numbers mean
nothing beyond their order — the gap between priority 10 and 20 carries no
weight. Drag rules to reorder them; Thresher renumbers the whole list densely.

### Editing

**Settings → Classification rules** lists every rule with its priority, and
**Settings → Sender groups** lists every group with its members. Both support add,
edit, delete and reorder. A group may have any number of address patterns; a
pattern can be an exact address (`someone@example.com`), a glob
(`*@example.com`), or a domain (`@example.com`).

### Rules apply to new mail, not old

Editing a rule does **not** reclassify what is already in your database. That is
deliberate — a stored classification is an audit record of what the rules said at
the time. To apply changes retroactively, use **Reclassify** on a single message,
or **Reclassify all** in Settings. Reclassifying never changes a message's triage
state and never sends a notification.

---

## 6. Filter chips and triage states

Every message carries a **triage state**, which is yours to move — separate from
the tier, which Thresher assigns.

**New → Acknowledged → Needs Action → Done**

The chips above the list filter by state:

| Chip | Shows |
| --- | --- |
| **Open** (default) | New + Needs action — what is actually outstanding |
| **Needs action** | Only what you have explicitly flagged |
| **Done** | What you have finished |
| **All** | Everything, with Done collapsed at the bottom |

Each chip carries a live count for your whole mailbox, not just the loaded page.

**Search spans every state**, whatever chip is selected — so nothing you have
triaged is ever unreachable. Nothing is ever deleted; suppression here means
"shown later or lower", never "discarded".

### Bulk triage

Select messages and mark them in one action. For large backlogs, Thresher can act
on **everything matching the current filter** rather than just the loaded page —
it tells you the count first and requires confirmation. The set is frozen at the
moment you are shown the count, so mail arriving mid-operation is never swept in.
Bulk actions are capped at 5,000 messages.

---

## 7. Modes, quiet hours, and the digest

**Operating mode** changes how much is surfaced, never how anything is
classified:

- **Focus** — only Tier 1 raises a notification.
- **Catch-up** — Tier 1 and Tier 2. *This is the default*, because until you name
  the people who matter, Tier 1 is unreachable (see §4).

**Tier 1 always surfaces, in any mode.** No mode suppresses it.

**Quiet hours** (Settings → Notifications, e.g. `22:00-07:00`) defer Tier 2
notifications. Tier 1 is exempt and still fires.

⚠️ **Known limitation:** a Tier 2 notification deferred by quiet hours is
recorded but **not replayed when the window ends**. The message is in your list,
correctly classified, and nothing is lost — but do not expect a catch-up banner
at 07:00.

**The daily digest** collects Tier 3 mail from the last 24 hours and delivers it
once, at `digest_time` (default 09:00).

---

## 8. Background polling

**Thresher polls while it is open, and stops when you quit it.** The backend is
started and stopped by the app.

The consequence is worth stating plainly: **if Thresher is closed, no mail is
fetched, and an urgent message will wait until you open it again.** This is a
deliberate trade — the alternative was a background process running whether or
not you had the app open, which is a bigger thing to ask of someone's machine
than this tool needs.

The poll interval is set in **Settings → Notifications**, from 1 to 15 minutes
(default 5).

---

## 9. Write-back to Gmail

By default **Thresher never modifies your mailbox.** First run does nothing to
your mail at all.

Optionally, advancing a message past New can mark it read in Gmail. This needs
**two** separate consents: the per-account preference must be enabled, *and* the
individual action must opt in. A standing preference alone is not enough —
that is deliberate, after a preference set once silently caused a write nobody
asked for months later.

Every attempt to modify the mailbox is logged, including failures. Labelling,
archiving and deleting are not implemented.

---

## 10. Troubleshooting

### Mail has stopped arriving

Thresher watches for this itself. If a mailbox stops being polled, an orange
banner appears at the top of the message list and the dock badge gains a `!`.
That check is keyed on **silence** — a poller that dies without writing an error
is still caught, because absence is the signal.

**Settings → Email accounts** shows per-account status. Note that "Test
connection" answers a different question: it checks whether the credential still
works, not whether anything is actually being fetched. A mailbox can pass that
test while not being polled at all.

### Authentication suddenly fails

Almost always a revoked app password — see §2.3. Changing your Google password
revokes them all. Generate a new one and re-enter it in Settings → Email accounts.

### Logs

**Settings → Reveal Logs in Finder** opens the log folder with the newest file
selected. They live at:

```
~/Library/Application Support/thresher/logs/
```

### Your data

The database is at `~/Library/Application Support/thresher/thresher.db`. It is
plain SQLite. Credentials are in the macOS Keychain under the service name
`thresher`, never in that file.

---

## Limitations

- **Gmail only.** Other IMAP providers are not supported or tested.
- **App passwords only.** No OAuth, so Advanced Protection accounts cannot connect.
- **Rules cannot match mail headers.** Only the five fields in §5. In particular
  `List-Unsubscribe` — the most reliable signal that something is bulk mail —
  is unreachable, which is why newsletters need sender or subject rules instead.
- **Alpha.** Expect rough edges, and keep your mail in Gmail.
