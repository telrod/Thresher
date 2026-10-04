#!/usr/bin/env bash
#
# scripts/backend.sh — start/stop/status for the thresher backend.
#
# The backend is two long-lived processes (CLAUDE.md "Running the backend"):
#   pipeline — IMAP ingestion → classification → SQLite → notifications (main.py)
#   api      — Flask REST API on http://127.0.0.1:8765 (python3 -m api.server)
#
# Usage:
#   scripts/backend.sh start [pipeline|api]   # both by default
#   scripts/backend.sh stop  [pipeline|api]
#   scripts/backend.sh restart
#   scripts/backend.sh status
#   scripts/backend.sh poll                   # single poll (main.py --once), foreground
#
# PID files and logs live in backend/.run/ (gitignored). Extra pipeline flags
# can be passed via THRESHER_PIPELINE_ARGS, e.g.:
#   THRESHER_PIPELINE_ARGS="--no-notify -v" scripts/backend.sh start pipeline

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$REPO_ROOT/backend"
RUN_DIR="$BACKEND_DIR/.run"
API_URL="http://127.0.0.1:8765"

mkdir -p "$RUN_DIR"

pid_file() { echo "$RUN_DIR/$1.pid"; }
log_file() { echo "$RUN_DIR/$1.log"; }

# Prints the recorded PID if that process is still alive, else cleans up.
alive_pid() {
    local name="$1" pidfile pid
    pidfile="$(pid_file "$name")"
    [[ -f "$pidfile" ]] || return 1
    pid="$(cat "$pidfile")"
    if kill -0 "$pid" 2>/dev/null; then
        echo "$pid"
    else
        rm -f "$pidfile"
        return 1
    fi
}

start_one() {
    local name="$1"; shift
    local pid
    if pid="$(alive_pid "$name")"; then
        echo "$name: already running (pid $pid)"
        return 0
    fi
    # cd on its own line so `&` backgrounds only the python command — with
    # `cd && nohup … &` the job is a wrapper subshell and $! is its pid, not
    # python's, which makes `stop` kill the wrapper and orphan the server.
    (
        cd "$BACKEND_DIR"
        nohup python3 "$@" >>"$(log_file "$name")" 2>&1 &
        echo $! >"$(pid_file "$name")"
    )
    sleep 1
    if pid="$(alive_pid "$name")"; then
        echo "$name: started (pid $pid, log $(log_file "$name"))"
    else
        echo "$name: FAILED to start — last log lines:" >&2
        tail -n 10 "$(log_file "$name")" >&2
        return 1
    fi
}

stop_one() {
    local name="$1" grace="${2:-10}" pid
    if ! pid="$(alive_pid "$name")"; then
        echo "$name: not running"
        return 0
    fi
    kill "$pid"
    for (( i = 0; i < grace * 4; i++ )); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
    done
    if kill -0 "$pid" 2>/dev/null; then
        # Safe for the pipeline: the IMAP cursor is in-memory, so anything
        # still queued is re-fetched on next start and deduped against the DB.
        echo "$name: did not exit after ${grace}s, sending SIGKILL" >&2
        kill -9 "$pid"
    fi
    rm -f "$(pid_file "$name")"
    echo "$name: stopped"
}

# launchd label for one of our two services, matching scripts/launchagent.sh.
# Duplicated rather than sourced: these scripts are deliberately independent
# (installing one stops the other), and a shared file would imply a coupling
# that does not exist. If the labels ever diverge, `launchagent.sh status` is
# the authority and this reports "not launchd-owned", which is the safe
# direction — it under-claims rather than inventing an owner.
launchd_label() {
    case "$1" in
        api)      echo "com.tomelrod.thresher.api" ;;
        pipeline) echo "com.tomelrod.thresher.pipeline" ;;
    esac
}

# Is this service loaded into launchd (D66)? Substring test on the whole
# listing rather than `launchctl list | grep -q`: under `set -o pipefail`,
# grep -q exits at the first match, the upstream command dies of SIGPIPE, and
# the condition reads FALSE with the match right there (E27, and the same
# idiom launchagent.sh uses).
launchd_owns() {
    local label
    label="$(launchd_label "$1")"
    [[ -n "$label" && "$(launchctl list 2>/dev/null || true)" == *"$label"* ]]
}

status_one() {
    local name="$1" pid
    if pid="$(alive_pid "$name")"; then
        echo "$name: running (pid $pid)"
    elif launchd_owns "$name"; then
        # THE POINT OF THIS BRANCH. backend.sh tracks only what IT started, via
        # its PID file, so a launchd-supervised backend showed as "stopped"
        # beside a live, healthy API — technically true and read by every human
        # as an outage, in the first diagnostic anyone reaches for.
        echo "$name: running under launchd (not started by this script — use scripts/launchagent.sh status)"
    else
        echo "$name: stopped"
    fi
}

wait_for_api() {
    for _ in {1..20}; do
        if curl -sf "$API_URL/preferences" >/dev/null 2>&1; then
            echo "api: healthy ($API_URL)"
            return 0
        fi
        sleep 0.5
    done
    echo "api: process is up but $API_URL/preferences not answering yet" >&2
    return 1
}

check_keychain() {
    # The pipeline reads the Gmail App Password from the Keychain at runtime.
    if ! security find-generic-password -s "thresher" >/dev/null 2>&1; then
        echo "WARNING: no 'thresher' Keychain item found — the pipeline will fail on IMAP login." >&2
        echo "         Store it with: security add-generic-password -s \"thresher\" -a \"<account>\" -w \"<app-password>\"" >&2
    fi
}

cmd="${1:-}"
target="${2:-all}"

case "$cmd" in
    start)
        if [[ "$target" == "pipeline" || "$target" == "all" ]]; then
            check_keychain
        fi
        if [[ "$target" == "api" || "$target" == "all" ]]; then
            start_one api -m api.server
            wait_for_api
        fi
        if [[ "$target" == "pipeline" || "$target" == "all" ]]; then
            # shellcheck disable=SC2086 — intentional word-splitting of extra flags
            start_one pipeline main.py ${THRESHER_PIPELINE_ARGS:-}
        fi
        ;;
    stop)
        if [[ "$target" == "pipeline" || "$target" == "all" ]]; then
            # SIGTERM makes the pipeline drain its classify queue and join its
            # threads (30s caps in pipeline.stop) — allow 45s before SIGKILL.
            stop_one pipeline 45
        fi
        if [[ "$target" == "api" || "$target" == "all" ]]; then
            stop_one api
        fi
        ;;
    restart)
        "$0" stop "$target"
        "$0" start "$target"
        ;;
    poll)
        # Single-shot: poll once, drain the queue, exit (main.py --once).
        # Runs in the foreground — no pid file, output goes to the terminal.
        if pid="$(alive_pid pipeline)"; then
            echo "pipeline: already running (pid $pid) — a concurrent single poll would race its producer. Stop it first: $0 stop pipeline" >&2
            exit 1
        fi
        check_keychain
        # shellcheck disable=SC2086 — intentional word-splitting of extra flags
        ( cd "$BACKEND_DIR" && exec python3 main.py --once ${THRESHER_PIPELINE_ARGS:-} )
        ;;
    status)
        status_one api
        status_one pipeline
        # Loud on unhealthy (Session-23 review nit): a running api process
        # whose endpoint doesn't answer is a failure state, not a silence.
        if curl -sf "$API_URL/preferences" >/dev/null 2>&1; then
            echo "api health: OK ($API_URL)"
            # Build provenance: WHICH code is answering. Session 27 opened with a
            # stale backend detectable only by inference — "the api is up" and "the
            # api is running the code you just wrote" are different claims.
            version_json=$(curl -sf "$API_URL/version" 2>/dev/null || true)
            if [ -n "$version_json" ]; then
                echo "api version: $version_json"
            else
                echo "api version: (endpoint not available — this backend predates /version, so it IS stale)"
            fi
            if launchd_owns api || launchd_owns pipeline; then
                echo "supervision: launchd (D66). \`scripts/backend.sh\` start/stop/restart do NOT control these;"
                echo "             use \`scripts/launchagent.sh status\` for the authoritative view."
            fi
        elif alive_pid api >/dev/null; then
            echo "api health: UNHEALTHY — process is up but $API_URL/preferences is not answering (check $(log_file api))" >&2
            exit 1
        else
            echo "api health: DOWN ($API_URL not answering)" >&2
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|poll} [pipeline|api]" >&2
        exit 2
        ;;
esac