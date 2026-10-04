//
//  AccountHealthTests.swift
//  ThresherTests
//
//  Session 34 — the dead-poller banner.
//
//  Grounded in a real outage: on 2026-08-13 the poller crashed on a transient
//  IMAP timeout and nothing fetched mail for 13 days, while the app looked
//  perfectly healthy. For the first 17 hours only ONE of two mailboxes was
//  dead, beside a healthy one — a state no amount of looking at the message
//  list could reveal.
//
//  These pin the derivation from the backend's report to the banner copy.
//

import XCTest
@testable import Thresher

final class AccountHealthTests: XCTestCase {

    private func entry(_ account: String, _ status: String,
                       seconds: Int? = 60, detail: String = "") -> AccountHealthEntry {
        AccountHealthEntry(account: account, status: status,
                           lastPollAt: nil, secondsSince: seconds, detail: detail)
    }

    private func report(_ entries: [AccountHealthEntry]) -> AccountHealthReport {
        AccountHealthReport(healthy: entries.allSatisfy(\.isOK),
                            accounts: entries, staleAfterSeconds: 660)
    }

    // ── Silence when there is nothing to say ────────────────────────────────

    func testHealthyAccountsProduceNoWarning() {
        let r = report([entry("a@x.com", "ok"), entry("b@x.com", "ok")])
        XCTAssertNil(AccountHealthVerdict.evaluate(r))
    }

    func testNilReportProducesNoWarning() {
        // We have not fetched health yet (or the backend is unreachable). We
        // know nothing, so we must not accuse the poller.
        XCTAssertNil(AccountHealthVerdict.evaluate(nil))
    }

    func testEmptyAccountRosterProducesNoWarning() {
        // First run / mid-onboarding: no mailbox connected yet. Warning that
        // "no mailbox is being polled" would be a false alarm on the one
        // screen where trust matters most.
        XCTAssertNil(AccountHealthVerdict.evaluate(report([])))
    }

    // ── THE CASE THAT ACTUALLY HAPPENED ────────────────────────────────────

    func testOneDeadAccountBesideAHealthyOneWarnsAndNamesIt() {
        // The 17-hour blind spot, exactly.
        let r = report([entry("you@example.org", "ok"),
                        entry("you@example.com", "stopped", seconds: 61_200,
                              detail: "TimeoutError: The read operation timed out")])
        let w = AccountHealthVerdict.evaluate(r)
        XCTAssertNotNil(w, "a dead mailbox beside a healthy one must still warn")
        XCTAssertEqual(w?.accounts, ["you@example.com"])
        XCTAssertTrue(w!.message.contains("you@example.com"),
                      "with several mailboxes the banner MUST name the broken one; got: \(w!.message)")
        XCTAssertTrue(w!.detail.contains("TimeoutError"),
                      "the tooltip should carry the backend's own cause")
    }

    func testStalePollerWarnsWithHowLongItHasBeenSilent() {
        let r = report([entry("a@x.com", "stale", seconds: 13 * 86_400)])
        let w = AccountHealthVerdict.evaluate(r)
        XCTAssertNotNil(w)
        XCTAssertTrue(w!.message.contains("13 days"),
                      "should name the silence duration; got: \(w!.message)")
    }

    func testAllAccountsDeadSaysMailIsNotArriving() {
        let r = report([entry("a@x.com", "stale", seconds: 99_999),
                        entry("b@x.com", "stopped", seconds: 99_999)])
        let w = AccountHealthVerdict.evaluate(r)
        XCTAssertNotNil(w)
        XCTAssertEqual(w?.accounts.count, 2)
        XCTAssertTrue(w!.message.lowercased().contains("not arriving"))
    }

    func testNeverPolledAccountIsReported() {
        let w = AccountHealthVerdict.evaluate(report([entry("a@x.com", "never", seconds: nil)]))
        XCTAssertNotNil(w, "a configured-but-never-polled account is not 'fine'")
    }

    func testUnknownStatusFromANewerBackendStillWarns() {
        // Forward compatibility: an unrecognized status must not read as OK.
        let w = AccountHealthVerdict.evaluate(report([entry("a@x.com", "wedged")]))
        XCTAssertNotNil(w)
        XCTAssertTrue(w!.message.contains("wedged"))
    }

    // ── Copy distinguishes the statuses ────────────────────────────────────

    func testStoppedAndStaleGetDifferentCopy() {
        // The endpoint exists to draw this distinction — "the poller told us it
        // gave up" vs "we haven't heard from it" — so the UI must not flatten
        // it back into one generic sentence.
        let stopped = AccountHealthVerdict.sentence(
            for: entry("a@x.com", "stopped"), totalAccounts: 1)
        let stale = AccountHealthVerdict.sentence(
            for: entry("a@x.com", "stale"), totalAccounts: 1)
        XCTAssertNotEqual(stopped, stale)
    }

    // ── Decoding the real payload shape ────────────────────────────────────

    func testDecodesTheBackendPayload() throws {
        // Captured verbatim from a live GET /health/accounts during the fix.
        let json = """
        {"accounts":[{"account":"you@example.org","detail":"","last_poll_at":\
        "2026-08-27T04:13:35.256237+00:00","seconds_since":69,"status":"ok"},\
        {"account":"you@example.com","detail":"no poll in 18720 min",\
        "last_poll_at":"2026-08-14T04:03:25.840765+00:00","seconds_since":1123200,\
        "status":"stale"}],"healthy":false,"stale_after_seconds":660}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(AccountHealthReport.self, from: json)
        XCTAssertFalse(r.healthy)
        XCTAssertEqual(r.accounts.count, 2)
        XCTAssertEqual(r.staleAfterSeconds, 660)
        let w = AccountHealthVerdict.evaluate(r)
        XCTAssertNotNil(w)
        XCTAssertEqual(w?.accounts, ["you@example.com"])
    }

    // ── Silence phrasing ───────────────────────────────────────────────────

    func testSilenceDescriptionScalesWithDuration() {
        XCTAssertEqual(entry("a", "stale", seconds: 300).silenceDescription, "5 min")
        XCTAssertEqual(entry("a", "stale", seconds: 3 * 3600).silenceDescription, "3 hours")
        XCTAssertEqual(entry("a", "stale", seconds: 5 * 86_400).silenceDescription, "5 days")
    }
}
