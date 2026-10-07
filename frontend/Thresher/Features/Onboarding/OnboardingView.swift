//
//  OnboardingView.swift
//  Thresher
//
//  First-run setup flow (§4.1.4). This is MOSTLY REUSE (work order §1.1): it
//  composes the already-built AccountConnectView (§4.1.3) and the shared
//  NotificationsSection (quiet hours / audio / operating mode) into a stepped
//  first-run wrapper plus a short tutorial. It introduces NO new wire shapes —
//  everything talks to the existing models/networking.
//
//  Steps (§2):
//   1. Welcome + brief tutorial  (static, no API; gated on the has-seen flag)
//   1a. Ask: who matters most    (AskPeopleStep — D75: BEFORE Connect, so Tier 1
//                                 membership is in place before the first fetch)
//   2. Connect a Gmail account   (AccountConnectView + App-Password help, §1.5)
//   3. Initial preferences       (NotificationsSection — reused, §1.2)
//   4. Notification permission   (STUB / FLAGGED pending §1.6 / OI-ON1 — we do NOT
//                                 build a UNUserNotificationCenter request on
//                                 assumption; urgency delivery is backend
//                                 osascript banners, so an in-app request may be
//                                 vestigial. the author decides.)
//   5. Done                      (set has-seen flag, route to Message List)
//
//  "Add another account" stays in Settings (§1.7) — onboarding is the first-run
//  wrapper only, not a second add-account entry point.
//

import SwiftUI

@MainActor
struct OnboardingView: View {
    private let api: SettingsAPI
    /// Called when the flow completes — the host swaps to the Message List (§5/§3).
    private let onFinished: () -> Void

    @State private var model: OnboardingViewModel
    @State private var step: Step = .welcome
    /// Accounts connected during THIS flow, shown inline so the user sees success
    /// before continuing. Seeded from the model's initial fetch.
    @State private var connectedThisRun: [String] = []
    /// Native-notification permission (D45). Replaces the old OI-ON1 inert stub —
    /// the onboarding step now makes the real request, because there's a consumer.
    @State private var notifications: NotificationManager
    @State private var requestingPermission = false
    /// The Ask step's state, kept here so Back into Ask shows what was entered.
    @State private var ask: AskPeopleModel
    /// True once an account is connected DURING this run — not seeded from
    /// accounts that already existed. D77 disables Back into Ask after it.
    @State private var connectedDuringRun = false

    init(api: SettingsAPI = APIClient(),
         model: OnboardingViewModel? = nil,
         notifications: NotificationManager? = nil,
         onFinished: @escaping () -> Void = {}) {
        self.api = api
        self.onFinished = onFinished
        _model = State(initialValue: model ?? OnboardingViewModel(api: api))
        _notifications = State(initialValue: notifications ?? NotificationManager())
        _ask = State(initialValue: AskPeopleModel(api: api))
    }

    /// Ordered steps. The tutorial step is skipped up front if already seen (§1.4)
    /// — a returning user starts at Ask (D76), not Connect.
    enum Step: Int, CaseIterable {
        case welcome, ask, connect, preferences, notificationPermission, done
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: 560)
                .padding(24)
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(minWidth: 640, minHeight: 520)
        .task {
            await model.refreshAccounts()
            connectedThisRun = model.accounts
            // Honor the has-seen flag (§1.4): skip the tutorial if already shown,
            // landing on Ask rather than Connect (D76).
            if step == .welcome {
                step = OnboardingFlow.initialStep(hasSeenTutorial: model.hasSeenTutorial)
            }
        }
        .task { await ask.load() }
    }

    // ── Step content ──────────────────────────────────────────────────────────

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:               welcome
        case .ask:                   AskPeopleView(model: ask)
        case .connect:               connect
        case .preferences:           preferences
        case .notificationPermission: notificationPermission
        case .done:                  done
        }
    }

    // 1. Welcome + tutorial (P2/P3: the system is legible from the start).
    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Welcome to Thresher")
                    .font(.largeTitle).bold()
                Text("Thresher sorts your mail by **urgency** and **category** instead of just read/unread — so the important things surface and the noise waits.")
                    .fixedSize(horizontal: false, vertical: true)

                tutorialCard(
                    title: "Five urgency tiers",
                    systemImage: "arrow.up.arrow.down",
                    body: "Every message lands in a tier from **T1 Immediate** down to **T5 Archive** (T2 Today, T3 Digest, T4 Low). Tier 1 always surfaces, in any mode."
                )
                tutorialCard(
                    title: "Triage states",
                    systemImage: "checklist",
                    body: "Move a message through **New → Acknowledged → Needs Action → Done** — a real workflow, not an unread-as-todo hack."
                )
                tutorialCard(
                    title: "Focus vs. Catch-up",
                    systemImage: "eye",
                    body: "Switch modes to change how much is **surfaced**. It never changes how mail is classified, and nothing is hidden permanently."
                )
                tutorialCard(
                    title: "Ambient, not interruptive",
                    systemImage: "bell.badge",
                    body: "Thresher surfaces mail quietly — no blocking pop-ups, no nagging. It shows up when you look."
                )
            }
        }
    }

    private func tutorialCard(title: String, systemImage: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2).frame(width: 32)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(.init(body)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    // 2. Connect (reuses AccountConnectView; App-Password help, §1.5).
    private var connect: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect your Gmail")
                    .font(.title).bold()

                // §1.5 — the single biggest first-run failure point: spell out that
                // an App Password is NOT the account password, and link the page.
                VStack(alignment: .leading, spacing: 6) {
                    Text("You’ll need a Gmail **App Password** — a 16-character code that’s different from your normal password. It lets Thresher read mail without your main credentials.")
                        .fixedSize(horizontal: false, vertical: true)
                    Link("How to create a Gmail App Password →",
                         destination: URL(string: "https://myaccount.google.com/apppasswords")!)
                        .font(.callout)
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

                // §1.3 recovery path: AccountConnectView store→verify already lands
                // a wrong App Password on a clear "re-enter" failure state and never
                // implies connected on a failed verify. On success we record the
                // account inline so the user sees it before advancing.
                AccountConnectView(api: api) { email in
                    connectedDuringRun = true
                    if !connectedThisRun.contains(email) { connectedThisRun.append(email) }
                    Task { await model.refreshAccounts() }
                }

                if !connectedThisRun.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connected").font(.headline)
                        ForEach(connectedThisRun, id: \.self) { email in
                            Label(email, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Text("You can add more now, or continue — you can always add another account later in Settings.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // 3. Initial preferences (reuses the shared NotificationsSection, §1.2).
    private var preferences: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set your preferences")
                .font(.title).bold()
            Text("Sensible defaults are already in place — adjust now or skip and change them later in Settings.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form { NotificationsSection(api: api) }
                .formStyle(.grouped)
        }
    }

    // 4. Notification permission — the REAL request (D45 resolved OI-ON1). Native
    // delivery (UNUserNotificationCenter) now has a consumer: banners that deep-link
    // into the app. Granting lets the app deliver urgent mail with click-to-open;
    // declining is fine — the backend still delivers via its own banners (the
    // coexistence floor), so this is an enhancement, never a gate.
    private var notificationPermission: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Turn on notifications")
                .font(.title).bold()
            Label(
                "Let Thresher alert you to urgent mail — click a notification to jump straight to the message.",
                systemImage: "bell.badge"
            )
            .fixedSize(horizontal: false, vertical: true)

            switch notifications.authorization {
            case .authorized:
                Label("Notifications are on.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .denied:
                Text("Notifications are off. You can turn them on any time in System Settings › Notifications — Thresher will still show urgent mail in the app either way.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .notDetermined:
                Button {
                    Task {
                        requestingPermission = true
                        await notifications.requestAuthorization()
                        requestingPermission = false
                    }
                } label: {
                    if requestingPermission { ProgressView().controlSize(.small) }
                    Text("Enable notifications")
                }
                .buttonStyle(.borderedProminent)
                .disabled(requestingPermission)

                Text("You’ll get the standard macOS permission prompt. You can skip this and decide later.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await notifications.refreshAuthorization() }
    }

    // 5. Done — set the has-seen flag (§5) and hand off to the host.
    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(.green)
            Text("You’re all set").font(.largeTitle).bold()
            Text(connectedThisRun.isEmpty
                 ? "You can connect an account any time from Settings."
                 : "Thresher will start sorting your mail on the next poll.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }

    // ── Footer navigation ─────────────────────────────────────────────────────

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { goBack() }
                    .buttonStyle(.bordered)
                    .disabled(previousStep == nil)
            }
            if step == .ask {
                askFooter
            } else {
                standardFooter
            }
        }
    }

    /// The Ask step's buttons. Return continues and Escape skips, so the step
    /// can be completed with Tab, Return and Escape alone. While the skip
    /// confirmation shows, Return confirms the skip and Escape goes back.
    @ViewBuilder
    private var askFooter: some View {
        Spacer()
        if ask.phase == .confirmingSkip {
            Button("Go back") { ask.cancelSkip() }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
            Button("Skip anyway") { if ask.skip() == .advance { goNext() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        } else {
            Button("Skip") { if ask.skip() == .advance { goNext() } }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
            Button("Continue") {
                Task { if await ask.primary() == .advance { goNext() } }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!ask.canSave)
        }
    }

    @ViewBuilder
    private var standardFooter: some View {
        Spacer()
        // OI-ON3: every step is skippable now. On Connect, Skip is "connect
        // later" — it exits to Done → Message List (which renders its own
        // no-account empty state) so a first-run user can look around before
        // committing an App Password, then connect from Settings.
        if canSkipCurrentStep {
            Button(skipLabel) { skip() }
                .buttonStyle(.borderless)
        }
        Button(primaryLabel) { advance() }
            .buttonStyle(.borderedProminent)
            .disabled(!canAdvance)
    }

    private var primaryLabel: String {
        switch step {
        case .welcome:               return "Get started"
        case .ask:                   return "Continue"
        case .connect:               return "Continue"
        case .preferences:           return "Continue"
        case .notificationPermission: return "Continue"
        case .done:                  return "Open Thresher"
        }
    }

    /// No step hard-gates advancement (OI-ON3). Connect used to require ≥1 account
    /// before you could continue; that stranded a first-run user who wanted to look
    /// around before committing an App Password. Now every step advances, and the
    /// Message List renders its own graceful no-account empty state ("No messages")
    /// — you connect later from Settings. Nothing here can block reaching the app.
    private var canAdvance: Bool { true }

    /// Preferences and the notification-permission stub are optional (Skip → next
    /// step). Connect is optional too (OI-ON3), but its Skip means "connect later"
    /// — it leaves the REST of onboarding and drops straight to Done, so the label
    /// and target differ (see footer + goNext).
    private var canSkipCurrentStep: Bool {
        switch step {
        case .connect, .preferences, .notificationPermission: return true
        default: return false
        }
    }

    /// The connect step's Skip is a "connect later" exit, not a step-forward — so
    /// it reads differently from the plain "Skip" on the optional prefs steps.
    private var skipLabel: String {
        step == .connect ? "Connect later" : "Skip"
    }

    // ── Step transitions ──────────────────────────────────────────────────────

    private func advance() {
        if step == .welcome { model.markTutorialSeen() }
        if step == .done { onFinished(); return }
        goNext()
    }

    /// Skip the current step. On Connect this is "connect later": jump past the
    /// remaining setup straight to Done (which already has friendly no-account copy
    /// and the hand-off to the Message List). Elsewhere it's a plain step-forward.
    private func skip() {
        if step == .connect {
            step = .done
        } else {
            goNext()
        }
    }

    private func goNext() {
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }

    /// Where Back goes, or nil when it is unavailable: never into the tutorial
    /// once it has been seen, and never into Ask once an account was connected
    /// in this run (D77). See `OnboardingFlow.previous`.
    private var previousStep: Step? {
        OnboardingFlow.previous(of: step, hasSeenTutorial: model.hasSeenTutorial,
                                connectedThisRun: connectedDuringRun)
    }

    private func goBack() {
        if let prev = previousStep { step = prev }
    }
}