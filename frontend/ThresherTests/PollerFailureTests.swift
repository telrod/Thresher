//
//  PollerFailureTests.swift
//  ThresherTests
//
//  OI43 — a poller the supervisor gave up on, and a first mail check that never
//  came, must both be visible.
//
//  Before this, `hasGivenUp(on:)` was read by no view: after three failed
//  relaunches mail and alerts stopped, and the only record was a line in
//  `supervisor.log`. The user heard nothing until the heartbeat went stale
//  eleven minutes later, and a poller that died before its first poll showed
//  "Waiting for the first mail check" for ever.
//
//  Every supervisor here logs to a temporary directory, and `tearDown` checks
//  the real `supervisor.log` is byte-for-byte unchanged (SHA-256), because these
//  tests drive give-ups and restarts on purpose — the same shape that once wrote
//  false "gave up on poller" lines into the user's log.
//

import AppKit
import CryptoKit
import SwiftUI
import UserNotifications
import XCTest
@testable import Thresher

@MainActor
final class PollerFailureTests: XCTestCase {

    // ── Fakes ────────────────────────────────────────────────────────────────

    private final class FakeProcessHost: BackendProcessHosting, @unchecked Sendable {
        var running: Set<String> = []
        private(set) var launchCount: [String: Int] = [:]
        var exitStatus: [String: Int32] = [:]

        func isRunning(_ id: String) -> Bool { running.contains(id) }
        func launch(_ id: String, python: URL, arguments: [String], workingDirectory: URL) throws {
            launchCount[id, default: 0] += 1
            running.insert(id)
        }
        func terminate(_ id: String) { running.remove(id) }
        func isPortInUse(_ port: Int) -> Bool { false }
        func lastExitStatus(_ id: String) -> Int32? {
            running.contains(id) ? nil : exitStatus[id]
        }
        func exits(_ id: String, status: Int32) {
            running.remove(id)
            exitStatus[id] = status
        }
    }

    /// What `/health/accounts` answers, changeable mid-test.
    private final class HealthBox: @unchecked Sendable {
        var report: AccountHealthReport?
    }

    /// Alerts the wiring posted, captured instead of reaching the real center.
    private final class Posted {
        var requests: [UNNotificationRequest] = []
    }

    private final class HealthAPI: MessageAPI, @unchecked Sendable {
        let rows: [MessageListRow]
        let health: AccountHealthReport?
        init(rows: [MessageListRow], health: AccountHealthReport?) {
            self.rows = rows
            self.health = health
        }
        func accountHealth() async throws -> AccountHealthReport {
            guard let health else { throw APIError.transport(URLError(.cannotConnectToHost)) }
            return health
        }
        func listPage(_ query: ListQuery) async throws -> MessagePage {
            MessagePage(rows: rows, total: rows.count, offset: query.offset)
        }
        func listMessages() async throws -> [MessageListRow] { rows }
        func listMessages(states: [String]?) async throws -> [MessageListRow] { rows }
        func messageCounts() async throws -> TriageCounts {
            TriageCounts(new: rows.count, acknowledged: 0, needsAction: 0, done: 0,
                         unclassified: 0)
        }
        func triageBulk(ids: [String], state: TriageState) async throws -> BulkTriageResult {
            throw APIError.badURL
        }
        func triageBulk(scope: BulkFilterScope,
                        state: TriageState) async throws -> BulkTriageResult {
            throw APIError.badURL
        }
        func searchMessages(query: String) async throws -> [MessageListRow] { rows }
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

    // ── The real log must not move ───────────────────────────────────────────

    private var logDirectory: URL!
    private var realLogDigest: String?

    private static var realSupervisorLog: URL {
        LocalProcessHost.logDirectory.appendingPathComponent("supervisor.log")
    }

    private static func digest(_ url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    override func setUp() {
        super.setUp()
        logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PollerFailureTests.\(UUID().uuidString)",
                                    isDirectory: true)
        realLogDigest = Self.digest(Self.realSupervisorLog)
    }

    override func tearDown() {
        XCTAssertEqual(Self.digest(Self.realSupervisorLog), realLogDigest,
                       "a test changed the user's real supervisor.log")
        try? FileManager.default.removeItem(at: logDirectory)
        super.tearDown()
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private struct Rig {
        let host: FakeProcessHost
        let supervisor: BackendSupervisor
        let status: PollerStatus
        let health: HealthBox
        let posted: Posted
    }

    private func rig() throws -> Rig {
        let host = FakeProcessHost()
        let supervisor = BackendSupervisor(
            host: host, backendDirectory: URL(fileURLWithPath: "/tmp/backend"),
            python: URL(fileURLWithPath: "/usr/bin/python3"),
            logDirectory: logDirectory)
        let health = HealthBox()
        let status = PollerStatus(fetchHealth: { health.report }, confirmInterval: 0.05)
        let posted = Posted()
        let alert = PollerStoppedAlert(deliver: { posted.requests.append($0) })
        PollerFailureWiring.connect(supervisor, to: status, alert: alert)
        try supervisor.start()
        return Rig(host: host, supervisor: supervisor, status: status,
                   health: health, posted: posted)
    }

    /// Kill the poller until the supervisor gives up, then keep ticking: the
    /// supervisor's timer does not stop after a give-up, so neither does this.
    private func driveToGiveUp(_ rig: Rig, extraTicks: Int = 5) {
        for _ in 0..<(BackendSupervisor.maxRestarts + 1 + extraTicks) {
            rig.host.exits(BackendSupervisor.pollerID, status: 1)
            rig.supervisor.restartAnythingThatDied()
        }
    }

    /// Let main-actor tasks run until `condition` holds or `timeout` passes.
    private func settle(timeout: TimeInterval = 2,
                        until condition: () -> Bool = { false }) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func entry(_ status: String, secondsSince: Int?) -> AccountHealthEntry {
        // `last_poll_at` in the poller's own format: Python's isoformat(), with
        // microseconds and a +00:00 offset.
        let stamp = secondsSince.map { s -> String in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
            return f.string(from: Date().addingTimeInterval(-Double(s)))
        }
        return AccountHealthEntry(account: "you@example.com", status: status,
                                  lastPollAt: stamp, secondsSince: secondsSince,
                                  detail: status == "never"
                                      ? "no poll recorded since this account was added" : "")
    }

    private func report(_ status: String, secondsSince: Int?) -> AccountHealthReport {
        AccountHealthReport(healthy: status == "ok",
                            accounts: [entry(status, secondsSince: secondsSince)],
                            staleAfterSeconds: 660)
    }

    // ── 1. Give-up: banner, badge, exactly one alert ─────────────────────────

    func testAGiveUpRaisesTheBannerStateAndPostsExactlyOneAlert() async throws {
        let rig = try rig()
        XCTAssertFalse(rig.status.isStopped)

        driveToGiveUp(rig)
        await settle(timeout: 0.5)

        XCTAssertEqual(rig.status.state, .gaveUp)
        XCTAssertTrue(rig.status.isStopped, "the banner must be up after a give-up")
        XCTAssertEqual(rig.posted.requests.count, 1,
                       "one alert per give-up, however many ticks follow it")
        let content = try XCTUnwrap(rig.posted.requests.first?.content)
        XCTAssertEqual(content.title, "Thresher stopped checking mail")
        XCTAssertEqual(content.body,
                       "Alerts are paused until it restarts. Open Thresher to restart it.")
    }

    func testTheBadgeHasADistinctStoppedState() {
        let unhealthy = report("stale", secondsSince: 4_000)
        XCTAssertEqual(DockBadge.label(urgentNew: 3, health: nil, pollerStopped: true), "3 Off")
        XCTAssertEqual(DockBadge.label(urgentNew: 0, health: nil, pollerStopped: true), "Off")
        XCTAssertEqual(DockBadge.label(urgentNew: 3, health: unhealthy, pollerStopped: true),
                       "3 Off", "Off replaces the ! rather than stacking with it")
        // Unchanged when the poller is running.
        XCTAssertEqual(DockBadge.label(urgentNew: 3, health: unhealthy, pollerStopped: false), "3!")
        XCTAssertEqual(DockBadge.label(urgentNew: 3, health: nil, pollerStopped: false), "3")
    }

    /// The badge must change AT the give-up, with no other input moving — the
    /// window is likely closed, and the count is not changing.
    func testTheRenderedBadgeChangesAtTheGiveUp() async throws {
        let original = NSApp.dockTile.badgeLabel
        defer { NSApp.dockTile.badgeLabel = original }

        let rig = try rig()
        let monitor = DockBadgeMonitor(api: HealthAPI(rows: [], health: nil),
                                       pollerStatus: rig.status)
        monitor.updateUrgentCount(2)
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "2")

        driveToGiveUp(rig)
        await settle(timeout: 0.3)
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "2 Off")
    }

    func testTheGiveUpBannerIsRENDERED() async throws {
        let stopped = try rig()
        driveToGiveUp(stopped)
        let running = try rig()

        let band = try await orangeBand(status: stopped.status, rows: [row()],
                                        health: nil, file: "poller-gave-up.png")
        let none = try await orangeBand(status: running.status, rows: [row()],
                                        health: nil, file: "poller-running.png")
        XCTAssertGreaterThan(band, 10, "no banner band rendered after a give-up")
        XCTAssertEqual(none, 0, "a banner rendered while the poller is running")
    }

    // ── 2. Restart ───────────────────────────────────────────────────────────

    func testRestartRelaunchesThePollerAndClearsOnlyAfterASuccessfulPoll() async throws {
        let rig = try rig()
        driveToGiveUp(rig, extraTicks: 0)
        XCTAssertTrue(rig.supervisor.hasGivenUp(on: BackendSupervisor.pollerID))
        let launchesBefore = rig.host.launchCount[BackendSupervisor.pollerID] ?? 0

        // The last poll on record predates the restart.
        rig.health.report = report("stale", secondsSince: 4_000)
        rig.status.restart()

        XCTAssertEqual(rig.host.launchCount[BackendSupervisor.pollerID], launchesBefore + 1,
                       "Restart did not relaunch the poller")
        XCTAssertFalse(rig.supervisor.hasGivenUp(on: BackendSupervisor.pollerID))
        let log = (try? String(contentsOf: logDirectory.appendingPathComponent("supervisor.log"),
                               encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("restart: poller restarted by the user"), log)

        // Relaunched is not working: the banner stays until a poll succeeds.
        await settle(timeout: 0.3)
        XCTAssertTrue(rig.status.isStopped, "the banner cleared before any poll succeeded")

        rig.health.report = report("ok", secondsSince: 0)
        await settle { !rig.status.isStopped }
        XCTAssertEqual(rig.status.state, .running, "a successful poll did not clear the banner")
    }

    func testRestartResetsTheBudgetAndAFreshGiveUpAlertsAgain() async throws {
        let rig = try rig()
        driveToGiveUp(rig)
        await settle(timeout: 0.3)
        rig.health.report = report("ok", secondsSince: 0)
        rig.status.restart()
        await settle { !rig.status.isStopped }
        let launchesAfterRestart = rig.host.launchCount[BackendSupervisor.pollerID] ?? 0

        // A full budget again: three more relaunches before the next give-up.
        for _ in 0..<BackendSupervisor.maxRestarts {
            rig.host.exits(BackendSupervisor.pollerID, status: 1)
            rig.supervisor.restartAnythingThatDied()
        }
        XCTAssertEqual(rig.host.launchCount[BackendSupervisor.pollerID],
                       launchesAfterRestart + BackendSupervisor.maxRestarts)
        XCTAssertFalse(rig.status.isStopped)

        driveToGiveUp(rig)
        await settle(timeout: 0.5)
        XCTAssertEqual(rig.status.state, .gaveUp)
        XCTAssertEqual(rig.posted.requests.count, 2, "one alert for each give-up")
    }

    // ── 3. A first check that never comes ────────────────────────────────────

    func testAnOverdueFirstCheckShowsTheStalenessBannerNotTheWaitingMessage() async throws {
        let status = PollerStatus(fetchHealth: { nil })
        status.pollerLaunched(at: Date().addingTimeInterval(-700))   // threshold 660s
        let model = MessageListViewModel(
            api: HealthAPI(rows: [], health: report("never", secondsSince: nil)),
            defaults: UserDefaults(suiteName: "test.poller.\(UUID().uuidString)")!,
            pollerStatus: status)
        await model.loadInitial()

        XCTAssertNil(model.firstFetch, "still saying the first check is in progress")
        XCTAssertEqual(model.accountWarning?.message,
                       "The mailbox hasn't checked for mail in 11 min. New mail and alerts "
                       + "may be delayed — quit and reopen Thresher if this persists.")

        let band = try await orangeBand(status: status, rows: [],
                                        health: report("never", secondsSince: nil),
                                        file: "first-check-overdue.png")
        XCTAssertGreaterThan(band, 10, "the staleness banner did not render")
    }

    func testAFirstCheckWithinTheThresholdStillSaysWaiting() async throws {
        let status = PollerStatus(fetchHealth: { nil })
        status.pollerLaunched(at: Date().addingTimeInterval(-600))
        let model = MessageListViewModel(
            api: HealthAPI(rows: [], health: report("never", secondsSince: nil)),
            defaults: UserDefaults(suiteName: "test.poller.\(UUID().uuidString)")!,
            pollerStatus: status)
        await model.loadInitial()
        XCTAssertEqual(model.firstFetch, .fetching)
        XCTAssertEqual(model.accountWarning?.message,
                       "Waiting for the first mail check on this mailbox.")
    }

    func testConnectingAnAccountRestartsTheFirstCheckClock() {
        let status = PollerStatus(fetchHealth: { nil })
        status.pollerLaunched(at: Date().addingTimeInterval(-3_600))
        status.accountConnected(at: Date().addingTimeInterval(-30))
        let resolved = report("never", secondsSince: nil)
            .resolvingOverdueFirstChecks(clock: status.firstCheckClock)
        XCTAssertEqual(resolved.accounts.first?.status, "never",
                       "an account connected 30s ago was called overdue")
    }

    func testWithNoClockNothingIsCalledOverdue() {
        // The app did not start the poller (launchd owns it): we do not know
        // when it began, so we do not guess.
        let resolved = report("never", secondsSince: nil)
            .resolvingOverdueFirstChecks(clock: nil)
        XCTAssertEqual(resolved.accounts.first?.status, "never")
    }

    func testEveryPollerLaunchStartsTheClock() throws {
        let rig = try rig()
        let first = try XCTUnwrap(rig.status.firstCheckClock, "start() did not start the clock")
        rig.host.exits(BackendSupervisor.pollerID, status: BackendSupervisor.exitNotConfigured)
        Thread.sleep(forTimeInterval: 0.01)
        rig.supervisor.restartAnythingThatDied()
        XCTAssertGreaterThan(try XCTUnwrap(rig.status.firstCheckClock), first)
    }

    // ── 4. The staleness wording mentions alerts ─────────────────────────────

    func testTheStaleSentenceSaysAlertsMayBeDelayed() {
        let stale = report("stale", secondsSince: 1_200).accounts[0]
        XCTAssertEqual(AccountHealthVerdict.sentence(for: stale, totalAccounts: 1),
                       "The mailbox hasn't checked for mail in 20 min. New mail and alerts "
                       + "may be delayed — quit and reopen Thresher if this persists.")
        let unknown = AccountHealthEntry(account: "you@example.com", status: "stale",
                                         lastPollAt: nil, secondsSince: nil, detail: "")
        XCTAssertEqual(AccountHealthVerdict.sentence(for: unknown, totalAccounts: 1),
                       "The mailbox hasn't checked for mail recently. New mail and alerts "
                       + "may be delayed.")
    }

    // ── Rendering ────────────────────────────────────────────────────────────

    private func row() -> MessageListRow {
        let stamp = ISO8601DateFormatter.listBound.string(from: Date().addingTimeInterval(-600))
        return MessageListRow(
            id: "a:1", account: "you@example.com", threadID: nil,
            senderName: "Someone", senderEmail: "someone@example.com",
            subject: "A message", receivedAt: stamp, ingestedAt: stamp,
            preview: "preview text", urgencyTier: 3,
            category: "work", triageState: "new")
    }

    /// Render the list for `status` and count the orange banner scanlines in the
    /// top third — the same measured predicate `AccountHealthRenderTests` uses.
    private func orangeBand(status: PollerStatus, rows: [MessageListRow],
                            health: AccountHealthReport?, file: String) async throws -> Int {
        let dir = URL(fileURLWithPath: "/tmp/thresher-health")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = MessageListViewModel(
            api: HealthAPI(rows: rows, health: health),
            defaults: UserDefaults(suiteName: "test.poller-render.\(UUID().uuidString)")!,
            pollerStatus: status)
        await model.loadInitial()

        let width: CGFloat = 520
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(
            rootView: MessageListView(model: model, selection: .constant(nil))
                .frame(width: width, height: 560)
                .preferredColorScheme(.light))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        defer { window.close() }

        let content = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent(file))
        }

        var rowsWarm = 0
        for y in 0..<(rep.pixelsHigh / 3) {
            var warm = 0, sampled = 0
            for x in stride(from: 8, to: rep.pixelsWide - 8, by: 16) {
                var px = [Int](repeating: 0, count: 4)
                rep.getPixel(&px, atX: x, y: y)
                sampled += 1
                let a = px[3]
                guard a > 0 else { continue }
                let r = px[0] * 255 / a, g = px[1] * 255 / a, b = px[2] * 255 / a
                if r - b > 120 && r > 200 && g > 90 && g < 210 { warm += 1 }
            }
            if sampled > 0 && warm > sampled / 2 { rowsWarm += 1 }
        }
        return rowsWarm
    }
}
