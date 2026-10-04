//
//  SettingsAreaTests.swift
//  ThresherTests
//
//  Mechanical guard for D43's Settings sidebar contract (OI14).
//
//  OI14: `7a415fb` (Settings IA restructure) was reviewed and approved as
//  behavior-neutral re-housing, and the Session 18 gate reported it had shipped
//  three sidebar rows with Email accounts missing. Verify-by-running in Session 19
//  showed the committed source already had all four rows in D43 order — the report
//  didn't match the source. This test makes the row set + order self-checking at
//  build/test time so a future re-housing commit can't silently drift from D43
//  (Email accounts / Classification rules / Sender groups / Notifications) and
//  rely on human screenshot review to catch it — which is exactly how OI14 slipped.
//

import XCTest
@testable import Thresher

final class SettingsAreaTests: XCTestCase {

    /// D43 as amended by D47: the Settings sidebar is a FIVE-row list in this
    /// exact order (Appearance appended, Session 25 dogfood polish Part D).
    /// The sidebar renders `SettingsArea.allCases`, so `allCases` order IS row
    /// order. This expectation was updated DELIBERATELY: the test was run red
    /// against the old four-row order first (the guard caught the D47 drift as
    /// designed), then amended to the approved five-row contract.
    func testSidebarMatchesD43Order() {
        XCTAssertEqual(
            SettingsArea.allCases.map(\.title),
            ["Email accounts", "Classification rules", "Sender groups",
             "Notifications", "Appearance"],
            "Settings sidebar drifted from the D43+D47 five-row order. See OI14 — "
                + "a wrong row set/order shipped once already and was caught only by screenshot."
        )
    }
}
/// E22 — the field/operator pairing contract the editor's picker enforces
/// (same production path: the picker renders RuleOperator.valid(for:)).
final class RuleOperatorPairingTests: XCTestCase {

    func testSenderGroupLocksToMatchesGroup() {
        XCTAssertEqual(RuleOperator.valid(for: .senderGroup), [.matchesGroup],
                       "sender_group with any other operator silently never matches (E22).")
    }

    func testOtherFieldsExcludeMatchesGroup() {
        for field in RuleField.selectable where field != .senderGroup {
            let valid = RuleOperator.valid(for: field)
            XCTAssertFalse(valid.contains(.matchesGroup),
                           "\(field) must not offer matches_group (E22).")
            XCTAssertFalse(valid.isEmpty)
            XCTAssertFalse(valid.contains(.unknown))
        }
    }
}
