//
//  MessageListUITests.swift
//  ThresherUITests
//
//  Parts 1 and 2 of the gate-defects workorder, at the layer the human gate
//  actually failed on: a real window, driven end to end.
//
//  All of these run against a seeded FixtureServer (see UITestSupport), never
//  the live store — Part 1.4's explicit requirement, and the only way an
//  ordering assertion can mean anything across days.
//

import XCTest

@MainActor
final class MessageListUITests: XCTestCase {

    private var server: FixtureServer!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        server?.stop()
        server = nil
        app = nil
    }

    // ── Part 0: the target itself works ─────────────────────────────────────

    /// Smoke test for the whole apparatus: the app launches, talks to the
    /// fixture, and renders seeded rows. If this fails, nothing below is
    /// meaningful.
    func testAppLaunchesAgainstFixtureAndRendersSeededRows() throws {
        server = try FixtureServer(messages: [
            FixtureMessage(id: "a", subject: "Alpha message", tier: 2, daysAgo: 1),
            FixtureMessage(id: "b", subject: "Beta message", tier: 4, daysAgo: 2),
        ])
        app = XCUIApplication.launched(against: server)

        let list = app.descendants(matching: .any)[A11y.messageList]
        XCTAssertTrue(list.waitForExistence(timeout: 20),
                      "the message list never appeared")
        XCTAssertTrue(app.staticTexts["Alpha message"].waitForExistence(timeout: 10),
                      "seeded row did not render — the app may not be using the fixture")
    }

    // ── Part 1: today's mail is reachable on page one ───────────────────────

    /// The D57 payoff, pinned. With a realistic mix — a big pile of old
    /// higher-tier mail plus a little fresh lower-tier mail — the fresh mail
    /// must be on the first page.
    ///
    /// This is the assertion that would have caught the gate complaint had the
    /// store been fresh, and it is deliberately about REACHABILITY rather than
    /// exact row order: the product question is "can I see today's mail without
    /// paginating", not "is it row 1".
    func testTodaysMailAppearsOnPageOneOfOpen() throws {
        // 150 old Tier-2s: enough to fill the 100-row page on their own if
        // tier-first ordering ignored age (the pre-D57 behaviour).
        var seed = (0..<150).map {
            FixtureMessage(id: "old\($0)", subject: "Old tier2 \($0)",
                           tier: 2, daysAgo: 200 + Double($0))
        }
        seed.append(FixtureMessage(id: "today", subject: "Arrived today",
                                   tier: 4, daysAgo: 0.1))
        server = try FixtureServer(messages: seed)
        app = XCUIApplication.launched(against: server)

        XCTAssertTrue(app.descendants(matching: .any)[A11y.messageList]
                        .waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Arrived today"].waitForExistence(timeout: 10),
                      "a message from today must be on page one of Open, "
                      + "not buried behind 150 older higher-tier messages")
    }

    /// The Tier 1 invariant, at the UI layer: an old Tier 1 still outranks
    /// fresh mail. Band 0 exists precisely so the decay rule cannot silently
    /// demote a Tier 1, and there are no open Tier 1s in the live store today
    /// — that's luck, not design, so it gets its own test.
    func testOldTierOneStillOutranksFreshMail() throws {
        server = try FixtureServer(messages: [
            FixtureMessage(id: "fresh", subject: "Fresh tier four", tier: 4, daysAgo: 0.1),
            FixtureMessage(id: "ancient", subject: "Ancient tier one", tier: 1, daysAgo: 400),
        ])
        app = XCUIApplication.launched(against: server)

        XCTAssertTrue(app.staticTexts["Ancient tier one"].waitForExistence(timeout: 20),
                      "a Tier 1 must surface at any age")
    }

    /// Part 1's actual fix: a stale store must be distinguishable from a quiet
    /// one. With the newest message days old, the list says so.
    ///
    /// This is the defect the gate really hit — the backend had been stopped
    /// for five days and the UI rendered that identically to "no new mail".
    func testStaleStoreShowsAStalenessBanner() throws {
        server = try FixtureServer(messages: [
            FixtureMessage(id: "old1", subject: "Five days old", tier: 2, daysAgo: 5),
            FixtureMessage(id: "old2", subject: "Six days old", tier: 4, daysAgo: 6),
        ])
        app = XCUIApplication.launched(against: server)

        let banner = app.descendants(matching: .any)[A11y.stalenessBanner]
        XCTAssertTrue(banner.waitForExistence(timeout: 20),
                      "a store whose newest message is 5 days old must say so — "
                      + "otherwise a stopped backend looks exactly like a quiet inbox")
    }

    /// The other side of the same coin: a genuinely fresh store must NOT nag.
    /// A banner that is always on is a banner nobody reads.
    func testFreshStoreShowsNoStalenessBanner() throws {
        server = try FixtureServer(messages: [
            FixtureMessage(id: "new1", subject: "Just arrived", tier: 2, daysAgo: 0.05),
        ])
        app = XCUIApplication.launched(against: server)

        XCTAssertTrue(app.staticTexts["Just arrived"].waitForExistence(timeout: 20))
        let banner = app.descendants(matching: .any)[A11y.stalenessBanner]
        XCTAssertFalse(banner.exists,
                       "a fresh store must not show a staleness warning")
    }

    // ── Part 2: clearing filters restores the view ──────────────────────────

    /// The gate sequence end to end: filter to a narrow slice, bulk-Done it,
    /// then reset both menus and confirm the full list returns.
    ///
    /// **What this test does NOT do: fail on the reload race.** That was
    /// measured, not assumed. With the `reloadGeneration` guards disabled this
    /// test still passes, because XCUITest cannot produce overlapping reloads:
    /// each synchronous `click()` waits for the app to go idle, and SwiftUI's
    /// idle check includes in-flight URLSession work. The fixture's request log
    /// shows six list fetches, strictly sequential, the last one fully cleared:
    ///
    ///   states=… → +tier=4 → +until=… → +until=… → until=… → (cleared)
    ///
    /// Raising the fixture's `slowDelay` to 8s did not change that — the
    /// harness serializes regardless of server latency.
    ///
    /// So the REAL guard for the race is
    /// `FilterResetRaceTests.testResettingTheTwoMenusSeparatelyRestoresTheFullView`
    /// in the unit target, which drives the model directly and does fail
    /// without the fix ("6" is not equal to "15"). This test earns its place by
    /// covering the whole user-visible sequence — menus, bulk action,
    /// confirmation dialog, restored list — which the unit test cannot reach.
    func testResettingBothMenusAfterBulkActionRestoresTheFullList() throws {
        var seed = (0..<8).map {
            FixtureMessage(id: "old\($0)", subject: "Backlog item \($0)",
                           tier: 4, daysAgo: 200)
        }
        seed += (0..<5).map {
            FixtureMessage(id: "fresh\($0)", subject: "Recent item \($0)",
                           tier: 2, daysAgo: 1)
        }
        server = try FixtureServer(messages: seed)
        // Narrowed queries answer last — the out-of-order completion that
        // exposes the race.
        server.slowPathPredicate = { target in
            target.contains("tier=") || target.contains("until=") || target.contains("since=")
        }
        // Must EXCEED the wall-clock gap between two menu picks, or the first
        // reload finishes before the second starts and the requests never
        // overlap — which is a test that passes for the wrong reason. Measured:
        // a menu open + item click costs ~2-3s of XCUITest pacing, so 8s makes
        // the overlap certain. Verified by disabling the reloadGeneration
        // guards: at 0.6s this test still passed, at 8s it fails.
        server.slowDelay = 8
        app = XCUIApplication.launched(against: server)

        XCTAssertTrue(app.descendants(matching: .any)[A11y.messageList]
                        .waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Recent item 0"].waitForExistence(timeout: 10),
                      "precondition: the unfiltered view shows recent mail")

        // Filter: Tier 4 + older than 90 days.
        selectTier("4 · Whenever")
        selectDate("Older than 90 days")

        let recentGone = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: app.staticTexts["Recent item 0"])
        wait(for: [recentGone], timeout: 20)

        // Bulk-Done the backlog, as in the gate sequence.
        app.descendants(matching: .any)[A11y.selectToggle].click()
        app.buttons["Select all 8 loaded"].firstMatch.click()
        app.buttons["Mark Done"].firstMatch.click()
        // Scope to the sheet: `app.buttons[...].firstMatch` can resolve to the
        // Touch Bar's mirror of the same button, which XCUITest refuses to
        // click ("cannot be called with Touch Bar elements"). The dialog's own
        // descendants are unambiguous.
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "confirmation dialog never appeared")
        sheet.buttons["Mark as Done"].click()
        let ok = app.sheets.firstMatch.buttons["OK"]
        if ok.waitForExistence(timeout: 15) { ok.click() }

        // Now reset the two menus SEPARATELY — the racing path.
        selectTier("All tiers")
        selectDate("Any time")

        XCTAssertTrue(app.staticTexts["Recent item 0"].waitForExistence(timeout: 25),
                      "after resetting both menus the full list must return; a "
                      + "stale response from the half-cleared filter set must not win")
    }

    // ── D59: select-all-matching, AT THE WINDOW ─────────────────────────────

    /// **The gate found this dead and 126 unit tests did not.**
    ///
    /// The unit tests drive the view MODEL (`model.captureFilterScope()`) and
    /// never render the view, so they proved the state machine correct while
    /// saying nothing about whether a click reaches it. That is the E16/OI14
    /// pattern this project has already been bitten by once: the Settings
    /// sidebar row existed in the model, passed a model-order test, and was
    /// invisible at render time.
    ///
    /// Needs MORE than one page of matches, or `canSelectAllMatching` is false
    /// and the button under test never renders at all.
    func testSelectAllMatchingArmsTheScopeWhenClicked() throws {
        let seed = (0..<150).map {
            FixtureMessage(id: "bl\($0)", subject: "Backlog item \($0)",
                           tier: 4, daysAgo: 200)
        }
        server = try FixtureServer(messages: seed)
        app = XCUIApplication.launched(against: server)

        XCTAssertTrue(app.descendants(matching: .any)[A11y.messageList]
                        .waitForExistence(timeout: 20))

        app.descendants(matching: .any)[A11y.selectToggle].click()

        // Precondition: BOTH affordances are offered and distinguishable.
        let loaded = app.buttons["Select all 100 loaded"].firstMatch
        let matching = app.buttons["Select all 150 matching"].firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 10),
                      "the loaded-only affordance must still be offered")
        XCTAssertTrue(matching.waitForExistence(timeout: 10),
                      "select-all-matching must render when more than one page matches")

        matching.click()

        // THE ASSERTION: the click must change the armed state. "All 150
        // matching" is the bulk bar's armed readout; if the click is ignored
        // the bar still says "0 selected" and Mark Done stays disabled.
        XCTAssertTrue(app.staticTexts["All 150 matching"].waitForExistence(timeout: 10),
                      "clicking select-all-matching did not arm the scope — the "
                      + "bulk bar never showed the armed readout")
        XCTAssertTrue(app.buttons["Mark Done"].firstMatch.isEnabled,
                      "Mark Done must be enabled once a scope is armed")
    }

    /// The gate's ACTUAL finding, at the layer that failed.
    ///
    /// The first version of this feature armed correctly and passed 126 unit
    /// tests, but every checkbox stayed empty — so the only confirmation the
    /// click had worked was a small label at the far end of the bar, and a real
    /// user at a real window read it as "nothing happened". State-level tests
    /// cannot see that; this one can.
    func testArmingTheScopeTicksTheVisibleCheckboxes() throws {
        let seed = (0..<150).map {
            FixtureMessage(id: "bl\($0)", subject: "Backlog item \($0)",
                           tier: 4, daysAgo: 200)
        }
        server = try FixtureServer(messages: seed)
        app = XCUIApplication.launched(against: server)

        XCTAssertTrue(app.descendants(matching: .any)[A11y.messageList]
                        .waitForExistence(timeout: 20))
        app.descendants(matching: .any)[A11y.selectToggle].click()

        // Before: no row is ticked. Queried by accessibility identifier — an
        // SF Symbol's own name is not queryable, which is why the checkbox
        // carries an identifier that flips with its state.
        let ticked = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "row.checkbox.ticked"))
        XCTAssertEqual(ticked.count, 0, "nothing armed ⇒ no ticks")

        app.buttons["Select all 150 matching"].firstMatch.click()

        // After: the rendered rows are visibly part of the action.
        XCTAssertTrue(app.descendants(matching: .any)["bulk.armedScope"]
                        .waitForExistence(timeout: 10),
                      "the armed badge must be on screen")
        XCTAssertGreaterThan(ticked.count, 0,
                             "an armed filter scope must TICK the visible rows — "
                             + "an empty checkbox column is the screen "
                             + "contradicting the action the user just took")
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    private func selectTier(_ title: String) {
        let menu = app.descendants(matching: .any)[A11y.tierFilterMenu]
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "tier menu missing")
        menu.click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "menu item \(title) missing")
        item.click()
    }

    private func selectDate(_ title: String) {
        let menu = app.descendants(matching: .any)[A11y.dateFilterMenu]
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "date menu missing")
        menu.click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "menu item \(title) missing")
        item.click()
    }
}
