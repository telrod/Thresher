# Run Summary — App Icon Follow-up (canvas inset + re-judgement)

**Session 39 · 2026-09-06 · follows `3c14b1e`**
Commits: `17b8dec` (padding) · decision-log entry **D71**
Evidence: `docs/workorders/evidence/appicon/padded-*.png`, `dock-neighbours-padded.png`

---

## 1. The canvas inset — what was measured

Measured rather than assumed, across **six** stock system icons at 256px
(Mail, Maps, Music, Notes, Podcasts, Reminders). **All six are byte-identical
in geometry**, which is what makes this a fixed system convention rather than
per-icon art direction.

| Measurement | Value | Insets |
| --- | --- | --- |
| **Opaque shape** (alpha > 250) | **206/256 = 0.8047** | 25 / 25 / 25 / 25 — symmetric |
| Full alpha box (alpha > 8) | 214/256 = 0.8359 | L21 R21 **T24 B18** |

**The two numbers differ because of the drop shadow, and separating them is
the whole finding.** Down the vertical centreline of `Notes.png` the top edge
cuts hard — alpha `0,1,2,5,9,255` — while the bottom ramps out —
`255,61,53,43,34,24,16,9,5,2`. That gradient is a **downward drop shadow**.
The *shape* is centred and symmetric; the shadow is macOS's to draw, not ours.

**So the convention to adopt is the opaque 0.8047**, inset 25/256 = 0.0977 per
side. My earlier "≈80%" was right, but for a poor reason: it came from a single
centre scanline, which misses the corner-adjacent extremes. Taking the full
bounding box is what produces 0.8359, and only separating shadow from shape
reconciles the two.

### How it was applied

Inside `drawIcon`, `S` is now the **artwork** edge rather than the canvas edge,
and the context is translated by the inset before anything is drawn. **Every §2
fraction is therefore unchanged relative to the artwork, exactly as instructed**
— the padding changes the mark's size on screen and nothing about its internal
proportions.

Verified by measuring our own output back: opaque bbox **206×206 in a 256
canvas** and **824×824 in 1024**, symmetric insets (25px, 100px), ratio 0.8047
to four decimal places. At 16 and 32 the measured ratio reads 0.75 — that is
pixel quantisation of a 12.88px artwork, not a geometry error.

**Result** (`evidence/appicon/dock-neighbours-padded.png`): composited beside
Notes and Music at equal canvas size, ours now occupies the same footprint and
the same corner radius. Before the inset it was ~24% larger in area than every
neighbour.

⚠️ **One verification limit worth recording.** `NSWorkspace.icon(forFile:)`
returns the icon **scaled to fill the requested box**, so the padding is
absorbed and the probe looks identical before and after. That probe proved the
corners were not double-masked (D71) but it **cannot** verify relative Dock
sizing. The neighbour composite from the raw PNGs — which is what the Dock
actually consumes — is the honest test, and is what I used.

---

## 2. Re-judging the ladder — the previous finding did NOT survive

You were right to require this. The artwork is now ~80% of its former linear
size (a 16px canvas carries a **12.88px** mark), and the small-size judgements
moved by roughly one full step down the ladder.

| Size | Before padding | **After padding** |
| --- | --- | --- |
| 1024–128 | Clean | **Unchanged.** Internal proportions identical; the mark simply sits smaller in its canvas. |
| 64 | Stem thinning, grains touching | Slightly worse; still legible. |
| **32** | *"The smallest size that still says wheat"* | ❌ **RETRACTED.** Grains now **fuse across the stem** — red, yellow and blue each read as one horizontal chevron rather than a pair. The dark gutters that separated each grain from the stem are gone; the V is nearly closed. This is about what **unpadded 16–24pt** looked like. |
| **16** | Three fused horizontal stripes | **Worse, and differently.** The three colours fuse into a **single solid block** with no dark space anywhere — red bleeds to yellow bleeds to blue. The stem is no longer a line but a scatter of desaturated pixels *inside* the colour mass. Corners are ~3px, so the squircle itself starts to go. Reads as one vertical multicoloured smear. |

**So "32 is the smallest size that still says wheat" is withdrawn.** With the
padding, the full mark's honest floor is **64pt**.

### ✅ DECIDED (the author, 2026-09-06): Option A, threshold 32 PIXELS

`coarseAtOrBelow = 32`, keyed on **physical pixels**. Commit `c84ba89`.

**the author's reasoning, recorded:** at 16 and 32 the icon's job is **recognition,
not communication** — nobody decodes a 16-pixel icon as a tier legend. Option B
kept all three colours but read as traffic lights rather than wheat, losing
identity at exactly the sizes where identity is the only thing the icon needs to
do. Losing yellow below 32 is the acceptable cost. **"The colours are the tiers"
is now recorded as a documented property of the LARGE mark (64px and up), not a
guarantee at every size** — noted in the renderer beside the `pairs` definition,
with an instruction not to "fix" it by restoring yellow, because that was tried.

**Pixel-keying was required, and the pipeline made it easy.** The full mark's
measured floor is 64 physical pixels; on retina the 32pt slot renders at 64px,
so a points-keyed threshold of 32 would have served the coarse mark into a slot
with enough pixels for the full one. `targets` in the renderer was **already
expressed in rendered pixel dimensions**, so no pipeline change was needed —
nothing awkward to report.

| Slot | Pixels | Variant |
| --- | --- | --- |
| `icon_16x16` | 16 | **coarse** |
| `icon_16x16@2x` | 32 | **coarse** |
| `icon_32x32` | 32 | **coarse** |
| `icon_32x32@2x` | 64 | full |
| `icon_128x128` … `icon_512x512@2x` | 128–1024 | full |

**Verified from pixel content, not the renderer's log line:** zero yellow pixels
in exactly the three coarse slots; three balanced colour counts in all seven
full slots; `16@2x` and `32@1x` byte-identical as they must be (same pixel size,
same variant).

**Verified through the real build too.** The compiled `AppIcon.icns` carries
four representations — `ic04`/`ic11`/`ic07`/`ic13` = 16/32/128/256px — coarse in
the first two, full in the other two. That four-element shape is **not** a
regression: the previous `/Applications` build has exactly the same set, and the
512/1024 assets live in `Assets.car`.

What the boundary looks like (`evidence/appicon/final-*.png`): at **32px coarse**
the angled ovals and the V survive and it still reads as wheat; at **64px full**
all three tiers are distinct with an open V and unbroken stem; at **16px coarse**
there is a solid stem with real dark space between red and blue.

## 3. Decision-log entry added — **D71**

Recorded in `project-log.md` as a **correction**, not a silent fix, per your
instruction. It states that the old renderer's claim ("macOS masks the squircle
itself, so a pre-rounded source would double-round") is **false**, names the two
independent methods that established it (decoding stock icons' alpha channel;
`NSWorkspace.icon(forFile:)` returning our icon exactly as rendered), records
the canvas-inset convention alongside it, and notes the general lesson: **a
comment asserting platform behaviour is a claim, and this one was believed for
nine sessions because nobody measured it.**

---

## 4. The spec defect — recorded as yours, per your note

**§2's geometry was written in SVG screen coordinates without saying so, and
handed to a y-up API.** The failure mode is the part worth keeping: the
rotation did not come out *slightly* wrong, it came out **mirrored** — and both
details §2 flagged as load-bearing inverted silently and together. The stem's
point had no V to emerge from, and the "ear of wheat" taper became a fern
frond. Nothing errored; the output was simply a different, plausible-looking
mark.

**Convention for future geometry specs in this project: name the coordinate
system in the first line.** A spec that says "y-down from the top-left, SVG
convention" costs four words and would have made this a compile-time-obvious
mismatch rather than something only a rendered image could catch.

Worth noting how close this came to shipping: the mirrored mark is not
*obviously* broken in isolation. It was caught only because §3.2 required
looking at every size rather than reasoning about the geometry.

---

## Fences

Icon only. No rename, no bundle identifier change, no rebranding. **No colour
inside the app was touched.** `coarseAtOrBelow` left at `nil`. **The app was
NOT installed to `/Applications`** — that remains yours to do, and
`/Applications` still holds the old "Quiet Signal" icon.

## Still owed

- The reduction-threshold decision above (option **and** threshold).
- Install, then the four §4 surfaces — Dock, Finder/Spotlight, Cmd-Tab, and the
  notification banner. The banner is still the one that matters most and is the
  same eyeball item **OI27** is narrowed to.
- Three commits from the previous session plus three from this one are unpushed.

---

## 5. Records added at the author's direction (second pass)

**Into OI37 — the probe-blindness finding, now a third instance.**
`NSWorkspace.icon(forFile:)` **scales the icon to fill the box it is asked
for**, which absorbs the padding entirely, so it returned a correct-looking
icon both before and after the inset. It was structurally incapable of testing
the property under change while appearing to confirm it — and it *had* genuinely
proved something else (no corner mask, D71), which is what made the false
confidence plausible. Same class as **E32**, where a hosted XCTest silently
ignored environment overrides and passed against the live backend: in both cases
the instrument answered a different question than the one asked, affirmatively.

Recorded in the useful form: **establish what a probe is BLIND to before
trusting its verdict.** Ask what the instrument normalises, defaults, or
discards — scaling, environment, caching, retries — and confirm the property
under test survives it. A probe that cannot fail for the reason you care about
is not evidence, however green it looks.

**Into D71 — the retraction was caused by an unrelated correction.**
*"32 is the smallest size that still says wheat"* was a sound finding, correctly
arrived at by rendering and looking. Adopting the canvas inset then shrank the
artwork by ~20% linearly and the finding became false. **Two correct findings
combined into a wrong conclusion**, because the second silently changed the
premise the first rested on. Neither step was careless, and **being more careful
would not have caught it** — which is exactly why it is worth recording. The
generalisation: a measurement is valid only against the artefact it was taken
from, so any change to that artefact expires every judgement made about it. When
a correction lands, re-run the observations that depended on the corrected thing
rather than assuming they are independent.

---

## Fences (unchanged, all held)

Icon only. No rename, no bundle identifier change, no rebranding. **No colour
inside the app was touched.** **The app was NOT installed to `/Applications`** —
that remains the author's, and `/Applications` still holds the old "Quiet Signal" icon.

## Still owed

- Install, then the four §4 surfaces — Dock, Finder/Spotlight, Cmd-Tab, and the
  **notification banner**, still the one that matters most and the same eyeball
  item **OI27** is narrowed to.
- Nothing else from this work order.
