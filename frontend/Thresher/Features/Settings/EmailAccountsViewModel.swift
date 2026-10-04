//
//  EmailAccountsViewModel.swift
//  Thresher
//
//  State + loading for the Email Accounts section (Settings §4.1.3, 4.1).
//  @Observable / @MainActor, same pattern as MessageList/Detail; the SettingsAPI
//  it calls is Sendable, so the background Tasks are strict-concurrency clean
//  (D42).
//
//  Honors P1: disconnect removes the Keychain CREDENTIAL only — the section's
//  copy (in the view) makes clear it does NOT delete mail; stored messages stay
//  searchable. The model just calls the endpoint and reloads the list.
//

import Foundation
import Observation

@MainActor
@Observable
final class EmailAccountsViewModel {
    private(set) var accounts: [String] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// 503 from GET /accounts means the host can't run `security` (non-macOS).
    /// Distinct from a generic error so the view can show a calmer explanation.
    private(set) var accountsUnavailable = false

    /// Per-account "test connection" result, keyed by email. Drives the inline
    /// row status without a shared spinner clobbering other rows.
    private(set) var testResults: [String: TestState] = [:]

    /// OI31: the backend's ingestion health, so each row can say whether that
    /// mailbox is actually being POLLED — which is a different question from
    /// "Test connection", and the one a 13-day outage turns on.
    ///
    /// Test connection asks "can I log in right now?" and is user-initiated.
    /// This asks "is the poller alive and fetching?" and is passive. A mailbox
    /// can pass the first and fail the second — that is EXACTLY the 17-hour
    /// blind spot: the credential was fine the whole time, and nothing was
    /// being fetched.
    private(set) var health: AccountHealthReport?

    /// The health entry for one account, or nil if we have no report or the
    /// backend does not list it.
    func healthEntry(for account: String) -> AccountHealthEntry? {
        health?.accounts.first { $0.account == account }
    }

    enum TestState: Equatable {
        case testing
        case ok
        case failed(String)
    }

    private let api: SettingsAPI

    init(api: SettingsAPI) {
        self.api = api
    }

    // ── Load ────────────────────────────────────────────────────────────────

    func load() async {
        isLoading = true
        await reload()
        isLoading = false
    }

    private func reload() async {
        // Health first so a row never renders its account before we know its
        // status — one extra request on a screen the user opened deliberately.
        //
        // `try?` then DISCARD on failure, never clear to nil: "we couldn't ask"
        // is not "the account is fine", and blanking a warning we showed a
        // moment ago would flicker it off exactly when the backend is in
        // trouble. Same rule the message-list banner follows.
        if let report = try? await api.accountHealth() {
            health = report
        }
        do {
            accounts = try await api.listAccounts()
            accountsUnavailable = false
            errorMessage = nil
        } catch APIError.http(let status, _) where status == 503 {
            // `security` unavailable on this host — not a user error.
            accountsUnavailable = true
            accounts = []
            errorMessage = nil
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Called by AccountConnectView's onConnected — refresh so the new account
    /// appears in the list.
    func refreshAfterConnect() async {
        await reload()
    }

    // ── Disconnect (P1: credential only, never the mail) ──────────────────────

    func disconnect(_ email: String) async {
        do {
            try await api.disconnectAccount(email)
            testResults[email] = nil
            await reload()
        } catch APIError.http(let status, _) where status == 404 {
            // Already gone — reconcile by reloading rather than erroring.
            await reload()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    // ── Test connection (verify-only, the STORED credential) ──────────────────

    func testConnection(_ email: String) async {
        testResults[email] = .testing
        do {
            let result = try await api.verifyAccount(email)
            if result.ok {
                testResults[email] = .ok
            } else {
                testResults[email] = .failed(result.reason.failureMessage ?? "Verification failed.")
            }
        } catch {
            testResults[email] = .failed(
                (error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }
}