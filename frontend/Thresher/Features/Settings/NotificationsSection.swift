//
//  NotificationsSection.swift
//  Thresher
//
//  SHARED Notifications & operating-mode editor. Lives under Settings because
//  that is where it mounts as the §4.3 "Notifications" pane, but it is written to
//  be reused UNCHANGED by Onboarding's "initial preferences" step (§4.1.4) — it
//  holds no Settings-only assumptions: it depends only on `SettingsAPI` (via its
//  view model) and renders as a `Section`, so any `Form` host can mount it.
//
//  Presents both preference surfaces together (NotificationsViewModel owns the
//  two-endpoint split, trap §1.4): quiet-hours + audio (typed surface) and
//  operating mode (generic map). Explicit Save — these are per-key/patch writes,
//  not live-on-every-keystroke, so the user edits then commits once.
//
//  P4: every one of these is a first-class, editable preference (nothing
//  hardcoded). P2: operating mode affects SURFACING, not classification — the
//  caption says so, so the user isn't misled into thinking Focus hides mail
//  permanently.
//

import SwiftUI

@MainActor
struct NotificationsSection: View {
    @State private var model: NotificationsViewModel
    /// Auto-clear timer for the transient "Saved" confirmation.
    @State private var clearTask: Task<Void, Never>?

    init(api: SettingsAPI = APIClient()) {
        _model = State(initialValue: NotificationsViewModel(api: api))
    }

    var body: some View {
        Section("Operating Mode") {
            Picker("Mode", selection: $model.operatingMode) {
                ForEach(OperatingMode.selectable, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isLoading || model.isSaving)

            Text("Focus surfaces only the most urgent mail; Catch-up shows more. This changes what’s **surfaced**, not how mail is classified — nothing is hidden permanently.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        // Polish batch 2, Part A. Lives here rather than in its own pane because
        // it is about CADENCE, which is what this section already governs.
        Section("Checking for Mail") {
            Stepper(value: $model.pollIntervalMinutes,
                    in: NotificationsViewModel.pollIntervalRange) {
                Text("Check every \(model.pollIntervalMinutes) "
                     + (model.pollIntervalMinutes == 1 ? "minute" : "minutes"))
            }
            .disabled(model.isLoading || model.isSaving)

            // Both consequences stated, because neither is guessable from the
            // control. (1) E11/D37: config is re-read per pass, so a change lands
            // on the NEXT poll — without saying so, the setting looks broken for
            // up to fifteen minutes. (2) The cost: 1 minute is 15× the IMAP
            // traffic of 15, and the app's own refresh follows at half the
            // interval (D49), so this is not a free knob.
            Text("Takes effect at the next check — up to \(model.pollIntervalMinutes) "
                 + (model.pollIntervalMinutes == 1 ? "minute" : "minutes")
                 + " from now. Checking more often finds mail sooner but talks to "
                 + "your mail server proportionally more; the app's own refresh "
                 + "follows at half this interval.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Human gate 3.1: the stepper's own label moves instantly, so
            // without this the control looks live and the value appears to
            // "revert" on the next visit. Say plainly that a save is owed.
            if model.hasUnsavedChanges {
                Label("Not saved yet — use Save preferences below.",
                      systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        Section("Quiet Hours") {
            // Quiet hours as "HH:MM" text fields. Leaving a field blank unsets it
            // (the model sends "" → server clears it). Kept as plain text (not a
            // DatePicker) to round-trip the server's stored "HH:MM" shape exactly.
            TextField("Start (HH:MM, blank = none)", text: $model.quietHoursStart)
                .disabled(model.isLoading || model.isSaving)
            TextField("End (HH:MM, blank = none)", text: $model.quietHoursEnd)
                .disabled(model.isLoading || model.isSaving)

            Toggle("Audio alerts", isOn: $model.audioAlerts)
                .disabled(model.isLoading || model.isSaving)

            Text("During quiet hours, ambient banners are suppressed (Tier 1 always still surfaces).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        // D51 alerts hint — in BOTH prefs surfaces (this section is shared by
        // Settings §4.3 and the onboarding notifications step). Honest copy:
        // banner persistence is an OS-level per-app choice the app cannot set
        // for itself; all we can do is say so and open the right pane.
        Section {
            HStack(alignment: .top, spacing: 10) {
                Text("Banners disappear on their own — that's how macOS banners work. "
                     + "To make Thresher's notifications stay until dismissed, "
                     + "choose the \u{201C}Alerts\u{201D} style in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Open System Settings") {
                    // The Notifications pane; the app's own row is one click in.
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }

        Section {
            HStack(spacing: 10) {
                Button {
                    Task {
                        await model.save()
                        if model.didSave { scheduleSavedClear() }
                    }
                } label: {
                    if model.isSaving { ProgressView().controlSize(.small) }
                    // Name the pending state on the button itself: it is the
                    // thing the user is looking for once they realise an edit
                    // did not stick.
                    Text(model.hasUnsavedChanges ? "Save preferences •" : "Save preferences")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isLoading || model.isSaving)

                if model.hasUnsavedChanges && !model.isSaving {
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if model.didSave {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await model.load() }
    }

    /// Show the "Saved" confirmation briefly, then clear it. Cancels any prior
    /// pending clear so rapid successive saves don't race.
    private func scheduleSavedClear() {
        clearTask?.cancel()
        clearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)   // 2s
            guard !Task.isCancelled else { return }
            model.clearSavedFlag()
        }
    }
}