# The original Spec Kit artifacts

**These are the original [Spec Kit](https://github.com/github/spec-kit) artifacts
— `spec.md`, `plan.md`, `tasks.md` — preserved as written.** They describe what
was going to be built.

**The build diverged. See [`DECISIONS.md`](../../DECISIONS.md) for how and why.**

## The divergence is the point

A spec that survived contact with implementation unchanged would be suspicious.
It would mean either that nothing was learned while building, or that the spec
was vague enough to accommodate any outcome.

This one did not survive unchanged, and the record of *why* it changed is the
actual finding. Roughly seventy numbered decisions sit between these three
documents and the code in this repository, several of them reversals of things
decided here. That is not drift to apologise for — it is what spec-driven
development with an agent looks like when the spec is specific enough to be
wrong about something.

Some of the larger departures, each traceable to a numbered decision:

| Planned here | What shipped | Why |
| --- | --- | --- |
| Redis as the message queue | Python's stdlib `queue.Queue` | No external broker earns its keep in a single-user local tool |
| A JVM rules engine (Pyke/Drools) | A small in-house evaluator | Same reasoning, one layer up |
| Alamofire for networking | `URLSession` + `async`/`await` | D35 |
| macOS 10.15 (Catalina) floor | macOS 14.0 (Sonoma) | D36 — to use `@Observable` and `NavigationSplitView` |
| The Gmail REST API over OAuth 2.0 (§4) | IMAP with an app password | OAuth deferred (D26); §4 is annotated in place as deferred rather than deleted |
| Mailbox write-back including archive/delete (§3.5.3) | Opt-in mark-as-read only, behind two gates | D54 deferred the destructive half; D63 added the second gate after a standing preference caused a write nobody asked for |

## What "preserved" means here, precisely

These files are the artifacts **as they stood when the project reached this
point**, not a snapshot of the first draft. A handful of lines were amended in
place while the build ran, and each such line names the decision that changed it
— `(D36)`, `(D50)`, `(D51)`. They are annotations, not rewrites: nothing was
edited to make an earlier judgement look better in hindsight.

Two things follow from that, and both are worth knowing before reading:

- **The checkboxes in `tasks.md` are not a progress bar.** Five of forty are
  ticked. Task tracking moved to work orders early (see
  [`docs/workorders/README.md`](../../docs/workorders/README.md) for why a task
  is not something an agent can execute), and the list was never kept current.
  An unticked box here says nothing about whether the work was done — most of it
  was.
- **The specification is not the documentation.** For what the software actually
  does today, read [`docs/USER-GUIDE.md`](../../docs/USER-GUIDE.md) and
  [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md). These three files are
  history.

`constitution.md`, the fourth Spec Kit artifact, is **not** archived here. It
lives at the top level of the repository because unlike the other three it is
still current — its principles constrain the code as written, and were amended
deliberately rather than outgrown.
