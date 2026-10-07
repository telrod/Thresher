#!/usr/bin/env bash
#
# scripts/phase3-reset-test-user.sh — return a Phase 3 TEST user to a fresh install.
#
# Deletes, for the user running it:
#   - ~/Library/Application Support/thresher   (database, logs, backups)
#   - every Keychain item with service "thresher"
#   - onboarding.tutorialSeen for the RELEASE bundle ID
#
# It is destructive by design, so it refuses — changing nothing — when:
#   - it is run by the user who owns this repo checkout (the daily user), or
#   - a process named Thresher is running, for ANY user: a running app would
#     recreate what this deletes, and a daily app still running in another
#     session would change the database Phase 3 fingerprints.
#
# Every refusal is checked before anything is touched, and all of them are
# reported, not just the first.
#
# Usage (as the test user, from that user's own Terminal):
#   bash /path/to/Thresher/scripts/phase3-reset-test-user.sh
#
# THRESHER_RESET_DRY_RUN=1 prints what would be deleted instead of deleting
# it. The tests set it so a broken guard cannot delete real data.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_BUNDLE_ID="com.tomelrod.Thresher"
KEYCHAIN_SERVICE="thresher"
DATA_DIR="$HOME/Library/Application Support/thresher"
DRY_RUN="${THRESHER_RESET_DRY_RUN:-0}"

# ── Refusals: all checked, none acted on yet ─────────────────────────────────
refusals=()

me="$(id -un)"
owner="$(stat -f %Su "$REPO_ROOT")"
if [[ "$me" == "$owner" ]]; then
    refusals+=("you are $me, who owns the repo checkout at $REPO_ROOT — this is the daily user, not a test user")
fi

if running="$(pgrep -x Thresher)"; then
    refusals+=("the Thresher app is running (pid $(echo $running | tr '\n' ' ')) — quit it in every user session first")
fi

if (( ${#refusals[@]} > 0 )); then
    echo "phase3-reset-test-user: REFUSED, nothing was changed:" >&2
    for r in "${refusals[@]}"; do
        echo "  - $r" >&2
    done
    exit 2
fi

# ── Reset ────────────────────────────────────────────────────────────────────
run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "would run: $*"
    else
        "$@"
    fi
}

done_word="deleted"
[[ "$DRY_RUN" == "1" ]] && done_word="would delete"

echo "Resetting Thresher for test user $me"

if [[ -e "$DATA_DIR" ]]; then
    run rm -rf "$DATA_DIR"
    echo "  $done_word   $DATA_DIR"
else
    echo "  absent    $DATA_DIR"
fi

# One item per call; loop until none is left.
deleted=0
if [[ "$DRY_RUN" == "1" ]]; then
    run security delete-generic-password -s "$KEYCHAIN_SERVICE"
    echo "  $done_word   every Keychain item for service \"$KEYCHAIN_SERVICE\""
else
    while security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; do
        deleted=$((deleted + 1))
    done
    echo "  deleted   $deleted Keychain item(s) for service \"$KEYCHAIN_SERVICE\""
fi

if defaults read "$RELEASE_BUNDLE_ID" onboarding.tutorialSeen >/dev/null 2>&1; then
    run defaults delete "$RELEASE_BUNDLE_ID" onboarding.tutorialSeen
    echo "  $done_word   $RELEASE_BUNDLE_ID onboarding.tutorialSeen"
else
    echo "  absent    $RELEASE_BUNDLE_ID onboarding.tutorialSeen"
fi

echo "Done. Launch Thresher: it should open on the welcome step."
