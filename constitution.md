# Project Constitution
**Project:** thresher  
**Version:** 1.0.0  
**Date:** 2026-06-13  
**Status:** Draft — awaiting author review

---

## Purpose

thresher exists to restore the author's relationship with his email by transforming an overwhelming firehose of messages into a calm, prioritized signal stream. The tool does not attempt to eliminate email — it routes every message to the right level of attention at the right time, so that nothing important is ever missed and nothing unimportant ever demands attention it doesn't deserve.

---

## Scope (MVP)

- **Single account:** you@example.com only
- **Single platform:** macOS desktop
- Future expansion to additional accounts and platforms is anticipated but out of scope for v1

---

## Learning Goals

thresher serves two goals:

1. **Primary:** Restore the user's relationship with email by transforming overwhelming volume into a calm, prioritized signal stream.

2. **Secondary:** Teach the user Spec-Driven Development (SDD) best practices by using GitHub Spec Kit to build the tool. All major decision points, moments of confusion or friction, and SDD methodology observations are captured for use in a future article.

The project explicitly prioritizes doing both — not just shipping the tool, but documenting the process as a learning artifact.

---

## Principles

These principles are non-negotiable. Every feature, design decision, and implementation choice MUST be evaluated against them. When principles appear to conflict, they are listed in priority order.

---

### P1 — Never Silently Drop

**Every email received MUST be retained and reachable.**

Suppression is a latency decision, not a deletion decision. An email classified as low-priority is delayed, not discarded. The worst possible failure mode is missing a signal entirely. There is no such thing as an email that "doesn't matter enough to keep."

- Acceptance test: given any email ever received, the user MUST be able to retrieve it from the system.
- Corollary: write-back to source mailboxes MUST NOT delete or archive emails unless the user explicitly and individually authorizes that action.

**Scope clause (D61, added Session 35).** P1 governs mail the tool has
**ingested** — mail it has taken responsibility for. **The user chooses the
ingestion boundary at connect time** (the retrieval window: last week / last
month / last 3 months / everything), and mail older than that boundary is never
retrieved at all.

This is a scope statement, not a weakening. Mail outside the window is not
dropped, hidden, or delayed by this tool — it is untouched on the mail server
and readable in any other client; the tool simply never copies it. What P1
forbids is the tool taking custody of a message and then losing it, and that
remains absolute.

Two consequences are stated here because they are the ones a user can be
surprised by:

- **The boundary is one-way.** It cannot be widened later, so the app never
  presents a narrow window as the safe default. Widening would mean reconciling
  a new range against what is already stored without duplicating anything or
  replaying alerts for old mail — real work, for a case most people meet once.
- **The boundary applies to the INITIAL backfill only, never to ongoing
  polling.** Close the app for two weeks and all of that mail is retrieved.
  Applying the window on every poll would mean closing the app could permanently
  hide an urgent message — the exact failure this tool exists to prevent, and
  unrecoverable given the point above.

Recorded here rather than left implicit because "the tool never fetched it" and
"the tool lost it" are indistinguishable to a user looking for a missing
message, and P1 is the invariant they would reasonably invoke.

---

### P2 — Ambient Over Interruptive

**Notifications MUST fit into the user's peripheral awareness. They MUST NOT demand immediate attention.**

The tool is designed to reduce cognitive load, not add to it. Tier 1 alerts (the most urgent) surface as a macOS notification or badge count — visible when the user glances, ignorable when the user is focused. No audio alerts, no SMS, no pop-ups that block work.

- Acceptance test: a user in deep focus can ignore a Tier 1 notification without losing work context, and still see it within a natural attention break.

---

### P3 — Transparent by Default

**The user MUST always be able to understand why an email was classified the way it was.**

Black-box classification erodes trust. Every routing decision must expose its reasoning on demand — which rule matched, which sender group applied, which content signal triggered the tier assignment.

- Acceptance test: for any classified email, the user can view a human-readable explanation of the classification without navigating away from the triage view.

---

### P4 — Preferences Are First-Class Adjustable Config

**Nothing that governs classification behavior is hardcoded.**

Sender groups, urgency rules, tier thresholds, the daily surfacing ceiling (~50 items), operating mode behavior, and notification style MUST all be user-configurable without requiring code changes. Default values are starting points, not permanent decisions.

- Acceptance test: a non-developer user can modify any classification rule using the configuration interface without editing source code.

---

### P5 — User Controls All Side Effects

**Actions that affect systems outside the tool (source mailboxes, notifications, external services) MUST be opt-in.**

Write-back to source mailboxes (marking read, flagging important) is an opt-in setting, configured per mailbox. Any integration with external services requires explicit user authorization. No side effect is ever activated by default.

- Acceptance test: on first run with no configuration, the tool reads email and classifies it — and does nothing else to any external system.

---

## Key Behavioral Invariants

These are derived from the principles and MUST be preserved across all versions:

1. **The suppression invariant:** No email is ever moved, deleted, or made unreachable by this tool unless explicitly authorized per P1 and P5.
2. **The Tier 1 invariant:** Tier 1 emails MUST always surface an ambient alert, regardless of operating mode (Focus or Catch-up). No mode suppresses Tier 1.
3. **The sender override invariant:** A known sender's email MUST NOT be classified below the floor tier implied by that sender's group, regardless of content signals.
4. **The write-back invariant:** Source mailbox state is only modified if write-back is explicitly enabled for that mailbox.

---

## Classification Model

The system uses a **5-tier urgency model** combined with a **Work/Personal category tag**.

| Tier | Label | Notification behavior |
|------|-------|----------------------|
| 1 | Immediate | Ambient macOS alert (notification or badge) — always fires |
| 2 | Soon | Surfaces within 1–4 hours |
| 3 | Today | Daily digest — sender + subject visible, summary on drill-down |
| 4 | Low | Retained silently; no notification |
| 5 | Archive | Retained silently; no notification |

**Category tags:** Work, Personal (expandable in future versions)

**v1 classification engine:** hand-tuned configuration rules. Machine learning and adaptive classification are explicitly deferred to a future version.

---

## Operating Modes

The user manually selects between two operating modes. Mode affects which tiers surface proactively — it does not affect retention or Tier 1 behavior.

| Mode | Intent | Behavior |
|------|--------|----------|
| **Focus** | Busy day; minimize interruption | Only Tier 1 alerts surface immediately; Tier 2–3 held for next check-in |
| **Catch-up** | Slow day; burn down backlog | Tier 2–3 surface more aggressively; backlog items promoted for review |

---

## Triage State Model

Every email passes through an explicit triage state. This replaces the user's current workaround of marking emails "unread" to mean "come back to this."

`New` → `Acknowledged` → `Needs Action` → `Done`

---

## Constraints

- **Local-first:** Classification and storage run locally on the user's machine in v1. Cloud deployment (AWS) is a planned future path.
- **Cloud AI:** Use of cloud AI for classification or summarization requires explicit user sign-off on specific services, cost model, and data handling before integration.
- **Thunderbird filter import:** Acceptable only if import can be automated. Manual re-entry of existing filters is not acceptable. Feasibility is a research spike before committing.
- **Phone access:** Out of scope for v1.
- **Daily surfacing ceiling:** ~50 items/day, configurable per P4.

---

## People in Scope (Sender Classification Seeds)

These known contacts inform default sender group assignments for the MVP account:

| Person / Group | Default sender group | Urgency floor |
|---------------|---------------------|---------------|
| Your manager | Leadership | Tier 1 |
| Recruiters (active job search) | Recruiters | Tier 2 |
| Family | Family | Tier 1 |
| Close colleagues | Close colleagues | Tier 2 |
| General known contacts | Known | Tier 3 |
| Unknown senders | Unknown | Tier 4–5 (content-driven) |

---

## Out of Scope (v1)

- Additional email accounts beyond you@example.com
- Mobile / phone access
- Adaptive or machine-learning classification
- Thunderbird filter import (pending research spike)
- Deletion or archiving of source email
- Multi-user support

---

*This constitution is the foundational document for thresher. All specs, plans, and tasks generated for this project MUST reference and comply with it.*
