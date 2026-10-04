# thresher Technical Plan

> **These are the original Spec Kit artifacts, preserved as written.**
>
> They describe what was going to be built, before roughly seventy decisions and
> several reversals. The build diverged — see `DECISIONS.md` for how and why.
>
> **The divergence is the finding.** A spec that survived contact with
> implementation unchanged would be suspicious; one that did not, with the record
> of why, is the actual story of spec-driven development with an agent.

This document outlines the high-level technical approach for implementing the thresher email management system, as specified in spec.md.

## System Architecture

thresher will be built as a native macOS application, using a modular, event-driven architecture. The main components will be:

1. **Email Ingestion Service**: Responsible for connecting to Gmail via IMAP (authenticating with an App Password retrieved from the macOS Keychain), retrieving new messages, and pushing them into the Message Queue for processing. Built in Python, using the imaplib library.

2. **Message Queue**: A lightweight, in-process queue (Python's standard-library `queue.Queue`) that decouples email ingestion from processing. For a single-user local tool this is the right weight — no external broker is needed, so Redis was dropped.

3. **Classification Engine**: Consumes messages from the queue, applies user-defined classification rules, and updates the Message Store with the assigned urgency and category. Built in Python, using a small in-house rules evaluator (no JVM/Pyke/Drools dependency).

4. **Message Store**: A SQLite database that holds the processed messages, classification metadata, and user preferences. Provides a simple, performant, and portable data layer.

5. **Notification Service**: Monitors the Message Store for new high-priority messages and triggers native macOS notifications via the UserNotifications framework. Built in Swift.

6. **User Interface**: A native macOS app, built in Swift and SwiftUI, that provides the main message list, detail views, settings screens, and triage actions. Communicates with the Message Store via a simple REST API.

7. **Sync Service**: A background process that periodically syncs local classification state back to Gmail via the Gmail API, applying labels and marking messages as read. Built in Python.

## Key Technologies

- **Python** for the backend services (Ingestion, Classification, Sync)
  - imaplib for IMAP client
  - A small in-house rules evaluator for classification (no JVM/Pyke/Drools dependency)
  - SQLAlchemy for database access
  - Flask for the REST API
- **Swift** and **SwiftUI** for the native macOS UI
  - UserNotifications framework for notifications
  - `URLSession` + `async`/`await` for HTTP networking (no Alamofire — D35; consistent with the project's drop-the-dependency pattern: Redis → `queue.Queue`, Pyke/Drools → plain Python)
- **SQLite** for the local message store database
- Python's standard-library `queue.Queue` for the in-process message queue (no Redis)
- **Gmail API** for syncing state to Gmail
- **IMAP + App Password** (stored in the macOS Keychain) for v1 Gmail authentication; OAuth 2.0 is deferred to a later phase (see Risks)
- **HTTPS/TLS** for secure communication

## Data Models

The main data entities will be:

- **Message**: Represents an email message, with fields for sender, subject, body, timestamp, etc.
- **Classification**: Metadata attached to a message, indicating its urgency tier and category.
- **Rule**: A user-defined classification rule, specifying criteria (sender, keywords, etc.) and the resulting classification if matched.
- **Preference**: A key-value store for user preferences, such as notification settings, sync behavior, etc.

Detailed schemas for these entities will be designed in the database design phase.

## Testing and Quality Assurance

thresher will follow a comprehensive testing strategy, including:

- **Unit Tests**: Written in Python (pytest) and Swift (XCTest) to verify the behavior of individual functions and classes.
- **Integration Tests**: To validate the interaction between components, especially around the message queue and database.
- **End-to-End Tests**: Automated UI tests, using a framework like Appium, to simulate user flows and verify overall system behavior.
- **Performance Tests**: To measure response times, resource utilization, and scalability under various loads.
- **Manual QA**: Exploratory testing by the QA team and beta users to catch any issues not covered by automation.

All tests will be run automatically in the CI/CD pipeline on every code change.

## Deployment and Release Management

thresher will use a typical CI/CD workflow:

1. Developers commit code changes to feature branches in GitHub.
2. On each commit, the CI system (e.g., GitHub Actions) builds the app and runs the automated test suite.
3. On successful tests, the feature branch is merged into a 'develop' integration branch.
4. Nightly builds are generated from 'develop' for internal testing.
5. When a feature set is complete and validated, 'develop' is merged into a 'release' branch.
6. The 'release' branch is used to generate beta builds for user acceptance testing.
7. After successful beta testing, the 'release' branch is tagged as a version and merged into 'main'.
8. Production builds are generated from the tagged 'main' commits.
9. Updates are distributed to end-users via a standard macOS installer package (.pkg) and the Sparkle update framework.

This process ensures that all code changes are properly tested before reaching end-users, and provides clear version control for tracking and troubleshooting issues.

## Risks and Mitigations

Some potential technical risks and their mitigations:

1. **Gmail API rate limiting**: Avoid hitting limits by batching sync operations and implementing exponential backoff on errors.
2. **Classification accuracy**: Allow user tuning of classification rules and provide clear feedback on why messages were classified as they were.
3. **SQLite performance at scale**: Profile typical user data volumes in beta testing, and be prepared to shard the database or move to a more scalable solution if needed.
4. **Security of user credentials**: v1 authenticates to Gmail with an App Password stored in the macOS Keychain (never hardcoded or in env files), retrieved at runtime. OAuth 2.0 is deferred to a later phase; when it lands, follow industry best practices for token management and continue using the Keychain for secure local storage.

Detailed risk assessments and mitigation plans will be developed in the implementation phase.

## Next Steps

1. Break down the major components into granular, actionable tasks in tasks.md.
2. Prioritize the tasks based on dependencies and user value.
3. Assign tasks to developers and create a project timeline.
4. Set up the development environment, including the code repository, build system, and CI/CD pipeline.
5. Begin implementation, starting with the highest priority tasks.
6. Regularly review progress, adjust plans as needed, and keep spec.md in sync with any requirement changes.

This plan provides a solid technical foundation for realizing the thresher vision. As with any complex software project, we expect to learn and adapt as we go. The key is to stay focused on delivering value to users, while maintaining technical excellence and a sustainable pace.
