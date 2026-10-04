//
//  UITestSupport.swift
//  ThresherUITests
//
//  Shared scaffolding for the XCUITest target (gate-defects workorder Part 0).
//
//  WHY A FIXTURE SERVER, NOT THE LIVE BACKEND
//  ------------------------------------------
//  Part 1.4 requires these tests run against a seeded fixture, not the live
//  ~4,900-message store. A UI test that asserts against real mail is a test
//  whose result changes every time mail arrives — it would have passed on
//  2026-08-01 and failed on 2026-08-02 for reasons having nothing to do with
//  the code. So each test stands up a tiny HTTP server on a loopback port,
//  seeds exactly the rows the assertion needs, and points the app at it via
//  `THRESHER_API_BASE_URL` (the seam added in APIClient).
//
//  The server speaks only the handful of endpoints the Message List and
//  Settings screens actually call on launch. Anything else 404s loudly rather
//  than returning a plausible empty body — a fixture that silently answers
//  "[]" to an endpoint you forgot to implement produces a green test that
//  proves nothing.
//

import Foundation
import Network
import XCTest

// ── Fixture model ───────────────────────────────────────────────────────────

/// One message row, in the shape the list serializer emits.
struct FixtureMessage {
    var id: String
    var account = "test@example.com"
    var senderName = "Sender"
    var senderEmail = "sender@example.com"
    var subject: String
    var tier: Int
    var state: String = "new"
    /// Age in days; converted to an ISO-8601 `received_at` at serialization.
    var daysAgo: Double

    var receivedAt: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    var json: [String: Any] {
        [
            "id": id, "account": account, "thread_id": NSNull(),
            "sender_name": senderName, "sender_email": senderEmail,
            "subject": subject, "received_at": receivedAt,
            "ingested_at": receivedAt, "preview": "preview text",
            "urgency_tier": tier, "category": "work", "triage_state": state,
        ]
    }
}

/// A sender group, in the D53 `patterns: [...]` shape.
struct FixtureGroup {
    var id: Int
    var name: String
    var floorTier: Int = 2
    var patterns: [String] = ["someone@example.com"]

    /// Mirrors the real serializer: `group_name` / `urgency_floor`, plus the
    /// D53 `patterns` array and the retained legacy `email_pattern`.
    var json: [String: Any] {
        ["id": id, "group_name": name, "urgency_floor": floorTier,
         "patterns": patterns, "email_pattern": patterns.first ?? "",
         "notes": NSNull()]
    }
}

/// A classification rule.
struct FixtureRule {
    var id: Int
    var name: String
    var field: String
    var op: String
    var value: String
    var tier: Int = 2
    var priority: Int
    var enabled = true
    var senderGroupID: Int?

    /// Must mirror the REAL serializer, key for key. Getting this wrong does
    /// not fail loudly — the client reports "The server sent data in an
    /// unexpected shape" and the section renders "No rules defined yet.",
    /// which reads like a missing feature rather than a bad fixture. (It cost
    /// a debug cycle here: `name` instead of `rule_name`, a bare array instead
    /// of the {"rules": […]} wrapper, and a Bool where the API sends 0/1.)
    var json: [String: Any] {
        ["id": id, "rule_name": name, "field": field, "operator": op,
         "value": value, "set_tier": tier, "set_category": "work",
         "priority": priority, "enabled": enabled ? 1 : 0,
         "notes": NSNull(), "updated_at": NSNull(),
         "sender_group_id": senderGroupID as Any]
    }
}

// ── Fixture server ──────────────────────────────────────────────────────────

/// A minimal HTTP/1.1 server for UI tests, on a system-assigned loopback port.
///
/// Deliberately hand-rolled over `Network.framework` rather than pulling in a
/// dependency: the project's standing pattern is to drop dependencies it can do
/// without (Redis → queue.Queue, Alamofire → URLSession), and what's needed
/// here is a few hundred lines of request/response over loopback.
final class FixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fixture.server")
    private let lock = NSLock()

    private var _messages: [FixtureMessage]
    private var _groups: [FixtureGroup]
    private var _rules: [FixtureRule]

    /// Every path the app requested, in order — lets a test assert what was
    /// ASKED for, not only what was rendered.
    private var _requestLog: [String] = []

    var requestLog: [String] { lock.withLock { _requestLog } }
    var messages: [FixtureMessage] { lock.withLock { _messages } }
    var groups: [FixtureGroup] { lock.withLock { _groups } }
    var rules: [FixtureRule] { lock.withLock { _rules } }

    /// Requests whose path matches this prefix are delayed by `slowDelay`.
    /// Used to force out-of-order completion in the filter-race test.
    var slowPathPredicate: (@Sendable (String) -> Bool)?
    var slowDelay: TimeInterval = 0.6

    private(set) var port: UInt16 = 0

    init(messages: [FixtureMessage] = [], groups: [FixtureGroup] = [],
         rules: [FixtureRule] = []) throws {
        _messages = messages
        _groups = groups
        _rules = rules

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)

        let started = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener.port?.rawValue ?? 0
                started.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        guard started.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "FixtureServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    func stop() { listener.cancel() }

    /// Mutate the seeded data mid-test (e.g. rename a group), under the lock.
    func mutate(_ body: (inout [FixtureMessage], inout [FixtureGroup], inout [FixtureRule]) -> Void) {
        lock.withLock { body(&_messages, &_groups, &_rules) }
    }

    // ── Connection handling ─────────────────────────────────────────────────

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil { conn.cancel(); return }

            // Headers complete?
            guard let headerEnd = Self.range(of: "\r\n\r\n", in: buffer) else {
                if isComplete { conn.cancel() } else { self.receive(conn, buffer: buffer) }
                return
            }
            let headerData = buffer[..<headerEnd.lowerBound]
            let header = String(decoding: headerData, as: UTF8.self)
            let contentLength = Self.contentLength(in: header)
            let bodyStart = headerEnd.upperBound
            let available = buffer.count - bodyStart

            guard available >= contentLength else {
                if isComplete { conn.cancel() } else { self.receive(conn, buffer: buffer) }
                return
            }
            let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
            self.handle(header: header, body: body, on: conn)
        }
    }

    private static func range(of needle: String, in data: Data) -> Range<Int>? {
        let pattern = Array(needle.utf8)
        let bytes = [UInt8](data)
        guard bytes.count >= pattern.count else { return nil }
        for i in 0...(bytes.count - pattern.count) where Array(bytes[i..<(i + pattern.count)]) == pattern {
            return i..<(i + pattern.count)
        }
        return nil
    }

    private static func contentLength(in header: String) -> Int {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    private func handle(header: String, body: Data, on conn: NWConnection) {
        guard let requestLine = header.split(separator: "\r\n").first else {
            conn.cancel(); return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = String(parts[0])
        let target = String(parts[1])

        lock.withLock { _requestLog.append("\(method) \(target)") }

        if let predicate = slowPathPredicate, predicate(target) {
            Thread.sleep(forTimeInterval: slowDelay)
        }

        let (status, payload, extraHeaders) = route(method: method, target: target, body: body)
        respond(conn, status: status, json: payload, extraHeaders: extraHeaders)
    }

    // ── Routing ─────────────────────────────────────────────────────────────

    private func route(method: String, target: String, body: Data)
    -> (Int, Any, [String: String]) {
        let comps = URLComponents(string: "http://x\(target)")
        let path = comps?.path ?? target
        let q = comps?.queryItems ?? []
        func param(_ name: String) -> String? {
            q.first { $0.name == name }?.value
        }

        switch (method, path) {
        case ("GET", "/preferences"):
            return (200, ["poll_interval_minutes": "5", "operating_mode": "focus"], [:])

        case ("GET", "/messages/counts"):
            let all = messages
            let counts: [String: Any] = [
                "new": all.filter { $0.state == "new" }.count,
                "acknowledged": all.filter { $0.state == "acknowledged" }.count,
                "needs_action": all.filter { $0.state == "needs_action" }.count,
                "done": all.filter { $0.state == "done" }.count,
                "unclassified": 0,
                "urgent_new": all.filter { $0.state == "new" && $0.tier <= 2 }.count,
            ]
            return (200, counts, [:])

        case ("GET", "/messages/search"):
            let needle = param("q") ?? ""
            let hits = messages.filter { $0.subject.localizedCaseInsensitiveContains(needle) }
            return (200, hits.map(\.json), [:])

        case ("GET", "/messages"):
            return listMessages(param: param)


        case ("GET", "/rules"):
            // ONE payload carries both: {rules: […], sender_groups: […]}.
            // The Settings screen reads its group list from here, not from a
            // separate GET /sender-groups (that path is POST/PUT/DELETE only).
            return (200, ["rules": rules.map(\.json),
                          "sender_groups": groups.map(\.json)], [:])

        case ("GET", "/accounts"):
            // Shape matters: the client decodes AccountsResponse, i.e.
            // {"accounts": ["…"]} — a list of STRINGS, not objects. Getting
            // this wrong routes the app into Onboarding, which is exactly how
            // the first run of these tests failed (the tree showed "Connect
            // your Gmail" instead of the list).
            return (200, ["accounts": ["test@example.com"]], [:])

        case ("GET", "/notifications"):
            return (200, ["notifications": [], "cursor": 0], [:])

        case ("GET", "/version"):
            return (200, ["sha": "uitest", "built_at": "uitest"], [:])

        case ("POST", "/messages/triage-bulk"):
            return bulkTriage(body)

        default:
            // Loud, not plausible: an unimplemented endpoint must fail the test
            // rather than quietly returning an empty collection.
            return (404, ["error": "fixture has no route for \(method) \(path)"], [:])
        }
    }

    private func listMessages(param: (String) -> String?) -> (Int, Any, [String: String]) {
        var hits = messages

        if let states = param("states") {
            let wanted = Set(states.split(separator: ",").map(String.init))
            hits = hits.filter { wanted.contains($0.state) }
        }
        if let tier = param("tier").flatMap(Int.init) {
            hits = hits.filter { $0.tier == tier }
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let since = param("since").flatMap({ f.date(from: $0) }) {
            hits = hits.filter { f.date(from: $0.receivedAt).map { $0 >= since } ?? false }
        }
        if let until = param("until").flatMap({ f.date(from: $0) }) {
            hits = hits.filter { f.date(from: $0.receivedAt).map { $0 < until } ?? false }
        }

        // D57 default ordering: recency band → tier → received_at DESC, with
        // Tier 1 exempt at any age (band 0). The fixture mirrors the server so
        // an ordering assertion in a UI test means something.
        hits.sort { a, b in
            let ba = Self.band(tier: a.tier, daysAgo: a.daysAgo)
            let bb = Self.band(tier: b.tier, daysAgo: b.daysAgo)
            if ba != bb { return ba < bb }
            if a.tier != b.tier { return a.tier < b.tier }
            return a.daysAgo < b.daysAgo
        }

        let total = hits.count
        let limit = param("limit").flatMap(Int.init) ?? 100
        let offset = param("offset").flatMap(Int.init) ?? 0
        let start = min(offset, total)
        let end = min(start + limit, total)
        let page = Array(hits[start..<end])

        return (200, page.map(\.json),
                ["X-Total-Count": String(total), "X-Offset": String(offset)])
    }

    static func band(tier: Int, daysAgo: Double) -> Int {
        if tier == 1 { return 0 }
        if daysAgo <= 14 { return 1 }
        if daysAgo <= 90 { return 2 }
        return 3
    }

    private func bulkTriage(_ body: Data) -> (Int, Any, [String: String]) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let ids = obj["message_ids"] as? [String],
              let state = obj["state"] as? String else {
            return (400, ["error": "bad bulk payload"], [:])
        }
        lock.withLock {
            for i in _messages.indices where ids.contains(_messages[i].id) {
                _messages[i].state = state
            }
        }
        return (200, ["updated": ids.count, "triage_state": state,
                      "wrote_back": 0, "write_back_skipped": true], [:])
    }

    // ── Response ────────────────────────────────────────────────────────────

    private func respond(_ conn: NWConnection, status: Int, json: Any,
                         extraHeaders: [String: String]) {
        let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "ERR")\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        head += "Connection: close\r\n\r\n"

        var out = Data(head.utf8)
        out.append(payload)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

// ── Accessibility identifiers, mirrored from the app ────────────────────────

/// The identifiers the app sets. Kept in one place so a rename breaks
/// compilation here rather than silently making a query match nothing —
/// XCUITest's default failure mode is "element not found", which reads
/// identically to "the feature is broken".
enum A11y {
    static let messageList = "message.list"
    static let chip = "chip."             // + TriageFilter rawValue
    static let tierFilterMenu = "filter.tier"
    static let dateFilterMenu = "filter.date"
    static let clearFilters = "filter.clear"
    static let selectToggle = "filter.select"
    static let stalenessBanner = "list.staleness"
    static let paginationFooter = "list.pagination"
    static let rowPrefix = "row."         // + message id
}

/// UserDefaults keys the app reads, mirrored as literals.
///
/// The UI test target cannot import the app module, so these cannot reference
/// `OnboardingViewModel.tutorialSeenKey` / `TriageFilter.defaultsKey` / etc.
/// directly. `UITestSupportContractTests` (unit target, which CAN see them)
/// asserts each literal still matches — the failure mode this guards against is
/// nasty: a renamed key silently stops skipping Onboarding, and every UI test
/// fails with "element not found" rather than "your key is stale".
enum DefaultsKeys {
    static let tutorialSeen  = "onboarding.tutorialSeen"
    static let triageFilter  = "list.triageFilter"
    static let tierFilter    = "list.tierFilter"
    static let dateWindow    = "list.dateWindow"
}

// ── Launch helpers ──────────────────────────────────────────────────────────

extension XCUIApplication {
    /// Launch the app pointed at `server`, with a clean slate for the
    /// client-side preferences the list persists (chip, tier, date window).
    /// Without the reset, a filter left over from a previous test's UserDefaults
    /// would silently narrow the next test's list.
    @MainActor
    static func launched(against server: FixtureServer,
                         extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["THRESHER_API_BASE_URL"] = server.baseURL
        app.launchEnvironment["THRESHER_UITEST"] = "1"
        for (k, v) in extraEnvironment { app.launchEnvironment[k] = v }
        // Skip onboarding and start from known filter state. These are the
        // REAL defaults keys the app reads — `-key value` launch arguments are
        // parsed by NSUserDefaults into the argument domain, which outranks
        // whatever is persisted, so each test starts from a clean slate
        // regardless of what a previous run left behind.
        // Literals, not symbols: a UI test target links against the app as a
        // separate PROCESS and has no `@testable import`, so the app's
        // constants are not in scope. `DefaultsKeys` below documents where each
        // literal comes from, and `UITestSupportContractTests` in the unit
        // target pins them against the real constants so a rename fails a test
        // instead of silently routing these launches into Onboarding.
        app.launchArguments += [
            "-\(DefaultsKeys.tutorialSeen)", "YES",
            "-\(DefaultsKeys.triageFilter)", "open",
            "-\(DefaultsKeys.tierFilter)", "0",
            "-\(DefaultsKeys.dateWindow)", "anyTime",
        ]
        app.launch()
        return app
    }
}