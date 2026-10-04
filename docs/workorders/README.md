# Work Orders

**Work orders are not part of Spec Kit.** The toolkit's artifacts are
`constitution.md`, `spec.md`, `plan.md` and `tasks.md`; it has no work-order
concept. These are this project's own extension.

They exist because **a task is not executable by an agent.** A task list says
what to build. It does not say what must already be true before starting, what
the agent must not touch, what counts as done, or what to do when the tree does
not match the assumption the task was written under. A work order carries
preconditions, scope fences, verification requirements, and an explicit list of
what *not* to do.

That gap — between "here is the task" and "here is something an agent can be
handed" — is what these documents fill.

## What is here

Eight orders, chosen to show the method working *and* failing:

| File | Why it is here |
| --- | --- |
| `app-icon-workorder.md` + its two run summaries | **The one that was wrong.** Its geometry spec was written in SVG screen coordinates without saying so and handed to a y-up API; the icon shipped mirrored and survived a full round of correction. Read the follow-up summary with it. |
| `overnight-seam-review-report.md` | **A precondition check stopping work.** Three paragraphs of refusing to proceed, because the stated preconditions did not match the machine. The work it declined had already been done two sessions earlier. |
| `cold-start-fixes-workorder.md` | The same discipline inside ordinary work rather than as a dramatic stop. |
| `migration-prep-batch-3-workorder.md` | A hard read-only fence, on the most sensitive material in the tree. |
| `retrieval-window-workorder.md` | A fence outcome recorded honestly: §3–§5 are marked *overtaken* in place rather than edited away. |
| `settings-4.2-rules-groups-workorder.md` | An ordinary successful build. This is what the format looks like on a normal day. |
| `d53-multi-pattern-groups-workorder.md` | The project's first real migration, run against a live database after a rehearsal on a copy. |
| `bulk-cap-workorder.md` | A clean one where the finding was that the ceiling was the endpoint's shape, not the UI's. |

They span the project's life, early to late.

## The later ones got sloppier

That is true, and more useful than a curated illusion. The early orders carry
explicit per-section verification steps; the later ones lean on "verify by
running" without saying what a pass looks like.

**But the app-icon order is the case worth studying, and it is not
carelessness.** That order was *detailed* — it specified grain angles and
positions to four decimal places — and it still produced a mirrored icon.
**Its precision went into constants while leaving the coordinate system
unstated.** Every number was right; the frame they were expressed in was never
named, so a y-down spec met a y-up API and nothing errored.

Precision aimed at the wrong layer is a more interesting failure than
carelessness, and a harder one to fix: not by trying harder or adding decimal
places, but by naming the frame that was too obvious to state.
