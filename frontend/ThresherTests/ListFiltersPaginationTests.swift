//
//  ListFiltersPaginationTests.swift
//  ThresherTests
//
//  OI21 (pagination), Part 2 (tier + date filters) and Part 3 (bulk triage).
//
//  What is worth pinning here is not "a page can load" but the honesty
//  properties, because every defect in this area was a LIE rather than a crash:
//   - the list showed 100 rows and implied that was the store (OI21, which
//     manufactured the phantom OI20);
//   - a filtered view would show a store-wide total if the total ignored filters;
//   - a bulk action must act on exactly what the user saw, and must say what it
//     did to the mailbox.
//

import XCTest
@testable import Thresher

private func row(_ id: String, tier: Int = 3, state: String = "new",
                 daysAgo: Double = 1) -> MessageListRow {
    let stamp = ISO8601DateFormatter.listBound.string(
        from: Date().addingTimeInterval(-daysAgo * 86_400))
    return MessageListRow(id: id, account: "acct", threadID: nil,
                          senderName: "Sender", senderEmail: "s@x.example",
                          subject: id, receivedAt: stamp, ingestedAt: stamp,
                          preview: "preview", urgencyTier: tier, category: "work",
                          triageState: state)
}

/// A fake that behaves like the real endpoint: it applies the filters, honours
/// limit/offset, and reports the FILTERED total. A fake that ignored the query
/// would make every assertion below vacuous.
private final class PagingAPI: MessageAPI, @unchecked Sendable {
    let all: [MessageListRow]
    /// Every query the model issued — lets a test assert what was ASKED, not
    /// just what came back.
    private(set) var queries: [ListQuery] = []
    private(set) var bulkCalls: [(ids: [String], state: TriageState)] = []
    var bulkError: Error?

    init(_ all: [MessageListRow]) { self.all = all }

    private func matching(_ q: ListQuery) -> [MessageListRow] {
        all.filter { r in
            if let states = q.states, !states.contains(r.triageState ?? "") { return false }
            if let tier = q.tier, r.urgencyTier != tier { return false }
            let received = ISO8601DateFormatter.listBound.date(from: r.receivedAt) ?? .distantPast
            if let since = q.since,
               let bound = ISO8601DateFormatter.listBound.date(from: since),
               received < bound { return false }
            if let until = q.until,
               let bound = ISO8601DateFormatter.listBound.date(from: until),
               received >= bound { return false }
            return true
        }
    }

    func listPage(_ query: ListQuery) async throws -> MessagePage {
        queries.append(query)
        let hits = matching(query)
        let start = min(query.offset, hits.count)
        let end = min(start + query.limit, hits.count)
        return MessagePage(rows: Array(hits[start..<end]), total: hits.count,
                           offset: query.offset)
    }

    func triageBulk(ids: [String], state: TriageState) async throws -> BulkTriageResult {
        bulkCalls.append((ids, state))
        if let bulkError { throw bulkError }
        return BulkTriageResult(updated: ids.count, triageState: state.rawValue,
                                wroteBack: 0, writeBackSkipped: true,
                                matching: nil, alreadyInState: nil)
    }

    /// D59 filter mode. Records the SCOPE so a test can assert what was sent —
    /// the filter, and specifically which `until` — rather than only the result.
    private(set) var scopedCalls: [(scope: BulkFilterScope, state: TriageState)] = []
    /// Lets a test simulate the server affecting a different number than was
    /// previewed (concurrent triage), which the UI must report rather than hide.
    var scopedUpdatedOverride: Int?

    func triageBulk(scope: BulkFilterScope,
                    state: TriageState) async throws -> BulkTriageResult {
        scopedCalls.append((scope, state))
        if let bulkError { throw bulkError }
        // Resolve against the fake store using the SCOPE's own bounds, so the
        // count reflects the frozen `until` rather than trusting the preview.
        let q = ListQuery(states: scope.states, tier: scope.tier,
                          since: scope.since, until: scope.until,
                          limit: Int.max, offset: 0)
        let hits = matching(q).count
        return BulkTriageResult(updated: scopedUpdatedOverride ?? hits,
                                triageState: state.rawValue,
                                wroteBack: 0, writeBackSkipped: true,
                                matching: hits, alreadyInState: 0)
    }

    func listMessages() async throws -> [MessageListRow] { all }
    func listMessages(states: [String]?) async throws -> [MessageListRow] {
        guard let states else { return all }
        return all.filter { states.contains($0.triageState ?? "") }
    }
    func messageCounts() async throws -> TriageCounts {
        TriageCounts(new: all.count, acknowledged: 0, needsAction: 0, done: 0,
                     unclassified: 0)
    }
    func searchMessages(query: String) async throws -> [MessageListRow] {
        all.filter { ($0.subject ?? "").contains(query) }
    }
    func preferences() async throws -> Preferences { throw APIError.badURL }
    func getMessage(id: String) async throws -> MessageDetail { throw APIError.badURL }
    func explain(id: String) async throws -> Explanation? { nil }
    func thread(id: String) async throws -> [MessageListRow] { [] }
    func setTriage(id: String, state: TriageState) async throws -> TriageUpdateResponse {
        throw APIError.badURL
    }
    func notifications(since: Int) async throws -> NotificationFeed { throw APIError.badURL }
    func reclassify(id: String) async throws -> ReclassifyResult { throw APIError.badURL }
    func reclassifyAll() async throws -> ReclassifySummary { throw APIError.badURL }
    func claimDelivery(forSeconds seconds: Int) async throws {}
}

@MainActor
final class ListFiltersPaginationTests: XCTestCase {

    private func makeModel(_ rows: [MessageListRow])
    -> (MessageListViewModel, PagingAPI) {
        let api = PagingAPI(rows)
        let model = MessageListViewModel(
            api: api,
            defaults: UserDefaults(suiteName: "test.filters.\(UUID().uuidString)")!)
        return (model, api)
    }

    // ── OI21: the window admits its size ────────────────────────────────────

    func testFirstPageReportsTheFullTotalNotTheRowCount() async {
        let (model, _) = makeModel((0..<250).map { row("m\($0)") })
        await model.loadInitial()
        XCTAssertEqual(model.rows.count, 100, "still one page")
        XCTAssertEqual(model.totalMatching, 250, "but the total is honest")
        XCTAssertTrue(model.hasMore)
    }

    func testLoadMoreReachesTheGenuineLastRow() async {
        let (model, _) = makeModel((0..<250).map { row("m\($0)") })
        await model.loadInitial()
        var guardCounter = 0
        while model.hasMore && guardCounter < 10 {
            await model.loadMore()
            guardCounter += 1
        }
        XCTAssertEqual(model.rows.count, 250)
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(Set(model.rows.map(\.id)).count, 250, "no duplicate rows")
    }

    func testLoadMoreDoesNotDuplicateRowsIfCalledTwice() async {
        let (model, _) = makeModel((0..<150).map { row("m\($0)") })
        await model.loadInitial()
        await model.loadMore()
        await model.loadMore()          // nothing left; must be a no-op
        XCTAssertEqual(model.rows.count, 150)
        XCTAssertEqual(Set(model.rows.map(\.id)).count, 150)
    }

    func testHasMoreIsFalseWhenEverythingFits() async {
        let (model, _) = makeModel((0..<10).map { row("m\($0)") })
        await model.loadInitial()
        XCTAssertFalse(model.hasMore, "a short list must not offer to load more")
    }

    // ── Part 2: the total tracks the FILTERS, or the affordance lies ────────

    func testTotalReflectsTheActiveTierFilter() async {
        var rows = (0..<200).map { row("t4:\($0)", tier: 4) }
        rows += (0..<5).map { row("t2:\($0)", tier: 2) }
        let (model, _) = makeModel(rows)
        await model.loadInitial()
        XCTAssertEqual(model.totalMatching, 205)

        model.tierFilter = .tier2
        await waitForReload()
        XCTAssertEqual(model.totalMatching, 5,
                       "a filtered view must not report the store-wide total")
        XCTAssertEqual(model.rows.count, 5)
        XCTAssertFalse(model.hasMore)
    }

    func testOlderThanWindowSelectsTheBacklogNotTheRecentMail() async {
        var rows = (0..<3).map { row("fresh:\($0)", daysAgo: 2) }
        rows += (0..<7).map { row("old:\($0)", daysAgo: 120) }
        let (model, api) = makeModel(rows)
        await model.loadInitial()

        model.dateWindow = .olderThan90Days
        await waitForReload()

        XCTAssertEqual(model.rows.count, 7)
        XCTAssertTrue(model.rows.allSatisfy { $0.id.hasPrefix("old:") })
        // The inverse window must travel as `until`, never `since` — reading the
        // boundary from the wrong side would silently return the complement.
        let last = api.queries.last
        XCTAssertNotNil(last?.until)
        XCTAssertNil(last?.since)
    }

    func testRecentWindowSendsSinceNotUntil() async {
        let (model, api) = makeModel((0..<4).map { row("m\($0)", daysAgo: 2) })
        await model.loadInitial()
        model.dateWindow = .last7Days
        await waitForReload()
        XCTAssertNotNil(api.queries.last?.since)
        XCTAssertNil(api.queries.last?.until)
    }

    func testFiltersComposeWithTheTriageChip() async {
        var rows = (0..<4).map { row("hit:\($0)", tier: 4, state: "new", daysAgo: 200) }
        rows += [row("wrongTier", tier: 2, state: "new", daysAgo: 200)]
        rows += [row("wrongState", tier: 4, state: "done", daysAgo: 200)]
        rows += [row("tooNew", tier: 4, state: "new", daysAgo: 1)]
        let (model, _) = makeModel(rows)
        model.filter = .open
        model.tierFilter = .tier4
        model.dateWindow = .olderThan90Days
        await model.loadInitial()
        XCTAssertEqual(Set(model.rows.map(\.id)),
                       Set((0..<4).map { "hit:\($0)" }),
                       "chip AND tier AND date must all apply")
    }

    func testClearFiltersRestoresTheFullView() async {
        let (model, _) = makeModel((0..<20).map { row("m\($0)", tier: 4) })
        model.tierFilter = .tier1
        await model.loadInitial()
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.hasActiveFilters)

        model.clearFilters()
        await waitForReload()
        XCTAssertFalse(model.hasActiveFilters)
        XCTAssertEqual(model.rows.count, 20)
    }

    func testSearchIgnoresTierAndDateFilters() async {
        // P1 floor. Search already ignores the chip; it must ignore these too,
        // or the one guaranteed-reachable path inherits a filter the user set
        // for a different purpose.
        var rows = [row("needle", tier: 1, state: "done", daysAgo: 900)]
        rows += (0..<5).map { row("hay:\($0)", tier: 4) }
        let (model, _) = makeModel(rows)
        model.tierFilter = .tier4
        model.dateWindow = .lastDay
        await model.loadInitial()

        model.searchText = "needle"
        await waitForSearchDebounce()

        XCTAssertEqual(model.rows.map(\.id), ["needle"],
                       "a Tier-1, Done, 900-day-old message must still be findable")
    }

    // ── Part 3: bulk triage ─────────────────────────────────────────────────

    func testBulkTriageSendsExactlyTheSelectedIds() async {
        let (model, api) = makeModel((0..<10).map { row("m\($0)") })
        await model.loadInitial()
        model.isSelecting = true
        model.selectedForBulk = ["m1", "m3", "m5"]

        await model.applyBulkTriage(.done)

        XCTAssertEqual(api.bulkCalls.count, 1)
        XCTAssertEqual(Set(api.bulkCalls[0].ids), ["m1", "m3", "m5"])
        XCTAssertEqual(api.bulkCalls[0].state, .done)
    }

    func testBulkTriageClearsSelectionAndLeavesSelectMode() async {
        let (model, _) = makeModel((0..<5).map { row("m\($0)") })
        await model.loadInitial()
        model.isSelecting = true
        model.selectedForBulk = ["m0"]

        await model.applyBulkTriage(.done)

        XCTAssertTrue(model.selectedForBulk.isEmpty)
        XCTAssertFalse(model.isSelecting)
    }

    func testBulkTriageOnEmptySelectionIsANoOp() async {
        let (model, api) = makeModel((0..<5).map { row("m\($0)") })
        await model.loadInitial()
        let result = await model.applyBulkTriage(.done)
        XCTAssertNil(result)
        XCTAssertTrue(api.bulkCalls.isEmpty, "must not call the endpoint with no ids")
    }

    func testBulkTriageFailureSurfacesAndKeepsSelection() async {
        // A 409 means the server changed NOTHING. Dropping the selection would
        // leave the user unable to retry what they had picked.
        let (model, api) = makeModel((0..<5).map { row("m\($0)") })
        await model.loadInitial()
        api.bulkError = APIError.http(status: 409, body: "stale set")
        model.isSelecting = true
        model.selectedForBulk = ["m0", "m1"]

        let result = await model.applyBulkTriage(.done)

        XCTAssertNil(result)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.selectedForBulk, ["m0", "m1"],
                       "a failed bulk must not silently discard the selection")
    }

    func testSelectAllCoversOnlyLoadedRows() async {
        // Scope honesty: with 250 matches and one page loaded, "select all"
        // means the 100 the user can see — the endpoint takes explicit ids, so
        // it can only ever act on what was actually fetched.
        let (model, _) = makeModel((0..<250).map { row("m\($0)") })
        await model.loadInitial()
        model.isSelecting = true
        model.selectAllLoaded()
        XCTAssertEqual(model.selectedForBulk.count, 100)
        XCTAssertEqual(model.totalMatching, 250)
    }

    func testLeavingSelectModeDropsTheSelection() async {
        let (model, _) = makeModel((0..<5).map { row("m\($0)") })
        await model.loadInitial()
        model.isSelecting = true
        model.selectedForBulk = ["m0", "m1"]
        model.isSelecting = false
        XCTAssertTrue(model.selectedForBulk.isEmpty)
    }

    func testSelectionIsPrunedToWhatIsStillVisible() async {
        // A selection that outlives its rows would make the confirmation count
        // ("Mark 40 messages as Done?") describe rows the user can no longer see.
        var rows = (0..<5).map { row("m\($0)", tier: 4) }
        rows += [row("t1", tier: 1)]
        let (model, _) = makeModel(rows)
        await model.loadInitial()
        model.isSelecting = true
        model.selectedForBulk = ["m0", "t1"]

        model.tierFilter = .tier1        // m0 leaves the view
        await waitForReload()

        XCTAssertEqual(model.selectedForBulk, ["t1"])
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    /// The filter setters kick off a detached reload Task; give it a turn.
    private func waitForReload() async {
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            await Task.yield()
        }
    }

    /// Search is debounced 300ms in the model.
    private func waitForSearchDebounce() async {
        try? await Task.sleep(nanoseconds: 600_000_000)
        await Task.yield()
    }
}
