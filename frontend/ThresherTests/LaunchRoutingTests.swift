//
//  LaunchRoutingTests.swift
//  ThresherTests
//
//  Cold start (Defect B, 2026-10-10). The app's first requests reached the
//  backend ~490ms before it was listening: the account check was refused and
//  read as "no accounts", so an existing user was routed into onboarding, and
//  the Ask step's one-shot load failed into "Try again".
//
//  The fake backend refuses every call — health probes included — until it has
//  seen `refuseFirst` of them, which is what a backend still starting looks like
//  from the app.
//
//  WHAT THESE CANNOT PROVE: that RootView renders the route, or the real
//  supervisor's timing. Phase 3 checks both on the machine.
//

import XCTest
@testable import Thresher

private final class ColdStartBackend: SettingsAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var refuseFirst: Int
    private(set) var apiCallsRefused = 0
    let accounts: [String]
    var accountsFailure: Error?

    init(refuseFirst: Int, accounts: [String]) {
        self.refuseFirst = refuseFirst
        self.accounts = accounts
    }

    /// The backend finishes starting: everything from now on is answered.
    func comeUp() { lock.withLock { refuseFirst = 0 } }

    /// `GET /health`, as the readiness gate sees it.
    func probe() -> Bool {
        lock.withLock {
            calls += 1
            return calls > refuseFirst
        }
    }

    private func admit() throws {
        let refused: Bool = lock.withLock {
            calls += 1
            if calls <= refuseFirst { apiCallsRefused += 1; return true }
            return false
        }
        if refused { throw APIError.transport(URLError(.cannotConnectToHost)) }
    }

    func listAccounts() async throws -> [String] {
        try admit()
        if let accountsFailure { throw accountsFailure }
        return accounts
    }

    func getRules(includeDisabled: Bool) async throws -> RulesResponse {
        try admit()
        return RulesResponse(rules: [], senderGroups: [
            SenderGroup(id: 1, groupName: "leadership", patterns: [], urgencyFloor: 1),
            SenderGroup(id: 2, groupName: "family", patterns: [], urgencyFloor: 1),
        ])
    }

    func saveOnboardingPeople(leadership: [String], family: [String]) async throws
        -> OnboardingPeopleResponse { throw APIError.badURL }
    func createRule(_ body: RuleWrite) async throws -> Rule { throw APIError.badURL }
    func updateRule(id: Int, patch: RuleWrite) async throws -> Rule { throw APIError.badURL }
    func deleteRule(id: Int) async throws {}
    func reorderRules(orderedIds: [Int]) async throws -> [Rule] { [] }
    func reclassifyAllMessages() async throws -> ReclassifySummary { throw APIError.badURL }
    func backendVersion() async throws -> BackendVersion { throw APIError.badURL }
    func createSenderGroup(_ body: SenderGroupWrite) async throws -> SenderGroup {
        throw APIError.badURL
    }
    func updateSenderGroup(id: Int, patch: SenderGroupWrite) async throws -> SenderGroup {
        throw APIError.badURL
    }
    func deleteSenderGroup(id: Int) async throws {}
    func getPreferences() async throws -> Preferences { throw APIError.badURL }
    func setPreference(key: String, value: String) async throws {}
    func getNotificationPrefs() async throws -> NotificationPrefs { throw APIError.badURL }
    func setNotificationPrefs(_ patch: NotificationPrefsWrite) async throws -> NotificationPrefs {
        throw APIError.badURL
    }
    func storeAccount(email: String, appPassword: String,
                      retrievalWindow: RetrievalWindow?) async throws {}
    func previewRetrieval(email: String, appPassword: String) async throws -> RetrievalPreview {
        throw APIError.badURL
    }
    func verifyAccount(_ email: String) async throws -> VerifyResult { throw APIError.badURL }
    func disconnectAccount(_ email: String) async throws {}
}

@MainActor
final class LaunchRoutingTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LaunchRoutingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func router(_ backend: ColdStartBackend, tutorialSeen: Bool,
                        timeout: Duration = .seconds(5)) -> LaunchRouter {
        defaults.set(tutorialSeen, forKey: OnboardingViewModel.tutorialSeenKey)
        return LaunchRouter(
            onboardModel: OnboardingViewModel(api: backend, defaults: defaults),
            isBackendHealthy: { backend.probe() },
            readinessTimeout: timeout,
            readinessInterval: .milliseconds(5))
    }

    /// The 2026-10-10 reproduction: an existing user, a backend still starting.
    func test_existingUser_backendRefusesFirstCalls_reachesMain() async {
        let backend = ColdStartBackend(refuseFirst: 3, accounts: ["a@example.com"])
        let router = router(backend, tutorialSeen: true)

        await router.resolve()

        XCTAssertEqual(router.route, .main,
                       "an existing user must not be routed into onboarding by a cold start")
        XCTAssertEqual(backend.apiCallsRefused, 0,
                       "no API request may be sent before the backend answers /health")
    }

    func test_newUser_backendRefusesFirstCalls_reachesOnboarding_andAskStepLoads() async {
        let backend = ColdStartBackend(refuseFirst: 3, accounts: [])
        let router = router(backend, tutorialSeen: false)

        await router.resolve()
        XCTAssertEqual(router.route, .onboarding)

        // What OnboardingView's .task does as soon as it appears.
        let ask = AskPeopleModel(api: backend)
        await ask.load()
        XCTAssertEqual(ask.phase, .editing, "the Ask step must show its fields, not Try again")
        XCTAssertEqual(backend.apiCallsRefused, 0)
    }

    func test_backendNeverComesUp_isUnreachable_notOnboarding() async {
        // A NEW user is the tempting case to misroute: zero accounts and an
        // unreachable backend used to look identical.
        let backend = ColdStartBackend(refuseFirst: .max, accounts: [])
        let router = router(backend, tutorialSeen: false, timeout: .milliseconds(200))

        await router.resolve()

        XCTAssertEqual(router.route, .unreachable)
    }

    func test_retryAfterUnreachable_reachesTheCorrectScreen() async {
        let backend = ColdStartBackend(refuseFirst: .max, accounts: ["a@example.com"])
        let router = router(backend, tutorialSeen: true, timeout: .milliseconds(200))
        await router.resolve()
        XCTAssertEqual(router.route, .unreachable)

        backend.comeUp()
        await router.retry()

        XCTAssertEqual(router.route, .main)
    }

    /// Distinct from the gate: /health answers, but the account check itself
    /// fails. That is still not "zero accounts".
    func test_accountCheckFails_isUnreachable_notOnboarding() async {
        let backend = ColdStartBackend(refuseFirst: 0, accounts: [])
        backend.accountsFailure = APIError.http(status: 500, body: nil)
        let router = router(backend, tutorialSeen: true)

        await router.resolve()

        XCTAssertEqual(router.route, .unreachable)
        XCTAssertFalse(router.onboardModel.shouldOnboard,
                       "shouldOnboard may only be true after a successful account check")
    }

    /// Guards the over-correction: a successful empty answer still onboards.
    func test_successfulZeroAccounts_stillOnboards() async {
        let backend = ColdStartBackend(refuseFirst: 0, accounts: [])
        let router = router(backend, tutorialSeen: true)

        await router.resolve()

        XCTAssertEqual(router.route, .onboarding)
    }
}
