#!/usr/bin/env bash
#
# scripts/build.sh — produce a distributable app, then stop.
#
# THIS IS THE ENTIRE DISTRIBUTION STORY. Distribution is source-only: no signing,
# no notarization, no binaries. A stranger's whole experience is clone → run this
# → get a working app, and there is no fallback if it doesn't work.
#
# NOT dev-run.sh. That is a development loop — it installs to /Applications,
# restarts launchd agents, relaunches the app, and asserts that the running
# artifacts agree. This produces an ARTIFACT and stops. It never installs, never
# touches a running backend, and never starts anything.
#
# WHAT IT DOES NOT BUNDLE: a Python runtime. macOS ships /usr/bin/python3 and
# flask is the only third-party dependency (D68), so the app runs on a stock
# machine with nothing installed. scripts/bundle-backend.sh does that work — it
# is invoked by the Xcode "Bundle backend" build phase, not called from here, so
# there is exactly one bundling implementation and it cannot drift.
#
# Usage:
#   scripts/build.sh                    # build to ./build/Thresher.app
#   scripts/build.sh --output DIR       # build somewhere else
#   scripts/build.sh --allow-dirty      # proceed on a dirty tree (stamp reads -dirty)
#   scripts/build.sh --debug            # Debug configuration (development only)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRONTEND_DIR="$REPO_ROOT/frontend"
SCHEME="Thresher"
CONFIG="Release"
OUTPUT_DIR="$REPO_ROOT/build"
ALLOW_DIRTY=0
FLOOR_PYTHON="/usr/bin/python3"
MIN_MACOS_MAJOR=14   # D36: deployment target floor is macOS 14 (Sonoma)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)      OUTPUT_DIR="${2:-}"; shift 2 ;;
        --allow-dirty) ALLOW_DIRTY=1; shift ;;
        --debug)       CONFIG="Debug"; shift ;;
        -h|--help)     sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
done
[[ -n "$OUTPUT_DIR" ]] || { echo "error: --output needs a directory" >&2; exit 2; }

step()  { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
note()  { printf '  %s\n' "$*"; }
warn()  { printf '  \033[33m! %s\033[0m\n' "$*"; }
fail()  { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── 1. Prerequisites ─────────────────────────────────────────────────────────
#
# Checked up front and by NAME. "A broken bundle that builds successfully" is the
# failure this script exists to prevent, and the way that happens is a missing
# prerequisite producing a partial artifact that still exits 0. Each failure below
# says what is missing AND what to do about it, because the person hitting it is
# a stranger with no context for this project.
step "1/5  Checking prerequisites"

MACOS_VER="$(sw_vers -productVersion 2>/dev/null || echo 0)"
MACOS_MAJOR="${MACOS_VER%%.*}"
if [[ "$MACOS_MAJOR" -lt "$MIN_MACOS_MAJOR" ]]; then
    fail "macOS $MACOS_VER is too old — this app targets macOS $MIN_MACOS_MAJOR (Sonoma) or later (D36).
      There is no workaround: the SwiftUI APIs it uses do not exist on earlier systems."
fi
ok "macOS $MACOS_VER"

if ! command -v xcodebuild >/dev/null 2>&1; then
    fail "xcodebuild not found — install the Xcode command line tools:
          xcode-select --install
      If Xcode is installed but not selected:
          sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi
# `xcodebuild -version` fails when only the CLI tools are present without a full
# Xcode — a real and confusing state, because xcodebuild EXISTS but cannot build
# an app. Catch it here rather than 200 lines into a build log.
#
# ⚠️ THIS CHECK REPORTS WHAT IT OBSERVED, NOT A DIAGNOSIS. An earlier version
# asserted "xcodebuild is present but not usable — the command line tools are
# selected instead of a full Xcode" on ANY non-zero exit. That fired twice on a
# machine with a correctly-selected full Xcode (`xcode-select -p` pointing at
# Xcode.app, and the very next run succeeding), and would have sent a stranger
# to reconfigure a working install.
#
# The cause was never reproduced: 12 consecutive runs in isolation, 6 under
# `set -euo pipefail`, and 6 with a concurrent xcodebuild all passed. So the
# honest message names the exit code and the captured stderr, offers
# `xcode-select -p` output as evidence, and says a retry may simply work — since
# on both observed occurrences it did.
#
# stderr is CAPTURED rather than discarded, because it is the one piece of
# evidence that would identify this if it recurs.
XCODE_ERR="$(mktemp -t thresher-xcodebuild-err)"
if XCODE_RAW="$(xcodebuild -version 2>"$XCODE_ERR")"; then
    XCODE_VER="$(printf '%s' "$XCODE_RAW" | head -1)"
    rm -f "$XCODE_ERR"
else
    XCODE_EXIT=$?
    printf '  \033[31m✗ xcodebuild -version failed (exit %s)\033[0m\n' "$XCODE_EXIT" >&2
    if [[ -s "$XCODE_ERR" ]]; then
        printf '    it said:\n' >&2
        sed 's/^/      /' "$XCODE_ERR" >&2
    else
        printf '    it printed nothing to stderr.\n' >&2
    fi
    printf '    xcode-select -p: %s\n' "$(xcode-select -p 2>&1 || echo '(failed)')" >&2
    rm -f "$XCODE_ERR"
    fail "could not determine the Xcode version.
      If xcode-select -p above points at Xcode.app, this may be transient —
      try again. If it points at CommandLineTools, xcodebuild exists but
      cannot build an app; select a full Xcode with:
          sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi
ok "$XCODE_VER"

if [[ ! -x "$FLOOR_PYTHON" ]]; then
    fail "no interpreter at $FLOOR_PYTHON — the bundled backend runs on the system
      python3 that ships with macOS. If it is missing, the command line tools
      install usually restores it:  xcode-select --install"
fi
ok "$("$FLOOR_PYTHON" --version 2>&1) at $FLOOR_PYTHON"

# rsync and pip are used by bundle-backend.sh during the build phase. Failing
# here names the missing tool; failing there is buried in an xcodebuild log.
command -v rsync >/dev/null 2>&1 || fail "rsync not found — required to assemble the bundled backend"
"$FLOOR_PYTHON" -m pip --version >/dev/null 2>&1 \
    || fail "pip is not available to $FLOOR_PYTHON — required to vendor flask into the bundle.
      Try:  $FLOOR_PYTHON -m ensurepip"
ok "rsync and pip available"

# ── 2. Working tree ──────────────────────────────────────────────────────────
#
# Not pedantry: the provenance stamp appends `-dirty`, and a distributable build
# that reports a dirty SHA cannot be traced back to anything. Allowed explicitly
# for local iteration, never silently.
step "2/5  Verifying the working tree"
cd "$REPO_ROOT"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    if [[ "$ALLOW_DIRTY" -eq 1 ]]; then
        warn "tree is dirty (--allow-dirty) — the build will be stamped -dirty"
    else
        printf '  \033[31m✗ working tree is not clean:\033[0m\n' >&2
        git status --porcelain | sed 's/^/    /' >&2
        fail "commit or stash the above, or re-run with --allow-dirty"
    fi
else
    ok "clean"
fi
HEAD_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
ok "HEAD is $HEAD_SHA"

# ── 3. Build ─────────────────────────────────────────────────────────────────
#
# The Xcode build phases do the real packaging work: "Bundle backend" invokes
# scripts/bundle-backend.sh, "Stamp build provenance" writes ISBuildSHA, and
# "Verify app icon" asserts the icon is not mirrored. Reusing them rather than
# reimplementing means a build here and a build in Xcode produce the same bundle.
step "3/5  Building ($CONFIG)"
BUILD_LOG="$(mktemp -t thresher-dist-build)"
if ! ( cd "$FRONTEND_DIR" && xcodebuild -project "$SCHEME.xcodeproj" \
        -scheme "$SCHEME" -configuration "$CONFIG" \
        -destination 'platform=macOS' build ) >"$BUILD_LOG" 2>&1; then
    printf '  \033[31m✗ xcodebuild FAILED — last 40 lines:\033[0m\n' >&2
    tail -40 "$BUILD_LOG" >&2
    fail "build failed (full log: $BUILD_LOG)"
fi
grep -E "note: (stamped|bundled|app icon verified)" "$BUILD_LOG" | sed 's/^/  /' || true
ok "built"

BUILT_APP="$( cd "$FRONTEND_DIR" && xcodebuild -project "$SCHEME.xcodeproj" \
    -scheme "$SCHEME" -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}' )/$SCHEME.app"
[[ -d "$BUILT_APP" ]] || fail "built app not found at $BUILT_APP"

# ── 4. Verify the artifact ───────────────────────────────────────────────────
#
# Everything here is checked on the COPY that will be distributed, not on the
# build directory, so what is asserted is what a stranger actually receives.
step "4/5  Verifying the artifact"

mkdir -p "$OUTPUT_DIR"
DEST="$OUTPUT_DIR/$SCHEME.app"
rm -rf "$DEST"
cp -R "$BUILT_APP" "$DEST"

RES="$DEST/Contents/Resources"

# 4a. The backend actually shipped.
[[ -f "$RES/backend/main.py" ]]     || fail "bundled backend is missing main.py — the app would launch with nothing to supervise"
[[ -d "$RES/backend/api" ]]         || fail "bundled backend is missing the api package"
[[ -d "$RES/backend/_vendor/flask" ]] || fail "flask was not vendored into the bundle — the API cannot start"
ok "backend + vendored flask present"

# 4b. Real seed.sql must never ship — it holds real contacts. bundle-backend.sh
#     checks this too; re-checked here because this is the artifact that leaves
#     the machine, and a second assertion costs nothing against that risk.
if [[ -e "$RES/backend/db/seed.sql" ]]; then
    fail "real seed.sql is inside the bundle — it holds real contacts and must never ship"
fi
[[ -f "$RES/backend/db/seed.example.sql" ]] \
    || fail "seed.example.sql missing — a fresh install cannot seed its database"
ok "example seed only (no real contacts)"

# 4c. Provenance stuck. §2.2 requires failing the build if it did not — a
#     distributable that cannot say which commit it is defeats the point of
#     source-only distribution.
APP_SHA="$(/usr/libexec/PlistBuddy -c 'Print :ISBuildSHA' \
    "$DEST/Contents/Info.plist" 2>/dev/null || echo '')"
[[ -n "$APP_SHA" ]] || fail "no ISBuildSHA in the built app — the provenance phase did not run or did not stick"
BACKEND_SHA="$(cat "$RES/backend/BUILD_SHA" 2>/dev/null || echo '')"
[[ -n "$BACKEND_SHA" ]] || fail "bundled backend has no BUILD_SHA stamp"
if [[ "$APP_SHA" != "$BACKEND_SHA" ]]; then
    fail "app ($APP_SHA) and bundled backend ($BACKEND_SHA) are stamped differently —
      they are not the same build"
fi
ok "provenance stamped: $APP_SHA (app and backend agree)"

# 4d. No Python runtime rode along. If one ever does, the distribution story
#     changes (size, relocation, signing) and that should be a decision, not a
#     side effect of someone adding a dependency.
if [[ -d "$RES/backend/_vendor" ]]; then
    STOWAWAY="$(find "$RES/backend/_vendor" -maxdepth 1 -name 'python*' -type d 2>/dev/null | head -1)"
    [[ -z "$STOWAWAY" ]] || warn "a python runtime appears to be vendored at $STOWAWAY — D68 says none should be"
fi

# 4e. The bundled backend imports on the FLOOR interpreter, from the DISTRIBUTED
#     copy. bundle-backend.sh proves this for the build directory; proving it
#     here catches anything the copy itself broke.
if ! PYTHONPATH="$RES/backend/_vendor" "$FLOOR_PYTHON" -c "
import sys; sys.path.insert(0, '$RES/backend')
import api.app, main, ingestion.pipeline, db.database
" 2>/dev/null; then
    fail "the distributed backend does not import on $FLOOR_PYTHON — it would fail on a stock machine"
fi
ok "bundled backend imports on $FLOOR_PYTHON"

SIZE="$(du -sh "$DEST" | cut -f1)"

# ── 5. Done ──────────────────────────────────────────────────────────────────
step "5/5  Done"
printf '\n\033[32mBuilt %s (%s), stamped %s\033[0m\n\n' "$SCHEME.app" "$SIZE" "$APP_SHA"
printf '  %s\n\n' "$DEST"
printf 'To use it, move it to your Applications folder and open it:\n\n'
printf '    mv %s /Applications/\n' "$(printf '%q' "$DEST")"
printf '    open /Applications/%s.app\n\n' "$SCHEME"
printf 'The app starts and stops its own backend (D67) — nothing else to install\n'
printf 'or run. On first launch it will ask for notification permission and walk\n'
printf 'you through connecting a mailbox.\n\n'
printf 'Developing on this instead? See docs/DEVELOPMENT.md — the development\n'
printf 'loop is scripts/dev-run.sh, and it is a different thing from this script.\n\n'
