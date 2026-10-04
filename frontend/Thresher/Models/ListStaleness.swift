//
//  ListStaleness.swift
//  Thresher
//
//  Part 1 of the gate-defects workorder: tell the user when the store is stale.
//
//  WHY THIS EXISTS
//  ---------------
//  The gate complaint was "today's mail isn't on page one of Open". The live
//  store said otherwise: the backend had been stopped for five days, so the
//  newest message was 4.94 days old. D57's ordering was right the whole time —
//  there was no fresh mail to order. A live poll ingested 48 messages and every
//  one of that day's landed on page one.
//
//  The real defect is that a stale store and a quiet one look IDENTICAL. Both
//  render old mail; neither says anything. The user cannot tell "nothing
//  arrived" from "nothing is running", and the second one is silently broken.
//  That ambiguity is the same family as OI21's silent truncation — the UI
//  implying something it hasn't checked — and it gets the same treatment: name
//  the situation instead of letting the absence speak.
//
//  Deliberately derived from the DATA the list already has (the newest
//  `received_at` among loaded rows) rather than a new backend health endpoint:
//  it needs no extra request, and it is true of what the user is actually
//  looking at. It cannot distinguish "poller stopped" from "genuinely no mail
//  for five days", so the copy says "no new mail in N days" and raises the
//  backend as the thing to check — it does not assert an outage it hasn't
//  verified.
//

import Foundation

/// A staleness verdict for the message list.
enum ListStaleness {

    /// How old the newest message must be before the list says anything.
    ///
    /// Three days, not one: a quiet weekend is normal and a banner that fires
    /// every Monday is a banner that gets ignored. Five days — the observed
    /// gate case — is comfortably past it.
    static let thresholdDays: Double = 3

    struct Verdict: Equatable {
        /// Whole days since the newest message arrived.
        let days: Int
        /// User-facing copy. Names the gap AND points at the likely cause.
        let message: String
    }

    /// Evaluate staleness from the newest `received_at` the list has loaded.
    ///
    /// Returns nil — meaning "say nothing" — for every case where staleness is
    /// not actually established:
    ///  - `nil` timestamp (an empty store; a first run has no mail yet and must
    ///    not be accused of an outage);
    ///  - an unparseable timestamp (which must not read as infinitely old and
    ///    pin a permanent banner);
    ///  - a future timestamp (clock skew must not yield a negative-day banner);
    ///  - anything inside the threshold.
    static func evaluate(newestReceivedAt: String?,
                         now: Date = Date()) -> Verdict? {
        guard let raw = newestReceivedAt else { return nil }
        return evaluate(newest: parse(raw), now: now)
    }

    /// Same verdict from an already-parsed date — the form the list uses, since
    /// it must pick the newest row by parsed date rather than string order.
    static func evaluate(newest: Date?, now: Date = Date()) -> Verdict? {
        guard let newest else { return nil }

        let elapsed = now.timeIntervalSince(newest)
        guard elapsed > 0 else { return nil }        // future / skew

        let days = elapsed / 86_400
        guard days >= thresholdDays else { return nil }

        let whole = Int(days.rounded(.down))
        return Verdict(days: whole, message: describe(days: whole))
    }

    /// The banner copy.
    ///
    /// "No new mail in N days" alone would invite exactly the wrong conclusion
    /// — a quiet inbox — which is the ambiguity this whole file exists to
    /// remove. So the sentence names the gap and then names the thing to check.
    static func describe(days: Int) -> String {
        let unit = days == 1 ? "1 day" : "\(days) days"
        return "No new mail in \(unit). Check that the backend poller is running."
    }

    /// Parse a stored `received_at`. The backend emits ISO-8601 with an offset;
    /// accept both the with- and without-fractional-seconds spellings rather
    /// than assuming one, since a parse failure here would silently disable the
    /// indicator.
    static func parse(_ raw: String) -> Date? {
        if let d = ISO8601DateFormatter.listBound.date(from: raw) { return d }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFractional.date(from: raw)
    }
}