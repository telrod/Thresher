//
//  RetrievalWindow.swift
//  Thresher
//
//  D61 — how far back mail is retrieved when an account is FIRST connected.
//
//  The window is resolved to an absolute cutoff server-side at connect time and
//  applies to the initial backfill ONLY; after that it stops filtering, so
//  closing the app for two weeks still retrieves those two weeks. See
//  BEHAVIOR.md, "The retrieval window applies to setup only".
//
//  THE CHOICE IS ONE-WAY. Widening later is not supported, which is why the
//  default here is the middle option rather than the narrowest: an over-narrow
//  choice is the unrecoverable mistake, and BEHAVIOR.md tells the user in as many
//  words to "pick a wider window than you think you need". (backfill-scope §6.2
//  originally asked for "start from now" as the default; that was written before
//  D61 settled the asymmetry, and defaulting to the narrowest option would
//  contradict the shipped decision.)
//
//  `rawValue` is the wire value POST /accounts and POST /accounts/preview accept.
//  The server 400s an unknown one, so these MUST stay in step with
//  RETRIEVAL_WINDOWS in api/app.py.
//

import Foundation

enum RetrievalWindow: String, CaseIterable, Identifiable, Sendable {
    case oneWeek = "1w"
    case oneMonth = "1m"
    case threeMonths = "3m"
    case everything = "everything"

    var id: String { rawValue }

    /// The default. Middle of the range: recent mail is present so the app is
    /// useful immediately, without dragging in years of dead mail.
    static let `default`: RetrievalWindow = .threeMonths

    var label: String {
        switch self {
        case .oneWeek: return "Last week"
        case .oneMonth: return "Last month"
        case .threeMonths: return "Last 3 months"
        case .everything: return "Everything"
        }
    }

    /// The consequence, in messages rather than adjectives. Shown under the
    /// picker; §6.3 of the work order is explicit that "start from now" vs
    /// "import everything" is not enough on its own.
    var consequence: String {
        switch self {
        case .everything:
            return "Your entire inbox is retrieved. For a large mailbox this can "
                 + "take several minutes and will fill the list with old mail."
        default:
            return "Mail older than this is never retrieved, and it cannot be "
                 + "added later without starting over with a new account. "
                 + "Nothing is deleted — older mail stays on your mail server."
        }
    }

    /// Only INBOX is ever polled, everywhere in this app. Worth saying once here
    /// so "everything" isn't read as "every folder" (work order §8).
    static let mailboxScopeNote = "Only your inbox is retrieved — not archived "
        + "mail, spam, or other folders."
}

/// `POST /accounts/preview` → `{account, counts: {"1w": 42, …}}`. How many
/// messages each window would actually retrieve, asked BEFORE the credential is
/// stored so the number can inform the choice rather than explain it afterwards.
struct RetrievalPreview: Codable, Sendable {
    let account: String
    let counts: [String: Int]

    /// The count for one window, or nil when the server didn't report it.
    func count(for window: RetrievalWindow) -> Int? { counts[window.rawValue] }
}
