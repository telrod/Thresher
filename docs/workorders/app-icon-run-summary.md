# Run Summary — New App Icon

**Session 39 · 2026-09-06 · executed against `eacea57`**
Work order: `docs/workorders/app-icon-workorder.md` · Commit: `526ad57`
Evidence: `docs/workorders/evidence/appicon/`

---

## §0 Preconditions

Working tree clean (only the untracked work order); log pointer current at
Session 38. `dev-run.sh` was **not** run. The existing renderer
(`design/appicon/RenderIcon.swift`) was read in full before anything was
written, and this is a **replacement in the same file** — same invocation
(`swift RenderIcon.swift <out-dir>`), same ten targets, same
render-then-copy pipeline into `AppIcon.appiconset`. No parallel
implementation, no new script, `Contents.json` untouched (filenames match).

The old renderer's source is preserved in this file's git history, per §1.

---

## What was rendered

All ten targets — 16/32/128/256/512 pt at 1× and 2× — into
`design/appicon/png/`, then copied into the asset catalog.

## What I saw at each size

| Size | What it looks like |
| --- | --- |
| **1024** | The mark fully resolved. V opens at the top with the stem's point through it, grains splay outward and up, the taper reads as an ear of wheat. Matches §2 in every particular. |
| **512** | Identical read. No loss. |
| **256** | Holds up well — three pairs distinct, colours clean, V still legible. |
| **128** | Still works. Three pairs readable; the gaps between grains are tightening but the stem stays continuous. |
| **64** | Pairs still distinguishable and the ramp reads, but the stem has thinned toward a hairline and grains begin to touch their vertical neighbours. |
| **32** | **Better than its thumbnail suggests.** Magnified 12×, the stem is a clean unbroken line, the pairs are separated by it, and the V is open. Tight but genuinely legible — this is the smallest size where the mark still says "wheat". |
| **16** | **Fails.** See below. |

Rendering at thumbnail scale was not enough to judge 32 and 16 — both were
magnified with nearest-neighbour (no smoothing) so individual pixels are
visible. At thumbnail size 32 looked broken and it is not; 16 looked bad and
is worse than it looks.

### Two things the spec did not anticipate

**1. The rotation sign is inverted relative to Core Graphics, and the first
render was wrong.** §2 specifies `−35°` left / `+35°` right in screen
(y-down) coordinates. Core Graphics is y-up, so the sign must flip to
preserve the intended splay. The first render took the spec literally and
produced **the opposite mark**: grain tops angled INWARD to meet the stem,
splaying at the bottom — a fern frond, with the stem poking out as a bare
grey stub and **no V at all** for it to show through. The two load-bearing
details in §2 both silently failed. Caught by looking at the 1024 render,
not by reasoning about the geometry; the fix and the trap are commented at
the call site.

**2. At 16pt the failure is specific and worth naming.** The grains fuse
into three solid horizontal bands — left and right of each pair merge
straight across the stem, so the pair reading is gone. The V closes
completely. The stem survives only as a muddy grey column where antialiasing
blends it into the colours crossing it. **What actually reads is three
horizontal colour stripes**, which is not a wheat ear — and, ironically, is
close to what the OLD icon's ramp of rows looked like.

---

## ⚠️ The 16pt judgement — THREE OPTIONS, NOT CHOSEN

Per §3.3 this is flagged, not decided. All three were rendered and compared
at 24× magnification; the PNGs are in `evidence/appicon/`.

**The renderer already carries the switch** — `coarseAtOrBelow: Int?` near
the bottom of the file — and it is currently **`nil`**, i.e. the full
three-pair mark ships at every size including 16. Setting it to `16` enables
whichever reduction is chosen. Nothing is committed to a reduction.

| Option | What it does | How it reads at 16pt |
| --- | --- | --- |
| **Ship as-is** | Full mark at every size | Three fused colour stripes. Honest but weak; the mark is unrecognisable at menu-bar/Spotlight size. |
| **A — two pairs** (`16pt-option-A`) | Drop the middle pair, fatten and widen the rest. The precedent the old icon set (it dropped four rows to two below 48px). | Clear improvement. Stem is unambiguous, real dark space between red and blue. But grains still fuse across each pair (no V), and **dropping yellow loses the middle of the tier ramp**. |
| **B — three pairs, wider spread** (`16pt-option-B`) | Keep all three pairs; shorten and fatten the grains, push them further from the stem. | **Strongest of the three.** Solid unbroken stem, all three tier colours survive, each pair clears the stem with dark gutters. Cost: grains become near-square blobs — the angled-oval character is gone, and it reads as six dots flanking a bar rather than an ear of wheat. |

My read, for whatever it is worth as input rather than a decision: **B**
keeps the tier ramp complete, which is the icon's whole semantic argument,
and the loss of oval character at 16pt is invisible in practice because
nobody perceives ellipse geometry at that size. **A** is more faithful to
"what a wheat ear does when simplified" and has this project's own
precedent behind it. They fail in different directions and I do not think
one is obviously right.

A fourth possibility not built: **keep the full mark everywhere and accept
that 16pt is a colour signature rather than a mark.** Several shipping macOS
icons do exactly this. It is a legitimate answer to §3.3 and costs nothing.

---

## Greyscale check (§3.4)

Confirmed exactly as the work order predicted, and **not adjusted**.

| Colour | Luminance | Grey |
| --- | --- | --- |
| red `#FF453A` | 108 | `#6C6C6C` |
| yellow `#FFD60A` | 208 | `#D0D0D0` |
| blue `#0A84FF` | 115 | `#737373` |
| grey `#98989D` | 152 | `#989898` |

Red and blue differ by **7 points out of 255** — indistinguishable. In the
greyscale render (`evidence/appicon/greyscale-256.png`) the top and bottom
pairs are the same mid-grey and the yellow middle pair pops bright.

**Position still separates them cleanly** — the mark reads as an ear of
wheat with a light band through the middle, and the ordering top-to-bottom
is unambiguous because it is carried by geometry, not hue. Hues were **not**
touched: they must match the app's badges (§1).

---

## ⚠️ The corner-radius question (§3.6) — ANSWERED, and it reverses the old file

**The spec's `0.223 × S` is correct. The previous renderer's stated reason
for drawing square corners was wrong.**

That file said: *"Corners are deliberately NOT rounded — macOS masks the
squircle itself, so a pre-rounded source would double-round."* Measured
against the stock system icons on this machine (`Notes.app`, `Mail.app`,
256px, alpha channel decoded directly):

- corner pixels: **alpha 0** · centre: **alpha 255**
- shape bounding box 206px within a 256px canvas

So macOS app icons **ship pre-rounded with transparent corners**, and the OS
applies **no mask of its own** to an app icon. A square edge-to-edge source
is the anomaly, not the safe default.

Verified end-to-end rather than by inference: a probe calling
`NSWorkspace.icon(forFile:)` — the same API Finder, the Dock, Spotlight and
Cmd-Tab use — returns the new icon **exactly as rendered**, corners intact,
with no double-rounding and no additional masking.

Measured radius proportion on the stock icons was **0.214** against the
spec's **0.223**; the small gap is my inset-walk measurement slightly
underestimating a true squircle's corner. **The spec needs no change.**

### A related finding the spec is silent on — flagged, not acted on

Stock macOS icons **do not fill their canvas**: the shape occupies 206 of
256px, an **≈80% inset**, with the remaining ~10% per side left transparent
as shadow/breathing room. Ours fills the canvas edge to edge.

The practical effect is that this icon will render **visibly larger** than
its neighbours in the Dock and Finder. That is a deliberate-looking choice
either way and it is **not** in §2, so I did not change it. If you want it
to sit consistently with system icons, the change is a single inset applied
in `drawIcon` — say the word and it is a two-line edit plus a re-render.

---

## §4 Verification — what I could and could not check

**What is verified:**

- The new mark is compiled into the built bundle's `AppIcon.icns` (extracted
  from `Contents/Resources` and viewed — it is the wheat stalk).
- `NSWorkspace.icon(forFile:)` on the built app returns the new icon. This
  is the same lookup Finder, the Dock, Spotlight and Cmd-Tab perform, so
  those four surfaces will draw this.
- Build succeeded; no app source changed, so no test run was warranted.

**What I did NOT do, deliberately:**

The app was **not installed to `/Applications`.** That copy currently holds
the old icon (verified — the probe returns "The Quiet Signal" for it, dated
06:27 today from your gate testing). Replacing it would swap out the app you
still have a human-gate item outstanding against, which §1's "icon only"
fence and the standing gate debt both argue against. **This is the one part
of §4 I left for you**: install when you are ready, or run `dev-run.sh`,
which the work order told me not to invoke.

**On caching — I concluded it is NOT a caching artifact.** Two bundles
currently claim the identifier (`/Applications` and DerivedData/Debug;
Release is not registered right now, so today it is two rather than the
three seen on 2026-09-06). They return *different* icons because they *are*
different bundles with different contents — old icon in `/Applications`, new
one in DerivedData. Nothing stale is being served, so no cache was cleared
and no `lsregister -kill` was run. If the old icon appears after you install,
**that** would be caching, and the fix is `killall Dock` plus
`lsregister -kill -r -domain local -domain user`.

**The notification banner (§4, "the one that matters most") is untested.**
It requires the app installed and running, a real Tier 1 delivered, and a
human to look at the banner — the same eyeball item OI27 has been narrowed
to. Worth pairing: install this build, then run that check once and close
both at the same time.

---

## Fences

Icon only. No rename, no bundle identifier change, no rebranding. **No
colour inside the app was touched** — `Badges.swift` is untouched and the
icon's hardcoded values are noted in the renderer as the project's only
hardcoded colours. The old renderer's source is preserved in git history.
`project-log.md` was not edited.

## For `project-log.md` (report, do not apply)

- **The corner-radius reversal is worth a decision-log entry.** The old
  renderer's claim was wrong and was load-bearing for that icon's design;
  the new measurement settles it with evidence and applies to any future
  icon work.
- **OI27** is unchanged by this: still one eyeball item, now with a second
  reason to run it (new icon in the banner).
