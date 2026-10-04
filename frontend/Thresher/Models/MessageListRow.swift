//
//  MessageListRow.swift
//  Thresher
//
//  The row shape returned by GET /messages and GET /messages/search.
//
//  Per docs/api-contract-map.md (E10 guard): list and search share ONE shape —
//  it carries `preview` but NO body, and NO rule_matches/explanation. The detail
//  endpoint is a *different* struct (MessageDetail, built in a later session)
//  that carries body/explanation but `preview: null`. Modeling them as separate
//  structs makes "preview only exists on list rows" a compile-time fact rather
//  than a convention to remember.
//
//  All three classification fields are nullable (LEFT JOIN; unclassified mail is
//  a real state, P1) — kept as raw optionals here and surfaced via the Tier /
//  Category / TriageState enums.
//

import Foundation

struct MessageListRow: Codable, Identifiable, Hashable {
    let id: String
    let account: String
    let threadID: String?
    let senderName: String?
    let senderEmail: String
    let subject: String?
    let receivedAt: String      // ISO-8601 string from the API
    let ingestedAt: String
    let preview: String?        // list/search only; nil if body_plain was null
    let urgencyTier: Int?       // nullable: unclassified
    let category: String?       // nullable
    let triageState: String?    // nullable

    enum CodingKeys: String, CodingKey {
        case id, account, subject, preview, category
        case threadID = "thread_id"
        case senderName = "sender_name"
        case senderEmail = "sender_email"
        case receivedAt = "received_at"
        case ingestedAt = "ingested_at"
        case urgencyTier = "urgency_tier"
        case triageState = "triage_state"
    }

    // ── Domain views over the nullable raw fields ──────────────────────────

    /// `nil` ⇒ the message is unclassified (render an "Unclassified" badge).
    var tier: Tier? { Tier(raw: urgencyTier) }

    /// Total: any missing/unknown value collapses to `.unknown`.
    var categoryValue: Category { Category(raw: category) }

    /// `nil` ⇒ unclassified (no triage state yet).
    var triage: TriageState? { TriageState(raw: triageState) }

    /// What the row shows as the "from" line: prefer the display name, fall back
    /// to the email (which is never null).
    var displaySender: String {
        if let name = senderName, !name.isEmpty { return name }
        return senderEmail
    }

    /// Subject is nullable on the wire; give the UI a stable placeholder.
    var displaySubject: String {
        if let subject, !subject.isEmpty { return subject }
        return "(no subject)"
    }

    /// Copy with a new triage_state — the one field a triage advance mutates.
    /// E20: lets the list patch a row in place when the detail pane triages,
    /// instead of refetching (P2/D34: no scroll/selection disruption).
    func withTriageState(_ newState: String) -> MessageListRow {
        MessageListRow(
            id: id, account: account, threadID: threadID,
            senderName: senderName, senderEmail: senderEmail, subject: subject,
            receivedAt: receivedAt, ingestedAt: ingestedAt, preview: preview,
            urgencyTier: urgencyTier, category: category, triageState: newState
        )
    }
}