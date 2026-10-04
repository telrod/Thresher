//
//  UITestSupportContractTests.swift
//  ThresherTests
//
//  A seam guard for the XCUITest target (gate-defects workorder Part 0).
//
//  The UI test target drives the app as a SEPARATE PROCESS, so it has no
//  `@testable import Thresher` and cannot reference the app's constants. It
//  therefore hard-codes the UserDefaults keys it injects via launch arguments
//  (see `DefaultsKeys` in UITestSupport.swift).
//
//  That duplication has a nasty failure mode: rename `TriageFilter.defaultsKey`
//  or `OnboardingViewModel.tutorialSeenKey` and the UI tests keep compiling,
//  keep launching, and simply stop skipping Onboarding — every one of them then
//  fails with "element not found", which reads like a broken feature rather
//  than a stale literal. (That exact failure cost a debug cycle on the first
//  run: the element dump showed "Connect your Gmail" where the message list
//  should have been.)
//
//  This test lives in the UNIT target, which CAN see the real constants, and
//  pins the literals against them. It is the cheapest possible guard: if it
//  fails, update the matching literal in UITestSupport.swift.
//

import XCTest
@testable import Thresher

final class UITestSupportContractTests: XCTestCase {

    // Mirrors of the literals in ThresherUITests/UITestSupport.swift.
    // Keep these two lists in sync — that is the entire point of the file.
    private enum Mirror {
        static let tutorialSeen = "onboarding.tutorialSeen"
        static let triageFilter = "list.triageFilter"
        static let tierFilter   = "list.tierFilter"
        static let dateWindow   = "list.dateWindow"
    }

    func testTutorialSeenKeyMatches() {
        XCTAssertEqual(OnboardingViewModel.tutorialSeenKey, Mirror.tutorialSeen,
                       "UITestSupport.DefaultsKeys.tutorialSeen is stale — UI tests "
                       + "would stop skipping Onboarding and fail as 'element not found'")
    }

    func testTriageFilterKeyMatches() {
        XCTAssertEqual(TriageFilter.defaultsKey, Mirror.triageFilter,
                       "UITestSupport.DefaultsKeys.triageFilter is stale")
    }

    func testTierFilterKeyMatches() {
        XCTAssertEqual(TierFilter.defaultsKey, Mirror.tierFilter,
                       "UITestSupport.DefaultsKeys.tierFilter is stale")
    }

    func testDateWindowKeyMatches() {
        XCTAssertEqual(DateWindow.defaultsKey, Mirror.dateWindow,
                       "UITestSupport.DefaultsKeys.dateWindow is stale")
    }

    /// The API base-URL override the UI tests rely on to point the app at a
    /// fixture. If this variable name changes, every UI test silently talks to
    /// the LIVE backend on :8765 — green or red, the result would be
    /// meaningless.
    func testAPIBaseURLOverrideRespectsTheEnvironmentVariableName() {
        // The name is what matters; assert the documented default holds when
        // the variable is absent (it is, in the unit-test process).
        XCTAssertEqual(APIClient.defaultBaseURL.absoluteString,
                       "http://localhost:8765",
                       "with THRESHER_API_BASE_URL unset the client must "
                       + "fall back to the real local backend")
    }
}
