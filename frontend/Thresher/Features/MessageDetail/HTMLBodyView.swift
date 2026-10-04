//
//  HTMLBodyView.swift
//  Thresher
//
//  HTML body fallback (dogfood polish Part B). Renders `body_html` when a
//  message has no usable `body_plain` — HTML-only mail (the SaneBox case) was
//  showing "(no plain-text body)" and couldn't be read or acted on.
//
//  THE NON-NEGOTIABLE (P5): remote content must not load, ever, in v1.
//  Auto-fetching a tracking pixel is an outward observable side effect — a
//  read receipt — and this app has kept its side-effect surface strictly
//  opt-in (write-back needed an explicit per-account preference; a pixel must
//  not sneak the same signal out the back door).
//
//  Blocking mechanism, in layers:
//   1. A compiled WKContentRuleList with `url-filter: ".*" → block` — WebKit's
//      own content-blocker engine refuses EVERY network subresource load
//      (img/css/font/fetch/media, http and https alike). The message HTML
//      itself still renders because it arrives via loadHTMLString, not a
//      network fetch. Inline `data:` images are not network loads and survive;
//      `cid:` parts don't resolve (no MIME context) and show as placeholders.
//   2. FAIL CLOSED: if the rule list fails to compile, the HTML is NOT
//      rendered at all — the view shows an honest placeholder instead of
//      falling back to an unblocked web view.
//   3. Content JavaScript is disabled (defense in depth; script can't run, so
//      it can't try to beacon even against a blocked network).
//   4. Navigation is pinned: the initial loadHTMLString commit is the only
//      in-view navigation allowed. Link clicks open in the default browser.
//

import SwiftUI
import WebKit

/// The rule-list plumbing, kept separate from the SwiftUI wrapper so tests can
/// drive the REAL blocking configuration against a live local listener.
@MainActor
enum SafeHTMLRenderer {
    static let ruleListIdentifier = "thresher.block-all-network"

    /// Block every URL the content-blocker engine sees. loadHTMLString content
    /// is not a network load, so the message body itself is unaffected.
    static let blockAllNetworkRules = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]
    """

    /// Compile (or fetch the cached) block-everything rule list. `nil` means
    /// the caller must NOT render HTML (fail closed).
    static func blockingRuleList() async -> WKContentRuleList? {
        try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: ruleListIdentifier,
            encodedContentRuleList: blockAllNetworkRules)
    }

    /// A web view configured with the full blocking stack. The rule list is
    /// required up front — there is no unblocked construction path.
    static func makeBlockedWebView(ruleList: WKContentRuleList) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(ruleList)
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")   // match the pane
        return webView
    }
}

/// SwiftUI wrapper: compiles the blocker first, renders only once it exists.
struct HTMLBodyView: View {
    let html: String
    @State private var ruleList: WKContentRuleList?
    @State private var compileFailed = false

    var body: some View {
        Group {
            if let ruleList {
                BlockedWebView(html: html, ruleList: ruleList)
            } else if compileFailed {
                // Fail closed (P5): no blocker, no HTML.
                Text("(HTML body withheld — the remote-content blocker is unavailable)")
                    .font(.body).italic()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            if let list = await SafeHTMLRenderer.blockingRuleList() {
                ruleList = list
            } else {
                compileFailed = true
            }
        }
    }
}

/// The NSViewRepresentable around the blocked WKWebView. Sizes itself to the
/// document height (measured after load via an API-injected probe — content
/// JS stays disabled) so it reads as part of the detail scroll, not a nested
/// scroller.
private struct BlockedWebView: NSViewRepresentable {
    let html: String
    let ruleList: WKContentRuleList
    @State private var contentHeight: CGFloat = 120

    func makeCoordinator() -> Coordinator { Coordinator(height: $contentHeight) }

    func makeNSView(context: Context) -> WKWebView {
        let webView = SafeHTMLRenderer.makeBlockedWebView(ruleList: ruleList)
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: contentHeight)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let height: Binding<CGFloat>
        init(height: Binding<CGFloat>) { self.height = height }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // App-injected probe: allowsContentJavaScript only gates the
            // page's own scripts, not API evaluation.
            webView.evaluateJavaScript("document.body.scrollHeight") { [height] value, _ in
                if let h = value as? Double, h > 0 {
                    Task { @MainActor in height.wrappedValue = CGFloat(h) }
                }
            }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only the initial loadHTMLString commit (about:blank) stays
            // in-view. A clicked link opens in the default browser — the
            // message pane never navigates (and the blocker never has to
            // trust it would have).
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}