//
//  EmailAccountsSection.swift
//  Thresher
//
//  Settings §4.1.3 "Email Accounts": list connected accounts, per-row Test
//  connection (verify-only) + Disconnect (behind a confirm), and the reusable
//  AccountConnectView for adding a new one.
//
//  P1 in the copy: the disconnect confirmation makes explicit that it removes the
//  stored CREDENTIAL, not the mail — existing messages stay searchable. The
//  backend DELETE /accounts touches the Keychain only.
//

import SwiftUI

@MainActor
struct EmailAccountsSection: View {
    @State private var model: EmailAccountsViewModel
    private let api: SettingsAPI

    /// The account a pending disconnect confirmation targets (nil = no dialog).
    @State private var pendingDisconnect: String?

    /// D67/OI33: whether the D66 launchd agents are installed. Read once on
    /// appear; the control only exists when there is something to stop.
    @State private var backgroundPollingInstalled = false
    @State private var backgroundPollingNote: String?
    @State private var backgroundPollingFailed = false

    init(api: SettingsAPI = APIClient()) {
        self.api = api
        _model = State(initialValue: EmailAccountsViewModel(api: api))
    }

    var body: some View {
        Section("Email Accounts") {
            if model.accountsUnavailable {
                Label("Account management isn’t available on this host.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else if model.accounts.isEmpty && !model.isLoading {
                Text("No accounts connected yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.accounts, id: \.self) { account in
                    accountRow(account)
                }
            }

            backgroundPollingControl

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }

            // The reusable connect component — refresh the list on success.
            AccountConnectView(api: api) { _ in
                Task { await model.refreshAfterConnect() }
            }
            .padding(.top, 4)
        }
        .task {
            backgroundPollingInstalled = BackgroundPolling().isSupervised
            await model.load()
        }
        .confirmationDialog(
            "Disconnect \(pendingDisconnect ?? "")?",
            isPresented: disconnectDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                if let account = pendingDisconnect {
                    Task { await model.disconnect(account) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // P1: be explicit — this removes the credential, NOT the mail.
            Text("This removes the stored App Password for this account. Your already-received messages stay in Thresher and remain searchable — only future polling stops.")
        }
    }

    // ── Background polling (D67 / OI33) ──────────────────────────────────────

    /// The off switch for the D66 always-on backend.
    ///
    /// Lives in the Email accounts pane rather than a new sidebar row: it is
    /// about whether these mailboxes are being polled, so it belongs beside
    /// them — and D43/D47 pin the sidebar's row order with a guard test, which a
    /// sixth row would amend for no gain in findability.
    ///
    /// Shown ONLY when the agents are actually installed. A permanent "stop
    /// background polling" control on a machine with no agents is an offer to
    /// fix a problem the user does not have.
    @ViewBuilder
    private var backgroundPollingControl: some View {
        if backgroundPollingInstalled {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Label("Mail is being checked in the background",
                      systemImage: "clock.arrow.circlepath")
                    .font(.callout)

                Text("Thresher is polling your mailboxes even when this app "
                     + "is closed, and starts again when you log in. Stopping it "
                     + "keeps all your mail and settings — new mail is simply "
                     + "fetched only while the app is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Stop background polling") { stopBackgroundPolling() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    if let note = backgroundPollingNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(backgroundPollingFailed ? .red : .green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func stopBackgroundPolling() {
        do {
            try BackgroundPolling().disable()
            // Re-read rather than assuming: the control must reflect what is
            // actually loaded, not what we asked for.
            backgroundPollingInstalled = BackgroundPolling().isSupervised
            backgroundPollingFailed = backgroundPollingInstalled
            backgroundPollingNote = backgroundPollingInstalled
                ? "Some agents are still running — see Terminal."
                : "Stopped. Mail is fetched while the app is open."
        } catch {
            // Never report success we did not verify: "stopped" while it is
            // still polling is the most harmful thing this control could say.
            backgroundPollingFailed = true
            backgroundPollingNote = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // ── Account row ───────────────────────────────────────────────────────────

    @ViewBuilder
    private func accountRow(_ account: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(account, systemImage: "envelope")
                Spacer()
                testStatus(for: account)
                Button("Test connection") {
                    Task { await model.testConnection(account) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.testResults[account] == .testing)

                Button("Disconnect", role: .destructive) {
                    pendingDisconnect = account
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // OI31: is this mailbox actually being POLLED? A different question
            // from "Test connection" (can I log in?), and the one the 13-day
            // outage turned on — the credential was valid throughout while
            // nothing was being fetched. Shown per row because the 17-hour
            // blind spot was ONE dead account beside a healthy one.
            ingestionStatus(for: account)
        }
        .padding(.vertical, 2)
    }

    /// Per-account ingestion status line. Silent when the account is polling
    /// normally: a row that says "ok" beside every healthy mailbox trains the
    /// eye to skip the line, which is the opposite of what a warning needs.
    @ViewBuilder
    private func ingestionStatus(for account: String) -> some View {
        if let entry = model.healthEntry(for: account), !entry.isOK {
            Label(
                AccountHealthVerdict.sentence(for: entry,
                                              totalAccounts: model.accounts.count),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .help(entry.detail.isEmpty ? entry.status : entry.detail)
        }
    }

    @ViewBuilder
    private func testStatus(for account: String) -> some View {
        switch model.testResults[account] {
        case .testing:
            ProgressView().controlSize(.small)
        case .ok:
            Label("OK", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly).foregroundStyle(.green)
                .help("Connection verified")
        case .failed(let message):
            Label("Failed", systemImage: "xmark.circle.fill")
                .labelStyle(.iconOnly).foregroundStyle(.red)
                .help(message)
        case nil:
            EmptyView()
        }
    }

    private var disconnectDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDisconnect != nil },
            set: { if !$0 { pendingDisconnect = nil } }
        )
    }
}