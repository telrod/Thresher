//
//  DockBadgeMonitor.swift
//  Thresher
//
//  The dock badge's own heartbeat — app-lifetime, not window-lifetime.
//
//  WHY THIS EXISTS (human gate, 2026-09-01, item 1.4 — FAILED).
//
//  OI31 put a `!` on the dock badge because the badge "is the only surface
//  visible with the window closed". It was wired as two `.onChange` observers
//  on `MessageListView`, fed by `MessageListViewModel.accountHealth`, whose
//  refresh loop is started in `.task` and cancelled in
//  `.onDisappear { model.cancelAll() }`.
//
//  So closing the window — the exact condition the feature was built for —
//  tore down the loop that feeds it. The badge froze at whatever it last
//  rendered. At the keyboard: the poller was stopped, the window closed, and
//  the badge sat at "3" for fifteen minutes and never grew its `!`.
//
//  SIXTEEN unit tests covered `DockBadge.label` and all sixteen passed, because
//  every one of them called the pure function directly. The function was never
//  wrong. What was wrong was whether anything CALLED it once the window went
//  away — which no test asked, and which is the fourth occurrence of the OI14
//  pattern here (model-level green, render-level broken).
//
//  THE RULE THIS ENCODES: a surface that exists for when the window is closed
//  must not depend on the window. Its liveness belongs to the app, beside the
//  notification poller and the backend supervisor, not to a view.
//
//  Deliberately NOT merged into MessageListViewModel: that model's whole
//  lifecycle is the window's, correctly so — it renders a list nobody is
//  looking at otherwise. This is the one fact that outlives the view.
//

import Foundation
import AppKit

/// Keeps the dock badge truthful for as long as the app is running.
///
/// Polls `GET /health/accounts` on the D49 cadence and repaints the badge.
/// The urgent COUNT still comes from the list model when a window is open —
/// this owns the half that must survive the window closing.
@MainActor
final class DockBadgeMonitor {

    private let api: MessageAPI
    private var task: Task<Void, Never>?

    /// Last health we successfully fetched. Held here rather than read from the
    /// list model so a closed window (no model updates) still has an answer.
    private(set) var health: AccountHealthReport?

    /// The urgent count, pushed in by the list model while a window is open.
    ///
    /// Not fetched here: `/messages/counts` is the list's concern and refetching
    /// it on a second cadence would double the request rate for a number that is
    /// already arriving. With the window closed the count cannot change in a way
    /// the user can act on anyway — but a poller dying still can, which is the
    /// asymmetry this whole class exists for.
    private(set) var urgentNew: Int = 0

    init(api: MessageAPI) { self.api = api }

    /// Push the count in from the list model (window open). Repaints immediately.
    func updateUrgentCount(_ count: Int) {
        urgentNew = count
        repaint()
    }

    /// Adopt health the list model already fetched, so an open window doesn't
    /// wait a full cadence for this loop's first tick. Same discard-on-failure
    /// discipline as the model: we only ever move to a KNOWN state.
    func adopt(health report: AccountHealthReport?) {
        guard let report else { return }
        health = report
        repaint()
    }

    /// Start the app-lifetime loop. Idempotent — a second call replaces the first.
    func start() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tick()
                // Same cadence rule as the list (D49): re-read the interval every
                // pass so a Settings change applies at the next tick. A dead
                // backend falls back to the default rather than spinning.
                var interval = TimeInterval(Preferences.defaultPollIntervalMinutes * 60)
                if let prefs = try? await self.api.preferences() {
                    interval = prefs.pollIntervalSeconds
                }
                let period = MessageListViewModel.refreshPeriod(forPollInterval: interval)
                try? await Task.sleep(nanoseconds: UInt64(period * 1_000_000_000))
            }
        }
    }

    /// One health fetch + repaint. Separated so a test can drive it without a timer.
    func tick() async {
        // DISCARD on failure rather than clearing to nil — identical to the list
        // model's reasoning: "we couldn't ask" is not "the account is fine", and
        // blanking a warning shown a moment ago would flicker it off exactly when
        // the backend is struggling.
        if let report = try? await api.accountHealth() {
            health = report
        }
        repaint()
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// The ONE derivation, shared with the window-open path: `DockBadge.label`.
    /// A second rule here would drift from the banner's, and two surfaces
    /// disagreeing about whether mail is arriving is worse than one saying
    /// nothing.
    private func repaint() {
        NSApp.dockTile.badgeLabel = DockBadge.label(urgentNew: urgentNew, health: health)
    }
}
