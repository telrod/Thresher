//
//  RemoteContentBlockTests.swift
//  ThresherTests
//
//  Part B's non-negotiable, pinned: HTML bodies render with remote content
//  BLOCKED (P5 — a fetched tracking pixel is an outward read receipt, and this
//  app's side-effect surface is strictly opt-in).
//
//  Method: a real TCP listener on 127.0.0.1 is the canary. The fixture embeds
//  <img>/<link>/fetch beacons pointing at it. The REAL blocking stack
//  (SafeHTMLRenderer.makeBlockedWebView, the same construction the detail view
//  uses) must produce ZERO connections. A deliberately UNBLOCKED control web
//  view must produce at least one — proving the canary actually detects
//  fetches, so the blocked test's silence is evidence rather than a broken
//  probe (verify the verifier).
//

import Network
import WebKit
import XCTest
@testable import Thresher

/// Minimal TCP canary: counts every accepted connection on an ephemeral port.
/// Any WebKit subresource fetch to the port shows up here — protocol details
/// don't matter, a connection at all is already the leaked signal.
private final class ConnectionCanary: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var _connections = 0
    var connections: Int { lock.withLock { _connections } }
    private(set) var port: UInt16

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        port = 0   // placeholder until the listener reports ready
        let started = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.lock.withLock { self._connections += 1 }
            conn.cancel()
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { started.signal() }
            if case .failed = state { started.signal() }
        }
        listener.start(queue: DispatchQueue(label: "canary"))
        guard started.wait(timeout: .now() + 5) == .success,
              let p = listener.port?.rawValue, p > 0 else {
            throw XCTSkip("canary listener failed to start")
        }
        port = p
    }

    func stop() { listener.cancel() }
}

private func trackingFixture(port: UInt16) -> String {
    """
    <html><head>
      <link rel="stylesheet" href="http://127.0.0.1:\(port)/style.css">
    </head><body>
      <p>Action required for continued service</p>
      <img src="http://127.0.0.1:\(port)/pixel.png" width="1" height="1">
      <img src="http://127.0.0.1:\(port)/logo.png">
    </body></html>
    """
}

@MainActor
final class RemoteContentBlockTests: XCTestCase {

    /// Load HTML and give WebKit time to attempt (or refuse) subresource loads.
    private func render(html: String, in webView: WKWebView) async {
        let delegate = FinishDelegate()
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: nil)
        await delegate.finished()
        // Post-load grace: subresource fetches happen after didFinish commit.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    func testBlockedWebViewNeverTouchesTheNetwork() async throws {
        let canary = try ConnectionCanary()
        defer { canary.stop() }

        let compiled = await SafeHTMLRenderer.blockingRuleList()
        let ruleList = try XCTUnwrap(compiled, "block-all rule list must compile")
        let webView = SafeHTMLRenderer.makeBlockedWebView(ruleList: ruleList)
        await render(html: trackingFixture(port: canary.port), in: webView)

        XCTAssertEqual(canary.connections, 0,
                       "P5 breach: the blocked web view opened a connection — a "
                           + "tracking pixel would have fired a read receipt.")
    }

    /// Control (verify the verifier): the SAME fixture in an UNBLOCKED web view
    /// must hit the canary — otherwise the zero above proves nothing.
    func testUnblockedControlProvesTheCanaryDetectsFetches() async throws {
        let canary = try ConnectionCanary()
        defer { canary.stop() }

        let unblocked = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        await render(html: trackingFixture(port: canary.port), in: unblocked)

        XCTAssertGreaterThan(canary.connections, 0,
                             "The canary saw no fetch from an unblocked web view — "
                                 + "the probe itself is broken; fix it before trusting the block test.")
    }
}

/// Await-able didFinish bridge.
@MainActor
private final class FinishDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false

    func finished() async {
        if done { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        done = true
        continuation?.resume()
        continuation = nil
    }
}