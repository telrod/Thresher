//
//  Classification.swift
//  Thresher
//
//  Domain enums over the nullable classification fields the API returns.
//
//  Per docs/api-contract-map.md, the three classification columns
//  (urgency_tier, category, triage_state) all arrive via a LEFT JOIN and are
//  ALL nullable: a message persisted before classification (P1) has none of
//  them. The Codable models keep the raw optionals (Int?/String?); these enums
//  are *computed accessors* so a missing or unrecognized value can never crash
//  decoding — it just maps to the explicit "unclassified"/"unknown" case the
//  UI renders.
//

import Foundation

/// Urgency tier 1 (Immediate) … 5 (Archive). `nil` on the model means the
/// message has not been classified yet — a real state (P1), shown as a distinct
/// "Unclassified" badge rather than hidden or defaulted to a tier.
enum Tier: Int, CaseIterable {
    case one = 1, two = 2, three = 3, four = 4, five = 5

    /// Map a raw, possibly-nil/out-of-range API value to a Tier, or nil.
    init?(raw: Int?) {
        guard let raw, let t = Tier(rawValue: raw) else { return nil }
        self = t
    }

    var label: String {
        switch self {
        case .one:   return "Immediate"
        case .two:   return "Today"
        case .three: return "Digest"
        case .four:  return "Low"
        case .five:  return "Archive"
        }
    }

    /// Short text for the badge (the numeral the spec's tier model uses).
    var shortLabel: String { "T\(rawValue)" }
}

/// Work / Personal category tag. The API also allows "unknown"; any
/// unrecognized or missing value collapses to `.unknown` so the UI is total.
enum Category: String, CaseIterable {
    case work, personal, unknown

    init(raw: String?) {
        guard let raw, let c = Category(rawValue: raw) else { self = .unknown; return }
        self = c
    }

    var label: String {
        switch self {
        case .work:     return "Work"
        case .personal: return "Personal"
        case .unknown:  return "Unknown"
        }
    }
}

/// Triage state machine: New → Acknowledged → Needs Action → Done.
/// Note the wire value "needs_action" (snake_case) maps to `.needsAction`.
/// A missing value (unclassified message) is represented as `nil` at the call
/// site, not a synthetic case here.
enum TriageState: String, CaseIterable {
    case new
    case acknowledged
    case needsAction = "needs_action"
    case done

    init?(raw: String?) {
        guard let raw, let s = TriageState(rawValue: raw) else { return nil }
        self = s
    }

    var label: String {
        switch self {
        case .new:         return "New"
        case .acknowledged: return "Acknowledged"
        case .needsAction: return "Needs Action"
        case .done:        return "Done"
        }
    }
}