# Work Order — New App Icon

> **Origin:** design session 2026-09-06. The mark is settled; this order builds
> the renderer and the asset set. It is **icon only** — no rename, no rebrand.
>
> **The mark:** a wheat stalk. A grey stem running the full height, topped by
> three pairs of oval grains angled outward, coloured from the app's own tier
> ramp — red, yellow, blue, top to bottom. It reads as separation, which is what
> the name means, and the colours are the tiers the app actually sorts into.

---

## §0 — Preconditions

1. Working tree clean; log state pointer current.
2. **Do not run `dev-run.sh` as a first step.** This order builds and installs at
   the end, once.
3. Locate the existing icon renderer (`design/appicon/`) and read it before
   writing anything. **Match its structure, invocation, and output pipeline** —
   this is a replacement, not a parallel implementation.

---

## §1 — Scope fences

- **Icon only.** No renaming, no bundle identifier changes, no rebranding. The
  rename to Thresher happens separately.
- **Do not change any colour inside the app.** The tier badges stay as they are.
  The icon borrows the app's colours; the app does not adopt the icon's.
- **Do not delete the old renderer's source from git history.** Replace the file,
  keep the history — "The Quiet Signal" is documented in the decision log and the
  article notes reference it.
- Do not edit `project-log.md`; report corrections.

---

## §2 — Geometry

All dimensions are fractions of the icon's edge length **S**, so one function
renders every size. Origin is the top-left of the icon square.

| Element | Value |
| --- | --- |
| Ground | Rounded square, fill `#0D0F12`, corner radius `0.223 × S` |
| Stem | Vertical line at `x = 0.5S`, from `y = 0.9077S` up to `y = 0.1077S` |
| Stem stroke | `0.0692 × S`, **round caps**, fill `#98989D` |
| Grain centres, x | `0.5S ± 0.1385S` |
| Grain centres, y | `0.2615S`, `0.4769S`, `0.7231S` |
| Grain shape | Ellipse, `rx = 0.0692S`, `ry = 0.1462S` |
| Grain rotation | `−35°` left side, `+35°` right side, about each grain's own centre |
| Grain colours | Top pair `#FF453A`, middle `#FFD60A`, bottom `#0A84FF` |
| Draw order | Ground, then stem, then grains (grains overlap the stem) |

**Two details that are load-bearing, not incidental:**

- **The stem runs past the top pair.** It ends above the grain centres and shows
  through the V between them, giving the mark a point. A flat-topped silhouette
  was noticeably weaker at small sizes.
- **The top gap is smaller than the bottom gap** (`0.2154S` vs `0.2462S`). Even
  spacing read as a diagram; the slight taper reads as an ear of wheat. Do not
  "correct" this to uniform spacing.

**Colour provenance.** These are Apple's dark-appearance system colours for
`.red`, `.yellow`, `.blue` and `.gray` — the same semantic colours
`Features/MessageList/Badges.swift` uses for tiers 1, 3, 4 and 5. The app
resolves them per appearance; an icon cannot, so they are pinned here. **The
generated icon is the only place in the project with hardcoded colour values.**
Note that in a comment.

---

## §3 — Required

1. **Render every size the asset catalog needs**, 1× and 2×, up to 1024.

2. **Look at the output. Every size.** Not a spot check. All three revisions of
   the previous icon came from rendering and reacting, not from reasoning about
   geometry — including the revision that found the rows read as a funnel.
   Report what you saw at each size, and say so plainly if something looks wrong
   at a size the spec did not anticipate.

3. **⚠️ 16pt is the risk and needs a judgement.** At 16 points the grains are
   roughly one pixel across and the stem is barely more. The previous icon
   handled exactly this by simplifying below 48pt. Render it, look at it, and
   report whether this mark needs a reduced variant — likely two pairs, or
   thicker grains and a wider spread. **Flag, don't invent:** if it needs
   simplifying, propose options rather than choosing one.

4. **Check it in greyscale.** Red and blue are nearly identical in luminance
   (`#6C6C6C` vs `#737373`), so for a colour-blind or greyscale viewer the ramp
   is carried entirely by vertical position. That is acceptable and expected —
   confirm position still separates them and note it. Do not adjust hues to fix
   it; the colours must match the app's badges.

5. **Wire it into `Assets.xcassets`** replacing the current app icon, following
   whatever pipeline the existing renderer uses.

6. **Report the corner radius question.** The spec hardcodes `0.223 × S`, which
   matches the traditional macOS squircle proportion. If the current macOS target
   applies its own icon mask, a self-drawn radius may double up or clash. Check
   the current guidance and report; do not change the spec unilaterally.

---

## §4 — Verification

Build and install once, at the end, then **look at it in all four places it
actually appears**:

- The Dock, alongside real neighbours
- Finder and Spotlight
- Cmd-Tab
- **A notification banner** — this is the one that matters most, since the
  banner icon question is a live open item (OI27), and the native-delivery path
  was confirmed on 2026-09-06 to render the app's own icon correctly

⚠️ **Expect icon caching to interfere.** macOS caches app icons aggressively, and
this project already has a LaunchServices registration problem — three bundles
claimed the identifier on 2026-09-06. If the old icon persists after install,
that is a caching artifact, not a rendering failure. Say which you concluded and
what you did about it.

---

## §5 — Closing

- Committed run summary is the artifact.
- Report: what was rendered, **what you saw at each size**, what was flagged.
- Include the 16pt judgement and the corner-radius finding explicitly; both are
  decisions for the author, not for the implementer.
