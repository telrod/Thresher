//
//  RulesSection.swift
//  Thresher
//
//  Settings §4.2 "Classification Rules".
//
//  Phase 1 (shipped): the rules LIST + a per-row enable/disable toggle. Read
//  passes include_disabled=true (trap §1.1) so a toggled-off rule stays visible
//  and re-enableable; the toggle writes PUT /rules/<id> {enabled:<bool>} (trap
//  §1.2 — bool on write).
//
//  Phase 2 (this build): add/edit/delete via RuleEditorView (a sheet), and
//  drag-to-reorder that shows the literal stored `priority` integer next to the
//  drag handle (OI12 — both the drag affordance AND the visible number, so the
//  ordinal that drives evaluation stays legible for the P3 debugging case).
//  Reorder persists via the D44 batch endpoint (PUT /rules/reorder); a 409 stale
//  set refetches and re-presents (see RulesViewModel.move).
//
//  Each row surfaces what makes a rule legible (P3): name + priority, the
//  field/operator/value match clause, and its tier/category effect badges.
//  A disabled rule is dimmed (not hidden).
//

import SwiftUI

@MainActor
struct RulesSection: View {
    @State private var model: RulesViewModel
    /// D52: a mailbox-wide re-run is worth confirming, even though it is
    /// non-destructive (triage preserved, nothing deleted).
    @State private var confirmReclassifyAll = false
    /// Drives the editor sheet: nil = closed, .add = new rule, .edit(rule) = edit.
    @State private var editing: EditorTarget?

    /// What the editor sheet is doing. Identifiable so `.sheet(item:)` drives it.
    enum EditorTarget: Identifiable {
        case add
        case edit(Rule)
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let r): return "edit-\(r.id)"
            }
        }
    }

    init(api: SettingsAPI = APIClient()) {
        _model = State(initialValue: RulesViewModel(api: api))
    }

    var body: some View {
        Section {
            if model.rules.isEmpty && !model.isLoading {
                Text("No rules defined yet.")
                    .foregroundStyle(.secondary)
            } else {
                // A List with .onMove gives drag-to-reorder. It's nested in the
                // Settings Form; a fixed-height plain-style List keeps the grouped
                // Form layout intact while enabling row moves.
                List {
                    ForEach(model.rules) { rule in
                        ruleRow(rule)
                            .contextMenu {
                                Button("Edit") { editing = .edit(rule) }
                                Button("Delete", role: .destructive) {
                                    Task { await model.delete(rule) }
                                }
                            }
                    }
                    .onMove { source, dest in
                        Task { await model.move(from: source, to: dest) }
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: 220)
                .disabled(model.isReordering)
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }

            // ── D52 part C: bulk reclassify ────────────────────────────────────
            // Housed here because this is where the user has just changed the rules
            // — the moment they want them applied to existing mail. Rule edits are
            // NOT retroactive (E11/D37), and classify-once stays the default
            // lifecycle (invariant 4), so this is the explicit way to close the gap.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button {
                        confirmReclassifyAll = true
                    } label: {
                        if model.isReclassifying {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("Reclassifying all mail…")
                            }
                        } else {
                            Label("Reclassify all mail", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(model.isReclassifying)
                    Spacer()
                }
                if let s = model.reclassifySummary {
                    Text(s.summaryLine)
                        .font(.caption)
                        .foregroundStyle(s.errors > 0 ? .orange : .secondary)
                }
                Text("Rule changes apply to new mail automatically. Use this once to re-run the current rules over mail you already have — your triage states are kept, and no notifications are sent.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            HStack {
                Text("Classification Rules")
                Spacer()
                if model.isReordering { ProgressView().controlSize(.small) }
                Button {
                    editing = .add
                } label: {
                    Label("Add rule", systemImage: "plus")
                }
                .help("Add a classification rule")
            }
        } footer: {
            Text("Drag to reorder. The number is the stored priority — lower runs first; the first matching rule wins.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await model.load() }
        .confirmationDialog("Reclassify all mail with the current rules?",
                            isPresented: $confirmReclassifyAll,
                            titleVisibility: .visible) {
            Button("Reclassify all mail") { Task { await model.reclassifyAll() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Every stored message is re-run through the current rules. Triage states are kept and no notifications are sent. Tiers and categories may change.")
        }
        .sheet(item: $editing) { target in
            switch target {
            case .add:
                RuleEditorView(
                    groupNames: model.groupNames,
                    onSave: { body in
                        let err = await model.create(body)
                        if err == nil { editing = nil }
                        return err
                    },
                    onCancel: { editing = nil }
                )
            case .edit(let rule):
                RuleEditorView(
                    existing: rule,
                    groupNames: model.groupNames,
                    onSave: { patch in
                        let err = await model.update(id: rule.id, patch: patch)
                        if err == nil { editing = nil }
                        return err
                    },
                    onCancel: { editing = nil }
                )
            }
        }
    }

    // ── Rule row ──────────────────────────────────────────────────────────────

    @ViewBuilder
    private func ruleRow(_ rule: Rule) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // OI12: the literal stored priority integer, next to the (system-drawn)
            // drag handle. Dense 1..N after any reorder (D44) — reads as a rank.
            Text("\(rule.priority)")
                .font(.caption.monospacedDigit()).bold()
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
                .help("Priority \(rule.priority) — lower runs first")

            VStack(alignment: .leading, spacing: 4) {
                Text(rule.ruleName)
                    .font(.body).bold()

                // field operator "value" (P3 — legible). Enum label views so a
                // future unknown vocabulary value still renders its raw string.
                Text(matchClause(rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                effectBadges(rule)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Tap the row body to edit.
            .contentShape(Rectangle())
            .onTapGesture { editing = .edit(rule) }

            toggle(rule)

            // OI16: explicit edit/delete affordances. The context menu stays,
            // but right-click-only was undiscoverable at the keyboard — the
            // icon buttons are the primary path now.
            Button {
                editing = .edit(rule)
            } label: { Image(systemName: "pencil") }
            .buttonStyle(.borderless)
            .help("Edit rule")
            Button(role: .destructive) {
                Task { await model.delete(rule) }
            } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .help("Delete rule")
        }
        // Dim a disabled rule so it reads as off but stays visible/re-enableable.
        .opacity(rule.isEnabled ? 1 : 0.5)
        .padding(.vertical, 2)
    }

    /// `field operator "value"`, e.g. `Sender domain contains "example.com"`.
    private func matchClause(_ rule: Rule) -> String {
        "\(rule.fieldValue.label) \(rule.operatorValue.label) \u{201C}\(rule.value)\u{201D}"
    }

    @ViewBuilder
    private func effectBadges(_ rule: Rule) -> some View {
        HStack(spacing: 6) {
            // A rule sets a tier, a category, or both (≥1 by the CHECK). Show
            // only the effect(s) it actually sets — not an "Unclassified" badge.
            if let tier = rule.tier {
                TierBadge(tier: tier)
            }
            if let category = rule.categoryEffect {
                CategoryBadge(category: category)
            }
        }
    }

    @ViewBuilder
    private func toggle(_ rule: Rule) -> some View {
        HStack(spacing: 6) {
            if model.isToggling(rule) {
                ProgressView().controlSize(.small)
            }
            Toggle("Enabled", isOn: enabledBinding(rule))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(model.isToggling(rule))
                .help(rule.isEnabled ? "Rule is active" : "Rule is disabled")
        }
    }

    /// Binding that reads the rule's current enabled state and writes through the
    /// view model's toggle path (PUT enabled bool). The set closure spawns the
    /// async write; the model replaces the row from the server response.
    private func enabledBinding(_ rule: Rule) -> Binding<Bool> {
        Binding(
            get: { rule.isEnabled },
            set: { newValue in
                guard newValue != rule.isEnabled else { return }
                Task { await model.setEnabled(rule, to: newValue) }
            }
        )
    }
}