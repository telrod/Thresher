# Brief: SDD's real value for this team — estimation & commitment

> **Status:** Draft brief, captured at the end of a planning session. To become a
> section of `sdd-team-playbook.md` next session. This is the framing to write that
> section *from*, plus the open task to anchor it with a real example.

## The reframe

The team's stated problem is "we start implementation before thinking everything
through." The *root cause* is a commitment-timing problem, not a discipline problem:

1. A delivery date gets committed (often by leadership) **before** the planning work is
   costed.
2. The committed date doesn't include the planning time, because at commitment time the
   planning hasn't been done — so it's treated as free.
3. To hit the date, the team compresses or skips the thinking (architecture, security,
   scalability, test strategy).
4. Skipped thinking surfaces later as **rework**.
5. Rework blows the date anyway → the team eats the overage in extra hours and cut
   testing → buggy code ships to meet the date.

The thinking work is real but **unpriced at commitment time**, so it gets valued at zero.

## Why this changes how to deploy SDD

**SDD by itself can make this worse before it makes it better.** It front-loads *more*
explicit thinking (constitution, spec, plan, ADRs, decision triage). Bolt that onto a
process where dates are still committed before planning is costed, and you've added more
unpriced work ahead of the same fixed deadline — the gap widens. The "we adopted SDD and
it slowed us down" failure happens exactly this way.

The leverage is **not** "do SDD." It's: **make the planning phase a costed, visible,
date-bearing part of the work, so a delivery commitment can't be made before planning is
done.** SDD is useful here precisely because its planning phase produces *artifacts and
gates* — concrete things that generate the estimate and justify the timing.

**The core gate:** no delivery-date commitment until the plan phase clears, because the
plan phase is what *produces* the delivery number. The team can commit to a date for
*finishing the plan* (spec + architecture + open decisions resolved); that output is what
yields the delivery estimate.

## What each SDD piece is *for* in this context

- **Decision triage** (playbook §7): surfaces, before implementation, the count of
  unresolved high-stakes decisions. "Eleven needs-the-team decisions still open" is a
  concrete, showable reason a date can't be firm yet. Converts "we haven't thought it
  through" (sounds like foot-dragging) into "here are eleven specific unresolved forks"
  (undeniable).
- **The planning gate**: the wall between "committed to a date" and "started building."
  Its job here is to stop implementation starting against an uncosted date.
- **ADR + rework-capture loop**: the *measurement instrument* (see metrics below).

## The two metrics (this is the before/after evidence)

These are what move leadership — not "we feel more organized," but data.

1. **Late-caught-decision count per feature.** Every time a decision is caught late and
   forces rework, it's a recorded event (an ADR, a reopened ticket). Count them. This is a
   direct proxy for "thinking we skipped and paid for later." If SDD is working, this
   number falls across successive features.

2. **Estimate-vs-actual delta.** Per feature, track three dates: (a) the date *committed*,
   (b) the date the *plan phase produced as an estimate*, (c) the *actual*. The expected
   pattern that proves the thesis: committed dates miss; plan-phase-estimated dates hit.
   That's the empirical case that commitment-before-planning is the defect — not the
   team's speed.

## The honest caution

You can run a perfect SDD process and still lose if dates keep getting committed *upstream*
of it. The methodology gives you artifacts and evidence; it does **not** by itself change
who commits to what, when. The hard part of the rollout isn't teaching the phases — it's
using the artifacts SDD produces to change the **commitment conversation** with leadership.

So weight the rollout toward: pilot one feature *fully* through SDD, instrument both
metrics religiously, and bring leadership the delta. The pitch is **not** "let us do SDD."
It's: "let us cost the planning before you commit the date — and here's the data showing
what skipping that costs us."

## Article angle (strongest thesis in the project)

The un-obvious claim: *the value of spec-driven development on a team isn't better specs —
it's that it makes the cost of thinking visible early enough to defend it against a
premature date.*

## Open task to make this concrete (do before next session if possible)

Find one real past example — even anecdotal — of the loop: a feature that committed to N
weeks, took N+X, where a meaningful chunk of the overage was rework on decisions made
implicitly. Doesn't need precision; needs one concrete instance that shows the loop. It
anchors both the playbook section and the article, and it's what makes the argument to
leadership land.
