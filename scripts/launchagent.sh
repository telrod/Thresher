#!/usr/bin/env bash
#
# scripts/launchagent.sh — install/remove launchd supervision for the backend.
#
# WHY THIS EXISTS
# ---------------
# On 2026-08-13 the poller crashed on a transient IMAP timeout. Nothing
# restarted it, so nothing fetched mail for 13 DAYS — 141 messages were waiting
# on the server when it was finally noticed. The crash itself is fixed (a
# SELECT timeout is now retried instead of killing the account), but "the
# poller only runs as long as the terminal that started it" is a separate and
# more general problem: a laptop reboot, a closed Terminal window, an OOM kill,
# or the next unforeseen crash all end ingestion silently and permanently.
#
# launchd's KeepAlive is the supervisor macOS already ships. With it, a crashed
# poller is back within seconds and the user never learns it happened.
#
# HOW THIS COEXISTS WITH backend.sh
# ---------------------------------
# backend.sh is the DEVELOPMENT front door: it starts processes under its own
# PID files so stop/restart/status work. Two supervisors both trying to own
# port 8765 would be worse than none — a launchd-restarted API racing a
# backend.sh-started one is exactly the orphan-on-8765 confusion dev-run.sh
# already exists to prevent.
#
# So they are mutually exclusive by construction:
#   - `install` stops anything backend.sh is running FIRST, then hands
#     ownership to launchd.
#   - while the agents are loaded, backend.sh start/stop still work on their
#     own PID files, but launchd will resurrect what it owns — so `uninstall`
#     is the right way to go back to manual control, and `install` says so.
#
# The agents run the SAME entry points as backend.sh (main.py and
# api.server) from the same checkout, so there is no second code path to drift.
#
# Usage:
#   scripts/launchagent.sh install     # take over supervision (survives reboot)
#   scripts/launchagent.sh uninstall   # hand control back to backend.sh
#   scripts/launchagent.sh status
#   scripts/launchagent.sh logs        # tail both agent logs

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$REPO_ROOT/backend"
RUN_DIR="$BACKEND_DIR/.run"
AGENT_DIR="$HOME/Library/LaunchAgents"
LABEL_PREFIX="com.tomelrod.thresher"
PIPELINE_LABEL="$LABEL_PREFIX.pipeline"
API_LABEL="$LABEL_PREFIX.api"
API_URL="http://127.0.0.1:8765"

step()  { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail()  { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
note()  { printf '  %s\n' "$*"; }

# Resolve the python3 that actually has flask, at INSTALL time. launchd runs
# with a minimal PATH that will not include pyenv shims, so `python3` alone
# resolves to /usr/bin/python3 — which does not have flask and would fail every
# few seconds forever. Baking the absolute interpreter path into the plist is
# the difference between a supervisor that works and one that thrashes.
resolve_python() {
    local py
    py="$(command -v python3 || true)"
    [[ -n "$py" ]] || fail "no python3 on PATH"
    # Follow pyenv shims to the real binary.
    if "$py" -c "import flask" 2>/dev/null; then
        "$py" -c "import sys; print(sys.executable)"
        return 0
    fi
    fail "the python3 on PATH ($py) cannot import flask — fix the environment first"
}

write_plist() {
    local label="$1" py="$2"; shift 2
    local args=("$@")
    local plist="$AGENT_DIR/$label.plist"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0">'
        echo '<dict>'
        echo "    <key>Label</key><string>$label</string>"
        echo '    <key>ProgramArguments</key>'
        echo '    <array>'
        echo "        <string>$py</string>"
        for a in "${args[@]}"; do echo "        <string>$a</string>"; done
        echo '    </array>'
        echo "    <key>WorkingDirectory</key><string>$BACKEND_DIR</string>"
        # RunAtLoad + KeepAlive: start now, and restart whenever it exits for
        # ANY reason. This is the whole point — a crash must not be terminal.
        echo '    <key>RunAtLoad</key><true/>'
        echo '    <key>KeepAlive</key><true/>'
        # Don't hammer on a persistent failure (e.g. a bad App Password):
        # 30s between respawns keeps a broken config from spinning the CPU,
        # while still recovering from a transient crash promptly.
        echo '    <key>ThrottleInterval</key><integer>30</integer>'
        echo "    <key>StandardOutPath</key><string>$RUN_DIR/$label.log</string>"
        echo "    <key>StandardErrorPath</key><string>$RUN_DIR/$label.log</string>"
        # PATH is for any subprocess (e.g. `security` for the Keychain, which
        # main.py shells out to for the App Password).
        echo '    <key>EnvironmentVariables</key>'
        echo '    <dict>'
        echo '        <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>'
        echo "        <key>PYTHONPATH</key><string>$BACKEND_DIR</string>"
        echo '    </dict>'
        echo '</dict>'
        echo '</plist>'
    } >"$plist"
    plutil -lint "$plist" >/dev/null || fail "generated plist is malformed: $plist"
    echo "$plist"
}

bootout() {
    local label="$1"
    launchctl bootout "gui/$UID/$label" 2>/dev/null || true
    launchctl unload -w "$AGENT_DIR/$label.plist" 2>/dev/null || true
}

cmd_install() {
    mkdir -p "$AGENT_DIR" "$RUN_DIR"

    step "1/4  Checking the environment"
    local PY
    PY="$(resolve_python)"
    ok "python3 with flask: $PY"
    # A Keychain entry is required for the poller to do anything useful. Warn
    # rather than fail — installing supervision before adding an account is a
    # legitimate order, and the agent will simply retry until one exists.
    if security find-generic-password -s "thresher" >/dev/null 2>&1; then
        ok "Keychain credential present"
    else
        warn "no 'thresher' Keychain item — the poller will fail to log in until one is added"
    fi

    step "2/4  Stopping anything backend.sh is running"
    # Ownership must not be split. If backend.sh started these, launchd would
    # start SECOND copies and the two would fight over port 8765.
    "$REPO_ROOT/scripts/backend.sh" stop >/dev/null 2>&1 || true
    local ORPHANS
    ORPHANS="$(lsof -nP -iTCP:8765 -sTCP:LISTEN -t 2>/dev/null || true)"
    if [[ -n "$ORPHANS" ]]; then
        note "killing process(es) still holding 8765: $(echo "$ORPHANS" | tr '\n' ' ')"
        # shellcheck disable=SC2086
        kill $ORPHANS 2>/dev/null || true
        sleep 1
    fi
    ok "clear"

    step "3/4  Installing the agents"
    bootout "$PIPELINE_LABEL"; bootout "$API_LABEL"
    local p1 p2
    p1="$(write_plist "$PIPELINE_LABEL" "$PY" main.py)"
    p2="$(write_plist "$API_LABEL" "$PY" -m api.server)"
    launchctl bootstrap "gui/$UID" "$p1" 2>/dev/null || launchctl load -w "$p1"
    launchctl bootstrap "gui/$UID" "$p2" 2>/dev/null || launchctl load -w "$p2"
    ok "loaded $PIPELINE_LABEL"
    ok "loaded $API_LABEL"

    step "4/4  Verifying they came up"
    local i
    for i in $(seq 1 30); do
        curl -fsS "$API_URL/health" >/dev/null 2>&1 && break
        sleep 0.5
    done
    curl -fsS "$API_URL/health" >/dev/null 2>&1 \
        || fail "API did not become healthy — see $RUN_DIR/$API_LABEL.log"
    ok "API healthy at $API_URL"
    # The poller proves itself by writing a heartbeat, not by merely existing —
    # the same standard the health endpoint holds it to.
    # Capture-then-match, never `curl | grep -q`: under `set -o pipefail` grep -q
    # exits at the first match, curl dies of SIGPIPE (141), and the condition
    # reads false — so a HEALTHY poller would report as not-yet-ready here.
    # Match with a regex, not a literal: Flask emits `"status":"ok"` (no space)
    # while python -m json.tool prints `"status": "ok"`. A literal that assumes
    # either spelling reports a healthy poller as not-ready.
    health_ok() {
        local body
        body="$(curl -fsS "$API_URL/health/accounts" 2>/dev/null || true)"
        [[ "$body" =~ \"status\":[[:space:]]*\"ok\" ]]
    }
    for i in $(seq 1 40); do
        health_ok && break
        sleep 1
    done
    if health_ok; then
        ok "poller is polling (at least one account reports ok)"
    else
        warn "no account reports 'ok' yet — check: scripts/launchagent.sh logs"
    fi

    printf '\n\033[32mSupervision installed.\033[0m The backend now starts at login and restarts on crash.\n'
    printf 'launchd owns these processes — use \033[1mscripts/launchagent.sh uninstall\033[0m before\n'
    printf 'going back to manual scripts/backend.sh control.\n\n'
}

cmd_uninstall() {
    step "Removing the agents"
    bootout "$PIPELINE_LABEL"; bootout "$API_LABEL"
    rm -f "$AGENT_DIR/$PIPELINE_LABEL.plist" "$AGENT_DIR/$API_LABEL.plist"
    ok "unloaded and removed"
    printf '\nBackend is no longer supervised. Start it manually with:\n'
    printf '  scripts/backend.sh start\n\n'
}

cmd_status() {
    local label found=0
    for label in "$PIPELINE_LABEL" "$API_LABEL"; do
        if [[ "$(launchctl list 2>/dev/null || true)" == *"$label"* ]]; then
            found=1
            printf '%s: %s\n' "$label" "$(launchctl list | awk -v l="$label" '$3==l {print "pid="$1" last_exit="$2}')"
        else
            printf '%s: not loaded\n' "$label"
        fi
    done
    if [[ "$found" -eq 1 ]]; then
        printf '\nAPI health   : %s\n' "$(curl -fsS "$API_URL/health" 2>/dev/null || echo 'unreachable')"
        printf 'Account health:\n'
        curl -fsS "$API_URL/health/accounts" 2>/dev/null \
            | python3 -m json.tool 2>/dev/null | sed 's/^/  /' \
            || printf '  unreachable\n'
    fi
}

cmd_logs() {
    local f1="$RUN_DIR/$PIPELINE_LABEL.log" f2="$RUN_DIR/$API_LABEL.log"
    printf 'Tailing:\n  %s\n  %s\n(Ctrl-C to stop)\n\n' "$f1" "$f2"
    tail -f "$f1" "$f2"
}

case "${1:-}" in
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
    logs)      cmd_logs ;;
    *) echo "Usage: $0 {install|uninstall|status|logs}" >&2; exit 2 ;;
esac
