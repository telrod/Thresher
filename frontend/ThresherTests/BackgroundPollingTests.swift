//
//  BackgroundPollingTests.swift
//  ThresherTests
//
//  D67 (OI33) — the backend's process model, decided.
//
//  Alpha inherited "two always-on launchd agents" from D66, which was an OUTAGE
//  FIX, never a product decision. the author's call for beta is the app-lifetime model:
//  the backend runs while the app runs. Quitting stops it; the Trash removes it.
//
//  What these pin is mostly the SAFE DIRECTION of each edge case, because every
//  one of them can fail two ways and only one way is recoverable:
//
//    - never leave agents running that the user asked to remove (the wart);
//    - never claim "stopped" when we could not verify it;
//    - never let an uninstall failure look like success.
//

import XCTest
@testable import Thresher

@MainActor
final class BackgroundPollingTests: XCTestCase {

    /// Records the launchctl-style operations a controller would perform,
    /// so the decision logic is testable without touching real launchd.
    private final class FakeAgentHost: AgentHosting, @unchecked Sendable {
        var loadedLabels: Set<String>
        var failOn: String?
        private(set) var booted: [String] = []
        private(set) var removed: [String] = []

        init(loaded: Set<String> = []) { self.loadedLabels = loaded }

        func isLoaded(_ label: String) -> Bool { loadedLabels.contains(label) }

        func bootout(_ label: String) throws {
            if failOn == label { throw BackgroundPollingError.couldNotStop(label) }
            booted.append(label)
            loadedLabels.remove(label)
        }

        func removePlist(_ label: String) throws {
            if failOn == "plist:\(label)" {
                throw BackgroundPollingError.couldNotStop(label)
            }
            removed.append(label)
        }
    }

    // ── Detecting the inherited always-on install ────────────────────────────

    func testSupervisionIsDetectedWhenBothAgentsAreLoaded() {
        let host = FakeAgentHost(loaded: Set(BackgroundPolling.allLabels))
        XCTAssertTrue(BackgroundPolling(host: host).isSupervised)
    }

    func testSupervisionIsDetectedWhenEVENONEAgentIsLoaded() {
        /// A half-installed state still polls the mailbox, so it still needs the
        /// off switch. Requiring both would hide exactly the broken install a
        /// user is most likely to want removed.
        let host = FakeAgentHost(loaded: [BackgroundPolling.pipelineLabel])
        XCTAssertTrue(BackgroundPolling(host: host).isSupervised)
    }

    func testNoAgentsMeansNotSupervised() {
        XCTAssertFalse(BackgroundPolling(host: FakeAgentHost()).isSupervised)
    }

    // ── Turning it off ───────────────────────────────────────────────────────

    func testDisablingRemovesBOTHAgents() throws {
        let host = FakeAgentHost(loaded: Set(BackgroundPolling.allLabels))
        try BackgroundPolling(host: host).disable()

        XCTAssertEqual(Set(host.booted), Set(BackgroundPolling.allLabels))
        XCTAssertEqual(Set(host.removed), Set(BackgroundPolling.allLabels),
                       "the plists must go too — otherwise they reload at next login")
    }

    func testDisablingUNLOADS_AND_REMOVES_notJustUnloads() throws {
        /// Unloading without deleting the plist means the agents come back at
        /// the next login. The user asked for it to stop, and it would restart
        /// behind their back — the worst version of this bug, because it looks
        /// like it worked.
        let host = FakeAgentHost(loaded: Set(BackgroundPolling.allLabels))
        try BackgroundPolling(host: host).disable()
        XCTAssertFalse(host.removed.isEmpty)
        XCTAssertEqual(Set(host.removed), Set(host.booted))
    }

    func testDisablingIsIdempotent() throws {
        /// Nothing loaded is the desired end state, so asking again must succeed
        /// rather than error. A user who clicks twice has not made a mistake.
        let host = FakeAgentHost()
        XCTAssertNoThrow(try BackgroundPolling(host: host).disable())
    }

    func testDisablingSTILLREMOVESTHEPLISTWhenNothingIsLoaded() throws {
        /// The dangerous in-between: plists on disk but not currently loaded.
        /// They would load at next login, so "not running" is not "removed".
        let host = FakeAgentHost()
        try BackgroundPolling(host: host).disable()
        XCTAssertEqual(Set(host.removed), Set(BackgroundPolling.allLabels))
    }

    // ── Failure must not read as success ─────────────────────────────────────

    func testAFailedStopTHROWSRatherThanReportingSuccess() {
        /// "Background polling stopped" when it is still polling is the single
        /// most harmful thing this control could say — the user walks away
        /// believing their mailbox is no longer being touched.
        let host = FakeAgentHost(loaded: Set(BackgroundPolling.allLabels))
        host.failOn = BackgroundPolling.pipelineLabel
        XCTAssertThrowsError(try BackgroundPolling(host: host).disable())
    }

    func testAFailedPlistRemovalAlsoTHROWS() {
        /// Same reasoning one layer down: unloaded but still on disk means it
        /// returns at login, so reporting success would be a lie with a delay.
        let host = FakeAgentHost(loaded: Set(BackgroundPolling.allLabels))
        host.failOn = "plist:\(BackgroundPolling.apiLabel)"
        XCTAssertThrowsError(try BackgroundPolling(host: host).disable())
    }

    func testTheOTHERAgentIsStillStoppedWhenONEFails() {
        /// Partial progress beats none: if the pipeline cannot be stopped, the
        /// API should not be left running as well. Stopping the mailbox poller
        /// is the part that matters, so the attempt continues and the error is
        /// reported afterwards.
        let host = FakeAgentHost(loaded: Set(BackgroundPolling.allLabels))
        host.failOn = BackgroundPolling.apiLabel
        _ = try? BackgroundPolling(host: host).disable()
        XCTAssertTrue(host.booted.contains(BackgroundPolling.pipelineLabel),
                      "one agent failing must not abandon the other")
    }

    // ── The labels themselves ────────────────────────────────────────────────

    func testTheLabelsMatchTheScript() {
        /// These strings are the contract with scripts/launchagent.sh. A typo
        /// means the app cheerfully reports "not supervised" while two agents
        /// poll the mailbox — failing toward silence, which is the direction
        /// this whole area of the code exists to avoid.
        XCTAssertEqual(BackgroundPolling.pipelineLabel, "com.tomelrod.thresher.pipeline")
        XCTAssertEqual(BackgroundPolling.apiLabel, "com.tomelrod.thresher.api")
        XCTAssertEqual(BackgroundPolling.allLabels.count, 2)
    }
}
