//
//  FilterScopedBulkTests.swift
//  ThresherTests
//
//  D59 — filter-scoped bulk triage, and the §B4 two-week preset.
//
//  The id mode was capped at the loaded page, so clearing a backlog meant
//  Load-more → select 100 → Done, dozens of times over. What is worth pinning
//  here is not "a bulk can fire" but the honesty and safety properties, because
//  every way this feature can go wrong is SILENT:
//
//   - it must send the FILTER, not a truncated id list (else it silently acts
//     on 100 of 1,594 while the button said 1,594);
//   - it must send the `until` it froze when the user was shown the count, not
//     a fresh one (else mail that arrived while they read the confirmation is
//     marked Done having never been seen);
//   - the count the confirmation names must be the count the action uses;
//   - the 2-week preset must resolve from D57's FRESH_DAYS, not a second
//     literal 14 that can drift away from it.
//

import XCTest
@testable import Thresher

private func scopedRow(_ id: String, tier: Int = 4, state: String = "new",
                       daysAgo: Double = 40) -> MessageListRow {
    let stamp = ISO8601DateFormatter.listBound.string(
        from: Date().addingTimeInterval(-daysAgo * 86_400))
    return MessageListRow(id: id, account: "acct", threadID: nil,
                          senderName: "Sender", senderEmail: "s@x.example",
                          subject: id, receivedAt: stamp, ingestedAt: stamp,
                          preview: "preview", urgencyTier: tier, category: "work",
                          triageState: state)
}

/// A fake that RESOLVES the filter itself, including the scope's frozen bound.
/// A fake that simply echoed the previewed count back would make every
/// assertion here vacuous — the point is that the bound does the excluding.
private final class ScopeAPI: MessageAPI, @unchecked Sendable {
    let all: [MessageListRow]
    private(set) var idCalls: [(ids: [String], state: TriageState)] = []
    private(set) var scopedCalls: [(scope: BulkFilterScope, state: TriageState)] = []
    /// Simulates the server affecting a different number than was previewed
    /// (concurrent triage) — which the UI must report, not swallow.
    var updatedOverride: Int?
    var prefs: [String: String] = [:]

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
        let hits = matching(query)
        let start = min(query.offset, hits.count)
        let end = min(start + query.limit, hits.count)
        return MessagePage(rows: Array(hits[start..<end]), total: hits.count,
                           offset: query.offset)
    }

    func triageBulk(ids: [String], state: TriageState) async throws -> BulkTriageResult {
        idCalls.append((ids, state))
        return BulkTriageResult(updated: ids.count, triageState: state.rawValue,
                                wroteBack: 0, writeBackSkipped: true)
    }

    func triageBulk(scope: BulkFilterScope,
                    state: TriageState) async throws -> BulkTriageResult {
        scopedCalls.append((scope, state))
        // Resolve using the SCOPE's own bounds — so a test asserting "5 fresh
        // messages were excluded" is asserting about the bound, not the fake.
        let q = ListQuery(states: scope.states, tier: scope.tier,
                          since: scope.since, until: scope.until,
                          limit: Int.max, offset: 0)
        let hits = matching(q).count
        return BulkTriageResult(updated: updatedOverride ?? hits,
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
    func preferences() async throws -> Preferences { Preferences(values: prefs) }
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
final class FilterScopedBulkTests: XCTestCase {

    private func makeModel(_ rows: [MessageListRow])
    -> (MessageListViewModel, ScopeAPI) {
        let api = ScopeAPI(rows)
        let model = MessageListViewModel(
            api: api,
            defaults: UserDefaults(suiteName: "test.d59.\(UUID().uuidString)")!)
        return (model, api)
    }

    // ── B1: send the filter, not the ids ────────────────────────────────────

    func testSelectAllMatchingSendsTheFilterNotAnIdList() async {
        // 250 matching, one page loaded. The id mode could only ever have named
        // the 100 it held — which is the entire defect this feature closes.
        let (model, api) = makeModel((0..<250).map { scopedRow("m\($0)") })
        await model.loadInitial()
        XCTAssertEqual(model.rows.count, 100)
        XCTAssertEqual(model.totalMatching, 250)

        model.isSelecting = true
        model.captureFilterScope()
        XCTAssertEqual(model.pendingBulkCount, 250,
                       "the armed count is the MATCH total, not the loaded count")

        let result = await model.applyFilterScopedTriage(.done)

        XCTAssertEqual(api.scopedCalls.count, 1, "must use the filter endpoint")
        XCTAssertTrue(api.idCalls.isEmpty, "must NOT fall back to an id list")
        XCTAssertEqual(result?.updated, 250,
                       "all 250 affected — not the 100 that were loaded")
    }

    func testTheScopeCarriesTheActiveFilterSet() async {
        let (model, api) = makeModel(
            (0..<120).map { scopedRow("t4:\($0)", tier: 4) }
            + (0..<80).map { scopedRow("t2:\($0)", tier: 2) })
        await model.loadInitial()
        model.tierFilter = .tier4
        try? await Task.sleep(nanoseconds: 200_000_000)
        model.isSelecting = true
        model.captureFilterScope()
        await model.applyFilterScopedTriage(.done)

        XCTAssertEqual(api.scopedCalls.first?.scope.tier, 4,
                       "the tier filter must travel with the scope — otherwise "
                       + "the bulk widens to every tier the user filtered out")
    }

    // ── A3/B1: the frozen `until` is the race guard ─────────────────────────

    func testTheFrozenUntilIsTheOneSentAtExecuteNotAFreshOne() async {
        let (model, api) = makeModel((0..<250).map { scopedRow("m\($0)") })
        await model.loadInitial()
        model.isSelecting = true

        // Freeze at a known instant, as clicking select-all-matching does.
        let captured = Date().addingTimeInterval(-3600)
        model.captureFilterScope(now: captured)
        let armed = model.filterScope?.until

        // Time passes while the user reads the confirmation…
        try? await Task.sleep(nanoseconds: 50_000_000)
        await model.applyFilterScopedTriage(.done)

        XCTAssertEqual(api.scopedCalls.first?.scope.until, armed,
                       "execute must replay the CAPTURED until")
        XCTAssertEqual(
            ISO8601DateFormatter.listBound.string(from: captured), armed,
            "the bound must be the capture instant, not re-derived at send — a "
            + "re-derived bound would sweep in mail that arrived while the user "
            + "was reading the confirmation")
    }

    func testMailArrivingAfterTheCaptureIsExcludedByTheFrozenBound() async {
        // Mail that postdates the capture instant exists in the store. The fake
        // resolves the set with the scope's own bounds, so this asserts the
        // BOUND does the excluding, not that the fake was handed a number.
        var rows = (0..<10).map { scopedRow("old\($0)") }
        rows += (0..<5).map { scopedRow("new\($0)", daysAgo: -1) }   // "arrives later"
        let (model, _) = makeModel(rows)
        await model.loadInitial()
        model.isSelecting = true

        model.captureFilterScope(now: Date())
        let result = await model.applyFilterScopedTriage(.done)

        XCTAssertEqual(result?.updated, 10,
                       "only the 10 that existed at capture may be affected — "
                       + "the 5 that arrive afterwards were never on screen")
    }

    func testABacklogWindowsOwnBoundSurvivesWhenItIsTighter() {
        // "Older than 30 days" already excludes recent mail; the capture instant
        // must not RELAX that. The window is the user's instruction and the
        // capture is the race guard — both hold, so the tighter one wins.
        let window = DateWindow.olderThan30Days.bounds()
        let query = ListQuery(states: nil, tier: nil,
                              since: window.since, until: window.until)
        let scope = BulkFilterScope(query: query, previewedCount: 5, now: Date())
        XCTAssertEqual(scope.until, window.until,
                       "the 30-day bound is tighter than now and must survive")
    }

    func testAnUnboundedWindowGetsTheCaptureInstantAsItsBound() {
        // "Any time" has no `until` of its own, and the server REQUIRES one in
        // filter mode. The capture instant is what fills it.
        let query = ListQuery(states: ["new"], tier: nil, since: nil, until: nil)
        let now = Date()
        let scope = BulkFilterScope(query: query, previewedCount: 9, now: now)
        XCTAssertEqual(scope.until, ISO8601DateFormatter.listBound.string(from: now))
    }

    // ── B2: the confirmation cannot be bypassed ─────────────────────────────

    func testApplyingWithoutAnArmedScopeDoesNothing() async {
        // Arming happens on the select-all click; executing happens only from
        // the confirmation. This pins that the model cannot be driven to a
        // filter-scoped WRITE without a scope having been armed first.
        let (model, api) = makeModel((0..<50).map { scopedRow("m\($0)") })
        await model.loadInitial()
        let result = await model.applyFilterScopedTriage(.done)
        XCTAssertNil(result)
        XCTAssertTrue(api.scopedCalls.isEmpty, "no scope ⇒ no request at all")
    }

    func testPendingBulkCountNamesTheSetTheActionWillUse() async {
        // The confirmation dialog renders `pendingBulkCount`. If that could
        // disagree with what the action sends, the confirmation would be a lie —
        // which is the one thing a confirmation cannot be.
        let (model, _) = makeModel((0..<250).map { scopedRow("m\($0)") })
        await model.loadInitial()
        model.isSelecting = true

        XCTAssertFalse(model.hasPendingBulk, "nothing armed ⇒ the buttons disable")
        model.selectAllLoaded()
        XCTAssertEqual(model.pendingBulkCount, 100)
        model.captureFilterScope()
        XCTAssertEqual(model.pendingBulkCount, 250)
        XCTAssertTrue(model.hasPendingBulk)
    }

    func testCaptureAndIdSelectionAreMutuallyExclusive() async {
        let (model, _) = makeModel((0..<250).map { scopedRow("m\($0)") })
        await model.loadInitial()
        model.isSelecting = true

        model.selectAllLoaded()
        XCTAssertEqual(model.selectedForBulk.count, 100)
        model.captureFilterScope()
        XCTAssertTrue(model.selectedForBulk.isEmpty,
                      "arming the filter scope must clear the checkbox set — "
                      + "otherwise the confirmation's number is ambiguous about "
                      + "which set it describes")

        model.selectAllLoaded()
        XCTAssertNil(model.filterScope,
                     "and choosing the id selection must disarm the scope")
    }

    // ── Scope lifetime ──────────────────────────────────────────────────────

    func testDiscardingAnArmedScopeSaysSoRatherThanFailingSilently() async {
        // THE bug this notice exists for: an armed scope is discarded by any
        // refresh — including the D49 fast path, which fires when new mail
        // arrives and is deliberately NOT suppressed (a Tier 1 banner outranks
        // keeping a bulk dialog valid). Without the notice the user presses
        // Mark Done and NOTHING happens: no triage, no error, no explanation.
        let (model, _) = makeModel((0..<250).map { scopedRow("m\($0)") })
        await model.loadInitial()
        model.isSelecting = true
        model.captureFilterScope()
        XCTAssertNil(model.scopeDiscardedNotice, "nothing to explain yet")

        // New mail lands → the D49 fast path refreshes the list.
        await model.userRefresh()

        XCTAssertNil(model.filterScope, "the scope is still discarded (correct)")
        XCTAssertNotNil(model.scopeDiscardedNotice,
                        "…but discarding it SILENTLY is the bug — the user must "
                        + "be told why the action went away")
        XCTAssertTrue(model.scopeDiscardedNotice!.contains("again"),
                      "the notice must say what to DO, not merely that something happened")
    }

    func testTheNoticeOnlyAppearsWhenAScopeWasActuallyDiscarded() async {
        // A refresh with nothing armed must not nag. The notice is an
        // explanation for a specific loss, not a general "the list refreshed".
        let (model, _) = makeModel((0..<250).map { scopedRow("m\($0)") })
        await model.loadInitial()
        await model.userRefresh()
        XCTAssertNil(model.scopeDiscardedNotice)

        // An id selection surviving a refresh is likewise not a discard.
        model.isSelecting = true
        model.selectAllLoaded()
        await model.userRefresh()
        XCTAssertNil(model.scopeDiscardedNotice)
    }

    func testReArmingClearsTheNotice() async {
        // Re-arming IS the response to the notice; leaving it up would nag
        // about something the user has just done.
        let (model, _) = makeModel((0..<250).map { scopedRow("m\($0)") })
        await model.loadInitial()
        model.isSelecting = true
        model.captureFilterScope()
        await model.userRefresh()
        XCTAssertNotNil(model.scopeDiscardedNotice)

        model.captureFilterScope()
        XCTAssertNil(model.scopeDiscardedNotice, "re-armed ⇒ nothing left to explain")
        XCTAssertNotNil(model.filterScope)

        // And Clear dismisses it too — the user has abandoned the action.
        await model.userRefresh()
        XCTAssertNotNil(model.scopeDiscardedNotice)
        model.clearFilterScope()
        XCTAssertNil(model.scopeDiscardedNotice)
    }

    func testSelectingModeSurvivesTheDiscardSoTheNoticeIsActuallyVisible() async {
        // The bulk bar — and therefore the notice — only renders while
        // `isSelecting`. If a discard also dropped out of selection mode, the
        // explanation would be written to a view that isn't on screen, which is
        // the same silent failure wearing a different hat.
        let (model, _) = makeModel((0..<250).map { scopedRow("m\($0)") })
        await model.loadInitial()
        model.isSelecting = true
        model.captureFilterScope()

        await model.userRefresh()

        XCTAssertTrue(model.isSelecting,
                      "the bulk bar must still be rendered, or the notice has "
                      + "nowhere to appear")
        XCTAssertNotNil(model.scopeDiscardedNotice)
    }

    func testAReloadDisarmsTheScopeRatherThanExecutingAStaleCount() async {
        // The scope promises "N matching, as of this instant". After a reload
        // that promise may no longer describe the view, so it is dropped —
        // re-arming is one click; executing a count the user can no longer see
        // is not recoverable.
        let (model, _) = makeModel((0..<250).map { scopedRow("m\($0)") })
        await model.loadInitial()
        model.isSelecting = true
        model.captureFilterScope()
        XCTAssertNotNil(model.filterScope)

        await model.userRefresh()
        XCTAssertNil(model.filterScope)
    }

    func testSelectAllMatchingIsOfferedOnlyWhenItMeansSomethingDifferent() async {
        // One page holds everything ⇒ "select all loaded" already IS everything,
        // and a second affordance saying the same thing is noise.
        let (small, _) = makeModel((0..<20).map { scopedRow("s\($0)") })
        await small.loadInitial()
        XCTAssertFalse(small.canSelectAllMatching)

        let (big, _) = makeModel((0..<250).map { scopedRow("b\($0)") })
        await big.loadInitial()
        XCTAssertTrue(big.canSelectAllMatching)
    }

    func testSearchDoesNotOfferFilterScopedBulk() async {
        // Search deliberately ignores the chip and the filters (P1 floor), so a
        // "N matching" count would describe a set the filter scope cannot express.
        let (model, _) = makeModel((0..<250).map { scopedRow("m\($0)") })
        await model.loadInitial()
        model.searchText = "m1"
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(model.canSelectAllMatching)
    }

    // ── B3: divergence is reported, not swallowed ───────────────────────────

    func testTheResultReportsWhatTheServerActuallyAffected() async {
        // Concurrent triage means the server can affect a different number than
        // was previewed. With the frozen bound this should be ~0, and a nonzero
        // value is worth SEEING rather than hiding.
        let (model, api) = makeModel((0..<250).map { scopedRow("m\($0)") })
        await model.loadInitial()
        model.isSelecting = true
        model.captureFilterScope()
        api.updatedOverride = 243        // someone else triaged 7 in between

        let result = await model.applyFilterScopedTriage(.done)
        XCTAssertEqual(result?.updated, 243,
                       "the model must surface the server's count, not echo the "
                       + "previewed one back")
        XCTAssertEqual(result?.matching, 250)
    }

    func testWriteBackStaysOffForAFilterScopedBulk() async {
        // P5. Filter-scoped selection makes a ~12,450-round-trip mailbox rewrite
        // far easier to fire, so the default must stay off AND be visible.
        let (model, _) = makeModel((0..<250).map { scopedRow("m\($0)") })
        await model.loadInitial()
        model.isSelecting = true
        model.captureFilterScope()
        let result = await model.applyFilterScopedTriage(.done)
        XCTAssertEqual(result?.writeBackSkipped, true)
        XCTAssertEqual(result?.wroteBack, 0)
    }

    // ── Gate finding: the armed state must be VISIBLE ───────────────────────

    func testAnArmedScopeTicksEveryRenderedRow() async {
        // THE gate finding. Clicking "Select all 176 matching" armed the scope
        // correctly, but every checkbox stayed empty — so the one element in
        // this UI that means "selected" said nothing, and the user reasonably
        // read the click as lost. The rows ARE a page of the matching set, so
        // ticking them is honest, not a white lie.
        let (model, _) = makeModel((0..<250).map { scopedRow("m\($0)") })
        await model.loadInitial()
        model.isSelecting = true

        XCTAssertFalse(model.isRowInPendingBulk(model.rows[0].id),
                       "nothing armed ⇒ nothing ticked")
        model.captureFilterScope()

        for row in model.rows {
            XCTAssertTrue(model.isRowInPendingBulk(row.id),
                          "every rendered row must be ticked while a filter "
                          + "scope is armed — an empty column contradicts the action")
        }
    }

    func testUntickingARowUnderAnArmedScopeDegradesToTheLoadedSet() async {
        // A filter has no "except this one". Rather than ignore the tap or
        // silently drop the 150 unloaded messages from the action, the
        // selection becomes exactly what is on screen minus that row — and the
        // bar stops claiming a number it can no longer honour.
        let (model, _) = makeModel((0..<250).map { scopedRow("m\($0)") })
        await model.loadInitial()
        model.isSelecting = true
        model.captureFilterScope()
        XCTAssertEqual(model.pendingBulkCount, 250)

        let victim = model.rows[3].id
        model.demoteScopeToLoadedSelection(excluding: victim)

        XCTAssertNil(model.filterScope, "the scope can no longer be honoured")
        XCTAssertEqual(model.pendingBulkCount, 99,
                       "100 loaded minus the one just un-ticked")
        XCTAssertFalse(model.isRowInPendingBulk(victim))
        XCTAssertTrue(model.isRowInPendingBulk(model.rows[0].id))
    }

    // ── §B4: the 2-week preset resolves from the shared constant ────────────

    func testTwoWeekPresetResolvesFromFreshDaysNotALiteral14() {
        // The preset and D57's recency band are the same number. Binding them
        // means they cannot drift, and OI29's promotion to a real preference
        // moves both at once with no client change.
        let now = Date()
        let bounds = DateWindow.olderThan2Weeks.bounds(now: now, freshDays: 21)
        let expected = ISO8601DateFormatter.listBound.string(
            from: now.addingTimeInterval(-21 * 86_400))
        XCTAssertEqual(bounds.until, expected,
                       "a server FRESH_DAYS of 21 must move the preset to 21 days")
        XCTAssertNil(bounds.since, "an 'older than' window bounds from above")

        // And the default tracks the shipped backend constant.
        XCTAssertEqual(DateWindow.olderThan2Weeks.days(freshDays: Preferences.defaultFreshDays),
                       14)
    }

    func testFreshDaysIsReadFromThePreferencesPayload() {
        XCTAssertEqual(Preferences(values: ["fresh_days": "21"]).freshDays, 21)
        // Absent ⇒ the shipped constant, not an invented window.
        XCTAssertEqual(Preferences(values: [:]).freshDays, 14)
        // Junk or zero ⇒ same. A zero window would select nothing at all.
        XCTAssertEqual(Preferences(values: ["fresh_days": "0"]).freshDays, 14)
        XCTAssertEqual(Preferences(values: ["fresh_days": "nonsense"]).freshDays, 14)
    }

    func testTheModelResolvesThePresetAgainstTheServersFreshDays() async {
        let (model, api) = makeModel((0..<20).map { scopedRow("m\($0)") })
        api.prefs = ["fresh_days": "21"]
        await model.loadInitial()
        XCTAssertEqual(model.freshDays, 21,
                       "loadInitial must resolve FRESH_DAYS before the first "
                       + "fetch, or a restored 2-week window spends the whole "
                       + "first view resolved against the fallback")
    }

    func testTheTwoWeekPresetIsOfferedInTheMenu() {
        XCTAssertTrue(DateWindow.allCases.contains(.olderThan2Weeks))
        XCTAssertEqual(DateWindow.olderThan2Weeks.label, "Older than 2 weeks")
        XCTAssertTrue(DateWindow.olderThan2Weeks.isBacklogWindow,
                      "it bounds from above (until), like the other backlog windows")
    }
}
