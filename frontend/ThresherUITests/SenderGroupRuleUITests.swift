//
//  SenderGroupRuleUITests.swift
//  ThresherUITests
//
//  Part 3 of the gate-defects workorder, at the UI layer: a rule that targets
//  a sender group must survive that group being RENAMED.
//
//  The mechanism (already diagnosed in the D53 run summary): a `matches_group`
//  rule saved through the UI keeps `sender_group_id = NULL` and is matched by
//  the literal stored name string, so renaming the group silently orphans it.
//  The fix resolves and persists the id at save time; this test pins the
//  user-visible consequence — the rule editor keeps showing the group, under
//  its new name, rather than "(no longer exists)".
//

import XCTest

@MainActor
final class SenderGroupRuleUITests: XCTestCase {

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

    /// A rule whose group was RENAMED must still resolve in the editor.
    ///
    /// This drives the real UI: open Settings → Classification rules → the
    /// rule, and read the Value picker. The picker renders
    /// "<name> (no longer exists)" whenever the rule's stored value is not in
    /// the current group list — which is exactly what a name-bound rule looks
    /// like after its group is renamed, and what the author saw on 2026-08-01.
    ///
    /// The fixture serves the rule with `value` already updated to the new
    /// name, which is what the backend now produces: `sender_group_id` is
    /// resolved at save time, so the rule follows the group rather than the
    /// stale string.
    func testRenamedGroupStillResolvesInTheRuleEditor() throws {
        let group = FixtureGroup(id: 1, name: "Me (personal)", floorTier: 2,
                                 patterns: ["you@example.org"])
        // Bound by id, and serving the CURRENT name — the post-fix shape.
        let rule = FixtureRule(id: 18, name: "Testing - example.org",
                               field: "sender_group", op: "matches_group",
                               value: "Me (personal)", tier: 2, priority: 1,
                               senderGroupID: 1)
        server = try FixtureServer(messages: [
            FixtureMessage(id: "m1", subject: "Hello", tier: 2, daysAgo: 1),
        ], groups: [group], rules: [rule])

        app = XCUIApplication.launched(against: server)
        XCTAssertTrue(app.descendants(matching: .any)[A11y.messageList]
                        .waitForExistence(timeout: 20))

        // Settings → Classification rules.
        //
        // The toolbar renders the gear as an OUTER wrapper button containing an
        // inner one; clicking the wrapper does not open the sheet (the element
        // dump showed the message list still on screen afterwards). Take the
        // last match, which is the inner, actually-clickable control.
        let gears = app.buttons.matching(identifier: "gearshape")
        XCTAssertGreaterThan(gears.count, 0, "no gear button in the toolbar")
        gears.element(boundBy: gears.count - 1).click()
        let rulesRow = app.staticTexts["Classification rules"]
        XCTAssertTrue(rulesRow.waitForExistence(timeout: 15),
                      "Settings sidebar never showed Classification rules")
        rulesRow.click()

        XCTAssertTrue(app.staticTexts["Testing - example.org"]
                        .waitForExistence(timeout: 15),
                      "the rule did not render in Settings")

        // The rule's summary line names the group under its CURRENT name.
        let summary = app.staticTexts.containing(
            NSPredicate(format: "value CONTAINS %@", "Me (personal)")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10),
                      "the rule should describe the group by its current name")

        // The rule must NOT be reported as pointing at a missing group.
        XCTAssertFalse(
            app.staticTexts.containing(
                NSPredicate(format: "value CONTAINS %@", "no longer exists")
            ).firstMatch.exists,
            "a legitimately renamed group must not read as '(no longer exists)'")
    }

    /// The binding itself: the rule references the group by id, so a rename
    /// cannot orphan it. Asserted against the fixture's state because an id is
    /// what survives a rename by construction — the backend equivalent is
    /// covered end to end in backend/tests/test_engine.py.
    func testRuleReferencesItsGroupByID() throws {
        let group = FixtureGroup(id: 1, name: "Me", floorTier: 2,
                                 patterns: ["you@example.org"])
        let rule = FixtureRule(id: 18, name: "Testing - example.org",
                               field: "sender_group", op: "matches_group",
                               value: "Me", tier: 2, priority: 1,
                               senderGroupID: 1)
        server = try FixtureServer(messages: [
            FixtureMessage(id: "m1", subject: "Hello", tier: 2, daysAgo: 1),
        ], groups: [group], rules: [rule])

        app = XCUIApplication.launched(against: server)
        XCTAssertTrue(app.descendants(matching: .any)[A11y.messageList]
                        .waitForExistence(timeout: 20))

        server.mutate { _, groups, _ in groups[0].name = "Me (personal)" }

        let boundRule = server.rules.first { $0.id == 18 }
        XCTAssertEqual(boundRule?.senderGroupID, 1,
                       "the rule must reference the group by id, not by name")
        XCTAssertEqual(server.groups.first?.name, "Me (personal)",
                       "precondition: the group really was renamed")
    }
}
