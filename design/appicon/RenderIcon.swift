//
//  RenderIcon.swift — generates the Thresher app icon PNGs.
//
//  The mark: a WHEAT STALK (chosen 2026-09-06). A grey stem running the full
//  height, topped by three pairs of oval grains angled outward, coloured from
//  the app's own tier ramp — red, yellow, blue, top to bottom. It reads as
//  separation, which is what the name means, and the colours are the tiers the
//  app actually sorts into.
//
//  REPLACES concept D, "The Quiet Signal" (2026-07-26) — one dot at rest above a
//  settled ramp of rows. That icon is documented in the decision log and the
//  article notes; its source is in this file's git history, deliberately kept.
//
//  Why Swift/Core Graphics rather than an SVG toolchain (inherited, still true):
//  the first attempt rasterized the SVG with ImageMagick, which has no librsvg
//  delegate here and silently dropped every gradient. Drawing through Core
//  Graphics uses the same renderer macOS itself uses for the icon, so what this
//  writes is what the Dock shows.
//
//  ── COLOUR PROVENANCE ───────────────────────────────────────────────────────
//  These are Apple's DARK-APPEARANCE system colours for .red, .yellow, .blue and
//  .gray — the same semantic colours Features/MessageList/Badges.swift uses for
//  tiers 1, 3, 4 and 5. The app resolves them per appearance; an icon cannot, so
//  they are pinned here.
//
//  ⚠️ THIS FILE IS THE ONLY PLACE IN THE PROJECT WITH HARDCODED COLOUR VALUES.
//  Everything inside the app uses SwiftUI semantic colours and inherits the
//  viewer's appearance. The icon borrows the app's colours; the app must never
//  adopt the icon's. If a tier colour ever changes in Badges.swift, it changes
//  here too — by hand, because nothing links them.
//
//  ── GEOMETRY ────────────────────────────────────────────────────────────────
//  Every dimension is a fraction of the icon's edge length S, so one function
//  renders every size with no per-size fudging. Origin is the TOP-LEFT of the
//  icon square; `y()` converts to Core Graphics' y-up space.
//
//  Two details are load-bearing, not incidental:
//
//    • The stem runs PAST the top pair. It ends above the grain centres and
//      shows through the V between them, giving the mark a point. A flat-topped
//      silhouette was noticeably weaker at small sizes.
//    • The top gap is SMALLER than the bottom gap (0.2154S vs 0.2462S). Even
//      spacing read as a diagram; the slight taper reads as an ear of wheat.
//      Do not "correct" this to uniform spacing.
//
//  ── CORNERS ─────────────────────────────────────────────────────────────────
//  This icon draws its own rounded square, and that REVERSES the previous
//  renderer's note ("macOS masks the squircle itself, so a pre-rounded source
//  would double-round"). That was wrong. Measured against the stock system
//  icons on this machine (Notes.app, Mail.app, 256px): the corner pixels have
//  alpha 0 and the centre alpha 255 — macOS app icons ship PRE-ROUNDED with
//  transparent corners, and the OS applies no mask of its own. A square source
//  is the anomaly, not the safe default. Confirmed end-to-end through
//  NSWorkspace.icon(forFile:) — the call Finder/Dock/Cmd-Tab use — which
//  returns the icon exactly as rendered, corners intact.
//
//  ── CANVAS INSET ────────────────────────────────────────────────────────────
//  The artwork does NOT fill the canvas. Measured across six stock system icons
//  (Mail, Maps, Music, Notes, Podcasts, Reminders — all 256px, all IDENTICAL,
//  so this is a fixed convention rather than per-icon art direction):
//
//      opaque shape   206/256 = 0.8047, inset 25px on all four sides
//      incl. shadow   214/256 = 0.8359, top 24 / bottom 18
//
//  The asymmetry in the second figure is macOS's own DOWNWARD drop shadow, not
//  the shape: down the centreline the top edge cuts hard (9 → 255) while the
//  bottom ramps out (255 → 61 → 53 → … → 2). So the shape itself is centred and
//  symmetric, and the shadow is the OS's to draw, not ours.
//
//  We therefore inset the ARTWORK to 206/256 of the canvas and leave the rest
//  transparent. Without this the icon renders ~24% larger in area than every
//  neighbour in the Dock.
//
//  EVERY §2 FRACTION BELOW IS RELATIVE TO THE ARTWORK, NOT THE CANVAS. The
//  mark's internal proportions are unchanged by the padding; only its effective
//  pixel size shrinks (at a 16px canvas the artwork is 12.88px, which is what
//  forced the 16/32pt legibility re-judgement).
//
//  Usage: swift RenderIcon.swift <output-dir>
//

import AppKit
import CoreGraphics
import Foundation

// ── Palette ──────────────────────────────────────────────────────────────────

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255, alpha: a)
}

let ground = rgb(0x0D, 0x0F, 0x12)   // near-black, sits UNDER the ramp
let stemGrey = rgb(0x98, 0x98, 0x9D) // .gray  — tier 5
let grainTop = rgb(0xFF, 0x45, 0x3A) // .red   — tier 1
let grainMid = rgb(0xFF, 0xD6, 0x0A) // .yellow— tier 3
let grainBot = rgb(0x0A, 0x84, 0xFF) // .blue  — tier 4

// ── The drawing ──────────────────────────────────────────────────────────────

/// Draws the wheat stalk at any edge length. Every constant is a fraction of
/// `side`, so this is the single source of truth for all ten exported sizes.
///
/// `coarse` selects the reduced variant for very small sizes — see the call
/// site in `renderPNG` and the note above it. When false, the full three-pair
/// mark is drawn exactly as specified.
/// Artwork edge as a fraction of the canvas edge — the stock macOS convention,
/// measured (see the CANVAS INSET note above). The artwork is centred; the
/// remainder is transparent padding that macOS fills with its own drop shadow.
let artworkRatio: CGFloat = 206.0 / 256.0

/// Converts an angle specified in SCREEN terms (clockwise positive, y-down —
/// the frame §2 is written in) into the mirrored drawing space set up by the
/// coordinate boundary in `drawIcon`.
///
/// The mirror that makes y-down positions work also reverses the handedness of
/// rotation, so this negation is the rotational half of that ONE conversion —
/// not a correction applied to a value. Every angle in the drawing passes
/// through here and none is adjusted at its use site.
func screenAngle(_ degrees: CGFloat) -> CGFloat { -degrees * .pi / 180 }

func drawIcon(into ctx: CGContext, side: CGFloat, coarse: Bool) {
    // S is the ARTWORK edge, not the canvas edge, so every fraction below stays
    // exactly as §2 specifies it — the padding changes the mark's size on screen
    // and nothing about its internal proportions.
    let S = side * artworkRatio
    let inset = (side - S) / 2

    // ── THE COORDINATE BOUNDARY — the ONE place y is converted ────────────────
    //
    // §2 of the work order is written in SCREEN coordinates: y measured DOWN
    // from the top-left. Core Graphics is y-UP. Both the flip and the padding
    // offset are applied here, once, as a transform — so every constant below is
    // §2's value verbatim, and NO individual value carries a hand-applied
    // correction.
    //
    // This matters more than it looks. The first version converted POSITIONS
    // through a `y()` helper and then separately negated the ROTATION sign to
    // compensate, which is the same correction applied twice in two places. The
    // result was a mark mirrored about the horizontal axis: grains angling
    // inward at the top and splaying at the bottom — a fern frond, with the stem
    // emerging as a bare stub and no V for it to point out of. Nothing errored;
    // it was simply a different, plausible-looking mark.
    //
    // POSITIONS come along for free: written y-down, they land correctly because
    // the whole space is flipped beneath them. ROTATIONS do not — a mirror
    // reverses handedness, so a clockwise screen angle becomes anticlockwise
    // here. `screenAngle` below is the other half of this same boundary, and is
    // the ONLY place a rotation is converted. Nothing else negates anything.
    ctx.saveGState()
    ctx.translateBy(x: inset, y: side - inset)   // to the artwork's top-left…
    ctx.scaleBy(x: 1, y: -1)                     // …then flip into screen space
    defer { ctx.restoreGState() }

    // ── Ground: rounded square, drawn by us (see the CORNERS note above).
    let radius = 0.223 * S
    let groundPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                            cornerWidth: radius, cornerHeight: radius,
                            transform: nil)
    ctx.addPath(groundPath)
    ctx.setFillColor(ground)
    ctx.fillPath()

    // ── Stem: a single round-capped stroke up the centre. It runs past the top
    //    pair on purpose (the point of the ear), so it is drawn before the
    //    grains and shows through the V between them.
    ctx.setStrokeColor(stemGrey)
    ctx.setLineWidth(0.0692 * S)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 0.5 * S, y: 0.9077 * S))
    ctx.addLine(to: CGPoint(x: 0.5 * S, y: 0.1077 * S))
    ctx.strokePath()

    // ── Grains: three pairs, each ellipse rotated outward about its own centre.
    //
    //    The reduced variant (Option A, chosen 2026-09-06) drops the MIDDLE pair
    //    and fattens/spreads what remains. Red and blue are kept because they are
    //    the ramp's endpoints: the mark still reads top-to-bottom as urgent-to-not
    //    even with the middle removed.
    //
    //    ⚠️ The full tier ramp — red, yellow, blue — is therefore a property of
    //    the mark at 64 physical pixels and above, NOT a guarantee at every size.
    //    That is deliberate: below 64px the icon's job is recognition, not
    //    communication. Do not "fix" this by restoring yellow at small sizes; it
    //    was tried (Option B) and the result reads as traffic lights, not wheat.
    let dx = 0.1385 * S
    let rx = (coarse ? 0.0900 : 0.0692) * S
    let ry = (coarse ? 0.1620 : 0.1462) * S
    let spread = coarse ? 0.1620 * S : dx

    let pairs: [(cy: CGFloat, colour: CGColor)] = coarse
        ? [(0.2615 * S, grainTop), (0.7231 * S, grainBot)]
        : [(0.2615 * S, grainTop), (0.4769 * S, grainMid), (0.7231 * S, grainBot)]

    for pair in pairs {
        for sign in [CGFloat(-1), CGFloat(1)] {
            let cx = 0.5 * S + sign * spread
            let cy = pair.cy
            // §2 verbatim: −35° on the left, +35° on the right, about the
            // grain's own centre. The literal spec value goes in; `screenAngle`
            // is the single boundary that maps it into the mirrored space.
            let angle = screenAngle(sign * -35)

            ctx.saveGState()
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: angle)
            ctx.addEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
            ctx.setFillColor(pair.colour)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
}

// ── Export ───────────────────────────────────────────────────────────────────

func renderPNG(side: Int, to url: URL, coarse: Bool) throws {
    guard let ctx = CGContext(data: nil, width: side, height: side,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw NSError(domain: "icon", code: 1) }

    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    drawIcon(into: ctx, side: CGFloat(side), coarse: coarse)

    guard let image = ctx.makeImage() else { throw NSError(domain: "icon", code: 2) }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: side, height: side)
    guard let data = rep.representation(using: .png, properties: [:])
    else { throw NSError(domain: "icon", code: 3) }
    try data.write(to: url)
}

let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: ".")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Render the reduced variant at or below this many PHYSICAL PIXELS.
//
// DECIDED 2026-09-06 (the author): Option A — two pairs, red and blue — at a threshold
// of 32 pixels. Measured floor for the full three-pair mark is 64 physical
// pixels; below that the grains fuse across the stem and the V closes.
//
// KEYED ON PIXELS, NOT POINTS, and the distinction is load-bearing. On a retina
// display the 32pt slot renders at 64px — exactly where the full mark still
// works — so a points-keyed threshold of 32 would serve the COARSE mark into a
// slot that has enough pixels for the full one. Pixels give:
//
//      16@1x = 16px  coarse        32@2x =  64px  full
//      16@2x = 32px  coarse       128@1x = 128px  full   … and up
//      32@1x = 32px  coarse
//
// which matches the measurement exactly. `targets` below is already expressed
// in rendered pixel dimensions, so this needs no pipeline change.
//
// WHY OPTION A, recorded because the trade is real: at 16 and 32 the icon's job
// is RECOGNITION, not communication — nobody decodes a 16-pixel icon as a tier
// legend. Option B kept all three colours but read as traffic lights rather than
// wheat, losing identity at exactly the sizes where identity is the only thing
// the icon has to do. Losing yellow below 32px is the accepted cost.
//
// So "the colours are the tiers" is a documented property of the LARGE mark
// (64px and up), not a guarantee at every size. See the note above `pairs`.
let coarseAtOrBelow: Int? = 32

// macOS AppIcon set: 16/32/128/256/512 pt, each @1x and @2x.
let targets: [(name: String, px: Int)] = [
    ("icon_16x16",      16),  ("icon_16x16@2x",    32),
    ("icon_32x32",      32),  ("icon_32x32@2x",    64),
    ("icon_128x128",   128),  ("icon_128x128@2x", 256),
    ("icon_256x256",   256),  ("icon_256x256@2x", 512),
    ("icon_512x512",   512),  ("icon_512x512@2x",1024),
]

for t in targets {
    let url = outDir.appendingPathComponent("\(t.name).png")
    let coarse = coarseAtOrBelow.map { t.px <= $0 } ?? false
    try renderPNG(side: t.px, to: url, coarse: coarse)
    print("  wrote \(t.name).png  (\(t.px)×\(t.px))\(coarse ? "  [reduced variant]" : "")")
}
print("Rendered \(targets.count) PNGs into \(outDir.path)")
