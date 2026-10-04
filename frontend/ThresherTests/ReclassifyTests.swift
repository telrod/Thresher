//
//  ReclassifyTests.swift
//  ThresherTests
//
//  D52 — reclassify on demand, client side.
//
//  The invariants are enforced by the SERVER (see backend/tests/test_api.py), so what
//  needs pinning here is that the client doesn't undo them at the seam:
//
//   - the triage state shown after a reclassification is the SERVER's, not the local
//     copy — that is how invariant 1 is asserted rather than assumed;
//   - the staleness note disappears after a re-run, because the classification is now
//     newer than every rule edit (a stale warning left on screen is a lie);
//   - "no change" reports as a real outcome, not as a failure;
//   - the dated line says "Reclassified" once a re-run has happened, and "Classified"
//     before (part D's whole point is that the fossil is legible).
//

import XCTest
import AppKit
import SwiftUI
@testable import Thresher

private func detail(tier: Int?, category: String?, state: String?,
                    classifiedAt: String? = "2026-01-01T00:00:00+00:00",
                    reclassifiedAt: String? = nil,
                    rulesChangedSince: Int? = 0) -> MessageDetail {
    MessageDetail(
        id: "acct:1", account: "acct", threadID: nil, senderName: "S",
        senderEmail: "s@x.example", subject: "subj",
        receivedAt: "2026-01-01T00:00:00+00:00",
        ingestedAt: "2026-01-01T00:00:00+00:00", preview: nil,
        bodyPlain: "body", bodyHTML: nil, urgencyTier: tier, category: category,
        triageState: state, explanation: "why", ruleMatches: nil,
        rfc822MessageID: nil, classifiedAt: classifiedAt,
        reclassifiedAt: reclassifiedAt, rulesChangedSince: rulesChangedSince)
}

private final class ReclassifyAPI: MessageAPI, @unchecked Sendable {
    var current: MessageDetail
    /// What the server will "return" — deliberately settable so a test can prove the
    /// client takes the server's triage state rather than keeping its own.
    var result: ReclassifyResult
    var explainCalls = 0
    init(current: MessageDetail, result: ReclassifyResult) {
        self.current = current
        self.result = result
    }

    func listMessages() async throws -> [MessageListRow] { [] }
    func listMessages(states: [String]?) async throws -> [MessageListRow] { [] }
    func messageCounts() async throws -> TriageCounts {
        TriageCounts(new: 0, acknowledged: 0, needsAction: 0, done: 0, unclassified: 0)
    }
    func searchMessages(query: String) async throws -> [MessageListRow] { [] }
    func preferences() async throws -> Preferences { throw APIError.badURL }
    func getMessage(id: String) async throws -> MessageDetail { current }
    func explain(id: String) async throws -> Explanation? { explainCalls += 1; return nil }
    func thread(id: String) async throws -> [MessageListRow] { [] }
    func setTriage(id: String, state: TriageState) async throws -> TriageUpdateResponse {
        throw APIError.badURL
    }
    func notifications(since: Int) async throws -> NotificationFeed { throw APIError.badURL }
    func reclassify(id: String) async throws -> ReclassifyResult { result }
    func reclassifyAll() async throws -> ReclassifySummary { throw APIError.badURL }
    func claimDelivery(forSeconds seconds: Int) async throws {}
}

private func result(tier: Int, category: String, state: String, changed: Bool,
                    previousTier: Int? = nil) -> ReclassifyResult {
    ReclassifyResult(
        messageID: "acct:1", urgencyTier: tier, category: category,
        triageState: state, classifiedAt: "2026-06-01T00:00:00+00:00",
        reclassifiedAt: "2026-06-01T00:00:00+00:00", changed: changed,
        previousTier: previousTier, previousCategory: nil, rulesChangedSince: 0)
}

@MainActor
final class ReclassifyTests: XCTestCase {

    func testTheDisplayedTriageStateComesFromTheSERVER_D52_invariant_1() async {
        // Local copy says "done". The server echoes "done" back — the client must
        // render the server's value, so a server-side regression would be visible
        // here rather than masked by the local copy.
        let api = ReclassifyAPI(current: detail(tier: 5, category: "unknown", state: "done"),
                                result: result(tier: 1, category: "work", state: "done",
                                               changed: true, previousTier: 5))
        let model = MessageDetailViewModel(messageID: "acct:1", api: api)
        await model.load()
        await model.reclassify()

        XCTAssertEqual(model.detail?.triageState, "done",
                       "reclassification must not reset triage state")
        XCTAssertEqual(model.detail?.urgencyTier, 1, "the new tier should be applied")
        XCTAssertEqual(model.detail?.category, "work")
    }

    func testStalenessNoteClearsAfterAReRun_D52() async {
        // Three rules had changed; after reclassifying, the classification is newer
        // than all of them, so leaving the warning up would be a lie.
        let api = ReclassifyAPI(
            current: detail(tier: 4, category: "unknown", state: "new",
                            rulesChangedSince: 3),
            result: result(tier: 2, category: "work", state: "new", changed: true))
        let model = MessageDetailViewModel(messageID: "acct:1", api: api)
        await model.load()
        XCTAssertEqual(model.detail?.stalenessNote, "3 rules have changed since")

        await model.reclassify()
        XCTAssertNil(model.detail?.stalenessNote, "the staleness note must clear")
    }

    func testNoChangeIsReportedAsAnOutcomeNotAFailure_D52() async {
        let api = ReclassifyAPI(current: detail(tier: 3, category: "work", state: "new"),
                                result: result(tier: 3, category: "work", state: "new",
                                               changed: false, previousTier: 3))
        let model = MessageDetailViewModel(messageID: "acct:1", api: api)
        await model.load()
        await model.reclassify()

        XCTAssertNil(model.errorMessage, "\"no change\" is not an error")
        XCTAssertEqual(model.lastReclassifyNote,
                       "No change — the current rules produce the same result")
    }

    func testTheStructuredExplanationIsRefetchedAfterAReRun_D52() async {
        // The rules that matched have changed, so a stale breakdown would be
        // actively misleading (P3).
        let api = ReclassifyAPI(current: detail(tier: 4, category: "unknown", state: "new"),
                                result: result(tier: 1, category: "work", state: "new",
                                               changed: true))
        let model = MessageDetailViewModel(messageID: "acct:1", api: api)
        await model.load()
        let before = api.explainCalls
        await model.reclassify()
        XCTAssertGreaterThan(api.explainCalls, before,
                             "the rule breakdown must be refetched after a re-run")
    }

    // ── Part D: the dated line ────────────────────────────────────────────────

    func testDatedLineSaysClassifiedBeforeAndReclassifiedAfter_D52() {
        let fresh = detail(tier: 3, category: "work", state: "new")
        XCTAssertTrue(fresh.classificationDateLine?.hasPrefix("Classified") == true,
                      "got \(String(describing: fresh.classificationDateLine))")

        let rerun = detail(tier: 3, category: "work", state: "new",
                           reclassifiedAt: "2026-06-01T12:00:00+00:00")
        XCTAssertTrue(rerun.classificationDateLine?.hasPrefix("Reclassified") == true,
                      "got \(String(describing: rerun.classificationDateLine))")
    }

    func testDatedLineParsesStampsWithAndWithoutFractionalSeconds_D52() {
        // The backend writes isoformat(), which includes microseconds only when
        // they're non-zero — a strict fractional parser drops the line at random.
        XCTAssertNotNil(detail(tier: 1, category: "work", state: "new",
                               classifiedAt: "2026-06-01T12:00:00+00:00")
                            .classificationDateLine)
        XCTAssertNotNil(detail(tier: 1, category: "work", state: "new",
                               classifiedAt: "2026-06-01T12:00:00.123456+00:00")
                            .classificationDateLine)
    }

    func testNoStalenessNoteWhenNothingIsKnownToHaveChanged_D52() {
        XCTAssertNil(detail(tier: 1, category: "work", state: "new",
                            rulesChangedSince: 0).stalenessNote)
        XCTAssertNil(detail(tier: 1, category: "work", state: "new",
                            rulesChangedSince: nil).stalenessNote)
        XCTAssertEqual(detail(tier: 1, category: "work", state: "new",
                              rulesChangedSince: 1).stalenessNote,
                       "1 rule has changed since")
    }

    // ── Part C: the bulk summary line ─────────────────────────────────────────

    func testBulkSummaryLineNamesErrorsRatherThanSwallowingThem_D52() {
        let clean = ReclassifySummary(counted: 1592, changed: 38, unchanged: 1554, errors: 0)
        XCTAssertEqual(clean.summaryLine,
                       "Reclassified 1592 messages — 38 changed, 1554 unchanged")

        let withErrors = ReclassifySummary(counted: 10, changed: 2, unchanged: 7, errors: 1)
        XCTAssertTrue(withErrors.summaryLine.contains("1 failed"),
                      "a failed message is still stored (P1) and the user should know")
    }
}

// ── D52 render evidence: the explain panel's dated + staleness copy ──────────

/// Part D is copy the user reads, so a picture is the only real verification — the
/// OI18 lesson (a passing test and a legible screen are different claims).
@MainActor
final class ReclassifyRenderEvidenceTests: XCTestCase {

    private static let evidenceDir = URL(fileURLWithPath: "/tmp/thresher-d52")

    private func render(_ detailToShow: MessageDetail, to filename: String) async throws {
        try? FileManager.default.createDirectory(at: Self.evidenceDir,
                                                 withIntermediateDirectories: true)
        let api = ReclassifyAPIEvidence(current: detailToShow)
        // Load BEFORE rendering: .task can't finish while the capture blocks the run
        // loop, so a self-loading view photographs as a spinner (it did).
        let model = MessageDetailViewModel(messageID: detailToShow.id, api: api)
        await model.load()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(
            rootView: MessageDetailView(model: model)
                .frame(width: 620, height: 620)
                .preferredColorScheme(.light))
        window.orderFrontRegardless()
        // The view loads itself in .task, so pump the run loop in slices until the
        // panel is really on screen. A single fixed sleep captured only the spinner
        // and the test still "passed" — evidence of nothing, which is worse than a
        // failure. So: wait for real ink, then assert we got it.
        var painted = false
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            if let v = window.contentView,
               let probe = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: probe)
                // Count inked scanlines across the whole window. A spinner-only
                // frame inks a handful of rows in one small central patch; the loaded
                // panel inks many, spread down the view. (The first probe sampled the
                // top 80pt — legitimately empty here, because the detail view has a
                // top inset, so it failed a render that was actually fine.)
                if Self.inkedScanlines(probe) > 12 {
                    painted = true
                    break
                }
            }
        }
        XCTAssertTrue(painted, "the detail panel never rendered — the PNG would be a "
                      + "spinner, which is evidence of nothing")
        defer { window.close() }

        let content = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: Self.evidenceDir.appendingPathComponent(filename))
    }

    /// How many scanlines contain non-background ink. Distinguishes "spinner only"
    /// (a few, clustered) from "panel rendered" (many, spread out).
    static func inkedScanlines(_ rep: NSBitmapImageRep) -> Int {
        guard let bg = rep.colorAt(x: 1, y: 1) else { return 0 }
        var count = 0
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y) {
                    let d = abs(c.redComponent - bg.redComponent)
                          + abs(c.greenComponent - bg.greenComponent)
                          + abs(c.blueComponent - bg.blueComponent)
                    if d > 0.12 { count += 1; break }
                }
                x += 4
            }
            y += 2
        }
        return count
    }

    func testRenderEvidenceExplainPanelDatedAndStale_D52() async throws {
        // Fresh: "Classified <date>", no staleness warning.
        try await render(detail(tier: 2, category: "work", state: "new"),
                         to: "explain-classified.png")
        // Stale: rules have changed since, so the warning shows — the case the whole
        // of part D exists for.
        try await render(detail(tier: 4, category: "unknown", state: "done",
                                rulesChangedSince: 3),
                         to: "explain-stale-3-rules.png")
        // Already re-run: the line reads "Reclassified <date>".
        try await render(detail(tier: 1, category: "personal", state: "done",
                                reclassifiedAt: "2026-07-26T13:50:31.475800+00:00"),
                         to: "explain-reclassified.png")
    }
}

/// A read-only fake for the render pass (the action isn't exercised here).
private final class ReclassifyAPIEvidence: MessageAPI, @unchecked Sendable {
    let current: MessageDetail
    init(current: MessageDetail) { self.current = current }
    func listMessages() async throws -> [MessageListRow] { [] }
    func listMessages(states: [String]?) async throws -> [MessageListRow] { [] }
    func messageCounts() async throws -> TriageCounts {
        TriageCounts(new: 0, acknowledged: 0, needsAction: 0, done: 0, unclassified: 0)
    }
    func searchMessages(query: String) async throws -> [MessageListRow] { [] }
    func preferences() async throws -> Preferences { throw APIError.badURL }
    func getMessage(id: String) async throws -> MessageDetail { current }
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
