//
//  AskPeopleStepTests.swift
//  ThresherTests
//
//  The onboarding Ask step (workorder Phase 2): the model's handling of every
//  status `POST /onboarding/people` returns, the navigation rules it added
//  (D76, D77), and a hosted render of each visible state.
//
//  WHAT THESE CANNOT PROVE: that a click reaches the model, or that the step is
//  reachable inside the running app. The model tests prove the state is right;
//  the renders prove each state is legible and distinct. Reachability and the
//  keyboard-only pass are Phase 3, run by a human.
//

import AppKit
import SwiftUI
import XCTest
@testable import Thresher

// ── Fake ─────────────────────────────────────────────────────────────────────

private final class AskFakeAPI: SettingsAPI, @unchecked Sendable {
    var groups: [SenderGroup]
    var loadFails = false
    var result: Result<OnboardingPeopleResponse, Error> = .failure(APIError.badURL)
    private(set) var saves: [(leadership: [String], family: [String])] = []

    init(leadership: [String] = ["boss@example.com"], family: [String] = []) {
        groups = [
            SenderGroup(id: 1, groupName: "leadership", patterns: leadership, urgencyFloor: 1),
            SenderGroup(id: 2, groupName: "family", patterns: family, urgencyFloor: 1),
        ]
    }

    func saveOnboardingPeople(leadership: [String], family: [String]) async throws
        -> OnboardingPeopleResponse {
        saves.append((leadership, family))
        return try result.get()
    }

    func getRules(includeDisabled: Bool) async throws -> RulesResponse {
        if loadFails { throw APIError.transport(URLError(.cannotConnectToHost)) }
        return RulesResponse(rules: [], senderGroups: groups)
    }
    func listAccounts() async throws -> [String] { [] }
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

private func response(_ status: String, _ groups: [String: [String]],
                      written: Bool = true, error: String? = nil) -> OnboardingPeopleResponse {
    // Built through the decoder, so these tests also pin the wire shape.
    var body: [String: Any] = ["written": written, "status": status, "groups": groups,
                               "reclassified": NSNull()]
    if let error { body["error"] = error }
    let data = try! JSONSerialization.data(withJSONObject: body)
    return try! JSONDecoder().decode(OnboardingPeopleResponse.self, from: data)
}

// ── Model ────────────────────────────────────────────────────────────────────

@MainActor
final class AskPeopleModelTests: XCTestCase {

    private func loaded(_ api: AskFakeAPI) async -> AskPeopleModel {
        let model = AskPeopleModel(api: api)
        await model.load()
        return model
    }

    private func type(_ text: String, into group: AskPeopleModel.Group,
                      _ model: AskPeopleModel) {
        let row = model.rows[group]!.last!          // the trailing empty row
        model.setText(text, group: group, row: row.id)
    }

    func testPrefillExcludesThePlaceholderAndKeepsAnEmptyRowToTypeInto() async {
        let api = AskFakeAPI(leadership: ["boss@example.com", "lead@example.com"],
                             family: ["kin@example.net"])
        let model = await loaded(api)
        XCTAssertEqual(model.phase, .editing)
        XCTAssertEqual(model.prefilled[.leadership], ["lead@example.com"])
        XCTAssertEqual(model.rows[.leadership]?.map(\.text), ["lead@example.com", ""])
        XCTAssertEqual(model.rows[.family]?.map(\.text), ["kin@example.net", ""])
    }

    func testSavedAdvancesAndSendsOnlyChangedGroups() async {
        let api = AskFakeAPI(family: ["kin@example.net"])
        api.result = .success(response("saved", ["leadership": ["dana@example.com"]]))
        let model = await loaded(api)
        type("dana@example.com", into: .leadership, model)
        let outcome = await model.primary()
        XCTAssertEqual(outcome, .advance)
        XCTAssertEqual(api.saves.count, 1)
        XCTAssertEqual(api.saves[0].leadership, ["dana@example.com"])
        XCTAssertEqual(api.saves[0].family, [], "an unchanged group is sent empty")
    }

    func testNoChangeWithMembersAdvancesWithoutCalling() async {
        let api = AskFakeAPI(family: ["kin@example.net"])
        let model = await loaded(api)
        let outcome = await model.primary()
        XCTAssertEqual(outcome, .advance)
        XCTAssertTrue(api.saves.isEmpty)
    }

    func testNothingEnteredAndNobodyThereConfirmsTheSkipAndSendsNothing() async {
        let api = AskFakeAPI()
        let model = await loaded(api)
        let first = await model.primary()
        XCTAssertEqual(first, .stay)
        XCTAssertEqual(model.phase, .confirmingSkip)
        model.cancelSkip()
        XCTAssertEqual(model.phase, .editing)
        XCTAssertEqual(model.skip(), .stay)
        XCTAssertEqual(model.phase, .confirmingSkip)
        XCTAssertEqual(model.skip(), .advance)
        XCTAssertTrue(api.saves.isEmpty, "skip sends nothing")
    }

    func testSkipWithExistingMembersAdvancesWithoutConfirming() async {
        let api = AskFakeAPI(family: ["kin@example.net"])
        let model = await loaded(api)
        XCTAssertEqual(model.skip(), .advance)
        XCTAssertTrue(api.saves.isEmpty)
    }

    func testRejectionMarksTheNamedEntryOnlyAndEditingClearsIt() async {
        let api = AskFakeAPI()
        api.result = .failure(OnboardingPeopleRejection(
            error: "'gmail.com' is out", invalid: [
                .init(group: "leadership", entry: "gmail.com", error: "'@gmail.com' is out")]))
        let model = await loaded(api)
        type("dana@example.com", into: .leadership, model)
        type("gmail.com", into: .leadership, model)
        let outcome = await model.primary()
        XCTAssertEqual(outcome, .stay)
        XCTAssertEqual(model.phase, .editing)
        let rows = model.rows[.leadership]!
        XCTAssertNil(rows[0].error)
        XCTAssertEqual(rows[1].error, "'@gmail.com' is out")
        XCTAssertNil(model.generalError)
        model.setText("gmail.co", group: .leadership, row: rows[1].id)
        XCTAssertNil(model.rows[.leadership]![1].error)
    }

    func testBothRetierStatusesStayAndSayTheyWereSaved() async {
        for status in ["saved_not_retiered", "saved_partially_retiered"] {
            let api = AskFakeAPI()
            api.result = .success(response(status, ["leadership": ["dana@example.com"]],
                                           error: "not re-tiered"))
            let model = await loaded(api)
            type("dana@example.com", into: .leadership, model)
            let outcome = await model.primary()
            XCTAssertEqual(outcome, .stay, status)
            XCTAssertEqual(model.phase, .savedNotRetiered(status))
            let next = await model.primary()
            XCTAssertEqual(next, .advance, "Continue moves on after reading it")
        }
    }

    func testUnchangedStatusAdvances() async {
        let api = AskFakeAPI()
        api.result = .success(response("unchanged", [:], written: false))
        let model = await loaded(api)
        type("dana@example.com", into: .leadership, model)
        let outcome = await model.primary()
        XCTAssertEqual(outcome, .advance)
    }

    func testClearingTheLastEntryLeavesOneEmptyRow() async {
        let api = AskFakeAPI(family: ["kin@example.net"])
        let model = await loaded(api)
        let kin = model.rows[.family]![0]
        model.setText("", group: .family, row: kin.id)
        XCTAssertEqual(model.rows[.family]?.map(\.text), [""])
        XCTAssertEqual(model.rows[.family]?.first?.id, kin.id, "the edited row is kept")
    }

    func testANormalizedEntryIsShownInItsStoredForm() async {
        let api = AskFakeAPI()
        api.result = .success(response("saved", ["leadership": ["@example.com"]]))
        let model = await loaded(api)
        type("example.com", into: .leadership, model)
        let outcome = await model.primary()
        XCTAssertEqual(outcome, .stay)
        XCTAssertEqual(model.phase, .saved)
        XCTAssertEqual(model.rows[.leadership]?.map(\.text), ["@example.com", ""])
    }

    func testAnEmptiedGroupShowsTheNoteAndIsSentEmpty() async {
        let api = AskFakeAPI(family: ["kin@example.net"])
        api.result = .success(response("saved", ["leadership": ["dana@example.com"]]))
        let model = await loaded(api)
        let kin = model.rows[.family]![0]
        model.setText("", group: .family, row: kin.id)
        XCTAssertTrue(model.isEmptied(.family))
        XCTAssertFalse(model.isEmptied(.leadership), "never had members")
        type("dana@example.com", into: .leadership, model)
        _ = await model.primary()
        XCTAssertEqual(api.saves.last?.family, [])
    }

    func testALoadFailureCannotSave() async {
        let api = AskFakeAPI()
        api.loadFails = true
        let model = await loaded(api)
        XCTAssertEqual(model.phase, .loadFailed)
        XCTAssertFalse(model.canSave)
        let outcome = await model.primary()
        XCTAssertEqual(outcome, .stay)
        XCTAssertTrue(api.saves.isEmpty)
        XCTAssertEqual(model.skip(), .advance)
    }
}

// ── Navigation ───────────────────────────────────────────────────────────────

final class OnboardingFlowTests: XCTestCase {

    func testAReturningUserStartsAtAsk() {
        XCTAssertEqual(OnboardingFlow.initialStep(hasSeenTutorial: true), .ask)
        XCTAssertEqual(OnboardingFlow.initialStep(hasSeenTutorial: false), .welcome)
    }

    func testAskComesBeforeConnect() {
        XCTAssertEqual(OnboardingView.Step.ask.rawValue + 1,
                       OnboardingView.Step.connect.rawValue)
    }

    func testBackIntoAskIsDisabledOnceAnAccountWasConnectedThisRun() {
        XCTAssertEqual(OnboardingFlow.previous(of: .connect, hasSeenTutorial: true,
                                               connectedThisRun: false), .ask)
        XCTAssertNil(OnboardingFlow.previous(of: .connect, hasSeenTutorial: true,
                                             connectedThisRun: true))
        // Other steps are unaffected by the connection.
        XCTAssertEqual(OnboardingFlow.previous(of: .preferences, hasSeenTutorial: true,
                                               connectedThisRun: true), .connect)
    }

    func testBackNeverReturnsToASeenTutorial() {
        XCTAssertNil(OnboardingFlow.previous(of: .ask, hasSeenTutorial: true,
                                             connectedThisRun: false))
        XCTAssertEqual(OnboardingFlow.previous(of: .ask, hasSeenTutorial: false,
                                               connectedThisRun: false), .welcome)
    }
}

// ── Wire shapes ──────────────────────────────────────────────────────────────

final class OnboardingPeopleWireTests: XCTestCase {

    /// The exact 400 body the backend returns (backend/api/app.py).
    func testRejectionDecodes() throws {
        let body = """
        {"error": "'@gmail.com' would match everyone at gmail.com",
         "invalid": [{"group": "family", "entry": "gmail.com",
                      "error": "'@gmail.com' would match everyone at gmail.com"}]}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(OnboardingPeopleRejection.self, from: body)
        XCTAssertEqual(r.invalid, [.init(group: "family", entry: "gmail.com",
                                         error: "'@gmail.com' would match everyone at gmail.com")])
    }

    /// A 207 carries a full reclassify summary or null; neither may break decoding.
    func testRetierResponseDecodes() throws {
        let body = """
        {"written": true, "status": "saved_partially_retiered",
         "groups": {"leadership": ["@example.com"]},
         "reclassified": {"counted": 3, "changed": 1, "unchanged": 2, "errors": 1,
                          "failed_ids": ["m1"]},
         "error": "Saved, but 1 stored message(s) were not re-tiered."}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(OnboardingPeopleResponse.self, from: body)
        XCTAssertEqual(r.status, "saved_partially_retiered")
        XCTAssertEqual(r.groups["leadership"], ["@example.com"])
    }
}

// ── Render ───────────────────────────────────────────────────────────────────

/// One PNG per visible state of the Ask step, written outside the repository.
///
/// Each state is reached through the model's own actions against a fake API,
/// not by setting fields, so a render reflects a path the step can really take.
/// The PNGs are compared pairwise: a state that renders identically to another
/// means that state is not visible at all (the four-identical-PNGs failure
/// recorded in CLAUDE.md).
@MainActor
final class AskPeopleRenderTests: XCTestCase {

    static let outputDir = URL(fileURLWithPath: "/tmp/thresher-ask-step")

    private struct Shot {
        let png: Data
        let ink: Int            // pixels that contrast with the background
        let background: Double  // luminance at a corner the view leaves empty
        let backgroundAlpha: Double
    }

    /// Renders `model` in `appearance` on `background`, writes the PNG, and
    /// measures it. "Ink" is any opaque pixel whose luminance differs from the
    /// background's by more than 0.4 — dark text on light, or light text on
    /// dark — so one measure serves both appearances. The bitmap is
    /// premultiplied: divide by alpha before reading colour.
    private func render(_ model: AskPeopleModel, _ name: String,
                        appearance: NSAppearance.Name, background: Color) throws -> Shot {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = NSHostingView(
            rootView: AskPeopleView(model: model)
                .padding(24)
                .frame(width: 560, height: 520, alignment: .topLeading)
                .background(background))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        defer { window.close() }

        let root = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)

        func sample(_ x: Int, _ y: Int) -> (lum: Double, alpha: Double)? {
            guard let raw = rep.colorAt(x: x, y: y),
                  let c = raw.usingColorSpace(.deviceRGB) else { return nil }
            let a = Double(c.alphaComponent)
            guard a > 0 else { return (0, 0) }
            return ((0.299 * c.redComponent + 0.587 * c.greenComponent
                     + 0.114 * c.blueComponent) / a, a)
        }
        // Bottom-right corner: inside the padding, below every state's content.
        let corner = try XCTUnwrap(sample(rep.pixelsWide - 4, rep.pixelsHigh - 4))
        var ink = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let s = sample(x, y), s.alpha > 0.5 else { continue }
                if abs(s.lum - corner.lum) > 0.4 { ink += 1 }
            }
        }
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: Self.outputDir,
                                                withIntermediateDirectories: true)
        try png.write(to: Self.outputDir.appendingPathComponent("\(name).png"))
        return Shot(png: png, ink: ink, background: corner.lum,
                    backgroundAlpha: corner.alpha)
    }

    private func loaded(_ api: AskFakeAPI) async -> AskPeopleModel {
        let model = AskPeopleModel(api: api)
        await model.load()
        return model
    }

    /// The six visible states, each reached through the model's own actions.
    private func states() async -> [(String, AskPeopleModel)] {
        // 1. empty — a fresh install: only the placeholder, which is hidden.
        let empty = await loaded(AskFakeAPI())

        // 2. prefilled — a returning user with members.
        let prefilled = await loaded(AskFakeAPI(
            leadership: ["boss@example.com", "lead@example.com"], family: ["kin@example.net"]))

        // 3. inline validation error, next to the entry it names.
        let rejecting = AskFakeAPI()
        rejecting.result = .failure(OnboardingPeopleRejection(
            error: "x", invalid: [.init(
                group: "family", entry: "gmail.com",
                error: "'@gmail.com' would match everyone at gmail.com, a shared mail provider. Enter the person's full address instead.")]))
        let invalid = await loaded(rejecting)
        invalid.setText("dana@example.com", group: .leadership,
                        row: invalid.rows[.leadership]!.last!.id)
        invalid.setText("gmail.com", group: .family, row: invalid.rows[.family]!.last!.id)
        _ = await invalid.primary()
        XCTAssertNotNil(invalid.rows[.family]!.first!.error)

        // 4. emptied-group note.
        let emptied = await loaded(AskFakeAPI(family: ["kin@example.net"]))
        emptied.setText("", group: .family, row: emptied.rows[.family]!.first!.id)
        XCTAssertTrue(emptied.isEmptied(.family))

        // 5. skip confirmation.
        let skipping = await loaded(AskFakeAPI())
        XCTAssertEqual(skipping.skip(), .stay)

        // 6. saved_not_retiered.
        let failing = AskFakeAPI()
        failing.result = .success(response("saved_not_retiered",
                                           ["leadership": ["dana@example.com"]],
                                           error: "Saved, but stored mail was not re-tiered"))
        let notRetiered = await loaded(failing)
        notRetiered.setText("dana@example.com", group: .leadership,
                            row: notRetiered.rows[.leadership]!.last!.id)
        _ = await notRetiered.primary()
        XCTAssertEqual(notRetiered.phase, .savedNotRetiered("saved_not_retiered"))

        return [("1-empty", empty), ("2-prefilled", prefilled),
                ("3-validation-error", invalid), ("4-emptied-group", emptied),
                ("5-skip-confirmation", skipping), ("6-saved-not-retiered", notRetiered)]
    }

    private func assertDistinct(_ shots: [String: Shot]) {
        XCTAssertEqual(shots.count, 6)
        let names = shots.keys.sorted()
        for (i, a) in names.enumerated() {
            for b in names[(i + 1)...] {
                XCTAssertNotEqual(shots[a]?.png, shots[b]?.png, "\(a) and \(b) rendered identically")
            }
        }
    }

    /// LIGHT appearance on an opaque white background. Without both, a machine
    /// in dark mode draws primary text white onto a transparent bitmap: the PNGs
    /// still differ byte-for-byte (coloured text and borders survive) while
    /// every title, label and entry is invisible. Measured — the first run of
    /// this test passed its distinctness check in exactly that state.
    func testEachStateRendersDistinctly() async throws {
        var shots: [String: Shot] = [:]
        for (name, model) in await states() {
            let shot = try render(model, name, appearance: .aqua, background: .white)
            // Ink is measured against the corner, so the corner must be the
            // opaque light ground — a transparent one makes white text count.
            XCTAssertGreaterThan(shot.backgroundAlpha, 0.99, "\(name): background is not opaque")
            XCTAssertGreaterThan(shot.background, 0.9, "\(name): background is not light")
            XCTAssertGreaterThan(shot.ink, 1500, "\(name): no legible text rendered (\(shot.ink) ink px)")
            shots[name] = shot
        }
        assertDistinct(shots)
    }

    /// DARK appearance on the real window's background. The onboarding window
    /// sets no background of its own, so what sits behind the step is the
    /// window's `windowBackgroundColor`, resolved dark — reproduced here as an
    /// opaque fill, not left transparent.
    ///
    /// Two guards, each proven red in all six states (2026-10-06):
    ///  - the corner must be opaque and dark, or this is not the real window.
    ///    Red with `Color.clear` as the background. The ink count alone stayed
    ///    green there (5.5k–9k px), which is why this guard exists.
    ///  - each state must carry ink that contrasts with that dark ground. Red
    ///    with `.foregroundStyle(Color.black)` forced on the step: 0 ink px in
    ///    five states, 615 in the sixth.
    ///
    /// LIMIT: "ink" is contrast, not text. A light fill counts too — forcing
    /// the light colour scheme turned every text field white and stayed green
    /// in five states. This proves text is not dark-on-dark; it does not prove
    /// the step looks right in dark mode. That glance is Phase 3's.
    func testEachStateIsLegibleInDarkAppearance() async throws {
        var shots: [String: Shot] = [:]
        for (name, model) in await states() {
            let shot = try render(model, "dark-\(name)", appearance: .darkAqua,
                                  background: Color(nsColor: .windowBackgroundColor))
            XCTAssertGreaterThan(shot.backgroundAlpha, 0.99,
                                 "\(name): background is not opaque (alpha \(shot.backgroundAlpha))")
            XCTAssertLessThan(shot.background, 0.3,
                              "\(name): background is not the dark window colour (lum \(shot.background))")
            XCTAssertGreaterThan(shot.ink, 1500,
                                 "\(name): no legible text on the dark window (\(shot.ink) ink px)")
            shots[name] = shot
        }
        assertDistinct(shots)
    }
}
