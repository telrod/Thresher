//
//  DockBadgeHealthTests.swift
//  ThresherTests
//
//  OI31 — the health warning had exactly one surface: the message list.
//
//  D65 exists because a dead poller was invisible for 13 days. But its banner
//  renders in `MessageListView` only, so sitting in Settings, in the detail
//  pane, or with the window closed put the user back in the blind spot the
//  feature was built to remove.
//
//  The dock badge is the right second surface precisely BECAUSE it carries the
//  same ambiguity in miniature: an empty badge means "no urgent mail" and
//  "nothing is being polled", and those are the two states D65 exists to tell
//  apart. It is also the only surface visible with the window closed.
//
//  The derivation was an inline expression in ThresherApp.swift with no
//  test. Adding a second concern to an untested inline expression is how the
//  count and the warning would silently disagree, so it is extracted here.
//

import XCTest
import AppKit
@testable import Thresher

final class DockBadgeHealthTests: XCTestCase {

    private func report(_ statuses: [(String, String)]) -> AccountHealthReport {
        AccountHealthReport(
            healthy: statuses.allSatisfy { $0.1 == "ok" },
            accounts: statuses.map {
                AccountHealthEntry(account: $0.0, status: $0.1,
                                   lastPollAt: nil, secondsSince: 600, detail: "")
            },
            staleAfterSeconds: 660)
    }

    // ── D51's existing behaviour must be preserved exactly ───────────────────

    func testAHealthyBadgeStillShowsTheUrgentCount() {
        let label = DockBadge.label(urgentNew: 3, health: report([("a@x", "ok")]))
        XCTAssertEqual(label, "3")
    }

    func testZeroClearsTheBadgeWhenHealthy() {
        /// D51: "zero clears it". An empty badge is the resting state and must
        /// stay that way, or the dock grows a permanent ornament.
        XCTAssertEqual(DockBadge.label(urgentNew: 0, health: report([("a@x", "ok")])), "")
    }

    func testUnknownHealthBehavesExactlyLikeD51() {
        /// nil health = we haven't asked yet, or couldn't. "We don't know" must
        /// never render as a warning — inventing an outage because the backend
        /// was slow to answer is the false-alarm direction, and the list banner
        /// makes the same choice.
        XCTAssertEqual(DockBadge.label(urgentNew: 4, health: nil), "4")
        XCTAssertEqual(DockBadge.label(urgentNew: 0, health: nil), "")
    }

    func testAnEmptyAccountRosterIsNotAWarning() {
        /// First run, mid-onboarding: no mailbox connected yet. Accusing the
        /// user of a broken poller before they have added an account would be a
        /// false alarm — same rule AccountHealthVerdict already applies.
        let empty = AccountHealthReport(healthy: true, accounts: [], staleAfterSeconds: 660)
        XCTAssertEqual(DockBadge.label(urgentNew: 0, health: empty), "")
        XCTAssertEqual(DockBadge.label(urgentNew: 2, health: empty), "2")
    }

    // ── The OI31 case: an unhealthy poller is visible in the dock ────────────

    func testADEADPollerMarksTheBadgeEvenWithNoUrgentMail() {
        /// THE BUG. Zero urgent + dead poller rendered as an empty badge —
        /// identical to a perfectly healthy quiet inbox. With the window closed
        /// that was the only surface, so the outage was invisible.
        let label = DockBadge.label(urgentNew: 0, health: report([("a@x", "stopped")]))
        XCTAssertEqual(label, "!")
    }

    func testADEADPollerMarksTheBadgeWITHOUTHidingTheCount() {
        /// The count is still true and still useful — replacing "3" with "!"
        /// would trade one lie for another. Both facts, one badge.
        let label = DockBadge.label(urgentNew: 3, health: report([("a@x", "stale")]))
        XCTAssertEqual(label, "3!")
    }

    func testOneDeadAccountBESIDEAHealthyOneStillWarns() {
        /// The 17-hour blind spot exactly: one mailbox dead, one polling
        /// happily, and the app as a whole looking fine. A badge keyed on
        /// `report.healthy` alone would be correct here only by luck — it is
        /// false when ANY account is bad, but this pins the case that actually
        /// happened.
        let label = DockBadge.label(urgentNew: 0,
                                    health: report([("a@x", "ok"), ("b@y", "stopped")]))
        XCTAssertEqual(label, "!")
    }

    func testEveryNonOKStatusWarns() {
        /// Including a status this build has never heard of. An unknown status
        /// from a newer backend must fail toward warning, not toward silence —
        /// the whole point of D65 is that silence is the dangerous reading.
        for status in ["stopped", "stale", "never", "error", "something_new"] {
            XCTAssertEqual(DockBadge.label(urgentNew: 0, health: report([("a@x", status)])),
                           "!", "status \(status) did not warn")
        }
    }

    func testTheMarkerIsStableAcrossCounts() {
        /// Guards the format itself: whatever the count, the warning marker is
        /// a suffix, so a glance at the dock reads "number, plus a problem".
        for n in [1, 9, 42, 1000] {
            XCTAssertEqual(DockBadge.label(urgentNew: n, health: report([("a@x", "stale")])),
                           "\(n)!")
        }
    }

    // ── The real dock tile, not just the derivation ──────────────────────────

    @MainActor
    func testTheREALDockTileRendersTheWarning() {
        /// The derivation being right is not the same as the badge being right:
        /// what reaches the user is `NSApp.dockTile.badgeLabel`, set by two
        /// `.onChange` observers in ThresherApp. Tests are hosted in the app,
        /// so this asserts the actual AppKit surface rather than a proxy for it.
        ///
        /// This does NOT cover the observers firing — SwiftUI's `.onChange`
        /// needs a rendered scene, and dock-tile appearance is a human-gate
        /// eyeball item (recorded as such for D51). It does cover the string
        /// AppKit is actually asked to draw, including that "" clears rather
        /// than drawing an empty pill.
        let original = NSApp.dockTile.badgeLabel
        defer { NSApp.dockTile.badgeLabel = original }

        let unhealthy = AccountHealthReport(
            healthy: false,
            accounts: [AccountHealthEntry(account: "a@x", status: "stopped",
                                          lastPollAt: nil, secondsSince: 900, detail: "")],
            staleAfterSeconds: 660)

        NSApp.dockTile.badgeLabel = DockBadge.label(urgentNew: 0, health: unhealthy)
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "!")

        NSApp.dockTile.badgeLabel = DockBadge.label(urgentNew: 7, health: unhealthy)
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "7!")

        let healthy = AccountHealthReport(
            healthy: true,
            accounts: [AccountHealthEntry(account: "a@x", status: "ok",
                                          lastPollAt: nil, secondsSince: 10, detail: "")],
            staleAfterSeconds: 660)
        NSApp.dockTile.badgeLabel = DockBadge.label(urgentNew: 0, health: healthy)
        XCTAssertEqual(NSApp.dockTile.badgeLabel ?? "", "",
                       "a healthy, quiet inbox must clear the badge (D51)")
    }

    func testANegativeCountIsTreatedAsZero() {
        /// The E20 triage seam decrements in place; a decrement below zero is
        /// already clamped there, but a badge that could render "-1!" would be
        /// a visible symptom of an invisible bookkeeping bug.
        XCTAssertEqual(DockBadge.label(urgentNew: -1, health: report([("a@x", "ok")])), "")
        XCTAssertEqual(DockBadge.label(urgentNew: -1, health: report([("a@x", "stale")])), "!")
    }
}


// MARK: - The Settings surface (OI31, second half)

/// The accounts pane is where a user goes to ACT on a dead mailbox, and it
/// showed nothing about ingestion at all — only "Test connection", which asks a
/// different question ("can I log in?") than the one a 13-day outage turns on
/// ("is anything being fetched?"). A mailbox can pass the first and fail the
/// second; that is precisely the 17-hour blind spot.
@MainActor
final class EmailAccountsHealthTests: XCTestCase {

    private final class HealthAPI: SettingsAPI, @unchecked Sendable {
        var accounts: [String]
        var report: AccountHealthReport?
        var healthError: Error?
        private(set) var healthCalls = 0

        init(accounts: [String], report: AccountHealthReport?, healthError: Error? = nil) {
            self.accounts = accounts
            self.report = report
            self.healthError = healthError
        }
        func listAccounts() async throws -> [String] { accounts }
        func accountHealth() async throws -> AccountHealthReport {
            healthCalls += 1
            if let healthError { throw healthError }
            return report!
        }
        func storeAccount(email: String, appPassword: String,
                          retrievalWindow: RetrievalWindow?) async throws {}
        func previewRetrieval(email: String, appPassword: String) async throws -> RetrievalPreview {
            RetrievalPreview(account: email, counts: [:])
        }
        func verifyAccount(_ email: String) async throws -> VerifyResult { throw APIError.badURL }
        func disconnectAccount(_ email: String) async throws {}
        func getRules(includeDisabled: Bool) async throws -> RulesResponse {
            RulesResponse(rules: [], senderGroups: [])
        }
        func createRule(_ body: RuleWrite) async throws -> Rule { throw APIError.badURL }
        func updateRule(id: Int, patch: RuleWrite) async throws -> Rule { throw APIError.badURL }
        func deleteRule(id: Int) async throws {}
        func reorderRules(orderedIds: [Int]) async throws -> [Rule] { [] }
        func reclassifyAllMessages() async throws -> ReclassifySummary { throw APIError.badURL }
        func backendVersion() async throws -> BackendVersion { throw APIError.badURL }
        func createSenderGroup(_ body: SenderGroupWrite) async throws -> SenderGroup { throw APIError.badURL }
        func updateSenderGroup(id: Int, patch: SenderGroupWrite) async throws -> SenderGroup { throw APIError.badURL }
        func deleteSenderGroup(id: Int) async throws {}
        func getPreferences() async throws -> Preferences { Preferences(values: [:]) }
        func setPreference(key: String, value: String) async throws {}
        func getNotificationPrefs() async throws -> NotificationPrefs {
            NotificationPrefs(quietHoursStart: nil, quietHoursEnd: nil, audioAlerts: false)
        }
        func setNotificationPrefs(_ patch: NotificationPrefsWrite) async throws -> NotificationPrefs {
            NotificationPrefs(quietHoursStart: nil, quietHoursEnd: nil, audioAlerts: false)
        }
    }

    private func report(_ statuses: [(String, String)]) -> AccountHealthReport {
        AccountHealthReport(
            healthy: statuses.allSatisfy { $0.1 == "ok" },
            accounts: statuses.map {
                AccountHealthEntry(account: $0.0, status: $0.1,
                                   lastPollAt: nil, secondsSince: 7200, detail: "boom")
            },
            staleAfterSeconds: 660)
    }

    func testTheModelExposesPerAccountHealth() async {
        let api = HealthAPI(accounts: ["a@x", "b@y"],
                            report: report([("a@x", "ok"), ("b@y", "stopped")]))
        let model = EmailAccountsViewModel(api: api)
        await model.load()

        XCTAssertEqual(model.healthEntry(for: "a@x")?.status, "ok")
        XCTAssertEqual(model.healthEntry(for: "b@y")?.status, "stopped")
        XCTAssertFalse(model.healthEntry(for: "b@y")?.isOK ?? true)
    }

    func testTHE_17_HOUR_CASE_oneDeadAccountBesideAHealthyOne() async {
        /// The failure that motivated D65: one mailbox dead, one polling fine,
        /// and nothing anywhere said so. Per-row status is the only shape that
        /// surfaces it — an app-level "healthy: false" would not say WHICH.
        let api = HealthAPI(accounts: ["alive@x", "dead@y"],
                            report: report([("alive@x", "ok"), ("dead@y", "stopped")]))
        let model = EmailAccountsViewModel(api: api)
        await model.load()

        XCTAssertTrue(model.healthEntry(for: "alive@x")?.isOK ?? false)
        XCTAssertFalse(model.healthEntry(for: "dead@y")?.isOK ?? true)

        let sentence = AccountHealthVerdict.sentence(
            for: model.healthEntry(for: "dead@y")!, totalAccounts: 2)
        XCTAssertTrue(sentence.contains("dead@y"),
                      "with several mailboxes the sentence must NAME the broken one: \(sentence)")
    }

    func testAnUnreachableBackendSaysNOTHINGRatherThanAccusingTheAccount() async {
        /// "We couldn't ask" is not "the account is broken". The accounts list
        /// still loads; health simply stays unknown.
        let api = HealthAPI(accounts: ["a@x"], report: nil,
                            healthError: APIError.http(status: 500, body: "down"))
        let model = EmailAccountsViewModel(api: api)
        await model.load()

        XCTAssertEqual(model.accounts, ["a@x"])
        XCTAssertNil(model.healthEntry(for: "a@x"))
    }

    func testAFAILEDHealthFetchDoesNotBLANKAPreviousWarning() async {
        /// Flickering a warning off exactly when the backend is having trouble
        /// is the worst possible moment to go quiet. The list banner makes the
        /// same call (discard on failure, never clear to nil).
        let api = HealthAPI(accounts: ["a@x"], report: report([("a@x", "stopped")]))
        let model = EmailAccountsViewModel(api: api)
        await model.load()
        XCTAssertFalse(model.healthEntry(for: "a@x")?.isOK ?? true)

        api.healthError = APIError.http(status: 500, body: "down")
        await model.load()
        XCTAssertFalse(model.healthEntry(for: "a@x")?.isOK ?? true,
                       "a failed refetch blanked a warning that is still true")
    }

    func testAnAccountTheBackendDoesNotListHasNoStatus() async {
        /// Just connected, poller hasn't seen it yet. Absence is not a fault —
        /// inventing one on a brand-new account is the false-alarm direction.
        let api = HealthAPI(accounts: ["a@x", "brandnew@z"],
                            report: report([("a@x", "ok")]))
        let model = EmailAccountsViewModel(api: api)
        await model.load()
        XCTAssertNil(model.healthEntry(for: "brandnew@z"))
    }
}
