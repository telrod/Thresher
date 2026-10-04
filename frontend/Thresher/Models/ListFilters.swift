//
//  ListFilters.swift
//  Thresher
//
//  Tier + date-range filters for the Message List (§4.1.1).
//
//  These are ORTHOGONAL to the D50 triage chips: the chip answers "what have I
//  done with it", these answer "which mail am I looking at". They AND together,
//  so "T4, older than 30 days, still Open" is one query — the backlog query the
//  dogfood log asked for.
//
//  Date windows are UI PRESETS that resolve to explicit ISO-8601 bounds
//  (`since`/`until`) at the API layer. Named windows deliberately do not exist
//  server-side: bounds compose and are testable, "last 7 days" is a label.
//
//  Search ignores all of this, exactly as it ignores the chip (P1 floor).
//

import Foundation

/// A relative date window. `nil` bounds mean "unbounded on that side".
enum DateWindow: String, CaseIterable, Identifiable, Sendable {
    case anyTime
    case lastDay
    case last7Days
    case last30Days
    /// The INVERSE window, and the reason this enum earns its keep: it is what
    /// makes triaging a backlog possible (filter to the fossils, then bulk Done).
    ///
    /// `olderThan2Weeks` (dogfood entry 24a) is the tightest of them and the one
    /// that matches D57's own recency band: everything below the fresh band is
    /// exactly what the ordering has already decided is stale. Its day count is
    /// NOT a literal — see `days(freshDays:)`.
    case olderThan2Weeks
    case olderThan30Days
    case olderThan90Days
    case olderThan1Year

    static let defaultsKey = "list.dateWindow"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anyTime:         "Any time"
        case .lastDay:         "Last 24 hours"
        case .last7Days:       "Last 7 days"
        case .last30Days:      "Last 30 days"
        case .olderThan2Weeks: "Older than 2 weeks"
        case .olderThan30Days: "Older than 30 days"
        case .olderThan90Days: "Older than 90 days"
        case .olderThan1Year:  "Older than 1 year"
        }
    }

    /// True for the "older than" windows — the ones that select a backlog
    /// rather than a recent slice. The UI uses this to explain what bulk Done
    /// is about to act on.
    var isBacklogWindow: Bool {
        switch self {
        case .olderThan2Weeks, .olderThan30Days, .olderThan90Days, .olderThan1Year: true
        default: false
        }
    }

    /// Days offset from now, or nil for unbounded.
    ///
    /// `freshDays` comes from the backend (`GET /preferences` → `fresh_days`,
    /// which serves D57's `FRESH_DAYS`). Only `.olderThan2Weeks` consumes it:
    /// that preset and the recency band are the same number, so binding it to
    /// the constant means they cannot drift, and OI29's later promotion to a
    /// real preference moves both at once. Every other window is its own
    /// literal, which is what it should be — "last 7 days" answers to nothing
    /// but itself.
    func days(freshDays: Int) -> Double? {
        switch self {
        case .anyTime:         nil
        case .lastDay:         1
        case .last7Days:       7
        case .last30Days:      30
        case .olderThan2Weeks: Double(freshDays)
        case .olderThan30Days: 30
        case .olderThan90Days: 90
        case .olderThan1Year:  365
        }
    }

    /// Resolve to (since, until) ISO-8601 bounds relative to `now`.
    /// `since` is the inclusive lower bound, `until` the exclusive upper one —
    /// matching the server contract. Recent windows set `since`; backlog
    /// windows set `until`, which is the same boundary read from the other side.
    func bounds(now: Date = Date(),
                freshDays: Int = Preferences.defaultFreshDays)
    -> (since: String?, until: String?) {
        guard let days = days(freshDays: freshDays) else { return (nil, nil) }
        let edge = now.addingTimeInterval(-days * 86_400)
        let stamp = ISO8601DateFormatter.listBound.string(from: edge)
        return isBacklogWindow ? (nil, stamp) : (stamp, nil)
    }
}

extension ISO8601DateFormatter {
    /// The bound format the list endpoint expects. Plain seconds precision —
    /// the server parses it with fromisoformat and compares via julianday.
    static let listBound: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// Tier selection. `nil` ⇒ every tier (the server omits the `tier` param).
/// Single-tier only, matching the backend's existing `tier=` contract; a
/// multi-tier selection would need the `states=`-style multi-value shape and is
/// deliberately not invented here.
enum TierFilter: Int, CaseIterable, Identifiable, Sendable {
    case tier1 = 1, tier2, tier3, tier4, tier5

    static let defaultsKey = "list.tierFilter"

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .tier1: "1 · Immediate"
        case .tier2: "2 · Today"
        case .tier3: "3 · This week"
        case .tier4: "4 · Whenever"
        case .tier5: "5 · Archive"
        }
    }

    var shortLabel: String { "T\(rawValue)" }
}
