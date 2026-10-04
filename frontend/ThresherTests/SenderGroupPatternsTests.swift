//
//  SenderGroupPatternsTests.swift
//  ThresherTests
//
//  D53 — multi-pattern sender groups, client side.
//
//  Two things need pinning, and both are decode/encode contracts rather than
//  layout, so they belong in a plain unit test:
//
//  1. The READ model must survive an UNMIGRATED backend. `patterns` is new, so a
//     backend that hasn't run the migration sends only `email_pattern`. Rendering
//     "no patterns" for a group that plainly has members would be a lie about the
//     user's config, so the decoder falls back.
//  2. The WRITE model must send the whole `patterns` set and must NOT send the
//     deprecated `email_pattern`. The server replaces the set atomically (D44
//     shape); a stale legacy key in the payload is exactly the "conflicting
//     patterns" 400 the server now raises by name (E12).
//

import XCTest
import AppKit
import SwiftUI
@testable import Thresher

final class SenderGroupPatternsTests: XCTestCase {

    private func decode(_ json: String) throws -> SenderGroup {
        try JSONDecoder().decode(SenderGroup.self, from: Data(json.utf8))
    }

    // ── Read model ────────────────────────────────────────────────────────────

    func testDecodesTheMultiPatternPayload_D53() throws {
        let g = try decode("""
        {"id": 7, "group_name": "Me", "email_pattern": "*@example.org",
         "patterns": ["*@example.org", "dana@work.example"],
         "urgency_floor": 1, "notes": null}
        """)
        XCTAssertEqual(g.patterns, ["*@example.org", "dana@work.example"])
        XCTAssertEqual(g.urgencyFloor, 1)
    }

    func testFallsBackToTheLegacyEmailPatternWhenPatternsIsAbsent_D53() throws {
        // What an unmigrated backend sends: no `patterns` key at all.
        let g = try decode("""
        {"id": 3, "group_name": "close_colleagues",
         "email_pattern": "*@example.com", "urgency_floor": 2, "notes": null}
        """)
        XCTAssertEqual(g.patterns, ["*@example.com"],
                       "an unmigrated backend's group must still show its member pattern")
    }

    func testFallsBackWhenPatternsIsPresentButEmpty_D53() throws {
        let g = try decode("""
        {"id": 3, "group_name": "x", "email_pattern": "a@b.example",
         "patterns": [], "urgency_floor": 2, "notes": null}
        """)
        XCTAssertEqual(g.patterns, ["a@b.example"])
    }

    func testAGenuinelyPatternlessGroupDecodesAsEmpty_D53() throws {
        // The legacy placeholder shape: no patterns AND no legacy pattern. This must
        // decode as empty rather than inventing one — the group really does match
        // nobody, and the list row says so in orange.
        let g = try decode("""
        {"id": 4, "group_name": "recruiters", "email_pattern": "",
         "patterns": [], "urgency_floor": 2, "notes": null}
        """)
        XCTAssertTrue(g.patterns.isEmpty)
    }

    // ── Write model ───────────────────────────────────────────────────────────

    private func encoded(_ w: SenderGroupWrite) throws -> [String: Any] {
        let data = try JSONEncoder().encode(w)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testWriteBodySendsPatternsAndNotTheDeprecatedColumn_D53() throws {
        var w = SenderGroupWrite()
        w.groupName = "cousins"
        w.patterns = ["a@x.example", "*@y.example"]
        w.urgencyFloor = 2

        let json = try encoded(w)
        XCTAssertEqual(json["patterns"] as? [String], ["a@x.example", "*@y.example"])
        XCTAssertEqual(json["group_name"] as? String, "cousins")
        XCTAssertNil(json["email_pattern"],
                     "sending the deprecated key alongside patterns is what the "
                     + "server rejects as a conflict (E12)")
    }

    func testOmittingPatternsLeavesTheSetUntouched_D53() throws {
        // A floor-only edit must not carry an empty `patterns`, which the server
        // would reject as an empty set (DG3) — omission means "don't touch".
        var w = SenderGroupWrite()
        w.urgencyFloor = 4

        let json = try encoded(w)
        XCTAssertNil(json["patterns"])
        XCTAssertEqual(json["urgency_floor"] as? Int, 4)
    }

    // ── The memberwise init used by tests/previews ────────────────────────────

    func testMemberwiseInitMirrorsTheLegacyPatternIntoPatterns_D53() {
        let g = SenderGroup(id: 1, groupName: "leadership",
                            emailPattern: "boss@x.example", urgencyFloor: 1)
        XCTAssertEqual(g.patterns, ["boss@x.example"])
    }
}

// ── D53 render evidence, at real data widths (the OI18 lesson) ───────────────

/// The workorder asks for render evidence of a group with several patterns AND a
/// placeholder group with none. Rendering it is the only way to see that the
/// patternless case says so instead of showing a blank line — the OI18 failure was
/// exactly "the probe data never exercised the real shape".
@MainActor
final class SenderGroupRenderEvidenceTests: XCTestCase {

    private static let evidenceDir = URL(fileURLWithPath: "/tmp/thresher-d53")

    private func render<V: View>(_ view: V, to filename: String,
                                width: CGFloat = 560, height: CGFloat = 620) throws {
        try? FileManager.default.createDirectory(at: Self.evidenceDir,
                                                 withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(
            rootView: view.frame(width: width, height: height).preferredColorScheme(.light))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        defer { window.close() }

        let content = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: Self.evidenceDir.appendingPathComponent(filename))
    }

    func testRenderEvidenceMultiPatternEditorAndPatternlessGroup_D53() throws {
        // A group with three patterns — the shape the editor now has to hold.
        let multi = SenderGroup(id: 7, groupName: "Me",
                                patterns: ["*@example.org", "dana@work.example",
                                           "@personal.example"],
                                urgencyFloor: 1)
        try render(SenderGroupEditorView(existing: multi, onSave: { _ in nil }),
                   to: "editor-multi-pattern.png")

        // The legacy placeholder: no patterns at all. Save must be blocked WITH a
        // visible reason, not a silently grey button.
        let empty = SenderGroup(id: 4, groupName: "recruiters",
                                patterns: [], urgencyFloor: 2)
        try render(SenderGroupEditorView(existing: empty, onSave: { _ in nil }),
                   to: "editor-patternless.png")

        // Model-level assertions so this stays a test, not just a camera.
        XCTAssertEqual(multi.patterns.count, 3)
        XCTAssertTrue(empty.patterns.isEmpty)
    }
}

/// Render evidence for the provenance footer, in the two states that matter: matching
/// SHAs, and the Session-27 case (a backend that was never restarted, so the SHAs
/// differ and the "≠" marker shows).
@MainActor
final class BuildProvenanceRenderEvidenceTests: XCTestCase {

    private static let evidenceDir = URL(fileURLWithPath: "/tmp/thresher-prov")

    private final class VersionAPI: SettingsAPI, @unchecked Sendable {
        let version: BackendVersion?
        init(version: BackendVersion?) { self.version = version }
        func getRules(includeDisabled: Bool) async throws -> RulesResponse {
            RulesResponse(rules: [], senderGroups: [])
        }
        func createRule(_ body: RuleWrite) async throws -> Rule { throw APIError.badURL }
        func updateRule(id: Int, patch: RuleWrite) async throws -> Rule { throw APIError.badURL }
        func deleteRule(id: Int) async throws {}
        func reorderRules(orderedIds: [Int]) async throws -> [Rule] { [] }
        func reclassifyAllMessages() async throws -> ReclassifySummary { throw APIError.badURL }
        func backendVersion() async throws -> BackendVersion {
            guard let version else { throw APIError.badURL }
            return version
        }
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
        func listAccounts() async throws -> [String] { [] }
        func storeAccount(email: String, appPassword: String,
                          retrievalWindow: RetrievalWindow?) async throws {}
        func previewRetrieval(email: String, appPassword: String) async throws -> RetrievalPreview {
            RetrievalPreview(account: email, counts: [:])
        }
        func verifyAccount(_ email: String) async throws -> VerifyResult { throw APIError.badURL }
        func disconnectAccount(_ email: String) async throws {}
    }

    private func render(_ version: BackendVersion?, to filename: String) throws {
        try? FileManager.default.createDirectory(at: Self.evidenceDir,
                                                 withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(
            rootView: SettingsView(api: VersionAPI(version: version))
                .frame(width: 760, height: 520)
                .preferredColorScheme(.light))
        window.orderFrontRegardless()
        // The footer's .task fetch is local (no network), so a couple of run-loop
        // slices is enough — but wait for ink rather than assuming.
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        defer { window.close() }

        let content = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: Self.evidenceDir.appendingPathComponent(filename))
    }

    func testRenderEvidenceProvenanceFooter() throws {
        // Matching: no marker.
        try render(BackendVersion(gitSHA: AppBuildStamp.current.sha,
                                  startedAt: "2026-07-26T15:29:00+00:00"),
                   to: "footer-match.png")
        // The Session 27 case: backend never restarted, so the SHAs differ.
        try render(BackendVersion(gitSHA: "39fd8c0-dirty",
                                  startedAt: "2026-07-26T15:29:00+00:00"),
                   to: "footer-mismatch.png")
        // Unreachable backend — provenance-relevant in itself.
        try render(nil, to: "footer-backend-unreachable.png")
    }
}
