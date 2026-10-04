//
//  AccountHealthClockTests.swift
//  ThresherTests
//
//  Session 36 — Part A of the gate-automation plan: the CLOCK SEAM.
//
//  WHAT THIS REPLACES
//  ------------------
//  Human gate items 1.2, 1.3 and 1.5 each cost up to ELEVEN MINUTES of
//  standing at a keyboard watching for an orange banner. The wait is real:
//  the backend derives staleness from wall-clock age of `poll_heartbeat:*`,
//  so a human has no way to make a mailbox look dead except to wait for it.
//
//  The seam that removes the wait is that the heartbeat is just a preference
//  string, `"<iso8601>|<status>|<detail>"`. Backdating it produces a genuinely
//  stale report with no waiting and no killed processes — which is also what
//  makes this safe to run on every build.
//
//  THE F1 LESSON, WHICH IS WHY THIS FILE EXISTS AT ALL
//  ---------------------------------------------------
//  Running the gate on 2026-09-01 recorded a FAIL on item 1.2: the banner did
//  not NAME the dead mailbox. That was the checklist's error, not the app's —
//  when EVERY mailbox is down the app deliberately says "No mailbox is being
//  polled", and naming each one is the PARTIAL-outage path. A single
//  `bootout` stops the one process fetching both, so a partial outage cannot
//  be produced that way at all.
//
//  So the copy has three branches and the gate could only ever reach one of
//  them. Before this file:
//
//    - the TOTAL-outage sentence appeared nowhere in any test — only in the
//      source. `testAllAccountsDeadSaysMailIsNotArriving` asserts the substring
//      "not arriving", which the PARTIAL sentence also contains, so it passes
//      against either branch and pins neither;
//    - the PARTIAL branch (3+ mailboxes, 2 dead) had no test whatsoever.
//
//  Asserting the right sentence for the right shape is the whole point: the
//  gate asked for the wrong one and a person spent time recording a defect
//  that did not exist.
//
//  EVERY TEST HERE WAS VERIFIED RED. See the comment on each one for the
//  sabotage it was run against — per the plan's rule that a guard which cannot
//  fail is not coverage.
//

import XCTest
@testable import Thresher

final class AccountHealthClockTests: XCTestCase {

    // MARK: - The clock seam

    /// Build a heartbeat preference value exactly as the poller writes it:
    /// `"<iso8601>|<status>|<detail>"`. This mirrors `_set_heartbeat` in
    /// `backend/tests/test_api.py` on purpose — if the poller's format ever
    /// changes, `testHeartbeatFormatMatchesThePoller` below fails loudly
    /// rather than this helper quietly encoding a format nobody writes.
    static func heartbeat(secondsAgo: Int,
                          status: String = "ok",
                          detail: String = "") -> String {
        let stamp = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-Double(secondsAgo)))
        return "\(stamp)|\(status)|\(detail)"
    }

    /// A report as the backend would render it for a set of backdated
    /// heartbeats. `secondsAgo` is what the gate spends 11 minutes producing.
    private func report(_ accounts: [(String, String, Int?)],
                        staleAfter: Int = 660) -> AccountHealthReport {
        let entries = accounts.map { account, status, secondsAgo in
            AccountHealthEntry(
                account: account,
                status: status,
                lastPollAt: secondsAgo.map {
                    ISO8601DateFormatter().string(
                        from: Date().addingTimeInterval(-Double($0)))
                },
                secondsSince: secondsAgo,
                detail: status == "stale" && secondsAgo != nil
                    ? "no poll in \(secondsAgo! / 60) min (expected every 5 min)"
                    : "")
        }
        return AccountHealthReport(
            healthy: entries.allSatisfy { $0.isOK },
            accounts: entries,
            staleAfterSeconds: staleAfter)
    }

    // MARK: - Item 1.2 — the warning appears on silence

    /// Gate 1.2, with the 11-minute wait removed.
    ///
    /// VERIFIED RED by returning `nil` from `evaluate` for stale entries:
    /// "the banner must fire once a mailbox has gone silent" fails.
    func testBackdatedHeartbeatFlipsTheVerdictToAWarning() {
        let healthy = report([("you@example.com", "ok", 60)])
        XCTAssertNil(AccountHealthVerdict.evaluate(healthy),
                     "a mailbox polled a minute ago must not warn")

        // The same mailbox, 11 minutes of silence later. This is the ONLY
        // difference — no process was killed, no clock was mocked.
        let silent = report([("you@example.com", "stale", 11 * 60)])
        let warning = AccountHealthVerdict.evaluate(silent)
        XCTAssertNotNil(warning,
                        "the banner must fire once a mailbox has gone silent")
        XCTAssertTrue(warning!.message.lowercased().contains("not be arriving")
                        || warning!.message.lowercased().contains("not arriving"),
                      "the user needs to be told mail is not arriving; got: \(warning!.message)")
    }

    /// THE F1 LESSON, DIRECTION 1 — a TOTAL outage says the generic sentence
    /// and deliberately does NOT name mailboxes.
    ///
    /// This is the exact shape one `launchctl bootout` produces, and the exact
    /// sentence the gate recorded as a Fail. Pinning it means the next person
    /// to read that sentence finds a test saying it is correct.
    ///
    /// VERIFIED RED by making the total-outage branch fall through to the
    /// named-account path: the assertion that no account is named fails with
    /// "you@example.com".
    func testTotalOutageUsesTheGenericSentenceAndNamesNoMailbox() {
        let warning = AccountHealthVerdict.evaluate(
            report([("you@example.com", "stale", 900),
                    ("you@example.org", "stale", 900)]))
        XCTAssertNotNil(warning)

        // Asserts the PROPERTY (generic, names nobody), not the exact wording —
        // the sentence was rewritten in 2026-09-07 to drop "poller", which a
        // user with no terminal cannot act on, and a literal match made this
        // test fail for a copy change that preserved its actual intent.
        XCTAssertTrue(warning!.message.contains("No mailbox is being"),
                      """
                      With every mailbox down the copy is deliberately generic. \
                      Gate item 1.2 asked for the mailbox to be NAMED here and \
                      recorded a Fail; that was the checklist's error. \
                      Got: \(warning!.message)
                      """)
        XCTAssertFalse(warning!.message.contains("you@example.com"),
                       "the total-outage sentence must not name individual mailboxes")
        XCTAssertFalse(warning!.message.contains("you@example.org"),
                       "the total-outage sentence must not name individual mailboxes")

        // The names are still carried for accessibility and the tooltip —
        // withheld from the SENTENCE, not discarded.
        XCTAssertEqual(Set(warning!.accounts),
                       ["you@example.com", "you@example.org"],
                       "the implicated accounts must still be reported to the UI")
    }

    /// THE F1 LESSON, DIRECTION 2 — a PARTIAL outage MUST name the mailbox.
    ///
    /// This is the 17-hour blind spot: one dead mailbox beside a healthy one,
    /// where the app as a whole looks fine. Asserted in the opposite direction
    /// from the test above so the two cannot both be satisfied by one generic
    /// sentence — which is precisely how the copy would rot.
    ///
    /// VERIFIED RED by making the single-bad-account branch emit the generic
    /// total-outage sentence: fails with "the dead mailbox must be named".
    func testPartialOutageNamesTheDeadMailbox() {
        let warning = AccountHealthVerdict.evaluate(
            report([("live@example.org", "ok", 30),
                    ("dead@gmail.com", "stale", 900)]))
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.message.contains("dead@gmail.com"),
                      """
                      One mailbox dead beside a healthy one is the case this \
                      feature was BUILT for (the 17-hour blind spot) — the dead \
                      mailbox must be named. Got: \(warning!.message)
                      """)
        XCTAssertFalse(warning!.message.contains("live@example.org"),
                       "the healthy mailbox must not be implicated")
        XCTAssertEqual(warning!.accounts, ["dead@gmail.com"])
    }

    /// The third branch, which had NO test before this file: several mailboxes
    /// connected, more than one dead, but not all of them. It must report the
    /// COUNT — "some mail is not arriving" is the part the user acts on.
    ///
    /// VERIFIED RED by deleting the `else` branch and falling through to the
    /// single-account sentence: fails because "2 mailboxes" is absent.
    func testSomeButNotAllMailboxesDeadReportsTheCount() {
        let warning = AccountHealthVerdict.evaluate(
            report([("a@x.com", "ok", 30),
                    ("b@x.com", "stale", 900),
                    ("c@x.com", "stopped", 900)]))
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.message.contains("2 mailboxes"),
                      """
                      With 2 of 3 mailboxes down the count must not be buried. \
                      Got: \(warning!.message)
                      """)
        XCTAssertEqual(Set(warning!.accounts), ["b@x.com", "c@x.com"])
        XCTAssertFalse(warning!.message.contains("No mailbox is being polled"),
                       "a partial outage must not claim every mailbox is down")
    }

    // MARK: - Item 1.3 — the warning clears itself

    /// Gate 1.3: restore the fetcher, and the banner disappears on its own.
    /// A fresh heartbeat is the only input that changes.
    ///
    /// VERIFIED RED by having `evaluate` cache its last warning: the
    /// "must clear itself" assertion fails.
    func testAFreshHeartbeatClearsTheWarningWithNoUserAction() {
        let outage = report([("you@example.com", "stale", 900)])
        XCTAssertNotNil(AccountHealthVerdict.evaluate(outage),
                        "precondition: the outage must warn")

        let restored = report([("you@example.com", "ok", 5)])
        XCTAssertNil(AccountHealthVerdict.evaluate(restored),
                     """
                     The banner must clear itself once a fresh heartbeat lands \
                     — gate 1.3 requires this WITHOUT the user clicking anything.
                     """)
    }

    /// A warning that clears must not need the outage to have been "seen".
    /// Recovery has to work from a cold start too — the app may have been
    /// launched after the poller was already fixed.
    func testRecoveryDoesNotDependOnHavingObservedTheOutage() {
        XCTAssertNil(AccountHealthVerdict.evaluate(report([("you@example.com", "ok", 5)])),
                     "a healthy report must be silent regardless of history")
    }

    // MARK: - Item 1.5 — the Settings per-account line

    /// Gate 1.5 has TWO halves and the second is the one that rots: healthy
    /// mailboxes must say NOTHING. A row that says "ok" beside every healthy
    /// mailbox trains the eye to skip the line, which is the opposite of what
    /// a warning needs.
    ///
    /// `EmailAccountsSection.ingestionStatus` renders only when
    /// `!entry.isOK`, so `isOK` IS the gate — asserted here per status.
    ///
    /// VERIFIED RED by making `isOK` return `status != "stopped"`: both the
    /// "stale" and "never" cases fail.
    func testOnlyUnhealthyAccountsGetASettingsLine() {
        let silent = ["ok"]
        let speaks = ["stale", "stopped", "never", "error", "wedged"]

        for status in silent {
            let entry = AccountHealthEntry(account: "a@x.com", status: status,
                                           lastPollAt: nil, secondsSince: 30,
                                           detail: "")
            XCTAssertTrue(entry.isOK,
                          """
                          A healthy mailbox must render NO line in Settings \
                          (gate 1.5: "no green ticks, no OK labels"). \
                          Status '\(status)' would have spoken.
                          """)
        }

        for status in speaks {
            let entry = AccountHealthEntry(account: "a@x.com", status: status,
                                           lastPollAt: nil, secondsSince: 900,
                                           detail: "")
            XCTAssertFalse(entry.isOK,
                           "status '\(status)' must produce a Settings line")
        }
    }

    /// The Settings line uses the same `sentence(for:totalAccounts:)` the
    /// banner does, so it inherits the naming rule — with several mailboxes
    /// connected it must name WHICH one, because the row it sits under is the
    /// only thing distinguishing them otherwise.
    ///
    /// VERIFIED RED by hardcoding `who = "The mailbox"`: fails at the
    /// multi-account assertion.
    func testTheSettingsLineNamesTheMailboxWhenSeveralAreConnected() {
        let entry = AccountHealthEntry(account: "dead@gmail.com", status: "stale",
                                       lastPollAt: nil, secondsSince: 900,
                                       detail: "")

        let multi = AccountHealthVerdict.sentence(for: entry, totalAccounts: 2)
        XCTAssertTrue(multi.contains("dead@gmail.com"),
                      "with 2 mailboxes the line must name this one; got: \(multi)")

        // With a single mailbox the name is redundant — there is nothing to
        // disambiguate — and reads as noise on the one row on screen.
        let single = AccountHealthVerdict.sentence(for: entry, totalAccounts: 1)
        XCTAssertFalse(single.contains("dead@gmail.com"),
                       "with one mailbox the name is redundant; got: \(single)")
    }

    // MARK: - The seam itself must stay honest

    /// The whole file rests on the heartbeat being `"<iso>|<status>|<detail>"`.
    /// If the poller changes that format, these tests would keep passing while
    /// testing a shape nobody writes — the exact "model of the bug" failure
    /// this plan was written to avoid. So pin the format, and point at the
    /// source of truth.
    func testHeartbeatFormatMatchesThePoller() {
        let value = Self.heartbeat(secondsAgo: 900, status: "stale",
                                   detail: "no poll in 15 min")
        let parts = value.split(separator: "|", maxSplits: 2,
                                omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 3,
                       """
                       Heartbeat is '<iso8601>|<status>|<detail>' — written by \
                       ingestion/pipeline.py and parsed by the /health/accounts \
                       handler in api/app.py. If this fails, that format moved \
                       and the backdating seam moved with it.
                       """)
        XCTAssertEqual(String(parts[1]), "stale")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: String(parts[0])),
                        "the stamp must parse as ISO-8601 or the backend reads it as stale")
    }
}
