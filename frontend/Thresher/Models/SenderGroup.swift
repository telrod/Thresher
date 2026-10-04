//
//  SenderGroup.swift
//  Thresher
//
//  The shapes behind the Sender Groups editor (Settings §4.1.3).
//
//  Per docs/api-contract-map.md `GET /rules` `sender_groups` element (and
//  confirmed against the live backend): the full `sender_groups` table row,
//  serialized as `dict(row)` off `SELECT *`. Unlike rules, sender groups have NO
//  read/write divergence — `urgency_floor` is an int both ways and there is no
//  `enabled` flag. So the read model doubles as the create/patch body via a thin
//  write DTO that only differs in optionality (for PUT patch semantics).
//
//  Validation (client-side, server enforces too): non-empty `email_pattern`,
//  `urgency_floor` ∈ 1–5.
//

import Foundation

/// One row from `GET /rules` `sender_groups`. `urgency_floor` is the
/// sender-override floor tier (the Sender override invariant: a known sender is
/// never shown below their group's floor).
struct SenderGroup: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let groupName: String
    /// DEPRECATED by D53 (two-step): the server still sends it, mirroring the
    /// first pattern, so a rollback to the previous binary keeps working. Read
    /// `patterns` instead — this is kept only to decode the payload faithfully.
    let emailPattern: String
    /// D53: a group is a named set of address patterns sharing ONE floor tier; a
    /// sender matching ANY pattern is in the group. Decoded with a fallback to
    /// `email_pattern` so the app still works against an unmigrated backend
    /// (the same two-step deprecation the server side implements).
    let patterns: [String]
    let urgencyFloor: Int       // ∈ 1–5
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case id, notes, patterns
        case groupName = "group_name"
        case emailPattern = "email_pattern"
        case urgencyFloor = "urgency_floor"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        groupName = try c.decode(String.self, forKey: .groupName)
        emailPattern = try c.decodeIfPresent(String.self, forKey: .emailPattern) ?? ""
        urgencyFloor = try c.decode(Int.self, forKey: .urgencyFloor)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        let decoded = try c.decodeIfPresent([String].self, forKey: .patterns) ?? []
        // Fall back to the legacy single pattern rather than rendering a group with
        // no patterns: an unmigrated backend still has members, and showing none
        // would be a lie about the user's config.
        patterns = decoded.isEmpty
            ? (emailPattern.isEmpty ? [] : [emailPattern])
            : decoded
    }

    /// Memberwise init, for tests and previews (the custom `init(from:)` above
    /// suppresses the synthesized one).
    init(id: Int, groupName: String, emailPattern: String = "",
         patterns: [String] = [], urgencyFloor: Int, notes: String? = nil) {
        self.id = id
        self.groupName = groupName
        self.emailPattern = emailPattern
        self.patterns = patterns.isEmpty && !emailPattern.isEmpty ? [emailPattern] : patterns
        self.urgencyFloor = urgencyFloor
        self.notes = notes
    }

    /// The floor as a Tier view; nil only if the server ever returns out-of-range
    /// (kept total so the editor can't crash on bad data).
    var floorTier: Tier? { Tier(raw: urgencyFloor) }
}

/// Body for `POST /sender-groups` (create) and `PUT /sender-groups/<id>`
/// (patch). Patch semantics: omitted keys are left intact. All-optional so the
/// one type serves create (send all required) and patch (a subset).
/// `Encodable`-only — never decoded.
struct SenderGroupWrite: Encodable, Sendable {
    var groupName: String?
    /// D53: send `patterns` — the server REPLACES the whole set atomically (the
    /// D44 shape), so the client never diffs patterns or issues per-pattern calls.
    /// Omitting it leaves the existing set untouched (a name-or-floor-only edit).
    var patterns: [String]?
    var urgencyFloor: Int?
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case notes, patterns
        case groupName = "group_name"
        case urgencyFloor = "urgency_floor"
    }
}