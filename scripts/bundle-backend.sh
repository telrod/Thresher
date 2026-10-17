#!/usr/bin/env bash
#
# scripts/bundle-backend.sh — copy the backend into the app bundle (D68).
#
# WHY: the app shipped no backend at all, so `BackendSupervisor` (D67) had
# nothing to supervise on any machine that wasn't the author's checkout. That was the
# last thing standing between D67 and beta.
#
# WHAT SHIPS, and what deliberately does not:
#
#   - `backend/` sources, minus tests, __pycache__, and any local seed.sql.
#     seed.sql holds REAL CONTACTS (that is why it is gitignored); shipping it
#     inside an app bundle would distribute the author's address book. The committed
#     seed.example.sql goes instead, and init_db seeds from it on first run.
#   - `_vendor/` — flask and its dependencies at the exact versions pinned in
#     backend/requirements.txt (D90), resolved FOR THE FLOOR INTERPRETER (see
#     below), ~2.6 MB.
#   - No Python runtime. /usr/bin/python3 is a shim that runs the Python 3.9
#     inside Xcode or the Command Line Tools (chosen by xcode-select), and the
#     whole API was verified to run on it (3.9.6) with the vendored tree. Bundling an
#     interpreter would add ~24-40 MB and a framework-relocation/signing problem
#     for no capability we need.
#
# THE FLOOR INTERPRETER IS THE POINT. Dependencies are resolved with
# /usr/bin/python3, not with whatever pyenv the developer happens to have on
# PATH. A wheel resolved for 3.11 can be silently incompatible with 3.9, and the
# failure would appear only on a user's machine. `backend/tests/test_python_floor.py`
# guards the other half — that our own sources still import on that interpreter.
#
# Idempotent: the destination is removed and rebuilt, never merged, so a deleted
# source file cannot survive in the bundle.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/backend"
FLOOR_PYTHON="${FLOOR_PYTHON:-/usr/bin/python3}"

DEST="${1:-}"
if [[ -z "$DEST" ]]; then
    echo "usage: bundle-backend.sh <destination-Resources-dir>" >&2
    exit 64
fi

say() { printf '  %s\n' "$*"; }

[[ -x "$FLOOR_PYTHON" ]] || { echo "error: no interpreter at $FLOOR_PYTHON" >&2; exit 1; }

BACKEND_DEST="$DEST/backend"
rm -rf "$BACKEND_DEST"
mkdir -p "$BACKEND_DEST"

# ── sources ────────────────────────────────────────────────────────────────
# Explicit excludes rather than an allowlist of what to copy: a new package
# should ship by default, whereas forgetting to add one to an allowlist is a
# runtime ImportError on someone else's machine.
rsync -a \
    --exclude 'tests/' \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    --exclude '.run/' \
    --exclude 'seed.sql' \
    --exclude '_vendor/' \
    "$SRC/" "$BACKEND_DEST/"

# seed.sql is excluded above because it holds real contacts. Fail loudly if it
# somehow arrived anyway — silently distributing an address book is exactly the
# kind of thing that must not degrade quietly.
if [[ -e "$BACKEND_DEST/db/seed.sql" ]]; then
    echo "error: real seed.sql reached the bundle — it holds real contacts" >&2
    exit 1
fi
[[ -f "$BACKEND_DEST/db/seed.example.sql" ]] \
    || { echo "error: seed.example.sql missing; a fresh install cannot seed" >&2; exit 1; }
say "sources copied (tests, caches and local seed excluded)"

# ── build provenance ───────────────────────────────────────────────────────
# A bundled backend cannot ask git which commit it is, so the answer is stamped
# beside it. Without this the shipped backend reports `unknown` — or worse,
# answers from whatever repository it happens to be launched from, which would
# be a confident SHA describing different code. Same honesty rule the app's own
# stamp follows: an unverifiable tree reports -dirty rather than claiming clean.
SHA="$(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ "$SHA" != "unknown" ]]; then
    if [[ -n "$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null)" ]]; then
        SHA="${SHA}-dirty"
    fi
fi
printf '%s\n' "$SHA" > "$BACKEND_DEST/BUILD_SHA"
say "stamped BUILD_SHA=$SHA"

# ── vendored dependencies ──────────────────────────────────────────────────
VENDOR="$BACKEND_DEST/_vendor"
mkdir -p "$VENDOR"
# --target with the FLOOR interpreter, so wheels match what will run them.
# Installed from exact pins (D90): an unpinned `flask` would pick up whatever
# release is newest on the day of the build.
REQUIREMENTS="$SRC/requirements.txt"
[[ -f "$REQUIREMENTS" ]] || { echo "error: $REQUIREMENTS missing" >&2; exit 1; }
"$FLOOR_PYTHON" -m pip install --quiet --disable-pip-version-check \
    --target "$VENDOR" -r "$REQUIREMENTS" >/dev/null
# pip leaves a bin/ of console scripts with absolute shebangs into the build
# machine's paths. Useless in a bundle and actively misleading in a signed app.
rm -rf "$VENDOR/bin"
find "$VENDOR" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

# What was vendored must be exactly what is pinned: no package missing, none
# extra, no version different. pip satisfies a pin it can, so a dependency added
# by a future bump would otherwise arrive unpinned without anyone noticing.
if ! "$FLOOR_PYTHON" - "$REQUIREMENTS" "$VENDOR" <<'EOF'
import pathlib, re, sys
norm = lambda n: re.sub(r"[-_.]+", "_", n).lower()
pinned = {}
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    line = line.split("#", 1)[0].strip()
    if not line:
        continue
    m = re.fullmatch(r"([A-Za-z0-9_.-]+)==([A-Za-z0-9_.+!-]+)", line)
    if not m:
        sys.exit(f"not an exact pin: {line!r}")
    pinned[norm(m.group(1))] = m.group(2)
vendored = {}
for d in pathlib.Path(sys.argv[2]).glob("*.dist-info"):
    name, version = d.name[: -len(".dist-info")].rsplit("-", 1)
    vendored[norm(name)] = version
if vendored != pinned:
    for n in sorted(set(pinned) | set(vendored)):
        if pinned.get(n) != vendored.get(n):
            print(f"  {n}: pinned {pinned.get(n)}, vendored {vendored.get(n)}",
                  file=sys.stderr)
    sys.exit(1)
EOF
then
    echo "error: vendored packages differ from $REQUIREMENTS" >&2
    exit 1
fi
say "vendored $(grep -c '==' "$REQUIREMENTS") pinned packages for $("$FLOOR_PYTHON" --version 2>&1) ($(du -sh "$VENDOR" | cut -f1)), matching requirements.txt"

# ── verify, rather than assume ─────────────────────────────────────────────
# The bundle is only useful if the floor interpreter can actually import the API
# from it. Checking here turns a broken bundle into a failed build instead of a
# beta user's blank window.
if ! PYTHONPATH="$VENDOR" "$FLOOR_PYTHON" -c "
import sys; sys.path.insert(0, '$BACKEND_DEST')
import api.app, main, ingestion.pipeline, db.database
" 2>/dev/null; then
    echo "error: the bundled backend does not import on $FLOOR_PYTHON" >&2
    PYTHONPATH="$VENDOR" "$FLOOR_PYTHON" -c "
import sys; sys.path.insert(0, '$BACKEND_DEST')
import api.app" 2>&1 | tail -5 >&2
    exit 1
fi
say "verified: bundled backend imports on $FLOOR_PYTHON"
say "total: $(du -sh "$BACKEND_DEST" | cut -f1)"
