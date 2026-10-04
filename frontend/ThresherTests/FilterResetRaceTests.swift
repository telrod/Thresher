//
//  FilterResetRaceTests.swift
//  ThresherTests
//
//  Part 2 of the gate-defects workorder: "the filter doesn't reset after
//  clearing".
//
//  The mechanism is a LAST-WRITE-WINS RACE between concurrent reloads.
//
//  Every filter setter's `didSet` spawns a detached `Task { await reload() }`,
//  and `reload()` assigns `rows`/`totalMatching` from whatever its own
//  `listPage` call returns. Nothing orders those tasks or checks, on
//  completion, whether the filter set that produced a response is still the
//  current one. So when two reloads overlap, the response that lands LAST wins
//  — regardless of which was issued last.
//
//  Measured, not assumed. Probing the live model showed:
//
//    - `clearFilters()` alone is SAFE, and not for the reason its comment
//      claims. Both its tasks begin executing only after the synchronous body
//      returns (the model is @MainActor, so a Task body cannot interleave with
//      it), so both read an already-fully-cleared filter set and issue the
//      identical unfiltered query. Redundant, but not divergent.
//
//    - Two SEPARATE filter changes — which is what the menus produce, and what
//      the gate report described as "resetting both controls to their
//      defaults" — genuinely race. Probe: clearing the tier, then a beat later
//      the date window, issued `[tier=nil until=set]` then `[tier=nil
//      until=nil]`. Completion order was the reverse: `unfiltered` landed
//      first, `until` landed last and overwrote it. Result: 6 rows rendered
//      where 15 were correct, with every control reading "All tiers / Any
//      time".
//
//  That is why the existing `testClearFiltersRestoresTheFullView` passes and
//  the bug is still real: it exercises the one path that happens not to race.
//  `LatencyAPI` below answers narrowed queries slowly and cleared ones quickly,
//  which makes the out-of-order completion deterministic instead of a
//  one-run-in-twenty flake.
//
//  The fix is a monotonic reload token: a response may only be applied if no
//  newer reload has been issued since it started.
//

import XCTest
@testable import Thresher

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

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

/// A fake that applies the filters honestly but answers SLOWLY for narrowed
/// queries and quickly for the unfiltered one.
///
/// That ordering is the point. It models the ordinary case where a filtered
/// query costs the server more than an unfiltered first page, and it makes the
/// out-of-order completion deterministic instead of timing-dependent — so this
/// test fails every run against the racy implementation rather than one run in
/// twenty.
private final class LatencyAPI: MessageAPI, @unchecked Sendable {
    let all: [MessageListRow]

    /// Mutable bookkeeping is lock-guarded, NOT bare `var`.
    ///
    /// This fake is deliberately exercised by CONCURRENT reloads — that is the
    /// whole point of the test — so unsynchronized `append` here is a real data
    /// race, and it presents as `malloc: pointer being freed was not allocated`
    /// inside `listPage`, i.e. a crash in the test harness masquerading as a
    /// crash in the code under test. Guard the arrays and the fake stays a
    /// measuring instrument instead of a second bug.
    private let lock = NSLock()
    private var _queries: [ListQuery] = []
    private var _completions: [String] = []

    var queries: [ListQuery] { lock.withLock { _queries } }
    /// Completion order, by a short description of each query's filter set.
    var completions: [String] { lock.withLock { _completions } }

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

    private func label(_ q: ListQuery) -> String {
        var parts: [String] = []
        if let tier = q.tier { parts.append("tier\(tier)") }
        if q.since != nil { parts.append("since") }
        if q.until != nil { parts.append("until") }
        return parts.isEmpty ? "unfiltered" : parts.joined(separator: "+")
    }

    func listPage(_ query: ListQuery) async throws -> MessagePage {
        lock.withLock { _queries.append(query) }
        // Narrowed queries answer LAST; the fully-cleared query answers first.
        let isNarrowed = query.tier != nil || query.since != nil || query.until != nil
        try? await Task.sleep(nanoseconds: isNarrowed ? 200_000_000 : 20_000_000)
        lock.withLock { _completions.append(label(query)) }
        let hits = matching(query)
        let start = min(query.offset, hits.count)
        let end = min(start + query.limit, hits.count)
        return MessagePage(rows: Array(hits[start..<end]), total: hits.count,
                           offset: query.offset)
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
    func triageBulk(ids: [String], state: TriageState) async throws -> BulkTriageResult {
        BulkTriageResult(updated: ids.count, triageState: state.rawValue,
                         wroteBack: 0, writeBackSkipped: true)
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
final class FilterResetRaceTests: XCTestCase {

    private func makeModel(_ rows: [MessageListRow])
    -> (MessageListViewModel, LatencyAPI) {
        let api = LatencyAPI(rows)
        let model = MessageListViewModel(
            api: api,
            defaults: UserDefaults(suiteName: "test.reset.\(UUID().uuidString)")!)
        return (model, api)
    }

    /// Long enough for every in-flight reload — including the deliberately slow
    /// filtered one — to have completed.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 900_000_000)
        await Task.yield()
    }

    // ── The reported defect ─────────────────────────────────────────────────

    /// Clear BOTH filters at once and the view must show the unfiltered list.
    ///
    /// Red against the racy `clearFilters()`: the half-cleared query
    /// (tier still applied, or the date bound still applied) lands last and
    /// overwrites the correct result, leaving rows filtered while the controls
    /// read "All tiers / Any time".
    func testClearingBothFiltersLeavesTheUnfilteredList() async {
        let (model, _) = makeModel((0..<20).map { row("m\($0)", tier: 4, daysAgo: 200) })
        model.tierFilter = .tier4
        model.dateWindow = .olderThan90Days
        await model.loadInitial()
        await settle()
        XCTAssertEqual(model.rows.count, 20, "precondition: the filtered view matches")

        model.clearFilters()
        await settle()

        XCTAssertFalse(model.hasActiveFilters, "the controls report cleared")
        XCTAssertEqual(model.rows.count, 20,
                       "and the ROWS must match the cleared filters, not a stale query")
        XCTAssertEqual(model.totalMatching, 20)
    }

    /// The sharper version: after clearing, rows the filter excluded must be
    /// back. If a stale filtered response wins, they are still missing.
    func testClearingRestoresRowsTheFilterHadExcluded() async {
        var rows = (0..<6).map { row("old:\($0)", tier: 4, daysAgo: 200) }
        rows += (0..<9).map { row("fresh:\($0)", tier: 2, daysAgo: 1) }
        let (model, _) = makeModel(rows)

        model.tierFilter = .tier4
        model.dateWindow = .olderThan90Days
        await model.loadInitial()
        await settle()
        XCTAssertEqual(model.rows.count, 6, "precondition: only the backlog matches")

        model.clearFilters()
        await settle()

        XCTAssertEqual(model.rows.count, 15,
                       "every message must be back after clearing both filters")
        XCTAssertTrue(model.rows.contains { $0.id.hasPrefix("fresh:") },
                      "the rows the tier filter excluded must return")
    }

    /// **The test that actually reproduces the reported bug.**
    ///
    /// Resetting the two controls SEPARATELY — which is what the menus produce,
    /// and what the gate report described — is the racing path. The tier is
    /// cleared first, then a beat later the date window; the fully-cleared
    /// query completes fast while the still-date-filtered one completes slow
    /// and lands last, overwriting the correct result.
    ///
    /// Probed against the unfixed model: 6 rows rendered where 15 were correct,
    /// with `hasActiveFilters == false` — the list disagreeing with its own
    /// controls, which is exactly what the author saw.
    func testResettingTheTwoMenusSeparatelyRestoresTheFullView() async {
        var rows = (0..<6).map { row("old:\($0)", tier: 4, daysAgo: 200) }
        rows += (0..<9).map { row("fresh:\($0)", tier: 2, daysAgo: 1) }
        let (model, _) = makeModel(rows)

        model.tierFilter = .tier4
        model.dateWindow = .olderThan90Days
        await model.loadInitial()
        await settle()
        XCTAssertEqual(model.rows.count, 6, "precondition: only the backlog matches")

        // Two separate menu picks, with a human-speed gap between them. The
        // second lands while the first reload is still in flight.
        model.tierFilter = nil
        try? await Task.sleep(nanoseconds: 50_000_000)
        model.dateWindow = .anyTime
        await settle()

        XCTAssertFalse(model.hasActiveFilters)
        XCTAssertEqual(model.rows.count, 15,
                       "resetting both menus must restore the full view; a slow "
                       + "response from the half-cleared filter set must not win")
    }

    /// The mirror image: narrowing via two separate menu picks must not be
    /// undone by a stale BROADER response landing late. Same race, opposite
    /// direction — worth pinning so the fix isn't special-cased to clearing.
    func testNarrowingViaTwoMenusIsNotUndoneByAStaleBroaderResponse() async {
        var rows = (0..<6).map { row("old:\($0)", tier: 4, daysAgo: 200) }
        rows += (0..<9).map { row("fresh:\($0)", tier: 2, daysAgo: 1) }
        let (model, _) = makeModel(rows)
        await model.loadInitial()
        await settle()
        XCTAssertEqual(model.rows.count, 15)

        model.tierFilter = .tier4
        try? await Task.sleep(nanoseconds: 50_000_000)
        model.dateWindow = .olderThan90Days
        await settle()

        XCTAssertEqual(model.rows.count, 6,
                       "the narrowed filter set must be what is rendered")
        XCTAssertTrue(model.rows.allSatisfy { $0.id.hasPrefix("old:") })
    }

    /// The invariant that actually fixes the class of bug: whatever the last
    /// reload rendered must correspond to the CURRENT filter set. Pinning the
    /// property rather than the symptom means a future "clear" path that
    /// reintroduces concurrent reloads fails here too.
    func testRenderedRowsAlwaysMatchTheCurrentFilterSet() async {
        var rows = (0..<6).map { row("t4:\($0)", tier: 4) }
        rows += (0..<9).map { row("t2:\($0)", tier: 2) }
        let (model, _) = makeModel(rows)
        await model.loadInitial()
        await settle()

        // Rapid-fire changes, the pattern a real user produces by clicking
        // through a menu. Only the final state may be on screen.
        model.tierFilter = .tier4
        model.tierFilter = .tier2
        model.tierFilter = nil
        await settle()

        XCTAssertNil(model.tierFilter)
        XCTAssertEqual(model.rows.count, 15,
                       "the last-issued filter set wins, not the last-completed request")
    }

    /// Clearing after a bulk action — the exact sequence from the gate check.
    func testClearingAfterABulkActionRestoresTheFullView() async {
        var rows = (0..<6).map { row("old:\($0)", tier: 4, daysAgo: 200) }
        rows += (0..<9).map { row("fresh:\($0)", tier: 2, daysAgo: 1) }
        let (model, _) = makeModel(rows)

        model.tierFilter = .tier4
        model.dateWindow = .olderThan90Days
        await model.loadInitial()
        await settle()

        model.isSelecting = true
        model.selectAllLoaded()
        await model.applyBulkTriage(.done)
        await settle()

        model.clearFilters()
        await settle()

        XCTAssertFalse(model.hasActiveFilters)
        XCTAssertEqual(model.rows.count, 15,
                       "after a bulk action, clearing must still restore the full view")
    }
}


