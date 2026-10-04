#!/bin/bash
#
# Verify the app icon in the BUILT product, not the sources.
#
# Called from the "Verify app icon" build phase. Lives here rather than embedded
# in project.pbxproj for the same reason bundle-backend.sh does: an embedded
# script is invisible in git diffs and cannot be run or tested on its own.
#
# WHY THE BUILT PRODUCT. Checking design/appicon/png would only prove the
# renderer's output is sound, which is already true the moment it is rendered.
# The failure this guards against is the compiled AppIcon.icns disagreeing with
# those sources — a stale asset catalog, a partial copy, or a hand-edited PNG in
# the appiconset. So it unpacks the icns Xcode actually produced and asserts
# against that.
#
# WHAT IT ASSERTS is in design/appicon/verify_icon.py: ramp order, stem
# clearance, and grain splay — all positional. The icon shipped MIRRORED on
# 2026-09-06 (grains angling inward at the top, a fern frond) and the
# verification of the day counted colour pixels per size and passed, because a
# mirrored mark has IDENTICAL colour counts. Counting how much of each colour is
# present says nothing about where it is or which way it points.
#
# ⚠️ SCOPE — WHAT THIS PHASE DOES NOT CHECK.
# Xcode compiles AppIcon.icns with only FOUR representations: ic04/ic11/ic07/ic13
# = 16, 32, 128 and 256 px. (Not a regression — the pre-2026-09-06 build has the
# same four.) The 512 and 1024 px assets are compiled into Assets.car instead,
# and this phase does not read them, so:
#
#   CHECKED here:      16px, 32px (coarse variant) · 128px, 256px (full mark)
#   NOT checked here:  512px, 1024px — they live in Assets.car
#
# In practice the same renderer emits all ten from one code path, so a defect
# reaching 512 without touching 128 would have to come from a hand-edited PNG in
# the appiconset rather than from the drawing code. That is the accepted risk and
# it is why this is scoped rather than exhaustive — but it IS a gap, not a
# guarantee, and the full ladder is only covered by running the checker directly:
#
#   python3 design/appicon/verify_icon.py design/appicon/png
#
# which asserts across all seven sizes it recognises. Do that after re-rendering.
#
# Usage: verify-appicon.sh <path-to-built-.app>

set -e

APP="$1"
if [ -z "$APP" ]; then
    echo "usage: verify-appicon.sh <path-to-.app>" >&2
    exit 2
fi

ICNS="$APP/Contents/Resources/AppIcon.icns"
if [ ! -f "$ICNS" ]; then
    echo "error: no AppIcon.icns in $APP — the asset catalog did not produce an icon" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKER="$REPO_ROOT/design/appicon/verify_icon.py"
if [ ! -f "$CHECKER" ]; then
    echo "error: icon checker missing at $CHECKER" >&2
    exit 1
fi

# Unpack into a temp iconset. iconutil names the members by size, which is what
# verify_icon.py keys on.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! iconutil -c iconset "$ICNS" -o "$WORK/icon.iconset" 2>"$WORK/err"; then
    echo "error: could not unpack $ICNS" >&2
    cat "$WORK/err" >&2
    exit 1
fi

# Fail loudly if the icns unpacked to nothing recognisable. Without this an
# empty directory would sail through as "no failures" — the shape of bug this
# whole guard exists to catch.
COUNT=$(find "$WORK/icon.iconset" -name '*.png' | wc -l | tr -d ' ')
if [ "$COUNT" -eq 0 ]; then
    echo "error: $ICNS unpacked to zero PNGs" >&2
    exit 1
fi

# /usr/bin/python3 explicitly: a build phase has launchd's minimal PATH and no
# pyenv shims, and this must run on the same 3.9 floor D68 pins for the bundled
# backend. The checker is stdlib-only for exactly this reason.
if ! /usr/bin/python3 "$CHECKER" "$WORK/icon.iconset"; then
    echo "error: the built app icon failed its positional checks — see above." >&2
    echo "       Re-render with: swift design/appicon/RenderIcon.swift design/appicon/png" >&2
    echo "       then copy into frontend/Thresher/Assets.xcassets/AppIcon.appiconset/" >&2
    exit 1
fi

echo "note: app icon verified ($COUNT representations in AppIcon.icns)"
