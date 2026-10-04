//
//  MessageRowView.swift
//  Thresher
//
//  One row in the Message List: sender, subject, timestamp, preview, plus the
//  tier / category / triage badges. Every field that's nullable on the wire is
//  rendered defensively (the model exposes display* fallbacks and the badges
//  handle nil), so an unclassified message (P1) renders cleanly.
//

import SwiftUI

struct MessageRowView: View {
    let row: MessageListRow
    /// Multi-account: show WHICH mailbox this arrived in. Off by default so a
    /// single-account user sees no new chrome — the list view flips it on only when
    /// more than one account is connected.
    var showAccount: Bool = false
    /// D47: reading fonts route through the FontScale metrics (System/Large).
    @AppStorage(FontScale.defaultsKey) private var fontScaleRaw: String = FontScale.system.rawValue
    private var scale: FontScale { FontScale(rawValue: fontScaleRaw) ?? .system }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Top line: sender + timestamp
            HStack(alignment: .firstTextBaseline) {
                Text(row.displaySender)
                    .font(scale.headline)
                    .lineLimit(1)
                Spacer()
                Text(Self.relativeTimestamp(row.receivedAt))
                    .font(scale.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            // Subject
            Text(row.displaySubject)
                .font(scale.subheadline)
                .lineLimit(1)
                .foregroundStyle(.primary)

            // Preview — list rows carry it (detail won't); optional, so guard.
            if let preview = row.preview, !preview.isEmpty {
                Text(preview)
                    .font(scale.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // Badges: tier (nil-aware), category, triage (nil-aware)
            HStack(spacing: 6) {
                TierBadge(tier: row.tier)
                CategoryBadge(category: row.categoryValue)
                TriageBadge(triage: row.triage)
                if showAccount {
                    AccountBadge(account: row.account)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Render the ISO-8601 `received_at` as a relative time ("2h ago"). Falls
    /// back to the raw string if parsing fails — never blank, never a crash.
    static func relativeTimestamp(_ iso: String) -> String {
        guard let date = isoParser.date(from: iso) ?? isoParserNoFraction.date(from: iso) else {
            return iso
        }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoParserNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}