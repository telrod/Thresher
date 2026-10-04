//
//  OnboardingViewModel.swift
//  Thresher
//
//  State for the first-run flow (§4.1.4) and the single launch-routing decision
//  (§3). Two independent signals decide first-run, deliberately from different
//  sources (trap §1.4):
//
//   - connect-needed  = DERIVED from `GET /accounts` == []  (the Keychain is the
//                       account registry, D41 — never a local flag that can
//                       desync from reality).
//   - tutorial-seen   = a LOCAL `UserDefaults` flag, so a returning user who
//                       disconnected all accounts isn't re-taught the basics.
//
//  Routing rule (§3): show Onboarding if accounts is empty OR the tutorial was
//  never seen; otherwise go straight to the Message List. Kept in ONE decision
//  (`shouldOnboard`) rather than scattered across views.
//
//  @Observable / @MainActor, SettingsAPI is Sendable (D42).
//

import Foundation
import Observation

@MainActor
@Observable
final class OnboardingViewModel {
    /// Connected accounts, refreshed from the API. Empty ⇒ connect-needed (§1.4).
    private(set) var accounts: [String] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// True once the initial `GET /accounts` has resolved (so routing waits for a
    /// real answer instead of racing on the empty default).
    private(set) var didResolveAccounts = false

    private let api: SettingsAPI
    private let defaults: UserDefaults

    /// UserDefaults key for the has-seen-tutorial flag (§1.4). A native-app local
    /// flag is fine here — this isn't a sandboxed artifact.
    static let tutorialSeenKey = "onboarding.tutorialSeen"

    init(api: SettingsAPI = APIClient(), defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
    }

    // ── Tutorial-seen (local flag) ────────────────────────────────────────────

    var hasSeenTutorial: Bool {
        get { defaults.bool(forKey: Self.tutorialSeenKey) }
        set { defaults.set(newValue, forKey: Self.tutorialSeenKey) }
    }

    // ── Connect-needed (derived from the API) ─────────────────────────────────

    var connectNeeded: Bool { accounts.isEmpty }

    /// The single routing decision (§3): onboard when there are no accounts OR the
    /// tutorial has never been shown. Callers must await `refreshAccounts()` first
    /// so this reflects the real registry, not the empty default.
    var shouldOnboard: Bool { connectNeeded || !hasSeenTutorial }

    // ── Load / refresh ────────────────────────────────────────────────────────

    func refreshAccounts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            accounts = try await api.listAccounts()
            errorMessage = nil
        } catch {
            // If the host can't list accounts (e.g. account mgmt unavailable), we
            // surface the error but do NOT fabricate a connected state — an empty
            // list on error keeps the user in the connect step rather than falsely
            // advancing them past it.
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
        didResolveAccounts = true
    }

    func markTutorialSeen() { hasSeenTutorial = true }
}