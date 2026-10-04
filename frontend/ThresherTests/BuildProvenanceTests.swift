//
//  BuildProvenanceTests.swift
//  ThresherTests
//
//  Session 36 — Part C of the gate-automation plan: gate item 3.2.
//
//  WHAT PART C EXPECTED TO FIND, AND WHAT WAS ACTUALLY THERE
//  ---------------------------------------------------------
//  The plan listed 3.2 as "cheap" — assert app stamp == /version and neither is
//  "unknown". Grepping first found only three `mismatches()` assertions, in
//  `SenderGroupPatternsTests.swift`, which reads like thin coverage in a wrong
//  home. Reading the whole file corrected that: the decode contract, ALL FOUR
//  mismatch combinations including both unknown-side cases and nil, graceful
//  degradation, AND render evidence for the footer in both states were already
//  covered by `BuildProvenanceTests` + `BuildProvenanceRenderEvidenceTests`
//  living at the bottom of that file.
//
//  So item 3.2 was already automated; what was wrong was that nobody could FIND
//  it. This file is the correct home (the tests moved here verbatim), plus the
//  two genuinely-missing assertions below.
//
//  WHAT WAS ACTUALLY MISSING
//  -------------------------
//  1. "Neither should say unknown" — the gate's own words — as a question asked
//     directly. `mismatches()` returns FALSE when either side is "unknown",
//     which is correct (missing information is not a conflict) but means an
//     entirely UNSTAMPED build is invisible to the one function anyone would
//     think to check. Worth an explicit test and an explicit comment, because
//     the natural mistake is to assume mismatches() answers 3.2 by itself.
//
//  2. The `-dirty` suffix surviving to the screen. The gate note calls it
//     "correct and expected"; it is the difference between "this is commit X"
//     and "this is commit X plus edits nobody can enumerate", which is exactly
//     what a gate run needs to know about itself. Nothing pinned it.
//
//  WHY 3.2 IS THE ITEM MOST WORTH HAVING: it catches a gate run against the
//  WRONG BINARY, the failure that silently invalidates every other item on the
//  checklist. Session 27 opened with both runtime artifacts stale and only
//  inference to detect it; the 2026-09-01 run lost two false starts to a
//  DerivedData build and recorded one Fail that was two instances racing.
//

import XCTest
@testable import Thresher

/// The `/version` decode contract plus the mismatch rule. Rendered display is
/// covered by `BuildProvenanceRenderEvidenceTests`.
final class BuildProvenanceTests: XCTestCase {

    // MARK: - Decode contract (moved verbatim from SenderGroupPatternsTests)

    func testDecodesTheVersionPayload() throws {
        let v = try JSONDecoder().decode(BackendVersion.self, from: Data("""
        {"git_sha": "abc1234", "started_at": "2026-07-26T15:00:00+00:00"}
        """.utf8))
        XCTAssertEqual(v.gitSHA, "abc1234")
        XCTAssertEqual(v.startedAt, "2026-07-26T15:00:00+00:00")
    }

    func testDecodesADirtyAndAnUnknownSHA() throws {
        for sha in ["abc1234-dirty", "unknown"] {
            let v = try JSONDecoder().decode(BackendVersion.self, from: Data("""
            {"git_sha": "\(sha)", "started_at": "2026-07-26T15:00:00+00:00"}
            """.utf8))
            XCTAssertEqual(v.gitSHA, sha)
        }
    }

    // MARK: - The mismatch rule (moved verbatim)

    func testMismatchIsOnlyClaimedWhenBOTHSHAsAreKnownAndDiffer() {
        let backend = { (sha: String) in
            BackendVersion(gitSHA: sha, startedAt: "2026-07-26T15:00:00+00:00")
        }
        let app = AppBuildStamp(sha: "aaa1111", builtAt: "2026-07-26T15:00:00Z")

        XCTAssertTrue(app.mismatches(backend("bbb2222")), "different known SHAs mismatch")
        XCTAssertFalse(app.mismatches(backend("aaa1111")), "same SHA is not a mismatch")
        // Missing information must never be reported as a mismatch — that would be a
        // false signal of exactly the kind this feature exists to prevent.
        XCTAssertFalse(app.mismatches(backend("unknown")))
        XCTAssertFalse(AppBuildStamp(sha: "unknown", builtAt: "unknown")
                        .mismatches(backend("bbb2222")))
        XCTAssertFalse(app.mismatches(nil), "not-yet-fetched is not a mismatch")
    }

    func testDisplayLineDegradesWithoutFabricating() {
        XCTAssertEqual(AppBuildStamp(sha: "unknown", builtAt: "unknown").displayLine,
                       "App unknown")
        // An unparseable stamp is shown verbatim rather than dropped.
        XCTAssertTrue(AppBuildStamp(sha: "abc1234", builtAt: "not-a-date")
                        .displayLine.contains("not-a-date"))
    }

    // MARK: - NEW (Session 36): the "neither should say unknown" half

    /// Gate 3.2 asks two questions and `mismatches()` only answers one. An
    /// unstamped build reports no mismatch against ANY backend — correct, and
    /// precisely why "is it unknown?" has to be asked separately.
    ///
    /// SCOPE, stated honestly: this drives a CONSTRUCTED stamp, not the real
    /// `.current`. Changing the `?? "unknown"` fallback in `AppBuildStamp` does
    /// NOT fail this test, and that was confirmed by trying it — the test
    /// bundle carries `ISBuildSHA`, so the fallback never executes under XCTest
    /// and no unit test in this target can reach it. What this DOES pin is the
    /// contract every caller depends on: given an unstamped stamp, the footer
    /// says so and `mismatches()` stays quiet. The fallback literal itself is
    /// covered on the backend side (`test_version_degrades_to_unknown_…`) and
    /// by gate item 3.2's own eyeball.
    func testAnUnstampedBuildIsDetectableRatherThanLookingFine() {
        let unstamped = AppBuildStamp(sha: "unknown", builtAt: "unknown")

        XCTAssertEqual(unstamped.sha, "unknown",
                       "an unstamped app must be detectable as unstamped")
        XCTAssertTrue(unstamped.displayLine.contains("unknown"),
                      """
                      The footer is the only surface for this. If an unstamped \
                      build does not SAY unknown there, gate 3.2's "neither \
                      should say unknown" cannot be answered by looking. \
                      Got: \(unstamped.displayLine)
                      """)

        // The trap, recorded deliberately: mismatches() says "no mismatch"
        // here, which is right, and is why nobody should treat it as the whole
        // of item 3.2.
        XCTAssertFalse(unstamped.mismatches(
            BackendVersion(gitSHA: "abc1234", startedAt: "2026-09-01T15:00:00+00:00")),
            "mismatches() must not invent a conflict from missing data")
    }

    /// The `-dirty` suffix must reach the screen. A modified build that looks
    /// pristine is the artifacts-mislead pattern at gate time: every recorded
    /// Pass would be against code that is not in any commit.
    ///
    /// VERIFIED RED by stripping the suffix inside `displayLine`.
    func testTheDirtySuffixIsNotSwallowedByTheFooter() {
        let dirty = AppBuildStamp(sha: "4a6180e-dirty", builtAt: "2026-08-31T23:42:00Z")
        XCTAssertTrue(dirty.displayLine.contains("-dirty"),
                      """
                      '-dirty' means uncommitted changes are in the running build \
                      — the gate note calls it correct and expected, and hiding it \
                      would make a modified build look pristine. \
                      Got: \(dirty.displayLine)
                      """)
        XCTAssertTrue(dirty.displayLine.contains("4a6180e"),
                      "the SHA itself must survive alongside the suffix")
    }

    /// Reading the real bundle must never crash or return empty. Deliberately
    /// weak on the VALUE — a test target's bundle need not carry the app's
    /// Info.plist keys, so requiring a real SHA here would fail for reasons
    /// unrelated to provenance — but it pins the degradation contract.
    func testReadingTheCurrentStampNeverCrashesOrReturnsEmpty() {
        let current = AppBuildStamp.current
        XCTAssertFalse(current.sha.isEmpty, "a missing key must read 'unknown', never empty")
        XCTAssertFalse(current.builtAt.isEmpty, "a missing key must read 'unknown', never empty")
        XCTAssertTrue(current.displayLine.hasPrefix("App "),
                      "footer shape is 'App <sha> …'; got: \(current.displayLine)")
    }
}
