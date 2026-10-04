//
//  Badges.swift
//  Thresher
//
//  Small pill views for tier, category, and triage state. The tier badge
//  explicitly renders the `nil` (unclassified) case — a real state per P1 —
//  rather than assuming every message has a tier.
//

import SwiftUI

/// Urgency-tier pill. `tier == nil` ⇒ a distinct "Unclassified" pill, so a
/// message persisted before classification (P1) renders without crashing.
struct TierBadge: View {
    let tier: Tier?

    var body: some View {
        Text(text)
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .help(helpText)
    }

    private var text: String { tier?.shortLabel ?? "—" }
    private var helpText: String { tier?.label ?? "Unclassified" }

    private var color: Color {
        switch tier {
        case .one:   return .red
        case .two:   return .orange
        case .three: return .yellow
        case .four:  return .blue
        case .five:  return .gray
        case nil:    return .secondary
        }
    }
}

/// Work / Personal / Unknown tag.
struct CategoryBadge: View {
    let category: Category

    var body: some View {
        Text(category.label)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
    }
}

/// Triage state. `nil` ⇒ unclassified, shown muted.
struct TriageBadge: View {
    let triage: TriageState?

    var body: some View {
        Text(triage?.label ?? "—")
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Capsule().stroke(Color.secondary.opacity(0.4), lineWidth: 1))
            .foregroundStyle(.secondary)
            .help(triage?.label ?? "Unclassified")
    }
}
/// Which mailbox a message arrived in (multi-account).
///
/// Shown ONLY when more than one account is connected — a single-account user must
/// see no new chrome, because a badge that always says the same thing is noise, not
/// signal. The list view owns that decision; this view just renders.
///
/// The label is the address's LOCAL PART, not the full address: "you" and
/// "hello" are scannable at a glance, where the full addresses are long, share no
/// useful prefix, and would push the badge row toward the clipping the chip row
/// already suffers at narrow widths. The full address is in the tooltip, so nothing
/// is actually hidden (P3's spirit).
struct AccountBadge: View {
    let account: String

    var body: some View {
        Text(Self.shortLabel(account))
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
            .help(account)
    }

    /// "you@example.com" → "you". Falls back to the whole string when
    /// there's no "@" — never blank, whatever the server sends.
    static func shortLabel(_ account: String) -> String {
        guard let at = account.firstIndex(of: "@"), at != account.startIndex else {
            return account
        }
        return String(account[account.startIndex..<at])
    }
}
