//
//  NotificationManager.swift
//  Thresher
//
//  Native notification delivery (§4.3 / D45). The app-side half of the D45
//  coexistence hand-off: while this manager is running and holds notification
//  permission, it CLAIMS delivery from the backend (a short-TTL heartbeat), polls
//  GET /notifications for the rows the backend deferred to it, and posts them as
//  native UNUserNotificationCenter banners — which, unlike the backend's osascript
//  banners, can deep-link back into the app (click-to-open, commit 3).
//
//  Why a claim + poll rather than push: the backend already owns all the alerting
//  judgment (dedup, quiet hours, mode gating, the Tier-1 invariant — D45 question
//  A1), so the app is a pure renderer of decisions the backend already made and
//  logged. It checks every 30s, the same pass as its heartbeat (D85); there is
//  no websocket. If the app quits, the claim goes stale within 90s and the
//  backend's osascript resumes — the Tier-1 floor never depends on the app
//  staying up.
//
//  Delivery cursor: the highest notification_log id we've processed, persisted in
//  UserDefaults so a relaunch doesn't re-post old alerts. The server returns a
//  `cursor` that advances past non-app rows too, so each app row fires once.
//

import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class NotificationManager: NSObject {
    /// Authorization state, surfaced so onboarding / settings can reflect it.
    enum Authorization: Equatable {
        case notDetermined, denied, authorized
    }
    private(set) var authorization: Authorization = .notDetermined

    /// A message id from a tapped notification, waiting to be routed into the
    /// split-view selection (click-to-open, §4.1.2 / D45). The main window observes
    /// this and applies it, then calls `consumePendingMessage()`. Held here (not
    /// delivered directly) so a COLD-START click — where the delegate fires before
    /// RootView has shown MainWindowView — isn't dropped: the id waits until the
    /// window appears and reads it.
    private(set) var pendingMessageID: String?

    private let api: MessageAPI
    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults

    /// How often the app tells the backend it is still alive.
    ///
    /// FIXED, and deliberately NOT derived from the poll interval. D49 derived
    /// the claim TTL from the cadence that refreshed it, which meant the app
    /// checked in only once per poll interval — every ~301s at 5 minutes, and
    /// every 900s at the 15-minute maximum. No backend freshness window can both
    /// keep a live app claiming at 15 minutes and notice a quit one promptly, so
    /// on 2026-09-06 an app that quit at 06:48 was still trusted at 06:57 and a
    /// Tier 1 alert reached nobody.
    ///
    /// The backend owns the staleness threshold (CLAIM_STALE_SECONDS = 90, three
    /// missed beats). Heartbeating is one small PUT to localhost, so a fixed 30s
    /// costs nothing and is independent of how often mail is fetched.
    static let heartbeatSeconds: TimeInterval = 30

    /// Retained for source compatibility with existing call sites/tests; the
    /// backend no longer reads an app-computed TTL (see `claimDelivery`).
    static func claimTTL(forPollInterval interval: TimeInterval) -> Int {
        Int(heartbeatSeconds)
    }
    static let cursorKey = "notifications.cursor"

    /// Set from the actual cadence in start(); default-derived so a direct
    /// tick() (tests) still claims with a cadence-consistent TTL.
    private(set) var claimTTLSeconds =
        claimTTL(forPollInterval: TimeInterval(Preferences.defaultPollIntervalMinutes * 60))

    /// D49 fast path (E21): called after a tick that posted ≥1 banner, so the
    /// window owner can refresh the message list in step with the banner — new
    /// T1/T2 mail renders when its banner fires, and the two never disagree.
    var onDeliveredNewMail: (() -> Void)?

    private var pollTask: Task<Void, Never>?

    /// Seams for tests: the cadence (seconds, not 30), the permission answer
    /// (the test host's own is whatever macOS has on record), and where a
    /// banner goes (the real center posts a real banner — OI45).
    private let checkInterval: TimeInterval
    private let authorizationOverride: (@MainActor () async -> Authorization)?
    private let deliverOverride: (@MainActor (UNNotificationRequest) async -> Void)?

    /// The live app's manager. A separate init rather than defaulted closure
    /// arguments: Swift 5.10's SILGen crashes on defaults of that shape inside
    /// an `@State` initializer (see LaunchRouter).
    convenience init(api: MessageAPI = APIClient(),
                     center: UNUserNotificationCenter = .current(),
                     defaults: UserDefaults = .standard) {
        self.init(api: api, center: center, defaults: defaults,
                  checkInterval: Self.heartbeatSeconds,
                  authorization: nil, deliver: nil)
    }

    init(api: MessageAPI,
         center: UNUserNotificationCenter,
         defaults: UserDefaults,
         checkInterval: TimeInterval,
         authorization: (@MainActor () async -> Authorization)?,
         deliver: (@MainActor (UNNotificationRequest) async -> Void)?) {
        self.api = api
        self.center = center
        self.defaults = defaults
        self.checkInterval = checkInterval
        self.authorizationOverride = authorization
        self.deliverOverride = deliver
        super.init()
        // Become the delegate so taps route into the app (commit 3) and banners
        // present even while the app is foregrounded.
        center.delegate = self
    }

    /// Read and clear the pending deep-link id. The main window calls this once it
    /// has applied the id to its selection, so a later appear doesn't re-navigate.
    func consumePendingMessage() -> String? {
        defer { pendingMessageID = nil }
        return pendingMessageID
    }

    // ── Permission (replaces the OI-ON1 inert stub) ───────────────────────────

    /// Reflect the current OS authorization without prompting (call on appear).
    func refreshAuthorization() async {
        if let authorizationOverride {
            authorization = await authorizationOverride()
            return
        }
        let settings = await center.notificationSettings()
        authorization = Self.map(settings.authorizationStatus)
    }

    /// Request notification permission (the real ask, wired from onboarding now
    /// that there's a consumer — D45). Idempotent: if already decided, this
    /// just reflects the existing status rather than re-prompting.
    @discardableResult
    func requestAuthorization() async -> Authorization {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            authorization = granted ? .authorized : .denied
        } catch {
            // A request error (rare) is treated as not-authorized; the backend
            // osascript path still covers delivery, so we degrade gracefully.
            authorization = .denied
        }
        return authorization
    }

    private static func map(_ status: UNAuthorizationStatus) -> Authorization {
        switch status {
        case .notDetermined:                   return .notDetermined
        case .denied:                          return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default:                       return .notDetermined
        }
    }

    // ── Delivery loop (check in → fetch → post, every 30s) ─────────────────────

    /// Start delivering natively. No-op unless authorized — without permission
    /// the backend keeps delivering and we never claim.
    ///
    /// ONE loop on the fixed heartbeat cadence (D85), each pass checking in AND
    /// fetching. Fetching only once per mail poll made a Tier 1 wait up to a
    /// whole poll interval for its banner — 3m55s measured on 2026-10-11 —
    /// where osascript, which this replaces, posts at once. One loop rather than
    /// a heartbeat loop plus a poll loop: the heartbeat is always at least as
    /// frequent, two loops calling `tick()` would read the same cursor and post
    /// the same rows, and claiming without fetching (which the separate
    /// heartbeat could do) defers alerts to an app that never shows them.
    ///
    /// `pollInterval` no longer sets any cadence here; it is kept for the call
    /// site and the claim TTL accessor.
    func start(pollInterval: TimeInterval) {
        claimTTLSeconds = Self.claimTTL(forPollInterval: pollInterval)
        stop()
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshAuthorization()
            while !Task.isCancelled {
                if self.authorization == .authorized {
                    await self.tick()
                }
                try? await Task.sleep(nanoseconds: UInt64(self.checkInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One delivery cycle: refresh the claim (so the backend keeps deferring to
    /// us), fetch new rows, post each as a native banner, advance the cursor.
    /// Best-effort — a transport error just skips this cycle; the backend still
    /// covers delivery, so a missed poll never drops an alert.
    func tick() async {
        // Check in on every pass: this IS the 30s heartbeat (D85), so the claim
        // and the fetch that honours it always happen together.
        try? await api.claimDelivery(forSeconds: claimTTLSeconds)

        let since = defaults.integer(forKey: Self.cursorKey)   // 0 if unset
        guard let feed = try? await api.notifications(since: since) else { return }

        for item in feed.notifications {
            await post(item)
        }
        // D49 fast path: banners mean new mail — let the list refresh in step.
        if !feed.notifications.isEmpty {
            onDeliveredNewMail?()
        }
        // Advance even when nothing was postable, so non-app rows aren't re-scanned.
        if feed.cursor > since {
            defaults.set(feed.cursor, forKey: Self.cursorKey)
        }
    }

    private func post(_ item: NotificationItem) async {
        let content = UNMutableNotificationContent()
        content.title = item.title ?? "Thresher"
        if let text = item.text { content.body = text }
        content.sound = nil   // ambient (P2); the backend decides sound, not us
        // Carry the message id so a click can deep-link to it (commit 3). Absent
        // for a digest row — the click will fall back to just opening the app.
        if let mid = item.messageID {
            content.userInfo = ["message_id": mid]
        }
        // One request per log id → dedupe identifier, so even a double-tick can't
        // post the same alert twice.
        let request = UNNotificationRequest(
            identifier: "thresher.notification.\(item.id)",
            content: content, trigger: nil)
        if let deliverOverride {
            await deliverOverride(request)
        } else {
            try? await center.add(request)
        }
    }

    /// Record a tapped notification's message id for the window to pick up. Split
    /// out so the delegate (a nonisolated system callback) has a single main-actor
    /// entry point.
    fileprivate func handleTappedMessage(_ messageID: String) {
        pendingMessageID = messageID
    }
}

// ── UNUserNotificationCenterDelegate (click-to-open, §4.1.2 / D45) ────────────
//
// The delegate methods are nonisolated system callbacks; each hops to the main
// actor to touch @Observable state. `didReceive` is the click: it pulls the
// message_id we stamped into userInfo at post time and stashes it as the pending
// deep link (MainWindowView applies it to the split-view selection). `willPresent`
// lets a banner show even while the app is frontmost, so foreground alerts aren't
// silently swallowed.
extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let messageID = userInfo["message_id"] as? String else { return }
        await MainActor.run { self.handleTappedMessage(messageID) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]   // show even when foregrounded (ambient, P2 — no sound here)
    }
}