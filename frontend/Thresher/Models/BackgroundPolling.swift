//
//  BackgroundPolling.swift
//  Thresher
//
//  D67 (OI33) — turning off the inherited always-on backend from inside the app.
//
//  WHY THIS EXISTS
//  ---------------
//  D66 handed the backend to launchd so a crashed poller could not stay dead for
//  13 days. That was an OUTAGE FIX and it worked, but it was never a product
//  decision: it left two agents running at login, polling a mailbox whether or
//  not the app was open, with no UI saying so, no pause, and no way out except a
//  terminal command. Dragging the app to the Trash left them polling forever.
//
//  For beta the model is app-lifetime: the backend runs while the app runs.
//  This type is the migration path off the always-on install — the off switch
//  that should have shipped with D66.
//
//  ON THE TIER 1 INVARIANT
//  -----------------------
//  Worth being precise, because it reads like a violation and is not. The
//  invariant (constitution §3.2) is "Tier 1 emails MUST always surface an
//  ambient alert, REGARDLESS OF OPERATING MODE. No mode suppresses Tier 1" — it
//  governs Focus vs Catch-up, not whether a process is running. And spec.md §3
//  promises only "periodically poll for new messages (default 5 minutes)"; it
//  never promised polling while the app is closed. Always-on came from D66's
//  implementation, not from the spec.
//
//  So this narrows to what was specified rather than retreating from it. The
//  honest statement of the trade is still owed to the user, and it is in
//  BEHAVIOR.md rather than buried here: with the app closed, mail is not
//  fetched, and an urgent message waits until you next open it.
//

import Foundation

/// The launchctl operations this needs, behind a protocol so the decision logic
/// is testable without touching real launchd.
protocol AgentHosting: Sendable {
    func isLoaded(_ label: String) -> Bool
    func bootout(_ label: String) throws
    func removePlist(_ label: String) throws
}

enum BackgroundPollingError: LocalizedError, Equatable {
    case couldNotStop(String)

    var errorDescription: String? {
        switch self {
        case .couldNotStop(let label):
            return "Couldn’t stop \(label). Background polling may still be "
                 + "running — run `scripts/launchagent.sh uninstall` in Terminal."
        }
    }
}

/// Reads and removes the D66 launchd agents.
struct BackgroundPolling {

    // These strings are the contract with scripts/launchagent.sh. A mismatch
    // means the app reports "not supervised" while two agents poll the mailbox
    // — failing toward silence, the direction this code exists to prevent.
    static let pipelineLabel = "com.tomelrod.thresher.pipeline"
    static let apiLabel = "com.tomelrod.thresher.api"
    static var allLabels: [String] { [pipelineLabel, apiLabel] }

    private let host: AgentHosting

    init(host: AgentHosting = LaunchctlHost()) { self.host = host }

    /// Is the always-on backend installed?
    ///
    /// True if EITHER agent is loaded, not both. A half-installed state still
    /// polls the mailbox, so it still needs the off switch; requiring both would
    /// hide precisely the broken install a user most wants gone.
    var isSupervised: Bool {
        Self.allLabels.contains { host.isLoaded($0) }
    }

    /// Stop and remove both agents.
    ///
    /// Unload AND delete the plist. Unloading alone leaves them to reload at the
    /// next login — the user asked for it to stop, and it would come back behind
    /// their back, which is the worst version of this bug because it looks like
    /// it worked.
    ///
    /// Idempotent: nothing loaded is the desired end state, so a second click is
    /// not an error. Plists are removed even when nothing is loaded, because
    /// "not running" is not "not installed".
    ///
    /// Continues past a failure on one agent before throwing. Partial progress
    /// beats none — if the API cannot be stopped, the mailbox poller should
    /// still be stopped — but the error is still raised, because reporting
    /// "background polling stopped" while it is still polling is the most
    /// harmful thing this control could say.
    func disable() throws {
        var firstError: Error?
        for label in Self.allLabels {
            do {
                if host.isLoaded(label) { try host.bootout(label) }
                try host.removePlist(label)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}

/// The real implementation, shelling out to `launchctl` exactly as
/// scripts/launchagent.sh does.
struct LaunchctlHost: AgentHosting {

    private var agentDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
    }

    func isLoaded(_ label: String) -> Bool {
        // `launchctl list` prints one line per loaded job; the label is the
        // third column. Matching the whole line would also match our own
        // plist path if it appeared, so compare the column.
        guard let out = Self.run("/bin/launchctl", ["list"]) else { return false }
        return out.split(separator: "\n").contains { line in
            line.split(separator: "\t").last.map(String.init) == label
        }
    }

    func bootout(_ label: String) throws {
        let uid = getuid()
        // `bootout gui/<uid>/<label>` is the modern form used by the script.
        if Self.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"]) == nil {
            // A job that is already gone reports failure; treat still-loaded as
            // the real test rather than trusting the exit code.
            if isLoaded(label) { throw BackgroundPollingError.couldNotStop(label) }
        }
    }

    func removePlist(_ label: String) throws {
        let url = agentDir.appendingPathComponent("\(label).plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw BackgroundPollingError.couldNotStop(label)
        }
    }

    /// Run a command, returning stdout, or nil if it exited non-zero.
    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
