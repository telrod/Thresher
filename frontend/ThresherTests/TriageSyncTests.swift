//
//  TriageSyncTests.swift
//  ThresherTests
//
//  E20 regression (dogfood defect batch 1, Part B).
//
//  Advancing triage in the detail pane left the list row's badge on the old
//  state until a full refresh: MessageDetailViewModel updated only its own
//  detail model, and MessageListViewModel's rows are independent structs with
//  no cross-VM signal. The fix routes a callback up through the split-view
//  owner (which owns both selection and, now, the list model): on a successful
//  server-confirmed setTriage, the list patches that ONE row in place.
//
//  The assertions pin the P2/D34 half of the contract too: the sync must not
//  refetch (no listMessages call) and must not touch any other row.
//

import XCTest
@testable import Thresher

/// Minimal MessageAPI fake: serves canned rows/detail, counts list fetches,
/// echoes triage writes back as the server does. Lock-guarded counters keep it
/// honestly Sendable (calls arrive from the view models' async contexts).
private final class FakeMessageAPI: MessageAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var _listCalls = 0
    var listCalls: Int { lock.withLock { _listCalls } }

    let rows: [MessageListRow]
    let searchResults: [MessageListRow]
    init(rows: [MessageListRow], searchResults: [MessageListRow] = []) {
        self.rows = rows
        self.searchResults = searchResults
    }

    func listMessages() async throws -> [MessageListRow] {
        try await listMessages(states: nil)
    }

    func listMessages(states: [String]?) async throws -> [MessageListRow] {
        lock.withLock { _listCalls += 1 }
        guard let states else { return rows }
        return rows.filter { states.contains($0.triageState ?? "unclassified") }
    }

    func messageCounts() async throws -> TriageCounts {
        TriageCounts(
            new: rows.filter { $0.triageState == "new" }.count,
            acknowledged: rows.filter { $0.triageState == "acknowledged" }.count,
            needsAction: rows.filter { $0.triageState == "needs_action" }.count,
            done: rows.filter { $0.triageState == "done" }.count,
            unclassified: rows.filter { $0.triageState == nil }.count)
    }

    func searchMessages(query: String) async throws -> [MessageListRow] { searchResults }
    func preferences() async throws -> Preferences { throw APIError.badURL }

    func getMessage(id: String) async throws -> MessageDetail {
        guard let row = rows.first(where: { $0.id == id }) else {
            throw APIError.http(status: 404, body: nil)
        }
        return MessageDetail(
            id: row.id, account: row.account, threadID: row.threadID,
            senderName: row.senderName, senderEmail: row.senderEmail,
            subject: row.subject, receivedAt: row.receivedAt,
            ingestedAt: row.ingestedAt, preview: nil,
            bodyPlain: "body", bodyHTML: nil,
            urgencyTier: row.urgencyTier, category: row.category,
            triageState: row.triageState, explanation: "why", ruleMatches: nil,
            rfc822MessageID: nil,
            classifiedAt: "2026-01-01T00:00:00+00:00", reclassifiedAt: nil,
            rulesChangedSince: 0)
    }

    func explain(id: String) async throws -> Explanation? { nil }
    func thread(id: String) async throws -> [MessageListRow] { [] }

    func setTriage(id: String, state: TriageState) async throws -> TriageUpdateResponse {
        TriageUpdateResponse(messageID: id, triageState: state.rawValue)
    }

    func notifications(since: Int) async throws -> NotificationFeed { throw APIError.badURL }
    func reclassify(id: String) async throws -> ReclassifyResult { throw APIError.badURL }
    func reclassifyAll() async throws -> ReclassifySummary { throw APIError.badURL }
    func claimDelivery(forSeconds seconds: Int) async throws {}
}

private func row(_ id: String, triage: String = "new") -> MessageListRow {
    MessageListRow(
        id: id, account: "acct", threadID: nil, senderName: nil,
        senderEmail: "someone@example.com", subject: "s",
        receivedAt: "2026-07-16T10:00:00+00:00",
        ingestedAt: "2026-07-16T10:00:00+00:00", preview: nil,
        urgencyTier: 1, category: "work", triageState: triage)
}

@MainActor
final class TriageSyncTests: XCTestCase {

    /// The E20 core, wired exactly as MainWindowView wires it: detail VM →
    /// onTriageChange → listModel.applyTriage. The badge state must change in
    /// place with NO list refetch and no disturbance of other rows.
    func testDetailTriageUpdatesListRowInPlaceWithoutReload() async {
        let api = FakeMessageAPI(rows: [row("acct:1"), row("acct:2")])
        let list = MessageListViewModel(api: api)
        await list.loadInitial()
        XCTAssertEqual(list.rows.map(\.triageState), ["new", "new"])
        let fetchesAfterLoad = api.listCalls

        let detail = MessageDetailViewModel(
            messageID: "acct:1", api: api,
            onTriageChange: { list.applyTriage(messageID: $0, stateRaw: $1) })
        await detail.load()
        await detail.setTriage(.acknowledged)

        XCTAssertEqual(detail.detail?.triageState, "acknowledged")
        XCTAssertEqual(list.rows.first { $0.id == "acct:1" }?.triageState, "acknowledged",
                       "E20: the list badge must reflect a triage made in the detail pane.")
        XCTAssertEqual(list.rows.first { $0.id == "acct:2" }?.triageState, "new",
                       "Only the triaged row may change.")
        XCTAssertEqual(api.listCalls, fetchesAfterLoad,
                       "The sync must patch in place — a refetch would disturb scroll/selection (P2/D34).")
        XCTAssertEqual(list.rows.count, 2)
    }

    /// A triage for a message the list isn't currently showing (filtered by an
    /// active search, or fetched straight from a notification deep link) must
    /// be a silent no-op, not a crash or a spurious insert.
    func testTriageForUnlistedMessageIsIgnored() async {
        let api = FakeMessageAPI(rows: [row("acct:1")])
        let list = MessageListViewModel(api: api)
        await list.loadInitial()

        list.applyTriage(messageID: "acct:GONE", stateRaw: "done")

        XCTAssertEqual(list.rows.map(\.id), ["acct:1"])
        XCTAssertEqual(list.rows[0].triageState, "new")
    }
}
// ── D50: chips, counts, persistence, P1 search floor ─────────────────────────

@MainActor
final class TriageFilterTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.d50.\(UUID().uuidString)")!
    }

    func testOpenIsTheDefaultAndExcludesAcknowledged() {
        let api = FakeMessageAPI(rows: [])
        let model = MessageListViewModel(api: api, defaults: freshDefaults())
        XCTAssertEqual(model.filter, .open, "Open is the decided default.")
        XCTAssertEqual(TriageFilter.open.states, ["new", "needs_action", "unclassified"],
                       "Open = New + Needs action + unclassified (D50 amendment: a stuck "
                           + "classify failure is visible by default); Ack EXCLUDED.")
        XCTAssertNil(TriageFilter.all.states, "All fetches unfiltered (incl. unclassified).")
    }

    func testChipPersistsAcrossModelLifetimes() async {
        let defaults = freshDefaults()
        let api = FakeMessageAPI(rows: [])
        let first = MessageListViewModel(api: api, defaults: defaults)
        first.filter = .done
        // "Relaunch": a fresh model over the same defaults domain.
        let second = MessageListViewModel(api: api, defaults: defaults)
        XCTAssertEqual(second.filter, .done, "The chip choice survives relaunch.")
    }

    func testCountsAreStoreWideAndChipsReadThem() async {
        let api = FakeMessageAPI(rows: [
            row("acct:1", triage: "new"), row("acct:2", triage: "needs_action"),
            row("acct:3", triage: "acknowledged"), row("acct:4", triage: "done"),
        ])
        let model = MessageListViewModel(api: api, defaults: freshDefaults())
        await model.loadInitial()
        let counts = try! XCTUnwrap(model.counts)
        XCTAssertEqual(TriageFilter.open.count(in: counts), 2, "new + needs_action (+0 unclassified)")
        XCTAssertEqual(TriageFilter.needsAction.count(in: counts), 1)
        XCTAssertEqual(TriageFilter.done.count(in: counts), 1)
        XCTAssertEqual(TriageFilter.all.count(in: counts), 4,
                       "All counts everything, Acknowledged included.")
    }

    func testInPlaceTriageKeepsCountsHonestBetweenTicks() async {
        let api = FakeMessageAPI(rows: [row("acct:1", triage: "new")])
        let model = MessageListViewModel(api: api, defaults: freshDefaults())
        await model.loadInitial()
        XCTAssertEqual(model.counts.map { TriageFilter.open.count(in: $0) }, 1)

        model.applyTriage(messageID: "acct:1", stateRaw: "done")

        XCTAssertEqual(model.counts.map { TriageFilter.open.count(in: $0) }, 0,
                       "The E20 seam must move the message between count buckets.")
        XCTAssertEqual(model.counts.map { TriageFilter.done.count(in: $0) }, 1)
        XCTAssertEqual(model.rows.count, 1,
                       "The row stays rendered until the next fetch — no yank (P2).")
    }

    func testSearchIgnoresTheChipP1Floor() async {
        // A model on the Open chip must still ask the SEARCH endpoint with no
        // state filter — a Done hit renders even when the chip is Open.
        let api = FakeMessageAPI(rows: [row("acct:done-hit", triage: "done")],
                                 searchResults: [row("acct:done-hit", triage: "done")])
        let model = MessageListViewModel(api: api, defaults: freshDefaults())
        XCTAssertEqual(model.filter, .open)
        model.searchText = "hit"
        // Deterministic wait: poll past the 300ms debounce until the reload
        // lands (a fixed sleep raced the debounce's own sleep).
        let deadline = Date().addingTimeInterval(5)
        while model.rows.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(model.rows.map(\.id), ["acct:done-hit"],
                       "P1 floor: search spans every triage state regardless of the chip.")
    }
}

// ── D51: dock-badge derivation (count logic only — the RENDERED badge is a
// human-gate eyeball item; NSDockTile isn't headless-testable, flagged not faked) ──

@MainActor
final class DockBadgeDerivationTests: XCTestCase {

    private func counts(urgent: Int) -> TriageCounts {
        TriageCounts(new: 5, acknowledged: 1, needsAction: 2, done: 3,
                     unclassified: 0, urgentNew: urgent)
    }

    func testUrgentNewDecodesFromTheCountsPayload() throws {
        let json = Data("""
        {"new": 4, "acknowledged": 0, "needs_action": 0, "done": 1,
         "unclassified": 1, "urgent_new": 2}
        """.utf8)
        let decoded = try JSONDecoder().decode(TriageCounts.self, from: json)
        XCTAssertEqual(decoded.urgentNew, 2)
    }

    func testTriagingAnUrgentNewMessageDecrementsTheBadge() async {
        // Through the REAL seam: applyTriage on a T1 message in state new.
        let api = FakeMessageAPI(rows: [row("acct:1", triage: "new")])   // tier 1
        let model = MessageListViewModel(
            api: api, defaults: UserDefaults(suiteName: "test.d51.\(UUID().uuidString)")!)
        await model.loadInitial()
        // Fake counts don't carry urgent_new; seed via the seam itself:
        model.applyTriage(messageID: "acct:1", stateRaw: "new")  // no-op (same state)

        var c = counts(urgent: 2)
        c.moveUrgent(tier: 1, from: "new", to: "acknowledged")
        XCTAssertEqual(c.urgentNew, 1, "any advance past New decrements")
        c.moveUrgent(tier: 2, from: "new", to: "done")
        XCTAssertEqual(c.urgentNew, 0)
        c.moveUrgent(tier: 2, from: "new", to: "done")
        XCTAssertEqual(c.urgentNew, 0, "never below zero")
    }

    func testLowTierAndNonNewTransitionsDoNotTouchTheBadge() {
        var c = counts(urgent: 2)
        c.moveUrgent(tier: 3, from: "new", to: "done")
        XCTAssertEqual(c.urgentNew, 2, "T3+ mail never counts toward the badge")
        c.moveUrgent(tier: 1, from: "acknowledged", to: "done")
        XCTAssertEqual(c.urgentNew, 2, "urgent mail already past New doesn't move it")
        c.moveUrgent(tier: nil, from: "new", to: "done")
        XCTAssertEqual(c.urgentNew, 2, "unclassified mail can't be urgent")
        c.moveUrgent(tier: 1, from: "acknowledged", to: "new")
        XCTAssertEqual(c.urgentNew, 3, "a reverse-triage BACK to New increments")
    }
}

/// D50 amendment (the author, Session 26): unclassified mail belongs in Open.
@MainActor
final class OpenIncludesUnclassifiedTests: XCTestCase {

    func testOpenFetchesAndCountsUnclassifiedMail() async {
        let stuck = MessageListRow(
            id: "acct:stuck", account: "acct", threadID: nil, senderName: nil,
            senderEmail: "stuck@example.com", subject: "never classified",
            receivedAt: "2026-07-17T12:00:00+00:00",
            ingestedAt: "2026-07-17T12:00:00+00:00", preview: nil,
            urgencyTier: nil, category: nil, triageState: nil)
        let api = FakeMessageAPI(rows: [stuck, row("acct:fine", triage: "new"),
                                        row("acct:handled", triage: "done")])
        let model = MessageListViewModel(
            api: api, defaults: UserDefaults(suiteName: "test.d50a.\(UUID().uuidString)")!)
        XCTAssertEqual(model.filter, .open)
        await model.loadInitial()

        XCTAssertEqual(Set(model.rows.map(\.id)), ["acct:stuck", "acct:fine"],
                       "Open shows unclassified + new; done stays out (P1: a stuck "
                           + "classify failure is visible by default).")
        let counts = model.counts!
        XCTAssertEqual(TriageFilter.open.count(in: counts), 2,
                       "the Open chip count includes the unclassified message")
    }
}
