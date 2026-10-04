//
//  MessageListViewModel.swift
//  Thresher
//
//  State + loading logic for the Message List screen (§4.1.1).
//
//  Uses @Observable (macOS 14 / D36). Refresh model (D34): explicit pull-to-
//  refresh plus a quiet background timer aligned to the backend poll interval
//  (read from GET /preferences). A background refresh must not disrupt the
//  user's selection or scroll (P2) — so it swaps the data array in place and
//  the view keys rows by stable id; SwiftUI diffs rather than resets.
//

import Foundation
import Observation

@MainActor
@Observable
final class MessageListViewModel {
    // ── Published state ────────────────────────────────────────────────────
    private(set) var rows: [MessageListRow] = []
    private(set) var isLoading = false        // first load / explicit refresh
    private(set) var errorMessage: String?

    /// D50: store-wide triage counts (chips' truth source). nil until first
    /// fetched; refreshed with every reload so the D49 cadence keeps them
    /// honest, and patched in place on the E20 triage seam between ticks.
    private(set) var counts: TriageCounts?

    // ── OI21: the list is a window, and it now says how big the window is ───

    /// Total matching the ACTIVE filter set store-wide. Distinct from the chip
    /// counts (which are per-state and unfiltered) — this is the M in
    /// "showing N of M", and it must track the filters or the affordance lies.
    private(set) var totalMatching = 0
    /// Loading a further page (distinct from `isLoading`, which is the first
    /// load / explicit refresh and owns the big spinner).
    private(set) var isLoadingMore = false

    /// Is there mail past what has been loaded? The honest answer OI21 was
    /// about — previously the UI simply stopped at row 100 and said nothing.
    var hasMore: Bool {
        !isSearching && MessagePage.hasMore(loaded: rows.count, total: totalMatching)
    }

    // ── Filters (orthogonal to the D50 chips; they AND together) ────────────

    /// Set while a caller is changing several filters as ONE user action, so
    /// the individual setters persist their value without each kicking off its
    /// own reload. The caller issues a single reload afterwards.
    private var suppressReload = false

    var tierFilter: TierFilter? {
        didSet {
            guard tierFilter != oldValue else { return }
            defaults.set(tierFilter?.rawValue ?? 0, forKey: TierFilter.defaultsKey)
            guard !suppressReload else { return }
            Task { await self.reload() }
        }
    }

    var dateWindow: DateWindow {
        didSet {
            guard dateWindow != oldValue else { return }
            defaults.set(dateWindow.rawValue, forKey: DateWindow.defaultsKey)
            guard !suppressReload else { return }
            Task { await self.reload() }
        }
    }

    /// Session 34: the backend's last per-account health report, or nil if we
    /// have not successfully fetched one this session.
    private(set) var accountHealth: AccountHealthReport?

    /// Is a mailbox failing to poll? Authoritative — this is the poller's own
    /// heartbeat, not an inference from the rows.
    ///
    /// NOT suppressed while searching or filtering, unlike `staleness`. That
    /// suppression exists because a narrowed view says nothing about the store,
    /// which is true of INFERENCE from loaded rows. This fact is about the
    /// backend and stays true regardless of what the user is looking at —
    /// and "mail is not arriving" is something they need while searching too.
    var accountWarning: AccountHealthVerdict.Warning? {
        AccountHealthVerdict.evaluate(accountHealth)
    }

    /// The first-fetch state: connected, nothing retrieved yet, and why.
    ///
    /// WHY THIS EXISTS. After connecting a mailbox the list is empty for as long
    /// as the first fetch takes, and three different situations render
    /// IDENTICALLY: fetching normally, fetching slowly, and not fetching at all
    /// because something broke. That ambiguity is this project's recurring
    /// failure shape — a condition that presents as success while being
    /// indistinguishable from failure.
    ///
    /// DERIVED, NOT FETCHED. Everything here comes from `accountHealth` and
    /// `rows`, both of which the list already has. A dedicated in-flight-poll
    /// endpoint was considered and rejected: the fetch itself is ~5 seconds
    /// after the server-side window narrowing (measured 2026-09-07, 377s → 5s),
    /// so a live progress count would cost a new endpoint and a polling cadence
    /// to render something barely seen.
    ///
    /// NOT gated on onboarding: any long first fetch shows this — a reconnect,
    /// a widened window, a large mailbox.
    enum FirstFetchState: Equatable {
        /// Connected, no mail yet, and the backend has not reported a problem.
        case fetching
        /// Connected, no mail yet, and the backend says it cannot fetch.
        /// A DISTINCT TERMINAL STATE, and the reason it is distinct: a fetch
        /// that dies while the UI still says "fetching" is the same class as
        /// the poller that was silently abandoned and the notification that
        /// logged success and reached nobody. Success is not the only ending.
        case failed(String)
    }

    var firstFetch: FirstFetchState? {
        Self.firstFetchState(health: accountHealth,
                             hasRows: !rows.isEmpty,
                             isLoading: isLoading)
    }

    /// The derivation, as a pure function of the three inputs it depends on —
    /// so it is testable without constructing a view model or a fake network.
    static func firstFetchState(health: AccountHealthReport?,
                                hasRows: Bool,
                                isLoading: Bool) -> FirstFetchState? {
        // Only meaningful before any mail has arrived. Once there are rows the
        // ordinary list, staleness and health surfaces take over.
        guard !hasRows, !isLoading else { return nil }
        guard let report = health, !report.accounts.isEmpty else { return nil }

        // A failing account outranks a fetching one: if any connected mailbox
        // reports a fault while the store is empty, saying "fetching" would be
        // false. Reuse the sentence the health verdict already builds rather
        // than inventing a second phrasing for the same fault.
        if report.accounts.contains(where: { $0.status == "error" || $0.status == "stopped" }),
           let warning = AccountHealthVerdict.evaluate(report) {
            return .failed(warning.message)
        }

        // "never" is the honest first-run status: connected, no poll completed
        // yet. "ok" with an empty store means the poll finished and found
        // nothing in the window — not a fetch in progress, so no banner.
        if report.accounts.contains(where: { $0.status == "never" }) {
            return .fetching
        }
        return nil
    }

    /// Part 1: is the store stale — i.e. has nothing arrived in days?
    ///
    /// The gate complaint ("today's mail isn't on page one") turned out to be a
    /// backend that had been stopped for five days, not a sort-order bug. D57's
    /// ordering was correct throughout; there was simply no fresh mail. What
    /// was genuinely missing is that a stale store and a quiet one render
    /// IDENTICALLY, so a stopped poller is invisible.
    ///
    /// Derived from the newest `received_at` among LOADED rows — no extra
    /// request, and true of what the user is actually looking at.
    ///
    /// Suppressed while searching and while any filter is active: both narrow
    /// the set deliberately, so "the newest row here is old" says nothing about
    /// the store. Filtering to "older than 90 days" and being told the mail is
    /// old would be the banner contradicting the user's own instruction.
    var staleness: ListStaleness.Verdict? {
        guard !isSearching, !hasActiveFilters else { return nil }
        // Session 34: health outranks staleness when both would fire. They are
        // two readings of the same situation — "no new mail in 13 days" and
        // "you@example.com stopped polling" — and the second names the account
        // and the fix. Showing both would stack two banners saying one thing.
        guard accountWarning == nil else { return nil }
        // Pick the newest by PARSED date, not by string order. Stored
        // timestamps carry an offset and the offsets are not uniform, so a
        // lexicographic max can name the wrong row — the same trap D57 hit
        // twice at the SQL layer (`julianday()`, never a TEXT compare).
        let newest = rows.compactMap { ListStaleness.parse($0.receivedAt) }.max()
        return ListStaleness.evaluate(newest: newest)
    }

    /// Are any non-chip filters narrowing the view? Drives the "clear filters"
    /// affordance — a filter you forgot you set is indistinguishable from an
    /// empty inbox, which is the same class of lie as the silent truncation.
    var hasActiveFilters: Bool { tierFilter != nil || dateWindow != .anyTime }

    // ── Bulk selection (Part 3) ─────────────────────────────────────────────

    /// Ids checked for a bulk action. Cleared whenever the visible set changes,
    /// so a bulk action can never apply to rows the user can no longer see.
    var selectedForBulk: Set<MessageListRow.ID> = []
    /// Is the multi-select mode active? Kept explicit rather than inferred from
    /// a non-empty selection, so the checkboxes don't appear and vanish.
    var isSelecting = false {
        didSet { if !isSelecting { selectedForBulk.removeAll() } }
    }

    /// Multi-account: are there messages from more than one mailbox in view?
    ///
    /// Derived from the loaded rows rather than a second `/accounts` fetch —
    /// deliberately. What the badge needs to answer is "would this badge tell the
    /// user something?", and a connected-but-empty account would make every badge
    /// say the same thing while adding chrome. Deriving it from the mail means the
    /// badge appears exactly when it distinguishes something.
    ///
    /// SEARCH is included in this: a search spans every mailbox (P1), so results
    /// from two accounts should be labelled even if the active chip's page is not.
    var showsAccountBadge: Bool {
        var seen: Set<String> = []
        for row in rows {
            seen.insert(row.account)
            if seen.count > 1 { return true }
        }
        return false
    }

    /// D50: the active chip. Persisted locally (like tutorialSeen); switching
    /// refetches with the chip's states filter. Search ignores the chip
    /// entirely (P1 floor — handled in reload()).
    var filter: TriageFilter {
        didSet {
            guard filter != oldValue else { return }
            defaults.set(filter.rawValue, forKey: TriageFilter.defaultsKey)
            Task { await self.reload() }
        }
    }

    /// Search text the view binds to. Empty ⇒ show the full list.
    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearchReload() } }
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let api: MessageAPI
    private let defaults: UserDefaults
    private var pollTask: Task<Void, Never>?
    private var searchDebounce: Task<Void, Never>?

    /// Monotonic reload counter — the fix for the filter-reset race.
    ///
    /// Every filter setter's `didSet` spawns its own detached reload, and
    /// nothing used to order them or check, on completion, whether the filter
    /// set that produced a response was still current. So two overlapping
    /// reloads resolved last-write-wins by RESPONSE arrival, not by issue
    /// order: reset the tier menu and then the date menu a beat later, and the
    /// fully-cleared query (fast) landed before the still-date-filtered one
    /// (slow), which then overwrote it. The list rendered 6 backlog rows while
    /// every control read "All tiers / Any time".
    ///
    /// Each reload takes a ticket before its first await and may only publish
    /// if no newer reload has been issued since. Stale responses are DISCARDED,
    /// not merged — a late response is not extra information, it is an answer
    /// to a question the user has already moved on from.
    private var reloadGeneration = 0

    init(api: MessageAPI, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
        // D50: restore the persisted chip; Open is the decided default.
        self.filter = defaults.string(forKey: TriageFilter.defaultsKey)
            .flatMap(TriageFilter.init(rawValue:)) ?? .open
        // Filters persist too (same rationale as the chip). 0 ⇒ no tier filter;
        // TierFilter's raw values start at 1, so 0 is an unambiguous "unset".
        self.tierFilter = TierFilter(rawValue: defaults.integer(forKey: TierFilter.defaultsKey))
        self.dateWindow = defaults.string(forKey: DateWindow.defaultsKey)
            .flatMap(DateWindow.init(rawValue:)) ?? .anyTime
    }

    /// The active filter set, resolved to server bounds. One place builds this,
    /// so the rows fetch and the total can never disagree about what is being
    /// asked for.
    private func currentQuery(offset: Int = 0) -> ListQuery {
        let bounds = dateWindow.bounds(freshDays: freshDays)
        return ListQuery(states: filter.states, tier: tierFilter?.rawValue,
                         since: bounds.since, until: bounds.until,
                         limit: ListQuery.pageSize, offset: offset)
    }

    // ── Loading ──────────────────────────────────────────────────────────

    /// Initial load — shows the spinner.
    func loadInitial() async {
        isLoading = true
        // §B4: resolve FRESH_DAYS BEFORE the first fetch. The background loop
        // also refreshes it, but only after its first sleep — so a restored
        // "older than 2 weeks" window would spend the whole first view resolved
        // against the fallback. Non-fatal if it fails: the fallback matches the
        // shipped server constant.
        if let prefs = try? await api.preferences() { freshDays = prefs.freshDays }
        await reload()
        isLoading = false
    }

    /// Explicit user pull-to-refresh. Shows nothing extra (the refreshable
    /// control owns the spinner); just refetches whatever the current view is.
    func userRefresh() async {
        await reload()
    }

    /// The actual fetch. Dispatches to list or search depending on `searchText`.
    /// Swaps `rows` in place so a background refresh doesn't reset scroll (P2).
    /// D50: the list fetch carries the active chip's states filter; SEARCH
    /// NEVER does (P1 floor — a Done hit renders even on the Open chip).
    /// Counts refresh alongside every list fetch so whatever cadence refreshes
    /// the rows keeps the chips honest too (the workorder's D34/D49 note).
    private func reload() async {
        // Take a ticket BEFORE the first await. Anything issued after this
        // point supersedes us, and our response must then be dropped rather
        // than published over theirs.
        reloadGeneration &+= 1
        let generation = reloadGeneration
        // Capture the search mode with the ticket: a reload that began as a
        // list fetch must not publish into a view that has since become a
        // search (and vice versa).
        let wasSearching = isSearching

        do {
            if wasSearching {
                // P1 floor: search spans every state AND ignores the tier/date
                // filters, exactly as it ignores the chip. A search that
                // silently inherited an "older than 90 days" filter would make
                // the one guaranteed-reachable path lie.
                let hits = try await api.searchMessages(query: searchText)
                guard generation == reloadGeneration else { return }
                rows = hits
                totalMatching = hits.count
            } else {
                let page = try await api.listPage(currentQuery())
                guard generation == reloadGeneration else { return }
                rows = page.rows
                totalMatching = page.total
            }
            errorMessage = nil
        } catch {
            // A superseded request's failure is not the current view's error —
            // reporting it would put a stale "Can't load messages" over a view
            // that is loading perfectly well.
            guard generation == reloadGeneration else { return }
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
        // A refetch can change which rows exist; a selection pointing at rows
        // that are no longer visible would make the bulk confirmation count a
        // lie. Keep only what is still on screen.
        pruneSelection()
        let fetched = try? await api.messageCounts()
        guard generation == reloadGeneration else { return }
        counts = fetched ?? counts

        // Session 34: ride the same cadence as counts — a dead poller is
        // exactly as relevant as the numbers beside it, and this adds one
        // cheap request to a pass that already makes two.
        //
        // `try?` then DISCARD on failure, rather than clearing to nil: an
        // unreachable backend must not be reported as an account fault (we
        // couldn't ask, so we know nothing new), and blanking a warning we
        // showed a moment ago would flicker the banner off precisely when the
        // backend is having trouble. Staleness still covers that case.
        if let report = try? await api.accountHealth() {
            guard generation == reloadGeneration else { return }
            accountHealth = report
        }
    }

    /// OI21: fetch the next page and APPEND. The list stops being a silent
    /// first-page window only if the user can actually walk to the end.
    func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        // Same generation guard as reload(): if the filter set changes while
        // this page is in flight, its rows belong to a view the user has left,
        // and appending them would mix two filter sets in one list.
        let generation = reloadGeneration
        do {
            let page = try await api.listPage(currentQuery(offset: rows.count))
            guard generation == reloadGeneration else { return }
            // Guard against a concurrent reload having reset the list under us:
            // only append rows we don't already have, keyed by stable id.
            let known = Set(rows.map(\.id))
            rows.append(contentsOf: page.rows.filter { !known.contains($0.id) })
            totalMatching = page.total
            errorMessage = nil
        } catch {
            guard generation == reloadGeneration else { return }
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Clear both non-chip filters.
    ///
    /// The old comment here said "each didSet reloads; the second wins", which
    /// was true by accident rather than by design: because this type is
    /// @MainActor, neither spawned Task can start until this body returns, so
    /// both read an already-cleared filter set and issue the same query. It was
    /// never the racing path — two SEPARATE menu picks were (see
    /// `reloadGeneration`). Both are safe now, and this one issues one reload
    /// instead of two redundant ones.
    func clearFilters() {
        // Assign without triggering each setter's own reload, then reload once.
        let changed = tierFilter != nil || dateWindow != .anyTime
        guard changed else { return }
        suppressReload = true
        tierFilter = nil
        dateWindow = .anyTime
        suppressReload = false
        Task { await self.reload() }
    }

    private func pruneSelection() {
        // D59: a frozen scope describes ONE filter set and one previewed count.
        // A reload means the filter set may have changed (or the store did), so
        // the scope's promise — "1,594 matching, as of this instant" — no longer
        // describes what the user is looking at. Drop it rather than execute a
        // count the user cannot see any more; re-arming is one click.
        //
        // Discarding is correct. Discarding SILENTLY is not: the quiet timer is
        // suppressed while a scope is armed, but the D49 fast path (a banner
        // means new mail → refresh the list) is deliberately NOT — suppressing
        // that would delay a Tier 1 alert to keep a bulk dialog valid, which is
        // backwards. So new mail landing mid-confirmation still disarms the
        // action, and without this notice the user presses Mark Done and NOTHING
        // HAPPENS: no triage, no error, no explanation. Say it instead.
        if filterScope != nil {
            scopeDiscardedNotice =
                "New mail arrived — select all matching again to confirm the updated count."
        }
        filterScope = nil
        guard !selectedForBulk.isEmpty else { return }
        let visible = Set(rows.map(\.id))
        selectedForBulk.formIntersection(visible)
    }

    // ── Bulk triage (Part 3) ────────────────────────────────────────────────

    /// Apply one triage state to every selected row.
    ///
    /// The server takes explicit ids and applies them all-or-nothing, so a
    /// stale set fails as a whole (409) rather than half-landing. On success we
    /// refetch rather than patching locally: a bulk Done usually empties most
    /// of the current view, and reconstructing that in place would be guesswork.
    @discardableResult
    func applyBulkTriage(_ state: TriageState) async -> BulkTriageResult? {
        let ids = Array(selectedForBulk)
        guard !ids.isEmpty else { return nil }
        do {
            let result = try await api.triageBulk(ids: ids, state: state)
            selectedForBulk.removeAll()
            isSelecting = false
            await reload()
            return result
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Select every row currently loaded. Still correct for small sets, and
    /// still the honest name for what it does: it acts on rows the user has
    /// actually seen. For a set larger than the loaded window, see
    /// `captureFilterScope()` — the two are offered side by side rather than
    /// one quietly standing in for the other.
    func selectAllLoaded() {
        selectedForBulk = Set(rows.map(\.id))
        filterScope = nil     // an id selection and a filter scope are exclusive
    }

    // ── Filter-scoped bulk (D59) ────────────────────────────────────────────

    /// D57's fresh-band edge in days, from the backend (§B4). The
    /// "older than 2 weeks" preset resolves from THIS rather than a second
    /// literal 14, so the preset and the recency band cannot drift apart.
    /// Seeded with the shipped constant and refreshed alongside the poll
    /// cadence, which is already a prefs read.
    var freshDays: Int = Preferences.defaultFreshDays

    /// The frozen scope for a "select all N matching" bulk, or `nil` when the
    /// pending action is an ordinary id selection. Set at the moment the user
    /// chooses select-all-matching and held — unchanged — through the
    /// confirmation and the execute.
    var filterScope: BulkFilterScope?

    /// Set when an armed scope was discarded by a refresh, so the bulk bar can
    /// explain why the action went away. Nil the rest of the time.
    ///
    /// This exists because the alternative is a button that silently does
    /// nothing — the worst outcome available here. Cleared as soon as the user
    /// re-arms or dismisses.
    var scopeDiscardedNotice: String?

    /// Is there a set larger than the loaded window to offer select-all-matching
    /// for? Below that, "select all loaded" already IS everything and a second
    /// affordance would be noise.
    var canSelectAllMatching: Bool { hasMore && !isSearching }

    /// Capture the current filter set and its previewed count as a frozen scope.
    ///
    /// **The capture instant is the race guard.** `BulkFilterScope` stamps
    /// `until = now` here, and that exact value is what gets sent on execute —
    /// never re-derived. Mail the poller ingests between this moment and the
    /// user confirming is therefore excluded by construction, rather than being
    /// swept into a Done it was never shown for.
    func captureFilterScope(now: Date = Date()) {
        filterScope = BulkFilterScope(query: currentQuery(),
                                      previewedCount: totalMatching, now: now)
        // The two selections are mutually exclusive: leaving checkboxes ticked
        // alongside "all 1,594 matching" would make the confirmation's number
        // ambiguous about which set it describes.
        selectedForBulk.removeAll()
        // Re-arming IS the response to the notice; leaving it up would nag about
        // something the user has just done.
        scopeDiscardedNotice = nil
    }

    func clearFilterScope() {
        filterScope = nil
        scopeDiscardedNotice = nil
    }

    /// Turn an armed filter scope into an ordinary id selection over the LOADED
    /// rows, dropping one the user just un-ticked.
    ///
    /// Un-ticking a single row while "all 176 matching" is armed cannot be
    /// expressed by the endpoint — a filter has no "except this one" — so
    /// rather than silently ignore the tap or silently drop 76 unloaded
    /// messages from the action, the selection degrades to exactly what is on
    /// screen and the bar stops claiming a number it can no longer honour.
    func demoteScopeToLoadedSelection(excluding id: MessageListRow.ID) {
        guard filterScope != nil else { return }
        filterScope = nil
        selectedForBulk = Set(rows.map(\.id))
        selectedForBulk.remove(id)
    }

    /// How many messages the pending bulk will affect — whichever mode is armed.
    /// One accessor so the confirmation dialog cannot name a different number
    /// than the action uses.
    var pendingBulkCount: Int {
        filterScope?.previewedCount ?? selectedForBulk.count
    }

    var hasPendingBulk: Bool { filterScope != nil || !selectedForBulk.isEmpty }

    /// Is this row part of the pending bulk action?
    ///
    /// **A filter scope covers every rendered row**, because the rows ARE a page
    /// of the matching set — so an armed scope must tick every checkbox rather
    /// than leave the column blank.
    ///
    /// The gate found this the hard way: clicking "Select all 176 matching"
    /// armed the scope correctly, but the checkbox column — the one thing in
    /// this UI that shouts "selection" — stayed empty, and the only confirming
    /// evidence was a small label at the far opposite end of the bar. The
    /// feature worked; it did not LOOK like it worked, which for a destructive
    /// bulk action is the same thing. (I had deliberately left the boxes empty,
    /// reasoning that "1,594 selected" beside 100 visible checkboxes would read
    /// as a bug. That was optimising for an imagined contradiction over the
    /// user's actual point of attention.)
    func isRowInPendingBulk(_ id: MessageListRow.ID) -> Bool {
        if filterScope != nil { return true }
        return selectedForBulk.contains(id)
    }

    /// Apply one triage state to everything matching the FROZEN scope.
    ///
    /// Sends the filter, not an id list — the whole point of D59. The server
    /// resolves and updates the set inside a single statement, so there is no
    /// window in which it could shift, and no page cap to work around.
    @discardableResult
    func applyFilterScopedTriage(_ state: TriageState) async -> BulkTriageResult? {
        guard let scope = filterScope else { return nil }
        do {
            let result = try await api.triageBulk(scope: scope, state: state)
            filterScope = nil
            selectedForBulk.removeAll()
            isSelecting = false
            await reload()
            return result
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    // ── Cross-pane triage sync (E20) ───────────────────────────────────────

    /// Reflect a triage change made elsewhere (the detail pane) in this list's
    /// row, IN PLACE: one element is replaced by id, no refetch, no array
    /// rebuild — so a background-refresh-grade row swap never happens and
    /// scroll/selection stay put (P2/D34). Unknown ids are ignored (the row may
    /// have been filtered out by an active search).
    func applyTriage(messageID: MessageListRow.ID, stateRaw: String) {
        guard let idx = rows.firstIndex(where: { $0.id == messageID }) else { return }
        let oldState = rows[idx].triageState
        rows[idx] = rows[idx].withTriageState(stateRaw)
        // D50: move the message between count buckets locally so the chips
        // stay honest between refresh ticks. The row itself stays rendered
        // even if it left the active chip's set — membership re-evaluates on
        // the next fetch, so triaging never yanks the selected row out from
        // under the user (P2, the D34 bar).
        if oldState != stateRaw {
            counts?.move(from: oldState, to: stateRaw)
            // D51: the badge decrements the moment an urgent message is
            // triaged past New — no waiting for the next tick.
            counts?.moveUrgent(tier: rows[idx].urgencyTier,
                               from: oldState, to: stateRaw)
        }
    }

    // ── Search debounce ────────────────────────────────────────────────────

    private func scheduleSearchReload() {
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            guard let self, !Task.isCancelled else { return }
            await self.reload()
        }
    }

    // ── Background refresh timer (D34, cadence amended by D49) ──────────────

    /// D49 floor: never spin faster than this, whatever the poll pref says.
    static let minimumRefreshPeriod: TimeInterval = 30

    /// D49 (E21): refresh at HALF the backend poll interval. The two timers
    /// free-run, so at equal periods the phase offset is whatever launch order
    /// dealt — observed live as the app polling ~7s BEFORE each backend poll
    /// landed, i.e. worst-case staleness (≈ a full interval) every cycle.
    /// Halving bounds staleness at interval/2 for every tier, with or without
    /// notification permission.
    static func refreshPeriod(forPollInterval interval: TimeInterval) -> TimeInterval {
        max(interval / 2, minimumRefreshPeriod)
    }

    /// Start a quiet background refresh loop paced by the backend poll interval
    /// (from preferences). Background refreshes do NOT set isLoading, so the UI
    /// stays calm (P2 — ambient, never jarring); they just swap rows.
    func startBackgroundRefresh() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // D49: re-read the cadence EVERY pass — a poll-interval pref
                // change applies at the next tick, not the next app launch.
                // Fall back to the default if prefs are unreachable. (We don't
                // fail the screen over a missing pref.)
                var interval = TimeInterval(Preferences.defaultPollIntervalMinutes * 60)
                if let prefs = try? await self.api.preferences() {
                    interval = prefs.pollIntervalSeconds
                    // §B4: same read, no extra request — keep the preset's day
                    // count tied to the server's FRESH_DAYS.
                    self.freshDays = prefs.freshDays
                }
                let period = Self.refreshPeriod(forPollInterval: interval)
                try? await Task.sleep(nanoseconds: UInt64(period * 1_000_000_000))
                if Task.isCancelled { break }
                // Don't background-refresh mid-search-typing churn; the search
                // debounce already keeps that fresh. Refresh the list view.
                //
                // D59: nor while a filter-scoped bulk is armed. A reload drops
                // the frozen scope (see pruneSelection), so a tick landing
                // between "Select all 1,594 matching" and the user confirming
                // would disarm the action under them — they press Mark Done and
                // nothing happens. The scope is short-lived and user-driven;
                // deferring one quiet tick costs nothing. The frozen `until` is
                // what keeps the count honest meanwhile, not the refresh.
                if !self.isSearching && self.filterScope == nil {
                    await self.reload()
                }
            }
        }
    }

    func stopBackgroundRefresh() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Cancel all in-flight work. Called from the view's onDisappear; the
    /// background loop and search debounce both check `Task.isCancelled`, so a
    /// cancelled task exits at its next await. (No deinit cleanup: the type is
    /// @MainActor-isolated and deinit runs in a non-isolated context.)
    func cancelAll() {
        pollTask?.cancel()
        searchDebounce?.cancel()
    }
}