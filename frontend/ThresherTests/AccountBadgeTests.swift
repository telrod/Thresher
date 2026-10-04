//
//  AccountBadgeTests.swift
//  ThresherTests
//
//  Multi-account: showing WHICH mailbox a message arrived in.
//
//  The behaviour worth pinning isn't that a badge can render — it's that it appears
//  exactly when it distinguishes something. A badge that always says the same thing
//  is chrome, not signal, and the app has exactly one user who until now had one
//  account.
//

import AppKit
import SwiftUI
import XCTest
@testable import Thresher

private func row(_ id: String, account: String, subject: String = "Subject",
                 tier: Int = 3, state: String = "new") -> MessageListRow {
    MessageListRow(id: id, account: account, threadID: nil,
                   senderName: "Sender", senderEmail: "s@x.example",
                   subject: subject, receivedAt: "2026-07-26T12:00:00+00:00",
                   ingestedAt: "2026-07-26T12:00:00+00:00",
                   preview: "preview", urgencyTier: tier, category: "work",
                   triageState: state)
}

private final class RowsAPI: MessageAPI, @unchecked Sendable {
    let all: [MessageListRow]
    init(_ all: [MessageListRow]) { self.all = all }
    func listMessages() async throws -> [MessageListRow] { all }
    func listMessages(states: [String]?) async throws -> [MessageListRow] {
        guard let states else { return all }
        return all.filter { states.contains($0.triageState ?? "") }
    }
    func messageCounts() async throws -> TriageCounts {
        TriageCounts(new: all.count, acknowledged: 0, needsAction: 0, done: 0,
                     unclassified: 0)
    }
    func searchMessages(query: String) async throws -> [MessageListRow] { all }
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
final class AccountBadgeTests: XCTestCase {

    private func model(_ rows: [MessageListRow]) async -> MessageListViewModel {
        let m = MessageListViewModel(
            api: RowsAPI(rows),
            defaults: UserDefaults(suiteName: "test.acct.\(UUID().uuidString)")!)
        await m.loadInitial()
        return m
    }

    // ── When the badge appears ────────────────────────────────────────────────

    func testTheBadgeIsHIDDENWithASingleAccount() async {
        let m = await model([row("a:1", account: "you@example.com"),
                             row("a:2", account: "you@example.com")])
        XCTAssertFalse(m.showsAccountBadge,
                       "a single-account user must see no new chrome")
    }

    func testTheBadgeAPPEARSWhenTwoMailboxesAreInView() async {
        let m = await model([row("a:1", account: "you@example.com"),
                             row("b:1", account: "hello@example.org")])
        XCTAssertTrue(m.showsAccountBadge)
    }

    func testAnEmptyListDoesNotShowTheBadge() async {
        let m = await model([])
        XCTAssertFalse(m.showsAccountBadge)
    }

    // ── The label ─────────────────────────────────────────────────────────────

    func testTheLabelIsTheLocalPartNotTheWholeAddress() {
        // "you" and "hello" are scannable; the full addresses are long, share
        // no useful prefix, and would push the badge row toward clipping.
        // The two addresses deliberately differ in their LOCAL PART, which is
        // the whole point — two accounts must produce two distinguishable
        // badges, so a fixture where both sides share a local part would assert
        // nothing.
        XCTAssertEqual(AccountBadge.shortLabel("you@example.com"), "you")
        XCTAssertEqual(AccountBadge.shortLabel("hello@example.org"), "hello")
    }

    func testTheLabelDegradesRatherThanGoingBlank() {
        // Whatever the server sends, the badge must never render empty.
        XCTAssertEqual(AccountBadge.shortLabel("no-at-sign"), "no-at-sign")
        XCTAssertEqual(AccountBadge.shortLabel("@leading"), "@leading")
        XCTAssertEqual(AccountBadge.shortLabel(""), "")
    }

    // ── Render evidence: present with two, ABSENT with one ───────────────────

    private static let evidenceDir = URL(fileURLWithPath: "/tmp/thresher-accounts")

    private func render(_ rows: [MessageListRow], to filename: String,
                        width: CGFloat = 420) async throws {
        try? FileManager.default.createDirectory(at: Self.evidenceDir,
                                                 withIntermediateDirectories: true)
        let m = await model(rows)
        let view = MessageListView(model: m, selection: .constant(nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(
            rootView: view.frame(width: width, height: 460).preferredColorScheme(.light))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        defer { window.close() }

        let content = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: Self.evidenceDir.appendingPathComponent(filename))
    }

    func testRenderEvidenceBadgePresentAndAbsent() async throws {
        let twoAccounts = [
            row("you@example.com:1", account: "you@example.com",
                subject: "Q3 planning deck", tier: 1),
            row("hello@example.org:1", account: "hello@example.org",
                subject: "Invoice #2291 attached", tier: 2),
            row("you@example.com:2", account: "you@example.com",
                subject: "Your flight itinerary", tier: 3),
        ]
        try await render(twoAccounts, to: "rows-two-accounts.png")
        // Narrow, because the chip row already clips at ~320pt and row chrome must
        // not make the ROW clip too.
        try await render(twoAccounts, to: "rows-two-accounts-narrow-320.png", width: 320)
        // The control case: one account ⇒ no badge at all.
        try await render([row("you@example.com:1", account: "you@example.com",
                              subject: "Q3 planning deck", tier: 1)],
                         to: "rows-one-account.png")
    }
}
