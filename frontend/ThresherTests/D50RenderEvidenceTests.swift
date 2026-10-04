//
//  D50RenderEvidenceTests.swift
//  ThresherTests
//
//  Render evidence for the D50 chip contract (workorder DoD: screenshots of
//  the chips in each state, incl. the Done disclosure collapsed AND expanded).
//  Follows the SettingsWindowLayoutTests pattern: hosted in the real app, the
//  view renders in a real NSWindow and the window content is cached to PNG
//  under /tmp/thresher-d50/. The assertions keep it a test (chips exist,
//  All splits Done out of the main run); the PNGs are the workorder record.
//

import AppKit
import SwiftUI
import XCTest
@testable import Thresher

private final class EvidenceAPI: MessageAPI, @unchecked Sendable {
    let all: [MessageListRow]
    /// OI18: the counts endpoint is STORE-WIDE, so the rendered chip counts are
    /// not the fixture's row count — at the alpha store they are four digits
    /// while the page holds 100 rows. Overriding the counts independently of the
    /// rows is what lets a test render the chips at real-data widths; deriving
    /// them from a 5-row fixture is exactly how the wrap bug shipped.
    let countsOverride: TriageCounts?
    init(all: [MessageListRow], countsOverride: TriageCounts? = nil) {
        self.all = all
        self.countsOverride = countsOverride
    }

    func listMessages() async throws -> [MessageListRow] { all }
    func listMessages(states: [String]?) async throws -> [MessageListRow] {
        guard let states else { return all }
        return all.filter { states.contains($0.triageState ?? "") }
    }
    func messageCounts() async throws -> TriageCounts {
        if let countsOverride { return countsOverride }
        return TriageCounts(new: all.filter { $0.triageState == "new" }.count,
                     acknowledged: all.filter { $0.triageState == "acknowledged" }.count,
                     needsAction: all.filter { $0.triageState == "needs_action" }.count,
                     done: all.filter { $0.triageState == "done" }.count,
                     unclassified: all.filter { $0.triageState == nil }.count)
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
final class D50RenderEvidenceTests: XCTestCase {

    private static let evidenceDir = URL(fileURLWithPath: "/tmp/thresher-d50")

    private func fixtureRows() -> [MessageListRow] {
        func mk(_ n: Int, tier: Int, state: String?, subject: String) -> MessageListRow {
            MessageListRow(id: "acct:e\(n)", account: "acct", threadID: nil,
                           senderName: "Sender \(n)", senderEmail: "s\(n)@example.com",
                           subject: subject,
                           receivedAt: "2026-07-17T0\(n):00:00+00:00",
                           ingestedAt: "2026-07-17T0\(n):00:00+00:00",
                           preview: "preview \(n)", urgencyTier: tier,
                           category: "work", triageState: state)
        }
        return [mk(1, tier: 1, state: "new", subject: "Urgent: budget"),
                mk(2, tier: 2, state: "needs_action", subject: "Review my doc"),
                mk(3, tier: 3, state: "acknowledged", subject: "Newsletter"),
                mk(4, tier: 4, state: "done", subject: "Receipt"),
                mk(5, tier: 5, state: "done", subject: "Sale!")]
    }

    /// The real alpha store's shape at the Session 27 gate (1,479 total) — the
    /// counts that made the chips wrap. Four digits in every wide chip.
    private static let realWidthCounts = TriageCounts(
        new: 1452, acknowledged: 7, needsAction: 0, done: 20, unclassified: 0,
        urgentNew: 4)

    private func render(filter: TriageFilter, doneExpanded: Bool,
                        to filename: String,
                        counts: TriageCounts? = nil,
                        width: CGFloat = 420) async throws {
        let defaults = UserDefaults(suiteName: "test.d50-render.\(UUID().uuidString)")!
        let model = MessageListViewModel(
            api: EvidenceAPI(all: fixtureRows(), countsOverride: counts),
            defaults: defaults)
        model.filter = filter
        await model.loadInitial()

        let view = MessageListView(model: model, selection: .constant(nil),
                                   doneInitiallyExpanded: doneExpanded)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // ARC owns it; close() must not over-release
        // Pin one appearance: an offscreen window otherwise mixes light chrome
        // with dark-mode-resolved text, rendering unselected chips invisible.
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: view.frame(width: width, height: 560).preferredColorScheme(.light))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        defer { window.close() }

        let content = window.contentView!
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: Self.evidenceDir.appendingPathComponent(filename))
    }

    func testRenderEvidenceAllChipStates() async throws {
        try? FileManager.default.createDirectory(at: Self.evidenceDir,
                                                 withIntermediateDirectories: true)
        try await render(filter: .open, doneExpanded: false, to: "chip-open.png")
        try await render(filter: .needsAction, doneExpanded: false, to: "chip-needs-action.png")
        try await render(filter: .done, doneExpanded: false, to: "chip-done.png")
        try await render(filter: .all, doneExpanded: false, to: "chip-all-done-collapsed.png")
        try await render(filter: .all, doneExpanded: true, to: "chip-all-done-expanded.png")

        // Keep it a test, not just a camera: the All view's main run excludes
        // Done rows (they live in the disclosure), and the fixture exercises
        // every chip's count path.
        let model = MessageListViewModel(
            api: EvidenceAPI(all: fixtureRows()),
            defaults: UserDefaults(suiteName: "test.d50-render.assert")!)
        model.filter = .all
        await model.loadInitial()
        XCTAssertEqual(model.rows.filter { $0.triage != .done }.count, 3,
                       "All's main run: new + needs_action + acknowledged")
        XCTAssertEqual(model.rows.filter { $0.triage == .done }.count, 2,
                       "All's Done disclosure holds the rest")
        let counts = try XCTUnwrap(model.counts)
        XCTAssertEqual(TriageFilter.open.count(in: counts), 2)
        XCTAssertEqual(TriageFilter.all.count(in: counts), 5)
    }

    // ── OI18: chips at real-data widths ─────────────────────────────────────

    /// OI18 (Session 27 gate): the chip labels and counts wrapped at the real
    /// store's four-digit counts — "Open" rendered "Op/en", "1,479" rendered
    /// "1,47/9". A wrapped count is actively misleading, because the counts ARE
    /// the chips' payload.
    ///
    /// This test exists because the D50 workorder's render evidence used a
    /// five-row fixture, so every chip count was one digit and the bug was
    /// unreachable — the same "the corpus never violated the convention" shape
    /// as OI19 in the same gate. Here the counts come from `realWidthCounts`
    /// (the actual gate-day totals) independently of the fixture rows.
    ///
    /// The assertion is on rendered GEOMETRY, not on the model: every chip must
    /// occupy a single text line. A one-line chip's height stays near the text
    /// line height; a wrapped chip is roughly twice as tall. That is the
    /// distinction only a rendered window can make (the E16/OI14 lesson).
    func testChipsDoNotWrapAtRealDataWidths_OI18() async throws {
        try? FileManager.default.createDirectory(at: Self.evidenceDir,
                                                 withIntermediateDirectories: true)

        // Render evidence at the real counts, at the default width and at a
        // deliberately narrow one (the window-minimum case the workorder says to
        // flag rather than invent an alternative for).
        try await render(filter: .open, doneExpanded: false,
                         to: "oi18-chips-real-counts-420.png",
                         counts: Self.realWidthCounts, width: 420)
        try await render(filter: .all, doneExpanded: false,
                         to: "oi18-chips-real-counts-narrow-320.png",
                         counts: Self.realWidthCounts, width: 320)

        // Geometry: prove the chip row is ONE text line.
        //
        // Measured at a CONSTRAINED width, not the roomy default. At 420pt the
        // four chips fit regardless, so the assertion would pass even against the
        // pre-fix layout and guard nothing (verified: it did). The wrap only
        // becomes reachable once the chips are asked to fit a narrower window —
        // which is exactly the real-world condition the gate hit. Squeezing the
        // window is the reliable way to make the bug reproducible on demand.
        let probeWidth: CGFloat = 300
        let defaults = UserDefaults(suiteName: "test.d50-oi18.\(UUID().uuidString)")!
        let model = MessageListViewModel(
            api: EvidenceAPI(all: fixtureRows(), countsOverride: Self.realWidthCounts),
            defaults: defaults)
        model.filter = .open
        await model.loadInitial()

        let view = MessageListView(model: model, selection: .constant(nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: probeWidth, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(
            rootView: view.frame(width: probeWidth, height: 560).preferredColorScheme(.light))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        defer { window.close() }

        // The counts really are four digits — otherwise this test proves nothing.
        XCTAssertEqual(TriageFilter.all.count(in: Self.realWidthCounts), 1479)
        XCTAssertEqual(TriageFilter.open.count(in: Self.realWidthCounts), 1452)

        // Measure the RENDERED PIXELS. SwiftUI text on macOS is drawn directly
        // rather than parked in CATextLayers, so walking the layer tree for
        // strings finds nothing (tried; the probe reported its own breakage).
        // The pixel test is also the more honest one: it measures what a human
        // at the window would see, which is the whole point of OI18.
        let root = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)

        // The chip bar is the FIRST contiguous band of ink below the top edge;
        // the list content starts after a clear gap. Measuring "all ink in the
        // top N points" would fold the first message row into the measurement
        // (it did, on the first attempt: 8pt padding + a 24pt chip band + list
        // ink from y=40 read as one 48pt band and failed a correct layout).
        // So: take the first band only, bounded by the gap that follows it.
        let bands = Self.inkBands(in: rep)
        let chipBand = try XCTUnwrap(bands.first,
                                     "no ink found at all — the probe is broken, not the layout")

        let scale = CGFloat(rep.pixelsHigh) / root.bounds.height
        let chipBandPoints = CGFloat(chipBand.height) / max(scale, 1)

        // One capsule row of caption-sized text ≈ 24pt. A wrapped chip row is two
        // text lines plus the same padding — measured at 40pt+ when this test was
        // verified red against the pre-fix layout.
        XCTAssertLessThan(
            chipBandPoints, 34,
            "the chip bar rendered \(chipBandPoints)pt tall at real four-digit counts — "
            + "that is a wrapped (multi-line) chip row, which is OI18")
    }

    /// Contiguous vertical runs of non-background ink, top-down. Background is
    /// sampled from the very top-left pixel, which the chip bar's padding
    /// guarantees is empty.
    private struct InkBand { let top: Int; let bottom: Int; var height: Int { bottom - top + 1 } }

    private static func inkBands(in rep: NSBitmapImageRep,
                                 searchRows: Int = 200) -> [InkBand] {
        guard let bg = rep.colorAt(x: 1, y: 1) else { return [] }
        func inked(_ y: Int) -> Bool {
            var x = 0
            while x < rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y) {
                    let d = abs(c.redComponent - bg.redComponent)
                          + abs(c.greenComponent - bg.greenComponent)
                          + abs(c.blueComponent - bg.blueComponent)
                          + abs(c.alphaComponent - bg.alphaComponent)
                    if d > 0.12 { return true }
                }
                x += 4   // chip glyphs are far wider than a 4px stride
            }
            return false
        }

        var bands: [InkBand] = []
        var start: Int? = nil
        var gap = 0
        for y in 0..<min(rep.pixelsHigh, searchRows) {
            if inked(y) {
                if start == nil { start = y }
                gap = 0
            } else if let s = start {
                gap += 1
                // Two clear scanlines end a band (glyph interiors have 1px gaps).
                if gap >= 2 {
                    bands.append(InkBand(top: s, bottom: y - gap))
                    start = nil
                    gap = 0
                }
            }
        }
        if let s = start { bands.append(InkBand(top: s, bottom: min(rep.pixelsHigh, searchRows) - 1)) }
        return bands
    }
}
