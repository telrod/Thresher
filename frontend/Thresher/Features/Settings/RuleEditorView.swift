//
//  RuleEditorView.swift
//  Thresher
//
//  Settings §4.2 Phase 2 — the add/edit sheet for a classification rule. Presented
//  as a sheet from RulesSection (add) or a rule row (edit). Composes the fixed
//  matcher vocabularies (RuleField / RuleOperator, from Rule.swift) as dropdowns
//  and the tier/category effect controls.
//
//  BOTH-EFFECTS INVARIANT (client-side, mirrors the server — D38 post-merge guard
//  + schema CHECK): a rule that can match MUST set a tier or a category (a
//  no-effect rule pollutes /explain, P3). We enforce it here so the user gets an
//  immediate, legible block instead of a round-trip 400: Save is disabled (with a
//  reason shown) whenever BOTH effects are cleared. The server still enforces it —
//  this is a UX pre-check, not the source of truth.
//
//  On create we send the full body (POST /rules, appends at MAX+1 priority, D44).
//  On edit we send the full field set as a PUT patch — including BOTH effects
//  every time (as explicit values or explicit nulls) so the merged result is
//  exactly what the form shows; the both-null guard then only fires when the user
//  genuinely cleared both (which Save already blocks).
//

import SwiftUI

@MainActor
struct RuleEditorView: View {
    /// The rule being edited, or nil for a new rule.
    private let existing: Rule?
    /// Existing sender-group names (polish Part C): when Field = Sender group,
    /// Value is a picker over these — free text can't name a nonexistent group.
    private let groupNames: [String]
    /// Persist callback: returns nil on success, or a user-facing error string
    /// (e.g. a server 400) so the sheet stays open and shows it. The host (view
    /// model) owns the actual POST/PUT + list reload.
    private let onSave: (RuleWrite) async -> String?
    private let onCancel: () -> Void

    // ── Form state ─────────────────────────────────────────────────────────────
    @State private var ruleName: String
    @State private var field: RuleField
    @State private var op: RuleOperator
    @State private var value: String
    /// The two effects are independent toggles + pickers. At least one must be on
    /// (the invariant). `setsTier`/`setsCategory` gate whether each is sent.
    @State private var setsTier: Bool
    @State private var tier: Tier
    @State private var setsCategory: Bool
    @State private var category: Category
    @State private var notes: String

    @State private var isSaving = false
    @State private var errorMessage: String?

    init(existing: Rule? = nil,
         groupNames: [String] = [],
         onSave: @escaping (RuleWrite) async -> String?,
         onCancel: @escaping () -> Void = {}) {
        self.existing = existing
        self.groupNames = groupNames
        self.onSave = onSave
        self.onCancel = onCancel

        // Seed the form from the existing rule, or sensible new-rule defaults.
        _ruleName = State(initialValue: existing?.ruleName ?? "")
        let seededField = existing.map { RuleField(raw: $0.field) } ?? .senderEmail
        _field = State(initialValue: seededField)
        // E22: a stored rule may carry an invalid combo (created before the
        // pairing was enforced). Seed the picker onto a valid operator for the
        // field — nothing persists until Save, and this IS the documented
        // repair path for such a rule.
        let seededOp = existing.map { RuleOperator(raw: $0.operator) } ?? .contains
        let validOps = RuleOperator.valid(for: seededField)
        _op = State(initialValue: validOps.contains(seededOp) ? seededOp : validOps[0])
        _value = State(initialValue: existing?.value ?? "")

        let seededTier = existing?.tier
        _setsTier = State(initialValue: seededTier != nil)
        _tier = State(initialValue: seededTier ?? .two)

        let seededCategory = existing?.categoryEffect
        _setsCategory = State(initialValue: seededCategory != nil)
        // Category effect is only work/personal (never .unknown); default work.
        _category = State(initialValue: seededCategory ?? .work)

        _notes = State(initialValue: existing?.notes ?? "")
    }

    private var isEditing: Bool { existing != nil }

    var body: some View {
        VStack(spacing: 0) {
            Text(isEditing ? "Edit Rule" : "New Rule")
                .font(.headline)
                .padding(.top, 16)

            Form {
                Section("Rule") {
                    TextField("Name", text: $ruleName)
                }

                // ── Matcher: field <operator> "value" ─────────────────────────
                Section("Match when") {
                    Picker("Field", selection: $field) {
                        ForEach(RuleField.selectable, id: \.self) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .onChange(of: field) { _, newField in
                        // Entering the sender_group field type: snap Value onto
                        // a real group (unless it already names one).
                        if newField == .senderGroup, !groupNames.contains(value) {
                            value = groupNames.first ?? ""
                        }
                        // E22: re-validate the operator against the new field —
                        // an invalid combo silently never matches in the engine.
                        let valid = RuleOperator.valid(for: newField)
                        if !valid.contains(op) {
                            op = valid[0]
                        }
                    }
                    // E22: the operator picker is field-dependent — sender_group
                    // locks to "matches group"; other fields exclude it.
                    Picker("Operator", selection: $op) {
                        ForEach(RuleOperator.valid(for: field), id: \.self) { o in
                            Text(o.label).tag(o)
                        }
                    }
                    .disabled(RuleOperator.valid(for: field).count == 1)
                    if field == .senderGroup {
                        // Part C: Value is a picker over EXISTING groups — free
                        // text could name a group that doesn't exist, a rule
                        // that silently never matches.
                        if groupNames.isEmpty {
                            Label("No sender groups defined yet — add one under Sender groups first.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Picker("Value", selection: $value) {
                                ForEach(groupNames, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                                // An edited rule may reference a since-deleted
                                // group: keep it selectable so opening the
                                // editor doesn't silently rewrite the rule.
                                if !value.isEmpty && !groupNames.contains(value) {
                                    Text("\(value) (no longer exists)").tag(value)
                                }
                            }
                        }
                    } else {
                        TextField("Value", text: $value)
                    }
                }

                // ── Effects: at least one required (the invariant) ────────────
                Section {
                    Toggle("Set urgency tier", isOn: $setsTier)
                    if setsTier {
                        Picker("Tier", selection: $tier) {
                            ForEach(Tier.allCases, id: \.self) { t in
                                Text("\(t.shortLabel) — \(t.label)").tag(t)
                            }
                        }
                    }
                    Toggle("Set category", isOn: $setsCategory)
                    if setsCategory {
                        Picker("Category", selection: $category) {
                            Text("Work").tag(Category.work)
                            Text("Personal").tag(Category.personal)
                        }
                        .pickerStyle(.segmented)
                    }
                } header: {
                    Text("Effect")
                } footer: {
                    // The invariant, made legible (P3) rather than a silent
                    // disabled button.
                    if !hasEffect {
                        Label("A rule must set a tier, a category, or both.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
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
                Button(isEditing ? "Save changes" : "Create rule") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(minWidth: 460, minHeight: 520)
    }

    // ── Validation (client-side pre-check; server is the source of truth) ───────

    /// The both-effects invariant: at least one of tier/category must be set.
    private var hasEffect: Bool { setsTier || setsCategory }

    private var canSave: Bool {
        !isSaving
            && !ruleName.trimmingCharacters(in: .whitespaces).isEmpty
            && !value.trimmingCharacters(in: .whitespaces).isEmpty
            && hasEffect
    }

    // ── Persist ─────────────────────────────────────────────────────────────

    private func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }

        // Build the body. Effects are sent as explicit values or explicit nulls
        // (.some(nil)) — NOT omitted — so a PUT patch makes the merged row exactly
        // match the form (clearing one effect actually clears it). canSave already
        // guarantees ≥1 effect, so this can't send both-null.
        var body = RuleWrite()
        body.ruleName = ruleName.trimmingCharacters(in: .whitespaces)
        body.field = field.rawValue
        body.operator = op.rawValue
        body.value = value.trimmingCharacters(in: .whitespaces)
        body.setTier = .some(setsTier ? tier.rawValue : nil)
        body.setCategory = .some(setsCategory ? category.rawValue : nil)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
        body.notes = trimmedNotes.isEmpty ? nil : trimmedNotes

        if let error = await onSave(body) {
            errorMessage = error   // keep the sheet open, show the server's reason
        }
        // On success the host dismisses the sheet.
    }
}