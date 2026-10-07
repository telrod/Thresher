//
//  SenderGroupEditorView.swift
//  Thresher
//
//  Settings §4.2 — add/edit sheet for a sender group (OI11 sibling surface).
//  Fields: group_name, a LIST of patterns (D53), urgency_floor ∈ 1–5. The floor is
//  the Sender override invariant: a known sender is never shown below their group's
//  floor tier.
//
//  D53: a sender group is a named set of address patterns sharing ONE floor tier,
//  and a sender matching ANY pattern is in the group. Save sends the whole set and
//  the server replaces it atomically (the D44 shape) — no per-pattern calls, so the
//  classifier's reload-per-poll never sees a half-updated group.
//
//  urgency_floor is validated client-side (a Tier picker can only pick 1–5, so
//  it's unrepresentable-out-of-range) AND server-side (_validate_sender_group).
//  An empty pattern set is blocked here and on the server (DG3: "Empty set
//  invalid") — with a VISIBLE reason rather than a dead Save button, since a
//  legacy placeholder group can legitimately open with zero patterns.
//

import SwiftUI

@MainActor
struct SenderGroupEditorView: View {
    private let existing: SenderGroup?
    private let onSave: (SenderGroupWrite) async -> String?
    private let onCancel: () -> Void

    /// One editable pattern row. Identity is per-ROW, not per-string, so two rows
    /// holding the same text (mid-typing) don't collapse into one in the ForEach.
    private struct PatternRow: Identifiable, Equatable {
        let id = UUID()
        var text: String
    }

    @State private var groupName: String
    @State private var patterns: [PatternRow]
    /// Held as a Tier so the picker can't express an out-of-range floor.
    @State private var floor: Tier
    @State private var notes: String

    @State private var isSaving = false
    @State private var errorMessage: String?

    init(existing: SenderGroup? = nil,
         onSave: @escaping (SenderGroupWrite) async -> String?,
         onCancel: @escaping () -> Void = {}) {
        self.existing = existing
        self.onSave = onSave
        self.onCancel = onCancel

        _groupName = State(initialValue: existing?.groupName ?? "")
        // A new group starts with one empty row to type into; an existing group
        // shows its whole set. A legacy placeholder with no patterns also gets one
        // empty row, so the editor is usable rather than blank.
        let seed = existing?.patterns ?? []
        _patterns = State(initialValue: seed.isEmpty ? [PatternRow(text: "")]
                                                     : seed.map { PatternRow(text: $0) })
        // Seed from the stored floor; default Tier 2 for a new group. An
        // out-of-range stored value (shouldn't happen — server bounds it) falls
        // back to .two so the picker always has a valid selection.
        _floor = State(initialValue: existing?.floorTier ?? .two)
        _notes = State(initialValue: existing?.notes ?? "")
    }

    private var isEditing: Bool { existing != nil }

    var body: some View {
        VStack(spacing: 0) {
            Text(isEditing ? "Edit Sender Group" : "New Sender Group")
                .font(.headline)
                .padding(.top, 16)

            Form {
                Section("Group") {
                    TextField("Name", text: $groupName)
                }

                Section {
                    ForEach($patterns) { $row in
                        HStack(spacing: 8) {
                            TextField("e.g. *@example.com", text: $row.text)
                                .disableAutocorrection(true)
                            // OI16 lesson: destructive actions get an explicit,
                            // visible control — never context-menu-only.
                            Button {
                                patterns.removeAll { $0.id == row.id }
                                if patterns.isEmpty { patterns = [PatternRow(text: "")] }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this pattern")
                            .disabled(patterns.count == 1
                                      && patterns[0].text.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    Button {
                        patterns.append(PatternRow(text: ""))
                    } label: {
                        Label("Add pattern", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Patterns")
                } footer: {
                    Text("A sender matching ANY of these is in the group. Use an exact address, a domain (example.com or @example.com — a bare domain is stored as @example.com), or a glob with * before the @ (*@example.com).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker("Urgency floor", selection: $floor) {
                        ForEach(Tier.allCases, id: \.self) { t in
                            Text("\(t.shortLabel) — \(t.label)").tag(t)
                        }
                    }
                } header: {
                    Text("Floor")
                } footer: {
                    Text("Mail from a matching sender is never surfaced below this tier (the sender override invariant).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Notes (optional)") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(1...3)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "xmark.octagon.fill")
                            .font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                // The blocking reason is stated next to the button, not left for the
                // user to infer from a grey control.
                if let reason = saveBlockedReason {
                    Text(reason)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(isEditing ? "Save changes" : "Create group") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .help(saveBlockedReason ?? "Save this group")
            }
            .padding(16)
        }
        // Taller than the pre-D53 sheet: the pattern LIST grows, so Floor and Notes
        // were pushed off the bottom at the old 440 (caught by the render evidence,
        // not by a passing test).
        .frame(minWidth: 460, minHeight: 560)
    }

    /// The patterns as the server will receive them: trimmed, empties dropped,
    /// de-duplicated, order preserved.
    private var cleanedPatterns: [String] {
        var out: [String] = []
        for row in patterns {
            let s = row.text.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty && !out.contains(s) { out.append(s) }
        }
        return out
    }

    /// Why Save is unavailable, in the user's words — nil when it's available.
    /// A disabled button with no explanation is the failure mode this avoids: an
    /// existing placeholder group legitimately opens with no patterns, and "Save is
    /// grey and I don't know why" is exactly the OI16-adjacent trap.
    private var saveBlockedReason: String? {
        if groupName.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Give the group a name."
        }
        if cleanedPatterns.isEmpty {
            return "Add at least one pattern — a group with none can never match."
        }
        return nil
    }

    private var canSave: Bool { !isSaving && saveBlockedReason == nil }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }

        var body = SenderGroupWrite()
        body.groupName = groupName.trimmingCharacters(in: .whitespaces)
        // The whole set: the server replaces it atomically (D44 shape).
        body.patterns = cleanedPatterns
        body.urgencyFloor = floor.rawValue
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
        body.notes = trimmedNotes.isEmpty ? nil : trimmedNotes

        if let error = await onSave(body) {
            errorMessage = error
        }
    }
}