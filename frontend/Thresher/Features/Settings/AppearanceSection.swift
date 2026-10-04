//
//  AppearanceSection.swift
//  Thresher
//
//  D47 — the Appearance Settings pane (fifth sidebar row, amending D43's
//  four-row order) and the font-scale model behind it.
//
//  Dogfood friction: the reading fonts are too small; the author wants a default and
//  a larger option. Purely a CLIENT concern (like `tutorialSeen`), so it lives
//  in UserDefaults via @AppStorage — no backend preference, nothing for the
//  classifier or another front end to care about.
//
//  The scale is applied through FontScale's font metrics below — views ask the
//  scale for a semantic font (`scale.body`) instead of scattering +2pt
//  constants. v1 values: System (untouched) / Large (+2pt on the reading
//  fonts). New reading surfaces should adopt FontScale, not raw `.font(.body)`.
//

import SwiftUI

/// The font-scale vocabulary. Raw value is the UserDefaults encoding.
///
/// Dogfood entry 27 (8/31/26) drove two changes here. Verbatim: *"Even with the
/// large text configuration there are still many things I can not read, such as
/// the Open, Needs action, Done, and All count. If someone chooses the Large
/// text, all the text sizes should be increased. I think it might be good to add
/// an additional setting for xtra large."*
///
/// Both halves were real:
///
///  1. **Large did not reach everything.** The D50 chip row hardcoded
///     `.caption2` for its counts and left its labels at the default, so the
///     row ignored this setting entirely — and the counts are the SMALLEST text
///     in the window while being the chips' entire payload (the OI18 lesson).
///     `ChipRowWidthTests` even modelled a `fontBump` for Large, so the test
///     encoded an intent the view never honoured.
///  2. **+2pt is not much.** Extra Large (+5pt) is the step for when Large is
///     still not enough.
///
/// New reading surfaces should adopt `FontScale`, never a raw `.font(.body)` —
/// that is exactly how the chip row came to be exempt from a setting whose
/// whole purpose is to be global.
enum FontScale: String, CaseIterable, Identifiable {
    case system
    case large
    case xlarge

    static let defaultsKey = "appearance.fontScale"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .large:  "Large"
        case .xlarge: "Extra Large"
        }
    }

    /// Points added to every base size at this scale. The ONE scaling rule —
    /// every semantic font below routes through `points(_:)`, so a new size
    /// cannot silently opt out.
    var pointBump: CGFloat {
        switch self {
        case .system: 0
        case .large:  2
        case .xlarge: 5
        }
    }

    private func points(_ base: CGFloat) -> CGFloat { base + pointBump }

    // Semantic reading fonts (base sizes = the macOS defaults for each style).
    var body: Font { .system(size: points(13)) }
    var headline: Font { .system(size: points(13), weight: .semibold) }
    var subheadline: Font { .system(size: points(11)) }
    var caption: Font { .system(size: points(10)) }
    var title2: Font { .system(size: points(17)) }

    // The chip row's fonts (entry 27). Sizes are vended as POINTS as well as
    // `Font`, because SwiftUI's `Font` does not expose its size — and a test
    // that recomputes the size itself is testing its own arithmetic, not the
    // view. `ChipRowWidthTests` measures through `chipLabelPoints` /
    // `chipCountPoints`, so hardcoding a size here makes that test fail.

    /// Base 11 = `.caption2`, the size the count shipped with.
    var chipCountPoints: CGFloat { points(11) }
    /// Base 13 = the default the label shipped with — it had no explicit font
    /// at all, which is why it never scaled.
    var chipLabelPoints: CGFloat { points(13) }

    /// Monospaced digits so the numbers do not jitter as they change.
    var chipCount: Font { .system(size: chipCountPoints, design: .monospaced) }
    var chipLabel: Font { .system(size: chipLabelPoints) }
}

/// The Appearance pane: one picker today, room for more appearance choices
/// later (P4 — a preference, not a hardcode).
@MainActor
struct AppearanceSection: View {
    @AppStorage(FontScale.defaultsKey) private var fontScaleRaw: String = FontScale.system.rawValue

    private var scale: FontScale { FontScale(rawValue: fontScaleRaw) ?? .system }

    var body: some View {
        Section {
            Picker("Font size", selection: $fontScaleRaw) {
                ForEach(FontScale.allCases) { s in
                    Text(s.label).tag(s.rawValue)
                }
            }
            .pickerStyle(.segmented)

            // Live preview so the choice is legible before leaving Settings.
            VStack(alignment: .leading, spacing: 4) {
                Text("Quarterly numbers are ready for review")
                    .font(scale.headline)
                Text("The message list and reading pane use this size.")
                    .font(scale.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Applies to the message list and reading pane. Stored on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}