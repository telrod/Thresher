//
//  Explanation.swift
//  Thresher
//
//  The bespoke shape returned by GET /messages/<id>/explain (NOT _message_json).
//  Per docs/api-contract-map.md: a standalone classification-reasoning object.
//  All fields are non-null here (the endpoint only exists when a classification
//  row exists) — but the endpoint 404s for unclassified mail, which the caller
//  handles by treating "explain" as optional (see APIClient.explain).
//
//  P3 note: the detail fetch already folds `explanation` into GET /messages/<id>,
//  so this endpoint is a secondary/refresh path. The Detail screen prefers the
//  folded text and only falls back to this for a richer structured breakdown.
//

import Foundation

struct Explanation: Codable, Hashable {
    let messageID: String
    let urgencyTier: Int
    let category: String
    let ruleMatches: [RuleMatch]   // may be [] (never absent on this endpoint)
    let explanation: String

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case urgencyTier = "urgency_tier"
        case category, explanation
        case ruleMatches = "rule_matches"
    }
}