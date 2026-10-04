//
//  BackendSupervisor.swift
//  Thresher
//
//  D67, second half — the app owns the backend's lifetime.
//
//  WHY
//  ---
//  D66 handed the backend to launchd because a crashed poller stayed dead for 13
//  days. D67 chose app-lifetime instead: two login agents polling a stranger's
//  mailbox forever is a bigger imposition than "an app I open", and the Tier 1
//  invariant does not require otherwise (constitution §3.2 governs operating
//  MODES, not process lifetime; spec.md §3 never promised polling while closed).
//
//  But the trade is only honest if the app is as reliable a supervisor as
//  launchd was FOR THE WINDOW IT COVERS. launchd gave two things, and both have
//  to survive the move:
//
//    1. KeepAlive — a crash is not permanent.        → `restartAnythingThatDied`
//    2. ThrottleInterval — a broken config does not  → `maxRestarts`
//       spin the CPU forever.
//
//  Losing (1) would reproduce the 13-day outage in miniature: a poller that
//  crashes at 9am inside a running app stays dead all day, silently, which is
//  precisely the failure this project has already paid for once.
//
//  WHAT THIS DELIBERATELY DOES NOT DO
//  ----------------------------------
//  It does not locate the backend by guessing. The app bundle ships no Python
//  and no `backend/` directory (verified: Contents/Resources holds an icon and
//  an asset catalog), so on a machine that is not the author's checkout there is
//  nothing to start. Guessing a path would produce a supervisor that silently
//  supervises nothing — the worst outcome, because it looks installed. It
//  throws and names the fix instead. **Packaging remains the open half of D67**
//  and this type is written to be ready for it: give it a real path and it works
//  unchanged.
//
//  It also stands down entirely when launchd already owns the backend, because
//  two supervisors restarting each other's corpses is worse than either alone —
//  the same rule `launchagent.sh install` enforces from the other side.
//

import Foundation

/// Process operations, behind a protocol so the supervision logic is testable
/// without spawning anything.
protocol BackendProcessHosting: Sendable {
    func isRunning(_ id: String) -> Bool
    func launch(_ id: String, python: URL, arguments: [String], workingDirectory: URL) throws
    func terminate(_ id: String)
    func isPortInUse(_ port: Int) -> Bool
    /// Exit status of the last run of `id`, or nil if it never ran or is running.
    ///
    /// Needed because "it stopped" is not one condition. A backend that exited
    /// because it had nothing to do yet must be waited for, not counted as a
    /// death — see `BackendSupervisor.exitNotConfigured`.
    func lastExitStatus(_ id: String) -> Int32?
}

enum BackendSupervisorError: LocalizedError, Equatable {
    case backendNotFound
    case pythonNotFound
    case launchFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .backendNotFound:
            return "Couldn’t find the Thresher backend. Set "
                 + "THRESHER_BACKEND_DIR to the repository's backend/ folder."
        case .pythonNotFound:
            return "Couldn’t find a python3 with Flask installed. Set "
                 + "THRESHER_PYTHON to a suitable interpreter."
        case .launchFailed(let id, let detail):
            return "Couldn’t start the \(id): \(detail)"
        }
    }
}

@MainActor
final class BackendSupervisor {

    static let pollerID = "poller"
    static let apiID = "api"
    static let apiPort = 8765

    /// How many times a process is relaunched before we stop and report.
    /// launchd used ThrottleInterval=30 for the same reason: a backend that
    /// cannot start — bad App Password, missing dependency — must not be
    /// retried forever, spinning the CPU and burying the real error.
    static let maxRestarts = 3

    /// Exit code meaning "no work available yet — keep watching, do not spend a
    /// restart." **Mirrored from `backend/main.py`'s EXIT_NOT_CONFIGURED; the
    /// two must agree**, and a test on each side pins its half of the contract.
    static let exitNotConfigured: Int32 = 3

    /// The supervisor's OWN log — separate from the two backend processes'.
    ///
    /// Its events are the ones with no other home: what start() did, a launch
    /// that failed, giving up on a process. Previously these went to NSLog and
    /// produced nothing findable — searching the unified log after the D1
    /// investigation returned no entries at all.
    static func appendToSupervisorLog(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        guard let data = line.data(using: .utf8),
              let handle = LocalProcessHost.logHandle(for: "supervisor") else { return }
        defer { try? handle.close() }
        handle.write(data)
    }

    /// One place that maps a process id to its arguments, so `start()` and
    /// `restartAnythingThatDied()` cannot drift into launching different things.
    static func arguments(for id: String) -> [String] {
        id == pollerID ? ["main.py"] : ["-m", "api.server"]
    }

    private let host: BackendProcessHosting
    private let backendDirectory: URL?
    private let python: URL?

    /// What THIS supervisor started. Only these are ever restarted or
    /// terminated — killing a backend we did not start would, on a supervised
    /// machine, make launchd restart it in a loop while the user watches mail
    /// stop and start.
    private var owned: Set<String> = []
    private var restarts: [String: Int] = [:]
    private var gaveUp: Set<String> = []
    /// Set by `stop()`, so the health check does not resurrect a backend the
    /// user (or app termination) deliberately stopped.
    private var stopped = false

    init(host: BackendProcessHosting = LocalProcessHost(),
         backendDirectory: URL? = BackendSupervisor.locateBackend(),
         python: URL? = BackendSupervisor.locatePython()) {
        self.host = host
        self.backendDirectory = backendDirectory
        self.python = python
    }

    /// Should the app manage the backend at all?
    ///
    /// No when launchd already owns it: alpha is still supervised (D66) and must
    /// stay that way until packaging lands. Two supervisors racing for the same
    /// processes is the failure `launchagent.sh install` refuses to allow, and
    /// it is worse here because each would restart what the other killed.
    nonisolated static func shouldManageBackend(launchdOwnsIt: Bool) -> Bool { !launchdOwnsIt }

    // ── Lifecycle ────────────────────────────────────────────────────────────

    /// Start whatever is not already running. Idempotent: a second window, a
    /// relaunch, or a retry must not produce a second poller — two pollers
    /// against one SQLite store is a worse failure than none, and it would look
    /// like it worked.
    /// What `start()` actually did, so the caller can report it.
    ///
    /// The poller cannot silently fail to start — a failed launch throws. What
    /// this exists for is the API SKIP, which is deliberate and silent: another
    /// process already holds the port. On the D67 path (the app owning its own
    /// backend) that should never happen, so `apiSkippedPortInUse` appearing in
    /// a user's log is itself a finding — something else is serving the store.
    struct StartSummary: Equatable {
        var startedPoller = false
        var startedAPI = false
        var pollerAlreadyRunning = false
        var apiAlreadyRunning = false
        var apiSkippedPortInUse = false

        /// One line for a log. Says what happened, not what was intended.
        var summary: String {
            var parts: [String] = []
            if startedPoller { parts.append("started poller") }
            else if pollerAlreadyRunning { parts.append("poller already running") }
            if startedAPI { parts.append("started API") }
            else if apiAlreadyRunning { parts.append("API already running") }
            else if apiSkippedPortInUse { parts.append("skipped API (port held)") }
            return parts.isEmpty ? "nothing to start" : parts.joined(separator: ", ")
        }
    }

    @discardableResult
    func start() throws -> StartSummary {
        guard let backendDirectory else { throw BackendSupervisorError.backendNotFound }
        guard let python else { throw BackendSupervisorError.pythonNotFound }
        stopped = false
        var summary = StartSummary()

        if !host.isRunning(Self.pollerID) {
            try host.launch(Self.pollerID, python: python,
                            arguments: Self.arguments(for: Self.pollerID),
                            workingDirectory: backendDirectory)
            owned.insert(Self.pollerID)
            summary.startedPoller = true
        } else {
            summary.pollerAlreadyRunning = true
        }

        // The API is skipped when something already holds the port — launchd on
        // this machine, or a backend.sh orphan. That process serves the same
        // store, so a second one would either fail noisily or race it. The
        // POLLER is still started regardless: an API being up says nothing about
        // whether anything is FETCHING, which is the half that caused the
        // 13-day outage.
        if host.isRunning(Self.apiID) {
            summary.apiAlreadyRunning = true
        } else if host.isPortInUse(Self.apiPort) {
            summary.apiSkippedPortInUse = true
        } else {
            try host.launch(Self.apiID, python: python,
                            arguments: Self.arguments(for: Self.apiID),
                            workingDirectory: backendDirectory)
            owned.insert(Self.apiID)
            summary.startedAPI = true
        }
        return summary
    }

    /// Stop only what this supervisor started.
    func stop() {
        stopped = true
        for id in owned where host.isRunning(id) {
            host.terminate(id)
        }
        owned.removeAll()
    }

    /// launchd's KeepAlive, in app form: relaunch anything we started that has
    /// since died. Called on a timer while the app runs.
    ///
    /// Bounded by `maxRestarts` — a process that keeps dying is reported rather
    /// than retried forever. Never runs after `stop()`, or quitting the app and
    /// the "Stop background polling" control would both be fighting a supervisor
    /// that dutifully brings the poller back.
    func restartAnythingThatDied() {
        guard !stopped else { return }
        guard let backendDirectory, let python else { return }

        for id in owned where !host.isRunning(id) {
            guard !gaveUp.contains(id) else { continue }

            // "Not configured yet" is a WAIT, not a death. The backend exits
            // with this code when no account is connected — which is every
            // launch before the user finishes onboarding. Counting it as a
            // death is what abandoned the poller on every first run: three
            // restarts 30s apart, all against a condition that resolves the
            // moment a credential is stored, then `gaveUp` FOREVER — roughly
            // 90 seconds before the user could possibly have typed a password.
            //
            // Relaunching without incrementing `restarts` is deliberate: the
            // budget exists to stop a genuinely broken backend spinning the
            // CPU, and this is not that. The relaunch is cheap (a process that
            // exits immediately) and it means the poller is already running the
            // instant an account appears, with no extra signalling path.
            if host.lastExitStatus(id) == Self.exitNotConfigured {
                try? host.launch(id, python: python,
                                 arguments: Self.arguments(for: id),
                                 workingDirectory: backendDirectory)
                continue
            }

            let count = restarts[id, default: 0]
            guard count < Self.maxRestarts else {
                gaveUp.insert(id)
                // The single most important line this app can write: from here
                // on, that process is never coming back without a relaunch, and
                // nothing in the UI says so.
                Self.appendToSupervisorLog(
                    "gave up on \(id) after \(count) restarts "
                    + "(last exit \(host.lastExitStatus(id).map(String.init) ?? "unknown")) "
                    + "— it will not be retried until the app is restarted")
                continue
            }
            restarts[id] = count + 1
            try? host.launch(id, python: python,
                             arguments: Self.arguments(for: id),
                             workingDirectory: backendDirectory)
        }
    }

    /// Has a process failed too many times to keep retrying? Surfaced so the UI
    /// can say so — a supervisor that quietly gives up is the silent failure
    /// D65 exists to prevent, one layer down.
    func hasGivenUp(on id: String) -> Bool { gaveUp.contains(id) }

    // ── Locating the backend (the packaging half of D67) ─────────────────────

    /// Where is `backend/`?
    ///
    /// Environment first, following the `THRESHER_API_BASE_URL` precedent:
    /// an explicit override is the only mechanism that works for a separate
    /// process, and it is how this becomes usable before packaging lands.
    /// Returns nil rather than guessing — see the type comment.
    nonisolated static func locateBackend() -> URL? {
        if let raw = ProcessInfo.processInfo.environment["THRESHER_BACKEND_DIR"] {
            let url = URL(fileURLWithPath: raw)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("main.py").path) {
                return url
            }
        }
        // The bundled backend (D68). Checked second so a developer's override
        // always wins — one expression, shared with locatePython, so the two
        // cannot disagree about whether a bundled backend exists.
        return bundledBackend()
    }

    /// The interpreter to run the backend with.
    ///
    /// **D68 changed the answer here.** Before packaging there was none: a bare
    /// `python3` resolves to `/usr/bin/python3`, which exists on every Mac and
    /// does NOT have Flask — the exact trap `launchagent.sh` documents, where
    /// launchd's minimal PATH found the system interpreter and the agent
    /// thrashed. So this returned nil rather than hand back something broken.
    ///
    /// The bundle now ships its dependencies (`backend/_vendor`), resolved
    /// *against this interpreter*, so `/usr/bin/python3` is exactly right — the
    /// whole API was verified to serve on it (3.9.6). It is only used when a
    /// bundled backend is present; a developer pointing at a checkout still needs
    /// `THRESHER_PYTHON`, because a checkout has no `_vendor` and the system
    /// interpreter genuinely cannot import flask there.
    nonisolated static func locatePython() -> URL? {
        if let raw = ProcessInfo.processInfo.environment["THRESHER_PYTHON"] {
            let url = URL(fileURLWithPath: raw)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        // Only claim the system interpreter when the vendored tree it needs is
        // actually there. Returning it unconditionally would resurrect the
        // thrashing failure on a developer machine.
        if bundledBackend() != nil,
           FileManager.default.isExecutableFile(atPath: systemPython.path) {
            return systemPython
        }
        return nil
    }

    /// macOS's stock interpreter. 3.9.6 on Sonoma — which is why
    /// `backend/tests/test_python_floor.py` exists: our sources must keep
    /// importing on it, and nothing else would notice if they stopped.
    nonisolated static let systemPython = URL(fileURLWithPath: "/usr/bin/python3")

    /// The backend inside the app bundle, if this build has one.
    nonisolated static func bundledBackend() -> URL? {
        guard let resource = Bundle.main.resourceURL?.appendingPathComponent("backend"),
              FileManager.default.fileExists(
                atPath: resource.appendingPathComponent("main.py").path)
        else { return nil }
        return resource
    }
}

extension LocalProcessHost {

    /// Where the backend's own output goes.
    ///
    /// Beside the database, in the app's support directory, because that is
    /// where a user (or a support request) will already be looking and it needs
    /// no new concept. One file per process id, so a poller problem and an API
    /// problem do not interleave into something unreadable.
    static var logDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("thresher/logs", isDirectory: true)
    }

    /// Rotate at 5 MB, keeping ONE previous generation.
    ///
    /// Sized against what the backend actually writes: a poll logs a handful of
    /// lines, so 5 MB is weeks of ordinary operation but still bounds a crash
    /// loop that writes a traceback every few seconds. One generation is kept
    /// because the common support case is "it broke just now" — an older
    /// generation is more disk for less value, and unbounded growth in an
    /// app-managed directory the user never sees is its own defect.
    static let maxLogBytes: UInt64 = 5 * 1024 * 1024

    /// An append handle for `id`'s log, rotating first if it has grown too big.
    /// Returns nil rather than throwing: losing logs must never stop the backend.
    static func logHandle(for id: String) -> FileHandle? {
        let dir = logDirectory
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let url = dir.appendingPathComponent("\(id).log")

        // Rotate BEFORE opening, so the handle we hand back is for a file that
        // is already within budget.
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64,
           size > maxLogBytes {
            let previous = dir.appendingPathComponent("\(id).log.1")
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: url, to: previous)
        }

        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        // Append rather than truncate: a restart must not erase the evidence of
        // why the previous run stopped, which is exactly what you need most.
        handle.seekToEndOfFile()
        return handle
    }
}

/// The real implementation, spawning child processes that die with the app.
final class LocalProcessHost: BackendProcessHosting, @unchecked Sendable {
    private var processes: [String: Process] = [:]
    private let lock = NSLock()

    func isRunning(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return processes[id]?.isRunning ?? false
    }

    func lastExitStatus(_ id: String) -> Int32? {
        lock.lock(); defer { lock.unlock() }
        guard let p = processes[id], !p.isRunning else { return nil }
        return p.terminationStatus
    }

    func launch(_ id: String, python: URL, arguments: [String], workingDirectory: URL) throws {
        let p = Process()
        p.executableURL = python
        p.arguments = arguments
        p.currentDirectoryURL = workingDirectory
        // D68: put the vendored tree on PYTHONPATH when one exists, so the API
        // can import flask from inside the bundle. PREPENDED to any inherited
        // value rather than replacing it, so a developer's own PYTHONPATH still
        // works; absent a _vendor directory this is a no-op and the environment
        // is untouched.
        var env = ProcessInfo.processInfo.environment
        let vendor = workingDirectory.appendingPathComponent("_vendor")
        if FileManager.default.fileExists(atPath: vendor.path) {
            let existing = env["PYTHONPATH"]
            env["PYTHONPATH"] = existing.map { "\(vendor.path):\($0)" } ?? vendor.path
            p.environment = env
        }
        // Write output to a FILE rather than discarding it.
        //
        // The original reasoning was sound and is preserved: a child writing
        // into a pipe nobody drains eventually blocks on a full buffer, which
        // would hang the backend in a way that looks like an IMAP stall. But the
        // fix chosen was to discard, which made every failure in the shipped
        // configuration invisible — to the user AND to us. The first-run poller
        // bug (D1) was diagnosable only because a checkout happened to be on the
        // same machine; a beta user would have had nothing to send.
        //
        // A file has neither problem: the kernel handles the writing, so there
        // is no pipe to drain and nothing to block on, and the output survives
        // for whoever needs it afterwards.
        if let handle = Self.logHandle(for: id) {
            p.standardOutput = handle
            p.standardError = handle
        } else {
            // Could not open a log (permissions, full disk). Losing logs must
            // never prevent the backend from running — that would turn a
            // diagnostics problem into an outage.
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        do {
            try p.run()
        } catch {
            throw BackendSupervisorError.launchFailed(id, error.localizedDescription)
        }
        lock.lock(); processes[id] = p; lock.unlock()
    }

    func terminate(_ id: String) {
        lock.lock()
        let p = processes.removeValue(forKey: id)
        lock.unlock()
        // SIGTERM, not SIGKILL: main.py installs a handler that drains the queue
        // and closes connections. A hard kill mid-write is how a WAL-mode SQLite
        // store gets a torn transaction.
        p?.terminate()
    }

    func isPortInUse(_ port: Int) -> Bool {
        // A connect() attempt is the honest test: `lsof` needs entitlements we
        // may not have, and a listening socket is exactly what "in use" means.
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
