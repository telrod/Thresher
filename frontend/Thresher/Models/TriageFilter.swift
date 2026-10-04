//
//  TriageFilter.swift
//  Thresher
//
//  D50 — triage-driven list visibility. The decided contract
//  (docs/design-gate-dogfood.md DG1), verbatim:
//   - chips: Open (default) · Needs action · Done · All, live counts each;
//   - Open = triage state New + Needs action (Acknowledged EXCLUDED — "seen,
//     nothing owed" counts as handled, an explicit sub-decision);
//   - All = everything; Ack renders normally; Done collapses into a bottom
//     disclosure;
//   - chip persists locally (UserDefaults, like tutorialSeen);
//   - search spans every state regardless of chip (P1 floor);
//   - tier-first ordering unchanged within any view.
//
//  Counts come from GET /messages/counts — STORE-WIDE by design: the list
//  endpoint paginates (limit cap 500) and the alpha store is 1,400+ messages,
//  so counting rendered rows would lie (the E10 reality check that decided
//  the mechanism).
//

import Foundation

/// The chip vocabulary, in display order.
enum TriageFilter: String, CaseIterable, Identifiable {
    case open
    case needsAction = "needs_action"
    case done
    case all

    static let defaultsKey = "list.triageFilter"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .open:        "Open"
        case .needsAction: "Needs action"
        case .done:        "Done"
        case .all:         "All"
        }
    }

    /// The `states=` filter this chip fetches with. `nil` ⇒ no filter (All).
    /// D50 amendment (the author, Session 26): Open INCLUDES "unclassified" (no
    /// classification row) — a stuck classify failure must be visible in the
    /// default view, not parked under All (P1). The server accepts the token
    /// on this read filter only.
    var states: [String]? {
        switch self {
        case .open:        ["new", "needs_action", "unclassified"]
        case .needsAction: ["needs_action"]
        case .done:        ["done"]
        case .all:         nil
        }
    }

    /// The chip's live count from the store-wide totals.
    func count(in counts: TriageCounts) -> Int {
        switch self {
        case .open:        counts.new + counts.needsAction + counts.unclassified
        case .needsAction: counts.needsAction
        case .done:        counts.done
        case .all:         counts.total
        }
    }
}

/// GET /messages/counts — store-wide totals per triage state; unclassified
/// mail is counted, never vanished (P1).
struct TriageCounts: Codable, Hashable, Sendable {
    var new: Int
    var acknowledged: Int
    var needsAction: Int
    var done: Int
    var unclassified: Int
    /// D51: the dock badge — triage-state-New Tier 1+2 (the Open view's
    /// urgent tail). Server-derived; adjusted locally on the E20 seam.
    var urgentNew: Int = 0

    var total: Int { new + acknowledged + needsAction + done + unclassified }

    enum CodingKeys: String, CodingKey {
        case new, acknowledged, done, unclassified
        case needsAction = "needs_action"
        case urgentNew = "urgent_new"
    }

    /// D50: keep chip counts honest between refresh ticks — an in-place triage
    /// (the E20 seam) moves one message between state buckets locally, the
    /// same transition the server just confirmed.
    mutating func move(from oldState: String?, to newState: String) {
        adjust(oldState, by: -1)
        adjust(newState, by: +1)
    }

    /// D51: keep the badge honest between ticks. Only a Tier 1/2 message
    /// entering or leaving triage-state New moves the urgent count.
    mutating func moveUrgent(tier: Int?, from oldState: String?, to newState: String) {
        guard let tier, tier <= 2 else { return }
        if oldState == "new" && newState != "new" { urgentNew = max(0, urgentNew - 1) }
        if oldState != "new" && newState == "new" { urgentNew += 1 }
    }

    private mutating func adjust(_ state: String?, by delta: Int) {
        switch state {
        case "new":          new = max(0, new + delta)
        case "acknowledged": acknowledged = max(0, acknowledged + delta)
        case "needs_action": needsAction = max(0, needsAction + delta)
        case "done":         done = max(0, done + delta)
        default:             unclassified = max(0, unclassified + delta)
        }
    }
}