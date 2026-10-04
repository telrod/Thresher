#!/usr/bin/env bash
#
# scripts/dev-run.sh — build, install, and run everything from HEAD, in one command.
#
# WHY THIS EXISTS: the backend and the app are separate artifacts started
# separately, and they have drifted from HEAD more than once. The Session 28–32
# human gate was nearly run against an app binary that predated the whole
# session — a gate against the wrong binary is a false PASS recorded with full
# confidence, which is worse than not running it.
#
# **Step 5 is the point of this script.** Building and launching are
# conveniences; asserting that the app's stamp and GET /version AGREE is the
# job. If they differ this exits non-zero and says so, because a mismatch means
# anything you observe afterwards is about an unknown pair of artifacts.
#
# Usage:
#   scripts/dev-run.sh                 # full: verify → build → install → restart → launch
#   scripts/dev-run.sh --skip-build    # reuse the current build (fast re-verify)
#   scripts/dev-run.sh --no-launch     # everything except opening the app
#   scripts/dev-run.sh --allow-dirty   # proceed on a dirty tree (stamps read -dirty)
#
# Idempotent and safe to re-run: an already-running backend is stopped first
# (including an orphan holding 8765 outside the PID file), and the installed app
# is replaced rather than merged.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRONTEND_DIR="$REPO_ROOT/frontend"
APP_DEST="/Applications/Thresher.app"
API_URL="http://127.0.0.1:8765"
SCHEME="Thresher"
CONFIG="Release"

SKIP_BUILD=0
NO_LAUNCH=0
ALLOW_DIRTY=0
for arg in "$@"; do
    case "$arg" in
        --skip-build)  SKIP_BUILD=1 ;;
        --no-launch)   NO_LAUNCH=1 ;;
        --allow-dirty) ALLOW_DIRTY=1 ;;
        -h|--help)     sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

step()  { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail()  { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
note()  { printf '  %s\n' "$*"; }
warn()  { printf '  \033[33m! %s\033[0m\n' "$*"; }

# ── 1. Clean tree ────────────────────────────────────────────────────────────
# Not pedantry: the provenance phase appends `-dirty` to the stamp, so a dirty
# tree makes step 5's comparison ambiguous — you can no longer tell "these
# artifacts match" from "these artifacts are both differently wrong".
step "1/6  Verifying the working tree"
cd "$REPO_ROOT"
DIRTY="$(git status --porcelain)"
if [[ -n "$DIRTY" ]]; then
    if [[ "$ALLOW_DIRTY" -eq 1 ]]; then
        note "tree is dirty (--allow-dirty); stamps will read -dirty:"
        printf '    %s\n' "$DIRTY"
    else
        printf '  \033[31m✗ working tree is not clean:\033[0m\n' >&2
        printf '    %s\n' "$DIRTY" >&2
        fail "commit, stash, or gitignore the above — or re-run with --allow-dirty"
    fi
else
    ok "clean"
fi
HEAD_SHA="$(git rev-parse --short HEAD)"
ok "HEAD is $HEAD_SHA"

# ── 2. Build ─────────────────────────────────────────────────────────────────
step "2/6  Building from HEAD"
if [[ "$SKIP_BUILD" -eq 1 ]]; then
    note "skipped (--skip-build)"
else
    # The backend is plain Python with a stdlib-only runtime — there is no
    # virtualenv or dependency step to run beyond Flask being importable. Assert
    # that rather than assume it, so a broken environment fails HERE with a
    # clear message instead of at the first request.
    ( cd "$REPO_ROOT/backend" && python3 -c "import flask, sqlite3" ) \
        || fail "backend environment is not importable (need flask on python3)"
    ok "backend environment importable"

    BUILD_LOG="$(mktemp -t thresher-build)"
    if ! ( cd "$FRONTEND_DIR" && xcodebuild -project "$SCHEME.xcodeproj" \
            -scheme "$SCHEME" -configuration "$CONFIG" \
            -destination 'platform=macOS' build ) >"$BUILD_LOG" 2>&1; then
        printf '  \033[31m✗ xcodebuild FAILED — last 30 lines:\033[0m\n' >&2
        tail -30 "$BUILD_LOG" >&2
        fail "build failed (full log: $BUILD_LOG)"
    fi
    grep -E "note: stamped" "$BUILD_LOG" | tail -1 | sed 's/^/  /' || true
    ok "app built ($CONFIG)"
fi

# Locate the product from the build settings rather than guessing at a
# DerivedData path — the hash in that path is not stable across machines.
BUILT_APP="$( cd "$FRONTEND_DIR" && xcodebuild -project "$SCHEME.xcodeproj" \
    -scheme "$SCHEME" -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}' )/$SCHEME.app"
[[ -d "$BUILT_APP" ]] || fail "built app not found at $BUILT_APP (run without --skip-build)"

# ── 3. Install ───────────────────────────────────────────────────────────────
step "3/6  Installing to $APP_DEST"
if pgrep -x "$SCHEME" >/dev/null 2>&1; then
    note "app is running — quitting it first"
    pkill -x "$SCHEME" || true
    for _ in $(seq 1 20); do pgrep -x "$SCHEME" >/dev/null 2>&1 || break; sleep 0.25; done
fi
# Replace, never merge: copying over a bundle leaves stale resources behind, and
# a stale Info.plist would defeat the very check this script exists to make.
rm -rf "$APP_DEST"
cp -R "$BUILT_APP" "$APP_DEST"
ok "installed"

# ── 4. Restart the backend at HEAD ───────────────────────────────────────────
step "4/6  Restarting the backend"

# D66: launchd may own the backend. If it does, RESTART IT THROUGH launchd —
# killing the processes here would just have launchd respawn its own copies,
# leaving two APIs racing for 8765 and the stamp check in step 5 comparing
# against whichever won. `kickstart -k` restarts in place, so the agents keep
# supervising and come back running the newly-checked-out code.
# NOTE: `launchctl list | grep -q` is WRONG under `set -o pipefail` — grep -q
# exits at the first match, launchctl dies of SIGPIPE (141), and pipefail makes
# the whole condition false. That silently skipped this branch and let the
# script kill a launchd-owned API, which respawned and failed step 4. Capture
# first, match second.
LAUNCHD_OWNED=0
LAUNCHCTL_LIST="$(launchctl list 2>/dev/null || true)"
if [[ "$LAUNCHCTL_LIST" == *"com.tomelrod.thresher."* ]]; then
    LAUNCHD_OWNED=1
    note "launchd owns the backend (D66) — restarting through it, not backend.sh"
    launchctl kickstart -k "gui/$UID/com.tomelrod.thresher.api" >/dev/null 2>&1 \
        || fail "could not restart the API agent"
    launchctl kickstart -k "gui/$UID/com.tomelrod.thresher.pipeline" >/dev/null 2>&1 \
        || fail "could not restart the pipeline agent"
    ok "agents restarted"
fi

if [[ "$LAUNCHD_OWNED" -eq 0 ]]; then
"$REPO_ROOT/scripts/backend.sh" stop >/dev/null 2>&1 || true
# backend.sh only knows about processes it started. A bare `python3 -m
# api.server` (or a crashed-and-restarted shell) can leave an orphan holding
# 8765 that `stop` cannot see — then the "restarted" backend is silently the OLD
# one, which is exactly the drift this script exists to catch.
ORPHANS="$(lsof -nP -iTCP:8765 -sTCP:LISTEN -t 2>/dev/null || true)"
if [[ -n "$ORPHANS" ]]; then
    note "killing orphan process(es) on 8765 outside the PID file: $(echo "$ORPHANS" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    kill $ORPHANS 2>/dev/null || true
    sleep 1
    ORPHANS="$(lsof -nP -iTCP:8765 -sTCP:LISTEN -t 2>/dev/null || true)"
    [[ -z "$ORPHANS" ]] || fail "port 8765 is still held by: $ORPHANS"
fi
"$REPO_ROOT/scripts/backend.sh" start >/dev/null || fail "backend failed to start"
fi
for _ in $(seq 1 30); do
    curl -fsS "$API_URL/health" >/dev/null 2>&1 && break
    sleep 0.5
done
curl -fsS "$API_URL/health" >/dev/null 2>&1 || fail "backend did not become healthy at $API_URL"
ok "backend healthy"

# ── 5. THE POINT OF THIS SCRIPT: do the two artifacts agree? ─────────────────
step "5/6  Verifying app and backend are the same build"
APP_SHA="$(/usr/libexec/PlistBuddy -c 'Print :ISBuildSHA' \
    "$APP_DEST/Contents/Info.plist" 2>/dev/null || echo 'unknown')"
API_SHA="$(curl -fsS "$API_URL/version" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("git_sha","unknown"))' \
    2>/dev/null || echo 'unknown')"

printf '  app     : %s\n' "$APP_SHA"
printf '  backend : %s\n' "$API_SHA"
printf '  HEAD    : %s\n' "$HEAD_SHA"

[[ "$APP_SHA" == "unknown" ]] && fail "app has no ISBuildSHA — the provenance phase did not run"
[[ "$API_SHA" == "unknown" ]] && fail "backend did not report a git_sha"
if [[ "$APP_SHA" != "$API_SHA" ]]; then
    fail "STAMP MISMATCH — the app and backend are different builds. Anything you observe now is about an unknown pair of artifacts."
fi
# Compared against HEAD separately: matching each other but not HEAD is a real
# state (--skip-build after a commit) and deserves its own message.
if [[ "$APP_SHA" != "$HEAD_SHA" && "$APP_SHA" != "$HEAD_SHA-dirty" ]]; then
    fail "both artifacts are $APP_SHA but HEAD is $HEAD_SHA — rebuild (drop --skip-build)"
fi
ok "app and backend agree, and match HEAD"

# ── 5b. Exactly one bundle may claim the identifier ──────────────────────────
#
# Session 36 Part E. Two copies of the app registered with LaunchServices is
# not a hypothetical: on 2026-09-02 both /Applications/Thresher.app AND the
# DerivedData Debug build claimed com.tomelrod.Thresher.
#
# WHY IT MATTERS MORE THAN IT LOOKS. Gate item 2.2 ("quit the app, send mail,
# expect a banner") was recorded as a FAIL on 2026-09-01. It was not a defect:
# the API log showed an unbroken polling cadence with the notification cursor
# advancing 295 -> 296 -> 297, so a SECOND running instance consumed both test
# notifications while the watched one was quit. A duplicate registration is
# also the leading suspect for OI27 (banners showing the wrong icon), since
# macOS resolves the icon through whichever bundle LaunchServices prefers.
#
# The stamp check above cannot see this: both copies can report the same SHA
# and still be two different processes racing for the same notification feed.
#
# A warning rather than a failure — a DerivedData registration is the normal
# result of building in Xcode, and blocking every dev run on it would just
# train people to ignore the message.

step "5b/6  LaunchServices registrations"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BUNDLES="$("$LSREGISTER" -dump 2>/dev/null \
    | grep -io "path: *.*Thresher\.app" \
    | sed 's/^ *[Pp]ath: *//' | sort -u || true)"
BUNDLE_COUNT="$(printf '%s\n' "$BUNDLES" | grep -c . || true)"

if [[ "$BUNDLE_COUNT" -le 1 ]]; then
    ok "exactly one bundle claims com.tomelrod.Thresher"
else
    warn "$BUNDLE_COUNT bundles claim com.tomelrod.Thresher:"
    printf '%s\n' "$BUNDLES" | sed 's/^/      /'
    warn "A gate run can watch one copy while another answers the notification feed"
    warn "(that is what made item 2.2 record a false Fail on 2026-09-01)."

    # Unregister every claimant that is NOT the installed app. Safe to do here
    # and nowhere else: this script has just installed /Applications and is
    # about to launch it, so a build-products copy is unambiguously stale.
    #
    # This RECURS — xcodebuild re-registers the DerivedData bundle on every
    # build (verified 2026-09-02: cleared, then back after one test run, while
    # a non-build command left it clear). So clearing it once is not a fix, and
    # doing it here means it happens after the last build before a gate.
    while IFS= read -r b; do
        [[ -z "$b" || "$b" == "$APP_DEST" ]] && continue
        if "$LSREGISTER" -u "$b" 2>/dev/null; then
            ok "unregistered stale bundle: $b"
        else
            warn "could not unregister: $b"
        fi
    done <<< "$BUNDLES"

    AFTER="$("$LSREGISTER" -dump 2>/dev/null \
        | grep -io "path: *.*Thresher\.app" \
        | sed 's/^ *[Pp]ath: *//' | sort -u || true)"
    AFTER_COUNT="$(printf '%s\n' "$AFTER" | grep -c . || true)"
    if [[ "$AFTER_COUNT" -le 1 ]]; then
        ok "exactly one bundle claims com.tomelrod.Thresher"
    else
        warn "$AFTER_COUNT still registered — clear by hand before judging Part 2"
    fi
fi

# Whatever is registered, nothing else may be RUNNING when a gate starts.
RUNNING="$(pgrep -fl "Thresher.app/Contents/MacOS/Thresher" 2>/dev/null || true)"
RUNNING_COUNT="$(printf '%s\n' "$RUNNING" | grep -c . || true)"
if [[ "$RUNNING_COUNT" -gt 1 ]]; then
    warn "$RUNNING_COUNT instances are ALREADY RUNNING — quit them before a gate run:"
    printf '%s\n' "$RUNNING" | sed 's/^/      /'
fi

# ── 6. Launch ────────────────────────────────────────────────────────────────
step "6/6  Launching"
if [[ "$NO_LAUNCH" -eq 1 ]]; then
    note "skipped (--no-launch)"
else
    open -a "$APP_DEST"
    ok "launched"
fi

printf '\n\033[32mReady.\033[0m App and backend both at %s\n\n' "$APP_SHA"
