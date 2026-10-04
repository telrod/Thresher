//
//  DockBadgeMonitorTests.swift
//  ThresherTests
//
//  The test that was missing when human-gate item 1.4 failed (2026-09-01).
//
//  `DockBadgeHealthTests` has sixteen tests and every one of them passed while
//  the badge sat frozen at "3" on a real dock, with the poller stopped and the
//  window closed, for fifteen minutes. They all called `DockBadge.label`
//  directly. The label function was never wrong.
//
//  What was wrong: the only things that CALLED it were two `.onChange`
//  observers on `MessageListView`, fed by a refresh loop that
//  `.onDisappear { model.cancelAll() }` tore down when the window closed —
//  which is the one condition the badge exists for.
//
//  So these tests assert the thing the old ones could not: that health keeps
//  being FETCHED and the badge keeps being REPAINTED with no window in play.
//  Each drives `DockBadgeMonitor` directly, with no view anywhere, because a
//  test that needs a window to pass would be testing the wrong lifetime.
//
//  Verified red against the pre-fix wiring: with the monitor removed and the
//  badge driven only by the view's observers, `testHealthKeepsBeingFetched...`
//  fails with 0 fetches — the frozen badge, reproduced.
//

import XCTest
import AppKit
@testable import Thresher

final class DockBadgeMonitorTests: XCTestCase {

    /// Counts health fetches so a test can prove the loop is alive, and can be
    /// told to go unhealthy partway through — the actual failure sequence
    /// (badge painted while healthy, poller dies later, window already closed).
    private final class HealthSpy: MessageAPI, @unchecked Sendable {
        private(set) var healthFetches = 0
        var report: AccountHealthReport?

        func accountHealth() async throws -> AccountHealthReport {
            healthFetches += 1
            guard let report else { throw APIError.transport(URLError(.cannotConnectToHost)) }
            return report
        }

        // Everything else is unused here; the monitor touches only health and
        // preferences. `preferences` throwing is realistic — the loop is
        // specified to fall back to the default cadence when prefs are
        // unreachable rather than failing.
        func listMessages() async throws -> [MessageListRow] { [] }
        func listMessages(states: [String]?) async throws -> [MessageListRow] { [] }
        func messageCounts() async throws -> TriageCounts { throw APIError.badURL }
        func searchMessages(query: String) async throws -> [MessageListRow] { [] }
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

    private func report(_ statuses: [(String, String)]) -> AccountHealthReport {
        AccountHealthReport(
            healthy: statuses.allSatisfy { $0.1 == "ok" },
            accounts: statuses.map {
                AccountHealthEntry(account: $0.0, status: $0.1,
                                   lastPollAt: nil, secondsSince: 900, detail: "")
            },
            staleAfterSeconds: 660)
    }

    // ── The gate failure itself ──────────────────────────────────────────────

    @MainActor
    func testTheBadgeGrowsItsWarningWithNoWindowInvolved() async {
        /// Item 1.4, exactly: urgent count on the badge, poller then dies, and
        /// nothing but the monitor is running. Before the fix this could not
        /// even be expressed — the only path to the badge went through a view.
        let spy = HealthSpy()
        spy.report = report([("a@x", "ok"), ("b@x", "ok")])
        let monitor = DockBadgeMonitor(api: spy)

        monitor.updateUrgentCount(3)
        await monitor.tick()
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "3",
                       "healthy with 3 urgent must read exactly as D51 always did")

        // The poller dies. No window, no view, no list model — only this loop.
        spy.report = report([("a@x", "stale"), ("b@x", "stale")])
        await monitor.tick()

        XCTAssertEqual(NSApp.dockTile.badgeLabel, "3!",
                       "the badge must grow its ! with no window open — this is "
                       + "the human-gate 1.4 failure")
    }

    @MainActor
    func testHealthKeepsBeingFetchedAfterAWindowWouldHaveClosed() async {
        /// The mechanism, not the symptom. The old wiring stopped FETCHING; the
        /// stale label was just what that looked like. Drive several ticks with
        /// nothing else alive and assert the requests actually happen.
        let spy = HealthSpy()
        spy.report = report([("a@x", "ok")])
        let monitor = DockBadgeMonitor(api: spy)

        for _ in 0..<3 { await monitor.tick() }

        XCTAssertEqual(spy.healthFetches, 3,
                       "the monitor must keep polling health on its own; the old "
                       + "view-owned loop was cancelled by .onDisappear")
    }

    @MainActor
    func testABareWarningWhenThereIsNoUrgentMail() async {
        /// OI31: `!` alone at zero urgent. The gate saw "3" and no `!`; the
        /// inverse (a `!` with no number) is the same bug's other half.
        let spy = HealthSpy()
        spy.report = report([("a@x", "stopped")])
        let monitor = DockBadgeMonitor(api: spy)

        monitor.updateUrgentCount(0)
        await monitor.tick()

        XCTAssertEqual(NSApp.dockTile.badgeLabel, "!")
    }

    // ── Fail-safe direction ──────────────────────────────────────────────────

    @MainActor
    func testAnUnreachableBackendDoesNotInventAnOutage() async {
        /// Same discipline as the list banner: "we couldn't ask" is not "the
        /// account is broken". A failed fetch must leave the last KNOWN state
        /// standing rather than clearing it or fabricating a warning.
        let spy = HealthSpy()
        spy.report = report([("a@x", "ok")])
        let monitor = DockBadgeMonitor(api: spy)
        monitor.updateUrgentCount(2)
        await monitor.tick()
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "2")

        spy.report = nil          // every fetch now throws
        await monitor.tick()

        XCTAssertEqual(NSApp.dockTile.badgeLabel, "2",
                       "an unreachable backend must not paint a warning")
    }

    @MainActor
    func testAWarningSurvivesABackendThatGoesUnreachable() async {
        /// The flicker case, in the direction that matters: once we KNOW a
        /// mailbox is stale, a subsequent failed fetch must not clear the
        /// warning — the condition is still true, we just can't re-confirm it.
        let spy = HealthSpy()
        spy.report = report([("a@x", "stale")])
        let monitor = DockBadgeMonitor(api: spy)
        monitor.updateUrgentCount(1)
        await monitor.tick()
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1!")

        spy.report = nil
        await monitor.tick()

        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1!",
                       "a known outage must not be cleared by an unanswered question")
    }

    @MainActor
    func testTheCountStillTracksTheListWhileAWindowIsOpen() async {
        /// The window-open path must be unchanged: the list model pushes counts
        /// in and the badge follows, exactly as D51 specified.
        let spy = HealthSpy()
        spy.report = report([("a@x", "ok")])
        let monitor = DockBadgeMonitor(api: spy)
        await monitor.tick()

        monitor.updateUrgentCount(7)
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "7")
        monitor.updateUrgentCount(0)
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "",
                       "D51: zero clears the badge")
    }

    @MainActor
    func testAdoptingNilHealthDoesNotDiscardWhatWeKnow() async {
        /// The list model hands over `accountHealth`, which is nil until its
        /// first successful fetch. Adopting that nil must not wipe a verdict
        /// this monitor already has — otherwise opening a window would briefly
        /// clear a live warning.
        let spy = HealthSpy()
        spy.report = report([("a@x", "stale")])
        let monitor = DockBadgeMonitor(api: spy)
        monitor.updateUrgentCount(4)
        await monitor.tick()
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "4!")

        monitor.adopt(health: nil)

        XCTAssertEqual(NSApp.dockTile.badgeLabel, "4!")
    }
}
