//
//  MessageDetailViewModel.swift
//  Thresher
//
//  State + loading for the Message Detail screen (§4.1.2). @Observable, @MainActor
//  (D36 / strict concurrency D42). The APIClient it calls is Sendable, so the
//  background Task fetches don't reintroduce last session's isolation issues.
//
//  P3: the message detail fetch already folds the human-readable `explanation`
//  in, so the reasoning is available the moment the message loads — no separate
//  round-trip the user has to initiate. We additionally fetch /explain for the
//  structured rule breakdown, but that's a graceful enhancement: it 404s for
//  unclassified mail (the explain/explanation asymmetry), which we treat as
//  "no structured detail" rather than an error (P1/P2).
//

import Foundation
import Observation

@MainActor
@Observable
final class MessageDetailViewModel {
    private(set) var detail: MessageDetail?
    private(set) var thread: [MessageListRow] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// Structured rule breakdown from /explain. nil when unclassified (the
    /// endpoint 404s) OR not yet loaded — the view falls back to the folded
    /// `explanation` text, which is the P3-satisfying source.
    private(set) var structuredExplanation: Explanation?
    private(set) var isUpdatingTriage = false
    /// D52: in-flight flag for "Reclassify now" (its own, so the triage control
    /// doesn't grey out while a reclassification runs).
    private(set) var isReclassifying = false
    /// D52: set after a successful reclassification so the panel can confirm what
    /// happened — "no change" is a real, useful answer and must not read as failure.
    private(set) var lastReclassifyNote: String?

    let messageID: String
    private let api: MessageAPI
    /// E20: called with (messageID, server-confirmed triage_state raw value)
    /// after a successful triage write, so the owning split view can patch the
    /// list row in place — the detail and list VMs are otherwise independent.
    private let onTriageChange: ((String, String) -> Void)?

    init(messageID: String, api: MessageAPI,
         onTriageChange: ((String, String) -> Void)? = nil) {
        self.messageID = messageID
        self.api = api
        self.onTriageChange = onTriageChange
    }

    // ── Load ────────────────────────────────────────────────────────────────

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            // The detail fetch carries the folded explanation (P3) in one call.
            detail = try await api.getMessage(id: messageID)
        } catch {
            detail = nil
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false

        // Best-effort structured breakdown. Unclassified mail 404s here — that's
        // expected and returns nil, NOT an error the user sees.
        structuredExplanation = (try? await api.explain(id: messageID)) ?? nil
    }

    /// Load the conversation (received_at ASC) for this message's thread, if it
    /// has one. List-shape rows (no bodies) per the contract.
    func loadThread() async {
        guard let threadID = detail?.threadID, !threadID.isEmpty else {
            thread = []
            return
        }
        thread = (try? await api.thread(id: threadID)) ?? []
    }

    // ── Triage (§3.4.1 state machine) ─────────────────────────────────────────

    /// The triage states a message can move to, in order. Unclassified mail has
    /// no classification row, so it can't be triaged — the view disables the
    /// controls in that case (the endpoint would 404).
    var canTriage: Bool { detail?.isClassified ?? false }

    func setTriage(_ state: TriageState) async {
        guard !isUpdatingTriage else { return }
        isUpdatingTriage = true
        defer { isUpdatingTriage = false }
        do {
            let resp = try await api.setTriage(id: messageID, state: state)
            // Reflect the server-confirmed state locally without a full refetch
            // (P2 — no jarring reload). Rebuild the detail with the new state.
            if let d = detail {
                detail = d.withTriageState(resp.triageState)
            }
            // E20: let the list patch its row too — server-confirmed state only,
            // so the two panes can never disagree about what was written.
            onTriageChange?(messageID, resp.triageState)
            errorMessage = nil
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    // ── D52 part A: reclassify this message ─────────────────────────────────

    /// Re-run the current engine over this message. Explicit user action only
    /// (invariant 4). The server preserves triage state (invariant 1) and fires no
    /// notifications (invariant 2); we ASSERT the former by taking the triage state
    /// from the response rather than assuming ours still holds.
    func reclassify() async {
        guard !isReclassifying else { return }
        isReclassifying = true
        defer { isReclassifying = false }
        do {
            let r = try await api.reclassify(id: messageID)
            if let d = detail {
                detail = d.withReclassification(r)
            }
            // Reload the structured breakdown: the rules that matched have changed,
            // so a stale panel would be actively misleading (P3).
            structuredExplanation = (try? await api.explain(id: messageID)) ?? nil
            lastReclassifyNote = r.changed
                ? "Updated to T\(r.urgencyTier) · \(r.category.capitalized)"
                : "No change — the current rules produce the same result"
            // The tier may have moved, so let the list patch its row (the E20 seam).
            onTriageChange?(messageID, r.triageState)
            errorMessage = nil
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private extension MessageDetail {
    /// Return a copy with an updated triage_state (the only field the triage
    /// control mutates). Keeps the rest of the immutable struct intact.
    func withTriageState(_ newState: String) -> MessageDetail {
        MessageDetail(
            id: id, account: account, threadID: threadID,
            senderName: senderName, senderEmail: senderEmail, subject: subject,
            receivedAt: receivedAt, ingestedAt: ingestedAt, preview: preview,
            bodyPlain: bodyPlain, bodyHTML: bodyHTML,
            urgencyTier: urgencyTier, category: category, triageState: newState,
            explanation: explanation, ruleMatches: ruleMatches,
            rfc822MessageID: rfc822MessageID,
            classifiedAt: classifiedAt, reclassifiedAt: reclassifiedAt,
            rulesChangedSince: rulesChangedSince
        )
    }

    /// D52: fold a reclassification result into the detail, in place (the E20
    /// no-refetch seam). `triageState` comes from the SERVER's response, not from
    /// the local copy — that is how invariant 1 is asserted rather than assumed.
    /// `rulesChangedSince` resets to 0: the classification is now newer than every
    /// rule edit, so any staleness note must disappear.
    func withReclassification(_ r: ReclassifyResult) -> MessageDetail {
        MessageDetail(
            id: id, account: account, threadID: threadID,
            senderName: senderName, senderEmail: senderEmail, subject: subject,
            receivedAt: receivedAt, ingestedAt: ingestedAt, preview: preview,
            bodyPlain: bodyPlain, bodyHTML: bodyHTML,
            urgencyTier: r.urgencyTier, category: r.category,
            triageState: r.triageState,
            explanation: explanation, ruleMatches: ruleMatches,
            rfc822MessageID: rfc822MessageID,
            classifiedAt: r.classifiedAt, reclassifiedAt: r.reclassifiedAt,
            rulesChangedSince: 0
        )
    }
}