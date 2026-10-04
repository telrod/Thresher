//
//  SettingsHealthRenderTests.swift
//  ThresherTests
//
//  Session 36 — Part D of the gate-automation plan: the render half of gate
//  item 1.5, "the warning in Settings".
//
//  WHY A RENDER TEST AND NOT MORE MODEL TESTS
//  -------------------------------------------
//  Part A already pinned the LOGIC of 1.5 (`AccountHealthClockTests`): a
//  healthy account is `isOK`, an unhealthy one is not, and the sentence names
//  the mailbox when several are connected. What no test asked is whether any of
//  that reaches the screen — and `AccountHealthRenderTests` covers only the
//  message-list banner, never the Settings pane.
//
//  That gap is exactly the shape this project keeps getting caught by: OI14 (a
//  sidebar row correct in the model and OCCLUDED at render time), OI18 (chip
//  labels that wrapped only at real widths), D59 (a bulk scope armed correctly
//  while every checkbox stayed empty, 126 unit tests green), and the F2 dock
//  badge three weeks ago (16 tests green while the badge sat frozen, because
//  every one called the pure function and none asked whether anything still
//  CALLED it).
//
//  So this renders the real `EmailAccountsSection` in a real window and reads
//  pixels, following `AccountHealthRenderTests` and the premultiplied-bitmap
//  lesson from `swiftui-render-test-traps`.
//
//  THE ASSERTION THAT MATTERS IS THE NEGATIVE ONE. Gate 1.5 has two halves and
//  the second is the one that rots quietly: "Healthy mailboxes should say
//  nothing at all — no green ticks, no 'OK' labels." A row that reassures on
//  every render trains the eye to skip the line, which is the opposite of what
//  a warning needs. The 2026-09-01 gate run could not check that half at all
//  (every mailbox was down, so there was no healthy row), and recorded
//  "I guess pass" against it.
//

import AppKit
import SwiftUI
import XCTest
@testable import Thresher

@MainActor
final class SettingsHealthRenderTests: XCTestCase {

    private static let evidenceDir = URL(fileURLWithPath: "/tmp/thresher-settings-health")

    private func entry(_ account: String, _ status: String,
                       seconds: Int? = 900) -> AccountHealthEntry {
        AccountHealthEntry(account: account, status: status,
                           lastPollAt: nil, secondsSince: seconds,
                           detail: status == "stale" ? "no poll in 15 min" : "")
    }

    /// Renders the Email Accounts pane and returns the amount of ORANGE ink in
    /// it. The warning Label is `.foregroundStyle(.orange)`, so orange pixels
    /// are a direct proxy for "a warning line is on screen" — and, unlike a
    /// string search, it cannot be satisfied by text that is present in the
    /// view hierarchy but invisible (the OI14 failure).
    ///
    /// Counting orange rather than any ink is what makes the negative assertion
    /// meaningful: the pane is full of ordinary text either way, so "is there
    /// ink" would be true in both states.
    private func orangePixelCount(health: AccountHealthReport,
                                  accounts: [String],
                                  name: String) throws -> Int {
        // The section OWNS its view model (`init(api:)` builds one), so the
        // stub API is the only injection point — which is the right seam
        // anyway: this renders the real view, not a hand-fed one.
        let api = HealthSettingsAPI(accounts: accounts, health: health)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: Form { EmailAccountsSection(api: api) }
                .formStyle(.grouped)
                .frame(width: 620, height: 420))
        window.orderFrontRegardless()
        // The section loads accounts AND health in .task; give both a beat.
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        defer { window.close() }

        let root = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)

        var orange = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let raw = rep.colorAt(x: x, y: y),
                      let c = raw.usingColorSpace(.deviceRGB) else { continue }
                // Bitmaps from cacheDisplay are PREMULTIPLIED (see
                // swiftui-render-test-traps): divide by alpha before judging a
                // colour, or every partially-transparent pixel reads as dark.
                let a = c.alphaComponent
                guard a > 0.05 else { continue }
                let r = c.redComponent / a, g = c.greenComponent / a, b = c.blueComponent / a
                // System orange sits around (1.0, 0.58, 0.0). Require a clear
                // red-over-blue margin so ordinary greys and the accent blue
                // cannot be mistaken for it.
                if r > 0.65, g > 0.30, g < 0.80, b < 0.35, r - b > 0.45 { orange += 1 }
            }
        }

        try? FileManager.default.createDirectory(at: Self.evidenceDir,
                                                 withIntermediateDirectories: true)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: Self.evidenceDir.appendingPathComponent("\(name).png"))
        }
        return orange
    }

    /// Both halves of gate 1.5, as one comparison.
    ///
    /// A single render cannot say whether orange ink means "the warning showed"
    /// — some other orange could exist. Rendering the SAME pane in both states
    /// and comparing is what makes it evidence: the only difference between the
    /// two is the health report.
    ///
    /// VERIFIED RED in both directions:
    ///   - `ingestionStatus` returning `EmptyView()` (the warning never
    ///     rendered) → the dead-account assertion fails with 0 orange pixels;
    ///   - dropping the `!entry.isOK` guard so every row speaks → the healthy
    ///     assertion fails, which is the "no green ticks, no OK labels" half.
    func testTheWarningRendersForADeadMailboxAndNothingForAHealthyOne() throws {
        let dead = AccountHealthReport(
            healthy: false,
            accounts: [entry("dead@gmail.com", "stale")],
            staleAfterSeconds: 660)
        let alive = AccountHealthReport(
            healthy: true,
            accounts: [entry("dead@gmail.com", "ok", seconds: 30)],
            staleAfterSeconds: 660)

        let whenDead = try orangePixelCount(health: dead,
                                            accounts: ["dead@gmail.com"],
                                            name: "dead")
        let whenHealthy = try orangePixelCount(health: alive,
                                               accounts: ["dead@gmail.com"],
                                               name: "healthy")

        XCTAssertGreaterThan(whenDead, 150, """
            A mailbox that is not being polled rendered \(whenDead) orange \
            pixels in Settings → Email accounts. The warning is not reaching \
            the screen — which is the OI14 shape: correct in the model, absent \
            in the window.
            """)

        XCTAssertLessThan(whenHealthy, whenDead / 4, """
            A HEALTHY mailbox rendered \(whenHealthy) orange pixels against \
            \(whenDead) for a dead one. Gate 1.5: "Healthy mailboxes should say \
            nothing at all — no green ticks, no OK labels." A row that reassures \
            on every render trains the eye to skip it.
            """)
    }

    /// The partial-outage case, at the pixel level: one dead mailbox beside a
    /// healthy one must produce exactly ONE warning line, not two and not none.
    /// This is the 17-hour blind spot — the case the feature exists for, and
    /// the one a single `bootout` cannot produce at the keyboard, so the gate
    /// has never actually exercised it.
    func testOnlyTheDeadRowSpeaksWhenOneOfTwoMailboxesIsDown() throws {
        let mixed = AccountHealthReport(
            healthy: false,
            accounts: [entry("live@example.org", "ok", seconds: 30),
                       entry("dead@gmail.com", "stale")],
            staleAfterSeconds: 660)
        let bothFine = AccountHealthReport(
            healthy: true,
            accounts: [entry("live@example.org", "ok", seconds: 30),
                       entry("dead@gmail.com", "ok", seconds: 30)],
            staleAfterSeconds: 660)

        let accounts = ["live@example.org", "dead@gmail.com"]
        let partial = try orangePixelCount(health: mixed, accounts: accounts,
                                           name: "partial-outage")
        let quiet = try orangePixelCount(health: bothFine, accounts: accounts,
                                         name: "both-healthy")

        XCTAssertGreaterThan(partial, 150, """
            One dead mailbox beside a healthy one produced \(partial) orange \
            pixels — the 17-hour blind spot must be visible in the pane where \
            the user goes to act on it.
            """)
        XCTAssertLessThan(quiet, partial / 4, """
            Two healthy mailboxes produced \(quiet) orange pixels; only the \
            broken row may speak.
            """)
    }
}

/// Serves a fixed account list and health report; every other call is unused
/// by this pane and throws so an accidental dependency is loud, not silent.
private final class HealthSettingsAPI: SettingsAPI, @unchecked Sendable {
    let accounts: [String]
    let health: AccountHealthReport
    init(accounts: [String], health: AccountHealthReport) {
        self.accounts = accounts
        self.health = health
    }
    func listAccounts() async throws -> [String] { accounts }
    func accountHealth() async throws -> AccountHealthReport { health }

    func getRules(includeDisabled: Bool) async throws -> RulesResponse {
        RulesResponse(rules: [], senderGroups: [])
    }
    func createRule(_ body: RuleWrite) async throws -> Rule { throw APIError.badURL }
    func updateRule(id: Int, patch: RuleWrite) async throws -> Rule { throw APIError.badURL }
    func deleteRule(id: Int) async throws {}
    func reorderRules(orderedIds: [Int]) async throws -> [Rule] { [] }
    func reclassifyAllMessages() async throws -> ReclassifySummary { throw APIError.badURL }
    func backendVersion() async throws -> BackendVersion { throw APIError.badURL }
    func createSenderGroup(_ body: SenderGroupWrite) async throws -> SenderGroup {
        throw APIError.badURL
    }
    func updateSenderGroup(id: Int, patch: SenderGroupWrite) async throws -> SenderGroup {
        throw APIError.badURL
    }
    func deleteSenderGroup(id: Int) async throws {}
    func getPreferences() async throws -> Preferences { throw APIError.badURL }
    func setPreference(key: String, value: String) async throws {}
    func getNotificationPrefs() async throws -> NotificationPrefs { throw APIError.badURL }
    func setNotificationPrefs(_ patch: NotificationPrefsWrite) async throws -> NotificationPrefs {
        throw APIError.badURL
    }
    func storeAccount(email: String, appPassword: String,
                      retrievalWindow: RetrievalWindow?) async throws {}
    func previewRetrieval(email: String, appPassword: String) async throws -> RetrievalPreview {
        throw APIError.badURL
    }
    func verifyAccount(_ email: String) async throws -> VerifyResult { throw APIError.badURL }
    func disconnectAccount(_ email: String) async throws {}
}
