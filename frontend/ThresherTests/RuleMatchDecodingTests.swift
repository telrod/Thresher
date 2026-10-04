//
//  RuleMatchDecodingTests.swift
//  ThresherTests
//
//  E19 regression (dogfood defect batch 1, Part A).
//
//  The engine appends the sender-override invariant record to rule_matches with
//  rule_id: null — it is an invariant, not a rule. RuleMatch.ruleID was declared
//  as a non-optional Int, so JSONDecoder failed the WHOLE MessageDetail /
//  Explanation for any message from a sender-grouped sender (leadership, family —
//  precisely the T1 population): the detail view showed "Can't load this message /
//  unexpected shape" and the P3 explain panel never rendered.
//
//  Fixtures are REAL engine output, not hand-mocked payloads: captured 2026-07-16
//  from engine.classify() with a floor-2 sender group ('vip-e19') + a T4 subject
//  rule in a throwaway seeded DB, serialized through the live Flask app
//  (GET /messages/<id> and GET /messages/<id>/explain). The backend test
//  test_detail_and_explain_carry_nil_rule_id_override_record_E19 pins the same
//  shape server-side, so fixture and serializer can't drift apart silently.
//

import XCTest
@testable import Thresher

final class RuleMatchDecodingTests: XCTestCase {

    /// GET /messages/<id> — the detail shape with a folded explanation and BOTH
    /// rule_matches record shapes: a normal int-rule_id match and the
    /// nil-rule_id sender-override invariant record.
    private static let detailFixture = Data("""
    {
      "account": "acct",
      "body_html": null,
      "body_plain": "hello",
      "category": "unknown",
      "explanation": "Urgency tier: 2\\nCategory: unknown\\nRules matched (2):\\n  • [E19 digest → T4] — subject contains 'e19-digest'\\n  • [Sender override invariant — group 'vip-e19'] — sender_group matches_group 'vip-e19'",
      "id": "acct:e19",
      "ingested_at": "2026-07-16T10:00:00+00:00",
      "preview": null,
      "received_at": "2026-07-16T10:00:00+00:00",
      "rule_matches": [
        {
          "applied_tier": 4,
          "field": "subject",
          "operator": "contains",
          "rule_id": 11,
          "rule_name": "E19 digest → T4",
          "value": "e19-digest"
        },
        {
          "applied_tier": 2,
          "field": "sender_group",
          "operator": "matches_group",
          "overrode_tier": 4,
          "rule_id": null,
          "rule_name": "Sender override invariant — group 'vip-e19'",
          "value": "vip-e19"
        }
      ],
      "sender_email": "aunt@e19.example",
      "sender_name": "Aunt",
      "subject": "e19-digest weekly",
      "thread_id": null,
      "triage_state": "new",
      "urgency_tier": 2
    }
    """.utf8)

    /// GET /messages/<id>/explain — the standalone shape; same rule_matches.
    private static let explainFixture = Data("""
    {
      "category": "unknown",
      "explanation": "Urgency tier: 2\\nCategory: unknown\\nRules matched (2):\\n  • [E19 digest → T4] — subject contains 'e19-digest'\\n  • [Sender override invariant — group 'vip-e19'] — sender_group matches_group 'vip-e19'",
      "message_id": "acct:e19",
      "rule_matches": [
        {
          "applied_tier": 4,
          "field": "subject",
          "operator": "contains",
          "rule_id": 11,
          "rule_name": "E19 digest → T4",
          "value": "e19-digest"
        },
        {
          "applied_tier": 2,
          "field": "sender_group",
          "operator": "matches_group",
          "overrode_tier": 4,
          "rule_id": null,
          "rule_name": "Sender override invariant — group 'vip-e19'",
          "value": "vip-e19"
        }
      ],
      "urgency_tier": 2
    }
    """.utf8)

    // ── The E19 core: both rule_matches-bearing shapes must decode ────────────

    func testMessageDetailDecodesWithSenderOverrideRecord() throws {
        let detail = try JSONDecoder().decode(MessageDetail.self, from: Self.detailFixture)
        XCTAssertEqual(detail.matches.count, 2,
                       "Both audit records — the rule match and the override — must survive decoding.")
        XCTAssertEqual(detail.urgencyTier, 2)
        XCTAssertNotNil(detail.explanation, "P3: the folded explanation must survive the decode.")
    }

    func testExplanationDecodesWithSenderOverrideRecord() throws {
        let explanation = try JSONDecoder().decode(Explanation.self, from: Self.explainFixture)
        XCTAssertEqual(explanation.ruleMatches.count, 2)
        XCTAssertEqual(explanation.urgencyTier, 2)
    }

    // ── The override record's content and identity ────────────────────────────

    func testOverrideRecordCarriesInvariantContext() throws {
        let detail = try JSONDecoder().decode(MessageDetail.self, from: Self.detailFixture)
        let override = try XCTUnwrap(detail.matches.first(where: \.isOverride))
        XCTAssertNil(override.ruleID)
        XCTAssertEqual(override.overrodeTier, 4,
                       "The override must keep the tier it floored FROM (P3 context).")
        XCTAssertTrue(override.ruleName.contains("vip-e19"),
                      "The invariant record's name is self-describing (group included).")
        XCTAssertEqual(override.displayLine,
                       "Sender override invariant — group 'vip-e19' — raised from T4")

        let rule = try XCTUnwrap(detail.matches.first(where: { !$0.isOverride }))
        XCTAssertEqual(rule.ruleID, 11)
        XCTAssertNil(rule.overrodeTier, "overrode_tier is absent on normal rule records.")
        XCTAssertEqual(rule.displayLine, "E19 digest → T4 — subject e19-digest")
    }

    func testRecordIdentitiesAreDistinctWithoutFabricatedRuleIDs() throws {
        let detail = try JSONDecoder().decode(MessageDetail.self, from: Self.detailFixture)
        let ids = detail.matches.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "Identifiable ids must stay unique so ForEach renders every record.")
        XCTAssertFalse(ids.contains("rule-0"),
                       "The nil case must not be faked as a real-looking rule id.")
    }
}
// ── D48 (closes OI4): the Gmail-web deep link ────────────────────────────────

@MainActor
final class GmailLinkTests: XCTestCase {

    private func detail(rfc822: String?) -> MessageDetail {
        MessageDetail(
            id: "acct:1", account: "acct", threadID: nil, senderName: nil,
            senderEmail: "a@example.com", subject: "s",
            receivedAt: "2026-07-17T10:00:00+00:00",
            ingestedAt: "2026-07-17T10:00:00+00:00", preview: nil,
            bodyPlain: "x", bodyHTML: nil, urgencyTier: 1, category: "work",
            triageState: "new", explanation: nil, ruleMatches: nil,
            rfc822MessageID: rfc822,
            classifiedAt: nil, reclassifiedAt: nil, rulesChangedSince: nil)
    }

    func testGmailURLEncodesTheMessageID() throws {
        let url = try XCTUnwrap(detail(rfc822: "<d48-probe@example.com>").gmailWebURL)
        XCTAssertEqual(url.absoluteString,
                       "https://mail.google.com/mail/u/0/#search/rfc822msgid:%3Cd48%2Dprobe%40example%2Ecom%3E")
    }

    func testMissingMessageIDDisablesTheLink() {
        XCTAssertNil(detail(rfc822: nil).gmailWebURL)
        XCTAssertNil(detail(rfc822: "").gmailWebURL,
                     "An empty header value must not build a link either.")
    }
}

/// D48 toolbar actions, driven through the PRODUCTION code path (GmailActions
/// is what the buttons call) — not a re-implementation in the test.
@MainActor
final class GmailActionTests: XCTestCase {

    private func detail(rfc822: String?) -> MessageDetail {
        MessageDetail(
            id: "acct:1", account: "acct", threadID: nil, senderName: nil,
            senderEmail: "a@example.com", subject: "s",
            receivedAt: "2026-07-17T10:00:00+00:00",
            ingestedAt: "2026-07-17T10:00:00+00:00", preview: nil,
            bodyPlain: "x", bodyHTML: nil, urgencyTier: 1, category: "work",
            triageState: "new", explanation: nil, ruleMatches: nil,
            rfc822MessageID: rfc822,
            classifiedAt: nil, reclassifiedAt: nil, rulesChangedSince: nil)
    }

    func testCopyLinkPutsTheGmailURLOnTheGivenPasteboard() {
        // A named private pasteboard so the test NEVER touches the user's
        // general clipboard (they may be mid-copy while the suite runs).
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("thresher.tests.d48"))
        defer { pasteboard.releaseGlobally() }

        let copied = GmailActions.copyLink(detail(rfc822: "<d48-probe@example.com>"),
                                           pasteboard: pasteboard)

        XCTAssertTrue(copied)
        XCTAssertEqual(pasteboard.string(forType: .string),
                       "https://mail.google.com/mail/u/0/#search/rfc822msgid:%3Cd48%2Dprobe%40example%2Ecom%3E")
    }

    func testCopyLinkRefusesWithoutMessageID() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("thresher.tests.d48-none"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertFalse(GmailActions.copyLink(detail(rfc822: nil), pasteboard: pasteboard))
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testOpenHandsTheURLToTheOpener() {
        var opened: URL?
        GmailActions.open(detail(rfc822: "<d48-probe@example.com>"), opener: { opened = $0 })
        XCTAssertEqual(opened?.absoluteString,
                       "https://mail.google.com/mail/u/0/#search/rfc822msgid:%3Cd48%2Dprobe%40example%2Ecom%3E")

        opened = nil
        GmailActions.open(detail(rfc822: nil), opener: { opened = $0 })
        XCTAssertNil(opened, "No Message-ID → the opener must never fire.")
    }
}
