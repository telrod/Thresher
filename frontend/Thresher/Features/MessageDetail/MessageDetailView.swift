//
//  MessageDetailView.swift
//  Thresher
//
//  The Message Detail screen (§4.1.2). Shows full message content + the inline
//  classification reasoning that satisfies P3, triage controls, and the
//  conversation view. Reuses the List feature's TierBadge/CategoryBadge/
//  TriageBadge (the nullable classification model is shared).
//
//  Invariants honored here:
//   - P3: the explain output is visible IN-PLACE (the "Why this tier?" section),
//     no navigation away, no user-initiated round-trip — it's there on load.
//   - P1: an unclassified message renders fully; the explain section shows the
//     "not classified yet" state instead of erroring on the /explain 404.
//   - P2: triage changes update in place; no modal pop-ups.
//

import SwiftUI

@MainActor
struct MessageDetailView: View {
    @State private var model: MessageDetailViewModel
    @State private var showThread = false
    /// D47: reading fonts route through the FontScale metrics (System/Large).
    @AppStorage(FontScale.defaultsKey) private var fontScaleRaw: String = FontScale.system.rawValue
    private var scale: FontScale { FontScale(rawValue: fontScaleRaw) ?? .system }

    init(messageID: String, api: MessageAPI = APIClient(),
         onTriageChange: ((String, String) -> Void)? = nil) {
        _model = State(initialValue: MessageDetailViewModel(
            messageID: messageID, api: api, onTriageChange: onTriageChange))
    }

    /// Accepts an ALREADY-LOADED model, mirroring `MessageListView`. Render-evidence
    /// tests need this: `.task` can't complete while the test blocks the run loop to
    /// capture the window, so a self-loading view photographs as a spinner.
    init(model: MessageDetailViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            if let detail = model.detail {
                content(detail)
            } else if model.isLoading {
                ProgressView().controlSize(.large)
            } else if let error = model.errorMessage {
                ContentUnavailableView {
                    Label("Can’t load this message", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await model.load() } }
                }
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .task(id: model.messageID) {
            await model.load()
            await model.loadThread()
        }
    }

    // ── Content ───────────────────────────────────────────────────────────────

    private func content(_ detail: MessageDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(detail)
                // Triage lives directly under the header (dogfood polish Part A):
                // at the old bottom position it needed a scroll on long messages.
                triageSection(detail)
                Divider()
                bodySection(detail)
                Divider()
                explainSection(detail)   // P3 — in place
                threadSection(detail)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(detail.displaySubject)
        .toolbar { toolbarContent(detail) }
    }

    private func header(_ detail: MessageDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.displaySubject)
                .font(scale.title2).bold()
            HStack {
                Text(detail.displaySender).font(scale.headline)
                Spacer()
                Text(detail.receivedAt).font(.caption).foregroundStyle(.secondary)
            }
            if detail.senderName != nil {
                Text(detail.senderEmail).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                TierBadge(tier: detail.tier)
                CategoryBadge(category: detail.categoryValue)
                TriageBadge(triage: detail.triage)
            }
        }
    }

    @ViewBuilder
    private func bodySection(_ detail: MessageDetail) -> some View {
        if let body = detail.displayBody {
            Text(body)
                .font(scale.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let html = detail.bodyHTML, !html.isEmpty {
            // HTML fallback (polish Part B): HTML-only mail renders through the
            // remote-content-blocked web view (P5: no fetch ever leaves; see
            // HTMLBodyView for the mechanism). Plain text stays preferred.
            HTMLBodyView(html: html)
        } else {
            // BOTH body fields empty — the only case that shows the placeholder.
            Text("(no body)")
                .font(scale.body).italic()
                .foregroundStyle(.secondary)
        }
    }

    // ── P3: explain in place ────────────────────────────────────────────────

    @ViewBuilder
    private func explainSection(_ detail: MessageDetail) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if detail.isClassified {
                    // The folded `explanation` from the detail fetch is the P3
                    // source — present the moment the message loads.
                    if let explanation = detail.explanation, !explanation.isEmpty {
                        Text(explanation)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Structured rule breakdown (from /explain) when available —
                    // a graceful enhancement over the text.
                    if !detail.matches.isEmpty {
                        Divider()
                        Text("Rules matched").font(.caption).foregroundStyle(.secondary)
                        ForEach(detail.matches) { m in
                            HStack(alignment: .top, spacing: 6) {
                                // E19: the sender-override invariant record has no
                                // rule id — render it distinctly (it's the floor
                                // guarantee firing, not a rule), never hide it (P3).
                                Image(systemName: m.isOverride ? "arrow.up.to.line.circle" : "checkmark.circle")
                                    .foregroundStyle(m.isOverride ? Color.orange : Color.green)
                                Text(m.displayLine)
                                    .font(.caption)
                            }
                        }
                    }
                } else {
                    // Unclassified (P1): the /explain endpoint 404s; we never
                    // surfaced that as an error. Show the honest state.
                    Label("Not classified yet — this message arrived before classification ran.",
                          systemImage: "clock")
                        .font(.callout).foregroundStyle(.secondary)
                }

                // ── D52: dated classification, staleness, and the re-run ──────
                Divider()
                reclassifyControls(detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Why this tier?", systemImage: "info.circle")
        }
    }

    /// D52 parts A + D. Lives in the explain panel because that is where the
    /// classification story already is (DG4), and P3 says the reasoning is visible
    /// without navigating away.
    @ViewBuilder
    private func reclassifyControls(_ detail: MessageDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Part D: the fossil, dated — "Classified <date>" becomes
                // "Reclassified <date>" once it has been re-run.
                if let line = detail.classificationDateLine {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // Explicit visible control, not a context menu (OI16 lesson).
                Button {
                    Task { await model.reclassify() }
                } label: {
                    if model.isReclassifying {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Reclassifying…")
                        }
                    } else {
                        Label("Reclassify now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(model.isReclassifying)
                .help("Re-run the current rules over this message. Your triage state is kept.")
            }

            // Part D's staleness copy. Phrased about what HAS changed, never about
            // what the app will do — reclassification is never automatic (invariant 4).
            if let note = detail.stalenessNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // "No change" is a real answer and must not read as a failure.
            if let note = model.lastReclassifyNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // ── Triage controls (§3.4.1) ──────────────────────────────────────────────

    @ViewBuilder
    private func triageSection(_ detail: MessageDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Triage").font(.caption).foregroundStyle(.secondary)
            Picker("Triage", selection: triageBinding(detail)) {
                ForEach(TriageState.allCases, id: \.self) { state in
                    Text(state.label).tag(state)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.canTriage || model.isUpdatingTriage)

            if !model.canTriage {
                Text("Unclassified mail can’t be triaged until it’s classified.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Binding that maps the picker to the model's triage call. Reading uses the
    /// current state (defaulting to .new for display); writing fires the update.
    private func triageBinding(_ detail: MessageDetail) -> Binding<TriageState> {
        Binding(
            get: { detail.triage ?? .new },
            set: { newValue in Task { await model.setTriage(newValue) } }
        )
    }

    // ── Conversation ──────────────────────────────────────────────────────────

    @ViewBuilder
    private func threadSection(_ detail: MessageDetail) -> some View {
        if model.thread.count > 1 {
            DisclosureGroup(isExpanded: $showThread) {
                VStack(alignment: .leading, spacing: 8) {
                    // received_at ASC per the contract — oldest first, top-down.
                    ForEach(model.thread) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(row.displaySender).font(.subheadline).bold()
                                Spacer()
                                Text(row.receivedAt).font(.caption2).foregroundStyle(.secondary)
                            }
                            if let preview = row.preview, !preview.isEmpty {
                                Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 2)
                        Divider()
                    }
                }
                .padding(.top, 4)
            } label: {
                Label("Conversation (\(model.thread.count) messages)", systemImage: "bubble.left.and.bubble.right")
                    .font(.callout)
            }
        }
    }

    // ── Toolbar: Open in Gmail web + copy URL (D48, closes OI4) ────────────────

    @ToolbarContentBuilder
    private func toolbarContent(_ detail: MessageDetail) -> some ToolbarContent {
        // D48: rfc822msgid: search on Gmail web — works regardless of local
        // client; reply happens there. Enabled ONLY when the detail payload
        // carried a Message-ID; absent → both controls stay disabled with the
        // original flagged-not-faked presentation.
        ToolbarItem(placement: .primaryAction) {
            Button {
                GmailActions.open(detail)
            } label: {
                Label("Open in Gmail", systemImage: "arrow.up.forward.app")
            }
            .disabled(detail.gmailWebURL == nil)
            .help(detail.gmailWebURL == nil
                  ? "Unavailable — this message has no Message-ID header."
                  : "Open this message in Gmail on the web")
        }
        // Explicit second control (per D48: discoverable, not a click modifier —
        // the OI16 lesson): copy the URL without opening the browser.
        ToolbarItem(placement: .primaryAction) {
            Button {
                GmailActions.copyLink(detail)
            } label: {
                Label("Copy Gmail Link", systemImage: "link")
            }
            .disabled(detail.gmailWebURL == nil)
            .help(detail.gmailWebURL == nil
                  ? "Unavailable — this message has no Message-ID header."
                  : "Copy the Gmail link to the clipboard without opening it")
        }
    }
}
/// D48: the two toolbar actions, extracted so tests drive the exact production
/// code path (not a re-implementation). Both are nil-safe no-ops when the
/// message carries no Message-ID — the buttons are disabled in that state, but
/// the actions defend themselves anyway.
@MainActor
enum GmailActions {
    static func open(_ detail: MessageDetail,
                     opener: (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        guard let url = detail.gmailWebURL else { return }
        opener(url)
    }

    @discardableResult
    static func copyLink(_ detail: MessageDetail,
                         pasteboard: NSPasteboard = .general) -> Bool {
        guard let url = detail.gmailWebURL else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(url.absoluteString, forType: .string)
    }
}
