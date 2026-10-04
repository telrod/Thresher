//
//  ThresherApp.swift
//  Thresher
//
//  App entry point. macOS 14 target (D36). The window content is a RootView that
//  makes the single first-run routing decision (§3, §4.1.4): show Onboarding when
//  there are no connected accounts OR the tutorial has never been seen; otherwise
//  the main Message List ↔ Detail split (§4.1.1/§4.1.2).
//

import SwiftUI

@main
struct ThresherApp: App {
    /// D67: the app owns the backend's lifetime. Held here (not in a view) so
    /// one supervisor spans the whole app rather than one per window.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                // Must match RootView's own floor, or the outer frame clamps the
                // window below what the split view needs and the chip row clips
                // again at the smallest size.
                .frame(minWidth: MessageListView.minimumColumnWidth + 420,
                       minHeight: 480)
        }

        // Settings screen (§4.1.3) also reachable via the standard ⌘, affordance.
        Settings {
            SettingsView()
        }
    }
}

/// D67 — the app-lifetime backend supervisor, wired to the app's own lifetime.
///
/// A delegate rather than a `.task` on a view: the backend must outlive any
/// single window and must be stopped exactly once, on termination. A view-scoped
/// task would start a second backend on a second window and stop it when either
/// closed.
///
/// STANDS DOWN when launchd owns the backend. Alpha is still supervised (D66)
/// until packaging lands, and two supervisors restarting each other's corpses is
/// worse than either alone — the same rule `launchagent.sh install` enforces
/// from the other side.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var supervisor: BackendSupervisor?

    /// Nudge the backend after an account is connected.
    ///
    /// WHY A HOOK RATHER THAN THE 30s TICK. On first run the poller is not
    /// running when the user clicks Connect — it exits EXIT_NOT_CONFIGURED
    /// while no account exists — so nothing polls until the supervisor's next
    /// relaunch tick. Measured on a real cold start: credential stored at
    /// 17:56:01, poller picked it up at 17:56:25. **24 seconds of a blank
    /// screen, entirely this tick**, while the fetch itself took 5.
    ///
    /// This calls the SAME `restartAnythingThatDied()` the timer calls, so
    /// there is one relaunch path, not two: it already treats an
    /// unconfigured exit as "wait, do not spend a restart", so an on-demand
    /// call cannot exhaust the budget or fight the wait-branch.
    ///
    /// Static because the connect view has no reference to the AppDelegate,
    /// and threading one through the onboarding flow to deliver a single
    /// nudge would be more coupling than the nudge is worth.
    @MainActor
    static func backendShouldPollNow() {
        shared?.supervisor?.restartAnythingThatDied()
    }

    /// The live delegate, so `backendShouldPollNow()` can reach the supervisor.
    private static weak var shared: AppDelegate?
    private var healthTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        guard BackendSupervisor.shouldManageBackend(
                launchdOwnsIt: BackgroundPolling().isSupervised) else {
            return
        }
        let supervisor = BackendSupervisor()
        do {
            let summary = try supervisor.start()
            self.supervisor = supervisor
            // Record what was ACTUALLY started, not what was intended. The API
            // skip is deliberate and silent, and on the D67 path it should never
            // fire — so "skipped API (port held)" appearing here means something
            // else is serving the store, which is worth knowing before debugging
            // anything else.
            BackendSupervisor.appendToSupervisorLog("start: \(summary.summary)")
        } catch {
            // Not fatal, and deliberately not a modal (P2): the app is still
            // usable against a backend started some other way, and the message
            // list already reports an unreachable backend and a dead poller
            // (D65/OI31). Crashing or blocking on a supervisor failure would be
            // a worse experience than the one it exists to prevent.
            NSLog("Backend supervisor did not start: %@",
                  (error as? LocalizedError)?.errorDescription ?? "\(error)")
            return
        }
        // launchd's KeepAlive, in app form. Without this a poller that crashes
        // at 9am inside a running app stays dead all day — the 13-day outage in
        // miniature, bounded only by how long the app stays open.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in supervisor.restartAnythingThatDied() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthTimer?.invalidate()
        healthTimer = nil
        // The whole point of D67: quitting the app stops the backend. Only what
        // this supervisor started is stopped — never launchd's, never an orphan.
        supervisor?.stop()
        supervisor = nil
    }
}

/// The one launch-routing decision point (§3). Resolves `shouldOnboard` from the
/// API (accounts) + local flag (tutorial-seen) before choosing, so routing never
/// races on the empty default. While that first fetch is in flight we show a
/// neutral loader rather than flashing the empty Message List or Onboarding.
@MainActor
struct RootView: View {
    @State private var onboardModel = OnboardingViewModel()
    /// The routing decision, LATCHED once accounts resolve: nil = undecided (still
    /// loading), true = show onboarding to completion, false = go to the main UI.
    ///
    /// Why latched, not re-derived from `shouldOnboard` every render: onboarding
    /// mutates the very signals `shouldOnboard` reads — clicking "Get started"
    /// marks the tutorial seen, which would flip `shouldOnboard` to false and yank
    /// the user out of the flow mid-step (they'd skip Connect / Prefs /
    /// Notifications). Deciding once and holding it until the flow calls
    /// `onFinished` keeps onboarding stable regardless of in-flight flag changes.
    @State private var showOnboarding: Bool?

    var body: some View {
        Group {
            switch showOnboarding {
            case .none:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .some(true):
                OnboardingView(model: onboardModel) { showOnboarding = false }
            case .some(false):
                MainWindowView()
            }
        }
        .task {
            // Resolve routing ONCE, then latch it. OnboardingView re-fetches
            // accounts on its own .task; this initial resolve gates the first paint
            // and the latch keeps it from changing under the user.
            if showOnboarding == nil {
                await onboardModel.refreshAccounts()
                showOnboarding = onboardModel.shouldOnboard
            }
        }
    }
}

/// The main app UI (§4.1.1/§4.1.2): Message List sidebar + Message Detail pane,
/// with Settings reachable from a toolbar button. Selection is lifted here so
/// picking a list row drives the detail pane.
@MainActor
struct MainWindowView: View {
    @State private var selection: MessageListRow.ID?
    /// Drives the Settings sheet (§4.1.3). A sheet keeps the list/detail split as
    /// the main window while making Settings reachable from a toolbar button
    /// (discoverable, not ⌘,-only). The native Settings scene ALSO hosts it for
    /// the standard ⌘, affordance.
    @State private var showSettings = false
    /// Native notification delivery (§4.3 / D45). While the main window is up, the
    /// manager claims the hand-off and polls GET /notifications, posting native
    /// banners. Its click-to-open delegate routes into `selection` (commit 3).
    @State private var notifications = NotificationManager()
    /// The list's model, owned HERE since E20 so the detail pane's triage
    /// callback can patch the same rows the sidebar renders (the two panes'
    /// view models are otherwise independent).
    @State private var listModel: MessageListViewModel
    /// The dock badge's health half, on an APP-lifetime loop (human gate 1.4).
    /// Deliberately not owned by the view: the badge exists for when the window
    /// is closed, so its liveness must not end with `.onDisappear`.
    @State private var badgeMonitor: DockBadgeMonitor
    private let api: MessageAPI

    init(api: MessageAPI = APIClient()) {
        self.api = api
        _listModel = State(initialValue: MessageListViewModel(api: api))
        _badgeMonitor = State(initialValue: DockBadgeMonitor(api: api))
    }

    var body: some View {
        NavigationSplitView {
            MessageListView(model: listModel, selection: $selection)
                // The list column floor is set BY MEASUREMENT, not taste: the
                // chip row is the widest fixed content in this column and it
                // must never clip, because the counts ARE the chips' payload
                // (the OI18 lesson — a truncated count actively misleads).
                //
                // Measured with the real chip geometry (4 chips, 8pt gaps, 10pt
                // inner padding, 12pt row padding): 380pt at the live store's
                // counts, and 468pt for the worst realistic case — five-digit
                // counts at the D47 "Large" font scale. Hence 480.
                //
                // 320 was the old floor and it clipped "Open" to "en 4,738" and
                // cut "All 4,939" off the right edge at the default width — the
                // standing flagged item, reported from a real window.
                .frame(minWidth: MessageListView.minimumColumnWidth,
                       idealWidth: MessageListView.minimumColumnWidth + 40)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showSettings = true
                        } label: { Image(systemName: "gearshape") }
                        .help("Settings")
                    }
                }
        } detail: {
            if let id = selection {
                // Re-created per selection (the id in .task drives reload).
                // E20: a successful triage write patches the list row in place
                // via the shared list model — no reload, no scroll disruption.
                MessageDetailView(messageID: id, onTriageChange: { messageID, stateRaw in
                    listModel.applyTriage(messageID: messageID, stateRaw: stateRaw)
                })
                .id(id)
            } else {
                ContentUnavailableView(
                    "Select a message",
                    systemImage: "envelope",
                    description: Text("Pick a message to see its full content and why it was classified.")
                )
            }
        }
        // Raised with the list column: a 520pt sidebar inside a 720pt window
        // left only 200pt for the detail pane, which is too narrow to read a
        // message in. 940 = 520 list + ~420 detail, both usable at the floor.
        .frame(minWidth: MessageListView.minimumColumnWidth + 420, minHeight: 480)
        // NOTE (gate-defects Part A): SettingsView is presented DIRECTLY, not
        // wrapped in a NavigationStack. SettingsView is itself a
        // NavigationSplitView (D43); nesting it inside a stack made the stack
        // draw its bar as a top overlay WITHOUT propagating a safe-area inset
        // to the AppKit-backed split view — occluding the first sidebar row
        // (Email accounts) and each pane's top edge (Add Rule) in the sheet.
        // The split view manages its own toolbar, so Done lands in a real bar
        // that the columns lay out below.
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showSettings = false }
                    }
                }
        }
        // Start native delivery on the D34 poll cadence (read from preferences,
        // same source the message list uses). No-op unless the user granted
        // permission — otherwise the backend keeps delivering (coexistence floor).
        .task {
            var interval = TimeInterval(Preferences.defaultPollIntervalMinutes * 60)
            if let prefs = try? await api.preferences() {
                interval = prefs.pollIntervalSeconds
            }
            // D49 fast path (E21): a posted banner means new mail — refresh the
            // list in step so the banner and the list never disagree. Quiet
            // refresh (userRefresh doesn't touch isLoading's spinner path from
            // a background call), rows swap in place (P2).
            let listModel = listModel
            notifications.onDeliveredNewMail = {
                Task { await listModel.userRefresh() }
            }
            notifications.start(pollInterval: interval)
            // App-lifetime, deliberately started here but never stopped on
            // window close: the badge is the ONLY health surface once the
            // window is gone (human gate 1.4 failed exactly there).
            badgeMonitor.start()
            // Cold-start deep link: if the app was launched by a notification tap,
            // the delegate already recorded the id before this window existed.
            // Apply it now that the split view is up (RootView has resolved routing).
            applyPendingDeepLink()
        }
        // Warm deep link: a tap while the app is already running.
        .onChange(of: notifications.pendingMessageID) { _, _ in
            applyPendingDeepLink()
        }
        // D51: dock badge = untriaged (state New) Tier 1/2 count — the Open
        // view's urgent tail. Both update points feed ONE derived value:
        // every reload refetches counts (D49 cadence + fast path), and the
        // E20 triage seam adjusts urgentNew in place — this observer just
        // renders whatever the model says. Zero clears the badge entirely.
        // The RENDERED badge is a human-gate eyeball item (dockTile isn't
        // headless-testable); the derivation is unit-tested.
        //
        // OI31: the badge ALSO carries a `!` when a mailbox is not polling.
        // D65's banner lives in the message list only, so a dead poller was
        // silent in Settings, in the detail pane, and — the case that matters —
        // with the window closed, where the badge is the only surface. An empty
        // badge meaning both "no urgent mail" and "nothing is being polled" is
        // the very ambiguity D65 exists to remove.
        //
        // TWO observers, one derivation: the badge must repaint when EITHER
        // input changes. Watching only the count would leave the warning
        // un-rendered until an unrelated triage happened to move the number —
        // and a poller dying is exactly when the count stops changing.
        // While a window IS open the list model is the fresher source for both
        // halves — it already refetches counts and health on every pass — so
        // hand them to the monitor rather than letting two loops race.
        .onChange(of: listModel.counts?.urgentNew) { _, _ in updateDockBadge() }
        .onChange(of: listModel.accountHealth) { _, _ in updateDockBadge() }
        // NOTE: no `.onDisappear` teardown here any more. Closing the window
        // used to stop notification polling AND freeze the dock badge — both
        // of which are precisely the "app running, window closed" case the two
        // features were built to serve. Teardown belongs to app termination
        // (`applicationWillTerminate`), not to a window going away.
    }

    /// Repaint the dock badge from the model's current state (D51 + OI31).
    /// Both observers call this so there is one derivation, not two.
    private func updateDockBadge() {
        badgeMonitor.updateUrgentCount(listModel.counts?.urgentNew ?? 0)
        badgeMonitor.adopt(health: listModel.accountHealth)
    }

    /// Route a tapped notification into the detail pane by setting the selection
    /// the split view already drives (§4.1.2). Consuming clears it so re-appearing
    /// doesn't re-navigate. If the tapped message isn't in the current list, the
    /// selection still drives MessageDetailView, which fetches it by id.
    private func applyPendingDeepLink() {
        if let messageID = notifications.consumePendingMessage() {
            selection = messageID
        }
    }
}