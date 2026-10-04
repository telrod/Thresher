# Work Order — Migration Prep Batch 3

> **Origin:** planning session 2026-09-06, after Session 39 closed the icon work.
>
> **Two parts, deliberately different in kind.** Part A is real code that
> de-risks the largest untested unknown in the migration plan. Part B is
> **read-only reconnaissance** that turns a blank page into a document the author can
> edit.
>
> **Context:** this project migrates to a fresh public repo named **Thresher**
> (`com.tomelrod.Thresher`), as a new tree with no shared history. The private
> repo freezes as the archive. Distribution is **source-only** — no signing, no
> notarization, no binaries — so `scripts/build.sh` is the entire distribution
> story.

---

## §0 — Preconditions

1. Working tree clean, level with origin, log state pointer current.
2. The live alpha backend is running and **stays running**. Do not restart it,
   do not touch the live database, do not run `dev-run.sh`.
3. **Do not install to `/Applications`.** That copy is the author's.

---

## §1 — Scope fences

- **Do not rename anything.** No `Thresher`, no `com.tomelrod`, no path changes.
  The rename happens in the migration staging tree, not here. Write Part A
  against the current name; it gets renamed with everything else.
- **Do not begin the migration.** No new repo, no copying, no scrubbing, no
  deleting. Part B **reports**; it changes nothing.
- **Do not scrub any PII in this repo.** The private repo's honesty is what makes
  it useful as an archive. Scrubbing happens once, later, on copies.
- Do not edit `project-log.md`; report corrections for the author.

---

## §2 — Part A: `scripts/build.sh`, the distributable build

### Why this is first

Source-only distribution means a stranger's entire experience is: clone, run one
command, get a working app. There is no fallback. The acceptance test —
**does the app launch with no development environment present?** — currently sits
at Stage 2 of the migration plan, which is late. A packaging problem found now
costs a session; found mid-migration it costs a session plus the disruption of
being halfway through a tree move.

`dev-run.sh` is a development loop — it builds, installs, restarts launchd agents
and relaunches. This is a different thing: it produces an artifact and stops.

### Required

1. **Read `dev-run.sh` and `bundle-backend.sh` first and reuse them.** If the
   bundling step already exists as a separate script, call it rather than
   reimplementing it. Report what you reused and what you had to add.

2. **Produce a self-contained app**, Release configuration:
   - `backend/` plus vendored flask copied into `Contents/Resources`
   - **No Python runtime bundled.** Stock `/usr/bin/python3` runs the backend and
     flask is the only third-party dependency (D68). If anything in the tree has
     acquired a second third-party dependency since, **stop and report** — that
     would change the distribution story, not just this script.
   - Build-provenance stamp applied, and **fail the build if it did not stick**

3. **Fail loudly on missing prerequisites** — Xcode command line tools, an
   unsupported macOS version, a missing `/usr/bin/python3`. A broken bundle that
   builds successfully is the failure mode this script exists to prevent. Name
   what is missing and what to do about it.

4. **Print where the app was written.** The script's last line should tell the
   user what to do next.

5. **Verify by running, in the most hostile environment you can arrange without
   disturbing the author's machine:**
   - Build to a scratch location, not `/Applications`
   - Launch it from there with a **minimal environment** — no pyenv shims, no
     repo-relative paths, a working directory outside the checkout
   - Confirm the backend starts, the API answers, and the app reaches a usable
     state
   - ⚠️ **State the limit of what you proved.** A genuinely clean test requires
     the checkout to be absent from the machine entirely, which is not available
     here. Say what remains unverified rather than implying full coverage —
     see OI37: establish what the probe is blind to before trusting its verdict.

6. **Document the development path separately and label it clearly.** Running the
   backend by hand, or under launchd, is for development. ⚠️ The README already
   made this mistake once — it described the unsupervised arrangement that caused
   a thirteen-day silent outage as though it were normal setup. Do not reproduce
   that shape.

---

## §3 — Part B: migration reconnaissance — READ ONLY

Two reports. **Change nothing.** Both are inputs to decisions the author will make.

### B1 — File inventory with a disposition recommendation

Every file in the tree, tracked and untracked, with a recommendation and a
one-line reason:

| Disposition | Meaning |
| --- | --- |
| **copy** | Goes to the public repo as-is |
| **scrub** | Goes, but contains names, employer references, or personal addresses |
| **never** | Does not go — real mail, real seeds, databases, private notes |
| **regenerate** | Not copied; produced by a script in the new tree |

⚠️ **The public repo will be built by allowlist, not by sweeping and scrubbing
after.** So the useful output is a list the author can edit down, where a mistake means
a missing file — noticed immediately — rather than a colleague's name on the
internet. Bias toward **never** when uncertain and say why.

**Flag separately: files you cannot assess by reading**, particularly anything
under `docs/workorders/evidence/`. Screenshots are where PII hides from grep, and
a real subject line in a chip screenshot is invisible to every automated check.
List them for manual review; do not guess.

### B2 — PII occurrence report

Every occurrence, with file, line number and enough surrounding context to judge
whether the sentence still makes sense once the name is replaced:

- every real personal name in the tree (manager, colleagues, recruiters)
- `<employer>`, `example.com`, `you@example.com`
- `you@example.com`, `you@example.org`, `example.org`
- the author's GitHub username — including **filesystem paths**
  (`/Users/<username>/...`), which appear in logs, plists and evidence output and
  are easy to miss
- Any other real personal name or address you encounter that is not on this list

Search **filenames and directory names as well as file contents.**

Group by file, and separate the mechanical cases (a path in a log line) from the
ones needing judgement (a decision-log paragraph about a conversation with a
named person). The second group is the real work and the author should see its size
before committing to a scrubbing approach.

**Report only.** Do not replace anything.

---

## §4 — Part C: log corrections to report

For the author to apply to `project-log.md`:

- **OI27 is CLOSED.** On 2026-09-06 the author installed the new icon and checked all
  four surfaces. A notification banner rendered the correct app icon **both with
  the app running and with it quit** — so the osascript path resolves the app's
  own icon after all. The generic-Script-Editor theory was wrong; the earlier
  reports were the duplicate-bundle problem. No helper app and no routing change
  are needed.
- The Session 39 handoff's "what is next" item 1 is stale for the same reason —
  the install and the four-surface check are done.

---

## §5 — Closing

- Committed run summary is the artifact.
- Per part: what changed, what was verified **by running**, what was flagged.
- Part B changes nothing — if you find yourself editing a file in Part B, stop.
- Push at the end; report the count and range.
