//
//  MessageListView.swift
//  Thresher
//
//  The Message List screen (§4.1.1): the main view, a list of messages with
//  search and pull-to-refresh.
//
//  Refresh (D34): `.refreshable` drives the explicit pull; a background timer
//  (started in .task / stopped in onDisappear) refreshes quietly on the backend
//  poll cadence. Selection lives in the view via `selection` and rows are keyed
//  by stable id, so a background row-swap doesn't disturb scroll or selection
//  (P2). No websocket.
//

import SwiftUI

@MainActor
struct MessageListView: View {
    /// Minimum width the list column may be given, in points.
    ///
    /// Set BY MEASUREMENT: the chip row is the widest fixed content in this
    /// column, and it must never clip — the counts ARE the chips' payload, so a
    /// cut-off count actively misleads (OI18's finding, and the reason the fix
    /// is "grant the width" rather than "abbreviate to 1.4K").
    ///
    /// Measured against the real chip geometry — 4 chips, 8pt gaps, 10pt inner
    /// padding, 12pt row padding: **380pt** at the live store's counts and
    /// **483pt** worst-case (five-digit counts at the D47 "Large" font scale).
    /// 520 covers both with room to spare.
    ///
    /// The worst case was measured by the test, not by hand — a first estimate
    /// of 468pt was 15pt low because it used `.body` metrics where the view uses
    /// the default font. That is exactly why the requirement is computed in
    /// `ChipRowWidthTests` rather than asserted as a literal.
    ///
    /// The previous floor of 320 clipped "Open 4,738" to "en 4,738" and cut
    /// "All 4,939" off the right edge at the DEFAULT window width — reported
    /// from a real window, having been a standing flagged item.
    /// `ChipRowWidthTests` pins this against the measured requirement.
    ///
    /// Raised 520 → 580 for Extra Large (dogfood entry 27). MEASURED by the
    /// test, not by hand: five-digit counts need **561pt at Extra Large**, so
    /// the old 520 floor would have clipped the new scale — reintroducing the
    /// exact OI18 failure this constant exists to prevent, in the setting
    /// chosen by the people least able to read a truncated number.
    ///
    /// A first pass set 560 from a hand-rolled measurement that GUESSED the
    /// chip labels; `testTheFloorFitsFiveDigitCountsAtExtraLarge` failed at
    /// 561.09 because it reads the real `TriageFilter.allCases`. That is the
    /// whole reason this number is test-derived rather than eyeballed — 580
    /// carries ~19pt of headroom over the true requirement.
    static let minimumColumnWidth: CGFloat = 580
    /// D47 / dogfood entry 27: the chip row's label and count route through the
    /// FontScale metrics like every other reading surface. They used to be a
    /// hardcoded `.caption2` and an unstyled default, which made the counts the
    /// smallest text in the window AND exempt from the font-size setting.
    @AppStorage(FontScale.defaultsKey) private var fontScaleRaw: String = FontScale.system.rawValue
    private var scale: FontScale { FontScale(rawValue: fontScaleRaw) ?? .system }
    /// Owned by the parent (the split view) since E20: the detail pane's triage
    /// callback patches this same model, so both panes see one row source.
    /// @Bindable because .searchable needs a binding into the observable model.
    @Bindable private var model: MessageListViewModel
    /// Selection is owned by the parent (the split view) so the detail pane can
    /// react to it. Bound through from the app.
    @Binding private var selection: MessageListRow.ID?

    /// `doneInitiallyExpanded` exists for render-evidence tests (both
    /// disclosure states must be capturable); the product default is collapsed.
    init(model: MessageListViewModel, selection: Binding<MessageListRow.ID?>,
         doneInitiallyExpanded: Bool = false) {
        _model = Bindable(model)
        _selection = selection
        _doneSectionExpanded = State(initialValue: doneInitiallyExpanded)
    }

    /// D50: while searching, the chip filter is suspended (P1 floor) — the
    /// chip bar dims to say so honestly.
    @State private var doneSectionExpanded: Bool

    /// Bulk confirmation (Part 3): the COUNT is the confirmation. "Mark 2,956
    /// messages as Done?" is the sentence that prevents an accident. A modal is
    /// P2-safe here — it is a user-initiated, wide-reaching action, not an
    /// unsolicited interruption.
    @State private var confirmingBulk: TriageState?
    @State private var bulkNotice: String?

    var body: some View {
        VStack(spacing: 0) {
            chipBar
            filterBar
            firstFetchBanner
            accountHealthBanner
            stalenessBanner
            if model.isSelecting { bulkBar }
            list
        }
        .confirmationDialog(
            confirmingBulk.map { bulkConfirmationTitle(for: $0) } ?? "",
            isPresented: Binding(get: { confirmingBulk != nil },
                                 set: { if !$0 { confirmingBulk = nil } }),
            titleVisibility: .visible
        ) {
            if let state = confirmingBulk {
                Button("Mark as \(state.label)") {
                    let target = state
                    // Capture the promised count BEFORE the call: applying
                    // clears the scope, and B3 needs something to compare the
                    // server's actual count against.
                    let promised = model.pendingBulkCount
                    let scoped = model.filterScope != nil
                    confirmingBulk = nil
                    Task {
                        let result = scoped
                            ? await model.applyFilterScopedTriage(target)
                            : await model.applyBulkTriage(target)
                        if let result {
                            bulkNotice = bulkResultMessage(result, target: target,
                                                           promised: promised)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { confirmingBulk = nil }
            }
        } message: {
            Text(bulkConfirmationDetail)
        }
        .alert("Bulk action", isPresented: Binding(get: { bulkNotice != nil },
                                                   set: { if !$0 { bulkNotice = nil } })) {
            Button("OK") { bulkNotice = nil }
        } message: { Text(bulkNotice ?? "") }
    }

    private var list: some View {
        List(selection: $selection) {
            if let error = model.errorMessage, model.rows.isEmpty {
                errorState(error)
            } else if model.rows.isEmpty && !model.isLoading {
                emptyState
            } else if model.filter == .all && !model.isSearching {
                // D50: All shows everything — Ack renders normally in place;
                // Done additionally collapses into a bottom disclosure.
                ForEach(model.rows.filter { $0.triage != .done }) { row in
                    selectableRow(row)
                }
                doneDisclosure
                paginationFooter
            } else {
                ForEach(model.rows) { row in
                    selectableRow(row)
                }
                paginationFooter
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("message.list")
        .overlay {
            if model.isLoading && model.rows.isEmpty {
                ProgressView().controlSize(.large)
            }
        }
        // Pull-to-refresh (D34).
        .refreshable { await model.userRefresh() }
        // Search drives GET /messages/search (P1 reachability).
        .searchable(text: $model.searchText, prompt: "Search all mail")
        .navigationTitle(model.isSearching ? "Search" : "Thresher")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.userRefresh() }
                } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
            }
        }
        // Initial load + start the quiet background timer; stop it on the way out.
        .task {
            await model.loadInitial()
            model.startBackgroundRefresh()
        }
        .onDisappear { model.cancelAll() }
    }

    // ── D50: chip bar + Done disclosure ─────────────────────────────────────

    private var chipBar: some View {
        HStack(spacing: 8) {
            ForEach(TriageFilter.allCases) { chip in
                Button {
                    model.filter = chip
                } label: {
                    // OI18 (Session 27 gate, real-data widths): at a 1,400+
                    // message store the labels and counts wrapped mid-word and
                    // mid-number ("Open" → "Op/en", "1,479" → "1,47/9"). A
                    // wrapped count is actively misleading — the counts ARE the
                    // chips' payload. So: single line, never truncated, and the
                    // layout grants whatever width the digits need. The
                    // four-digit call (workorder Part 2) is GRANT THE WIDTH, not
                    // abbreviate to "1.4K" — same transparency instinct as
                    // OI12's visible literal priority integer.
                    HStack(spacing: 4) {
                        Text(chip.label)
                            .font(scale.chipLabel)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let counts = model.counts {
                            Text("\(chip.count(in: counts))")
                                .font(scale.chipCount)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    // Explicit fills both states: a clear-background chip
                    // disappears entirely in an inactive window (found by the
                    // render evidence — plain buttons dim when non-key).
                    .background(
                        Capsule().fill(model.filter == chip
                                       ? Color.accentColor.opacity(0.25)
                                       : Color.secondary.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(
                        model.filter == chip ? Color.accentColor : Color.clear))
                }
                .buttonStyle(.plain)
                .help(chipHelp(chip))
                // XCUITest locator (Part 0). Identifier, not label text: the
                // labels carry live counts, so a text query would break every
                // time the store changes.
                .accessibilityIdentifier("chip.\(chip.rawValue)")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // P1 floor: search spans every state — the chips don't apply while a
        // search is active, and the bar dims to say so.
        .opacity(model.isSearching ? 0.4 : 1)
        .disabled(model.isSearching)
    }

    // ── Filter bar: tier + date window (Part 2) ─────────────────────────────
    //
    // Deliberately a SECOND row of Menus, not more chips. The chip row already
    // clips at ~320pt (a standing flagged item) and its counts are its payload;
    // adding controls there would make a known problem worse. Menus collapse to
    // a fixed width regardless of how many options they hold, so this row does
    // not grow with the vocabulary.

    private var filterBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("All tiers") { model.tierFilter = nil }
                Divider()
                ForEach(TierFilter.allCases) { tier in
                    Button(tier.label) { model.tierFilter = tier }
                }
            } label: {
                filterLabel(icon: "chart.bar.doc.horizontal",
                            text: model.tierFilter?.shortLabel ?? "All tiers",
                            active: model.tierFilter != nil)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Show only one urgency tier")
            .accessibilityIdentifier("filter.tier")

            Menu {
                ForEach(DateWindow.allCases) { window in
                    Button(window.label) { model.dateWindow = window }
                }
            } label: {
                filterLabel(icon: "calendar",
                            text: model.dateWindow == .anyTime ? "Any time" : model.dateWindow.label,
                            active: model.dateWindow != .anyTime)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Filter by when the message arrived")
            .accessibilityIdentifier("filter.date")

            if model.hasActiveFilters {
                Button {
                    model.clearFilters()
                } label: {
                    Label("Clear", systemImage: "xmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove the tier and date filters")
                .accessibilityIdentifier("filter.clear")
            }

            Spacer()

            // Multi-select toggle. Explicit mode rather than inferred from a
            // non-empty selection, so checkboxes don't appear and vanish.
            Button {
                model.isSelecting.toggle()
            } label: {
                Label(model.isSelecting ? "Cancel" : "Select",
                      systemImage: model.isSelecting ? "xmark" : "checklist")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isSelecting ? Color.accentColor : .secondary)
            .help(model.isSelecting ? "Leave selection mode" : "Select messages for a bulk action")
            .disabled(model.isSearching)
            .accessibilityIdentifier("filter.select")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        // Same P1 honesty as the chip bar: search ignores these filters, so the
        // row dims to say the controls are not in effect.
        .opacity(model.isSearching ? 0.4 : 1)
        .disabled(model.isSearching)
    }

    // ── Staleness banner (Part 1) ───────────────────────────────────────────
    //
    // The gate complaint was "today's mail isn't on page one of Open". The live
    // store settled it: the backend had been stopped five days, so the newest
    // message WAS 4.94 days old — D57's ordering was right the whole time.
    // What was actually missing is this: a stale store and a quiet one looked
    // identical, so a stopped poller was invisible. Ambient, dismissible-by-
    // fixing, never modal (P2).

    // ── Session 34: the poller is not running ────────────────────────────────
    //
    // The staleness banner below infers from the rows and needs three days of
    // silence before it says anything. This one KNOWS — it reads the poller's
    // own heartbeat via GET /health/accounts — so it can fire within two poll
    // intervals and name the mailbox.
    //
    // That gap is the whole point: the alpha ran 13 days with no ingestion, and
    // for 17 of the first hours only ONE of two mailboxes was dead, which no
    // amount of looking at the list could have revealed.
    //
    // Ambient, never modal (P2): it is a line at the top of the list, not an
    // alert. It clears itself on the next healthy poll — there is no dismiss,
    // because dismissing "mail is not arriving" hides a condition that is still
    // true, and this app exists to not lose mail.

    /// The first fetch after connecting a mailbox — and its failure ending.
    ///
    /// Three situations used to render identically here: fetching normally,
    /// fetching slowly, and not fetching because something broke. Only the
    /// first two are acceptable to show as "waiting"; the third is a failure
    /// and must say so.
    ///
    /// A BANNER, NOT A PROGRESS ROW. The fetch is ~5 seconds once the retrieval
    /// window is applied server-side (measured 2026-09-07: 377s → 5s, and the
    /// scanned-vs-kept gap closed from 1,588→15 to 17→15). A live progress
    /// count would need an endpoint exposing in-flight poll state plus a
    /// polling cadence, to render something the user barely sees.
    @ViewBuilder
    private var firstFetchBanner: some View {
        switch model.firstFetch {
        case .fetching:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Fetching your mail…")
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .accessibilityIdentifier("list.firstFetch")

        case .failed(let message):
            // Orange, matching the health banner: this is a verified fault, not
            // a hint. No spinner — a spinner on a dead fetch is the lie this
            // state exists to prevent.
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.18))
            .accessibilityIdentifier("list.firstFetchFailed")

        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var accountHealthBanner: some View {
        // Suppressed when the first-fetch banner is already showing the same
        // fault: both derive from `accountWarning`, so rendering both would
        // print one problem twice. The first-fetch phrasing wins there because
        // it is the more specific situation (connected, nothing retrieved yet).
        if let warning = model.accountWarning, model.firstFetch == nil {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(warning.message)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.caption)
            // Deliberately louder than the staleness banner's `.secondary`:
            // this is a verified outage, not a hint, and mail is being missed
            // for as long as it shows.
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.18))
            .accessibilityIdentifier("list.accountHealth")
            .help(warning.detail)
        }
    }

    @ViewBuilder
    private var stalenessBanner: some View {
        if let verdict = model.staleness {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.exclamationmark")
                Text(verdict.message)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
            .accessibilityIdentifier("list.staleness")
            .help("The newest message in the store is \(verdict.days) days old. "
                  + "If mail should have arrived since, the backend poller may not be running.")
        }
    }

    private func filterLabel(icon: String, text: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(active ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(active ? Color.accentColor.opacity(0.15)
                                          : Color.secondary.opacity(0.10)))
    }

    // ── Bulk confirmation copy (B2/B3) ──────────────────────────────────────

    /// B2: the confirmation names the COUNT, the target state, and — for a
    /// filter-scoped bulk — that the scope is the filter rather than the
    /// checkboxes. No filter-scoped bulk executes without passing through here.
    private func bulkConfirmationTitle(for state: TriageState) -> String {
        let n = model.pendingBulkCount
        let plural = n == 1 ? "" : "s"
        if model.filterScope != nil {
            return "Mark all \(n) matching message\(plural) as \(state.label)?"
        }
        return "Mark \(n) message\(plural) as \(state.label)?"
    }

    private var bulkConfirmationDetail: String {
        let base = "This changes triage state only — nothing is deleted, and every message stays searchable."
        guard model.filterScope != nil else {
            // Id mode never writes back; say so rather than leaving it implied.
            return base + " Your mailbox is not changed."
        }
        // B2 requires stating whether write-back is on. It is off for bulk and
        // there is no UI to turn it on, so this is a statement of fact, not a
        // guess — and the result message repeats it from the server's answer.
        return base
            + " It covers every message matching the current filter, including "
            + "ones not yet loaded — but not mail that arrives from here on. "
            + "Your mailbox is not changed."
    }

    /// B3: report the ACTUAL affected count, and say so plainly when it differs
    /// from what was promised rather than swallowing the difference. With the
    /// frozen `until` the divergence should be ~0; a nonzero value means
    /// concurrent triage, which is worth seeing rather than hiding.
    private func bulkResultMessage(_ result: BulkTriageResult,
                                   target: TriageState,
                                   promised: Int) -> String {
        let n = result.updated
        var text = "\(n) message\(n == 1 ? "" : "s") marked \(target.label)."
        if n != promised {
            text += " That differs from the \(promised) shown when you confirmed"
            if let already = result.alreadyInState, already > 0 {
                text += " — \(already) already had that state"
            }
            text += "."
        } else if let already = result.alreadyInState, already > 0 {
            text += " (\(already) already had that state.)"
        }
        text += result.writeBackSkipped
            ? " Your mailbox was not changed."
            : " \(result.wroteBack) marked read in your mailbox."
        return text
    }

    // ── Bulk action bar (Part 3) ────────────────────────────────────────────

    private var bulkBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            // D59: an armed scope is discarded by any refresh — including the
            // D49 fast path, which fires when new mail arrives and is
            // deliberately NOT suppressed (a Tier 1 banner outranks keeping a
            // bulk dialog valid). Without this line the user presses Mark Done
            // and nothing happens at all. Its own ROW, not a trailing item in
            // the HStack: the controls already fill that row, and the chip-row
            // clipping (OI18) is the standing lesson about squeezing text in
            // beside them.
            if let notice = model.scopeDiscardedNotice {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(notice)
                    Spacer(minLength: 0)
                    Button("Dismiss") { model.scopeDiscardedNotice = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("bulk.scopeDiscardedNotice")
            }
            // D59: select-all-matching gets its OWN ROW, deliberately separated
            // from "Select all N loaded".
            //
            // The gate found them side by side, one word apart, in identical
            // blue: the user armed 176, then a stray click on the neighbouring
            // control silently swapped it for 100 — a quieter action wearing
            // near-identical clothes, sitting where the hand already was. A
            // bordered button on its own line makes the two neither adjacent
            // nor interchangeable-looking.
            if model.canSelectAllMatching {
                HStack(spacing: 8) {
                    Button("Select all \(model.totalMatching) matching") {
                        model.captureFilterScope()
                    }
                    .buttonStyle(.bordered)
                    .font(.caption.weight(.medium))
                    .accessibilityIdentifier("bulk.selectAllMatching")
                    .help("Acts on every message matching the current filter — including \(model.totalMatching - model.rows.count) not yet loaded. Mail arriving after you click is excluded.")

                    Text("\(model.totalMatching - model.rows.count) beyond this page")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            bulkControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    private var bulkControls: some View {
        HStack(spacing: 10) {
            if model.filterScope != nil {
                // A FILLED badge, not plain blue text among blue buttons. The
                // gate finding: the armed readout was the only confirmation the
                // click had worked, it sat at the far end of the bar from the
                // button, and it looked like every other control around it.
                Text("All \(model.pendingBulkCount) matching")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
                    .accessibilityIdentifier("bulk.armedScope")
                    .help("Every message matching the current filter, frozen when you selected it")
            } else {
                Text("\(model.selectedForBulk.count) selected")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button("Select all \(model.rows.count) loaded") { model.selectAllLoaded() }
                .buttonStyle(.plain).font(.caption)
                .foregroundStyle(Color.accentColor)
                // Honest about scope: this selects what is LOADED, which is not
                // the same as everything matching the filter when more pages
                // remain. Saying so beats a "select all" that quietly means
                // something narrower.
                .help(model.hasMore
                      ? "Selects the \(model.rows.count) rows loaded so far, not all \(model.totalMatching) matches. Load more to extend the selection."
                      : "Selects every matching message")

            if model.hasPendingBulk {
                Button("Clear") {
                    model.selectedForBulk.removeAll()
                    model.clearFilterScope()
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Button("Mark Done") { confirmingBulk = .done }
                .disabled(!model.hasPendingBulk)
                .help("Move the selected messages to Done (nothing is deleted)")
            Menu("More") {
                Button("Mark Acknowledged") { confirmingBulk = .acknowledged }
                Button("Mark Needs Action") { confirmingBulk = .needsAction }
            }
            .fixedSize()
            .disabled(!model.hasPendingBulk)
        }
        // Padding and background live on the enclosing VStack (`bulkBar`) so the
        // notice row sits inside the same tinted band as the controls.
    }

    private func chipHelp(_ chip: TriageFilter) -> String {
        switch chip {
        case .open:        return "New + Needs action (default view)"
        case .needsAction: return "Only messages marked Needs Action"
        case .done:        return "Only messages marked Done"
        case .all:         return "Everything, including Acknowledged; Done collapses at the bottom"
        }
    }

    @ViewBuilder
    private var doneDisclosure: some View {
        let doneRows = model.rows.filter { $0.triage == .done }
        if !doneRows.isEmpty {
            DisclosureGroup(isExpanded: $doneSectionExpanded) {
                ForEach(doneRows) { row in
                    selectableRow(row)
                }
            } label: {
                Label("Done (\(doneRows.count))", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // ── Rows + pagination (OI21) ────────────────────────────────────────────

    /// A row, with a checkbox in front of it while selecting. The checkbox is
    /// an explicit control rather than a click modifier — the OI16 lesson: an
    /// affordance nobody can see is an affordance nobody uses.
    @ViewBuilder
    private func selectableRow(_ row: MessageListRow) -> some View {
        if model.isSelecting {
            HStack(spacing: 8) {
                // An armed filter scope ticks EVERY rendered row — the rows are
                // a page of the matching set, so an empty column would be the
                // screen contradicting the action (the gate finding).
                Image(systemName: model.isRowInPendingBulk(row.id)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.isRowInPendingBulk(row.id)
                                     ? Color.accentColor : .secondary)
                    .imageScale(.large)
                    // The tick is RENDERED evidence that a bulk action covers
                    // this row, so it needs to be assertable from a UI test —
                    // an SF Symbol alone is not queryable by name. Identifier
                    // flips with the state so a test can count ticked rows.
                    .accessibilityIdentifier(model.isRowInPendingBulk(row.id)
                                             ? "row.checkbox.ticked"
                                             : "row.checkbox.empty")
                MessageRowView(row: row, showAccount: model.showsAccountBadge)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Un-ticking one row while "all 176 matching" is armed would
                // silently mean something the confirmation cannot express — the
                // filter has no "except this one". So a tap CONVERTS the scope
                // to the concrete set the user can see, minus the row they just
                // tapped, and the bar stops claiming 176.
                if model.filterScope != nil {
                    model.demoteScopeToLoadedSelection(excluding: row.id)
                } else if model.selectedForBulk.contains(row.id) {
                    model.selectedForBulk.remove(row.id)
                } else {
                    model.selectedForBulk.insert(row.id)
                }
            }
            .tag(row.id)
        } else {
            MessageRowView(row: row, showAccount: model.showsAccountBadge)
                .tag(row.id)
        }
    }

    /// OI21's actual fix at the UI layer: state how much of the store this view
    /// is showing, and offer the rest. Before this the list simply stopped at
    /// row 100 and said nothing, so "not in the list" and "not in the store"
    /// looked identical — which is how the phantom OI20 was born.
    @ViewBuilder
    private var paginationFooter: some View {
        if !model.isSearching && model.totalMatching > 0 {
            HStack(spacing: 8) {
                Text("Showing \(model.rows.count) of \(model.totalMatching)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if model.hasMore {
                    if model.isLoadingMore {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Load \(min(ListQuery.pageSize, model.totalMatching - model.rows.count)) more") {
                            Task { await model.loadMore() }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .listRowSeparator(.hidden)
        }
    }

    // ── Empty / error states ────────────────────────────────────────────────

    @ViewBuilder
    private var emptyState: some View {
        if !model.isSearching && model.hasActiveFilters {
            // A filter you forgot you set looks exactly like an empty inbox.
            // Same family of lie as the silent truncation, so it gets the same
            // treatment: name the cause and offer the undo.
            ContentUnavailableView {
                Label("No messages match these filters", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Filtered by \(activeFilterSummary). The \(model.filter.label) view may still have other messages.")
            } actions: {
                Button("Clear filters") { model.clearFilters() }
            }
        } else {
            ContentUnavailableView(
                model.isSearching ? "No matches" : "Nothing in \(model.filter.label)",
                systemImage: model.isSearching ? "magnifyingglass" : "tray",
                description: Text(model.isSearching
                    ? "Nothing matches “\(model.searchText)”."
                    : model.filter == .all
                        ? "New mail will appear here after the next poll."
                        : "The \(model.filter.label) view is empty — other chips may have messages.")
            )
        }
    }

    private var activeFilterSummary: String {
        var parts: [String] = []
        if let tier = model.tierFilter { parts.append("tier \(tier.rawValue)") }
        if model.dateWindow != .anyTime { parts.append(model.dateWindow.label.lowercased()) }
        return parts.joined(separator: ", ")
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Can’t load messages", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await model.userRefresh() } }
        }
    }
}