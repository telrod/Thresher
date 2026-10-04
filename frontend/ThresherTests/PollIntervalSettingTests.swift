//
//  PollIntervalSettingTests.swift
//  ThresherTests
//
//  Polish batch 2, Part A: `poll_interval_minutes` is exposed in Settings.
//
//  The pref already existed and was already honoured on both sides — the backend
//  poller reads it per pass, and D49 derives the app's refresh cadence and the
//  D45 delivery-claim TTL from it — but there was NO WAY TO SET IT. It sat in the
//  DB, editable only by curl.
//
//  Two things these tests pin that are easy to get subtly wrong:
//
//  1. The bound is enforced CLIENT-side too, not just by the server. A control
//     that lets you pick 0 and then shows a server error is a worse control than
//     one that cannot express 0.
//  2. The D49 derivation must still hold across the NEW range. At the 1-minute
//     end the halving hits the 30s floor, so the app must not start spinning
//     faster than the floor just because the user picked the minimum.
//

import XCTest
@testable import Thresher

@MainActor
final class PollIntervalSettingTests: XCTestCase {

    // ── A recording fake: what did the editor actually PUT? ──────────────────

    private final class RecordingAPI: SettingsAPI, @unchecked Sendable {
        var stored: [String: String]
        private(set) var writes: [(key: String, value: String)] = []
        var failNextWrite: Error?

        init(stored: [String: String] = [:]) { self.stored = stored }

        func getPreferences() async throws -> Preferences { Preferences(values: stored) }
        func setPreference(key: String, value: String) async throws {
            if let failNextWrite { self.failNextWrite = nil; throw failNextWrite }
            writes.append((key, value))
            stored[key] = value
        }
        func getNotificationPrefs() async throws -> NotificationPrefs {
            NotificationPrefs(quietHoursStart: nil, quietHoursEnd: nil, audioAlerts: false)
        }
        func setNotificationPrefs(_ patch: NotificationPrefsWrite) async throws -> NotificationPrefs {
            NotificationPrefs(quietHoursStart: nil, quietHoursEnd: nil, audioAlerts: false)
        }

        // Unused by this editor.
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
        func listAccounts() async throws -> [String] { [] }
        func storeAccount(email: String, appPassword: String,
                          retrievalWindow: RetrievalWindow?) async throws {}
        func previewRetrieval(email: String, appPassword: String) async throws -> RetrievalPreview {
            RetrievalPreview(account: email, counts: [:])
        }
        func verifyAccount(_ email: String) async throws -> VerifyResult { throw APIError.badURL }
        func disconnectAccount(_ email: String) async throws {}
    }

    // ── Load / save round trip ───────────────────────────────────────────────

    func testLoadReadsTheStoredPollInterval() async {
        let api = RecordingAPI(stored: ["poll_interval_minutes": "9",
                                        "operating_mode": "focus"])
        let model = NotificationsViewModel(api: api)
        await model.load()
        XCTAssertEqual(model.pollIntervalMinutes, 9)
    }

    func testAnAbsentPollIntervalFallsBackToTheDefault() async {
        let api = RecordingAPI(stored: ["operating_mode": "focus"])
        let model = NotificationsViewModel(api: api)
        await model.load()
        XCTAssertEqual(model.pollIntervalMinutes, Preferences.defaultPollIntervalMinutes)
    }

    func testSavingWritesThePollIntervalPref() async {
        let api = RecordingAPI(stored: ["operating_mode": "focus"])
        let model = NotificationsViewModel(api: api)
        await model.load()
        model.pollIntervalMinutes = 12
        await model.save()

        XCTAssertEqual(api.stored["poll_interval_minutes"], "12")
        XCTAssertTrue(api.writes.contains { $0.key == "poll_interval_minutes" && $0.value == "12" })
    }

    func testSavingAnUnchangedIntervalStillRoundTripsTheOtherPrefs() async {
        /// Operating mode and the interval share the generic per-key surface;
        /// adding the interval write must not displace the mode write.
        let api = RecordingAPI(stored: ["operating_mode": "focus"])
        let model = NotificationsViewModel(api: api)
        await model.load()
        model.operatingMode = .catchUp
        await model.save()

        XCTAssertEqual(api.stored["operating_mode"], "catch-up")
        XCTAssertNotNil(api.stored["poll_interval_minutes"])
    }

    // ── The client-side bound ────────────────────────────────────────────────

    func testTheClientClampsBelowTheMinimum() async {
        /// A zero interval is a spin loop. The server rejects it too, but the
        /// control must not be able to express it in the first place.
        let api = RecordingAPI()
        let model = NotificationsViewModel(api: api)
        await model.load()
        model.pollIntervalMinutes = 0
        await model.save()

        XCTAssertEqual(api.stored["poll_interval_minutes"],
                       String(NotificationsViewModel.pollIntervalRange.lowerBound))
    }

    func testTheClientClampsAboveTheMaximum() async {
        let api = RecordingAPI()
        let model = NotificationsViewModel(api: api)
        await model.load()
        model.pollIntervalMinutes = 999
        await model.save()

        XCTAssertEqual(api.stored["poll_interval_minutes"],
                       String(NotificationsViewModel.pollIntervalRange.upperBound))
    }

    func testTheClientRangeMATCHESTheServerBound() {
        /// 1–15, the same numbers `_validate_preference` enforces in api/app.py.
        /// If these drift, the UI offers a value the server will 400 on — the
        /// class of bug where the control looks fine and the save silently fails.
        XCTAssertEqual(NotificationsViewModel.pollIntervalRange, 1...15)
    }

    func testAStoredValueOutsideTheRangeIsClampedOnLoad() async {
        /// A pre-existing DB (or a curl'd value from before the bound existed)
        /// must not present the picker with an unselectable value.
        let api = RecordingAPI(stored: ["poll_interval_minutes": "60"])
        let model = NotificationsViewModel(api: api)
        await model.load()
        XCTAssertTrue(NotificationsViewModel.pollIntervalRange.contains(model.pollIntervalMinutes),
                      "an out-of-range stored value reached the picker: \(model.pollIntervalMinutes)")
    }

    // ── D49 still holds across the new range ─────────────────────────────────

    func testTheD49DerivationHoldsAtTheONE_MINUTE_END() {
        /// interval/2 = 30s, which is exactly the floor — the app must not spin
        /// faster than 30s just because the user chose the minimum.
        let period = MessageListViewModel.refreshPeriod(forPollInterval: 60)
        XCTAssertEqual(period, MessageListViewModel.minimumRefreshPeriod)
        XCTAssertGreaterThanOrEqual(period, 30)
    }

    func testTheD49DerivationHoldsAtTheFIFTEEN_MINUTE_END() {
        XCTAssertEqual(MessageListViewModel.refreshPeriod(forPollInterval: 15 * 60), 450)
    }

    func testTheDeliveryHeartbeatIsTheSameAtEverySettableInterval() {
        /// SUPERSEDES the D49 assertion here ("the claim TTL must stay ahead of
        /// the cadence, 2× + 30s"). That property is what lost a Tier 1 alert on
        /// 2026-09-06: a TTL long enough to span one poll interval is also long
        /// enough to outlive a quit app, and at 15 minutes it was 1830s.
        ///
        /// The app now checks in on a fixed cadence the backend can bound, so
        /// what must hold across the settable range is that the cadence does not
        /// move with the interval at all.
        for minutes in NotificationsViewModel.pollIntervalRange {
            let interval = TimeInterval(minutes * 60)
            let cadence = NotificationManager.claimTTL(forPollInterval: interval)
            XCTAssertEqual(cadence, Int(NotificationManager.heartbeatSeconds),
                           "heartbeat cadence varies with the interval at \(minutes)m")
        }
    }

    // ── Human gate 3.1 (2026-09-01): "it goes back to 5 minutes" ─────────────
    //
    // Recorded as FAILED twice at the keyboard — set 1, reverted; set 15,
    // reverted. The backend was never at fault: the API log shows TWO attempted
    // changes and exactly ONE PUT. The stepper edits local state and only the
    // "Save preferences" button in a separate Section persists, so an edit made
    // and then navigated away from is simply dropped — silently, and with the
    // stepper's own label having shown the new value the whole time.
    //
    // These pin the round trip AND the visibility of a pending save, because
    // the old tests covered clamping and derivation (both correct) and could
    // not have caught this.

    func testAnEditedIntervalSurvivesSaveAndReload() async {
        /// The gate's actual complaint, end to end. Nothing here existed before:
        /// every prior test called save() and inspected `writes`, which cannot
        /// distinguish "persisted" from "persisted and then read back wrong".
        let api = RecordingAPI(stored: ["poll_interval_minutes": "5"])
        let model = NotificationsViewModel(api: api)
        await model.load()
        XCTAssertEqual(model.pollIntervalMinutes, 5)

        model.pollIntervalMinutes = 12
        await model.save()

        // A FRESH model against the same store — this is "close Settings and
        // come back", which is where the value appeared to revert.
        let reopened = NotificationsViewModel(api: api)
        await reopened.load()
        XCTAssertEqual(reopened.pollIntervalMinutes, 12,
                       "a saved interval must survive reopening Settings")
    }

    func testAPendingEditIsVisibleAsUnsaved() async {
        /// The fix for the gate failure is not persistence — that already
        /// worked — but SAYING that a save is owed.
        let api = RecordingAPI(stored: ["poll_interval_minutes": "5"])
        let model = NotificationsViewModel(api: api)
        await model.load()
        XCTAssertFalse(model.hasUnsavedChanges,
                       "a freshly loaded editor has nothing pending")

        model.pollIntervalMinutes = 1
        XCTAssertTrue(model.hasUnsavedChanges,
                      "an edited interval must announce itself as unsaved")

        await model.save()
        XCTAssertFalse(model.hasUnsavedChanges,
                       "saving clears the pending state")
    }

    func testAnUntouchedEditorNeverClaimsUnsavedChanges() async {
        /// Crying wolf is its own defect: an indicator that is always on is
        /// indistinguishable from no indicator (the -dirty stamp lesson).
        let api = RecordingAPI(stored: ["poll_interval_minutes": "5"])
        let model = NotificationsViewModel(api: api)
        XCTAssertFalse(model.hasUnsavedChanges,
                       "before the first load there is nothing to compare")
        await model.load()
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testEveryEditableFieldParticipatesInTheUnsavedCheck() async {
        /// The snapshot must cover the whole editor, not just the field that
        /// prompted it — a dirty check that misses a field is worse than none,
        /// because it makes "no indicator" mean "nothing pending".
        let api = RecordingAPI(stored: ["poll_interval_minutes": "5",
                                        "operating_mode": "focus"])

        for mutate in [
            { (m: NotificationsViewModel) in m.pollIntervalMinutes = 9 },
            { (m: NotificationsViewModel) in m.quietHoursStart = "23:00" },
            { (m: NotificationsViewModel) in m.quietHoursEnd = "07:00" },
            { (m: NotificationsViewModel) in m.audioAlerts.toggle() },
            { (m: NotificationsViewModel) in m.operatingMode = .catchUp },
        ] {
            let model = NotificationsViewModel(api: api)
            await model.load()
            XCTAssertFalse(model.hasUnsavedChanges)
            mutate(model)
            XCTAssertTrue(model.hasUnsavedChanges,
                          "an edited field must mark the editor dirty")
        }
    }

    func testAFailedSaveKeepsThePendingStatePending() async {
        /// If the write fails, the edit is still unsaved — clearing the flag
        /// would tell the user their change landed when it did not, which is
        /// the same class of silent loss the gate found.
        let api = RecordingAPI(stored: ["poll_interval_minutes": "5"])
        let model = NotificationsViewModel(api: api)
        await model.load()
        model.pollIntervalMinutes = 11
        api.failNextWrite = APIError.http(status: 500, body: "boom")

        await model.save()

        XCTAssertTrue(model.hasUnsavedChanges,
                      "a failed save must not report itself as clean")
    }
}
