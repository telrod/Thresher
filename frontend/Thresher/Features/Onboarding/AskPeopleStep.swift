//
//  AskPeopleStep.swift
//  Thresher
//
//  The onboarding Ask step (workorder: onboarding ask-step, Phase 2; D75–D78).
//
//  WHY IT EXISTS: both Tier 1 rules match sender groups that ship with a
//  placeholder matching nobody, so a fresh install cannot produce a Tier 1. This
//  step asks for the people whose mail matters most and writes them, in ONE
//  call, to `POST /onboarding/people`.
//
//  THE CONTRACT IT RELIES ON (backend D78/D79):
//   - each submitted list REPLACES that group's members, so the inputs are
//     prefilled with the current members (placeholder excluded) — what the user
//     sees is what gets saved;
//   - an empty list leaves the group unchanged, so this step cannot remove
//     everyone (the emptied-group note says so);
//   - 400 names every rejected entry and writes nothing;
//   - 200 "saved" / "unchanged", and 207 "saved_not_retiered" /
//     "saved_partially_retiered" — the 207s mean the people ARE saved but mail
//     already stored kept its old tier.
//
//  It sits BEFORE Connect (D75), so on a fresh install membership is in place
//  before the first fetch.
//

import SwiftUI

// ── Wire shapes ──────────────────────────────────────────────────────────────

/// 200 / 207 body of `POST /onboarding/people`.
struct OnboardingPeopleResponse: Decodable, Sendable {
    let written: Bool
    let status: String
    /// The STORED form of each group that was written (e.g. `@example.com`).
    let groups: [String: [String]]
    let error: String?
}

/// 400 body: nothing was written, and each rejected entry is named.
struct OnboardingPeopleRejection: Error, Decodable, Sendable {
    struct Entry: Decodable, Sendable, Hashable {
        let group: String
        let entry: String
        let error: String
    }
    let error: String
    let invalid: [Entry]
}

// ── Navigation (pure, so it can be tested) ───────────────────────────────────

/// The step order and the two routing rules the Ask step added. Kept out of the
/// view so the rules are unit-testable rather than buried in `@State`.
enum OnboardingFlow {
    /// D76: a returning user (tutorial seen) starts at Ask, not Connect —
    /// otherwise the step, and the reclassify that exists for that user, would
    /// cover nobody.
    static func initialStep(hasSeenTutorial: Bool) -> OnboardingView.Step {
        hasSeenTutorial ? .ask : .welcome
    }

    /// Where Back goes from `step`, or nil if Back is unavailable.
    ///
    /// D77: never back into Ask once an account was connected in THIS run. A
    /// poll pass builds its engine once, so edits made while the first fetch is
    /// running don't reach mail it is already ingesting.
    static func previous(of step: OnboardingView.Step, hasSeenTutorial: Bool,
                         connectedThisRun: Bool) -> OnboardingView.Step? {
        guard let prev = OnboardingView.Step(rawValue: step.rawValue - 1) else { return nil }
        if prev == .welcome && hasSeenTutorial { return nil }
        if prev == .ask && connectedThisRun { return nil }
        return prev
    }
}

// ── Model ────────────────────────────────────────────────────────────────────

@MainActor
@Observable
final class AskPeopleModel {

    enum Group: String, CaseIterable, Identifiable {
        case leadership, family
        var id: String { rawValue }
    }

    struct Row: Identifiable, Equatable {
        let id = UUID()
        var text: String
        /// The server's message for this exact entry, cleared when it is edited.
        var error: String?
    }

    enum Phase: Equatable {
        case loading
        case loadFailed
        case editing
        case saving
        case confirmingSkip
        /// Saved, and something is worth seeing before moving on: entries were
        /// stored in a different form (a bare domain became `@domain`).
        case saved
        /// 207: the people are saved; mail already stored was not (fully) re-tiered.
        case savedNotRetiered(String)
    }

    /// What the host should do after an action.
    enum Outcome: Equatable { case stay, advance }

    /// The seeded leadership member. It matches nobody, so it is never shown.
    static let placeholder = "boss@example.com"

    private(set) var phase: Phase = .loading
    private(set) var rows: [Group: [Row]] = [:]
    /// Members at load (or after the last save), placeholder excluded.
    private(set) var prefilled: [Group: [String]] = [:]
    /// Groups that exist on the server. A missing group is not shown or sent.
    private(set) var available: [Group] = []
    private(set) var generalError: String?

    private let api: SettingsAPI

    init(api: SettingsAPI) {
        self.api = api
    }

    // ── Load ──────────────────────────────────────────────────────────────────

    func load() async {
        phase = .loading
        generalError = nil
        do {
            let groups = try await api.getRules(includeDisabled: false).senderGroups
            var found: [Group] = []
            for group in Group.allCases {
                guard let g = groups.first(where: { $0.groupName == group.rawValue }) else {
                    continue
                }
                found.append(group)
                let members = g.patterns.filter {
                    $0.caseInsensitiveCompare(Self.placeholder) != .orderedSame
                }
                prefilled[group] = members
                rows[group] = members.map { Row(text: $0) }
                ensureTrailingEmptyRow(group)
            }
            available = found
            phase = .editing
        } catch {
            // Saving REPLACES members, so saving over members we could not read
            // could delete people. Without a load, the only safe actions are retry
            // and skip.
            phase = .loadFailed
        }
    }

    // ── Editing ───────────────────────────────────────────────────────────────

    func setText(_ text: String, group: Group, row id: UUID) {
        guard var list = rows[group], let i = list.firstIndex(where: { $0.id == id }) else {
            return
        }
        list[i].text = text
        list[i].error = nil
        rows[group] = list
        ensureTrailingEmptyRow(group)
        if phase == .saved || phase == .confirmingSkip { phase = .editing }
    }

    func removeRow(_ id: UUID, group: Group) {
        rows[group]?.removeAll { $0.id == id }
        ensureTrailingEmptyRow(group)
    }

    /// There is always exactly one empty row at the end to type into, so more
    /// entries can be added with the keyboard alone. A run of trailing empty
    /// rows (clearing the last entry) collapses to the first of them, which
    /// keeps the row being edited.
    private func ensureTrailingEmptyRow(_ group: Group) {
        var list = rows[group] ?? []
        func blank(_ r: Row) -> Bool { r.text.trimmingCharacters(in: .whitespaces).isEmpty }
        while list.count >= 2, blank(list[list.count - 1]), blank(list[list.count - 2]) {
            list.removeLast()
        }
        if list.last.map({ !blank($0) }) ?? true {
            list.append(Row(text: ""))
        }
        rows[group] = list
    }

    func entries(_ group: Group) -> [String] {
        (rows[group] ?? []).map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A group that had members and was cleared. Saving leaves it unchanged —
    /// the endpoint cannot empty a group — so the step says so.
    func isEmptied(_ group: Group) -> Bool {
        !(prefilled[group] ?? []).isEmpty && entries(group).isEmpty
    }

    var hasChanges: Bool {
        available.contains { entries($0) != (prefilled[$0] ?? []) }
    }

    /// True when either group already has real members (placeholder excluded).
    var hadMembers: Bool { available.contains { !(prefilled[$0] ?? []).isEmpty } }

    var canSave: Bool {
        switch phase {
        case .loading, .loadFailed, .saving: return false
        default: return true
        }
    }

    // ── Actions ───────────────────────────────────────────────────────────────

    /// Continue (Return).
    func primary() async -> Outcome {
        switch phase {
        case .loading, .loadFailed, .saving:
            return .stay
        case .confirmingSkip, .saved, .savedNotRetiered:
            return .advance
        case .editing:
            if !hasChanges {
                // Nothing typed and nobody there: that is a skip, so confirm it.
                if !hadMembers && available.allSatisfy({ entries($0).isEmpty }) {
                    phase = .confirmingSkip
                    return .stay
                }
                return .advance                   // nothing to change
            }
            return await save()
        }
    }

    /// Skip (Escape). Sends nothing.
    func skip() -> Outcome {
        switch phase {
        case .confirmingSkip:
            return .advance
        case .editing where !hadMembers:
            phase = .confirmingSkip               // Tier 1 stays empty — say so first
            return .stay
        default:
            return .advance                       // existing members stay as they are
        }
    }

    /// "Go back" from the skip confirmation (Escape while confirming).
    func cancelSkip() {
        if phase == .confirmingSkip { phase = .editing }
    }

    private func save() async -> Outcome {
        phase = .saving
        generalError = nil
        // An empty list means "leave this group as it is", so a group the user
        // did not change is sent empty rather than rewritten (and re-classified)
        // for nothing.
        func outgoing(_ group: Group) -> [String] {
            guard available.contains(group) else { return [] }
            let current = entries(group)
            return current == (prefilled[group] ?? []) ? [] : current
        }
        let leadership = outgoing(.leadership)
        let family = outgoing(.family)
        do {
            let response = try await api.saveOnboardingPeople(leadership: leadership,
                                                              family: family)
            return apply(response, submitted: [.leadership: leadership, .family: family])
        } catch let rejection as OnboardingPeopleRejection {
            markRejected(rejection)
            phase = .editing
            return .stay
        } catch {
            generalError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            phase = .editing
            return .stay
        }
    }

    private func apply(_ response: OnboardingPeopleResponse,
                       submitted: [Group: [String]]) -> Outcome {
        var normalized = false
        for (name, stored) in response.groups {
            guard let group = Group(rawValue: name) else { continue }
            if stored != submitted[group] { normalized = true }
            prefilled[group] = stored
            rows[group] = stored.map { Row(text: $0) }
            ensureTrailingEmptyRow(group)
        }
        switch response.status {
        case "saved_not_retiered", "saved_partially_retiered":
            phase = .savedNotRetiered(response.status)
            return .stay
        case "saved", "unchanged":
            if normalized {
                phase = .saved
                return .stay
            }
            phase = .editing
            return .advance
        default:
            // An unknown status from a newer backend. `written` is the fact that
            // matters; show it rather than guess.
            phase = response.written ? .saved : .editing
            return .stay
        }
    }

    private func markRejected(_ rejection: OnboardingPeopleRejection) {
        var unmatched: [String] = []
        for item in rejection.invalid {
            guard let group = Group(rawValue: item.group), var list = rows[group] else {
                unmatched.append(item.error)
                continue
            }
            var hit = false
            for i in list.indices
            where list[i].text.trimmingCharacters(in: .whitespaces) == item.entry {
                list[i].error = item.error
                hit = true
            }
            rows[group] = list
            if !hit { unmatched.append(item.error) }
        }
        generalError = unmatched.isEmpty ? nil : unmatched.joined(separator: "\n")
    }
}

// ── View ─────────────────────────────────────────────────────────────────────

/// The step's content. The Back / Skip / Continue footer lives in
/// `OnboardingView`, like every other step's.
@MainActor
struct AskPeopleView: View {
    let model: AskPeopleModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Who matters most?")
                    .font(.title).bold()
                Text(model.hadMembers
                     ? "Mail from these people always lands in **Tier 1**, at the top of your list."
                     : "Mail from these people always lands in **Tier 1**, at the top of your list. Until you add someone, nothing reaches Tier 1.")
                    .fixedSize(horizontal: false, vertical: true)

                switch model.phase {
                case .loading:
                    ProgressView().controlSize(.small)
                case .loadFailed:
                    loadFailed
                case .confirmingSkip:
                    skipConfirmation
                default:
                    if case .savedNotRetiered = model.phase { notRetiered }
                    if model.phase == .saved { savedNote }
                    ForEach(model.available) { group in groupInput(group) }
                    if let error = model.generalError {
                        Text(error).font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func title(_ group: AskPeopleModel.Group) -> String {
        switch group {
        case .leadership: return "People whose mail you never want to miss at work"
        case .family:     return "Family"
        }
    }

    @ViewBuilder
    private func groupInput(_ group: AskPeopleModel.Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title(group)).font(.headline)
            ForEach(model.rows[group] ?? []) { row in
                VStack(alignment: .leading, spacing: 2) {
                    TextField("name@example.com", text: Binding(
                        get: { row.text },
                        set: { model.setText($0, group: group, row: row.id) }))
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.phase == .saving)
                    if let error = row.error {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if group == .leadership {
                Text("You can enter a whole domain (for example example.com) to cover everyone there.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isEmptied(group) {
                Label("This step can’t remove everyone from a group, so saving leaves it as it is. To empty it, use Settings › Sender groups.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var loadFailed: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Couldn’t load your current groups, so this step can’t save safely. Try again, or skip and add people later in Settings › Sender groups.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { Task { await model.load() } }
        }
    }

    private var skipConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Skip for now?", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("Without anyone here, nothing reaches Tier 1 and focus mode stays silent. You can add people any time in Settings › Sender groups.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var savedNote: some View {
        Label("Saved. A domain is stored as @domain, which matches everyone at that domain.",
              systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var notRetiered: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Your people are saved.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Mail Thresher had already fetched wasn’t re-sorted, so some of it may still sit in a lower tier. To fix that, open Settings › Classification rules and choose Reclassify all mail.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
