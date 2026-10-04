//
//  MessagePage.swift
//  Thresher
//
//  One page of the message list, plus the total for the filter set that
//  produced it (OI21).
//
//  The list was ALWAYS a window onto the store — `limit` defaults to 100
//  server-side and the client never paginated — but nothing said so, so every
//  view implied it was showing everything. That is what manufactured the
//  phantom OI20: a Done message "missing from All" was merely on page two, and
//  a gate item plus a workorder part were spent on a defect that did not exist.
//
//  Carrying the total makes the window's size a fact the UI can state.
//

import Foundation

/// The filter set for one list fetch. Everything ANDs together server-side.
struct ListQuery: Equatable, Sendable {
    /// D50 triage chip states (`nil` ⇒ All).
    var states: [String]?
    /// Single urgency tier (`nil` ⇒ every tier).
    var tier: Int?
    /// ISO-8601 inclusive lower bound on received_at.
    var since: String?
    /// ISO-8601 exclusive upper bound on received_at ("older than X").
    var until: String?
    var limit: Int = ListQuery.pageSize
    var offset: Int = 0

    /// Rows per page. The server caps `limit` at 500; staying well under keeps
    /// each page fast to fetch and render on a 4,900-message store.
    static let pageSize = 100

    /// The same filters at the next page's offset.
    func nextPage(after loaded: Int) -> ListQuery {
        var next = self
        next.offset = loaded
        return next
    }
}

/// A page of rows plus the honest total for its filter set.
struct MessagePage: Equatable, Sendable {
    var rows: [MessageListRow]
    /// Total matching THIS filter set store-wide — not the row count.
    var total: Int
    /// The offset these rows started at.
    var offset: Int

    /// Is there more beyond what has been loaded so far?
    static func hasMore(loaded: Int, total: Int) -> Bool { loaded < total }
}

/// POST /messages/triage-bulk response.
struct BulkTriageResult: Codable, Equatable, Sendable {
    let updated: Int
    let triageState: String
    /// How many source messages were marked read in the mailbox. Zero unless
    /// write-back was explicitly requested for this bulk call (P5).
    let wroteBack: Int
    /// True when write-back was deliberately skipped — the bulk default.
    /// Surfaced so the UI can be honest that the mailbox was left alone rather
    /// than leaving the user to assume either way.
    let writeBackSkipped: Bool
    /// Filter-scoped mode only (D59): how many messages the filter matched, and
    /// how many of those already held the target state. `nil` in id mode.
    ///
    /// `updated` alone cannot distinguish "1,594 moved" from "1,594 matched,
    /// 900 of which were already Done" — SQLite counts a no-op UPDATE as a
    /// changed row.
    let matching: Int?
    let alreadyInState: Int?

    enum CodingKeys: String, CodingKey {
        case updated
        case triageState = "triage_state"
        case wroteBack = "wrote_back"
        case writeBackSkipped = "write_back_skipped"
        case matching
        case alreadyInState = "already_in_state"
    }

    /// The two filter-mode fields default to `nil` — they are genuinely absent
    /// from an id-mode response, so callers constructing an id-mode result say
    /// nothing about them rather than inventing a zero.
    init(updated: Int, triageState: String, wroteBack: Int,
         writeBackSkipped: Bool, matching: Int? = nil,
         alreadyInState: Int? = nil) {
        self.updated = updated
        self.triageState = triageState
        self.wroteBack = wroteBack
        self.writeBackSkipped = writeBackSkipped
        self.matching = matching
        self.alreadyInState = alreadyInState
    }
}

/// The set a filter-scoped bulk will act on (D59), frozen at the moment the
/// user chose it.
///
/// **`until` is the race guard, and it is captured HERE rather than at send.**
/// A poll can land between the user reading "this will mark 1,594 messages
/// Done" and their confirming it. Without a frozen upper bound, mail that
/// arrived in that window is marked Done having never been seen — nothing is
/// deleted, so it is not a P1 violation, but it is the same shape of harm and
/// it is silent. Anything ingested after this instant has `received_at > until`
/// and is excluded by construction.
///
/// The server REQUIRES `until` in filter mode and refuses to default it: a
/// server-side `now` would be evaluated at execute time, which is precisely the
/// race this closes.
struct BulkFilterScope: Equatable, Sendable {
    var states: [String]?
    var tier: Int?
    var since: String?
    /// Frozen upper bound. Never re-derived — see the type's note.
    var until: String
    /// The count shown to the user when the scope was captured, so the result
    /// can be compared against what they were actually promised.
    var previewedCount: Int

    /// Capture the scope for the currently-displayed filter set.
    ///
    /// `now` is injectable for tests only. A backlog window already carries its
    /// own `until`; keep whichever bound is TIGHTER, since the window's edge is
    /// the user's instruction and the capture instant is the race guard — both
    /// must hold, so neither may relax the other.
    init(query: ListQuery, previewedCount: Int, now: Date = Date()) {
        self.states = query.states
        self.tier = query.tier
        self.since = query.since
        self.previewedCount = previewedCount
        // Compare as DATES, never as strings. D57 hit the text-compare trap
        // twice at the SQL layer; the same reasoning applies here, and a
        // string min() would silently depend on both bounds sharing a
        // zero-padded UTC spelling.
        let windowDate = query.until.flatMap(ISO8601DateFormatter.listBound.date(from:))
        let tighter = windowDate.map { Swift.min($0, now) } ?? now
        self.until = ISO8601DateFormatter.listBound.string(from: tighter)
    }
}
