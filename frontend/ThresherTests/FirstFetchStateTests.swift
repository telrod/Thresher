//
//  FirstFetchStateTests.swift
//  ThresherTests
//
//  The first fetch after connecting a mailbox, and — the part that matters —
//  its FAILURE ending.
//
//  WHY THIS EXISTS. Three situations used to render identically on an empty
//  list: fetching normally, fetching slowly, and not fetching at all because
//  something broke. A user cannot tell them apart, which is this project's
//  recurring failure shape — a condition that presents as success while being
//  indistinguishable from failure. The same shape as the poller that was
//  silently abandoned (D1), the notification that logged success and reached
//  nobody (D69), and the health check that read a different source than the
//  behaviour it was checking (OI37).
//
//  So the assertions below are mostly about the failure state. "It shows a
//  spinner while fetching" is the easy half; "it STOPS showing a spinner when
//  the fetch is dead" is the half that was missing.
//

import XCTest
@testable import Thresher

@MainActor
final class FirstFetchStateTests: XCTestCase {

    private func entry(_ account: String, _ status: String,
                       detail: String = "") -> AccountHealthEntry {
        AccountHealthEntry(account: account, status: status, lastPollAt: nil,
                           secondsSince: nil, detail: detail)
    }

    /// The derivation is a pure function of its three inputs, so these tests
    /// need no view model and no fake network.
    private func state(_ health: AccountHealthReport?,
                       hasRows: Bool = false,
                       isLoading: Bool = false) -> MessageListViewModel.FirstFetchState? {
        MessageListViewModel.firstFetchState(health: health, hasRows: hasRows,
                                             isLoading: isLoading)
    }

    // ── The waiting state ────────────────────────────────────────────────────

    func testAConnectedMailboxWithNoPollYetIsFetching() {
        let st = state(AccountHealthReport(
            healthy: true, accounts: [entry("a@b.com", "never")],
            staleAfterSeconds: 660))
        XCTAssertEqual(st, .fetching)
    }

    // ── The failure ending — the requirement ─────────────────────────────────

    func testAFailingFetchIsNOTShownAsFetching() {
        /// THE POINT OF THIS FILE. A fetch that died must not keep rendering as
        /// "Fetching your mail…" — a spinner over a dead fetch is precisely the
        /// lie this state exists to prevent.
        ///
        /// VERIFIED RED by removing the error/stopped branch from `firstFetch`:
        /// the account falls through to the `never` check and reports
        /// `.fetching` forever, with a spinner, while nothing is happening.
        for status in ["error", "stopped"] {
            let st = state(AccountHealthReport(
                healthy: false,
                accounts: [entry("a@b.com", status, detail: "auth failed")],
                staleAfterSeconds: 660))
            guard case .failed = st else {
                return XCTFail("status \(status) rendered as \(String(describing: st)) "
                               + "— a dead fetch must have its own ending")
            }
        }
    }

    func testTheFailureCarriesAMessageRatherThanJustAFlag() {
        /// A terminal state that says only "failed" leaves the user with
        /// nothing to do. The health endpoint already builds a sentence; use it.
        let st = state(AccountHealthReport(
            healthy: false,
            accounts: [entry("a@b.com", "stopped", detail: "auth failed")],
            staleAfterSeconds: 660))
        guard case .failed(let message) = st else {
            return XCTFail("expected a failure state")
        }
        XCTAssertFalse(message.isEmpty, "the failure state carries no explanation")
    }

    // ── When it must NOT appear ──────────────────────────────────────────────

    func testAPollThatFinishedAndFoundNothingIsNotFetching() {
        /// "ok" with an empty store means the poll completed and the window held
        /// nothing — a finished fetch, not one in progress. Showing a spinner
        /// would misrepresent a completed operation as an ongoing one.
        let st = state(AccountHealthReport(
            healthy: true, accounts: [entry("a@b.com", "ok")],
            staleAfterSeconds: 660))
        XCTAssertNil(st)
    }

    func testNoAccountsMeansNoFirstFetchState() {
        /// Before onboarding there is nothing to fetch, so neither ending
        /// applies — the onboarding flow owns that screen.
        let st = state(AccountHealthReport(
            healthy: true, accounts: [], staleAfterSeconds: 660))
        XCTAssertNil(st)
        XCTAssertNil(state(nil))
    }
}
