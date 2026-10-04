//
//  BuildProvenance.swift
//  Thresher
//
//  "Which code am I running?" as a displayed fact, on both sides of the seam.
//
//  Session 27 opened with BOTH runtime artifacts stale — the backend process and the
//  installed /Applications binary each predated the D50+D51 batch — and the only tell
//  was inference ("do I see chips?"). A gate pass against the wrong binary is a false
//  PASS recorded with full confidence, which the OI14 occlusion arc already showed can
//  re-close a real bug.
//
//  Design (from the workorder): no manual bumping (anything a human must remember to
//  update will drift), passive display (P2 — inform, never interrupt), dirty-tree
//  honesty, and graceful degradation to "unknown" rather than a fabricated value.
//

import Foundation

/// `GET /version` — the backend's provenance.
struct BackendVersion: Codable, Hashable, Sendable {
    let gitSHA: String
    let startedAt: String

    enum CodingKeys: String, CodingKey {
        case gitSHA = "git_sha"
        case startedAt = "started_at"
    }
}

/// The app's own build stamp, read from the Info.plist keys the build phase writes.
/// Never crashes and never fabricates: a missing key reads "unknown", which is itself
/// provenance-relevant (it means this build predates the stamping phase).
struct AppBuildStamp: Hashable, Sendable {
    let sha: String
    let builtAt: String

    static let current = AppBuildStamp(
        sha: (Bundle.main.object(forInfoDictionaryKey: "ISBuildSHA") as? String) ?? "unknown",
        builtAt: (Bundle.main.object(forInfoDictionaryKey: "ISBuildDate") as? String) ?? "unknown")

    /// `App <sha> · built <date>`, with the date shown in the user's locale when it
    /// parses and verbatim when it doesn't (better a raw stamp than a dropped one).
    var displayLine: String {
        var line = "App \(sha)"
        if builtAt != "unknown" {
            let f = ISO8601DateFormatter()
            if let d = f.date(from: builtAt) {
                let out = DateFormatter()
                out.dateStyle = .medium
                out.timeStyle = .short
                line += " · built \(out.string(from: d))"
            } else {
                line += " · built \(builtAt)"
            }
        }
        return line
    }

    /// True when both SHAs are known AND differ — the only case worth marking.
    /// "unknown" on either side is not a mismatch, it's missing information, and
    /// claiming a mismatch from missing data would be its own false signal.
    func mismatches(_ backend: BackendVersion?) -> Bool {
        guard let backend else { return false }
        guard sha != "unknown", backend.gitSHA != "unknown" else { return false }
        return sha != backend.gitSHA
    }
}
