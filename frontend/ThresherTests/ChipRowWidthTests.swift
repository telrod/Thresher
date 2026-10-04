//
//  ChipRowWidthTests.swift
//  ThresherTests
//
//  The list column must be wide enough that the D50 chip row never CLIPS.
//
//  OI18 fixed wrapping ("Open" → "Op/en"). This is the sibling failure that
//  survived it: at the old 320pt column floor the row didn't wrap, it was cut
//  off — "Open 4,738" rendered as "en 4,738" and "All 4,939" ran off the right
//  edge, at the DEFAULT window width. Reported from a real window after a
//  clean install.
//
//  Why measure instead of hardcoding a number: a fixed expectation would rot
//  the moment the font, padding, or chip vocabulary changes, and would pass
//  while the UI clipped. This computes what the row actually needs from the
//  same geometry the view uses, and asserts the shipped floor covers it.
//

import AppKit
import SwiftUI
import XCTest
@testable import Thresher

@MainActor
final class ChipRowWidthTests: XCTestCase {

    /// Mirrors `MessageListView.chipBar` geometry. Kept adjacent to the view's
    /// literals on purpose — if those change, this recomputes rather than
    /// asserting a stale constant.
    private enum ChipGeometry {
        static let interChipSpacing: CGFloat = 8    // HStack(spacing: 8)
        static let labelToCountGap: CGFloat = 4     // HStack(spacing: 4)
        static let chipHorizontalPadding: CGFloat = 10
        static let rowHorizontalPadding: CGFloat = 12
    }

    /// Width the chip row needs to render every chip on one unclipped line.
    ///
    /// Takes a `FontScale` rather than a raw point bump (dogfood entry 27): the
    /// view now derives BOTH chip fonts from the scale, so the measurement must
    /// come from the same source or it can pass while the row clips. The base
    /// sizes mirror `FontScale.chipLabel` (13) and `.chipCount` (11).
    private func requiredChipRowWidth(counts: TriageCounts,
                                      scale: FontScale = .system) -> CGFloat {
        // Read the sizes OUT OF `FontScale`, never recompute them here. A first
        // version wrote `13 + scale.pointBump` and, when the chip fonts were
        // sabotaged back to hardcoded sizes, **still passed** — it was testing
        // a model of the view rather than the view. Fourth occurrence of that
        // pattern in this project; the fix each time is to source the value
        // from the code under test.
        let labelFont = NSFont.systemFont(ofSize: scale.chipLabelPoints)
        let countFont = NSFont.monospacedDigitSystemFont(
            ofSize: scale.chipCountPoints, weight: .regular)

        var total = ChipGeometry.rowHorizontalPadding * 2
        let chips = TriageFilter.allCases
        for (i, chip) in chips.enumerated() {
            let labelWidth = (chip.label as NSString)
                .size(withAttributes: [.font: labelFont]).width
            let countWidth = ("\(chip.count(in: counts))" as NSString)
                .size(withAttributes: [.font: countFont]).width
            total += labelWidth + ChipGeometry.labelToCountGap + countWidth
                   + ChipGeometry.chipHorizontalPadding * 2
            if i < chips.count - 1 { total += ChipGeometry.interChipSpacing }
        }
        return total
    }

    /// the author's live store when the clipping was reported.
    private static let liveCounts = TriageCounts(
        new: 4519, acknowledged: 4, needsAction: 3, done: 216, unclassified: 216,
        urgentNew: 174)

    /// Five-digit counts — the headroom case. A 10k+ mailbox is not exotic and
    /// the floor should not need revisiting when the author's store grows.
    private static let fiveDigitCounts = TriageCounts(
        new: 99_999, acknowledged: 9_999, needsAction: 9_999, done: 99_999,
        unclassified: 0, urgentNew: 9_999)

    func testShippedFloorFitsTheChipRowAtLiveCounts() {
        let needed = requiredChipRowWidth(counts: Self.liveCounts)
        XCTAssertGreaterThanOrEqual(
            MessageListView.minimumColumnWidth, needed,
            """
            The list column floor (\(MessageListView.minimumColumnWidth)pt) is \
            narrower than the chip row needs (\(needed)pt) at real counts — the \
            chips will CLIP, which is what OI18's sibling defect was.
            """)
    }

    func testShippedFloorFitsFiveDigitCountsAtLargeFontScale() {
        // The worst realistic combination: a big mailbox AND D47's Large scale.
        let needed = requiredChipRowWidth(counts: Self.fiveDigitCounts, scale: .large)
        XCTAssertGreaterThanOrEqual(
            MessageListView.minimumColumnWidth, needed,
            """
            Floor \(MessageListView.minimumColumnWidth)pt < \(needed)pt needed \
            for five-digit counts at the Large font scale.
            """)
    }

    func testTheOldFloorIsProvenTooNarrow() {
        // Pins the DEFECT, not just the fix: 320 must be demonstrably
        // insufficient, so this file can never be "satisfied" by regressing the
        // constant. If this ever fails, the measurement model has drifted from
        // the view and the other assertions here are no longer trustworthy.
        let needed = requiredChipRowWidth(counts: Self.liveCounts)
        XCTAssertLessThan(320, needed,
                          "320pt was the reported clipping width; it must measure as too narrow")
    }

    /// Render proof at the shipped floor: the chip row's ink must not touch
    /// either edge of the column. Pixels, not layout math — the same reasoning
    /// as the OI18 test (SwiftUI text on macOS isn't in inspectable layers, and
    /// what a human sees is the thing under test).
    func testChipRowDoesNotTouchEitherEdgeAtTheShippedFloor() async throws {
        let width = MessageListView.minimumColumnWidth
        let defaults = UserDefaults(suiteName: "test.chipwidth.\(UUID().uuidString)")!
        let model = MessageListViewModel(api: StubAPI(counts: Self.liveCounts),
                                         defaults: defaults)
        model.filter = .open
        await model.loadInitial()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: MessageListView(model: model, selection: .constant(nil))
                .frame(width: width, height: 560))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        defer { window.close() }

        let root = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)

        // Scan the chip band (top ~40pt of the column, below any inset) and find
        // the leftmost and rightmost inked columns.
        let bandTop = 0
        let bandBottom = min(44, rep.pixelsHigh)
        var minInkX = Int.max
        var maxInkX = -1
        for y in bandTop..<bandBottom {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                // Any pixel meaningfully different from the window background.
                if c.brightnessComponentSafe > 0.30 {
                    minInkX = min(minInkX, x)
                    maxInkX = max(maxInkX, x)
                }
            }
        }

        guard maxInkX >= 0 else {
            return XCTFail("no chip-row ink found; the probe is broken, not the layout")
        }
        // Clipping shows up as ink running into the very first/last pixel column.
        XCTAssertGreaterThan(minInkX, 0,
                            "chip row ink reaches the left edge — 'Open' is being clipped")
        XCTAssertLessThan(maxInkX, rep.pixelsWide - 1,
                          "chip row ink reaches the right edge — 'All' is being clipped")
    }

    // ── Dogfood entry 27: the scale must REACH the chip row ──────────────────
    //
    // Verbatim: "Even with the large text configuration there are still many
    // things I can not read, such as the Open, Needs action, Done, and All
    // count." It was right — the row hardcoded `.caption2` for the count and
    // gave the label no font at all, so it ignored the setting entirely while
    // every other reading surface honoured it.
    //
    // The gap survived because the tests above measured a `fontBump` the VIEW
    // never applied: the helper modelled the intent, the view did not implement
    // it, and nothing compared the two. These tests close that by driving the
    // same `FontScale` the view now reads.

    func testTheFloorFitsFiveDigitCountsAtExtraLarge() {
        /// The new scale's worst case. This is the test that forced the floor
        /// from 520 to 560 — Extra Large needs 542pt at five digits, so the
        /// shipped floor would have CLIPPED, which is precisely the OI18
        /// failure, in the setting chosen by people who cannot read small text.
        let needed = requiredChipRowWidth(counts: Self.fiveDigitCounts, scale: .xlarge)
        XCTAssertGreaterThanOrEqual(
            MessageListView.minimumColumnWidth, needed, """
            Floor \(MessageListView.minimumColumnWidth)pt < \(needed)pt needed \
            for five-digit counts at Extra Large — the chip row clips.
            """)
    }

    func testTheFloorFitsLiveCountsAtEveryScale() {
        /// No scale may be exempt. Iterating `allCases` means a scale added
        /// later cannot quietly skip this check.
        for scale in FontScale.allCases {
            let needed = requiredChipRowWidth(counts: Self.liveCounts, scale: scale)
            XCTAssertGreaterThanOrEqual(
                MessageListView.minimumColumnWidth, needed,
                "chip row clips at \(scale.label) with live counts")
        }
    }

    func testEveryScaleActuallyChangesTheChipFonts() {
        /// The regression guard for the bug itself. `.caption2` was a CONSTANT,
        /// so the row rendered identically at every setting. If the chip fonts
        /// ever stop depending on the scale, this fails.
        let widths = FontScale.allCases.map {
            requiredChipRowWidth(counts: Self.liveCounts, scale: $0)
        }
        XCTAssertEqual(widths.count, Set(widths).count,
                       """
                       Two scales produce an identical chip row width, so the \
                       chip fonts are not reading the scale — this is exactly \
                       the entry-27 defect.
                       """)
    }

    func testTheScalesAreOrderedAndDistinct() {
        /// Extra Large must actually be larger than Large. A bump table is easy
        /// to typo, and a "bigger" option that is not bigger is worse than no
        /// option — the user changes the setting and nothing happens.
        XCTAssertEqual(FontScale.system.pointBump, 0)
        XCTAssertLessThan(FontScale.system.pointBump, FontScale.large.pointBump)
        XCTAssertLessThan(FontScale.large.pointBump, FontScale.xlarge.pointBump)
    }
}

private extension NSColor {
    /// `brightnessComponent` traps on colors outside a compatible space.
    var brightnessComponentSafe: CGFloat {
        (usingColorSpace(.deviceRGB) ?? .black).brightnessComponent
    }
}

/// Minimal MessageAPI: the width question depends on the COUNTS, not the rows.
private final class StubAPI: MessageAPI, @unchecked Sendable {
    let counts: TriageCounts
    init(counts: TriageCounts) { self.counts = counts }
    func listMessages() async throws -> [MessageListRow] { [] }
    func listMessages(states: [String]?) async throws -> [MessageListRow] { [] }
    func messageCounts() async throws -> TriageCounts { counts }
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
