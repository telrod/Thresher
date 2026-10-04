//
//  NotificationsViewModel.swift
//  Thresher
//
//  State + load/save for the shared Notifications & mode editor
//  (NotificationsSection). Backs BOTH the Settings §4.3 "Notifications" pane and
//  Onboarding's "initial preferences" step (§4.1.4) — the editor is written once
//  and reused, so this model holds no host-specific assumptions.
//
//  Two preference surfaces, deliberately separate (NotificationPrefs.swift trap
//  §1.4): quiet-hours + audio bind to the TYPED /preferences/notifications
//  surface; operating mode lives in the generic flat map and is written one key
//  at a time via PUT /preferences/<key>. This model owns both so a single editor
//  view can present them together without knowing they come from two endpoints.
//
//  @Observable / @MainActor, same pattern as EmailAccountsViewModel /
//  RulesViewModel; the SettingsAPI it calls is Sendable, so its background Tasks
//  are strict-concurrency clean (D42).
//

import Foundation
import Observation

@MainActor
@Observable
final class NotificationsViewModel {
    // ── Editable state (bound by the view) ────────────────────────────────────
    //
    // Quiet hours are held as "HH:MM" strings (server's stored shape) or "" when
    // unset. The empty-string-unsets contract (NotificationPrefs trap §1.5) is
    // applied at save time, not here — the view just edits text/toggles.

    var quietHoursStart = ""
    var quietHoursEnd = ""
    var audioAlerts = false
    var operatingMode: OperatingMode = .focus

    /// How often the backend polls IMAP, in minutes (polish batch 2, Part A).
    ///
    /// The pref was already read by the poller AND already drove the app's own
    /// cadence (D49: refresh at interval/2, claim TTL at 2×interval+30s) — it
    /// simply had no control, so it was settable only by curl. Held unclamped
    /// here so the stepper edits freely; `save()` clamps, which keeps the
    /// clamping in ONE place rather than fighting the binding mid-edit.
    var pollIntervalMinutes = Preferences.defaultPollIntervalMinutes

    /// The supported range, matching `_validate_preference` in api/app.py.
    /// Client and server both enforce it: a control that can express a value the
    /// server rejects is a control whose save silently fails.
    static let pollIntervalRange = 1...15

    // ── Unsaved-changes tracking (human gate 3.1) ─────────────────────────────
    //
    // WHY: at the keyboard this section read as BROKEN. The stepper updates its
    // own label instantly — "Check every 1 minute" — so it looks like a live
    // control, but nothing is persisted until the "Save preferences" button in a
    // separate Section further down. Leaving and returning showed 5 again, and
    // the gate recorded "Fail. It goes back to 5 minutes after saving" twice.
    //
    // The API log settles what happened: TWO attempted changes (1, then 15)
    // produced exactly ONE PUT. The backend was never wrong — it stores and
    // returns whatever it is sent. The control simply never said that an edit
    // was pending, so the save was made on the wrong value and the rest looked
    // like data loss.
    //
    // Deliberately NOT fixed by auto-saving on every stepper click: that would
    // fire a PUT per increment (1→15 is fourteen writes), and each one changes
    // the poller's cadence and the app's own refresh. An explicit save is right;
    // it just has to be VISIBLE that one is owed.

    /// The last values known to be persisted. `nil` until the first load.
    private var savedSnapshot: Snapshot?

    private struct Snapshot: Equatable {
        var quietHoursStart: String
        var quietHoursEnd: String
        var audioAlerts: Bool
        var operatingMode: OperatingMode
        var pollIntervalMinutes: Int
    }

    private var currentSnapshot: Snapshot {
        Snapshot(quietHoursStart: quietHoursStart,
                 quietHoursEnd: quietHoursEnd,
                 audioAlerts: audioAlerts,
                 operatingMode: operatingMode,
                 pollIntervalMinutes: pollIntervalMinutes)
    }

    /// True when the editor holds changes that are not on the server yet.
    ///
    /// Before the first successful load there is nothing to compare against, so
    /// this reads false — showing "unsaved changes" on a screen the user has not
    /// touched would be crying wolf.
    var hasUnsavedChanges: Bool {
        guard let savedSnapshot else { return false }
        return savedSnapshot != currentSnapshot
    }

    /// Record the current values as persisted. Called after a successful load
    /// and a successful save — the only two moments the two sides are known
    /// to agree.
    private func markClean() { savedSnapshot = currentSnapshot }

    /// Clamp into `pollIntervalRange`. Used on load (a DB written before the
    /// bound existed can hold anything) and on save.
    static func clampPollInterval(_ minutes: Int) -> Int {
        min(max(minutes, pollIntervalRange.lowerBound), pollIntervalRange.upperBound)
    }

    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    /// A transient confirmation the save landed (the view can show/auto-clear it).
    private(set) var didSave = false

    private let api: SettingsAPI

    init(api: SettingsAPI) {
        self.api = api
    }

    // ── Load (both surfaces) ──────────────────────────────────────────────────

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // Typed surface: quiet hours + audio.
            let notif = try await api.getNotificationPrefs()
            quietHoursStart = notif.quietHoursStart ?? ""
            quietHoursEnd = notif.quietHoursEnd ?? ""
            audioAlerts = notif.audioAlerts

            // Generic surface: operating mode (coerced via GeneralPrefs). An
            // unknown/absent stored mode falls back to Focus so the picker never
            // shows a non-selectable state on first run.
            let prefs = try await api.getPreferences()
            let general = GeneralPrefs(prefs)
            operatingMode = general.operatingMode == .unknown ? .focus : general.operatingMode
            // Clamped on the way in: a value stored before the bound existed (or
            // curl'd) must not reach the picker as an unselectable state.
            pollIntervalMinutes = Self.clampPollInterval(prefs.pollIntervalMinutes)

            // Both sides now agree: this is the baseline for "unsaved changes".
            markClean()
            errorMessage = nil
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    // ── Save (both surfaces) ──────────────────────────────────────────────────

    /// Persist the edited values. Quiet hours + audio go to the typed notification
    /// endpoint in one patch; operating mode goes to the generic per-key upsert.
    ///
    /// Empty-string-unsets (NotificationPrefs trap §1.5): a blank quiet-hour field
    /// is sent as `""` (`.some("")`) so the server clears it — NOT `.none`, which
    /// would omit the key and leave a stale value stored. A filled field sends the
    /// string; the server normalizes it.
    func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let patch = NotificationPrefsWrite(
            quietHoursStart: .some(quietHoursStart.trimmingCharacters(in: .whitespaces)),
            quietHoursEnd: .some(quietHoursEnd.trimmingCharacters(in: .whitespaces)),
            audioAlerts: audioAlerts
        )

        do {
            // Write the typed surface, then echo the server-normalized values back
            // into the fields (it may reformat "9:00" → "09:00"), so the UI shows
            // exactly what's stored.
            let saved = try await api.setNotificationPrefs(patch)
            quietHoursStart = saved.quietHoursStart ?? ""
            quietHoursEnd = saved.quietHoursEnd ?? ""
            audioAlerts = saved.audioAlerts

            // Operating mode via the generic per-key upsert (stringly-typed).
            try await api.setPreference(key: GeneralPrefs.operatingModeKey, value: operatingMode.rawValue)

            // Poll interval, same generic surface. Clamped here rather than in
            // the binding so the stepper stays responsive while editing, and so
            // exactly one code path decides what a valid value is.
            let clamped = Self.clampPollInterval(pollIntervalMinutes)
            pollIntervalMinutes = clamped
            try await api.setPreference(key: GeneralPrefs.pollIntervalKey,
                                        value: String(clamped))

            // Persisted — the edited values ARE the saved values now.
            markClean()
            errorMessage = nil
            didSave = true
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            didSave = false
        }
    }

    /// Clear the transient saved-confirmation flag (view calls this after showing
    /// it briefly, so a later edit starts clean).
    func clearSavedFlag() { didSave = false }
}