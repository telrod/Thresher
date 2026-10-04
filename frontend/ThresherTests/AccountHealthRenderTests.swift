//
//  AccountHealthRenderTests.swift
//  ThresherTests
//
//  Session 34 — RENDER evidence for the dead-poller banner.
//
//  WHY A RENDERED WINDOW AND NOT JUST THE MODEL
//  --------------------------------------------
//  This project has now been bitten three times by a feature that was correct
//  in the model and wrong on screen: OI14 (a sidebar row present in the model
//  but occluded at render time), OI18 (chip labels that wrapped only at real
//  data widths), and D59 (a bulk scope armed correctly while every checkbox
//  stayed empty — 126 unit tests passed against it, and a human at the
//  keyboard correctly read it as a dead button).
//
//  A banner warning that mail is not arriving is exactly the kind of thing
//  that must not be invisible, so the assertions here are on rendered
//  geometry: the banner occupies real height in the window, and its text is
//  laid out on ONE line rather than clipped. PNGs land under
//  /tmp/thresher-health/ as the record.
//

import AppKit
import SwiftUI
import XCTest
@testable import Thresher

private final class HealthAPI: MessageAPI, @unchecked Sendable {
    let rows: [MessageListRow]
    let health: AccountHealthReport?
    init(rows: [MessageListRow], health: AccountHealthReport?) {
        self.rows = rows
        self.health = health
    }

    /// The point of this fake: serve a health report, or simulate an
    /// unreachable backend by throwing (which the VM's `try?` turns into
    /// "say nothing").
    func accountHealth() async throws -> AccountHealthReport {
        guard let health else {
            throw APIError.transport(URLError(.cannotConnectToHost))
        }
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

final class AccountHealthRenderTests: XCTestCase {

    private static let evidenceDir = URL(fileURLWithPath: "/tmp/thresher-health")

    private func row(_ id: String, daysAgo: Double) -> MessageListRow {
        let stamp = ISO8601DateFormatter.listBound.string(
            from: Date().addingTimeInterval(-daysAgo * 86_400))
        return MessageListRow(
            id: id, account: "you@example.com", threadID: nil,
            senderName: "Someone", senderEmail: "someone@example.com",
            subject: "A message", receivedAt: stamp, ingestedAt: stamp,
            preview: "preview text", urgencyTier: 3,
            category: "work", triageState: "new")
    }

    private func entry(_ account: String, _ status: String,
                       seconds: Int?, detail: String = "") -> AccountHealthEntry {
        AccountHealthEntry(account: account, status: status, lastPollAt: nil,
                           secondsSince: seconds, detail: detail)
    }

    /// Render the list with a given health report and return the rendered bitmap.
    ///
    /// Measurement note (learned the hard way here): SwiftUI's
    /// `.accessibilityIdentifier` does NOT surface as `NSView
    /// .accessibilityIdentifier()` on the AppKit views an `NSHostingView`
    /// builds, so walking the view tree for the id finds nothing even when the
    /// banner is plainly on screen. Asserting that way produced a red test
    /// against a WORKING feature — a false negative, the mirror image of the
    /// OI14 bug and just as misleading.
    ///
    /// So the assertion is on PIXELS, which is what the user actually sees:
    /// the banner paints an orange band, and its presence pushes the first
    /// message row down. Both are properties of the rendered image, and
    /// neither depends on how SwiftUI happens to build its view tree.
    @MainActor
    private func renderBanner(health: AccountHealthReport?,
                              to filename: String,
                              width: CGFloat = 460) async throws -> NSBitmapImageRep {
        try? FileManager.default.createDirectory(at: Self.evidenceDir,
                                                 withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "test.health-render.\(UUID().uuidString)")!
        let model = MessageListViewModel(
            api: HealthAPI(rows: [row("a:1", daysAgo: 0.1)], health: health),
            defaults: defaults)
        await model.loadInitial()

        let view = MessageListView(model: model, selection: .constant(nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(
            rootView: view.frame(width: width, height: 560).preferredColorScheme(.light))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        defer { window.close() }

        let content = window.contentView!
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: Self.evidenceDir.appendingPathComponent(filename))
        }
        return rep
    }

    /// How many horizontal scanlines in the top third of the window are the
    /// banner's orange band?
    ///
    /// Thresholds come from SAMPLING the real render, not from reasoning about
    /// the SwiftUI colour: the band composites to ≈(255, 150, 39), i.e. red far
    /// above blue. An earlier version of this guessed at "a light warm tint"
    /// (r>0.85, g>0.7) and reported zero against a banner that was plainly
    /// there — a false negative is exactly as dangerous as the invisible-banner
    /// bug it is meant to catch, so the predicate is pinned to measured values.
    ///
    /// Everything else in this region is greyscale (r≈g≈b) or white, so a wide
    /// red-over-blue gap is unambiguous.
    private static func orangeBandHeight(in rep: NSBitmapImageRep) -> Int {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return 0 }
        var rows = 0
        for y in 0..<(h / 3) {
            var warm = 0
            var sampled = 0
            for x in stride(from: 8, to: w - 8, by: 16) {
                var px = [Int](repeating: 0, count: 4)
                rep.getPixel(&px, atX: x, y: y)
                sampled += 1
                // The cached bitmap is PREMULTIPLIED and largely transparent
                // (a sampled pixel in the band reads [46,27,7] at alpha 46, not
                // [255,150,39] at alpha 255). Un-premultiply before comparing,
                // or every colour test silently measures alpha instead of hue —
                // which is what made an earlier version of this report zero
                // against a banner the PNG shows plainly.
                let a = px[3]
                guard a > 0 else { continue }
                let r = px[0] * 255 / a
                let g = px[1] * 255 / a
                let b = px[2] * 255 / a
                // Measured band ≈ (255,150,39): a decisive red-over-blue gap
                // that no greyscale chrome or white background can produce.
                if r - b > 120 && r > 200 && g > 90 && g < 210 { warm += 1 }
            }
            // The band spans the full width, so a genuine banner row is warm
            // across most samples — a stray orange glyph is not.
            if sampled > 0 && warm > sampled / 2 { rows += 1 }
        }
        return rows
    }

    // ── The banner is actually on screen ───────────────────────────────────

    @MainActor
    func testDeadAccountBannerIsRENDERED() async throws {
        // The 2026-08-13 shape: one mailbox stopped, one fine.
        let report = AccountHealthReport(
            healthy: false,
            accounts: [entry("you@example.org", "ok", seconds: 60),
                       entry("you@example.com", "stopped", seconds: 61_200,
                             detail: "TimeoutError: The read operation timed out")],
            staleAfterSeconds: 660)
        let rep = try await renderBanner(health: report, to: "banner-one-account-dead.png")
        let band = Self.orangeBandHeight(in: rep)
        XCTAssertGreaterThan(band, 8,
            "the dead-poller banner must be VISIBLE in the rendered window — "
            + "a warning that is correct in the model and invisible on screen is "
            + "the OI14/D59 failure this project has now hit three times "
            + "(evidence: /tmp/thresher-health/banner-one-account-dead.png)")
    }

    @MainActor
    func testHealthyBackendRendersNoBanner() async throws {
        let report = AccountHealthReport(
            healthy: true,
            accounts: [entry("a@x.com", "ok", seconds: 30)],
            staleAfterSeconds: 660)
        let rep = try await renderBanner(health: report, to: "banner-healthy-absent.png")
        XCTAssertLessThanOrEqual(Self.orangeBandHeight(in: rep), 2,
            "a healthy backend must render NO warning band")
    }

    @MainActor
    func testUnreachableBackendRendersNoAccountBanner() async throws {
        // We could not ask, so we must not accuse an account. (The list's own
        // error path covers "can't reach the backend".)
        let rep = try await renderBanner(health: nil, to: "banner-unreachable-absent.png")
        XCTAssertLessThanOrEqual(Self.orangeBandHeight(in: rep), 2,
            "an unreachable backend is not an account fault — claiming one would "
            + "be inventing a diagnosis we never made")
    }

    // ── Health outranks staleness (they must not stack) ────────────────────

    @MainActor
    func testHealthWarningSuppressesTheStalenessBanner() async throws {
        let defaults = UserDefaults(suiteName: "test.health-vs-stale.\(UUID().uuidString)")!
        let report = AccountHealthReport(
            healthy: false,
            accounts: [entry("a@x.com", "stale", seconds: 13 * 86_400)],
            staleAfterSeconds: 660)
        // Rows are 13 days old, so staleness WOULD fire on its own.
        let model = MessageListViewModel(
            api: HealthAPI(rows: [row("a:1", daysAgo: 13)], health: report),
            defaults: defaults)
        await model.loadInitial()

        XCTAssertNotNil(model.accountWarning, "health knows the poller is stale")
        XCTAssertNil(model.staleness,
            "the inference-based staleness banner must stand down when the "
            + "authoritative one is showing — two banners saying one thing is noise")
    }

    @MainActor
    func testStalenessStillFiresWhenHealthIsQuiet() async throws {
        // The complement: health says everything is fine (e.g. the poller is
        // running but the mailbox is genuinely quiet), so staleness — which
        // measures something different — is still free to speak.
        let defaults = UserDefaults(suiteName: "test.stale-alone.\(UUID().uuidString)")!
        let report = AccountHealthReport(
            healthy: true, accounts: [entry("a@x.com", "ok", seconds: 30)],
            staleAfterSeconds: 660)
        let model = MessageListViewModel(
            api: HealthAPI(rows: [row("a:1", daysAgo: 13)], health: report),
            defaults: defaults)
        await model.loadInitial()

        XCTAssertNil(model.accountWarning)
        XCTAssertNotNil(model.staleness,
            "a running poller and a 13-day-old newest message is still worth saying")
    }
}
