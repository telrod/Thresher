//
//  DockBadge.swift
//  Thresher
//
//  What the dock badge says (D51 + OI31).
//
//  D51 made the badge the count of untriaged Tier 1/2 mail, and zero clears it.
//  That is right, and it carries an ambiguity OI31 named: an empty badge means
//  BOTH "no urgent mail" and "nothing is being polled". Those are precisely the
//  two states D65 exists to tell apart — and with the window closed the badge is
//  the only surface there is, so it was the blind spot D65 left behind.
//
//  So the badge carries both facts: the count, and a `!` when a mailbox is not
//  polling. Not one or the other — replacing "3" with "!" would trade one lie
//  for another, since the three urgent messages are still there and still real.
//
//  This is a plain function rather than an inline expression in the view because
//  it now has two inputs and a resting state that must stay empty. The previous
//  one-liner had no test; a second concern bolted onto an untested expression is
//  how the count and the warning would quietly disagree.
//
//  Deliberately NOT here: any notion of "seen". D51 rejected that and nothing
//  since has changed the argument — the badge reflects triage state, which the
//  user already controls, rather than a second concept to keep in sync.
//

import Foundation

enum DockBadge {

    /// The marker appended when a mailbox is not polling. One character: the
    /// badge is small, and the point is "look at the app", not "read this".
    static let warningMarker = "!"

    /// The badge string. Empty means no badge at all.
    ///
    /// - Parameters:
    ///   - urgentNew: `counts.urgent_new` — untriaged Tier 1/2 (D51).
    ///   - health: the last `GET /health/accounts` report, or nil if we have
    ///     not successfully fetched one.
    ///
    /// `nil` health renders exactly as D51 did. "We couldn't ask" is not
    /// evidence of an outage, and inventing one because the backend was slow to
    /// answer is the false-alarm direction — the same call the list banner
    /// makes, and the same reason it discards a failed fetch rather than
    /// clearing to nil.
    static func label(urgentNew: Int, health: AccountHealthReport?) -> String {
        let count = max(urgentNew, 0)
        let countPart = count > 0 ? String(count) : ""
        // Reuse the ONE verdict function. A second "is this healthy?" rule here
        // would drift from the banner's, and two surfaces disagreeing about
        // whether mail is arriving is worse than one surface saying nothing.
        let unhealthy = AccountHealthVerdict.evaluate(health) != nil
        return unhealthy ? countPart + warningMarker : countPart
    }
}
