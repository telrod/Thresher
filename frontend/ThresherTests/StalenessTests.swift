//
//  StalenessTests.swift
//  ThresherTests
//
//  Part 1 of the gate-defects workorder.
//
//  The gate complaint was "today's mail isn't on page one of Open". Querying
//  the live store settled it: the backend had been stopped for five days, so
//  the newest message in the store was 4.94 days old. D57's ordering was
//  correct the whole time — there was simply no fresh mail to order. A live
//  poll ingested 48 messages and all 8 of that day's landed on page one.
//
//  So the defect is not the sort. It is that a STALE store and a QUIET one
//  render identically: the list shows old mail either way and says nothing.
//  These tests pin the derivation behind the indicator that fixes that.
//
//  Deliberately a pure function of (newest message date, now): no clock
//  injection games in the view, and the boundary cases are testable without a
//  running backend.
//

import XCTest
@testable import Thresher

final class StalenessTests: XCTestCase {

    private func stamp(daysAgo: Double) -> String {
        ISO8601DateFormatter.listBound.string(
            from: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    // ── The threshold ───────────────────────────────────────────────────────

    func testFreshStoreIsNotStale() {
        XCTAssertNil(ListStaleness.evaluate(newestReceivedAt: stamp(daysAgo: 0.1)),
                     "mail from an hour ago is not a staleness signal")
    }

    func testStoreJustUnderThresholdIsNotStale() {
        let justUnder = ListStaleness.thresholdDays - 0.1
        XCTAssertNil(ListStaleness.evaluate(newestReceivedAt: stamp(daysAgo: justUnder)))
    }

    func testStoreOverThresholdIsStale() {
        let over = ListStaleness.thresholdDays + 0.5
        let result = ListStaleness.evaluate(newestReceivedAt: stamp(daysAgo: over))
        XCTAssertNotNil(result, "a store past the threshold must report staleness")
    }

    /// The real case: five days, which is exactly what the gate hit.
    func testFiveDayGapReportsFiveDays() {
        let result = ListStaleness.evaluate(newestReceivedAt: stamp(daysAgo: 5))
        XCTAssertEqual(result?.days, 5)
        XCTAssertTrue(result!.message.contains("5 days"),
                      "the copy must name the actual gap, got: \(result!.message)")
    }

    // ── Honest about what it does and doesn't know ──────────────────────────

    /// An EMPTY store is not a stale store. A first run with no mail yet would
    /// otherwise be accused of a backend outage on its very first launch.
    func testEmptyStoreIsNotReportedAsStale() {
        XCTAssertNil(ListStaleness.evaluate(newestReceivedAt: nil),
                     "no messages at all is not evidence of staleness")
    }

    /// An unparseable timestamp must not silently read as "infinitely old" and
    /// pin a permanent banner to the window.
    func testUnparseableTimestampIsNotReportedAsStale() {
        XCTAssertNil(ListStaleness.evaluate(newestReceivedAt: "not-a-date"))
    }

    /// A clock skew that puts the newest message in the future must not produce
    /// a negative-day banner.
    func testFutureTimestampIsNotStale() {
        XCTAssertNil(ListStaleness.evaluate(newestReceivedAt: stamp(daysAgo: -2)))
    }

    // ── Wording ─────────────────────────────────────────────────────────────

    /// The banner has to point at the cause. "No new mail in 5 days" invites
    /// the wrong conclusion (a quiet inbox); the copy must raise the backend.
    func testMessageNamesTheLikelyCause() {
        let result = ListStaleness.evaluate(newestReceivedAt: stamp(daysAgo: 9))
        XCTAssertNotNil(result)
        let text = result!.message.lowercased()
        XCTAssertTrue(text.contains("backend") || text.contains("poll"),
                      "the copy must point at the poller, got: \(result!.message)")
    }

    func testSingularDayIsNotPluralised() {
        // Only reachable if the threshold is ever lowered to < 1 day, but the
        // formatting should not be able to emit "1 days".
        let result = ListStaleness.describe(days: 1)
        XCTAssertTrue(result.contains("1 day"))
        XCTAssertFalse(result.contains("1 days"))
    }
}