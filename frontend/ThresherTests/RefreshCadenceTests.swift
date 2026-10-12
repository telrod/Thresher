//
//  RefreshCadenceTests.swift
//  ThresherTests
//
//  D49 (E21) — the refresh-cadence contract, amended from D34 with the author's
//  sign-off (Session 25):
//   1. the UI list refresh runs at HALF the backend poll interval (floor 30s),
//      re-reading the pref each pass — bounds staleness at interval/2 for every
//      tier, with or without notification permission;
//   2. a notification tick that posts banners also triggers a list refresh
//      (fast path — banner and list never disagree);
//   3. the delivery-claim TTL is DERIVED from the cadence that refreshes it
//      (≥ 2× poll interval + slack), closing the 90s-TTL-vs-300s-tick lapse
//      the E21 investigation flagged.
//

import UserNotifications
import XCTest
@testable import Thresher

/// MessageAPI fake for the notification tick: serves a canned feed, records
/// the TTL each claim arrived with. Everything else is unused by tick().
private final class FakeNotificationAPI: MessageAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var _claimedTTLs: [Int] = []
    var claimedTTLs: [Int] { lock.withLock { _claimedTTLs } }

    let feed: NotificationFeed
    init(feed: NotificationFeed) { self.feed = feed }

    func reclassify(id: String) async throws -> ReclassifyResult { throw APIError.badURL }
    func reclassifyAll() async throws -> ReclassifySummary { throw APIError.badURL }
    func claimDelivery(forSeconds seconds: Int) async throws {
        lock.withLock { _claimedTTLs.append(seconds) }
    }
    func notifications(since: Int) async throws -> NotificationFeed { feed }

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
}

/// A feed that starts empty and gains an alert when the test hands one off,
/// the way `notification_log` gains a row when the backend defers to the app.
/// Serves only rows above `since`, like `GET /notifications?since=`.
private final class HandOffNotificationAPI: MessageAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [NotificationItem] = []
    private var _fetches = 0
    var fetches: Int { lock.withLock { _fetches } }

    func handOff(_ item: NotificationItem) { lock.withLock { items.append(item) } }

    func claimDelivery(forSeconds seconds: Int) async throws {}
    func notifications(since: Int) async throws -> NotificationFeed {
        lock.withLock {
            _fetches += 1
            let fresh = items.filter { $0.id > since }
            return NotificationFeed(notifications: fresh,
                                    cursor: fresh.map(\.id).max() ?? since)
        }
    }

    func reclassify(id: String) async throws -> ReclassifyResult { throw APIError.badURL }
    func reclassifyAll() async throws -> ReclassifySummary { throw APIError.badURL }
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
}

@MainActor
private final class PostedBanners {
    var identifiers: [String] = []
}

private func tierOneItem(id: Int) -> NotificationItem {
    NotificationItem(id: id, messageID: "acct:\(id)", notificationType: "tier1_alert",
                     sentAt: "2026-07-16T10:00:00+00:00", title: "t", text: "x")
}

/// A throwaway defaults suite per test: the manager persists its delivery
/// cursor to UserDefaults, and the hosted test app shares the real app's
/// defaults domain — tests must NEVER touch the live cursor (§0-adjacent:
/// clobbering it would re-post or skip the author's real banners).
private func throwawayDefaults() -> UserDefaults {
    UserDefaults(suiteName: "test.refresh-cadence.\(UUID().uuidString)")!
}

@MainActor
final class RefreshCadenceTests: XCTestCase {

    // ── 1. List refresh period ────────────────────────────────────────────────

    func testRefreshPeriodIsHalfThePollInterval() {
        XCTAssertEqual(MessageListViewModel.refreshPeriod(forPollInterval: 300), 150)
        XCTAssertEqual(MessageListViewModel.refreshPeriod(forPollInterval: 600), 300)
        XCTAssertEqual(MessageListViewModel.refreshPeriod(forPollInterval: 60), 30)
    }

    func testRefreshPeriodNeverDropsBelowTheFloor() {
        XCTAssertEqual(MessageListViewModel.refreshPeriod(forPollInterval: 45), 30)
        XCTAssertEqual(MessageListViewModel.refreshPeriod(forPollInterval: 0), 30)
    }

    // ── 3. The heartbeat is INDEPENDENT of the poll cadence ───────────────────
    //
    // SUPERSEDES the D49 contract these two tests used to assert ("the claim TTL
    // must outlive the poll cadence that refreshes it", TTL = 2*interval + 30).
    // That coupling is what lost a Tier 1 alert on 2026-09-06: because the app
    // refreshed its claim only once per poll interval, the claim had to be long
    // enough to span one — so a quit app stayed "live" to the backend for
    // minutes. At the 15-minute maximum it refreshed only every 900s, and no
    // backend freshness window can both keep a live app claiming that rarely and
    // notice a quit one promptly.
    //
    // The app now checks in on a FIXED cadence and the backend owns staleness
    // (CLAIM_STALE_SECONDS = 90). The property to protect is the opposite of the
    // old one: the heartbeat must NOT scale with the poll interval.

    func testHeartbeatCadenceDoesNotScaleWithThePollInterval() {
        let cadences = [60, 150, 300, 600, 900].map {
            NotificationManager.claimTTL(forPollInterval: TimeInterval($0))
        }
        XCTAssertEqual(Set(cadences).count, 1,
                       "the heartbeat cadence still varies with the poll interval — "
                        + "that coupling is what let a quit app stay trusted for ~10 min")
        XCTAssertEqual(cadences.first, Int(NotificationManager.heartbeatSeconds))
    }

    func testHeartbeatStaysWellInsideTheBackendStalenessWindow() {
        // The backend presumes the app gone after 90s (three missed beats).
        // A cadence at or above that window means a LIVE app is periodically
        // mistaken for a dead one, which brings back the double banners D45
        // exists to prevent.
        XCTAssertLessThan(NotificationManager.heartbeatSeconds, 90,
                          "a live app would be judged stale between beats")
        XCTAssertLessThanOrEqual(NotificationManager.heartbeatSeconds * 3, 90,
                                 "the backend window should tolerate ~3 missed beats")
    }

    func testTickChecksInRegardlessOfThePollInterval() async {
        let api = FakeNotificationAPI(feed: NotificationFeed(notifications: [], cursor: 0))
        let manager = NotificationManager(api: api, defaults: throwawayDefaults())

        manager.start(pollInterval: 900)   // the widest interval offered
        manager.stop()
        XCTAssertEqual(manager.claimTTLSeconds, Int(NotificationManager.heartbeatSeconds))

        await manager.tick()
        XCTAssertEqual(api.claimedTTLs, [Int(NotificationManager.heartbeatSeconds)],
                       "tick must check in on the fixed cadence, not one derived "
                        + "from the poll interval.")
    }

    // ── 4. Alerts are fetched on the heartbeat, not the poll (D85) ────────────
    //
    // On 2026-10-11 a Tier 1 handed to the app at 13:38:41Z reached Notification
    // Center at 13:42:36Z — 3m55s — because the app fetched alerts only once
    // per mail poll (5 min). osascript, which it replaces, posts at once.

    private func waitUntil(timeout: TimeInterval = 2,
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testAnAlertHandedOffBetweenPollsIsDeliveredOnTheNextHeartbeat() async {
        let api = HandOffNotificationAPI()
        let posted = PostedBanners()
        let manager = NotificationManager(
            api: api, center: .current(), defaults: throwawayDefaults(),
            checkInterval: 0.05,                       // the heartbeat, scaled down
            authorization: { .authorized },
            deliver: { posted.identifiers.append($0.identifier) })

        manager.start(pollInterval: 3600)              // the next POLL is an hour away
        // The first pass has run and found nothing yet.
        let firstPass = await waitUntil { api.fetches >= 1 }
        XCTAssertTrue(firstPass, "the manager never made its first check")

        api.handOff(tierOneItem(id: 21))               // backend defers a Tier 1 to the app
        let delivered = await waitUntil {
            posted.identifiers.contains("thresher.notification.21")
        }
        // A few more beats: still exactly one banner for that alert.
        _ = await waitUntil(timeout: 0.2) { false }
        manager.stop()

        XCTAssertTrue(delivered, "an alert handed off between polls waited for the next "
                        + "POLL instead of the next heartbeat")
        XCTAssertEqual(posted.identifiers, ["thresher.notification.21"],
                       "one handed-off alert must post exactly one banner")
    }

    /// OI44 / D88: the daily digest arrives through the same feed as a Tier 1,
    /// told apart by `notification_type` "digest" and a null `message_id`. It
    /// posts with the backend's title and body, and carries no message id, so
    /// clicking it opens the app rather than deep-linking to one message.
    func testAHandedOffDigestPostsItsSummaryWithNoDeepLink() async {
        let api = HandOffNotificationAPI()
        var requests: [UNNotificationRequest] = []
        let manager = NotificationManager(
            api: api, center: .current(), defaults: throwawayDefaults(),
            checkInterval: 0.05,
            authorization: { .authorized },
            deliver: { requests.append($0) })
        api.handOff(NotificationItem(
            id: 31, messageID: nil, notificationType: "digest",
            sentAt: "2026-10-11T13:00:00+00:00",
            title: "Daily digest · 4 Tier 3 messages", text: "Ann, Bo, Cy, and 1 more"))

        manager.start(pollInterval: 3600)
        let posted = await waitUntil { !requests.isEmpty }
        _ = await waitUntil(timeout: 0.2) { false }
        manager.stop()

        XCTAssertTrue(posted, "a handed-off digest was never posted")
        XCTAssertEqual(requests.count, 1, "one digest, one banner")
        XCTAssertEqual(requests.first?.identifier, "thresher.notification.31")
        XCTAssertEqual(requests.first?.content.title, "Daily digest · 4 Tier 3 messages")
        XCTAssertEqual(requests.first?.content.body, "Ann, Bo, Cy, and 1 more")
        XCTAssertNil(requests.first?.content.userInfo["message_id"],
                     "a digest is not one message and must not deep-link to one")
    }

    // ── 2. Fast path: banners trigger a list refresh ──────────────────────────

    func testTickWithNewRowsFiresTheListRefreshHook() async {
        let api = FakeNotificationAPI(
            feed: NotificationFeed(notifications: [tierOneItem(id: 7)], cursor: 7))
        let manager = NotificationManager(api: api, defaults: throwawayDefaults())
        var refreshes = 0
        manager.onDeliveredNewMail = { refreshes += 1 }

        await manager.tick()

        XCTAssertEqual(refreshes, 1,
                       "A tick that posted a banner must let the list refresh in step (D49).")
    }

    func testQuietTickDoesNotFireTheListRefreshHook() async {
        let api = FakeNotificationAPI(feed: NotificationFeed(notifications: [], cursor: 9))
        let manager = NotificationManager(api: api, defaults: throwawayDefaults())
        var refreshes = 0
        manager.onDeliveredNewMail = { refreshes += 1 }

        await manager.tick()

        XCTAssertEqual(refreshes, 0,
                       "No new rows → no spurious list refresh (P2: quiet stays quiet).")
    }
}