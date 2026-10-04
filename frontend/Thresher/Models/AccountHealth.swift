//
//  AccountHealth.swift
//  Thresher
//
//  Session 34: per-account ingestion health, from GET /health/accounts.
//
//  WHY THIS EXISTS
//  ---------------
//  On 2026-08-13 the poller died on a transient IMAP timeout and nothing
//  fetched mail for 13 days. The app looked completely healthy the whole
//  time. Worse, one of the two mailboxes had been dead for 17 HOURS before
//  the process finally exited — with no indication anywhere.
//
//  RELATIONSHIP TO ListStaleness
//  -----------------------------
//  `ListStaleness` already tells the user "no new mail in N days, check the
//  poller". It is deliberately INFERENCE from the loaded rows, and its own
//  header names the limit: it "cannot distinguish 'poller stopped' from
//  'genuinely no mail for five days'", so it declines to assert an outage it
//  has not verified. That was the right call with no health endpoint.
//
//  This is the verification it lacked, so the two compose rather than compete:
//
//    - health KNOWS (the backend reports the poller's own heartbeat) and so
//      may name the account and the cause;
//    - staleness INFERS, and stays the fallback for everything health cannot
//      see — most importantly a backend that is entirely unreachable.
//
//  Health wins where both apply: "you@example.com hasn't polled in 3 hours" is
//  strictly more actionable than "no new mail in 3 days", and it fires long
//  before the 3-day staleness threshold. Three days of silence was never the
//  right time to first hear about a dead poller.
//
//  WHAT IT DELIBERATELY DOES NOT DO
//  --------------------------------
//  It does not treat "cannot reach the backend" as an account problem. That is
//  a different failure with a different fix, the list will already have failed
//  to load, and claiming an account is unhealthy because we couldn't ask would
//  be inventing a diagnosis. `nil` — say nothing — is the honest answer there,
//  and staleness still covers the case from the data side.
//

import Foundation

/// One account's ingestion status, as reported by the backend.
struct AccountHealthEntry: Codable, Hashable, Sendable {
    let account: String
    /// "ok" · "error" · "stopped" · "stale" · "never".
    /// Kept as a String rather than an enum on purpose: an unknown status from
    /// a newer backend must not fail decoding of the whole payload and blind
    /// the banner. Unknown values are treated as not-ok but unnamed.
    let status: String
    let lastPollAt: String?
    let secondsSince: Int?
    let detail: String

    enum CodingKeys: String, CodingKey {
        case account, status, detail
        case lastPollAt = "last_poll_at"
        case secondsSince = "seconds_since"
    }

    var isOK: Bool { status == "ok" }

    /// Human phrase for how long this account has been silent.
    var silenceDescription: String? {
        guard let secondsSince else { return nil }
        let minutes = secondsSince / 60
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        let hours = minutes / 60
        if hours < 48 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        let days = hours / 24
        return days == 1 ? "1 day" : "\(days) days"
    }
}

/// The whole payload.
struct AccountHealthReport: Codable, Hashable, Sendable {
    let healthy: Bool
    let accounts: [AccountHealthEntry]
    let staleAfterSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case healthy, accounts
        case staleAfterSeconds = "stale_after_seconds"
    }
}

/// The banner verdict derived from a report.
enum AccountHealthVerdict {

    struct Warning: Equatable {
        /// User-facing sentence. Names WHICH mailbox and WHAT is wrong.
        let message: String
        /// Longer text for the tooltip, including the backend's own detail.
        let detail: String
        /// Accounts implicated, for tests and accessibility.
        let accounts: [String]
    }

    /// Build a warning, or nil when there is nothing to say.
    ///
    /// Returns nil when every account is ok — and, importantly, when the report
    /// lists NO accounts at all. An empty roster means no mailbox is connected
    /// yet (a first run, mid-onboarding); accusing the user of a broken poller
    /// before they have added an account would be a false alarm on the one
    /// screen where trust matters most.
    static func evaluate(_ report: AccountHealthReport?) -> Warning? {
        guard let report, !report.accounts.isEmpty else { return nil }
        let bad = report.accounts.filter { !$0.isOK }
        guard !bad.isEmpty else { return nil }

        let names = bad.map(\.account)
        let detail = bad
            .map { entry -> String in
                let extra = entry.detail.isEmpty ? "" : " — \(entry.detail)"
                return "\(entry.account): \(entry.status)\(extra)"
            }
            .joined(separator: "\n")

        // The single-account case gets a specific sentence; the multi-account
        // case must not bury the count, since "some mail is not arriving" is
        // the part the user needs to act on.
        let message: String
        if bad.count == report.accounts.count && report.accounts.count > 1 {
            message = "No mailbox is being checked for mail. New mail is not "
                    + "arriving — quit and reopen Thresher."
        } else if let only = bad.first, bad.count == 1 {
            message = Self.sentence(for: only, totalAccounts: report.accounts.count)
        } else {
            message = "\(bad.count) mailboxes are not being checked for mail. "
                    + "New mail is not arriving from them."
        }
        return Warning(message: message, detail: detail, accounts: names)
    }

    /// The one-account sentence, phrased by what the backend actually reported.
    ///
    /// Each status gets its own copy rather than one generic line: "stopped"
    /// (the poller told us it gave up) and "stale" (we haven't heard from it)
    /// call for different user actions, and flattening them would throw away
    /// the distinction the endpoint exists to draw.
    static func sentence(for entry: AccountHealthEntry, totalAccounts: Int) -> String {
        // With several mailboxes connected, naming the affected one is the
        // whole point — the 17-hour blind spot was ONE dead account beside a
        // healthy one, where the app as a whole looked fine.
        let who = totalAccounts > 1 ? entry.account : "The mailbox"
        let silence = entry.silenceDescription

        // WRITTEN FOR SOMEONE WITH NO TERMINAL. These sentences used to tell the
        // user to "start" or "restart the backend poller" — an instruction they
        // cannot act on, for a component they have no reason to know exists, and
        // which under D67 the APP is responsible for starting. That is
        // development-arrangement copy leaking onto a shipped surface.
        //
        // The "never" case was also actively misleading: it appears on a normal
        // first run, before the first check has finished, and read as an error
        // when nothing was wrong. Worse, in the D1 first-run bug it claimed
        // nothing had been started when in fact the poller had run four times
        // and exited.
        //
        // Each sentence now describes the STATE, and where there is a real
        // action it is one available in this app: quitting and reopening.
        switch entry.status {
        case "stopped":
            return "\(who) stopped checking for mail. New mail is not arriving — "
                 + "quit and reopen Thresher to start it again."
        case "stale":
            if let silence {
                return "\(who) hasn't checked for mail in \(silence). New mail may "
                     + "not be arriving — quit and reopen Thresher if this persists."
            }
            return "\(who) hasn't checked for mail recently. New mail may not be arriving."
        case "never":
            // Not an error. On a fresh install this is simply the truth until
            // the first check completes, and it resolves itself.
            return "Waiting for the first mail check on \(who.lowercased() == "the mailbox" ? "this mailbox" : who)."
        case "error":
            return "\(who) is having trouble checking for mail. Thresher is still trying."
        default:
            return "\(who) is not checking for mail normally (\(entry.status))."
        }
    }
}
