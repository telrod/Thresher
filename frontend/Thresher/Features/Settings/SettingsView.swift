//
//  SettingsView.swift
//  Thresher
//
//  The Settings screen container (§4.1.3). A sidebar List drives a detail pane
//  (D43 — Settings IA is sidebar-list + detail), one row per configuration area
//  (P4 — all preferences first-class and editable). Sidebar rows, in order:
//   - Email accounts (4.1)              — committed §4.1 content (incl. AccountConnectView).
//   - Classification rules (4.2)        — committed Phase 1 list + enable/disable toggle.
//     (OI10 → Option B: Rules is a sidebar ROW here, not a top-level screen.)
//   - Sender groups (4.2)               — sibling row (OI11); SenderGroupsSection CRUD.
//   - Notifications (4.3)               — shared NotificationsSection (quiet hours,
//                                         audio, operating mode); also reused by
//                                         Onboarding's initial-prefs step (§4.1.4).
//
//  Presented via the macOS Settings scene (⌘,) and a toolbar sheet — the
//  list/detail NavigationSplitView below is *internal* to Settings; the app's
//  main window split (Message List ↔ Detail) is untouched (macOS 14 / D36).
//
//  Each detail pane hosts the section's existing @Observable-backed view
//  unchanged: the panes are re-housed, not rewritten. A section still owns its
//  own view model + SettingsAPI and loads/fails independently (P2 — one section
//  erroring never blanks the others).
//

import SwiftUI

@MainActor
struct SettingsView: View {
    private let api: SettingsAPI

    /// The selected sidebar area. Defaults to Email accounts so the detail pane
    /// is never empty on open.
    @State private var selection: SettingsArea = .emailAccounts

    init(api: SettingsAPI = APIClient()) {
        self.api = api
    }

    /// Build provenance, fetched once when Settings opens. nil = not fetched yet or
    /// unreachable; the footer distinguishes those two states honestly.
    @State private var backendVersion: BackendVersion?
    @State private var backendUnreachable = false

    var body: some View {
        NavigationSplitView {
            // The sidebar is the D43+D47 FIVE-row list plus a passive provenance
            // footer BELOW the list — not a sixth row. `testSidebarMatchesD43Order`
            // and the D47 geometry pins must stay green, so the row set is untouched.
            VStack(spacing: 0) {
                List(SettingsArea.allCases, selection: $selection) { area in
                    Label(area.title, systemImage: area.systemImage)
                        .tag(area)
                }
                Divider()
                provenanceFooter
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail(for: selection)
        }
        .navigationTitle("Settings")
        .frame(minWidth: 720, minHeight: 480)
        .task {
            // No retry loop, no blocking (workorder §3.3): one attempt, and a failure
            // is displayed rather than swallowed.
            do {
                backendVersion = try await api.backendVersion()
                backendUnreachable = false
            } catch {
                backendVersion = nil
                backendUnreachable = true
            }
        }
    }

    // ── Build provenance (passive) ──────────────────────────────────────────────
    //
    // Answers "which code am I running?" when asked, and never notifies (P2). Session
    // 27 opened with both runtime artifacts stale and only inference to detect it.

    @ViewBuilder
    private var provenanceFooter: some View {
        let stamp = AppBuildStamp.current
        VStack(alignment: .leading, spacing: 2) {
            Text(stamp.displayLine)
            if let v = backendVersion {
                HStack(spacing: 4) {
                    // The mismatch marker is deliberately subtle — inform, don't
                    // interrupt. Only shown when BOTH SHAs are known and differ;
                    // "unknown" is missing information, not a mismatch.
                    if stamp.mismatches(v) {
                        Text("≠").bold().foregroundStyle(.orange)
                            .help("The app and backend were built from different commits")
                    }
                    Text("Backend \(v.gitSHA)")
                }
            } else if backendUnreachable {
                // Provenance-relevant in itself: this is how a dead or
                // not-yet-restarted backend surfaces.
                Text("Backend unreachable").foregroundStyle(.orange)
            }

            // ── Reveal Logs ──────────────────────────────────────────────────
            //
            // Distribution is SOURCE-ONLY: there is no crash reporter and no
            // telemetry, so a user sending a log IS the entire support channel.
            // Logs the user cannot find do not exist for the people who need
            // them most — the ones whose app is not working and who have never
            // opened Terminal.
            //
            // Placed beside the build stamp on purpose: "which code am I
            // running" and "what did it do" are the two things a bug report
            // needs, and they should be answerable from one place.
            //
            // Disabled rather than hidden when the directory is absent, so the
            // affordance still says the logs exist and where — a missing
            // control would read as "there are no logs".
            Button {
                revealLogs()
            } label: {
                Label("Reveal Logs in Finder", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.link)
            .font(.caption2)
            .disabled(!logsDirectoryExists)
            .help(logsDirectoryExists
                  ? "Open the folder containing the backend logs"
                  : "No logs yet — they appear once the backend has run")
            .accessibilityIdentifier("settings.revealLogs")
            .padding(.top, 2)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Does the log directory exist yet? It is created on first backend launch,
    /// so on a truly fresh install there is briefly nothing to reveal.
    private var logsDirectoryExists: Bool {
        FileManager.default.fileExists(atPath: LocalProcessHost.logDirectory.path)
    }

    /// Open the log folder with the newest log selected, so the user lands on
    /// the file rather than a folder they then have to interpret.
    private func revealLogs() {
        let dir = LocalProcessHost.logDirectory
        let newest = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "log" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return da < db
            }
        if let newest {
            NSWorkspace.shared.activateFileViewerSelecting([newest])
        } else {
            NSWorkspace.shared.open(dir)
        }
    }

    // ── Detail dispatch ─────────────────────────────────────────────────────────
    //
    // Each re-housed section is a Section-styled view, so it gets the grouped
    // Form ancestor it expects. The placeholders are bare empty-states (their
    // content is a later phase — not built here).

    @ViewBuilder
    private func detail(for area: SettingsArea) -> some View {
        switch area {
        case .emailAccounts:
            Form { EmailAccountsSection(api: api) }
                .formStyle(.grouped)
                .navigationTitle(area.title)
        case .classificationRules:
            Form { RulesSection(api: api) }
                .formStyle(.grouped)
                .navigationTitle(area.title)
        case .senderGroups:
            Form { SenderGroupsSection(api: api) }
                .formStyle(.grouped)
                .navigationTitle(area.title)
        case .notifications:
            Form { NotificationsSection(api: api) }
                .formStyle(.grouped)
                .navigationTitle(area.title)
        case .appearance:
            Form { AppearanceSection() }
                .formStyle(.grouped)
                .navigationTitle(area.title)
        }
    }

    /// Empty-state placeholder for a sidebar area whose content is a later phase.
    @ViewBuilder
    private func placeholder(_ area: SettingsArea) -> some View {
        ContentUnavailableView(
            area.title,
            systemImage: area.systemImage,
            description: Text("This section isn’t available yet.")
        )
        .navigationTitle(area.title)
    }
}

/// The Settings sidebar areas, in display order (D43). A plain value enum:
/// `Hashable` (for List selection) and `Sendable` come for free, D42-clean.
enum SettingsArea: String, CaseIterable, Identifiable {
    case emailAccounts
    case classificationRules
    case senderGroups
    case notifications
    case appearance   // D47: fifth row (amends D43's four-row order)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .emailAccounts:       "Email accounts"
        case .classificationRules: "Classification rules"
        case .senderGroups:        "Sender groups"
        case .notifications:       "Notifications"
        case .appearance:          "Appearance"
        }
    }

    var systemImage: String {
        switch self {
        case .emailAccounts:       "envelope"
        case .classificationRules: "slider.horizontal.3"
        case .senderGroups:        "person.2"
        case .notifications:       "bell"
        case .appearance:          "textformat.size"
        }
    }
}