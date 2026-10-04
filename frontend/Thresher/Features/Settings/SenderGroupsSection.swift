//
//  SenderGroupsSection.swift
//  Thresher
//
//  Settings §4.2 "Sender Groups" — its own sidebar-row surface (OI11: a sibling
//  row, NOT a tab and NOT nested under Rules). Mounts in SettingsView's
//  `.senderGroups` detail pane (was a placeholder).
//
//  Lists each group's name, email pattern, and urgency-floor tier badge (P3 —
//  the floor is legible), with add (header +), edit (tap / context menu), and
//  delete (context menu, behind no confirm — a group is cheap config, and P1's
//  never-delete is about messages, not config). Wires POST/PUT/DELETE
//  /sender-groups via SenderGroupsViewModel.
//

import SwiftUI

@MainActor
struct SenderGroupsSection: View {
    @State private var model: SenderGroupsViewModel
    @State private var editing: EditorTarget?

    enum EditorTarget: Identifiable {
        case add
        case edit(SenderGroup)
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let g): return "edit-\(g.id)"
            }
        }
    }

    init(api: SettingsAPI = APIClient()) {
        _model = State(initialValue: SenderGroupsViewModel(api: api))
    }

    var body: some View {
        Section {
            if model.groups.isEmpty && !model.isLoading {
                Text("No sender groups defined yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.groups) { group in
                    groupRow(group)
                        .contextMenu {
                            Button("Edit") { editing = .edit(group) }
                            Button("Delete", role: .destructive) {
                                Task { await model.delete(group) }
                            }
                        }
                }
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("Sender Groups")
                Spacer()
                Button {
                    editing = .add
                } label: {
                    Label("Add group", systemImage: "plus")
                }
                .help("Add a sender group")
            }
        } footer: {
            Text("A known sender is never surfaced below their group's floor tier (the sender override invariant).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await model.load() }
        .sheet(item: $editing) { target in
            switch target {
            case .add:
                SenderGroupEditorView(
                    onSave: { body in
                        let err = await model.create(body)
                        if err == nil { editing = nil }
                        return err
                    },
                    onCancel: { editing = nil }
                )
            case .edit(let group):
                SenderGroupEditorView(
                    existing: group,
                    onSave: { patch in
                        let err = await model.update(id: group.id, patch: patch)
                        if err == nil { editing = nil }
                        return err
                    },
                    onCancel: { editing = nil }
                )
            }
        }
    }

    // ── Group row ─────────────────────────────────────────────────────────────

    @ViewBuilder
    private func groupRow(_ group: SenderGroup) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.groupName)
                    .font(.body).bold()
                // D53: a group can hold several patterns, so the row shows all of
                // them rather than the deprecated single `email_pattern` column.
                // Empty is rendered honestly — a group with no patterns matches
                // nobody, and silently showing nothing would hide that.
                if group.patterns.isEmpty {
                    Text("No patterns — this group matches nobody")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(group.patterns.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { editing = .edit(group) }

            // The floor tier as a badge (P3 — the override floor is legible).
            if let tier = group.floorTier {
                VStack(alignment: .trailing, spacing: 2) {
                    TierBadge(tier: tier)
                    Text("floor").font(.caption2).foregroundStyle(.secondary)
                }
            }

            // OI16: explicit edit/delete affordances (context menu stays, but
            // right-click-only was undiscoverable — icons are primary now).
            Button {
                editing = .edit(group)
            } label: { Image(systemName: "pencil") }
            .buttonStyle(.borderless)
            .help("Edit sender group")
            Button(role: .destructive) {
                Task { await model.delete(group) }
            } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .help("Delete sender group")
        }
        .padding(.vertical, 2)
    }
}