//
//  LaunchRouter.swift
//  Thresher
//
//  The one launch-routing decision (§3), lifted out of RootView so it can be
//  tested without a window.
//
//  READINESS FIRST. The supervisor launches the backend and returns at once; it
//  does not wait for the API to listen. Measured on 2026-10-10: the app's first
//  request was refused at 09:33:03.249 and the API began serving at 09:33:03.740.
//  The refused account check read as "no accounts" (an existing user landed in
//  onboarding) and the Ask step's one-shot load fell into "Try again". So no
//  view-driven request is sent until `GET /health` answers — polled on its own
//  cadence with a deadline, whoever started the backend (this app, launchd, or
//  scripts/backend.sh).
//
//  NEVER "UNREACHABLE" AS "NO ACCOUNTS". A backend that never answers, or an
//  account check that fails, routes to `.unreachable` with a Retry — not to
//  onboarding, which only a successful empty answer may reach.
//

import Foundation
import Observation

@MainActor
@Observable
final class LaunchRouter {
    enum Route: Equatable {
        /// Waiting for the backend to answer, then for the account check.
        case starting
        /// The backend never answered, or the account check failed.
        case unreachable
        case onboarding
        case main
    }

    /// LATCHED once resolved. Onboarding mutates the very signals
    /// `shouldOnboard` reads — "Get started" marks the tutorial seen — so a
    /// re-derived route would yank the user out of the flow mid-step.
    private(set) var route: Route = .starting

    let onboardModel: OnboardingViewModel
    private let isBackendHealthy: @Sendable () async -> Bool
    private let readinessTimeout: Duration
    private let readinessInterval: Duration

    /// The live app's router. A separate no-argument init rather than default
    /// arguments: Swift 5.10's SILGen crashes evaluating defaults of this shape
    /// inside RootView's `@State` initializer.
    convenience init() {
        self.init(onboardModel: OnboardingViewModel(),
                  isBackendHealthy: { await APIClient().isHealthy() },
                  readinessTimeout: .seconds(15),
                  readinessInterval: .milliseconds(100))
    }

    init(onboardModel: OnboardingViewModel,
         isBackendHealthy: @escaping @Sendable () async -> Bool,
         readinessTimeout: Duration,
         readinessInterval: Duration) {
        self.onboardModel = onboardModel
        self.isBackendHealthy = isBackendHealthy
        self.readinessTimeout = readinessTimeout
        self.readinessInterval = readinessInterval
    }

    func resolve() async {
        route = .starting
        guard await waitForBackend() else {
            route = .unreachable
            return
        }
        await onboardModel.refreshAccounts()
        guard onboardModel.accountsLoaded else {
            NSLog("Launch: backend answered /health but the account check failed: %@",
                  onboardModel.errorMessage ?? "unknown error")
            route = .unreachable
            return
        }
        route = onboardModel.shouldOnboard ? .onboarding : .main
    }

    func retry() async {
        await resolve()
    }

    /// Poll `/health` until it answers or the deadline passes.
    private func waitForBackend() async -> Bool {
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: readinessTimeout)
        var probes = 0
        while !Task.isCancelled {
            probes += 1
            if await isBackendHealthy() {
                // The line Phase-3-style checks look for: every request before
                // it in the unified log is a health probe.
                NSLog("Launch: backend ready after %d probe(s), %@",
                      probes, "\(started.duration(to: clock.now))")
                return true
            }
            if clock.now >= deadline { break }
            try? await Task.sleep(for: readinessInterval)
        }
        NSLog("Launch: backend did not answer /health after %d probe(s) in %@",
              probes, "\(readinessTimeout)")
        return false
    }

    /// Onboarding finished: hand over to the main UI.
    func finishOnboarding() { route = .main }
}
