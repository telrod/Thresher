//
//  RulesViewModel.swift
//  Thresher
//
//  State + loading for the Classification Rules list (Settings §4.2, Phase 1).
//  @Observable / @MainActor, same pattern as EmailAccountsViewModel; the
//  SettingsAPI it calls is Sendable, so the background Tasks are
//  strict-concurrency clean (D42).
//
//  Two traps shape this model (parent §1):
//   - §1.1 — the read MUST pass `include_disabled: true`, or a toggled-off rule
//     vanishes from the list and can never be re-enabled from the UI. We never
//     call getRules without it.
//   - §1.2/§1.4 — `enabled` is read as a 0/1 INT (Rule.enabled) but written as a
//     JSON BOOL. The toggle therefore writes via `RuleWrite(enabled: <bool>)`,
//     which (omitting both effects) is a pure patch — it can't trip the
//     server-side both-null guard (§1.3).
//
//  Phase 1 scope: list + enable/disable toggle only. No editor (Phase 2),
//  no sender groups (Phase 3).
//

import Foundation
import Observation

@MainActor
@Observable
final class RulesViewModel {
    private(set) var rules: [Rule] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// Existing sender-group names (same GET /rules payload) — the editor's
    /// Value picker options when Field = Sender group (polish Part C).
    private(set) var groupNames: [String] = []

    /// Rule ids with a toggle write in flight, so a row's toggle disables itself
    /// (and shows a spinner) without freezing the rest of the list.
    private(set) var togglingIDs: Set<Int> = []

    /// True while a batch reorder write is in flight, so the list disables further
    /// drags and the section can show progress until the server confirms.
    private(set) var isReordering = false
    /// D52 part C: bulk reclassify state. Separate from isReordering so the rules
    /// list stays usable/legible about which operation is running.
    private(set) var isReclassifying = false
    /// The run summary, kept so the pane can report what happened rather than
    /// silently finishing (errors included — P1: a failed message is still stored).
    private(set) var reclassifySummary: ReclassifySummary?

    private let api: SettingsAPI

    init(api: SettingsAPI) {
        self.api = api
    }

    // ── Load ────────────────────────────────────────────────────────────────

    func load() async {
        isLoading = true
        await reload()
        isLoading = false
    }

    /// Fetch rules with `include_disabled: true` (trap §1.1) so disabled rows
    /// stay visible and re-enableable. Sender groups arrive on the same payload;
    /// their names feed the editor's Value picker for `field = sender_group`
    /// (polish Part C — a typed nonexistent group can never match).
    private func reload() async {
        do {
            let response = try await api.getRules(includeDisabled: true)
            rules = response.rules
            groupNames = response.senderGroups.map(\.groupName)
            errorMessage = nil
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    // ── Enable / disable toggle (int-read / bool-write, trap §1.2) ────────────

    /// Flip a rule's enabled flag via `PUT /rules/<id> {"enabled": <bool>}`.
    /// Patch semantics: only `enabled` is sent, so the effects are left intact and
    /// the both-null guard can't fire (§1.3). The returned rule (full row, 0/1
    /// int) replaces the local copy so the row reflects server truth — and stays
    /// visible across enabled→disabled→enabled (proves §1.1).
    func setEnabled(_ rule: Rule, to enabled: Bool) async {
        guard !togglingIDs.contains(rule.id) else { return }
        togglingIDs.insert(rule.id)
        defer { togglingIDs.remove(rule.id) }

        do {
            let updated = try await api.updateRule(id: rule.id, patch: RuleWrite(enabled: enabled))
            if let idx = rules.firstIndex(where: { $0.id == updated.id }) {
                rules[idx] = updated
            } else {
                // The row moved out from under us (e.g. a concurrent reload);
                // reconcile by reloading rather than guessing.
                await reload()
            }
            errorMessage = nil
        } catch {
            // The write failed — surface it and reload so the toggle snaps back
            // to the real server state rather than lying about the flip.
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            await reload()
        }
    }

    func isToggling(_ rule: Rule) -> Bool { togglingIDs.contains(rule.id) }

    // ── Create / edit / delete (Phase 2) ──────────────────────────────────────
    //
    // Each write reloads the list from the server afterward so the local rows
    // reflect server truth — including the server-assigned priority (a new rule
    // appends at MAX+1, D44) and the both-null guard's rejection (§1.3). The
    // caller (editor sheet) inspects the thrown error for a validation message;
    // these return the error string (nil on success) so the sheet can stay open
    // and show it rather than dismissing on a 400.

    /// Create a rule (`POST /rules`). Returns nil on success, or a user-facing
    /// error string (e.g. the both-null guard 400) so the editor can keep the
    /// sheet open and surface it.
    func create(_ body: RuleWrite) async -> String? {
        do {
            _ = try await api.createRule(body)
            await reload()
            errorMessage = nil
            return nil
        } catch {
            return (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Edit a rule (`PUT /rules/<id>`, patch semantics). Returns nil on success or
    /// an error string. The editor sends the full effect state each time, so the
    /// post-merge both-null guard (§1.3) only fires on a genuinely no-effect rule.
    func update(id: Int, patch: RuleWrite) async -> String? {
        do {
            _ = try await api.updateRule(id: id, patch: patch)
            await reload()
            errorMessage = nil
            return nil
        } catch {
            return (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Delete a rule (`DELETE /rules/<id>`). Config hard-delete (P1 is about
    /// messages, not rules). Surfaces failure into `errorMessage` + reloads.
    func delete(_ rule: Rule) async {
        do {
            try await api.deleteRule(id: rule.id)
            await reload()
            errorMessage = nil
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            await reload()
        }
    }

    // ── Reorder (D44 batch) ────────────────────────────────────────────────────

    /// Reorder rules by moving the rows at `source` to `destination` (SwiftUI
    /// `.onMove` semantics), then persist the whole new order via the batch
    /// endpoint. Optimistically applies the move locally so the drag feels
    /// immediate, then reconciles from the server's dense-renumbered response.
    ///
    /// On a `409` stale set (a rule was created/deleted elsewhere since load), the
    /// local order is not what the server has — we refetch and re-present (the map
    /// remedy) rather than pushing a bad permutation again. `400` (shouldn't
    /// happen from a UI-built full permutation) is surfaced the same way.
    func move(from source: IndexSet, to destination: Int) async {
        guard !isReordering else { return }
        // Optimistic local reorder for immediate feedback.
        let previous = rules
        rules.move(fromOffsets: source, toOffset: destination)
        let orderedIds = rules.map(\.id)

        isReordering = true
        defer { isReordering = false }
        do {
            let reordered = try await api.reorderRules(orderedIds: orderedIds)
            rules = reordered           // server truth: dense 1..N priorities
            errorMessage = nil
        } catch {
            // Roll back the optimistic move, then reconcile against the live table
            // (a 409 means membership drifted — refetch shows the real set).
            rules = previous
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            await reload()
        }
    }

    // ── D52 part C: reclassify the whole store ──────────────────────────────

    /// Re-run the current engine over every stored message. Explicit, one-off user
    /// action — this is NOT a background job and must never read as one (invariant
    /// 4). The server preserves every triage state (invariant 1) and fires no
    /// notifications for the run (invariant 2).
    func reclassifyAll() async {
        guard !isReclassifying else { return }
        isReclassifying = true
        reclassifySummary = nil
        defer { isReclassifying = false }
        do {
            reclassifySummary = try await api.reclassifyAllMessages()
            errorMessage = nil
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

}