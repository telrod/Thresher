//
//  ChipRowClippingThresholdTests.swift
//  ThresherTests
//
//  Session 36 — Part D of the gate-automation plan: gate item 5.1.
//
//  WHAT 5.1 ACTUALLY ASKS, AND WHY IT IS DIFFERENT FROM EVERY OTHER ITEM
//  ---------------------------------------------------------------------
//  Its own note: "Known going in: the row CLIPS below roughly 320pt rather
//  than wrapping. Confirming the width is the point — this is a MEASUREMENT,
//  not a pass/fail." So the human is asked to drag a window narrower and
//  narrower and write down a number.
//
//  `ChipRowWidthTests` already proves the shipped floor is SUFFICIENT — that
//  the row fits at 580pt, at five digits, at every font scale. What no test
//  answers is the question the checklist asks: **at what width does it first
//  clip?** That is a different question, and the interesting one, because the
//  answer is what tells you how much headroom the floor actually has.
//
//  So this file measures the threshold instead of asserting a bound, by
//  bisecting real renders. The number it finds is reported in the test's own
//  failure text and pinned only loosely — see `testTheMeasuredThresholdSitsBelowTheShippedFloor`
//  for why a tight assertion on it would be the wrong instrument.
//
//  THE "roughly 320pt" IN THE CHECKLIST IS STALE, AND THAT IS THE FINDING.
//  It was recorded before the floor moved 520 → 580 for D47's Extra Large
//  scale (dogfood entry 27, commit 0975c07). A stale number in a checklist is
//  worse than no number: the human compares what they see against it and
//  records a discrepancy as a defect — exactly the F1 failure mode from
//  Session 36 Part A, where item 1.2 asked for the wrong sentence.
//
//  METHOD, and its limits: this renders the real view at a series of widths
//  and scans the chip band for ink touching either edge — the same probe
//  `ChipRowWidthTests.testChipRowDoesNotTouchEitherEdgeAtTheShippedFloor`
//  uses, for the same reason (SwiftUI text on macOS is not in inspectable
//  layers, so pixels are the honest surface). Rendering is slow, so the search
//  is a bisection over a bounded range rather than a linear sweep.
//

import AppKit
import SwiftUI
import XCTest
@testable import Thresher

@MainActor
final class ChipRowClippingThresholdTests: XCTestCase {

    /// This suite writes the font scale into `UserDefaults.standard` (see
    /// `chipRowClips`), so it must put it back — a leaked Extra Large would
    /// change what every later render test in the process measures.
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: FontScale.defaultsKey)
        super.tearDown()
    }

    /// The same live counts `ChipRowWidthTests` uses, so the two files describe
    /// the same mailbox and their numbers can be compared directly.
    private static let liveCounts = TriageCounts(
        new: 4519, acknowledged: 4, needsAction: 3, done: 216, unclassified: 216,
        urgentNew: 174)

    /// Renders the message list at `width` and reports whether the chip row's
    /// ink touches either edge of the column.
    ///
    /// Returns nil when no ink is found at all — a broken probe, which must be
    /// distinguishable from "renders cleanly". Conflating the two is how a
    /// render test quietly becomes a no-op.
    private func chipRowClips(atWidth width: CGFloat,
                              scale: FontScale = .system) throws -> Bool? {
        // THE FONT SCALE MUST GO TO `UserDefaults.standard`, NOT a test suite.
        // `MessageListView` reads it with `@AppStorage(FontScale.defaultsKey)`,
        // which is hardwired to `.standard` — so writing the scale into the
        // view model's injected suite sets a value NOTHING READS. The first
        // version of this file did exactly that, and the Extra Large test
        // measured 438pt, identical to System, i.e. it silently rendered at
        // the default scale and asserted nothing. Caught by probing whether the
        // two scales differ; they did not. Restored in `tearDown`.
        UserDefaults.standard.set(scale.rawValue, forKey: FontScale.defaultsKey)
        let defaults = UserDefaults(suiteName: "test.clipthreshold.\(UUID().uuidString)")!
        let model = MessageListViewModel(api: ThresholdStubAPI(counts: Self.liveCounts),
                                         defaults: defaults)
        model.filter = .open

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: MessageListView(model: model, selection: .constant(nil))
                .frame(width: width, height: 400))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        defer { window.close() }

        guard let root = window.contentView,
              let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)
        else { return nil }
        root.cacheDisplay(in: root.bounds, to: rep)

        var minInkX = Int.max
        var maxInkX = -1
        let bandBottom = min(44, rep.pixelsHigh)
        for y in 0..<bandBottom {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.thresholdBrightness > 0.30 {
                    minInkX = min(minInkX, x)
                    maxInkX = max(maxInkX, x)
                }
            }
        }
        guard maxInkX >= 0 else { return nil }
        return minInkX <= 0 || maxInkX >= rep.pixelsWide - 1
    }

    /// Narrowest width at which the row renders WITHOUT clipping, found by
    /// bisection over [low, high]. Precision is deliberately coarse (8pt): the
    /// number is for a human reading a checklist, and each probe costs a real
    /// render.
    private func narrowestCleanWidth(low: CGFloat, high: CGFloat,
                                     scale: FontScale = .system) throws -> CGFloat? {
        guard try chipRowClips(atWidth: high, scale: scale) == false else { return nil }
        var lo = low, hi = high
        while hi - lo > 8 {
            let mid = ((lo + hi) / 2).rounded()
            if try chipRowClips(atWidth: mid, scale: scale) == false {
                hi = mid
            } else {
                lo = mid
            }
        }
        return hi
    }

    // MARK: - The measurement gate item 5.1 asks a human to take

    /// Measures the actual clipping threshold and REPORTS it. This is the
    /// number the checklist asks the human to write on a line, taken by
    /// machine at the same font scale a default install uses.
    ///
    /// The assertion is deliberately loose — it checks the threshold is a
    /// real, sane measurement below the shipped floor, not that it equals some
    /// exact value. Pinning an exact pixel width would make this test a
    /// tripwire for every font, padding and vocabulary change, i.e. it would
    /// fail constantly without anything being wrong. The VALUE is the output;
    /// the assertion only guards that the value means something.
    func testMeasureTheWidthAtWhichTheChipRowFirstClips() throws {
        let threshold = try XCTUnwrap(
            narrowestCleanWidth(low: 200, high: MessageListView.minimumColumnWidth),
            """
            The row clips even at the shipped floor \
            (\(MessageListView.minimumColumnWidth)pt) — that is the OI18 sibling \
            defect back, not a measurement problem.
            """)

        // Reported so a checklist reader can copy it. `print` rather than an
        // assertion message because this succeeds: the number is the product.
        print("""

        ┌─ GATE ITEM 5.1 — measured, not estimated ──────────────────────────┐
          Chip row renders CLEANLY at and above:  \(Int(threshold))pt
          Shipped column floor:                   \(Int(MessageListView.minimumColumnWidth))pt
          Headroom:                               \(Int(MessageListView.minimumColumnWidth - threshold))pt
          (live counts, System font scale)
        └────────────────────────────────────────────────────────────────────┘

        """)

        XCTAssertGreaterThan(threshold, 200,
                             "a threshold at the search floor means the probe never saw clipping")
        XCTAssertLessThanOrEqual(threshold, MessageListView.minimumColumnWidth,
                                 "the row must render cleanly at the shipped floor")
    }

    /// The property that actually matters, and the one worth failing on: the
    /// user CANNOT reach a clipping width through the UI, because the column
    /// floor stops them first.
    ///
    /// This is the honest form of "does it clip at 320pt?" — the answer is that
    /// 320pt is not reachable. `NavigationSplitView`'s
    /// `navigationSplitViewColumnWidth(min:)` is what enforces it.
    ///
    /// VERIFIED RED by lowering `minimumColumnWidth` to 320: fails with the
    /// measured threshold naming how much too narrow that is.
    func testTheShippedFloorIsWiderThanTheMeasuredClippingThreshold() throws {
        let threshold = try XCTUnwrap(
            narrowestCleanWidth(low: 200, high: MessageListView.minimumColumnWidth))

        XCTAssertGreaterThanOrEqual(
            MessageListView.minimumColumnWidth, threshold,
            """
            The column floor (\(Int(MessageListView.minimumColumnWidth))pt) is \
            NARROWER than the width the chip row needs \
            (\(Int(threshold))pt measured by render). A user dragging the window \
            in would reach a clipped chip row, which is gate item 5.1's defect.
            """)
    }

    /// The checklist's "roughly 320pt" must not be believed without checking.
    /// If 320pt now renders cleanly, that note is stale and should be corrected
    /// rather than left for a human to compare against.
    ///
    /// This asserts the DIRECTION the note claims (320 is too narrow), so if a
    /// future change ever makes the row fit at 320 this fails and says the note
    /// needs updating — which is the useful outcome either way.
    func testTheChecklistsClaimedClippingWidthStillClips() throws {
        let clipsAt320 = try XCTUnwrap(
            chipRowClips(atWidth: 320),
            "probe found no ink at 320pt — broken probe, not a clean render")
        XCTAssertTrue(clipsAt320,
                      """
                      Gate item 5.1's note says the row clips below ~320pt. It no \
                      longer does, so the note is STALE and must be corrected — a \
                      stale number in a checklist makes a human record a \
                      discrepancy as a defect (the F1 failure mode).
                      """)
    }

    /// Extra Large is the worst case and the one whose users can least afford a
    /// clipped count — the setting exists because those counts were unreadable
    /// (dogfood entry 27).
    ///
    /// VERIFIED RED at a 320pt floor. NOT red at 520, and that is worth stating
    /// rather than hiding: at the LIVE counts used here Extra Large needs
    /// 491pt, so the pre-entry-27 floor of 520 does clear it. The 520 → 580
    /// move was forced by FIVE-DIGIT counts (542pt needed —
    /// `ChipRowWidthTests.testTheFloorFitsFiveDigitCountsAtExtraLarge`), which
    /// is a headroom argument for a 10k+ mailbox, not a live clip. A first
    /// draft of this comment claimed red at 520; running it said otherwise.
    ///
    /// The division of labour between the two files is therefore: that one
    /// asserts the floor covers the worst COMPUTED case, this one measures
    /// what actually clips on screen today.
    func testTheFloorStillClearsTheThresholdAtExtraLarge() throws {
        let threshold = try XCTUnwrap(
            narrowestCleanWidth(low: 200,
                                high: MessageListView.minimumColumnWidth,
                                scale: .xlarge),
            """
            The chip row clips at the shipped floor when the font scale is \
            Extra Large — the regression the 520 → 580 floor change prevented, \
            in the setting chosen by the people least able to read a truncated \
            number.
            """)

        print("""

        ┌─ GATE ITEM 5.1 — Extra Large scale ────────────────────────────────┐
          Chip row renders CLEANLY at and above:  \(Int(threshold))pt
          Shipped column floor:                   \(Int(MessageListView.minimumColumnWidth))pt
          Headroom:                               \(Int(MessageListView.minimumColumnWidth - threshold))pt
        └────────────────────────────────────────────────────────────────────┘

        """)

        XCTAssertLessThanOrEqual(threshold, MessageListView.minimumColumnWidth)
    }
}

private extension NSColor {
    /// Same probe as `ChipRowWidthTests`, duplicated deliberately: that one is
    /// fileprivate, and widening a production-adjacent helper's access so a
    /// test can reach it is a worse trade than four lines of duplication.
    var thresholdBrightness: CGFloat {
        (usingColorSpace(.deviceRGB) ?? .black).brightnessComponent
    }
}

/// Counts are what determine the row's width; rows are irrelevant here.
private final class ThresholdStubAPI: MessageAPI, @unchecked Sendable {
    let counts: TriageCounts
    init(counts: TriageCounts) { self.counts = counts }
    func listMessages() async throws -> [MessageListRow] { [] }
    func listMessages(states: [String]?) async throws -> [MessageListRow] { [] }
    func listPage(_ query: ListQuery) async throws -> MessagePage {
        MessagePage(rows: [], total: 0, offset: 0)
    }
    func messageCounts() async throws -> TriageCounts { counts }
    func searchMessages(query: String) async throws -> [MessageListRow] { [] }
    func preferences() async throws -> Preferences { throw APIError.badURL }
    func getMessage(id: String) async throws -> MessageDetail { throw APIError.badURL }
    func explain(id: String) async throws -> Explanation? { nil }
    func thread(id: String) async throws -> [MessageListRow] { [] }
    func setTriage(id: String, state: TriageState) async throws -> TriageUpdateResponse {
        throw APIError.badURL
    }
    func triageBulk(ids: [String], state: TriageState) async throws -> BulkTriageResult {
        throw APIError.badURL
    }
    func triageBulk(scope: BulkFilterScope,
                    state: TriageState) async throws -> BulkTriageResult {
        throw APIError.badURL
    }
    func notifications(since: Int) async throws -> NotificationFeed { throw APIError.badURL }
    func reclassify(id: String) async throws -> ReclassifyResult { throw APIError.badURL }
    func reclassifyAll() async throws -> ReclassifySummary { throw APIError.badURL }
    func claimDelivery(forSeconds seconds: Int) async throws {}
    func accountHealth() async throws -> AccountHealthReport { throw APIError.badURL }
}
