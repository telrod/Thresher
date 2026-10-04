//
//  AccountConnectView.swift
//  Thresher
//
//  REUSABLE connect-a-Gmail-account component. Lives under Settings because that
//  is where it first ships (§4.1.3 "Email Accounts"), but it is written to be
//  imported UNCHANGED by Onboarding (§4.1.4) — so it holds NO Settings-only
//  assumptions: it depends only on `SettingsAPI`, takes an `onConnected`
//  callback the host reacts to, and renders its own form + status. The host
//  decides what "connected" means next (Settings reloads the list; Onboarding
//  advances the flow).
//
//  store → verify, NOT the reverse (trap §1.8, confirmed by running):
//  `/accounts/verify` tests the credential ALREADY in the Keychain and ignores
//  any password in the body. So a NEW account must POST /accounts (store) FIRST,
//  THEN POST /accounts/verify. A post-store `auth_failed` means the stored
//  password is wrong — we tell the user exactly that and let them re-enter or
//  disconnect; we NEVER imply "connected" on a failed verify.
//
//  The App Password is a secret (P5-adjacent): it lives only in the secure-entry
//  @State field and is handed straight to `storeAccount`. We clear it the moment
//  the store call is dispatched — it is never logged, echoed, or retained past
//  the in-flight request. (The backend never returns it either.)
//

import SwiftUI

@MainActor
struct AccountConnectView: View {
    /// Called once the account is both stored AND verified-ok, with the email.
    /// The host owns what happens next (Settings reloads its list; Onboarding
    /// advances). Optional so a host that only needs the inline status can omit it.
    private let onConnected: (String) -> Void
    private let api: SettingsAPI

    @State private var email = ""
    /// The secret. Bound to a SecureField; wiped the instant we dispatch store.
    @State private var appPassword = ""
    @State private var phase: Phase = .idle
    /// D61 initial-backfill bound. Defaults to the middle option — the choice is
    /// ONE-WAY, so an over-narrow default is the unrecoverable mistake.
    @State private var window: RetrievalWindow = .default
    /// Per-window message counts from POST /accounts/preview, once fetched.
    @State private var preview: RetrievalPreview?
    @State private var isPreviewing = false
    /// Set when the preview call failed. Rendered as "couldn't check", NEVER as
    /// a count of zero — zero would read as "your mailbox is empty" at exactly
    /// the moment the user is deciding how much to import.
    @State private var previewFailed = false
    /// Auto-clear timer for the transient `.connected` banner. Held so a second
    /// connect (or teardown) can cancel a pending clear and avoid a race.
    @State private var clearTask: Task<Void, Never>?

    /// Explicit focus order so Tab steps email → App Password → Connect rather
    /// than detouring through a system AutoFill control (Bug 2). `.connect` lets
    /// us move focus off the fields onto the button after the password.
    @FocusState private var focus: Field?
    private enum Field: Hashable { case email, password }

    /// The connect state machine. `.verifying` and `.storing` are distinct so the
    /// status copy can say which step is in flight (store→verify, §1.8).
    ///
    /// `.connected` is a TRANSIENT success banner (auto-clears to `.idle` after a
    /// couple of seconds) — NOT a persistent state. That's the balance between
    /// the two failure modes seen in testing: a sticky badge went stale after a
    /// disconnect this component can't observe (it kept saying "Connected"); but
    /// removing the badge entirely left a successful connect with no positive
    /// feedback. A short-lived banner confirms the action and is gone before it
    /// could lie about current state.
    private enum Phase: Equatable {
        case idle
        case storing
        case verifying
        case connected
        case failed(String)     // user-facing message (never contains the secret)
    }

    init(api: SettingsAPI = APIClient(), onConnected: @escaping (String) -> Void = { _ in }) {
        self.api = api
        self.onConnected = onConnected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect a Gmail account")
                .font(.headline)

            TextField("you@example.com", text: $email)
                .textContentType(.username)
                .disableAutocorrection(true)
                .disabled(isBusy)
                .focused($focus, equals: .email)
                // Return in the email field advances to the password rather than
                // submitting — the form usually still needs the secret.
                .onSubmit { focus = .password }

            SecureField("Gmail App Password", text: $appPassword)
                // ⚠️ NO .textContentType(.password) (Bug 2): a "password" content
                // type makes macOS inject its Passwords AutoFill button into the
                // tab order (email → [Passwords] → …), skipping this field. A
                // Gmail App Password is NOT the user's login credential and must
                // not pull Keychain AutoFill suggestions, so we drop the
                // association entirely. Stays secure-entry (SecureField masks it).
                .disabled(isBusy)
                .focused($focus, equals: .password)
                // Return in the password field SUBMITS Connect when valid (Bug 1):
                // consuming Return here stops it from falling through to the
                // sheet's default "Done" button (which would dismiss). When the
                // form is invalid this is a no-op — Return does nothing, as asked.
                .onSubmit { submitFromReturn() }

            Text("Use a Gmail **App Password**, not your account password. It’s stored in your macOS Keychain and sent only to the local backend.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            // ── D61 retrieval window ────────────────────────────────────────
            // Offered at BOTH entry points because this component is shared by
            // Settings → Email accounts and Onboarding (see the file header).
            VStack(alignment: .leading, spacing: 6) {
                Picker("Retrieve mail from:", selection: $window) {
                    ForEach(RetrievalWindow.allCases) { w in
                        Text(w.label).tag(w)
                    }
                }
                .disabled(isBusy)

                // The consequence in messages, not adjectives (§6.3).
                Text(window.consequence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                windowCountLabel

                Text(RetrievalWindow.mailboxScopeNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await connect() }
                } label: {
                    if isBusy { ProgressView().controlSize(.small) }
                    Text("Connect")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)

                statusLabel
            }
        }
        .padding(.vertical, 4)
    }

    /// The size preview: "About 3,311 messages will be retrieved."
    ///
    /// §6.4 calls this "the single most useful sentence this feature can show",
    /// and it is only useful if it is honest — so a failed check says so rather
    /// than rendering zero, and the count is only shown for the window it was
    /// actually measured for.
    @ViewBuilder
    private var windowCountLabel: some View {
        HStack(spacing: 8) {
            if isPreviewing {
                ProgressView().controlSize(.small)
                Text("Checking your mailbox…").font(.caption).foregroundStyle(.secondary)
            } else if previewFailed {
                Label("Couldn’t check the size of your mailbox — you can still connect.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let n = preview?.count(for: window) {
                Label("About \(n) message\(n == 1 ? "" : "s") will be retrieved.",
                      systemImage: window == .everything && n > 500
                          ? "exclamationmark.triangle.fill" : "tray.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(window == .everything && n > 500 ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Check how much mail this is") {
                    Task { await runPreview() }
                }
                .controlSize(.small)
                .disabled(!canSubmit)
            }
        }
    }

    /// Ask the backend how many messages each window would retrieve. Read-only
    /// and stores nothing — see POST /accounts/preview. Never blocks connecting:
    /// a failure is reported and the Connect button stays live, because refusing
    /// to connect over a failed *preview* would be the tail wagging the dog.
    private func runPreview() async {
        let account = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, !appPassword.isEmpty else { return }
        isPreviewing = true
        previewFailed = false
        defer { isPreviewing = false }
        do {
            preview = try await api.previewRetrieval(email: account, appPassword: appPassword)
        } catch {
            preview = nil
            previewFailed = true
        }
    }

    // ── Status line ───────────────────────────────────────────────────────────

    @ViewBuilder
    private var statusLabel: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .storing:
            Label("Storing credential…", systemImage: "key").font(.caption).foregroundStyle(.secondary)
        case .verifying:
            Label("Verifying with Gmail…", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption).foregroundStyle(.secondary)
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // ── Derived state ───────────────────────────────────────────────────────

    private var isBusy: Bool { phase == .storing || phase == .verifying }

    private var canSubmit: Bool {
        !isBusy
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appPassword.isEmpty
    }

    /// Return-key submit (Bug 1). Only fires when the form is valid; otherwise a
    /// no-op (Return does nothing on an incomplete form, as specified). Moves
    /// focus off the field so the keyboard isn't left in a stale text context
    /// while the request runs.
    private func submitFromReturn() {
        guard canSubmit else { return }
        focus = nil
        Task { await connect() }
    }

    // ── store → verify (§1.8) ─────────────────────────────────────────────────

    /// The store→verify sequence, extracted from the view so it is testable.
    ///
    /// A SwiftUI `View`'s `@State` is not reachable from a unit test, so leaving
    /// this inline would have meant either no coverage or a test-only hook bolted
    /// onto the view. Neither is good: the OI14 lesson is that a test pinning the
    /// wrong surface reads as coverage without being it. The sequencing rule this
    /// protects — store BEFORE verify (§1.8), because verify tests the STORED
    /// credential and ignores any password in the body — is exactly the kind of
    /// ordering that a refactor silently inverts.
    ///
    /// Returns the verify result; throws only if the STORE failed (the caller
    /// distinguishes "couldn't store" from "stored but wouldn't verify").
    @discardableResult
    static func performConnect(api: SettingsAPI, account: String, secret: String,
                               window: RetrievalWindow?) async throws -> VerifyResult {
        try await api.storeAccount(email: account, appPassword: secret,
                                   retrievalWindow: window)
        return try await api.verifyAccount(account)
    }

    private func connect() async {
        let account = email.trimmingCharacters(in: .whitespacesAndNewlines)
        // Capture the secret locally, then WIPE the field immediately — it does
        // not live in view state past this dispatch.
        let secret = appPassword
        appPassword = ""

        // Cancel any pending banner auto-clear from a prior connect so it can't
        // fire mid-flight (the .connected guard would already protect us, but
        // cancelling keeps the timer from lingering).
        clearTask?.cancel()

        // 1) Store the App Password (Keychain write — the only side effect).
        phase = .storing
        do {
            try await api.storeAccount(email: account, appPassword: secret,
                                       retrievalWindow: window)
        } catch {
            phase = .failed(storeErrorMessage(error))
            return
        }

        // 2) Verify the STORED credential (it takes no password — §1.8).
        phase = .verifying
        do {
            let result = try await api.verifyAccount(account)
            if result.ok {
                // Hand off to the host (the account row is the authoritative
                // confirmation), clear the form for the next account, and show a
                // brief green "Connected" banner that auto-clears (see Phase doc:
                // transient so it can't go stale after a disconnect this component
                // can't observe). The email field clears so the banner isn't read
                // as "this address, still connected".
                // Poll NOW rather than at the supervisor's next 30s tick. On
                // first run the poller is not running at this moment (it exits
                // while unconfigured), so without this the user watches a blank
                // list for up to 30 seconds — measured at 24s on a real cold
                // start, against a fetch that took 5.
                //
                // AFTER verification, never before: a credential that failed to
                // verify should not trigger a poll that can only fail too.
                AppDelegate.backendShouldPollNow()

                onConnected(account)
                email = ""
                focus = nil
                // The next account is a different mailbox: a stale count would
                // describe the one just connected. The window resets to the
                // default rather than persisting the last choice, since it is a
                // per-account, one-way decision.
                preview = nil
                previewFailed = false
                window = .default
                phase = .connected
                scheduleConnectedBannerClear()
            } else {
                // Stored but the credential failed. Be explicit that it is NOT
                // connected and how to recover — never leave them thinking it is.
                phase = .failed(result.reason.failureMessage ?? "Verification failed.")
            }
        } catch {
            // The credential IS stored, but we couldn't verify it (transport/HTTP).
            // Say so honestly — they can retry verify from the account row.
            phase = .failed("Stored the credential, but couldn’t verify it: "
                            + ((error as? APIError)?.errorDescription ?? error.localizedDescription))
        }
    }

    /// Auto-clear the transient `.connected` banner back to `.idle` after a short
    /// delay. Cancels any prior pending clear so rapid successive connects don't
    /// race, and only resets if we're STILL `.connected` — a new connect attempt
    /// (`.storing`) or a later `.failed` must not be clobbered back to idle.
    private func scheduleConnectedBannerClear() {
        clearTask?.cancel()
        clearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)   // 2.5s
            guard !Task.isCancelled, phase == .connected else { return }
            phase = .idle
        }
    }

    /// Map a store-step failure to copy. 502 is the Keychain-write error the
    /// backend returns; anything else is transport/unexpected.
    private func storeErrorMessage(_ error: Error) -> String {
        if case APIError.http(let status, _) = error, status == 502 {
            return "Couldn’t save to the Keychain. Try again."
        }
        return (error as? APIError)?.errorDescription ?? error.localizedDescription
    }
}