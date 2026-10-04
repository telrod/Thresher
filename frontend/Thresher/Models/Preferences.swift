//
//  Preferences.swift
//  Thresher
//
//  GET /preferences returns a FLAT {key: value} map of STRINGS (per
//  docs/api-contract-map.md) — not a list, not typed. Values are stringly-typed
//  even when semantically int/bool, so the Swift layer coerces.
//
//  S12 added `poll_interval_minutes` — the D34 background-refresh cadence. The
//  Settings screen (§4.1.3) now reads the rest of the generic keys too
//  (operating mode, digest time, ceiling, write-back) via the typed
//  `GeneralPrefs` view below — the OTHER half of the two-surface split (trap
//  §1.4). Quiet-hours + audio do NOT live here; they bind to the typed
//  `/preferences/notifications` surface (NotificationPrefs.swift).
//

import Foundation

/// A decoded `GET /preferences` response: a flat string→string map plus typed
/// accessors for the keys we care about.
struct Preferences: Codable, Sendable {
    let values: [String: String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        values = try container.decode([String: String].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    init(values: [String: String]) { self.values = values }

    // ── Typed coercions ───────────────────────────────────────────────────

    /// D34: the background-refresh cadence, in minutes. Coerced from the
    /// `poll_interval_minutes` string; falls back to a sane default if the key
    /// is absent or unparseable.
    var pollIntervalMinutes: Int {
        guard let raw = values["poll_interval_minutes"], let n = Int(raw), n > 0 else {
            return Preferences.defaultPollIntervalMinutes
        }
        return n
    }

    var pollIntervalSeconds: TimeInterval { TimeInterval(pollIntervalMinutes * 60) }

    static let defaultPollIntervalMinutes = 5

    /// D57's fresh recency-band edge, in days, served by `GET /preferences`.
    ///
    /// The "older than 2 weeks" list preset and D57's band edge are THE SAME
    /// NUMBER expressed twice, and OI29 flags both as preference candidates.
    /// Reading it from the backend means they cannot drift apart, and promoting
    /// it to a real stored preference later moves both at once with no client
    /// change. Falls back to the shipped constant if the key is absent (an
    /// older backend) — a fallback that matches today's server value rather
    /// than inventing a different window.
    var freshDays: Int {
        guard let raw = values["fresh_days"], let n = Int(raw), n > 0 else {
            return Preferences.defaultFreshDays
        }
        return n
    }

    /// Mirrors `FRESH_DAYS` in `backend/db/database.py`.
    static let defaultFreshDays = 14
}

// MARK: - GeneralPrefs (typed view over the stringly-typed generic map)

/// Operating mode (D-level: affects surfacing, not classification). Focus /
/// Catch-up; manual toggle. `.unknown` keeps decoding total if the stored string
/// is ever something else.
enum OperatingMode: String, CaseIterable, Sendable {
    case focus
    case catchUp = "catch-up"
    case unknown

    static var selectable: [OperatingMode] { allCases.filter { $0 != .unknown } }

    init(raw: String?) { self = OperatingMode(rawValue: raw ?? "") ?? .unknown }

    var label: String {
        switch self {
        case .focus:   return "Focus"
        case .catchUp: return "Catch-up"
        case .unknown: return "Unknown"
        }
    }
}

/// A typed read-only view that coerces the Settings-relevant keys out of the
/// generic `[String:String]` map (trap §1.4 — these keys live ONLY here, not on
/// the typed `/preferences/notifications` surface). Writes go back one key at a
/// time via `PUT /preferences/<key>` (the generic upsert coerces to string), so
/// this is a view, not a write DTO — the raw map is the round-trip source of
/// truth (P4: one source of truth).
struct GeneralPrefs: Sendable {
    let raw: [String: String]

    init(_ preferences: Preferences) { self.raw = preferences.values }

    // Storage keys (also the path segment for PUT /preferences/<key>).
    static let operatingModeKey = "operating_mode"
    static let dailyCeilingKey = "daily_ceiling"
    static let digestTimeKey = "digest_time"
    static let pollIntervalKey = "poll_interval_minutes"
    static let writebackKey = "writeback_enabled"

    var operatingMode: OperatingMode { OperatingMode(raw: raw[Self.operatingModeKey]) }

    /// Surfacing ceiling — a count; falls back to nil if absent/unparseable so
    /// the UI can show "unset" rather than a fabricated number.
    var dailyCeiling: Int? {
        guard let s = raw[Self.dailyCeilingKey] else { return nil }
        return Int(s)
    }

    /// Digest send time as the stored `"HH:MM"` string (digest scheduler key).
    var digestTime: String? { raw[Self.digestTimeKey] }

    var pollIntervalMinutes: Int? {
        guard let s = raw[Self.pollIntervalKey] else { return nil }
        return Int(s)
    }

    /// Write-back opt-in (P5). Generic map stores `"true"`/`"false"` strings.
    var writebackEnabled: Bool { raw[Self.writebackKey] == "true" }
}