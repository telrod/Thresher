//
//  MessageDetail.swift
//  Thresher
//
//  The object shape returned by GET /messages/<id> — the OTHER serializer shape
//  (the E10 divergence the contract map documents). This is a SIBLING of
//  MessageListRow, NOT a superset: the two endpoints run different queries and
//  return different column sets.
//
//  Per docs/api-contract-map.md `GET /messages/<id>`:
//   - carries `body_plain` / `body_html` (the list shape does NOT)
//   - carries a folded-in `explanation` string (null when unclassified) — this
//     is what satisfies P3 in a single fetch, no separate round-trip
//   - `rule_matches` is a CONDITIONAL KEY: present only when a classification
//     row exists AND it's non-empty; the key is *absent* otherwise (not null).
//     Decoded as optional; absent and empty are treated the same.
//   - `preview` is ALWAYS null here (`messages` has no preview column; the detail
//     query is `SELECT m.*`). Modeled optional, never relied on.
//   - the three classification fields are nullable (LEFT JOIN; unclassified mail
//     is a real state, P1) — surfaced through the shared Tier?/Category/TriageState
//     enums, exactly as the list row does.
//

import Foundation

/// One entry in the classification audit trail (`rule_matches`). Per the map the
/// elements are dicts `{rule_id, rule_name, field, value}` — NOT strings.
///
/// E19: `rule_id` is NULL on the sender-override invariant record — the engine
/// appends it in Step 3 as an invariant, not a rule. It carries the same
/// rule_name/field/value keys (the name is self-describing, group included)
/// plus `overrode_tier`: the tier the floor overrode (itself null when no rule
/// had set one). Every field here except the four base keys is conditional.
struct RuleMatch: Codable, Identifiable, Hashable {
    let ruleID: Int?
    let ruleName: String
    let field: String
    let value: String
    /// Override record only: the tier the group floor overrode (null/absent
    /// when nothing had set a tier before the invariant ran).
    let overrodeTier: Int?

    /// The sender-override invariant record (P3: shown, never hidden).
    var isOverride: Bool { ruleID == nil }

    /// Stable identity without fabricating a fake Int that could collide with a
    /// real rule id: rule records key by id; the override record keys by its
    /// self-describing name (group-unique within one classification) plus the
    /// overrode tier as a disambiguator.
    var id: String {
        if let ruleID { return "rule-\(ruleID)" }
        return "invariant-\(ruleName)-\(overrodeTier.map(String.init) ?? "none")"
    }

    /// The one-line audit rendering for the "Why this tier?" panel. The override
    /// record's name already names the group; add where the tier was raised from
    /// when known, instead of the meaningless "field value" tail.
    var displayLine: String {
        guard isOverride else { return "\(ruleName) — \(field) \(value)" }
        if let overrodeTier { return "\(ruleName) — raised from T\(overrodeTier)" }
        return ruleName
    }

    enum CodingKeys: String, CodingKey {
        case ruleID = "rule_id"
        case ruleName = "rule_name"
        case overrodeTier = "overrode_tier"
        case field, value
    }
}

struct MessageDetail: Codable, Identifiable, Hashable {
    let id: String
    let account: String
    let threadID: String?
    let senderName: String?
    let senderEmail: String
    let subject: String?
    let receivedAt: String        // ISO-8601
    let ingestedAt: String
    let preview: String?          // always nil on detail; modeled optional, never used
    let bodyPlain: String?        // detail only
    let bodyHTML: String?         // detail only
    let urgencyTier: Int?         // nullable: unclassified
    let category: String?         // nullable
    let triageState: String?      // nullable
    let explanation: String?      // P3: folded-in reasoning; nil when unclassified
    let ruleMatches: [RuleMatch]? // CONDITIONAL key — absent when empty (not null)
    /// D48 (closes OI4): the RFC822 Message-ID from raw_headers — detail only,
    /// null when the header is absent (the Gmail control stays disabled).
    let rfc822MessageID: String?
    /// D52 part D: when this classification was made, so the panel can date it.
    let classifiedAt: String?
    /// D52: non-nil ⇒ the classification was RE-run (invariant 3's dated audit,
    /// with no versioning). nil = classified once at ingest, the default lifecycle.
    let reclassifiedAt: String?
    /// D52 part D: rules KNOWN to have changed since this classification. Rules with
    /// no recorded edit time contribute zero, so the copy must say "known", not
    /// "might have" — see `stalenessNote`.
    let rulesChangedSince: Int?

    enum CodingKeys: String, CodingKey {
        case id, account, subject, preview, category, explanation
        case threadID = "thread_id"
        case senderName = "sender_name"
        case senderEmail = "sender_email"
        case receivedAt = "received_at"
        case ingestedAt = "ingested_at"
        case bodyPlain = "body_plain"
        case bodyHTML = "body_html"
        case urgencyTier = "urgency_tier"
        case triageState = "triage_state"
        case ruleMatches = "rule_matches"
        case rfc822MessageID = "rfc822_message_id"
        case classifiedAt = "classified_at"
        case reclassifiedAt = "reclassified_at"
        case rulesChangedSince = "rules_changed_since"
    }

    // ── D52: the dated classification line + staleness copy (part D) ───────

    /// "Classified <date>" or "Reclassified <date>" — the fossil made legible.
    /// nil when unclassified (the panel already says so in its own words).
    var classificationDateLine: String? {
        let stamp = reclassifiedAt ?? classifiedAt
        guard let stamp, let date = MessageDetail.parseISO(stamp) else { return nil }
        let shown = MessageDetail.displayFormatter.string(from: date)
        return reclassifiedAt != nil ? "Reclassified \(shown)" : "Classified \(shown)"
    }

    /// Parse an ISO-8601 stamp with OR without fractional seconds. The backend writes
    /// `datetime.now(timezone.utc).isoformat()`, which includes microseconds — but
    /// only when they're non-zero, so a strict fractional-seconds parser silently
    /// fails roughly one time in a million and drops the date line.
    static func parseISO(_ s: String) -> Date? {
        isoFormatter.date(from: s) ?? isoFormatterNoFraction.date(from: s)
    }

    /// The staleness line, or nil when nothing is known to have changed. Wording is
    /// deliberately about rules that HAVE changed, not about what the app will do —
    /// reclassification is never automatic (invariant 4).
    var stalenessNote: String? {
        guard let n = rulesChangedSince, n > 0 else { return nil }
        return n == 1 ? "1 rule has changed since" : "\(n) rules have changed since"
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // ── Domain views over the nullable raw fields (shared enums) ───────────

    /// `nil` ⇒ unclassified (render an "Unclassified" badge — P1).
    var tier: Tier? { Tier(raw: urgencyTier) }
    var categoryValue: Category { Category(raw: category) }
    var triage: TriageState? { TriageState(raw: triageState) }

    /// Sender display: prefer the name, fall back to the (never-null) email.
    var displaySender: String {
        if let senderName, !senderName.isEmpty { return senderName }
        return senderEmail
    }

    var displaySubject: String {
        if let subject, !subject.isEmpty { return subject }
        return "(no subject)"
    }

    /// The best plain text to show: prefer body_plain; both can be nil.
    var displayBody: String? {
        if let bodyPlain, !bodyPlain.isEmpty { return bodyPlain }
        return nil
    }

    /// Normalize the conditional `rule_matches` key: absent and empty are the
    /// same to the UI.
    var matches: [RuleMatch] { ruleMatches ?? [] }

    /// Has this message been classified? (Detail returns explanation:null and
    /// nil tier for unclassified mail; this is the single source of truth the
    /// view uses to decide the explain section's content.)
    var isClassified: Bool { urgencyTier != nil }

    /// D48: the Gmail-web deep link — rfc822msgid: search, works regardless of
    /// local mail client. nil when the Message-ID is absent (control disabled;
    /// flagged-not-faked, the OI4 presentation).
    var gmailWebURL: URL? {
        guard let rfc822MessageID, !rfc822MessageID.isEmpty,
              let encoded = rfc822MessageID.addingPercentEncoding(
                  withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "https://mail.google.com/mail/u/0/#search/rfc822msgid:\(encoded)")
    }
}
// ── D52: reclassify payloads ─────────────────────────────────────────────────

/// `POST /messages/<id>/reclassify` — the fresh classification, returned so the
/// caller can patch list + detail in place without a refetch (the E20 seam).
struct ReclassifyResult: Codable, Hashable, Sendable {
    let messageID: String
    let urgencyTier: Int
    let category: String
    /// Invariant 1: the server sends back the PRESERVED triage state, so the client
    /// can assert rather than assume that reclassification didn't reset it.
    let triageState: String
    let classifiedAt: String
    let reclassifiedAt: String
    let changed: Bool
    let previousTier: Int?
    let previousCategory: String?
    let rulesChangedSince: Int?

    enum CodingKeys: String, CodingKey {
        case category, changed
        case messageID = "message_id"
        case urgencyTier = "urgency_tier"
        case triageState = "triage_state"
        case classifiedAt = "classified_at"
        case reclassifiedAt = "reclassified_at"
        case previousTier = "previous_tier"
        case previousCategory = "previous_category"
        case rulesChangedSince = "rules_changed_since"
    }
}

/// `POST /messages/reclassify-all` — the run summary the Settings UI reports.
struct ReclassifySummary: Codable, Hashable, Sendable {
    let counted: Int
    let changed: Int
    let unchanged: Int
    let errors: Int

    /// One line a human can act on. Errors are named, never swallowed (P1: a
    /// message that failed to classify is still stored, and the user should know).
    var summaryLine: String {
        var s = "Reclassified \(counted) message\(counted == 1 ? "" : "s") — "
            + "\(changed) changed, \(unchanged) unchanged"
        if errors > 0 { s += ", \(errors) failed" }
        return s
    }
}
