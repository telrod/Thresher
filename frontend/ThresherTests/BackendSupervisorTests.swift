//
//  BackendSupervisorTests.swift
//  ThresherTests
//
//  D67, second half — the app owns the backend's lifetime.
//
//  D66 gave the backend to launchd because a crashed poller stayed dead for 13
//  days. D67 chose app-lifetime instead: the backend runs while the app runs.
//  That trade is only honest if the app is at least as reliable a supervisor as
//  launchd was for the window it covers — which means the two failures that
//  actually happened must both stay fixed:
//
//    1. a crash must not be permanent (launchd's KeepAlive did this);
//    2. a dead poller must not be silent (D65/OI31 do this, unchanged).
//
//  So these tests are mostly about the unhappy paths. The happy path — "it
//  starts" — is the easy part and the least likely to be wrong.
//

import XCTest
@testable import Thresher

@MainActor
final class BackendSupervisorTests: XCTestCase {

    /// Records what the supervisor would launch, without spawning anything.
    private final class FakeProcessHost: BackendProcessHosting, @unchecked Sendable {
        var running: Set<String> = []
        var launchError: Error?
        var portInUse = false
        private(set) var launched: [String] = []
        private(set) var terminated: [String] = []
        private(set) var launchCount: [String: Int] = [:]

        func isRunning(_ id: String) -> Bool { running.contains(id) }
        func launch(_ id: String, python: URL, arguments: [String], workingDirectory: URL) throws {
            if let launchError { throw launchError }
            launched.append(id)
            launchCount[id, default: 0] += 1
            running.insert(id)
        }
        func terminate(_ id: String) {
            terminated.append(id)
            running.remove(id)
        }
        func isPortInUse(_ port: Int) -> Bool { portInUse }

        /// Exit status a stopped process should report. Set to
        /// `BackendSupervisor.exitNotConfigured` to simulate a backend that ran
        /// before any account was connected.
        var exitStatus: [String: Int32] = [:]
        func lastExitStatus(_ id: String) -> Int32? {
            running.contains(id) ? nil : exitStatus[id]
        }

        /// Simulate the process exiting with `status` (it stops running).
        func exits(_ id: String, status: Int32) {
            running.remove(id)
            exitStatus[id] = status
        }
    }

    private func supervisor(_ host: FakeProcessHost,
                            backend: URL? = URL(fileURLWithPath: "/tmp/backend"),
                            python: URL? = URL(fileURLWithPath: "/usr/bin/python3")
    ) -> BackendSupervisor {
        BackendSupervisor(host: host, backendDirectory: backend, python: python)
    }

    // ── First run: the poller must survive an unconfigured start ─────────────
    //
    // THE DEFECT THIS GUARDS (found 2026-09-07 by the first real cold start):
    // the app launches with an empty Keychain, the poller exits because there
    // are no accounts, and the supervisor counts that as a death. Three
    // restarts 30s apart exhaust the budget, `gaveUp` excludes the poller
    // PERMANENTLY — roughly 90 seconds before a user can finish typing an App
    // Password. Connecting a mailbox then does nothing: no ingestion, ever,
    // until the app is restarted. It fails in the direction that looks like
    // success, since the API is up and the UI renders.
    //
    // The obvious test is vacuous: launching with credentials already present
    // never exercises this path, which is why four sessions of alpha use never
    // saw it.

    func testAnUnconfiguredExitIsWaitedForRatherThanCountedAsADeath() throws {
        let host = FakeProcessHost()
        let sup = supervisor(host)
        try sup.start()

        // Far more ticks than maxRestarts, all while unconfigured — this is the
        // user still reading the onboarding screens.
        for _ in 0..<(BackendSupervisor.maxRestarts + 5) {
            host.exits(BackendSupervisor.pollerID,
                       status: BackendSupervisor.exitNotConfigured)
            sup.restartAnythingThatDied()
        }

        XCTAssertTrue(host.running.contains(BackendSupervisor.pollerID),
                      "the poller was abandoned while the user was still onboarding")

        // And it must still be alive AFTER an account appears — the case that
        // actually matters, and the one that was broken.
        host.exits(BackendSupervisor.pollerID,
                   status: BackendSupervisor.exitNotConfigured)
        sup.restartAnythingThatDied()
        XCTAssertTrue(host.running.contains(BackendSupervisor.pollerID),
                      "the poller did not come back once the account was connected")
    }

    func testAnUnconfiguredExitDoesNotSpendTheRestartBudget() throws {
        /// The budget exists to stop a genuinely broken backend spinning the
        /// CPU. An unconfigured exit is not that, so it must not consume it —
        /// otherwise a slow onboarding still exhausts the budget and the next
        /// REAL crash is abandoned immediately.
        let host = FakeProcessHost()
        let sup = supervisor(host)
        try sup.start()

        for _ in 0..<10 {
            host.exits(BackendSupervisor.pollerID,
                       status: BackendSupervisor.exitNotConfigured)
            sup.restartAnythingThatDied()
        }

        // Now a genuine crash. The full budget must still be available.
        for _ in 0..<BackendSupervisor.maxRestarts {
            host.exits(BackendSupervisor.pollerID, status: 1)
            sup.restartAnythingThatDied()
        }
        XCTAssertTrue(host.running.contains(BackendSupervisor.pollerID),
                      "a real crash was abandoned early because unconfigured "
                        + "exits had already eaten the restart budget")
    }

    func testAGenuineCrashIsStillAbandonedAfterTheBudget() throws {
        /// The over-correction guard. If unconfigured exits are waited for, a
        /// REAL failure must still stop being retried — otherwise a backend
        /// that cannot start spins forever, which is what maxRestarts exists
        /// to prevent.
        let host = FakeProcessHost()
        let sup = supervisor(host)
        try sup.start()

        for _ in 0..<(BackendSupervisor.maxRestarts + 2) {
            host.exits(BackendSupervisor.pollerID, status: 1)
            sup.restartAnythingThatDied()
        }
        XCTAssertFalse(host.running.contains(BackendSupervisor.pollerID),
                       "a permanently broken poller is being retried forever")
    }

    func testTheExitCodeContractMatchesTheBackend() {
        /// The value is a contract with backend/main.py's EXIT_NOT_CONFIGURED.
        /// A matching assertion lives in test_main_multiaccount.py; if these two
        /// drift, first-run ingestion breaks silently and neither side fails.
        XCTAssertEqual(BackendSupervisor.exitNotConfigured, 3)
    }

    // ── Starting ─────────────────────────────────────────────────────────────

    func testStartLaunchesBothProcesses() throws {
        let host = FakeProcessHost()
        try supervisor(host).start()
        XCTAssertEqual(Set(host.launched),
                       Set([BackendSupervisor.pollerID, BackendSupervisor.apiID]))
    }

    func testStartIsIdempotent() throws {
        /// Two windows, a relaunch, a retry after a transient failure — none of
        /// these should produce a second poller. Two pollers against one SQLite
        /// store is a worse failure than none, and it would look like it worked.
        let host = FakeProcessHost()
        let sup = supervisor(host)
        try sup.start()
        try sup.start()
        XCTAssertEqual(host.launchCount[BackendSupervisor.pollerID], 1)
        XCTAssertEqual(host.launchCount[BackendSupervisor.apiID], 1)
    }

    func testStartDoesNOTLaunchTheAPIWhenSomethingAlreadyHoldsThePort() throws {
        /// launchd may still own the backend (alpha), or an orphan from
        /// backend.sh may hold 8765. Launching a second API would either fail
        /// noisily or, worse, race the first for the same port. The existing one
        /// is serving the same store, so the right move is to leave it alone.
        let host = FakeProcessHost()
        host.portInUse = true
        try supervisor(host).start()
        XCTAssertFalse(host.launched.contains(BackendSupervisor.apiID),
                       "started a second API against an occupied port")
    }

    func testAnOccupiedPortDoesNotBlockThePoller() throws {
        /// The API and the poller are separate failures. An API already running
        /// says nothing about whether anything is FETCHING — which is the half
        /// that caused the 13-day outage.
        let host = FakeProcessHost()
        host.portInUse = true
        try supervisor(host).start()
        XCTAssertTrue(host.launched.contains(BackendSupervisor.pollerID))
    }

    // ── The configuration that can't ship yet ────────────────────────────────

    func testStartTHROWSWhenTheBackendCannotBeLocated() {
        /// The app bundle ships no Python and no backend/ directory (verified —
        /// Contents/Resources holds only the icon and asset catalog). Guessing a
        /// path would produce a supervisor that silently supervises nothing, so
        /// this fails loudly and names the fix.
        let host = FakeProcessHost()
        XCTAssertThrowsError(try supervisor(host, backend: nil).start()) { error in
            XCTAssertTrue("\(error)".contains("backend"), "\(error)")
        }
        XCTAssertTrue(host.launched.isEmpty)
    }

    func testStartTHROWSWhenPythonCannotBeLocated() {
        let host = FakeProcessHost()
        XCTAssertThrowsError(try supervisor(host, python: nil).start())
        XCTAssertTrue(host.launched.isEmpty)
    }

    func testAFailedLaunchDoesNotReportSuccess() {
        let host = FakeProcessHost()
        host.launchError = BackendSupervisorError.launchFailed("poller", "boom")
        XCTAssertThrowsError(try supervisor(host).start())
    }

    // ── Stopping ─────────────────────────────────────────────────────────────

    func testStopTerminatesOnlyWhatWeStarted() throws {
        /// The one thing this must never do is kill a backend it did not start —
        /// on the alpha machine that is launchd's, and killing it would make
        /// launchd restart it in a loop while the user watches mail stop and
        /// start.
        let host = FakeProcessHost()
        host.portInUse = true            // API is somebody else's
        let sup = supervisor(host)
        try sup.start()                  // starts only the poller
        sup.stop()
        XCTAssertEqual(host.terminated, [BackendSupervisor.pollerID],
                       "stopped a process this supervisor did not start")
    }

    func testStopIsIdempotent() throws {
        let host = FakeProcessHost()
        let sup = supervisor(host)
        try sup.start()
        sup.stop()
        sup.stop()
        XCTAssertEqual(host.terminated.filter { $0 == BackendSupervisor.pollerID }.count, 1)
    }

    func testStopWithoutStartDoesNothing() {
        let host = FakeProcessHost()
        supervisor(host).stop()
        XCTAssertTrue(host.terminated.isEmpty)
    }

    // ── The crash-recovery half of what launchd was doing ────────────────────

    func testADeadProcessIsRESTARTEDByTheHealthCheck() throws {
        /// This is the KeepAlive replacement, and the reason app-lifetime is an
        /// acceptable trade at all. Without it, a poller crash inside a running
        /// app is permanent for that session — the 13-day outage in miniature,
        /// just bounded by how long the app stays open.
        let host = FakeProcessHost()
        let sup = supervisor(host)
        try sup.start()

        host.running.remove(BackendSupervisor.pollerID)   // it crashed
        sup.restartAnythingThatDied()

        XCTAssertEqual(host.launchCount[BackendSupervisor.pollerID], 2,
                       "a crashed poller was not restarted")
    }

    func testAHealthyProcessIsNOTRestarted() throws {
        let host = FakeProcessHost()
        let sup = supervisor(host)
        try sup.start()
        sup.restartAnythingThatDied()
        XCTAssertEqual(host.launchCount[BackendSupervisor.pollerID], 1)
    }

    func testNothingIsRestartedAfterAnIntentionalStop() throws {
        /// Otherwise "Stop background polling" and quitting the app would both
        /// fight the supervisor, which would dutifully bring the poller back.
        let host = FakeProcessHost()
        let sup = supervisor(host)
        try sup.start()
        sup.stop()
        sup.restartAnythingThatDied()
        XCTAssertEqual(host.launchCount[BackendSupervisor.pollerID], 1,
                       "the supervisor resurrected a deliberately stopped backend")
    }

    func testARestartLoopIsBOUNDED() throws {
        /// A backend that cannot start — bad App Password, missing dependency —
        /// must not be relaunched forever. launchd used ThrottleInterval=30 for
        /// exactly this; an unbounded retry would spin the CPU and bury the real
        /// error in a thousand identical log lines.
        let host = FakeProcessHost()
        let sup = supervisor(host)
        try sup.start()

        for _ in 0..<(BackendSupervisor.maxRestarts + 5) {
            host.running.remove(BackendSupervisor.pollerID)
            sup.restartAnythingThatDied()
        }
        XCTAssertLessThanOrEqual(host.launchCount[BackendSupervisor.pollerID] ?? 0,
                                 BackendSupervisor.maxRestarts + 1)
        XCTAssertTrue(sup.hasGivenUp(on: BackendSupervisor.pollerID),
                      "a repeatedly-failing process must be reported, not retried silently")
    }

    // ── D68: the bundled backend ─────────────────────────────────────────────

    func testTheBUNDLEDBackendIsFoundInTheAppBundle() {
        /// Tests are hosted in the app, and the build phase bundles the backend,
        /// so this asserts against the REAL bundle — the thing that decides
        /// whether a beta user's app supervises anything at all.
        guard let backend = BackendSupervisor.bundledBackend() else {
            return XCTFail("no bundled backend in the built app — the "
                           + "\"Bundle backend\" build phase did not run")
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: backend.appendingPathComponent("main.py").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: backend.appendingPathComponent("_vendor/flask").path),
            "the vendored dependencies are missing — the API cannot import flask")
    }

    func testTheBundleShipsNoREALSeedAndNoTests() {
        /// seed.sql holds real contacts and is gitignored precisely so it cannot
        /// travel. Shipping it inside an app bundle would distribute an address
        /// book — a privacy failure, not a packaging one.
        guard let backend = BackendSupervisor.bundledBackend() else { return }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: backend.appendingPathComponent("db/seed.sql").path),
            "the bundle contains a real seed.sql — that is somebody's contacts")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: backend.appendingPathComponent("db/seed.example.sql").path),
            "no example seed — a fresh install cannot seed at all")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: backend.appendingPathComponent("tests").path))
    }

    func testTheSystemPythonIsUsedONLYWithABundledBackend() {
        /// `/usr/bin/python3` exists on every Mac and cannot import flask on its
        /// own. Claiming it unconditionally would resurrect the exact thrashing
        /// failure launchagent.sh documents — an interpreter that starts and
        /// immediately dies on ImportError, forever. It is correct only because
        /// the bundle ships dependencies resolved against it.
        if BackendSupervisor.bundledBackend() != nil {
            XCTAssertEqual(BackendSupervisor.locatePython(),
                           BackendSupervisor.systemPython,
                           "a bundled build should run on the system interpreter")
        }
    }

    // ── Deferring to launchd ─────────────────────────────────────────────────

    func testTheSupervisorSTANDSDOWNWhenLaunchdOwnsTheBackend() {
        /// Alpha is still supervised by launchd (D66) and must stay that way
        /// until this ships. Two supervisors racing for the same processes is
        /// the exact failure launchagent.sh's install refuses to allow, and it
        /// would be worse here because both would be restarting each other's
        /// corpses.
        XCTAssertFalse(BackendSupervisor.shouldManageBackend(launchdOwnsIt: true))
        XCTAssertTrue(BackendSupervisor.shouldManageBackend(launchdOwnsIt: false))
    }
}
