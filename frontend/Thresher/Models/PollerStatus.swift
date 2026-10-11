//
//  PollerStatus.swift
//  Thresher
//
//  OI43 — what the app knows about its own poller, for the surfaces that must
//  say so.
//
//  WHY THIS EXISTS
//  ---------------
//  After `maxRestarts` failed relaunches the supervisor stops relaunching the
//  poller, and mail and alerts stop with it. Until now the only record was a
//  line in `supervisor.log`: `hasGivenUp(on:)` was read by no view, and the
//  user heard nothing until the account heartbeat went stale about eleven
//  minutes later, in words that did not mention alerts. A poller that died
//  before its first poll was worse — it showed "Waiting for the first mail
//  check" indefinitely, which reads as normal.
//
//  App-lifetime, beside the supervisor that feeds it, for the reason the dock
//  badge monitor gives: a give-up while the window is closed is the case that
//  matters, so nothing here may depend on a window being open.
//

import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class PollerStatus {

    enum State: Equatable {
        /// The supervisor is relaunching the poller as needed (or does not own it).
        case running
        /// The supervisor gave up: nothing will fetch mail until a restart.
        case gaveUp
        /// The user pressed Restart at `since`; cleared by the first successful
        /// poll after that instant, not by the relaunch itself.
        case restarting(since: Date)
    }

    /// The live app's instance, wired to the supervisor in `AppDelegate`.
    static let shared = PollerStatus()

    private(set) var state: State = .running

    /// When the clock for "the first mail check is overdue" started: the most
    /// recent launch of the poller, or the most recent account connection.
    /// nil when this app did not start the poller (launchd owns it, say), in
    /// which case nothing is ever called overdue — we do not know when it began.
    private(set) var firstCheckClock: Date?

    /// Is the give-up banner up? True from the give-up until a poll succeeds.
    var isStopped: Bool { state != .running }

    /// Set by the wiring: relaunches the poller with a fresh restart budget.
    var restartPoller: (() -> Void)?

    private let fetchHealth: () async -> AccountHealthReport?
    private let confirmInterval: TimeInterval
    private var confirmTask: Task<Void, Never>?
    private var observers: [@MainActor () -> Void] = []

    init(fetchHealth: @escaping () async -> AccountHealthReport? = {
             try? await APIClient().accountHealth()
         },
         confirmInterval: TimeInterval = 5) {
        self.fetchHealth = fetchHealth
        self.confirmInterval = confirmInterval
    }

    /// The poller was launched — at start, after a crash, after an
    /// unconfigured exit, or by Restart. Each launch gets its own full
    /// threshold before its first check is called overdue.
    func pollerLaunched(at date: Date = Date()) {
        firstCheckClock = date
    }

    /// A mailbox was just connected. Its first check cannot have happened yet,
    /// however long the poller has been running.
    func accountConnected(at date: Date = Date()) {
        firstCheckClock = date
    }

    func pollerGaveUp() {
        confirmTask?.cancel()
        confirmTask = nil
        setState(.gaveUp)
    }

    /// The banner's Restart. Relaunches through the supervisor, then waits for
    /// a successful poll: a relaunched process is not yet a working one, and
    /// clearing on the relaunch would hide the next failure behind a banner
    /// that already said "fixed".
    func restart(at date: Date = Date()) {
        guard state == .gaveUp else { return }
        setState(.restarting(since: date))
        restartPoller?()
        confirmTask?.cancel()
        confirmTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.isRestarting {
                self.observe(await self.fetchHealth())
                guard self.isRestarting else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.confirmInterval * 1_000_000_000))
            }
        }
    }

    /// Feed a health report in. Every fetch anywhere in the app comes through
    /// here, so whichever loop sees the first good poll clears the banner.
    func observe(_ report: AccountHealthReport?, now: Date = Date()) {
        guard case .restarting(let since) = state, let report else { return }
        if report.hasSuccessfulPoll(after: since, now: now) {
            confirmTask?.cancel()
            confirmTask = nil
            setState(.running)
        }
    }

    /// Called on every state change — the dock badge, which must repaint at
    /// the give-up even with no window open.
    func addObserver(_ observer: @escaping @MainActor () -> Void) {
        observers.append(observer)
    }

    private var isRestarting: Bool {
        if case .restarting = state { return true }
        return false
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        observers.forEach { $0() }
    }
}

/// The one alert the app posts when the supervisor gives up on the poller.
@MainActor
struct PollerStoppedAlert {
    static let title = "Thresher stopped checking mail"
    static let body = "Alerts are paused until it restarts. Open Thresher to restart it."

    let deliver: @MainActor (UNNotificationRequest) async -> Void

    init(deliver: @escaping @MainActor (UNNotificationRequest) async -> Void) {
        self.deliver = deliver
    }

    /// Post the alert. The identifier carries the instant, so a later give-up
    /// is a new alert rather than a silent replacement of the first.
    func post(at date: Date = Date()) async {
        let content = UNMutableNotificationContent()
        content.title = Self.title
        content.body = Self.body
        let request = UNNotificationRequest(
            identifier: "thresher.poller.stopped.\(Int(date.timeIntervalSince1970))",
            content: content, trigger: nil)
        await deliver(request)
    }

    /// The live app's alert: the real notification center.
    static var live: PollerStoppedAlert {
        PollerStoppedAlert(deliver: { request in
            try? await UNUserNotificationCenter.current().add(request)
        })
    }
}

/// Connects a supervisor's events to the status and the alert. One function, so
/// the app and the tests exercise the same wiring.
@MainActor
enum PollerFailureWiring {
    static func connect(_ supervisor: BackendSupervisor,
                        to status: PollerStatus,
                        alert: PollerStoppedAlert) {
        // Exactly one alert per give-up: the supervisor reports a give-up once,
        // when it happens, and never again on the ticks that follow.
        supervisor.onGiveUp = { id in
            guard id == BackendSupervisor.pollerID else { return }
            status.pollerGaveUp()
            Task { @MainActor in await alert.post() }
        }
        supervisor.onPollerLaunched = { date in status.pollerLaunched(at: date) }
        status.restartPoller = { [weak supervisor] in
            supervisor?.restartAfterGiveUp(BackendSupervisor.pollerID)
        }
    }
}

extension AccountHealthReport {
    /// The report with any "never" account whose first check is overdue
    /// rewritten as "stale".
    ///
    /// "never" alone cannot tell a first check in progress from one that will
    /// not come: a poller that hangs or dies before its first poll showed
    /// "Waiting for the first mail check" indefinitely. The backend knows the
    /// threshold (`stale_after_seconds`, two intervals plus a minute) but not
    /// when the poller started; the app knows that. Past the threshold the entry
    /// becomes "stale", so every surface that reads health says so.
    ///
    /// With no clock — this app did not start the poller — nothing changes.
    func resolvingOverdueFirstChecks(clock: Date?, now: Date = Date()) -> AccountHealthReport {
        guard let clock else { return self }
        let threshold = TimeInterval(staleAfterSeconds
            ?? Preferences.defaultPollIntervalMinutes * 60 * 2 + 60)
        let waited = now.timeIntervalSince(clock)
        guard waited > threshold, accounts.contains(where: { $0.status == "never" })
        else { return self }
        let resolved = accounts.map { entry -> AccountHealthEntry in
            guard entry.status == "never" else { return entry }
            return AccountHealthEntry(
                account: entry.account, status: "stale", lastPollAt: nil,
                secondsSince: Int(waited),
                detail: "no poll in \(Int(waited) / 60) min since the poller started")
        }
        return AccountHealthReport(healthy: false, accounts: resolved,
                                   staleAfterSeconds: staleAfterSeconds)
    }

    /// Has any account completed a successful poll after `instant`?
    ///
    /// Uses `seconds_since`, which the backend computes against its own clock
    /// at the moment it answers, rather than parsing `last_poll_at`: no date
    /// format to get wrong, and `now` is when the answer arrived.
    func hasSuccessfulPoll(after instant: Date, now: Date = Date()) -> Bool {
        accounts.contains { entry in
            guard entry.isOK, let seconds = entry.secondsSince else { return false }
            return now.addingTimeInterval(-TimeInterval(seconds)) >= instant
        }
    }
}
