# thresher Specification

> **These are the original Spec Kit artifacts, preserved as written.**
>
> They describe what was going to be built, before roughly seventy decisions and
> several reversals. The build diverged — see `DECISIONS.md` for how and why.
>
> **The divergence is the finding.** A spec that survived contact with
> implementation unchanged would be suspicious; one that did not, with the record
> of why, is the actual story of spec-driven development with an agent.

## 1. Introduction

### 1.1 Purpose
The purpose of thresher is to restore the user's relationship with their email inbox by transforming an overwhelming volume of messages into a calm, prioritized stream of relevant information. The system will automatically classify incoming emails by urgency and category, and present them to the user in a way that reduces cognitive load and allows them to focus on what's most important.

### 1.2 Scope
The initial version of thresher will support the following:

- Integration with a single email account (you@example.com)
- Operation on a single platform (macOS desktop)
- Classification of emails into 5 urgency tiers and 2 categories (Work and Personal)
- User notification of high-urgency emails via native macOS notifications
- User interaction to triage and action emails
- Configuration of classification rules and notification preferences
- Local storage and processing of email data

Future versions may expand to additional platforms (web, mobile), more granular categories, and cloud-based processing, but these are out of scope for the initial release.

**Amended (Session 29): multiple email accounts are IN scope.** As originally written
this section put multi-account support out of scope, which contradicted §2.1's
description of the primary user as someone who "receives a high volume of email across
multiple accounts" — the very problem the tool exists to solve. The contradiction was
never load-bearing while only one mailbox was connected, and was resolved in favour of
§2.1 when alpha testing needed two. The ingestion layer was already account-namespaced
throughout (`{account}:{uid}` identity, per-account cursors, UIDVALIDITY, Keychain
credentials and write-back gates), so this amendment records a decision, not a rewrite.

**Still out of scope: PER-ACCOUNT classification rules.** Rules and sender groups are
global — one rule set applied to every mailbox. That is the right default (most rules
should be global) but it has a visible consequence worth stating: a sender group
matching a domain you also *receive at* will classify mail in that mailbox. Per-account
rule scoping is deferred to a design gate, after real use shows whether global rules
are actually a problem.

### 1.3 Definitions
- **Urgency Tier**: A classification of an email's importance and time-sensitivity on a scale of 1 (most urgent) to 5 (least urgent).
- **Category Tag**: A label indicating whether an email relates to the user's work or personal life.
- **Triage State**: The status of an email in the user's workflow, progressing from New to Acknowledged to Needs Action to Done.

## 2. Overall Description

### 2.1 Product Perspective
thresher is a standalone email management application that integrates with the user's existing email account (initially Gmail) and operating system (initially macOS). It is designed to complement, not replace, the user's current email client by providing an additional layer of intelligence and prioritization on top of the raw message stream.

The system will consist of several key components:

1. An email ingestion module that connects to the user's email account and retrieves new messages.
2. A classification engine that analyzes each message and assigns it an urgency tier and category tag based on a set of user-defined rules.
3. A notification module that alerts the user to high-priority messages via the operating system's native notification mechanism.
4. A user interface that allows the user to view, triage, and action messages, as well as configure the system's behavior.
5. A local data store that securely persists the user's email data and classification rules.

### 2.2 Product Functions
The key functions of thresher are:

1. Continuously monitor the user's email account for new messages.
2. Analyze each incoming message to determine its urgency and category.
3. Present messages to the user in a prioritized, easy-to-digest format.
4. Alert the user to high-priority messages in a timely but unobtrusive manner.
5. Provide a simple, efficient interface for the user to process and action messages.
6. Allow the user to customize the classification rules and notification settings to suit their needs.
7. Securely store the user's email data locally, with options to sync to the cloud in the future.

### 2.3 User Classes and Characteristics
The primary user of Thresher is me, the author — a senior technology leader. I receive a high volume of email across multiple accounts: work communications, personal messages, and a great deal of automated notification and marketing mail. I struggle to keep up with the volume and often miss important messages among the noise.

My time is valuable, and I need to identify and respond to high-priority items quickly while still having a way to process less urgent messages when I have time. I am technically savvy but do not want to spend much time configuring or maintaining the system.

In the future, the system may be expanded to support additional users with similar email management challenges.

### 2.4 Operating Environment
thresher will initially operate as a desktop application on macOS. It will require:

- macOS 14.0 (Sonoma) or later (D36; raised from the original 10.15 Catalina floor so the SwiftUI app can use modern idioms — `@Observable`, `NavigationSplitView`)
- Access to the internet to retrieve email from the user's Gmail account
- Sufficient local storage to securely persist the user's email data and configuration settings

### 2.5 Design and Implementation Constraints

## 3. System Features

### 3.1 Email Ingestion
The email ingestion module will be responsible for connecting to the user's Gmail account and retrieving new messages. It will:

- Authenticate with the user's Gmail account using IMAP and an App Password retrieved at runtime from the macOS Keychain (OAuth 2.0 is deferred to a later phase)
- Connect to Gmail's IMAP server for message retrieval (POP will not be supported to avoid removing messages from the server)
- Periodically poll for new messages (default interval: 5 minutes, user-configurable)
- Retrieve the core content of each new message, including headers and body (but not attachments)
- Pass the raw message data to the classification engine for analysis
- Mark each retrieved message as "read" in the user's Gmail account (if configured to do so)

### 3.2 Email Classification
The email classification module will analyze each incoming message and assign it an urgency tier and category tag based on a set of user-defined rules.

#### 3.2.1 Urgency Tiers

Scenario: Classify message by urgency
When a new message arrives
Then the system should classify it into one of the following urgency tiers:
- Tier 1: Requires immediate attention, top priority
- Tier 2: Requires attention within the next 1-4 hours  
- Tier 3: Requires attention today, but can wait a few hours
- Tier 4: Not time-sensitive, can be dealt with in the next few days
- Tier 5: No action needed, for reference only

Rule: Classification by sender
When a message is from a sender in the "Leadership" group
Then it should be classified as Tier 1 urgency

Rule: Classification by keyword
When a message contains the keyword "urgent" in the subject or body  
Then it should be classified as Tier 2 urgency or higher

#### 3.2.2 Category Tags

Scenario: Classify message by category
When a new message arrives
Then the system should assign it one or more of the following category tags:
- Work: Related to the user's professional responsibilities
- Personal: Related to the user's personal life

Rule: Classification by sender domain
When a message is from a sender with a "company.com" email domain
Then it should be classified with the "Work" category  

Rule: Classification by mailing list
When a message is sent to a mailing list related to a hobby
Then it should be classified with the "Personal" category

### 3.3 User Notification
The user notification module will be responsible for alerting the user to incoming messages in accordance with their urgency tier and the user's current operating mode.

Scenario: Notify on Tier 1 message
When a new Tier 1 message arrives  
Then the system should immediately trigger a native macOS notification with the sender and subject
And increment the app's unread badge count
And optionally play a subtle audio alert (if enabled by the user)

Scenario: Notify on Tier 2 message in Catch-up mode
When a new Tier 2 message arrives
And the user is in "Catch-up" mode
Then the system should immediately trigger a native macOS notification with slightly lower prominence than Tier 1

Scenario: Queue Tier 2 message in Focus mode 
When a new Tier 2 message arrives
And the user is in "Focus" mode
Then the system should add the message to the "Soon" queue for later review
And not trigger any immediate notification

Scenario: Summarize Tier 3 messages in daily digest
When the scheduled daily digest time arrives (default 9am, user-configurable)
Then the system should trigger a digest notification  
And include a summary of all Tier 3 messages received in the last 24 hours
And allow the user to expand each summary to see the full message in the app

### 3.4 User Interaction
The thresher UI will provide a simple, efficient interface for the user to review, triage, and action incoming messages.

#### 3.4.1 Triage States

Rule: New messages start as "New"
When a message is first classified
Then its triage state should be set to "New"

Rule: Opening a message marks it "Acknowledged" 
When the user opens a message to view its details
Then the system should transition its triage state to "Acknowledged"

Rule: Marking a message for follow-up  
When the user marks a message as needing a response or action
Then the system should transition its triage state to "Needs Action"

Rule: Completing a message
When the user marks a message as fully handled  
Then the system should transition its triage state to "Done"

#### 3.4.2 Operating Modes

Rule: Focus mode suppresses non-critical notifications
When the user selects "Focus" operating mode
Then the system should only trigger immediate notifications for Tier 1 messages
And queue Tier 2 and below for later review  

Rule: Catch-up mode surfaces more messages
When the user selects "Catch-up" operating mode
Then the system should trigger immediate notifications for both Tier 1 and Tier 2 messages
And include Tier 3 messages more prominently in the daily digest

Scenario: Operating mode does not affect classification
When the user changes their operating mode
Then the system should not change how it classifies the urgency or category of messages  
But only adjust which messages trigger active notifications

### 3.5 Configuration and Customization
thresher will provide several points of configuration to allow the user to tailor the system to their needs and preferences.

#### 3.5.1 Classification Rules
The user will be able to view, edit, add, and remove the rules used to assign urgency tiers and category tags to incoming messages. This will include:

- Specifying sender identities and relationships for different tiers/categories
- Defining keyword matches for subject lines and message bodies
- Configuring metadata-based rules (e.g., "mark any message sent only to me as Tier 1")

The system will provide a user-friendly interface for managing these rules without requiring direct editing of configuration files.

#### 3.5.2 Notification Preferences
The user will be able to customize various aspects of the notification behavior, such as:

- Enable/disable audio alerts for Tier 1 messages
- Set the daily digest delivery time for Tier 3 messages
- Choose the default operating mode (Focus or Catch-up)
- Specify quiet hours during which all notifications should be suppressed

#### 3.5.3 Mailbox Write-Back 
The user will be able to configure if and how thresher should write back state to the source Gmail mailbox, such as:

- Mark messages as read when retrieved
- Apply Gmail labels that mirror the assigned urgency tier or category
- Archive or delete messages in Gmail when marked as Done in thresher

By default, no write-back will occur to prevent unintended side effects.

### 3.6 Data Retention and Access
thresher will securely store all retrieved message data locally on the user's device. This includes:

- The raw message headers and body content (excluding attachments)

- The assigned classification metadata (urgency tier, category tags)
- The current triage state of each message

The system will provide a search interface to allow the user to find and retrieve any processed messages, even if they have been archived or deleted in the source mailbox.


## 4. External Interface Requirements

### 4.1 User Interfaces

#### 4.1.1 Message List
The main screen of the app, displaying a list of messages sorted and grouped by urgency tier. 

- Each message row includes sender, subject, timestamp, and a brief preview
- Messages can be filtered by category, triage state, or other criteria
- **Triage filter chips (D50):** Open (default) · Needs action · Done · All, each
  with a live store-wide count. Open = triage state New + Needs action **+
  unclassified mail** (no classification row — amended by the author, Session 26: a
  stuck classify failure must be visible by default, P1); Acknowledged is
  excluded — "seen, nothing owed" counts as handled. All shows
  every state; Acknowledged renders normally and Done collapses into a disclosure
  section at the bottom. The selected chip persists across launches (local
  preference). Search always spans every triage state regardless of the active
  chip (P1 floor). Tier-first ordering is unchanged within any view; chips have
  no effect on classification, notifications, digest, or operating modes.
- **Dock badge (D51):** the count of untriaged (state New) Tier 1–2 messages —
  derived entirely from triage state; any advance past New decrements it; zero
  shows no badge.
- Selecting a message opens the Message Detail view

#### 4.1.2 Message Detail
Displayed when a message is selected from the Message List.

- Shows the full message content, with options to change triage state, view full conversation, or open in Gmail
- Changing triage state updates the message's position in the list view  

#### 4.1.3 Settings
Screens for managing app preferences and connected accounts.

- Email Accounts: Connect or disconnect Gmail accounts, manage the stored App Password (held in the macOS Keychain)
- Classification Rules: View, edit, add, or remove rules for urgency tiers and categories
- Notification Preferences: Configure notification modes, quiet hours, audio alerts
- Notification Preferences include the alerts hint (D51): banners auto-dismiss by
  macOS design; the pane says so honestly and offers an "Open System Settings"
  link to the Notifications pane, where alert-style persistence is the user's
  own OS-level choice

#### 4.1.4 Onboarding
The initial setup flow, displayed on first launch or when adding a new account.
The notifications step shares the Settings notification pane, so it carries the
same D51 alerts hint and System Settings link.

- Connect a Gmail account by supplying an App Password, which is stored in the macOS Keychain (OAuth-based connection is deferred to a later phase)
- Configure initial notification and classification preferences
- Brief tutorial highlighting key features

### 4.2 Software Interfaces

#### 4.2.1 Gmail API (deferred to a later phase)

> **Scope note:** This section describes the Gmail API integration that backs mailbox write-back and state sync. It is **deferred to a later phase** along with OAuth 2.0. In v1, message retrieval is handled by the Email Ingestion module over **IMAP using an App Password** (see §3.1), and **no write-back/sync occurs** (see §3.5.3). The design below is retained for the phase in which the Gmail API and OAuth land.

thresher will integrate with Gmail via the public Gmail API (v1). Key operations:

- **Authentication**: OAuth 2.0 flow to obtain access and refresh tokens for a user's account
  - Scopes: `gmail.readonly` for message retrieval, `gmail.modify` for labeling and marking read
  - Tokens persisted securely in the local application data store
  
- **Message List**: Retrieve message metadata for display in the list view
  - Endpoint: `GET /gmail/v1/users/{userId}/messages`
  - Parameters: 
    - `q`: Search query for filtering messages
    - `maxResults`: Page size for results (default 50)
    - `pageToken`: Token for pagination
  - Response: List of message IDs and metadata (sender, subject, timestamp, etc.)

- **Message Detail**: Retrieve full message content for display in the detail view  
  - Endpoint: `GET /gmail/v1/users/{userId}/messages/{messageId}`
  - Parameters:
    - `format`: "full" to include message body content
  - Response: Full message data, including headers, body plain text and/or HTML, and attachments

- **Modify Messages**: Mark retrieved messages as read, apply labels for triage state
  - Endpoint: `POST /gmail/v1/users/{userId}/messages/{messageId}/modify`
  - Request Body:
    - `removeLabelIds`: ["UNREAD"] to mark as read
    - `addLabelIds`: Custom labels for triage state (e.g., "THRESHER_ACKNOWLEDGED")

All API requests must include a valid OAuth access token in the `Authorization` header. Expired access tokens will be refreshed using the stored refresh token.

Rate limits and error handling:

- Stay within the Gmail API usage limits (250 quota units per user per second)
- Implement exponential backoff for rate limit errors (HTTP 429)
- Handle other error codes gracefully (e.g., 401 for expired token, 404 for deleted message)

#### 4.2.2 macOS User Notifications
thresher will display system notifications using the macOS User Notifications framework (UserNotifications.framework).

- Request authorization to display notifications on first launch
- Create and deliver notifications based on urgency tier and operating mode:
  - Tier 1: Display immediately with sound alert (if enabled)
  - Tier 2: Display immediately with sound (Catch-up mode) or badge app icon (Focus mode)  
  - Tier 3: Aggregate into daily digest notification
- Handle notification interactions (click to open message, dismiss)

Configuration options exposed via Settings screen:

- Enable/disable sound alerts
- Set quiet hours to suppress all notifications
- Choose default notification style (alert vs. badge)

## 5. Other Non-functional Requirements

### 5.1 Performance
- UI responsiveness:
  - Navigation between screens should complete within 100ms.
  - Message content should load within 500ms of selection.
- Email processing:
  - New messages should be classified and trigger appropriate notifications within 30 seconds of being retrieved from Gmail.
  - The system should be able to process at least 100 new messages per minute without UI responsiveness degradation.
- Resource utilization:
  - The system should consume no more than 256MB of RAM and 10% CPU on average.
  - Local storage size should grow by no more than 1MB per 1000 messages processed.

### 5.2 Reliability
- Error handling:
  - The system should gracefully handle and recover from network disruptions, Gmail API errors, and other exceptional conditions.
  - In the event of an unrecoverable error, the system should fail safely and provide clear diagnostic information.
- Data persistence:
  - All user data and application state should be regularly backed up to protect against data loss.
  - The system should implement a robust data migration mechanism to support future schema changes.

### 5.3 Security
- Data protection:
  - All sensitive user data (email content, etc.) must be encrypted at rest using AES-256 or stronger. Credentials (the v1 Gmail App Password, and OAuth tokens once that phase lands) are stored in the macOS Keychain rather than the application data store.
  - All network communication must use HTTPS/TLS with a trusted certificate authority.
- Access control: 
  - The system should operate with the principle of least privilege, only requesting and retaining the minimum permissions needed for each function.
  - User credentials should never be stored in plain text, and should be securely hashed using a modern algorithm (e.g., bcrypt, scrypt).
- Secure development:
  - The codebase should be regularly scanned for common vulnerabilities (e.g., OWASP Top 10) and dependencies should be kept up to date.
  - All user input should be validated, sanitized, and escaped to prevent injection attacks.

### 5.4 Privacy
- Data minimization:
  - The system should only collect and retain user data that is directly necessary for its core functions.
  - Users should have control over what data is shared with the system and be able to easily delete their data if desired.
- Transparency:
  - The system's privacy policies and data handling practices should be clearly communicated to users, including through in-app privacy notifications.
  - Any sharing of anonymized usage data should be explicitly opt-in with clear user benefits.
- Local-first:
  - By default, all email data should be processed and stored locally on the user's device, not in the cloud.
  - Any cloud-based functionality (e.g., for backup or sync) should be optional and require explicit user permission.

### 5.5 Maintainability
- Code quality:
  - The codebase should adhere to clean code principles, with clear naming, small functions, and minimal duplication.
  - All code should be regularly reviewed for quality and consistency, using static analysis tools where appropriate.
- Modularity:
  - The system architecture should be modular and loosely coupled, with clear separation of concerns between components.
  - Dependencies between modules should be explicitly defined and minimized.
- Documentation:
  - All code, APIs, and configuration files should be thoroughly documented using a consistent format (e.g., JSDoc, OpenAPI).
  - The system should maintain comprehensive user and developer guides that are updated with each release.

### 5.6 Portability
- Cross-platform:
  - The core system logic should be implemented in a platform-agnostic way, avoiding OS-specific dependencies where possible.
  - Any platform-specific code should be clearly isolated and abstracted behind interfaces.
- Configurability: 
  - Hard-coded values should be minimized in favor of configuration files, environment variables, and runtime flags.
  - The build and deployment process should support easy configuration for different target environments.
