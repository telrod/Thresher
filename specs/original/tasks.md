# thresher Implementation Tasks

> **These are the original Spec Kit artifacts, preserved as written.**
>
> They describe what was going to be built, before roughly seventy decisions and
> several reversals. The build diverged — see `DECISIONS.md` for how and why.
>
> **The divergence is the finding.** A spec that survived contact with
> implementation unchanged would be suspicious; one that did not, with the record
> of why, is the actual story of spec-driven development with an agent.

This document breaks down the technical work outlined in plan.md into discrete, actionable tasks. Each task is linked back to the relevant requirements in spec.md, and assigned a priority and effort estimate.

> **Staleness note (Session 10, 2026-06-20):** this file is largely out of date. Most foundational tasks (Sessions 1–7: SQLite store, in-house rules evaluator, message/classification persistence, IMAP ingestion, notifications, Flask REST API, Tier 3 digest) are **built and tested** but still show unchecked here — `tasks.md` was never reconciled as implementation progressed. A **full reconcile is deferred** (out of scope for the api-gap docs commit). The only boxes checked in this pass are the api-gap batch's own new API work, itemized under *REST API (api-gap batch)* below; the historical 0/35 backlog is acknowledged here rather than silently wrong.

## Task List

### Email Ingestion Service
- [ ] Task: Set up Python environment and install necessary libraries (imaplib, etc.)
  - Spec Ref: 3.1 Email Ingestion
  - Priority: High
  - Effort: 2 points

- [ ] Task: Implement Keychain accessor for the Gmail App Password (v1 auth; OAuth 2.0 deferred)
  - Spec Ref: 3.1 Email Ingestion
  - Priority: High
  - Effort: 1 point

- [ ] Task: Implement Gmail IMAP client 
  - Spec Ref: 3.1 Email Ingestion
  - Priority: High
  - Effort: 3 points

- [ ] Task: Implement message parsing and normalization
  - Spec Ref: 3.1 Email Ingestion
  - Priority: High
  - Effort: 5 points

- [ ] Task: Implement message queue producer
  - Spec Ref: 3.1 Email Ingestion
  - Priority: High
  - Effort: 3 points

- [ ] Task: Implement error handling and retry logic
  - Spec Ref: 5.2 Reliability
  - Priority: Medium
  - Effort: 3 points

### Message Queue
- [ ] Task: Wire up in-process `queue.Queue` for the ingestion→classification handoff (no Redis)
  - Spec Ref: 3.1 Email Ingestion
  - Priority: High
  - Effort: 1 point

- [ ] Task: Define message queue item shape (parsed Message dataclass)
  - Spec Ref: 3.1 Email Ingestion
  - Priority: High
  - Effort: 1 point

### Classification Engine
- [ ] Task: Implement an in-house Python rules evaluator (no Pyke/Drools/JVM dependency)
  - Spec Ref: 3.2 Email Classification
  - Priority: High
  - Effort: 8 points

- [ ] Task: Define initial classification rule set
  - Spec Ref: 3.2 Email Classification
  - Priority: High
  - Effort: 3 points

- [ ] Task: Implement message queue consumer
  - Spec Ref: 3.1 Email Ingestion
  - Priority: High
  - Effort: 3 points

- [ ] Task: Implement message store update logic
  - Spec Ref: 3.2 Email Classification
  - Priority: High
  - Effort: 5 points

### Message Store
- [ ] Task: Design message store schema
  - Spec Ref: 3.6 Data Retention and Access
  - Priority: High
  - Effort: 3 points

- [ ] Task: Set up SQLite database
  - Spec Ref: 3.6 Data Retention and Access
  - Priority: High
  - Effort: 2 points

- [ ] Task: Implement message CRUD operations
  - Spec Ref: 3.6 Data Retention and Access
  - Priority: High
  - Effort: 5 points

- [ ] Task: Implement classification metadata CRUD operations
  - Spec Ref: 3.2 Email Classification
  - Priority: High
  - Effort: 3 points

### REST API (api-gap batch, Session 10)
> Endpoints the Settings/onboarding screens need, closed before the SwiftUI build. Shipped & verified-by-running (commits 6d906fe, cfe2f50).
- [x] Task: Rules CRUD endpoints (`POST`/`PUT`/`DELETE /rules`) with field/operator/tier/category validation + the both-null rule-effect invariant (post-merge check + schema CHECK)
  - Spec Ref: 4.1.3 Settings (P4)
- [x] Task: Sender-group CRUD endpoints (`POST`/`PUT`/`DELETE /sender-groups`) with `urgency_floor` bounds 1–5
  - Spec Ref: 4.1.3 Settings (P4 + sender-override invariant)
- [x] Task: Thread fetch endpoint (`GET /threads/<id>`, messages ordered `received_at` ASC)
  - Spec Ref: 4.1.2 Message Detail ("view full conversation")
- [x] Task: Account verify endpoint (`POST /accounts/verify`, read-only IMAP login test, no mailbox side effects)
  - Spec Ref: 4.1.4 Onboarding (P5; closes E7 at setup)
- [x] Task: Phase C API test suite for the above (suite 68 → 99 green)
  - Spec Ref: 4.1.3 / 4.1.2 / 4.1.4

### Notification Service
- [ ] Task: Implement macOS notification trigger
  - Spec Ref: 3.3 User Notification
  - Priority: High
  - Effort: 5 points

- [ ] Task: Implement notification preferences
  - Spec Ref: 3.5.2 Notification Preferences
  - Priority: Medium
  - Effort: 3 points

### User Interface
- [ ] Task: Design main message list view
  - Spec Ref: 4.1.1 Message List
  - Priority: High
  - Effort: 5 points

- [ ] Task: Implement message list view in Swift/SwiftUI
  - Spec Ref: 4.1.1 Message List
  - Priority: High
  - Effort: 8 points

- [ ] Task: Design message detail view
  - Spec Ref: 4.1.2 Message Detail
  - Priority: High
  - Effort: 3 points

- [ ] Task: Implement message detail view in Swift/SwiftUI
  - Spec Ref: 4.1.2 Message Detail
  - Priority: High
  - Effort: 5 points

- [ ] Task: Design settings screens
  - Spec Ref: 4.1.3 Settings
  - Priority: Medium
  - Effort: 5 points

- [ ] Task: Implement settings screens in Swift/SwiftUI
  - Spec Ref: 4.1.3 Settings
  - Priority: Medium
  - Effort: 8 points

- [ ] Task: Design onboarding flow
  - Spec Ref: 4.1.4 Onboarding
  - Priority: Medium
  - Effort: 3 points

- [ ] Task: Implement onboarding flow in Swift/SwiftUI
  - Spec Ref: 4.1.4 Onboarding
  - Priority: Medium
  - Effort: 5 points

### Sync Service
- [ ] Task: Implement Gmail API client in Python (requires OAuth 2.0 — deferred to a later phase)
  - Spec Ref: 4.2.1 Gmail API
  - Priority: Low (deferred)
  - Effort: 5 points
  - Note: v1 has no write-back/sync; this lands with the deferred OAuth work.

- [ ] Task: Implement message labeling sync
  - Spec Ref: 3.5.3 Mailbox Write-Back 
  - Priority: Medium
  - Effort: 3 points

- [ ] Task: Implement 'mark as read' sync
  - Spec Ref: 3.5.3 Mailbox Write-Back
  - Priority: Low
  - Effort: 2 points

### Testing and QA
- [ ] Task: Implement Python unit tests
  - Spec Ref: 5.5 Maintainability
  - Priority: High
  - Effort: 5 points

- [ ] Task: Implement Swift unit tests
  - Spec Ref: 5.5 Maintainability
  - Priority: High
  - Effort: 5 points

- [ ] Task: Implement integration tests
  - Spec Ref: 5.5 Maintainability
  - Priority: High
  - Effort: 8 points

- [ ] Task: Set up CI/CD pipeline
  - Spec Ref: 5.5 Maintainability
  - Priority: High
  - Effort: 5 points

- [ ] Task: Implement UI automation tests
  - Spec Ref: 5.5 Maintainability
  - Priority: Medium
  - Effort: 8 points

- [ ] Task: Conduct manual QA testing
  - Spec Ref: 5.5 Maintainability
  - Priority: High
  - Effort: 5 points

## Next Steps

1. Review and refine tasks with the development team.
2. Assign tasks to individual developers.
3. Create a project timeline based on task dependencies and developer availability.
4. Begin implementation, tracking progress against the task list.

This task breakdown provides a granular view of the work ahead. It should help the team to parallelize work, track progress, and ensure that all spec requirements are being met.

As with the plan, expect this task list to evolve as the team begins implementation and learns more. The priority and effort estimates in particular should be regularly reviewed and updated based on actual experience.

The key is to maintain a steady flow of work, with clear priorities and a focus on delivering value to users. Regular check-ins, demos, and retrospectives will help to keep the project on track and aligned with the goals outlined in the spec.
