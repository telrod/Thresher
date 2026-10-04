//
//  APIClient.swift
//  Thresher
//
//  Thin client over the local Flask API (http://localhost:8765), built on
//  URLSession + async/await (D35 — no Alamofire, consistent with the project's
//  drop-the-dependency pattern).
//
//  The client only knows how to GET typed JSON and surface a typed error. It
//  does NOT own any UI state — view models call it and publish results.
//

import Foundation

/// Errors the client can surface, mapped to user-presentable text by the UI.
enum APIError: LocalizedError {
    case badURL
    case transport(Error)              // URLSession failed (server down, refused…)
    case http(status: Int, body: String?)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Could not build the request URL."
        case .transport:
            return "Couldn't reach thresher. Is the backend running on :8765?"
        case .http(let status, let body):
            if let body, !body.isEmpty { return "Server error \(status): \(body)" }
            return "Server error \(status)."
        case .decoding:
            return "The server sent data in an unexpected shape."
        }
    }
}

/// Abstraction so the view model can be tested against a fake. The concrete
/// `APIClient` talks to the real backend.
///
/// `Sendable`: the client is handed to a `@MainActor` view model that then calls
/// it from background `Task`s, so it must be safe to cross actor boundaries
/// (strict-concurrency requirement). `APIClient` satisfies this with only
/// `Sendable` immutable state.
protocol MessageAPI: Sendable {
    func listMessages() async throws -> [MessageListRow]
    /// D50: the multi-state list fetch — `states` maps to `?states=a,b`
    /// (nil ⇒ unfiltered). One query so tier-first ordering holds across the
    /// combined set.
    func listMessages(states: [String]?) async throws -> [MessageListRow]
    /// OI21 + filters: one page of the list, WITH the total for this filter set.
    /// The list has always been a window onto the store; this is the call that
    /// makes the window's size knowable, so the UI can page to the genuine end
    /// instead of silently stopping at row 100.
    func listPage(_ query: ListQuery) async throws -> MessagePage
    /// D50: store-wide triage counts (the chips' truth source — the list
    /// paginates, so rendered-row counting would lie).
    func messageCounts() async throws -> TriageCounts
    /// Bulk triage (explicit ids, all-or-nothing server-side). Write-back is
    /// off by default for bulk — see the endpoint's contract.
    @discardableResult
    func triageBulk(ids: [String], state: TriageState) async throws -> BulkTriageResult
    /// D59: bulk triage scoped to a FILTER rather than an id list — the only way
    /// to clear a backlog larger than one page. The scope carries a frozen
    /// `until` so the set cannot grow between the count the user saw and the
    /// execute.
    @discardableResult
    func triageBulk(scope: BulkFilterScope,
                    state: TriageState) async throws -> BulkTriageResult
    func searchMessages(query: String) async throws -> [MessageListRow]
    func preferences() async throws -> Preferences

    // ── Message Detail (§4.1.2) ──────────────────────────────────────────────
    func getMessage(id: String) async throws -> MessageDetail
    /// Returns `nil` when the message is unclassified (the endpoint 404s for that
    /// case — see the explain/explanation asymmetry below). Other failures throw.
    func explain(id: String) async throws -> Explanation?
    /// Full conversation, received_at ASC. List-shape rows (no bodies).
    func thread(id: String) async throws -> [MessageListRow]
    /// Move a message to a new triage state. Returns the server-confirmed state.
    func setTriage(id: String, state: TriageState) async throws -> TriageUpdateResponse

    // ── Reclassify on demand (D52) ───────────────────────────────────────────
    /// D52 part A: re-run the CURRENT engine over one stored message. Explicit user
    /// action only (invariant 4) and silent — the server fires no notifications
    /// (invariant 2) and preserves the triage state (invariant 1).
    func reclassify(id: String) async throws -> ReclassifyResult
    /// D52 part C: re-run the engine over the whole store. Synchronous by
    /// measurement, not assumption (~1,600 messages in well under a second).
    func reclassifyAll() async throws -> ReclassifySummary

    // ── Native notification delivery (§4.3 / D45) ────────────────────────────
    /// Poll the notification feed for rows the app should deliver natively, newer
    /// than `since` (the last cursor the app processed). Returns the rows + the new
    /// cursor to store for the next poll.
    func notifications(since: Int) async throws -> NotificationFeed
    /// Claim native delivery for the next `seconds` (the D45 hand-off heartbeat):
    /// while the claim is live the backend logs alerts but skips its own osascript
    /// banner, so the two paths never double-fire. Refreshed on the poll cadence;
    /// lapses if the app stops calling it.
    func claimDelivery(forSeconds seconds: Int) async throws

    // ── Health (Session 34) ───────────────────────────────────────────────
    /// Per-account ingestion health. Throws like any other call when the
    /// backend is unreachable — the caller treats that as "say nothing about
    /// accounts" rather than as an account fault, since we couldn't ask.
    func accountHealth() async throws -> AccountHealthReport
}

extension MessageAPI {
    /// Default: report nothing.
    ///
    /// This exists so the many test fakes conforming to `MessageAPI` need not
    /// implement a method their subject never calls. It THROWS rather than
    /// returning a synthetic healthy report: a fake that silently claimed
    /// every account was fine could make a health test pass against a stub
    /// that never ran the code under test. Throwing lands in the caller's
    /// `try?`, which means "say nothing" — the same honest path a real
    /// unreachable backend takes.
    func accountHealth() async throws -> AccountHealthReport {
        throw APIError.http(status: 501, body: "accountHealth not implemented by this client")
    }
}

// Defaults for the paging/bulk additions, so the many existing test fakes keep
// conforming without each restating them. `APIClient` overrides both; a fake
// that cares supplies its own. The default page derives its total from the rows
// it returns — i.e. "what you see is all there is", which is the pre-pagination
// behaviour and therefore the safe fallback rather than an invented number.
extension MessageAPI {
    func listPage(_ query: ListQuery) async throws -> MessagePage {
        let rows = try await listMessages(states: query.states)
        return MessagePage(rows: rows, total: rows.count, offset: query.offset)
    }

    @discardableResult
    func triageBulk(ids: [String], state: TriageState) async throws -> BulkTriageResult {
        BulkTriageResult(updated: ids.count, triageState: state.rawValue,
                         wroteBack: 0, writeBackSkipped: true,
                         matching: nil, alreadyInState: nil)
    }

    @discardableResult
    func triageBulk(scope: BulkFilterScope,
                    state: TriageState) async throws -> BulkTriageResult {
        BulkTriageResult(updated: scope.previewedCount, triageState: state.rawValue,
                         wroteBack: 0, writeBackSkipped: true,
                         matching: scope.previewedCount, alreadyInState: 0)
    }
}

/// The Settings surface (§4.1.3): rules + sender groups, the two preference
/// surfaces, and account connect/list/verify/disconnect. Separate protocol from
/// `MessageAPI` so a Settings view model can depend only on what it uses (and be
/// faked independently). `APIClient` conforms to both.
///
/// `Sendable`: same contract as `MessageAPI` — a @MainActor view model calls
/// these from background `Task`s.
protocol SettingsAPI: Sendable {
    // ── Rules ────────────────────────────────────────────────────────────────
    /// The editor MUST pass `includeDisabled: true` (trap §1.1) or toggled-off
    /// rules vanish and can't be re-enabled. Returns rules + sender groups.
    func getRules(includeDisabled: Bool) async throws -> RulesResponse
    func createRule(_ body: RuleWrite) async throws -> Rule
    func updateRule(id: Int, patch: RuleWrite) async throws -> Rule
    func deleteRule(id: Int) async throws
    /// Batch reorder (D44). `orderedIds` is the COMPLETE new order of ALL rule ids
    /// (enabled + disabled); position becomes priority, server renumbers dense
    /// 1..N in one transaction. Returns the full reordered set (same element shape
    /// as `getRules`). Throws `APIError.http(409, …)` on a stale set (membership
    /// drifted since fetch) and `APIError.http(400, …)` on a malformed body — both
    /// bodies name the mismatched ids; the caller refetches and re-presents on 409.
    func reorderRules(orderedIds: [Int]) async throws -> [Rule]
    /// D52 part C: re-run the engine over the whole store. Lives on SettingsAPI too
    /// because the bulk control sits in the Classification Rules pane — the moment
    /// the user has just changed the rules is when they want to apply them.
    func reclassifyAllMessages() async throws -> ReclassifySummary

    // ── Build provenance ─────────────────────────────────────────────────────
    /// `GET /version`. Throwing (rather than returning nil) so the caller can show
    /// "Backend unreachable" — which is itself provenance-relevant: it is how a dead
    /// or not-restarted backend surfaces.
    func backendVersion() async throws -> BackendVersion

    // ── Sender groups ──────────────────────────────────────────────────────
    func createSenderGroup(_ body: SenderGroupWrite) async throws -> SenderGroup
    func updateSenderGroup(id: Int, patch: SenderGroupWrite) async throws -> SenderGroup
    func deleteSenderGroup(id: Int) async throws

    // ── Preferences (two surfaces, trap §1.4) ────────────────────────────────
    /// Generic flat string map (operating mode / digest / ceiling / poll).
    func getPreferences() async throws -> Preferences
    /// Generic per-key upsert (coerces to string server-side). One key at a time.
    func setPreference(key: String, value: String) async throws
    /// Typed notification surface (quiet hours + audio).
    func getNotificationPrefs() async throws -> NotificationPrefs
    func setNotificationPrefs(_ patch: NotificationPrefsWrite) async throws -> NotificationPrefs

    // ── Accounts ──────────────────────────────────────────────────────────
    func listAccounts() async throws -> [String]
    /// Store the App Password (POST /accounts). The secret lives only in `body`
    /// for the duration of this call — never logged, never retained.
    /// `retrievalWindow` (D61) is the initial-backfill bound, resolved to an
    /// absolute cutoff server-side; nil means "no cutoff", i.e. everything.
    func storeAccount(email: String, appPassword: String,
                      retrievalWindow: RetrievalWindow?) async throws
    /// How many messages each retrieval window would bring in (POST
    /// /accounts/preview). Read-only and stores nothing — asked BEFORE the
    /// credential exists, so the password travels in the body exactly as it does
    /// for storeAccount and is dropped just as fast.
    func previewRetrieval(email: String, appPassword: String) async throws -> RetrievalPreview
    /// Verify the STORED credential (trap §1.8 — takes no password). Returns the
    /// 4-value reason, safe to switch on.
    func verifyAccount(_ email: String) async throws -> VerifyResult
    /// Disconnect: removes the Keychain credential only (P1 — messages stay).
    func disconnectAccount(_ email: String) async throws

    // ── Health (OI31) ─────────────────────────────────────────────────────
    /// Per-account ingestion health, so the accounts pane can show whether a
    /// mailbox is actually being polled. Same endpoint the message-list banner
    /// uses — one source, so two surfaces cannot disagree.
    func accountHealth() async throws -> AccountHealthReport
}

extension SettingsAPI {
    /// Default: report nothing, by THROWING rather than returning a synthetic
    /// healthy report. Same reasoning as the MessageAPI default — a fake that
    /// silently claimed every account was fine could make a health test pass
    /// against a stub that never ran the code under test. Throwing lands in the
    /// caller's `try?`, which means "say nothing": the honest path a real
    /// unreachable backend takes.
    func accountHealth() async throws -> AccountHealthReport {
        throw APIError.http(status: 501, body: "accountHealth not implemented by this client")
    }
}

/// `GET /rules` wrapper: `{ rules: [...], sender_groups: [...] }`.
struct RulesResponse: Codable, Sendable {
    let rules: [Rule]
    let senderGroups: [SenderGroup]

    enum CodingKeys: String, CodingKey {
        case rules
        case senderGroups = "sender_groups"
    }
}

/// Response from POST /messages/<id>/triage — `{message_id, triage_state}`.
struct TriageUpdateResponse: Codable, Hashable {
    let messageID: String
    let triageState: String

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case triageState = "triage_state"
    }
}

/// `Sendable` by construction: a `final` class whose only stored state is an
/// immutable `URL` and a `URLSession` (both `Sendable`). The `JSONDecoder` is
/// created per-call rather than stored — `JSONDecoder` is not `Sendable`, and a
/// stored one would force `@unchecked`; a fresh decoder per request is cheap and
/// keeps the type honestly `Sendable`.
final class APIClient: MessageAPI, SettingsAPI {
    private let baseURL: URL
    private let session: URLSession

    /// The backend the app talks to.
    ///
    /// Normally `http://localhost:8765`. `THRESHER_API_BASE_URL` in the
    /// process environment overrides it, which is what lets a UI test point the
    /// app at a seeded fixture server instead of the live store — XCUITest
    /// drives the app as a SEPARATE process, so launch environment is the only
    /// channel available for this. Nothing in the shipping app sets it; an
    /// unset or unparseable value falls back to the default, so a typo
    /// degrades to normal behaviour rather than a broken client.
    static let defaultBaseURL: URL = {
        let fallback = URL(string: "http://localhost:8765")!
        guard let raw = ProcessInfo.processInfo.environment["THRESHER_API_BASE_URL"],
              let url = URL(string: raw), url.scheme != nil else { return fallback }
        return url
    }()

    init(baseURL: URL = APIClient.defaultBaseURL,
         session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // ── Message List (§4.1.1) ──────────────────────────────────────────────

    func listMessages() async throws -> [MessageListRow] {
        try await listMessages(states: nil)
    }

    func listMessages(states: [String]?) async throws -> [MessageListRow] {
        // GET /messages[?states=a,b] — array of list rows (server defaults:
        // limit 100, tier-grouped ordering). D50: `states` is the multi-value
        // triage filter; the server 400s unknown names (never a silent empty
        // view).
        guard let states, !states.isEmpty else {
            return try await get([MessageListRow].self, path: "/messages")
        }
        var components = URLComponents()
        components.path = "/messages"
        components.queryItems = [URLQueryItem(name: "states",
                                              value: states.joined(separator: ","))]
        guard let path = components.string else { throw APIError.badURL }
        return try await get([MessageListRow].self, path: path)
    }

    func listPage(_ query: ListQuery) async throws -> MessagePage {
        // GET /messages with every active filter ANDed together, plus
        // limit/offset. The total for THIS filter set comes back in
        // X-Total-Count — that header is the whole point (OI21): without it the
        // client cannot tell "that's all of it" from "that's the first page".
        var components = URLComponents()
        components.path = "/messages"
        var items: [URLQueryItem] = []
        if let states = query.states, !states.isEmpty {
            items.append(.init(name: "states", value: states.joined(separator: ",")))
        }
        if let tier = query.tier {
            items.append(.init(name: "tier", value: String(tier)))
        }
        if let since = query.since { items.append(.init(name: "since", value: since)) }
        if let until = query.until { items.append(.init(name: "until", value: until)) }
        items.append(.init(name: "limit", value: String(query.limit)))
        items.append(.init(name: "offset", value: String(query.offset)))
        components.queryItems = items
        guard let path = components.string else { throw APIError.badURL }
        let (rows, headers) = try await getWithHeaders([MessageListRow].self, path: path)
        // Absent header ⇒ fall back to "what we got is all there is". An older
        // backend is the only way that happens, and under-reporting the total
        // degrades to today's behaviour rather than inventing a number.
        let total = (headers["X-Total-Count"] as? String).flatMap(Int.init)
            ?? (query.offset + rows.count)
        return MessagePage(rows: rows, total: total, offset: query.offset)
    }

    func messageCounts() async throws -> TriageCounts {
        // GET /messages/counts — store-wide per-state totals (D50).
        try await get(TriageCounts.self, path: "/messages/counts")
    }

    @discardableResult
    func triageBulk(ids: [String], state: TriageState) async throws -> BulkTriageResult {
        // POST /messages/triage-bulk — explicit ids, applied all-or-nothing.
        // A 409 means the id set went stale and NOTHING changed; the caller
        // refetches rather than guessing which half landed.
        struct Body: Encodable {
            let message_ids: [String]
            let state: String
        }
        return try await send(BulkTriageResult.self, method: "POST",
                              path: "/messages/triage-bulk",
                              body: Body(message_ids: ids, state: state.rawValue))
    }

    @discardableResult
    func triageBulk(scope: BulkFilterScope,
                    state: TriageState) async throws -> BulkTriageResult {
        // POST /messages/triage-bulk in FILTER mode (D59): send the filter, not
        // an id list. The id mode is capped at the loaded page, so clearing a
        // backlog meant Load-more → select 100 → Done, dozens of times over.
        //
        // `until` is REQUIRED and is the scope's frozen capture instant — the
        // server refuses to default it, because a server-side `now` would be
        // evaluated at execute time and let mail that arrived after the user
        // saw the count be triaged unseen.
        struct Filter: Encodable {
            let states: [String]?
            let tier: Int?
            let since: String?
            let until: String
        }
        struct Body: Encodable {
            let state: String
            let filter: Filter
        }
        let body = Body(state: state.rawValue,
                        filter: Filter(states: scope.states, tier: scope.tier,
                                       since: scope.since, until: scope.until))
        return try await send(BulkTriageResult.self, method: "POST",
                              path: "/messages/triage-bulk", body: body)
    }

    func searchMessages(query: String) async throws -> [MessageListRow] {
        // GET /messages/search?q=… — same row shape as the list (E10: shared
        // serializer). Empty/missing q is a 400 server-side; the caller guards
        // against firing on empty input, but we also short-circuit here.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var components = URLComponents()
        components.path = "/messages/search"
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        guard let path = components.string else { throw APIError.badURL }
        return try await get([MessageListRow].self, path: path)
    }

    func preferences() async throws -> Preferences {
        // GET /preferences — flat {key:value} string map (D34 reads
        // poll_interval_minutes from it).
        try await get(Preferences.self, path: "/preferences")
    }

    // ── Message Detail (§4.1.2) ──────────────────────────────────────────────

    func getMessage(id: String) async throws -> MessageDetail {
        // GET /messages/<id> — single object: body + folded explanation +
        // conditional rule_matches; preview is null here (E10 divergence).
        try await get(MessageDetail.self, path: "/messages/\(Self.escape(id))")
    }

    func explain(id: String) async throws -> Explanation? {
        // GET /messages/<id>/explain — 404s for UNCLASSIFIED mail (asymmetry: the
        // detail fetch returns 200 + explanation:null for the same message). We
        // map that one 404 to `nil` rather than an error so the screen renders
        // the unclassified state cleanly (P1) and never leaks an error (P2). Any
        // other HTTP/transport failure still throws.
        do {
            return try await get(Explanation.self, path: "/messages/\(Self.escape(id))/explain")
        } catch APIError.http(let status, _) where status == 404 {
            return nil
        }
    }

    func thread(id: String) async throws -> [MessageListRow] {
        // GET /threads/<id> — array of list-shape rows, received_at ASC. Reuses
        // MessageListRow (same serializer as the list — no bodies here).
        try await get([MessageListRow].self, path: "/threads/\(Self.escape(id))")
    }

    func setTriage(id: String, state: TriageState) async throws -> TriageUpdateResponse {
        // POST /messages/<id>/triage {"state": …} → {message_id, triage_state}.
        // Note: 404 if the message has no classification row (unclassified mail
        // can't be triaged) — surfaced to the caller as APIError.http(404).
        try await post(TriageUpdateResponse.self,
                       path: "/messages/\(Self.escape(id))/triage",
                       body: ["state": state.rawValue])
    }

    // ── Reclassify on demand (D52) ───────────────────────────────────────────

    func reclassify(id: String) async throws -> ReclassifyResult {
        // POST /messages/<id>/reclassify → the fresh classification, so the caller
        // can patch in place without a refetch (the E20 seam's lesson).
        try await post(ReclassifyResult.self,
                       path: "/messages/\(Self.escape(id))/reclassify",
                       body: [String: String]())
    }

    func reclassifyAll() async throws -> ReclassifySummary {
        // POST /messages/reclassify-all → {counted, changed, unchanged, errors}.
        try await post(ReclassifySummary.self,
                       path: "/messages/reclassify-all", body: [String: String]())
    }

    /// SettingsAPI's spelling of the same call (one implementation, two protocols).
    func reclassifyAllMessages() async throws -> ReclassifySummary {
        try await reclassifyAll()
    }

    // ── Build provenance ─────────────────────────────────────────────────────

    func backendVersion() async throws -> BackendVersion {
        try await get(BackendVersion.self, path: "/version")
    }

    // ── Native notification delivery (§4.3 / D45) ────────────────────────────

    func notifications(since: Int) async throws -> NotificationFeed {
        // GET /notifications?since=<cursor> → {notifications:[…], cursor}. Only
        // app-owned rows come back; cursor advances past all scanned rows.
        var components = URLComponents()
        components.path = "/notifications"
        components.queryItems = [URLQueryItem(name: "since", value: String(since))]
        guard let path = components.string else { throw APIError.badURL }
        return try await get(NotificationFeed.self, path: path)
    }

    func claimDelivery(forSeconds seconds: Int) async throws {
        // PUT /preferences/notification_delivery_heartbeat = <now, ISO>.
        //
        // We send WHEN WE CHECKED IN, not how long to trust us. The backend owns
        // the freshness window (CLAIM_STALE_SECONDS) — the same direction as
        // D65's poll heartbeat, where silence reads as broken rather than the
        // reporter asserting its own health.
        //
        // The old shape was an app-computed "valid until" = now + 2*pollInterval
        // + 30s. That carried when trust expired but not when it was earned, so a
        // quit app's claim outlived it: on 2026-09-06 a Tier 1 was deferred to an
        // app gone 9m35s, and no banner fired by any path. `seconds` is now
        // unused and kept only so the call site and its fakes stay source-stable.
        _ = seconds
        try await sendNoContent(method: "PUT",
                                path: "/preferences/notification_delivery_heartbeat",
                                body: ["value": Self.iso8601.string(from: Date())])
    }

    /// Fixed ISO-8601 formatter (UTC, with offset) for the delivery-owner claim.
    /// `nonisolated` + a computed factory keeps `APIClient` honestly `Sendable`
    /// (a stored `DateFormatter`/`ISO8601DateFormatter` is not `Sendable`, D42).
    private static var iso8601: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }

    // ── Settings: Rules (§4.1.3) ──────────────────────────────────────────────

    func getRules(includeDisabled: Bool) async throws -> RulesResponse {
        // GET /rules — the editor passes include_disabled=true (trap §1.1) so a
        // toggled-off rule stays visible and re-enableable.
        var components = URLComponents()
        components.path = "/rules"
        if includeDisabled {
            components.queryItems = [URLQueryItem(name: "include_disabled", value: "true")]
        }
        guard let path = components.string else { throw APIError.badURL }
        return try await get(RulesResponse.self, path: path)
    }

    func createRule(_ body: RuleWrite) async throws -> Rule {
        // POST /rules → 201 + created rule. `enabled` is a bool in the body
        // (trap §1.2); 400 if it would have no effect (both-null guard, §1.3).
        try await send(Rule.self, method: "POST", path: "/rules", body: body)
    }

    func updateRule(id: Int, patch: RuleWrite) async throws -> Rule {
        // PUT /rules/<int:id> — patch semantics; only encoded keys are written
        // (trap §1.3). Integer path only (a non-int segment 404s the route, §1.6).
        try await send(Rule.self, method: "PUT", path: "/rules/\(id)", body: patch)
    }

    func deleteRule(id: Int) async throws {
        // DELETE /rules/<int:id> — config hard-delete (P1's never-delete is about
        // messages, not rules). Response body {deleted:id} is ignored.
        try await sendNoContent(method: "DELETE", path: "/rules/\(id)")
    }

    func reorderRules(orderedIds: [Int]) async throws -> [Rule] {
        // PUT /rules/reorder {ordered_ids:[…]} (D44). Position IS priority; the
        // server renumbers dense 1..N in one transaction and returns the full
        // reordered set as {rules:[…]} — so the caller re-renders from the
        // response without a second fetch. The <int:rule_id> route can't capture
        // "reorder", so this reaches reorder_rules, not update_rule (map §route
        // isolation). 400/409 surface as APIError.http with the id-naming body.
        try await send(RulesReorderResponse.self, method: "PUT",
                       path: "/rules/reorder",
                       body: ReorderBody(orderedIds: orderedIds)).rules
    }

    // ── Settings: Sender groups (§4.1.3) ──────────────────────────────────────

    func createSenderGroup(_ body: SenderGroupWrite) async throws -> SenderGroup {
        try await send(SenderGroup.self, method: "POST", path: "/sender-groups", body: body)
    }

    func updateSenderGroup(id: Int, patch: SenderGroupWrite) async throws -> SenderGroup {
        try await send(SenderGroup.self, method: "PUT", path: "/sender-groups/\(id)", body: patch)
    }

    func deleteSenderGroup(id: Int) async throws {
        try await sendNoContent(method: "DELETE", path: "/sender-groups/\(id)")
    }

    // ── Settings: Preferences — two surfaces (trap §1.4) ──────────────────────

    func getPreferences() async throws -> Preferences {
        // The generic flat string map (operating mode / digest / ceiling / poll).
        // Same endpoint MessageAPI.preferences() reads; kept here for the
        // SettingsAPI surface so a Settings VM needn't depend on MessageAPI.
        try await get(Preferences.self, path: "/preferences")
    }

    func setPreference(key: String, value: String) async throws {
        // PUT /preferences/<key> {"value": …} — generic upsert, coerced to string
        // server-side. One key at a time. Response {key,value} ignored.
        try await sendNoContent(method: "PUT",
                                path: "/preferences/\(Self.escape(key))",
                                body: ["value": value])
    }

    func getNotificationPrefs() async throws -> NotificationPrefs {
        // GET /preferences/notifications — TYPED surface (coerced bool/HH:MM).
        try await get(NotificationPrefs.self, path: "/preferences/notifications")
    }

    func setNotificationPrefs(_ patch: NotificationPrefsWrite) async throws -> NotificationPrefs {
        // PUT /preferences/notifications — strict (trap §1.5): "" unsets a
        // quiet-hour, audio_alerts must be a real bool, unknown key → 400.
        // Returns the full merged typed state.
        try await send(NotificationPrefs.self, method: "PUT",
                       path: "/preferences/notifications", body: patch)
    }

    // ── Settings: Accounts (§4.1.3) ──────────────────────────────────────────

    func listAccounts() async throws -> [String] {
        // GET /accounts → {accounts:[…]}. 503 if `security` is unavailable
        // (non-macOS host) — surfaced as APIError.http(503) for distinct copy.
        try await get(AccountsResponse.self, path: "/accounts").accounts
    }

    func storeAccount(email: String, appPassword: String,
                      retrievalWindow: RetrievalWindow?) async throws {
        // POST /accounts → 201. The App Password lives ONLY in this body and is
        // dropped when the call returns; never logged, never retained, never
        // echoed back (the response is {account, stored:true}). 502 → Keychain
        // write failed (surfaced as APIError.http(502)).
        //
        // `retrieval_window` is omitted entirely when nil rather than sent as
        // null: an absent key means "no cutoff" server-side, which is the
        // pre-D61 behaviour and the safe reading for any caller that doesn't
        // care. The server 400s an unrecognised value.
        try await sendNoContent(method: "POST", path: "/accounts",
                                body: StoreAccountBody(account: email,
                                                       appPassword: appPassword,
                                                       retrievalWindow: retrievalWindow?.rawValue))
    }

    func previewRetrieval(email: String, appPassword: String) async throws -> RetrievalPreview {
        // POST /accounts/preview → {account, counts}. Stores nothing (P5): no
        // Keychain write, no retrieval_cutoff row. 502 → the mailbox couldn't be
        // read; the caller must NOT render that as a count of zero.
        try await send(RetrievalPreview.self, method: "POST", path: "/accounts/preview",
                       body: StoreAccountBody(account: email, appPassword: appPassword,
                                              retrievalWindow: nil))
    }

    func verifyAccount(_ email: String) async throws -> VerifyResult {
        // POST /accounts/verify {account} → {ok, reason}. Tests the STORED
        // credential (trap §1.8 — no password in the body).
        try await send(VerifyResult.self, method: "POST", path: "/accounts/verify",
                       body: VerifyAccountBody(account: email))
    }

    func disconnectAccount(_ email: String) async throws {
        // DELETE /accounts/<path:account> → {disconnected}. Keychain only (P1 —
        // messages stay searchable). 404 → "not connected"; 502 → Keychain error.
        try await sendNoContent(method: "DELETE", path: "/accounts/\(Self.escape(email))")
    }

    func accountHealth() async throws -> AccountHealthReport {
        // GET /health/accounts — the poller's own per-account heartbeat
        // (Session 34). 503 when the Keychain is unavailable, which surfaces as
        // APIError.http and is handled by the caller as "say nothing".
        try await get(AccountHealthReport.self, path: "/health/accounts")
    }

    /// Percent-encode a path segment. Message ids are the synthetic
    /// `{account}:{uid}` PK — the colon and any `@`/dots must be escaped so the
    /// id lands in one path component.
    private static func escape(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? segment
    }

    // ── Core GET / POST ───────────────────────────────────────────────────────

    private func get<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8)
            throw APIError.http(status: http.statusCode, body: body)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// GET that also hands back the response headers. Needed for OI21's
    /// X-Total-Count: the body is a bare array (unchanged, so every existing
    /// caller keeps working) and the pagination total rides alongside it.
    private func getWithHeaders<T: Decodable>(
        _ type: T.Type, path: String
    ) async throws -> (T, [AnyHashable: Any]) {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        let http = response as? HTTPURLResponse
        if let http, !(200...299).contains(http.statusCode) {
            throw APIError.http(status: http.statusCode,
                                body: String(data: data, encoding: .utf8))
        }

        do {
            return (try JSONDecoder().decode(T.self, from: data),
                    http?.allHeaderFields ?? [:])
        } catch {
            throw APIError.decoding(error)
        }
    }

    private func post<T: Decodable>(_ type: T.Type, path: String,
                                    body: [String: String]) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8)
            throw APIError.http(status: http.statusCode, body: body)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    // ── Generic request with an Encodable body (POST/PUT/DELETE) ────────────────
    //
    // The Settings writes need arbitrary Encodable bodies (RuleWrite,
    // SenderGroupWrite, NotificationPrefsWrite, StoreAccountBody, …) and verbs
    // beyond POST, which the [String:String]-only `post` above can't express.
    // These two helpers cover every Settings write: `send` decodes a typed
    // response; `sendNoContent` discards the body (deletes, stores, per-key
    // prefs) but still maps non-2xx to APIError so the caller sees 400/404/502.

    /// Perform a request with an optional Encodable body and decode the response.
    private func send<Response: Decodable, Body: Encodable>(
        _ type: Response.Type, method: String, path: String, body: Body
    ) async throws -> Response {
        let data = try await raw(method: method, path: path, body: body)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// Perform a write whose response body we don't need. Still surfaces non-2xx
    /// as APIError (so 400/404/502 reach the caller's mapping).
    private func sendNoContent<Body: Encodable>(
        method: String, path: String, body: Body? = Optional<Empty>.none
    ) async throws {
        _ = try await raw(method: method, path: path, body: body)
    }

    /// An empty Encodable, so `sendNoContent` can default to no body (DELETE).
    private struct Empty: Encodable {}

    /// Core: build the request, encode an optional body, run it, map non-2xx to
    /// APIError, and return the raw response bytes.
    private func raw<Body: Encodable>(
        method: String, path: String, body: Body?
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONEncoder().encode(body)
            } catch {
                // An encode failure is a programming error in a write DTO, not a
                // transport/decoding one — surface it distinctly.
                throw APIError.decoding(error)
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8)
            throw APIError.http(status: http.statusCode, body: bodyText)
        }
        return data
    }
}