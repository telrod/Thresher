#!/usr/bin/env python3
"""
Positional assertions for the rendered app icon.

WHY THIS EXISTS, and why colour counts are not enough: a vertically mirrored
mark has IDENTICAL colour counts to a correct one. The 2026-09-06 verification
counted red/yellow/blue pixels per size, passed cleanly, and the icon that
shipped was a fern frond — grains angling inward at the top, splaying at the
bottom, with the stem emerging as a bare stub. Counting *how much* of each
colour is present says nothing about *where* it is or *which way it points*.

So these assert geometry, in SCREEN coordinates (y measured DOWN from the top),
which is the same frame §2 of the work order is written in:

  1. RAMP ORDER      red's centroid is above yellow's is above blue's.
  2. STEM ABOVE      the stem's topmost pixel is above the red pair's topmost.
  3. GRAIN SPLAY     each grain's top end is FURTHER FROM the stem than its
                     bottom end — i.e. the V opens upward. This is the one the
                     mirrored render failed, and the one colour counts cannot see.

SCOPE NOTE. This checks whichever of its known filenames exist in the directory
it is given, so what gets covered depends on the caller:

  design/appicon/png            all 7 recognised sizes (32@2x…512@2x, plus the
                                two coarse slots) — the full ladder
  an unpacked AppIcon.icns      only 4, because Xcode compiles just
                                ic04/ic11/ic07/ic13 = 16/32/128/256 px into the
                                icns; 512 and 1024 go to Assets.car and are NOT
                                seen here

So the build phase (scripts/verify-appicon.sh) is a subset check by construction.
Run this directly against design/appicon/png after re-rendering if you want the
whole ladder asserted.

Usage:  python3 verify_icon.py <png-dir>
Exit 0 if every checked file passes, 1 otherwise.
"""

import struct
import sys
import zlib
from pathlib import Path

RED = (0xFF, 0x45, 0x3A)
YELLOW = (0xFF, 0xD6, 0x0A)
BLUE = (0x0A, 0x84, 0xFF)
GREY = (0x98, 0x98, 0x9D)

# Only sizes with enough pixels for centroids to be meaningful. The coarse
# slots (16px, 32px) are checked for ramp order only — see main().
FULL_MARK_FILES = ["icon_32x32@2x.png", "icon_128x128.png", "icon_256x256.png",
                   "icon_512x512.png", "icon_512x512@2x.png"]
COARSE_FILES = ["icon_16x16@2x.png", "icon_32x32.png"]


def read_png(path):
    """Decode a PNG to (width, height, channels, pixel bytes). No dependencies."""
    data = Path(path).read_bytes()
    pos, idat = 8, b""
    width = height = channels = None
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, _, colour_type = struct.unpack(">IIBB", body[:10])
            channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colour_type]
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        pos += 12 + length

    raw = zlib.decompress(idat)
    stride = width * channels
    out, prev, p = bytearray(), bytearray(stride), 0
    for _ in range(height):
        filt = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if filt == 1:
                line[i] = (line[i] + a) & 255
            elif filt == 2:
                line[i] = (line[i] + b) & 255
            elif filt == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif filt == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 255
        out += line
        prev = line
    return width, height, channels, bytes(out)


def pixels_of(img, target, tol=28):
    """Screen-coordinate (x, y) of every opaque pixel matching `target`."""
    w, h, ch, px = img
    tr, tg, tb = target
    found = []
    for y in range(h):
        row = y * w
        for x in range(w):
            i = (row + x) * ch
            if ch == 4 and px[i + 3] < 200:
                continue
            if (abs(px[i] - tr) < tol and abs(px[i + 1] - tg) < tol
                    and abs(px[i + 2] - tb) < tol):
                found.append((x, y))
    return found


def centroid_y(points):
    return sum(y for _, y in points) / len(points)


def check_ramp_order(img, name, coarse, failures):
    """1. Red above blue (and above yellow, when the middle pair is present)."""
    red = pixels_of(img, RED)
    blue = pixels_of(img, BLUE)
    if not red or not blue:
        failures.append(f"{name}: missing red or blue pixels entirely")
        return
    ry, by = centroid_y(red), centroid_y(blue)
    if not ry < by:
        failures.append(
            f"{name}: RAMP INVERTED — red centroid_y={ry:.1f} is not above "
            f"blue centroid_y={by:.1f} (screen coords, y down)")
    if not coarse:
        yellow = pixels_of(img, YELLOW)
        if not yellow:
            failures.append(f"{name}: full mark is missing yellow")
            return
        yy = centroid_y(yellow)
        if not (ry < yy < by):
            failures.append(
                f"{name}: RAMP OUT OF ORDER — expected red<yellow<blue by "
                f"centroid_y, got red={ry:.1f} yellow={yy:.1f} blue={by:.1f}")


def check_stem_above_red(img, name, failures):
    """2. The stem's point must clear the top pair — that is what makes the ear."""
    stem = pixels_of(img, GREY, tol=20)
    red = pixels_of(img, RED)
    if not stem or not red:
        failures.append(f"{name}: missing stem or red pixels")
        return
    stem_top = min(y for _, y in stem)
    red_top = min(y for _, y in red)
    if not stem_top < red_top:
        failures.append(
            f"{name}: STEM DOES NOT CLEAR THE TOP PAIR — stem top y={stem_top} "
            f"is not above red top y={red_top}")


def check_grain_splay(img, name, failures):
    """3. THE ONE COLOUR COUNTS CANNOT SEE.

    For the LEFT grain of the top pair, the top end must sit further from the
    stem (smaller x) than the bottom end. If the mark is mirrored vertically the
    inequality reverses, while every colour count stays identical.
    """
    w = img[0]
    red = [(x, y) for x, y in pixels_of(img, RED) if x < w / 2]
    if len(red) < 40:
        failures.append(f"{name}: too few left-side red pixels to judge splay")
        return

    ys = sorted({y for _, y in red})
    band = max(1, len(ys) // 4)
    top_rows, bottom_rows = set(ys[:band]), set(ys[-band:])
    top_x = [x for x, y in red if y in top_rows]
    bottom_x = [x for x, y in red if y in bottom_rows]
    mean_top = sum(top_x) / len(top_x)
    mean_bottom = sum(bottom_x) / len(bottom_x)

    if not mean_top < mean_bottom:
        failures.append(
            f"{name}: GRAINS MIRRORED — left red grain's top end (mean x="
            f"{mean_top:.1f}) is not further from the stem than its bottom end "
            f"(mean x={mean_bottom:.1f}). The V opens downward: this is the fern "
            f"frond, and it has the same colour counts as the correct mark.")


def main():
    directory = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    failures, checked = [], 0

    for name in FULL_MARK_FILES:
        path = directory / name
        if not path.exists():
            continue
        img = read_png(path)
        check_ramp_order(img, name, coarse=False, failures=failures)
        check_stem_above_red(img, name, failures)
        check_grain_splay(img, name, failures)
        checked += 1

    for name in COARSE_FILES:
        path = directory / name
        if not path.exists():
            continue
        img = read_png(path)
        # Coarse slots are 16-32px: centroids are sound, but a 4-row "band" is
        # too few pixels to judge splay honestly, so that check is full-mark only.
        check_ramp_order(img, name, coarse=True, failures=failures)
        checked += 1

    if not checked:
        print(f"no icon PNGs found in {directory}", file=sys.stderr)
        return 1

    if failures:
        print(f"FAILED — {len(failures)} problem(s) across {checked} file(s):")
        for f in failures:
            print(f"  ✗ {f}")
        return 1

    print(f"PASSED — ramp order, stem clearance and grain splay OK "
          f"across {checked} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
