//
//  SenderGroupsViewModel.swift
//  Thresher
//
//  State + CRUD for the Sender Groups editor (Settings §4.2 Phase 3 / OI11 —
//  a sibling sidebar row, not nested under Rules). @Observable / @MainActor, same
//  pattern as RulesViewModel; SettingsAPI is Sendable (D42).
//
//  Read: sender groups arrive on the SAME payload as rules — GET /rules returns
//  { rules, sender_groups } (map §"GET /rules"). There is no standalone
//  GET /sender-groups, so this VM reads via getRules and keeps only the
//  sender_groups array. include_disabled has no effect on sender groups (they
//  have no enabled flag) — we pass false.
//
//  Write: POST/PUT/DELETE /sender-groups. urgency_floor ∈ 1–5 is validated
//  client-side in the editor AND server-side (_validate_sender_group).
//

import Foundation
import Observation

@MainActor
@Observable
final class SenderGroupsViewModel {
    private(set) var groups: [SenderGroup] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

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

    /// Sender groups ride on the GET /rules payload; we keep only that array.
    /// Ordered urgency_floor ASC server-side.
    private func reload() async {
        do {
            let response = try await api.getRules(includeDisabled: false)
            groups = response.senderGroups
            errorMessage = nil
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    // ── Create / edit / delete ──────────────────────────────────────────────
    //
    // Create/edit return nil on success or a user-facing error string so the
    // editor sheet can stay open on a server 400 (e.g. urgency_floor out of range)
    // rather than dismissing.

    func create(_ body: SenderGroupWrite) async -> String? {
        do {
            _ = try await api.createSenderGroup(body)
            await reload()
            errorMessage = nil
            return nil
        } catch {
            return (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func update(id: Int, patch: SenderGroupWrite) async -> String? {
        do {
            _ = try await api.updateSenderGroup(id: id, patch: patch)
            await reload()
            errorMessage = nil
            return nil
        } catch {
            return (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func delete(_ group: SenderGroup) async {
        do {
            try await api.deleteSenderGroup(id: group.id)
            await reload()
            errorMessage = nil
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            await reload()
        }
    }
}