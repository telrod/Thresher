//
//  Rule.swift
//  Thresher
//
//  The shapes behind the Classification Rules editor (Settings §4.1.3).
//
//  Per docs/api-contract-map.md `GET /rules` (and confirmed by running the live
//  backend): the rules editor MUST be fed by `GET /rules?include_disabled=true`,
//  or a toggled-off rule vanishes and can never be re-enabled from the UI
//  (trap §1.1).
//
//  ⚠️ READ/WRITE SHAPE DIVERGENCE (trap §1.2 — confirmed by running): in the
//  `GET /rules` payload `enabled` is an INT (0/1), but `POST`/`PUT /rules` bodies
//  take a real JSON BOOL. So the read model (`Rule`) carries `enabled: Int` and
//  the write DTO (`RuleWrite`) carries `enabled: Bool`. They are deliberately
//  SEPARATE types — modeling one round-tripping struct would mis-encode the wire.
//
//  field/operator/set_category vocabularies are fixed (map §"GET /rules"). We
//  keep `field`/`operator`/`value` as validated Strings on the wire model and
//  expose enum *views* (with an explicit `.unknown` case for forward-compat) so a
//  future server-side vocabulary addition can't crash decoding.
//

import Foundation

// MARK: - Read model (GET /rules element)

/// One row from `GET /rules` — the full `rules` table row as the backend
/// serializes it (`dict(row)` off `SELECT *`). `enabled` is the 0/1 INT the wire
/// sends; `set_tier`/`set_category` are nullable (the CHECK only requires ≥1
/// non-null, trap §1.3).
struct Rule: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let ruleName: String
    let priority: Int
    let enabled: Int            // ⚠️ 0/1 INT on read (bool on write — see RuleWrite)
    let field: String
    let `operator`: String
    let value: String
    let setTier: Int?           // nullable; ∈ 1–5 when present
    let setCategory: String?    // nullable; work|personal when present
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case id, priority, enabled, field, value, notes
        case ruleName = "rule_name"
        case `operator` = "operator"
        case setTier = "set_tier"
        case setCategory = "set_category"
    }

    // ── Domain views over the raw fields ───────────────────────────────────

    /// `enabled` is stored as 0/1 int on the wire; this is the bool the UI binds.
    var isEnabled: Bool { enabled != 0 }

    /// `nil` ⇒ this rule sets no tier (only a category). Out-of-range collapses
    /// to nil so a future tier value can't crash the view.
    var tier: Tier? { Tier(raw: setTier) }

    /// The category this rule sets, or nil if it only sets a tier. Note: this is
    /// NOT the total `Category(raw:)` — a rule with no `set_category` should show
    /// "no category effect", not `.unknown`. So we keep it optional.
    var categoryEffect: Category? {
        guard let setCategory else { return nil }
        return Category(rawValue: setCategory)
    }

    var fieldValue: RuleField { RuleField(raw: field) }
    var operatorValue: RuleOperator { RuleOperator(raw: `operator`) }
}

// MARK: - Write DTO (POST/PUT /rules body)

/// The body for `POST /rules` (create) and `PUT /rules/<id>` (patch).
///
/// ⚠️ `enabled` is a real JSON **bool** here (trap §1.2) — the opposite of the
/// 0/1 int the read model decodes.
///
/// PATCH SEMANTICS (trap §1.3): on `PUT`, only the keys present in the encoded
/// body are written; omitted keys leave the existing column intact. That has a
/// sharp edge for the effects — "remove a rule's tier" means sending the
/// *remaining* effect, NOT blanking both. The both-null guard (server-side)
/// rejects a merged result with neither `set_tier` nor `set_category`.
///
/// All fields are optional so the same type serves both create (send all
/// required) and patch (send a subset). `Encodable`-only — it is never decoded.
struct RuleWrite: Encodable, Sendable {
    var ruleName: String?
    var field: String?
    var `operator`: String?
    var value: String?
    /// Use `.some(nil)` to explicitly clear one effect (sends JSON `null`);
    /// `.none` (the default) omits the key entirely (patch leaves it intact).
    var setTier: Int?? = .none
    var setCategory: String?? = .none
    var priority: Int?
    var enabled: Bool?          // ⚠️ real bool on write (int on read)
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case priority, enabled, field, value, notes
        case ruleName = "rule_name"
        case `operator` = "operator"
        case setTier = "set_tier"
        case setCategory = "set_category"
    }

    /// Hand-rolled so a doubly-optional `.some(nil)` encodes an explicit JSON
    /// `null` (clear that one effect) while `.none` omits the key (patch leaves
    /// it intact). The default `Encodable` synthesis can't express that
    /// distinction for `Int??`/`String??`.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(ruleName, forKey: .ruleName)
        try c.encodeIfPresent(field, forKey: .field)
        try c.encodeIfPresent(`operator`, forKey: .operator)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(priority, forKey: .priority)
        try c.encodeIfPresent(enabled, forKey: .enabled)
        try c.encodeIfPresent(notes, forKey: .notes)
        // Doubly-optional effects: .some(x) → encode x (incl. explicit null);
        // .none → omit the key (patch-preserve).
        if let setTier { try c.encode(setTier, forKey: .setTier) }       // x may be nil → JSON null
        if let setCategory { try c.encode(setCategory, forKey: .setCategory) }
    }
}

// MARK: - Reorder (D44 batch endpoint)

/// Body for `PUT /rules/reorder` (D44). `ordered_ids` is the COMPLETE new order
/// of ALL rule ids (enabled + disabled) — position is priority; the client never
/// computes a priority number, so the wire format can't express a gap or a tie.
/// `Encodable`-only.
struct ReorderBody: Encodable, Sendable {
    let orderedIds: [Int]

    enum CodingKeys: String, CodingKey {
        case orderedIds = "ordered_ids"
    }
}

/// `PUT /rules/reorder` success (`200`) → `{rules:[…]}` — the full reordered set,
/// same element shape as `GET /rules?include_disabled=true`, so the client
/// re-renders from the response without a second fetch. (400/409 don't decode to
/// this; they surface as `APIError.http` with the id-naming body.)
struct RulesReorderResponse: Decodable, Sendable {
    let rules: [Rule]
}

// MARK: - Fixed vocabularies (enum views with forward-compat unknown)

/// The `field` vocabulary (map §"GET /rules"). `.unknown` keeps decoding total
/// if the server adds a field type later (P3: the editor still shows the rule).
enum RuleField: String, CaseIterable, Sendable {
    case senderEmail = "sender_email"
    case senderDomain = "sender_domain"
    case subject
    case body
    case senderGroup = "sender_group"
    case unknown

    /// `.unknown` is excluded from the picker (it's only a decode fallback).
    static var selectable: [RuleField] { allCases.filter { $0 != .unknown } }

    init(raw: String) { self = RuleField(rawValue: raw) ?? .unknown }

    var label: String {
        switch self {
        case .senderEmail:  return "Sender email"
        case .senderDomain: return "Sender domain"
        case .subject:      return "Subject"
        case .body:         return "Body"
        case .senderGroup:  return "Sender group"
        case .unknown:      return "Unknown"
        }
    }
}

/// The `operator` vocabulary (map §"GET /rules").
enum RuleOperator: String, CaseIterable, Sendable {
    case equals
    case contains
    case startsWith = "starts_with"
    case endsWith = "ends_with"
    case matchesGroup = "matches_group"
    case unknown

    static var selectable: [RuleOperator] { allCases.filter { $0 != .unknown } }

    /// E22: the field/operator pairing contract, mirrored from the backend
    /// (`_valid_operators_for_field`). `matches_group` is meaningful ONLY
    /// against `sender_group`; any other combo silently never matches in the
    /// engine. The editor's operator picker offers exactly this set.
    static func valid(for field: RuleField) -> [RuleOperator] {
        if field == .senderGroup { return [.matchesGroup] }
        return selectable.filter { $0 != .matchesGroup }
    }

    init(raw: String) { self = RuleOperator(rawValue: raw) ?? .unknown }

    var label: String {
        switch self {
        case .equals:       return "equals"
        case .contains:     return "contains"
        case .startsWith:   return "starts with"
        case .endsWith:     return "ends with"
        case .matchesGroup: return "matches group"
        case .unknown:      return "unknown"
        }
    }
}