//
//  RetrievalWindowTests.swift
//  ThresherTests
//
//  The backfill-scope gap: D61 shipped the retrieval window server-side in
//  Session 33, but `storeAccount` never sent it — so EVERY account connected
//  through the real UI got "everything", which is the 3,311-message harm the
//  feature exists to prevent. The backend was right and unreachable.
//
//  What these pin, in rough order of how quietly each could break:
//
//  1. The window actually reaches the wire. This is the whole bug.
//  2. Omitted-when-nil, never null — an absent key means "no cutoff"
//     server-side, so the encoding choice IS the compatibility contract.
//  3. The raw values match the server's RETRIEVAL_WINDOWS, or the server 400s.
//  4. A failed size preview never renders as zero.
//

import XCTest
@testable import Thresher

@MainActor
final class RetrievalWindowTests: XCTestCase {

    private class RecordingAPI: SettingsAPI, @unchecked Sendable {
        fileprivate(set) var storedWindow: RetrievalWindow??
        fileprivate(set) var previewCalls = 0
        var previewResult: RetrievalPreview?
        var previewError: Error?
        var verifyOK = true

        func storeAccount(email: String, appPassword: String,
                          retrievalWindow: RetrievalWindow?) async throws {
            storedWindow = .some(retrievalWindow)
        }
        func previewRetrieval(email: String, appPassword: String) async throws -> RetrievalPreview {
            previewCalls += 1
            if let previewError { throw previewError }
            return previewResult ?? RetrievalPreview(account: email, counts: [:])
        }
        func verifyAccount(_ email: String) async throws -> VerifyResult {
            // VerifyResult is decode-only (it normalises `reason`), so build one
            // the way the network would rather than adding an init for tests.
            let json = #"{"ok":\#(verifyOK),"reason":"ok"}"#.data(using: .utf8)!
            return try JSONDecoder().decode(VerifyResult.self, from: json)
        }
        func listAccounts() async throws -> [String] { [] }
        func disconnectAccount(_ email: String) async throws {}
        func getRules(includeDisabled: Bool) async throws -> RulesResponse {
            RulesResponse(rules: [], senderGroups: [])
        }
        func createRule(_ body: RuleWrite) async throws -> Rule { throw APIError.badURL }
        func updateRule(id: Int, patch: RuleWrite) async throws -> Rule { throw APIError.badURL }
        func deleteRule(id: Int) async throws {}
        func reorderRules(orderedIds: [Int]) async throws -> [Rule] { [] }
        func reclassifyAllMessages() async throws -> ReclassifySummary { throw APIError.badURL }
        func backendVersion() async throws -> BackendVersion { throw APIError.badURL }
        func createSenderGroup(_ body: SenderGroupWrite) async throws -> SenderGroup { throw APIError.badURL }
        func updateSenderGroup(id: Int, patch: SenderGroupWrite) async throws -> SenderGroup { throw APIError.badURL }
        func deleteSenderGroup(id: Int) async throws {}
        func getPreferences() async throws -> Preferences { Preferences(values: [:]) }
        func setPreference(key: String, value: String) async throws {}
        func getNotificationPrefs() async throws -> NotificationPrefs {
            NotificationPrefs(quietHoursStart: nil, quietHoursEnd: nil, audioAlerts: false)
        }
        func setNotificationPrefs(_ patch: NotificationPrefsWrite) async throws -> NotificationPrefs {
            NotificationPrefs(quietHoursStart: nil, quietHoursEnd: nil, audioAlerts: false)
        }
    }

    // ── The wire contract: the gap itself ────────────────────────────────────

    func testTheWindowIsENCODEDIntoTheStoreAccountBody() throws {
        /// THE BUG. `storeAccount` sent only {account, app_password}, so D61's
        /// server-side window was unreachable from the real UI and every account
        /// connected through it retrieved everything.
        let body = StoreAccountBody(account: "a@x.example", appPassword: "pw",
                                    retrievalWindow: "3m")
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(body)) as! [String: Any]
        XCTAssertEqual(json["retrieval_window"] as? String, "3m")
        XCTAssertEqual(json["app_password"] as? String, "pw")
    }

    func testANilWindowIsOMITTED_notEncodedAsNull() throws {
        /// Server-side an ABSENT key means "no cutoff" (the pre-D61 behaviour).
        /// A literal null is a different value on the wire, and relying on the
        /// server to coerce it is relying on something nobody wrote down.
        let body = StoreAccountBody(account: "a@x.example", appPassword: "pw",
                                    retrievalWindow: nil)
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(body)) as! [String: Any]
        XCTAssertNil(json["retrieval_window"],
                     "a nil window must be omitted, not sent as null")
    }

    func testTheRawValuesMatchTheServersWindowSet() {
        /// These are the exact keys of RETRIEVAL_WINDOWS in api/app.py. The
        /// server 400s anything else, so a typo here is a connect that fails
        /// only at runtime, only for the window nobody tested.
        XCTAssertEqual(Set(RetrievalWindow.allCases.map(\.rawValue)),
                       ["1w", "1m", "3m", "everything"])
    }

    func testTheDefaultIsTheMIDDLEOptionNotTheNarrowest() {
        /// The choice is ONE-WAY (D61/BEHAVIOR.md: "pick a wider window than you
        /// think you need"), so an over-narrow default is the unrecoverable
        /// mistake. backfill-scope §6.2 asked for "start from now"; that predates
        /// D61 settling the asymmetry.
        XCTAssertEqual(RetrievalWindow.default, .threeMonths)
    }

    // ── The connect path actually carries it ─────────────────────────────────

    func testConnectingSendsTheSelectedWindow() async throws {
        let api = RecordingAPI()
        let result = try await AccountConnectView.performConnect(
            api: api, account: "a@x.example", secret: "pw", window: .oneWeek)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(api.storedWindow ?? nil, .oneWeek)
    }

    func testConnectingWithoutTouchingThePickerSendsTheDefault() async throws {
        /// The silent path: a user who ignores the control must still get a
        /// bounded backfill, not "everything" by omission — which is exactly what
        /// shipped before this change.
        let api = RecordingAPI()
        try await AccountConnectView.performConnect(
            api: api, account: "a@x.example", secret: "pw", window: .default)
        XCTAssertEqual(api.storedWindow ?? nil, .threeMonths)
    }

    func testStoreHappensBEFOREVerify() async throws {
        /// §1.8, confirmed by running back in Session 14: /accounts/verify tests
        /// the credential ALREADY in the Keychain and ignores any password in the
        /// body, so verifying first would always fail for a new account. An
        /// ordering like this is exactly what a refactor inverts silently.
        final class OrderAPI: RecordingAPI, @unchecked Sendable {
            var order: [String] = []
            override func storeAccount(email: String, appPassword: String,
                                       retrievalWindow: RetrievalWindow?) async throws {
                order.append("store")
                try await super.storeAccount(email: email, appPassword: appPassword,
                                             retrievalWindow: retrievalWindow)
            }
            override func verifyAccount(_ email: String) async throws -> VerifyResult {
                order.append("verify")
                return try await super.verifyAccount(email)
            }
        }
        let api = OrderAPI()
        try await AccountConnectView.performConnect(
            api: api, account: "a@x.example", secret: "pw", window: .threeMonths)
        XCTAssertEqual(api.order, ["store", "verify"])
    }

    // ── The size preview is honest ───────────────────────────────────────────

    func testThePreviewReportsThePerWindowCount() {
        let preview = RetrievalPreview(account: "a@x.example",
                                       counts: ["1w": 40, "3m": 340, "everything": 3311])
        XCTAssertEqual(preview.count(for: .threeMonths), 340)
        XCTAssertEqual(preview.count(for: .everything), 3311)
    }

    func testAMissingCountIsNIL_notZero() {
        /// Zero would read as "your mailbox is empty" at the exact moment the
        /// user is deciding how much to import — the most misleading possible
        /// answer, and indistinguishable from a genuinely empty mailbox.
        let preview = RetrievalPreview(account: "a@x.example", counts: [:])
        XCTAssertNil(preview.count(for: .everything))
    }

    func testAFailedPreviewDoesNotBlockConnecting() async throws {
        /// Refusing to connect over a failed *preview* would be the tail wagging
        /// the dog: the preview is advisory, the connect is the actual task.
        let api = RecordingAPI()
        api.previewError = APIError.http(status: 502, body: "mailbox unreachable")
        try await AccountConnectView.performConnect(
            api: api, account: "a@x.example", secret: "pw", window: .oneMonth)
        XCTAssertEqual(api.storedWindow ?? nil, .oneMonth)
    }
}
