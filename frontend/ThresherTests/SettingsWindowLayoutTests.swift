//
//  SettingsWindowLayoutTests.swift
//  ThresherTests
//
//  Render-level guard for the Settings window's top inset (gate-defects Part A,
//  the E16-class lesson behind OI14: `testSidebarMatchesD43Order` pins MODEL
//  order, not rendered visibility — the Session-23 human gate found the first
//  sidebar row and the Add Rule control occluded by the window's title bar).
//
//  This test target is HOSTED in the real app (TEST_HOST = Thresher.app),
//  so it can open the actual SwiftUI `Settings` scene window, inspect the real
//  AppKit geometry, and render the real window chrome to a bitmap — the same
//  occluding geometry a human sees at ⌘,, unlike an offscreen NSHostingView.
//
//  Also writes render evidence to /tmp/thresher-part-a/ for the work-order
//  record (diagnostics text + a PNG of the full window including title bar).
//

import XCTest
import AppKit
@testable import Thresher

@MainActor
final class SettingsWindowLayoutTests: XCTestCase {

    private static let evidenceDir = URL(fileURLWithPath: "/tmp/thresher-part-a")

    /// Open the SwiftUI Settings scene the same way ⌘, does and wait for its window.
    private func openSettingsWindow() throws -> NSWindow {
        try? FileManager.default.createDirectory(at: Self.evidenceDir,
                                                 withIntermediateDirectories: true)
        // macOS 13+ responder-chain action for the Settings scene (⌘, sends
        // this); fall back to the pre-13 selector if unhandled.
        let known = NSApp.windows.map(ObjectIdentifier.init)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // Drive the real "Settings…" menu item (⌘,) — the exact path a user
        // takes — rather than guessing at private selectors.
        var sent = false
        var debug = ""
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
            let item = appMenu.items[index]
            debug += "menu item: \(item.title) action=\(String(describing: item.action)) target=\(String(describing: item.target))\n"
            appMenu.update()
            appMenu.performActionForItem(at: index)
            sent = true
        } else {
            debug += "no ⌘, menu item found; falling back to selectors\n"
            sent = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                || NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        try? debug.write(to: Self.evidenceDir.appendingPathComponent("menu-debug.txt"),
                         atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            // Match the NEW window rather than a title string — the Settings
            // scene window's title may lag its creation (visibility not
            // required; the test runner app may never become frontmost).
            if let w = NSApp.windows.first(where: {
                !known.contains(ObjectIdentifier($0))
            }) {
                w.orderFrontRegardless()
                // Let SwiftUI finish its first layout/animation pass.
                RunLoop.main.run(until: Date().addingTimeInterval(1.5))
                return w
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let inventory = NSApp.windows
            .map { "\(type(of: $0)) title=\($0.title) visible=\($0.isVisible)" }
            .joined(separator: "\n")
        try? "sendAction=\(sent)\n\(inventory)\n"
            .write(to: Self.evidenceDir.appendingPathComponent("no-window-debug.txt"),
                   atomically: true, encoding: .utf8)
        XCTFail("Settings window did not appear within 8s (sendAction=\(sent))")
        throw NSError(domain: "SettingsWindowLayoutTests", code: 1)
    }

    /// Depth-first description of the AppKit hierarchy with window-coordinate frames.
    private func dumpHierarchy(_ view: NSView, indent: String = "", into out: inout String) {
        let inWindow = view.convert(view.bounds, to: nil)
        out += "\(indent)\(type(of: view)) frame(win)=\(inWindow)\n"
        for sub in view.subviews {
            dumpHierarchy(sub, indent: indent + "  ", into: &out)
        }
    }

    /// Render the FULL window (title bar included) so the evidence shows the
    /// chrome that occludes — not just the content view.
    private func renderWindow(_ window: NSWindow, to filename: String) throws {
        let frameView = window.contentView!.superview!   // NSThemeFrame
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            XCTFail("could not create bitmap rep"); return
        }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let png = rep.representation(using: .png, properties: [:])!
        try png.write(to: Self.evidenceDir.appendingPathComponent(filename))
    }

    func testSettingsContentClearsTheTitleBar() throws {
        let window = try openSettingsWindow()
        defer { window.close() }

        let contentView = window.contentView!

        // ── Diagnostics for the work-order record ────────────────────────────
        var diag = ""
        diag += "window.frame            = \(window.frame)\n"
        diag += "window.styleMask        = \(window.styleMask.rawValue) (fullSizeContentView=\(window.styleMask.contains(.fullSizeContentView)))\n"
        diag += "titlebarAppearsTransparent = \(window.titlebarAppearsTransparent)\n"
        diag += "toolbar                 = \(String(describing: window.toolbar))\n"
        diag += "toolbarStyle            = \(window.toolbarStyle.rawValue)\n"
        diag += "contentView.frame       = \(contentView.frame)\n"
        diag += "contentLayoutRect       = \(window.contentLayoutRect)\n"
        diag += "safeAreaInsets(content) = \(contentView.safeAreaInsets)\n"
        dumpHierarchy(contentView, into: &diag)
        try diag.write(to: Self.evidenceDir.appendingPathComponent("diagnostics.txt"),
                       atomically: true, encoding: .utf8)
        try renderWindow(window, to: "settings-window.png")

        // ── The actual guard ──────────────────────────────────────────────────
        // The title bar occupies the space between the top of the content view
        // and contentLayoutRect. If the window is styled full-size-content, the
        // SwiftUI hierarchy must still lay its interactive content out inside
        // contentLayoutRect (plus safe-area handling), or the first sidebar row
        // / Add Rule control render under the bar (the Session-23 defect).
        let titleBarHeight = contentView.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThan(titleBarHeight, 0, "window should have a title bar")

        // Find the sidebar's List (an NSTableView inside the split view's first
        // column) and assert its first row is fully below the title bar in
        // window coordinates (AppKit windows are bottom-left origin: "below the
        // bar" means maxY of the row <= contentLayoutRect.maxY).
        let tables = contentView.descendants(ofType: NSTableView.self)
        XCTAssertFalse(tables.isEmpty, "expected the sidebar List's NSTableView")
        guard let sidebar = tables.first, sidebar.numberOfRows > 0 else {
            XCTFail("sidebar table missing or empty"); return
        }
        XCTAssertEqual(sidebar.numberOfRows, 5, "D43+D47: five sidebar rows")

        let firstRowRect = sidebar.convert(sidebar.rect(ofRow: 0), to: nil) // window coords
        let layoutRect = window.contentLayoutRect
        XCTAssertLessThanOrEqual(
            firstRowRect.maxY, layoutRect.maxY + 0.5,
            """
            First sidebar row (Email accounts) renders under the title bar: \
            row top y=\(firstRowRect.maxY) vs contentLayoutRect top y=\(layoutRect.maxY). \
            (Part A regression — content must lay out below the bar.)
            """
        )
    }
}

extension SettingsWindowLayoutTests {

    /// Is the backend answering? (OI22.)
    ///
    /// This whole suite drives the REAL app inside the test host, and
    /// `RootView` shows a loader until accounts resolve from the API — so with
    /// no backend the main window never reaches `MainWindowView` and never
    /// grows its custom toolbar items. The test then failed as *"no custom
    /// toolbar items appeared in the main window"*, which reads as a layout
    /// regression and sends the reader into toolbar code. It cost a debugging
    /// cycle before anyone thought to check whether :8765 was up.
    ///
    /// Uses `APIClient.defaultBaseURL` rather than a hardcoded URL so the probe
    /// cannot disagree with the app about which backend it is waiting for —
    /// `THRESHER_API_BASE_URL` moves both together.
    ///
    /// BOTH BRANCHES VERIFIED (2026-09-02): passes with the backend up; skips
    /// with this message when it is not. Getting the second half proved
    /// awkward and the finding is worth leaving here — **environment overrides
    /// do NOT reach a hosted unit test.** Neither
    /// `THRESHER_API_BASE_URL=… xcodebuild …` nor
    /// `TEST_RUNNER_THRESHER_API_BASE_URL=…` changed what the app saw; both
    /// runs sailed past the skip and PASSED against the live backend, which
    /// looks exactly like a verified skip branch and is not one.
    /// (`TEST_RUNNER_*` is for a UI-test runner process; this test is hosted
    /// inside the app.) The skip was confirmed by temporarily pointing this
    /// probe at a dead port — which also honoured the constraint that the live
    /// alpha backend must not be stopped.
    private func backendIsReachable(timeout: TimeInterval = 3) -> Bool {
        let url = APIClient.defaultBaseURL.appendingPathComponent("version")
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // Synchronous on purpose: this gates a test that then drives the main
        // RunLoop, and an async probe would interleave with that.
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                reachable = true
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        return reachable
    }

    /// The OTHER route to Settings: the main-window gear button presents
    /// SettingsView inside a sheet (`NavigationStack { SettingsView() }`).
    /// The Session-23 screenshots came from a live gate interaction — this
    /// covers the presentation the ⌘, scene test can't.
    func testSettingsSheetContentClearsTheTopBar() throws {
        // OI22: name the real precondition instead of failing as a layout bug.
        try XCTSkipUnless(backendIsReachable(), """
            SKIPPED — the backend is not answering at \(APIClient.defaultBaseURL).

            This test drives the real app: RootView shows a loader until accounts \
            resolve from the API, so with no backend the main window never reaches \
            MainWindowView and never grows the toolbar items this test clicks. It \
            would otherwise fail as "no custom toolbar items appeared in the main \
            window", which reads as a layout regression and is not one.

            Start it with `scripts/backend.sh start` (or `scripts/launchagent.sh \
            status` if launchd owns it) and re-run.
            """)

        try? FileManager.default.createDirectory(at: Self.evidenceDir,
                                                 withIntermediateDirectories: true)
        guard let main = NSApp.windows.first(where: { $0.title == "Thresher" }) else {
            XCTFail("main window not found"); return
        }
        // Wait for launch routing to finish (RootView shows a loader until
        // accounts resolve) — the toolbar's custom items appear with
        // MainWindowView. The gear is a pure-SwiftUI ToolbarItemHostingView
        // (no NSControl inside), so it can't performClick; drive it with a
        // synthesized mouse down/up through the window's own event pipeline.
        func customToolbarItems() -> [NSToolbarItem] {
            (main.toolbar?.items ?? []).filter {
                !$0.itemIdentifier.rawValue.hasPrefix("com.apple.SwiftUI") && $0.view != nil
            }
        }
        let gearDeadline = Date().addingTimeInterval(10)
        while Date() < gearDeadline, customToolbarItems().isEmpty {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        let candidates = customToolbarItems()
        guard !candidates.isEmpty else {
            XCTFail("no custom toolbar items appeared in the main window"); return
        }

        func click(_ view: NSView) {
            let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            func event(_ kind: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(
                    with: kind, location: center, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: main.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1
                )
            }
            guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
            // Queue the up BEFORE delivering the down: a control's synchronous
            // mouse-tracking loop otherwise spins forever waiting for a real
            // mouse-up that will never come (this hung the first attempt).
            NSApp.postEvent(up, atStart: false)
            main.sendEvent(down)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }

        // Two custom items exist (gear + the list's refresh); clicking refresh
        // is harmless, so try each until the sheet attaches.
        var sheet: NSWindow?
        for item in candidates {
            click(item.view!)
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline {
                if let s = main.attachedSheet { sheet = s; break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            if sheet != nil { break }
        }
        guard let sheet else { XCTFail("Settings sheet did not appear within 8s"); return }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        defer {
            main.endSheet(sheet)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }

        let contentView = sheet.contentView!
        var diag = ""
        diag += "sheet.frame             = \(sheet.frame)\n"
        diag += "sheet.styleMask         = \(sheet.styleMask.rawValue) (fullSizeContentView=\(sheet.styleMask.contains(.fullSizeContentView)))\n"
        diag += "toolbar                 = \(String(describing: sheet.toolbar))\n"
        diag += "contentLayoutRect       = \(sheet.contentLayoutRect)\n"
        diag += "safeAreaInsets(content) = \(contentView.safeAreaInsets)\n"
        dumpHierarchy(contentView, into: &diag)
        try diag.write(to: Self.evidenceDir.appendingPathComponent("sheet-diagnostics.txt"),
                       atomically: true, encoding: .utf8)
        try renderWindow(sheet, to: "settings-sheet.png")

        // Sidebar first row must clear whatever top bar the sheet draws. The
        // bar is SwiftUI-drawn (not window chrome — contentLayoutRect covers
        // the whole sheet), so detect it geometrically: any full-width,
        // bar-height view pinned to the window's top edge that is NOT an
        // ancestor of the split view. In the Session-23 defect this was a
        // 38pt _NSGraphicsView overlaying the split view's top.
        let tables = contentView.descendants(ofType: NSTableView.self)
        guard let sidebar = tables.first, sidebar.numberOfRows > 0 else {
            XCTFail("sheet sidebar table missing or empty"); return
        }
        XCTAssertEqual(sidebar.numberOfRows, 5, "D43+D47: five sidebar rows")

        let windowTop = contentView.convert(contentView.bounds, to: nil).maxY
        let fullWidth = contentView.convert(contentView.bounds, to: nil).width
        var topBarBottom = windowTop
        func scanForTopBars(_ view: NSView) {
            let f = view.convert(view.bounds, to: nil)
            let isBar = f.maxY >= windowTop - 0.5 && f.width >= fullWidth - 0.5
                        && f.height > 0 && f.height <= 100
            if isBar && !sidebar.isDescendant(of: view) {
                topBarBottom = min(topBarBottom, f.minY)
                return  // a bar's own subviews are inside it; no need to recurse
            }
            for sub in view.subviews { scanForTopBars(sub) }
        }
        scanForTopBars(contentView)

        let firstRowRect = sidebar.convert(sidebar.rect(ofRow: 0), to: nil)
        XCTAssertLessThanOrEqual(
            firstRowRect.maxY, topBarBottom + 0.5,
            """
            First sidebar row (Email accounts) renders under the sheet's top \
            bar: row top y=\(firstRowRect.maxY) vs bar bottom y=\(topBarBottom). \
            (Part A regression — Session-23 gate defect.)
            """
        )

        // No interactive control anywhere in the sheet may hide under the bar
        // either (the gate's clipped/unclickable Add Rule control case).
        for button in contentView.descendants(ofType: NSButton.self) {
            let f = button.convert(button.bounds, to: nil)
            guard f.minY < topBarBottom else {  // fully inside the bar = bar's own control
                continue
            }
            XCTAssertLessThanOrEqual(
                f.maxY, topBarBottom + 0.5,
                "Control \(type(of: button)) at \(f) is occluded by the sheet's top bar"
            )
        }
    }
}

private extension NSView {
    func descendants<T: NSView>(ofType type: T.Type) -> [T] {
        var found: [T] = []
        for sub in subviews {
            if let t = sub as? T { found.append(t) }
            found.append(contentsOf: sub.descendants(ofType: type))
        }
        return found
    }
}
