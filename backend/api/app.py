"""
thresher REST API
Flask app over the SQLite store, consumed by the SwiftUI front end (spec §4 / §3.6).

Endpoints:
  GET    /health                          liveness
  GET    /version                         build provenance: {git_sha, started_at}
  GET    /messages                        list messages + classification (filters: tier, category, triage_state, states, account, limit, offset)
  GET    /messages/search?q=…             full-text-ish search (P1: any email reachable)
  GET    /messages/<id>                   one message + classification
  GET    /messages/<id>/explain           human-readable classification reasoning (P3)
  POST   /messages/<id>/triage            {"state": "acknowledged"} → update triage state
                                          (+ opt-in mailbox mark-as-read write-back, §3.5.3/P5)
  GET    /preferences                     all prefs (P4)
  PUT    /preferences/<key>               {"value": "…"} → set a pref
  GET    /preferences/notifications       typed notification prefs (P4, gap #5)
  PUT    /preferences/notifications       validated quiet-hours/audio write (gap #5)
  GET    /rules                           enabled rules + sender groups (P4)
                                          ?include_disabled=true → all rules (gap #4)
  GET    /accounts                        connected accounts (Keychain-backed, gap #3)
  POST   /accounts                        {"account","app_password"} → store in Keychain (gap #2)
  DELETE /accounts/<account>              disconnect (remove Keychain entry, gap #3)
  POST   /accounts/verify                 read-only IMAP login test (P5)

Design:
  - App factory (create_app) takes a connection_factory so tests inject in-memory DBs.
  - SQLite connections aren't shared across threads; we open one per request via
    Flask's `g` and close it on teardown. Run threaded=False for a single-user tool.
  - The API's only external side effect is opt-in mailbox write-back (mark-as-read
    on triage advance), gated per-account and OFF by default (P5 — spec §3.5.3,
    D16/D21). With no write-back preference set, the API touches only the local store.

Constitution refs: P1 (reachability/search), P3 (explain), P4 (prefs/rules), P5 (no side effects).
"""

import json
import logging
import re
from datetime import datetime, timedelta, timezone

from flask import Flask, g, jsonify, request

from db.database import (
    ClassificationRepo,
    MessageRepo,
    PreferencesRepo,
    RulesRepo,
    MalformedReorder,
    StaleReorderSet,
    get_connection,
    default_db_path,
    message_filter_clause,
    FRESH_DAYS,
)
from classification.engine import ClassificationResult
from classification.patterns import (
    PLACEHOLDER_PATTERN, normalize_pattern, normalize_patterns, pattern_error,
)
from notifications.service import NotificationService

log = logging.getLogger(__name__)

# ── Shared validation vocabularies ──────────────────────────────────────────
# Centralized so every endpoint validates against the same source of truth
# (mirrors schema.sql CHECK constraints + engine field/operator support).
VALID_TRIAGE_STATES = {"new", "acknowledged", "needs_action", "done"}
VALID_CATEGORIES = {"work", "personal", "unknown"}      # schema allows on messages/rules: work|personal
VALID_RULE_SET_CATEGORIES = {"work", "personal"}        # rules.set_category CHECK
VALID_TIERS = {1, 2, 3, 4, 5}
# The Host values the API answers to (D83): a loopback name, with or without a
# port. Any port, because rebinding is about the name. Matched whole, so a
# lookalike such as `localhost.example.org` is refused.
_LOOPBACK_HOST = re.compile(r"(?:127\.0\.0\.1|localhost|\[::1\])(?::\d+)?", re.IGNORECASE)

VALID_RULE_FIELDS = {"sender_email", "sender_domain", "subject", "body", "sender_group"}
VALID_RULE_OPERATORS = {"equals", "contains", "starts_with", "ends_with", "matches_group"}

# D60/B5 — the largest set one bulk action may touch. NOT a performance bound
# (one UPDATE handles far more); a bound on the cost of a filter that matched
# more than intended, for when the count-naming confirmation gets clicked
# through. Documented in docs/BEHAVIOR.md, which is the decided spec.
BULK_MAX_MESSAGES = 5000

# D61 — retrieval window vocabulary. Value is days back, or None for "everything".
#
# Resolved to an absolute cutoff at connect time (see store_account), never
# stored as a relative span.
#
# The work order proposed 2 days / 1 week / 1 month / 3 months / everything.
# **"2 days" is deliberately not offered** and this is a flagged deviation, not
# an oversight: the window CANNOT be widened later (docs/BEHAVIOR.md), so the
# narrowest option is the one most likely to be regretted permanently, and
# BEHAVIOR.md already tells the user to pick wider than they think they need.
# One week is the narrowest defensible floor. If a 2-day option is wanted, add
# it here — but decide the regret case first.
RETRIEVAL_WINDOWS = {
    "1w": 7,
    "1m": 30,
    "3m": 90,
    "everything": None,
}
RETRIEVAL_CUTOFF_KEY_PREFIX = "retrieval_cutoff:"   # + <account> → ISO-8601

# Set when an account is connected, to make the poller poll immediately instead
# of waiting out its interval. Read and CLEARED by the producer, so it is a
# one-shot request rather than standing state.
POLL_REQUESTED_KEY = "poll_requested_at"

# The groups the onboarding Ask step writes (D78). Both carry the Tier 1 rules.
ONBOARDING_GROUPS = ("leadership", "family")

# ── Notification preferences (typed surface over the preferences table) ───────
# The Settings screen binds to these specific keys (frontend gap #5). They live
# in the generic key-value `preferences` table (P4), but get a validated,
# type-coerced API so the UI doesn't push raw strings through PUT /preferences.
NOTIFICATION_PREF_KEYS = {
    "quiet_hours_start": "time",   # "HH:MM", 00:00–23:59 (or empty string = unset)
    "quiet_hours_end":   "time",
    "audio_alerts":      "bool",   # stored as "true"/"false"
}
NOTIFICATION_PREF_DEFAULTS = {
    "quiet_hours_start": None,     # null when never set
    "quiet_hours_end":   None,
    "audio_alerts":      False,
}


# ── Mailbox write-back (spec §3.5.3, D16, D21, P5) ────────────────────────────
# Opt-in PER MAILBOX, OFF by default (P5 — no side effect activated by default).
# The flag lives in the generic `preferences` table (D41 — the Keychain is the
# only account registry; no second accounts store that can drift), keyed per
# account. `GET /preferences` surfaces it as a stringly-typed value like any other.
WRITEBACK_ENABLED_KEY_PREFIX = "writeback_enabled:"   # + <account>  → "true"/"false"


def _writeback_enabled(prefs: "PreferencesRepo", account: str) -> bool:
    """True iff write-back is explicitly enabled for `account` (P5 default off).

    Only the exact string "true" (case-insensitive) enables it — an unset key, or
    any other value, is off. So a mailbox with no preference row is never written
    to (the write-back invariant)."""
    raw = prefs.get(f"{WRITEBACK_ENABLED_KEY_PREFIX}{account}")
    return (raw or "").strip().lower() == "true"


def _normalize_iso_bound(value: str) -> str:
    """Undo query-string mangling of an ISO-8601 offset.

    `+` is the URL encoding of a SPACE, so a correctly-formed bound like
    `2026-07-18T03:32:16+00:00` arrives here as `...03:32:16 00:00` unless the
    client percent-encoded it. Rejecting that would 400 a bound the user got
    *right*, so restore the `+` (a space before a HH:MM offset tail is never
    valid ISO otherwise, making this unambiguous). `Z` is folded to +00:00 for
    fromisoformat on older Pythons."""
    return re.sub(r" (\d{2}:\d{2})$", r"+\1", value.strip()).replace("Z", "+00:00")


def _valid_iso8601(value: str) -> bool:
    """True iff `value` parses as an ISO-8601 date or datetime.

    Guards the list endpoint's `since`/`until` bounds. Note the query itself
    compares with julianday(), which is *lenient* — it returns NULL for junk,
    and a NULL comparison is false, so an unvalidated typo would quietly return
    an empty list. Rejecting it here is what keeps "no results" meaning "no
    results" rather than "your filter was malformed"."""
    try:
        datetime.fromisoformat(_normalize_iso_bound(value))
        return True
    except (ValueError, AttributeError):
        return False


def parse_bound(name: str, value):
    """Validate + normalize one ISO-8601 received_at bound.

    Returns `(normalized, None)` on success or `(None, error_message)`; a
    `None` input is a `(None, None)` no-op so callers can pass an absent param
    straight through.

    **ONE parser, two endpoints** — `GET /messages` and the filter-scoped mode of
    `POST /messages/triage-bulk`. They parse the same bound strings, and a second
    parser is how E24 recurs: `+` is the URL encoding of a space, so a correctly
    formed `+00:00` offset arrives mangled, julianday() returns NULL for it, and
    the filter drops SILENTLY. On the list endpoint that failure returns too many
    rows; on the bulk endpoint it would UPDATE the wrong set. Same bug, far worse
    consequence — which is why the reuse is mandatory rather than tidy.
    """
    if value is None:
        return None, None
    if not isinstance(value, str) or not _valid_iso8601(value):
        return None, (f"invalid {name}={value!r}; expected an ISO-8601 "
                      f"datetime or date (e.g. 2026-07-14 or "
                      f"2026-07-14T00:00:00+00:00)")
    # Return the NORMALIZED bound: julianday() would return NULL for the
    # `+`-mangled spelling the validator just accepted.
    return _normalize_iso_bound(value), None


# ── preference bounds (polish batch 2, Part A) ───────────────────────────────
#
# PUT /preferences/<key> is a generic string store, which is right for most keys
# and wrong for the few that feed a loop. `poll_interval_minutes: 0` gives the
# producer a zero wait — a spin loop hammering IMAP — and a negative one is worse
# still. The Settings control enforces 1-15, but a client-only bound is no bound:
# curl, an older build, or a future screen will eventually PUT junk here.
#
# Deliberately narrow. Only keys with a known-unsafe range are validated; every
# other pref stays a free-form string, because a validator that has to be updated
# for each new key is a validator that will silently reject a valid one.
POLL_INTERVAL_MIN_MINUTES = 1
POLL_INTERVAL_MAX_MINUTES = 15


def _validate_preference(key: str, value: str) -> "str | None":
    """Return an error message if `value` is not storable for `key`, else None."""
    if key != "poll_interval_minutes":
        return None
    try:
        minutes = int(value)
    except (TypeError, ValueError):
        return (f"poll_interval_minutes must be a whole number of minutes between "
                f"{POLL_INTERVAL_MIN_MINUTES} and {POLL_INTERVAL_MAX_MINUTES}; "
                f"got {value!r}")
    if not (POLL_INTERVAL_MIN_MINUTES <= minutes <= POLL_INTERVAL_MAX_MINUTES):
        return (f"poll_interval_minutes must be between {POLL_INTERVAL_MIN_MINUTES} "
                f"and {POLL_INTERVAL_MAX_MINUTES} minutes; got {minutes}")
    return None


def create_app(connection_factory=None, imap_client_factory=None) -> Flask:
    """
    Build the Flask app. connection_factory() -> sqlite3.Connection; defaults to
    the on-disk database. Each request gets its own connection (SQLite + threads).

    imap_client_factory(account) -> a GmailImapClient-like object used for mailbox
    write-back (mark-as-read). Injected in tests so no real IMAP connection is made;
    defaults to a real GmailImapClient. Only ever constructed when write-back is
    enabled for the account (P5), so the default path opens no connection otherwise.
    """
    app = Flask(__name__)
    _factory = connection_factory or (lambda: get_connection(default_db_path()))

    def _default_imap_client(account):
        # Imported lazily so the API has no hard IMAP dependency on paths that
        # never touch write-back (and so tests that inject a factory don't import it).
        from ingestion.imap_client import GmailImapClient
        return GmailImapClient(account=account)

    _imap_factory = imap_client_factory or _default_imap_client

    def conn():
        if "db" not in g:
            g.db = _factory()
        return g.db

    @app.teardown_appcontext
    def _close(_exc):
        db = g.pop("db", None)
        if db is not None:
            db.close()

    # D83 — a web page in the user's browser must not reach this API. Binding to
    # loopback stops other machines, not other origins. Two checks close the gap:
    #   - Host must be loopback. A DNS-rebound page sends its own hostname, so
    #     this refuses it before any handler runs.
    #   - Writes must be JSON. A cross-site form or text/plain POST needs no CORS
    #     preflight, and `get_json(silent=True) or {}` would run the handler on
    #     an empty body. Requiring application/json forces the preflight, which
    #     fails because this API sends no CORS headers. DELETE is always
    #     preflighted, so it is not listed.
    @app.before_request
    def _local_only():
        if not _LOOPBACK_HOST.fullmatch(request.host):
            return jsonify(error="forbidden host"), 403
        if request.method in ("POST", "PUT", "PATCH") and not request.is_json:
            return jsonify(error="expected application/json"), 415
        return None

    # ── messages ──────────────────────────────────────────────────────────────

    @app.get("/health")
    def health():
        return jsonify(status="ok")

    @app.get("/health/accounts")
    def health_accounts():
        """
        Per-account ingestion health (Session 34).

        WHY THIS EXISTS: on 2026-08-13 the poller died on a transient IMAP
        timeout and nothing fetched mail for 13 days. The app looked completely
        healthy the entire time — this API was up, the list rendered, counts
        served — because a stopped poller and a quiet mailbox are the same
        picture from here. One account had in fact been dead for 17 hours
        before the process exited, with no indication anywhere.

        The poller stamps `poll_heartbeat:<account>` on every poll outcome;
        this reads it and reports STALENESS. That direction matters: a crashed
        poller writes nothing at all, so health must be inferred from the
        ABSENCE of a recent beat, never from the presence of an error record.
        Silence therefore reads as unhealthy, which is the fail-safe default —
        the opposite convention would have stayed green through the outage.

        Status per account:
          ok       — beat within the stale threshold, last poll succeeded
          error    — beat is recent, but the last poll failed (still retrying)
          stopped  — the producer recorded a fatal stop
          stale    — no beat within the threshold (poller dead, killed, or
                     never started); `never` if it has no beat at all
        Accounts come from the Keychain registry (D41), so a configured-but-
        never-polled mailbox appears rather than being silently omitted.
        """
        from ingestion.keychain import list_accounts, KeychainError
        from ingestion.pipeline import (
            poll_heartbeat_key, DEFAULT_POLL_INTERVAL_MINUTES)

        prefs = PreferencesRepo(conn())

        # Threshold is derived from the CONFIGURED poll interval, not a literal:
        # at a 5-minute cadence a 10-minute silence is meaningful, but if the
        # user widens the interval a fixed threshold would cry wolf every poll.
        try:
            interval_min = float(prefs.get("poll_interval_minutes",
                                           str(DEFAULT_POLL_INTERVAL_MINUTES)))
        except (TypeError, ValueError):
            interval_min = float(DEFAULT_POLL_INTERVAL_MINUTES)
        # Two missed polls plus a minute of slack — one slow poll is not news.
        stale_after = interval_min * 60 * 2 + 60

        try:
            accounts = list_accounts()
        except KeychainError as exc:
            log.warning("health/accounts: cannot read Keychain: %s", exc)
            return jsonify(error="keychain_unavailable", detail=str(exc)), 503

        now = datetime.now(timezone.utc)
        out = []
        for account in accounts:
            raw = prefs.get(poll_heartbeat_key(account))
            entry = {"account": account, "last_poll_at": None,
                     "seconds_since": None, "detail": ""}
            if not raw:
                entry.update(status="never",
                             detail="no poll recorded since this account was added")
                out.append(entry)
                continue
            parts = raw.split("|", 2)
            stamp = parts[0]
            recorded = parts[1] if len(parts) > 1 else "ok"
            entry["detail"] = parts[2] if len(parts) > 2 else ""
            # The producer publishes the interval it is ACTUALLY using as a
            # trailing field (B2). `detail` is written with "|" stripped out but
            # is the free-form field, so split it off the RIGHT, and fall back to
            # the preference for a heartbeat written by an older build.
            account_interval_min = interval_min
            if entry["detail"].count("|"):
                head, _, tail = entry["detail"].rpartition("|")
                try:
                    account_interval_min = float(tail) / 60.0
                    entry["detail"] = head
                except (TypeError, ValueError):
                    pass
            # Same rule as the global default, but against the interval THIS
            # account's producer is running on, so a changed setting cannot make
            # a healthy poller look stale (the false alarm degrades the one
            # surface that catches a process that is alive and not working).
            account_stale_after = account_interval_min * 60 * 2 + 60
            try:
                seen = datetime.fromisoformat(stamp)
                if seen.tzinfo is None:
                    seen = seen.replace(tzinfo=timezone.utc)
            except ValueError:
                entry.update(status="stale", detail=f"unparseable heartbeat {stamp!r}")
                out.append(entry)
                continue
            age = (now - seen).total_seconds()
            entry["last_poll_at"] = stamp
            entry["seconds_since"] = int(age)
            if recorded == "stopped":
                # A fatal stop stays 'stopped' regardless of age: the poller
                # told us it is not coming back, which is more specific (and
                # more actionable) than "we haven't heard from it".
                entry["status"] = "stopped"
            elif age > account_stale_after:
                entry["status"] = "stale"
                entry["detail"] = (f"no poll in {int(age // 60)} min "
                                   f"(expected every {int(account_interval_min)} min)")
            else:
                entry["status"] = "ok" if recorded == "ok" else "error"
            out.append(entry)

        healthy = all(a["status"] == "ok" for a in out) if out else True
        return jsonify(healthy=healthy, accounts=out,
                       stale_after_seconds=int(stale_after))

    # ── build provenance ────────────────────────────────────────────────────────

    @app.get("/version")
    def version():
        """Which code is this process running? (provenance workorder.)

        Session 27 opened with a stale backend AND a stale app binary, detectable only
        by inference. This makes it a fact you can ask for. Always 200: an endpoint
        whose job is to answer "what are you?" must never fail to answer.
        """
        from provenance import payload
        return jsonify(payload())

    @app.get("/messages")
    def list_messages():
        tier = request.args.get("tier", type=int)
        category = request.args.get("category")
        triage_state = request.args.get("triage_state")
        # D50: multi-state filter — `states=new,needs_action` (comma-separated).
        # The Open chip needs New+Needs action in ONE query so tier-first
        # ordering holds across the combined set. Invalid names → 400 (never a
        # silent empty view).
        states_raw = request.args.get("states")
        triage_states = None
        if states_raw is not None:
            triage_states = [s.strip() for s in states_raw.split(",") if s.strip()]
            # D50 amendment: "unclassified" (no classification row) is a valid
            # states= token — the Open view includes it (P1: a stuck classify
            # failure is visible by default). NOT valid for the triage
            # endpoint's writes; only this read filter.
            valid_states = VALID_TRIAGE_STATES | {"unclassified"}
            invalid = [s for s in triage_states if s not in valid_states]
            if invalid or not triage_states:
                return jsonify(
                    error=f"invalid states {invalid or '(empty)'}; "
                          f"must be from {sorted(valid_states)}"
                ), 400
        # Multi-account: `?account=<email>` scopes the list to one mailbox.
        # Deliberately NOT validated against the connected set — it is a filter,
        # not an assertion, so an account disconnected mid-session yields an empty
        # list instead of a 400 the UI would have to special-case.
        account = request.args.get("account")
        # Date range (filters Part 2): explicit ISO-8601 bounds, never named
        # windows. "Last 7 days" is a UI preset that resolves to `since=`; the
        # inverse — "older than 30 days" — is `until=` alone, and that is the
        # case that makes triaging a backlog possible. `since` inclusive,
        # `until` exclusive. Validated here so a typo is a 400, not a silently
        # empty list (the D50 lesson: never a silent empty view).
        since = request.args.get("since")
        until = request.args.get("until")
        bounds = {}
        for name, value in (("since", since), ("until", until)):
            parsed, err = parse_bound(name, value)
            if err:
                return jsonify(error=err), 400
            bounds[name] = parsed
        since, until = bounds.get("since"), bounds.get("until")
        limit = request.args.get("limit", default=100, type=int)
        offset = request.args.get("offset", default=0, type=int)
        filters = dict(
            tier=tier, category=category, triage_state=triage_state,
            triage_states=triage_states, account=account,
            since=since, until=until,
        )
        repo = MessageRepo(conn())
        rows = repo.list_with_classification(
            **filters, limit=min(limit, 500), offset=offset,
        )
        # OI21: the list is a WINDOW onto the store, and until now it never said
        # so — `limit` defaults to 100 and the client never paginated, so every
        # view silently claimed to be complete. (That is what manufactured the
        # phantom OI20: a Done message "missing from All" was merely on page 2.)
        # The total for THIS filter set travels in a header, so the body stays a
        # bare array and every existing client keeps working.
        response = jsonify([_message_json(r) for r in rows])
        response.headers["X-Total-Count"] = str(repo.count_matching(**filters))
        response.headers["X-Offset"] = str(offset)
        return response

    @app.get("/bulk-operations")
    def list_bulk_operations():
        """D60/B3 — recent executed bulk operations, newest first.

        Deliberately minimal and read-only: enough to answer "what did that
        operation do?" from the command line. No UI in this work order, and no
        other code path consults this data — it is a log, not state (see the
        schema comment).
        """
        limit = request.args.get("limit", default=50, type=int)
        limit = max(1, min(limit, 500))
        rows = ClassificationRepo(conn()).recent_bulk_operations(limit=limit)
        return jsonify([
            {
                "id": r["id"],
                "executed_at": r["executed_at"],
                "triage_state": r["triage_state"],
                # Parsed back to an object: the caller wants the filter, not a
                # string that happens to contain one.
                "filter": (json.loads(r["filter_json"]) if r["filter_json"] else None),
                "until": r["until_bound"],
                "account": r["account"],
                "matched": r["matched_count"],
                "updated": r["updated_count"],
                "already_in_state": r["already_count"],
            }
            for r in rows
        ])

    @app.get("/messages/counts")
    def message_counts():
        """D50 chip counts: store-wide totals per triage state (+ unclassified).
        Whole-store by design — the list paginates, so counting fetched rows
        would lie once the store outgrows a page."""
        return jsonify(MessageRepo(conn()).triage_counts())

    @app.get("/messages/search")
    def search_messages():
        q = request.args.get("q", "").strip()
        if not q:
            return jsonify(error="missing query parameter 'q'"), 400
        rows = MessageRepo(conn()).search(q, limit=200)
        return jsonify([_message_json(r) for r in rows])

    @app.get("/messages/<path:message_id>")
    def get_message(message_id):
        row = conn().execute(
            """
            SELECT m.*, c.urgency_tier, c.category, c.triage_state,
                   c.classified_at, c.rule_matches, c.reclassified_at
            FROM messages m
            LEFT JOIN classifications c ON c.message_id = m.id
            WHERE m.id = ?
            """,
            (message_id,),
        ).fetchone()
        if row is None:
            return jsonify(error="message not found"), 404
        payload = _message_json(row, include_body=True)
        # Fold the classification reasoning into the detail payload so the UI
        # satisfies P3 in a single fetch (spec §4.1.2). Guard the unclassified
        # case: a message persisted before classification (P1) LEFT-JOINs to a
        # NULL classification — return explanation: null, never a 500.
        if row["urgency_tier"] is not None:
            import json
            result = ClassificationResult(
                urgency_tier=row["urgency_tier"],
                category=row["category"],
                rule_matches=json.loads(row["rule_matches"]) if row["rule_matches"] else [],
                classified_at=row["classified_at"],
            )
            payload["explanation"] = result.explain()
            # D52 part D: the detail view shows the dated line + staleness without a
            # second fetch (same one-fetch-satisfies-P3 reasoning as `explanation`).
            from classification.reclassify import rules_changed_since
            reclassified_at = (row["reclassified_at"]
                               if "reclassified_at" in row.keys() else None)
            payload["reclassified_at"] = reclassified_at
            payload["rules_changed_since"] = rules_changed_since(
                conn(), reclassified_at or row["classified_at"])
        else:
            payload["explanation"] = None
            payload["reclassified_at"] = None
            payload["rules_changed_since"] = 0
        return jsonify(payload)

    @app.get("/messages/<path:message_id>/explain")
    def explain_message(message_id):
        """P3: human-readable reasoning for why a message was classified as it was."""
        row = ClassificationRepo(conn()).get(message_id)
        if row is None:
            return jsonify(error="classification not found"), 404
        import json
        result = ClassificationResult(
            urgency_tier=row["urgency_tier"],
            category=row["category"],
            rule_matches=json.loads(row["rule_matches"]),
            classified_at=row["classified_at"],
        )
        # D52 part D: date the classification and say how stale it is. The count is
        # "rules KNOWN to have changed since" — rules with a NULL updated_at
        # (pre-D52, never edited through the app) contribute zero, and the UI copy
        # must not overclaim beyond that.
        from classification.reclassify import rules_changed_since
        reclassified_at = (row["reclassified_at"]
                           if "reclassified_at" in row.keys() else None)
        effective = reclassified_at or row["classified_at"]
        return jsonify(
            message_id=message_id,
            urgency_tier=result.urgency_tier,
            category=result.category,
            rule_matches=result.rule_matches,
            explanation=result.explain(),
            classified_at=row["classified_at"],
            reclassified_at=reclassified_at,
            rules_changed_since=rules_changed_since(conn(), effective),
        )

    # ── reclassify on demand (D52) ──────────────────────────────────────────────
    # Classify-once-at-ingest remains the DEFAULT lifecycle (invariant 4): both of
    # these run only when the user asks. Neither fires notifications (invariant 2),
    # neither resets triage state (invariant 1), and both overwrite in place with a
    # dated audit rather than versioning (invariant 3). See classification/reclassify.

    @app.post("/messages/<path:message_id>/reclassify")
    def reclassify_message(message_id):
        """D52 part A — re-run the CURRENT engine over one stored message."""
        from classification.reclassify import reclassify_one

        c = conn()
        row = MessageRepo(c).get(message_id)
        if row is None:
            return jsonify(error="message not found"), 404

        # An unclassified message (P1 stores before classifying; the D50 amendment
        # surfaces those in Open) is exactly what this should be able to fix — so it
        # is a valid target, not a 404.
        outcome = reclassify_one(c, row)
        payload = outcome.to_dict()
        payload["rules_changed_since"] = 0   # just reclassified ⇒ nothing newer
        return jsonify(payload)

    @app.post("/messages/reclassify-all")
    def reclassify_all_messages():
        """D52 part C — re-run the engine over the whole store.

        Synchronous: the work is pure local compute over a SQLite store, and the
        measured run against the real ~1,600-message alpha DB is fast enough that a
        job system would be speculation (the number is recorded in the run summary).
        A per-message failure is counted and the pass continues (P1).
        """
        from classification.reclassify import reclassify_all

        summary = reclassify_all(conn())
        return jsonify(summary)

    @app.post("/messages/<path:message_id>/triage")
    def set_triage(message_id):
        body = request.get_json(silent=True) or {}
        state = body.get("state")
        if state not in VALID_TRIAGE_STATES:
            return jsonify(
                error=f"invalid state; must be one of {sorted(VALID_TRIAGE_STATES)}"
            ), 400
        repo = ClassificationRepo(conn())
        if repo.get(message_id) is None:
            return jsonify(error="classification not found"), 404
        repo.update_triage_state(message_id, state)

        # Mailbox write-back (spec §3.5.3, D16/D21, P5): when triage advances PAST
        # `new` and write-back is opt-in-enabled for this message's account, mark
        # the source message read. Best-effort and NON-FATAL — a write-back miss
        # must not fail the triage the user just performed (the local state
        # change is the primary action; the mailbox sync is a courtesy).
        #
        # D63 — TWO gates now, not one. The account pref is necessary but no
        # longer sufficient: the request must ALSO pass `write_back: true`,
        # exactly as both bulk modes require.
        #
        # Why this changed: the pref was set once, deliberately, at alpha open
        # (Session 25) and then governed every triage forever after. Fourteen
        # sessions later a *restore* — moving a message BACK to acknowledged
        # after a test — silently marked a real Gmail message read. Nobody asked
        # for that; the caller was undoing something. P5 says the user controls
        # side effects, and a standing pref set once is consent to a policy, not
        # to each act. Bulk already worked this way (D59); this path never got
        # revisited, so the most-used path was the least gated.
        #
        # Default False: a client that says nothing gets no mailbox side effect.
        write_back_requested = bool(body.get("write_back"))
        wrote_back = False
        if write_back_requested:
            wrote_back = _maybe_write_back(conn(), message_id, state)

        return jsonify(message_id=message_id, triage_state=state,
                       wrote_back=wrote_back,
                       write_back_skipped=(not write_back_requested))

    @app.post("/messages/triage-bulk")
    def set_triage_bulk():
        """Move many messages to one triage state in a single transaction.

        Shape follows D44's reorder lesson: a BATCH endpoint applied
        all-or-nothing, so a partial apply can never leave the store half
        triaged.

        **Two modes, exactly one per request** (400 if both, 400 if neither):

        - `message_ids: […]` — explicit ids. The client sends what the user
          actually saw. Unchanged since Session 31.
        - `filter: {…}` — **D59, filter-scoped**: "mark everything matching this
          filter Done". The id mode was capped at the page window, so clearing a
          4,000-message backlog meant Load-more → select 100 → Done, dozens of
          times over. That ceiling was never a UI limit; it was this endpoint's
          shape.

        The original id-only design called a filter query "materially more
        dangerous, because the matching set can change between the user seeing it
        and the server applying it". That hazard is real and is answered rather
        than waved away: **`until` is REQUIRED in filter mode**, captured by the
        client at preview time and replayed on execute, so the set is frozen by
        construction (see the 400 below). The `filter` keys are the same
        vocabulary as `GET /messages`, parsed through the same `parse_bound`.

        **Write-back is OFF by default here, and that is a deliberate decision
        rather than an omission (P5).** The single-message path marks the source
        message `\\Seen` on advance past `new`, and each such write-back is a
        SELECT + a server-side UID SEARCH over the whole mailbox + a STORE. A
        realistic bulk Done on the alpha store (T4 older than 30 days) covers
        4,150 messages — roughly 12,450 IMAP round-trips, each with a
        full-mailbox header search. That is not a courtesy any more; it is a
        long-running mailbox rewrite hiding inside a list action. Callers may
        opt in per request with `{"write_back": true}`, and the response always
        reports what actually happened so the behaviour is visible, not assumed.

        Like reclassify (D52), this is triage state ONLY: it never
        reclassifies and never notifies.
        """
        body = request.get_json(silent=True) or {}
        state = body.get("state")
        ids = body.get("message_ids")
        filt = body.get("filter")
        if state not in VALID_TRIAGE_STATES:
            return jsonify(
                error=f"invalid state; must be one of {sorted(VALID_TRIAGE_STATES)}"
            ), 400
        # Exactly one mode. Both is ambiguous (which set wins?) and neither is a
        # request to update nothing — in an endpoint this destructive-shaped,
        # guessing either way is worse than a 400 that names the problem.
        if ids is not None and filt is not None:
            return jsonify(
                error="send message_ids OR filter, not both"
            ), 400
        if ids is None and filt is None:
            return jsonify(
                error="send either message_ids (explicit ids) or filter "
                      "(filter-scoped bulk)"
            ), 400

        if filt is not None:
            return _triage_bulk_by_filter(state, filt, body)

        if not isinstance(ids, list) or not ids:
            return jsonify(
                error="message_ids must be a non-empty list of message ids"
            ), 400
        if not all(isinstance(i, str) for i in ids):
            return jsonify(error="message_ids must be strings"), 400
        # De-dup while preserving order: a double-click that repeats an id must
        # not inflate `updated` or double-count a write-back.
        seen_ids, unique_ids = set(), []
        for i in ids:
            if i not in seen_ids:
                seen_ids.add(i)
                unique_ids.append(i)

        c = conn()
        repo = ClassificationRepo(c)
        # Verify the whole set BEFORE writing anything — all-or-nothing means the
        # caller learns its set was stale instead of discovering a partial apply.
        missing = [i for i in unique_ids if repo.get(i) is None]
        if missing:
            return jsonify(
                error="no classification for some message_ids; nothing was changed",
                missing=missing[:20], missing_count=len(missing),
            ), 409

        # D60/B5: the cap applies to BOTH modes — an id list is just as capable
        # of being larger than intended as a filter is.
        if len(unique_ids) > BULK_MAX_MESSAGES:
            return jsonify(
                error=f"this request names {len(unique_ids)} messages, above the "
                      f"{BULK_MAX_MESSAGES} limit for one bulk action; split it",
                matching=len(unique_ids), limit=BULK_MAX_MESSAGES,
            ), 400

        # Counted BEFORE the update, or "already in this state" would be every
        # row (the update makes it true).
        already = sum(1 for i in unique_ids
                      if (repo.get(i) or {})["triage_state"] == state)

        try:
            # D60: `filter_json` is NULL for the id mode — there was no filter,
            # and recording a synthesised one would make the log claim the
            # operation was something it wasn't.
            repo.update_triage_state_bulk(
                unique_ids, state,
                audit={"matched": len(unique_ids), "already": already},
            )
        except Exception:
            log.exception("bulk triage failed; transaction rolled back")
            return jsonify(error="bulk triage failed; nothing was changed"), 500

        wrote_back = 0
        write_back_requested = bool(body.get("write_back"))
        if write_back_requested:
            for i in unique_ids:
                if _maybe_write_back(conn(), i, state):
                    wrote_back += 1

        return jsonify(
            updated=len(unique_ids), triage_state=state,
            wrote_back=wrote_back,
            write_back_skipped=(not write_back_requested),
        )

    def _triage_bulk_by_filter(state, filt, body):
        """D59 filter-scoped bulk. Returns a Flask response.

        Split out of `set_triage_bulk` for readability only — it is the same
        endpoint and the same contract.
        """
        if not isinstance(filt, dict):
            return jsonify(error="filter must be an object"), 400

        known = {"tier", "category", "state", "states", "account", "since", "until"}
        unknown = sorted(set(filt) - known)
        if unknown:
            # Never ignore a key we don't understand: a typo'd filter key that
            # is silently dropped WIDENS the set being updated. Failing loudly
            # is the only safe reading.
            return jsonify(
                error=f"unknown filter keys {unknown}; allowed: {sorted(known)}"
            ), 400

        # ── `until` is REQUIRED — this is the race guard, not a formality ──
        # A poll can land between the user reading "this will mark 3,204
        # messages Done" and the execute. With no upper bound, mail that
        # arrived in that window is marked Done HAVING NEVER BEEN SEEN — not a
        # P1 violation (nothing is deleted) but a close cousin, and silent.
        # The client captures `until = now` at preview and replays THAT value
        # here, so anything ingested since has received_at > until and is
        # excluded. Deliberately NOT defaulted server-side: a server-side `now`
        # is evaluated at execute time and defeats the entire guard.
        if filt.get("until") is None:
            return jsonify(
                error="filter.until is required for a filter-scoped bulk: it "
                      "freezes the matching set. Capture `until` when the user "
                      "is shown the count and send that same value here, so "
                      "mail that arrives in between is not triaged unseen."
            ), 400

        bounds = {}
        for name in ("since", "until"):
            parsed, err = parse_bound(name, filt.get(name))
            if err:
                return jsonify(error=err), 400
            bounds[name] = parsed

        tier = filt.get("tier")
        if tier is not None and not isinstance(tier, int):
            return jsonify(error="filter.tier must be an integer"), 400

        # Same multi-state vocabulary as GET /messages (D50), including the
        # "unclassified" token — the Open chip is new+needs_action+unclassified,
        # and a bulk scoped to what the chip shows must be able to say so.
        states_raw = filt.get("states")
        triage_states = None
        if states_raw is not None:
            if isinstance(states_raw, str):
                triage_states = [s.strip() for s in states_raw.split(",") if s.strip()]
            elif isinstance(states_raw, list):
                triage_states = [str(s).strip() for s in states_raw if str(s).strip()]
            else:
                return jsonify(error="filter.states must be a list or a "
                                     "comma-separated string"), 400
            valid_states = VALID_TRIAGE_STATES | {"unclassified"}
            invalid = [s for s in triage_states if s not in valid_states]
            if invalid or not triage_states:
                return jsonify(
                    error=f"invalid states {invalid or '(empty)'}; "
                          f"must be from {sorted(valid_states)}"
                ), 400

        single_state = filt.get("state")
        if single_state is not None and single_state not in VALID_TRIAGE_STATES:
            return jsonify(
                error=f"invalid filter.state; must be one of "
                      f"{sorted(VALID_TRIAGE_STATES)}"
            ), 400

        filters = dict(
            tier=tier, category=filt.get("category"), triage_state=single_state,
            triage_states=triage_states, account=filt.get("account"),
            since=bounds["since"], until=bounds["until"],
        )

        repo = ClassificationRepo(conn())
        matching, already = repo.count_matching_for_triage(state, **filters)

        # D60/B5 — bound the cost of a mistake, not of the query. One SQL
        # statement handles far more than this; the cap exists because a filter
        # can match far more than intended, and the confirmation that names the
        # count can be clicked through. `matching` comes from
        # count_matching_for_triage, which resolves the SAME set through the
        # shared predicate that the UPDATE will use — so the cap guards the set
        # it counts rather than a near-miss of it.
        if matching > BULK_MAX_MESSAGES:
            return jsonify(
                error=f"this filter matches {matching} messages, above the "
                      f"{BULK_MAX_MESSAGES} limit for one bulk action; narrow "
                      f"the filter and repeat",
                matching=matching, limit=BULK_MAX_MESSAGES,
            ), 400

        write_back_requested = bool(body.get("write_back"))
        # Resolve the affected ids BEFORE the update only when write-back was
        # asked for — it needs per-message Message-IDs. The default path never
        # materialises the set (the Session 29 fetchall() lesson: a bulk
        # operation is exactly where loading the whole store looks harmless).
        pending_write_back = []
        if write_back_requested and state != "new":
            where, params = message_filter_clause(**filters)
            pending_write_back = [
                r[0] for r in conn().execute(
                    "SELECT m.id FROM messages m "
                    "LEFT JOIN classifications c ON c.message_id = m.id "
                    f"{where}", params
                ).fetchall()
            ]

        try:
            # D60: the audit row travels WITH the update so both land in one
            # transaction. The filter is stored as JSON, not a rendered string —
            # a sentence describing a filter cannot be re-executed or compared,
            # and this record's whole value is that it holds what the operation
            # actually selected on.
            updated = repo.update_triage_state_by_filter(
                state,
                audit={
                    "matched": matching,
                    "already": already,
                    "filter_json": json.dumps(filt, sort_keys=True),
                    "until_bound": bounds["until"],
                    "account": filt.get("account"),
                },
                **filters,
            )
        except Exception:
            log.exception("filter-scoped bulk triage failed; rolled back")
            return jsonify(error="bulk triage failed; nothing was changed"), 500

        wrote_back = 0
        for mid in pending_write_back:
            if _maybe_write_back(conn(), mid, state):
                wrote_back += 1

        # `updated` is the ACTUAL affected row count. The client compares it to
        # the count it previewed and surfaces any divergence rather than
        # swallowing it: with `until` frozen this should be ~0, and a nonzero
        # value means concurrent triage, which is worth seeing.
        return jsonify(
            updated=updated, triage_state=state,
            matching=matching, already_in_state=already,
            wrote_back=wrote_back,
            write_back_skipped=(not write_back_requested),
        )

    def _log_writeback(db, account, message_id, rfc_id, state, ok, detail) -> None:
        """Record one write-back ATTEMPT (D63). Never raises.

        Logging must not be able to break the thing it observes: write-back is
        already best-effort and non-fatal, so a failure to record it cannot be
        allowed to fail the user's triage. A swallowed logging error is the
        lesser evil — and it is logged.

        Committed immediately rather than joining a caller's transaction: unlike
        the bulk log, this records an effect that has ALREADY happened outside
        the database, on a remote server. Rolling the record back would not
        un-mark the message; it would only hide that it was marked.
        """
        try:
            db.execute(
                "INSERT INTO writeback_log (attempted_at, account, message_id, "
                "rfc822_id, action, triage_state, ok, detail) VALUES (?,?,?,?,?,?,?,?)",
                (datetime.now(timezone.utc).isoformat(), account, message_id,
                 rfc_id, "mark_read", state, 1 if ok else 0, detail),
            )
            db.commit()
        except Exception:
            log.exception("write-back audit row failed for %s (the write-back "
                          "itself is unaffected)", message_id)

    @app.get("/writeback-log")
    def list_writeback_log():
        """D63 — recent mailbox write-back attempts, newest first.

        Read-only, and the answer to a question that previously had none: which
        real messages has this app modified on the server? `?message_id=` bounds
        it to one message ("was THIS ever written back?"), which is the shape
        needed to scope a blast radius.
        """
        limit = max(1, min(request.args.get("limit", default=50, type=int), 500))
        mid = request.args.get("message_id")
        c = conn()
        if mid:
            rows = c.execute(
                "SELECT * FROM writeback_log WHERE message_id = ? "
                "ORDER BY id DESC LIMIT ?", (mid, limit)).fetchall()
        else:
            rows = c.execute(
                "SELECT * FROM writeback_log ORDER BY id DESC LIMIT ?",
                (limit,)).fetchall()
        return jsonify([
            {"id": r["id"], "attempted_at": r["attempted_at"],
             "account": r["account"], "message_id": r["message_id"],
             "rfc822_id": r["rfc822_id"], "action": r["action"],
             "triage_state": r["triage_state"], "ok": bool(r["ok"]),
             "detail": r["detail"]}
            for r in rows
        ])

    def _maybe_write_back(db, message_id, state) -> bool:
        """Mark the source message read if triage advanced past `new` and the
        account has write-back enabled. Returns True iff the \\Seen flag was set.
        Swallows all write-back errors (logs them) so triage never fails on a
        mailbox hiccup."""
        if state == "new":
            return False   # only advancing PAST new syncs read state
        row = db.execute(
            "SELECT account, raw_headers FROM messages WHERE id = ?", (message_id,)
        ).fetchone()
        if row is None:
            return False
        account = row["account"]
        if not _writeback_enabled(PreferencesRepo(db), account):
            return False   # P5: opt-in per mailbox, off by default — untouched.

        # Target by the immutable RFC822 Message-ID (not the id's bare uid — see
        # GmailImapClient write-back note; UIDVALIDITY isn't persisted).
        import json
        headers = json.loads(row["raw_headers"]) if row["raw_headers"] else {}
        rfc_id = (headers.get("Message-ID") or headers.get("Message-Id")
                  or headers.get("message-id"))
        if not rfc_id:
            log.warning("write-back: %s has no RFC822 Message-ID header; skipping", message_id)
            _log_writeback(db, account, message_id, None, state, False,
                           "no RFC822 Message-ID header")
            return False

        try:
            client = _imap_factory(account)
            with client:
                ok = client.mark_read(rfc_id)
            # D63: recorded here, at the ONE point where the mailbox is actually
            # touched — every path (single, bulk-id, bulk-filter) funnels through
            # this function, so logging here cannot be bypassed by a new caller.
            _log_writeback(db, account, message_id, rfc_id, state, ok,
                           None if ok else "no single exact Message-ID match")
            return ok
        except Exception as exc:
            _log_writeback(db, account, message_id, rfc_id, state, False, str(exc)[:200])
            log.exception("write-back: mark-read failed for %s (account %s); "
                          "triage stands, mailbox unchanged", message_id, account)
            return False

    # ── notifications feed (D45 — native delivery hand-off) ──────────────────────

    @app.get("/notifications")
    def list_notifications():
        """Notifications the native app should DELIVER, newer than `since` (D45).

        The backend records every alert decision in notification_log. When the app
        owns delivery (it set the delivery-owner heartbeat), the backend logs the
        row but skips its own osascript banner and tags it `delivery: "app"` — this
        endpoint returns exactly those rows so the app delivers them natively. Rows
        the backend already delivered via osascript (`delivery: "osascript"`) are
        NOT returned: returning them would double-fire the banner the user saw.

        `?since=<id>` is the highest log id the app has already processed; only rows
        with a greater id come back (ascending), so the app advances a monotonic
        cursor and each notification fires exactly once. Default since=0 (all).
        """
        import json
        since = request.args.get("since", default=0, type=int)
        rows = conn().execute(
            """
            SELECT id, message_id, notification_type, sent_at, payload
            FROM notification_log
            WHERE id > ?
            ORDER BY id ASC
            """,
            (since,),
        ).fetchall()
        out = []
        cursor = since
        for r in rows:
            cursor = r["id"]   # advance past EVERY scanned row (incl. osascript /
                               # quiet-hours rows) so they're never re-scanned.
            payload = json.loads(r["payload"]) if r["payload"] else {}
            # Only app-owned rows are the app's to deliver. osascript rows and
            # quiet-hours defers (no delivery tag) are excluded from the feed.
            if payload.get("delivery") != "app":
                continue
            out.append({
                "id": r["id"],
                "message_id": r["message_id"],
                "notification_type": r["notification_type"],
                "sent_at": r["sent_at"],
                "title": payload.get("title"),
                "text": payload.get("text"),
            })
        # `cursor` = highest log id considered; the app stores it and passes it as
        # `since` next poll, so it advances past non-app rows too and each app row
        # is delivered exactly once.
        return jsonify(notifications=out, cursor=cursor)

    # ── preferences (P4) ────────────────────────────────────────────────────────

    @app.get("/preferences")
    def get_preferences():
        prefs = PreferencesRepo(conn()).all()
        # D57's recency-band edge, exposed so the UI's "older than 2 weeks"
        # preset resolves from the SAME constant the ordering uses instead of
        # hardcoding a second 14 (§B4). Derived, not stored: it is read-only
        # here, and a PUT to this key writes an ordinary preference row that
        # this line then shadows — flagged in the run summary rather than
        # silently half-supported. OI29 wants both promoted to a real
        # preference; when that happens, this key becomes the stored one and
        # the constant reads from it, and the UI needs no change.
        prefs["fresh_days"] = str(FRESH_DAYS)
        return jsonify(prefs)

    @app.put("/preferences/<key>")
    def set_preference(key):
        body = request.get_json(silent=True) or {}
        if "value" not in body:
            return jsonify(error="body must include 'value'"), 400
        value = str(body["value"])
        error = _validate_preference(key, value)
        if error is not None:
            # Reject BEFORE the write, so a bad value leaves the previous one
            # intact (E12: validate what would be stored, not the submitted half).
            return jsonify(error=error), 400
        PreferencesRepo(conn()).set(key, value)
        return jsonify(key=key, value=value)

    # ── digest (spec §3.3) ──────────────────────────────────────────────────

    @app.get("/digest/preview")
    def digest_preview():
        """Show what the Tier 3 digest would contain right now — no side effect."""
        rows = NotificationService(conn())._recent_tier3()
        return jsonify(
            count=len(rows),
            messages=[
                {
                    "id": r["id"],
                    "sender_name": r["sender_name"],
                    "sender_email": r["sender_email"],
                    "subject": r["subject"],
                    "received_at": r["received_at"],
                    "category": r["category"],
                }
                for r in rows
            ],
        )

    @app.post("/digest/run")
    def digest_run():
        """
        Send the Tier 3 digest now (user-initiated, e.g. a 'digest me now' button).
        This is the one endpoint that triggers a notification side effect; it is
        explicit per request (P5). `force=true` bypasses the once-per-day guard.
        """
        force = bool((request.get_json(silent=True) or {}).get("force", False))
        result = NotificationService(conn()).build_and_send_digest(force=force)
        return jsonify(
            sent=result.sent, reason=result.reason,
            message_count=result.message_count, message_ids=result.message_ids,
        )

    # ── rules (P4) ────────────────────────────────────────────────────────────

    @app.get("/rules")
    def get_rules():
        """
        Enabled rules + sender groups (P4). By default returns ONLY enabled rules
        (what the engine evaluates). Pass `?include_disabled=true` for the Settings
        rules editor, which must see disabled rows to re-enable them (frontend
        gap #4). Each rule's `enabled` field is the 0/1 int from the column.
        """
        repo = RulesRepo(conn())
        include_disabled = request.args.get("include_disabled", "").lower() in ("1", "true", "yes")
        rules = repo.all_rules() if include_disabled else repo.all_enabled()
        return jsonify(
            rules=[dict(r) for r in rules],
            sender_groups=[dict(g) for g in repo.all_sender_groups()],
        )

    @app.post("/rules")
    def create_rule():
        body = request.get_json(silent=True) or {}
        err = _validate_rule(body, require_all=True)
        if err:
            return jsonify(error=err), 400
        row = RulesRepo(conn()).create_rule(body)
        return jsonify(dict(row)), 201

    @app.put("/rules/reorder")
    def reorder_rules():
        """Batch reorder (D44). Body: {"ordered_ids": [7, 14, 3, …]} — position is
        priority. The server renumbers everything dense (1..N) in one transaction.

        200 → the full reordered rules list (same shape as GET /rules?include_disabled=true),
              so the client re-renders from the response without a second fetch.
        400 → malformed: missing/duplicate/non-integer ids.
        409 → stale set: shape valid but membership doesn't match the live table;
              the error body names which ids were unexpected/missing (P3).

        The <int:rule_id> converter on update_rule won't match "reorder", so this
        route is unambiguous regardless of declaration order (test asserts this).
        """
        body = request.get_json(silent=True) or {}
        ordered_ids = body.get("ordered_ids")
        repo = RulesRepo(conn())
        try:
            rules = repo.reorder(ordered_ids)
        except MalformedReorder as e:
            return jsonify(error=str(e), **e.mismatch), 400
        except StaleReorderSet as e:
            return jsonify(error=str(e), **e.mismatch), 409
        return jsonify(rules=[dict(r) for r in rules])

    @app.put("/rules/<int:rule_id>")
    def update_rule(rule_id):
        body = request.get_json(silent=True) or {}
        err = _validate_rule(body, require_all=False)
        if err:
            return jsonify(error=err), 400
        repo = RulesRepo(conn())
        existing = repo.get_rule(rule_id)
        if existing is None:
            return jsonify(error="rule not found"), 404
        # both-null guard, post-merge: a rule that can match must still set a
        # tier or a category (P3 — a no-effect rule pollutes /explain). Compute the
        # MERGED result (patch over the existing row), not just what the request
        # body carries — so clearing the only remaining effect is caught even when
        # the other field was already null in the DB. "Omit both" leaves the
        # existing effect intact and passes.
        merged_tier = body["set_tier"] if "set_tier" in body else existing["set_tier"]
        merged_category = body["set_category"] if "set_category" in body else existing["set_category"]
        if merged_tier is None and merged_category is None:
            return jsonify(
                error="update would leave the rule with neither set_tier nor "
                      "set_category; a rule that can match must set at least one"
            ), 400
        # E22, post-merge (same D38 pattern): a PUT patching only `field` (or
        # only `operator`) can combine with the stored half into a pair the
        # engine will never match — two valid halves, one invalid whole (E12).
        merged_field = body["field"] if "field" in body else existing["field"]
        merged_operator = body["operator"] if "operator" in body else existing["operator"]
        err = _validate_field_operator_pair(merged_field, merged_operator)
        if err:
            return jsonify(error=err), 400
        return jsonify(dict(repo.update_rule(rule_id, body)))

    @app.delete("/rules/<int:rule_id>")
    def delete_rule(rule_id):
        if not RulesRepo(conn()).delete_rule(rule_id):
            return jsonify(error="rule not found"), 404
        return jsonify(deleted=rule_id)

    # ── sender groups (P4 + sender-override invariant) ──────────────────────────

    @app.post("/sender-groups")
    def create_sender_group():
        body = request.get_json(silent=True) or {}
        err = _validate_sender_group(body, require_all=True)
        if err:
            return jsonify(error=err), 400
        row = RulesRepo(conn()).create_sender_group(body)
        return jsonify(dict(row)), 201

    @app.put("/sender-groups/<int:group_id>")
    def update_sender_group(group_id):
        body = request.get_json(silent=True) or {}
        err = _validate_sender_group(body, require_all=False)
        if err:
            return jsonify(error=err), 400
        row = RulesRepo(conn()).update_sender_group(group_id, body)
        if row is None:
            return jsonify(error="sender group not found"), 404
        return jsonify(dict(row))

    @app.delete("/sender-groups/<int:group_id>")
    def delete_sender_group(group_id):
        if not RulesRepo(conn()).delete_sender_group(group_id):
            return jsonify(error="sender group not found"), 404
        return jsonify(deleted=group_id)

    # ── onboarding: the people whose mail matters most (D78, D79) ───────────────

    @app.post("/onboarding/people")
    def onboarding_people():
        """Set the Tier 1 groups from the onboarding Ask step, in one call.

        Body: `{"leadership": [...], "family": [...]}`. For each group whose list is
        non-empty after normalization, the group's pattern set is REPLACED with the
        submitted one (Ask prefills current members, so replace is what the user
        sees), with the seeded placeholder dropped. A group whose list is empty or
        absent is left unchanged — an empty pattern set is invalid (DG3), so this
        step cannot remove everyone; Settings can.

        All-or-nothing: if any entry fails validation, nothing is written and every
        rejected entry is named. Both groups are written in one transaction. If any
        messages are already stored they are reclassified, because mail is
        classified once at ingest and would otherwise keep its old tier (D79).

        `status` says what happened: "unchanged" (empty request), "saved" (200),
        or, with 207 because the groups ARE saved, "saved_not_retiered" (reclassify
        raised) or "saved_partially_retiered" (some messages failed to re-tier).
        """
        body = request.get_json(silent=True)
        if body is None:
            body = {}
        if not isinstance(body, dict):
            return jsonify(error="body must be a JSON object"), 400
        unknown = sorted(set(body) - set(ONBOARDING_GROUPS))
        if unknown:
            return jsonify(error=f"unknown fields: {unknown}; expected "
                                 f"{list(ONBOARDING_GROUPS)}"), 400

        submitted: dict = {}
        invalid: list = []
        for name in ONBOARDING_GROUPS:
            raw = body.get(name)
            if raw is None:
                continue
            if not isinstance(raw, list) or any(not isinstance(x, str) for x in raw):
                return jsonify(error=f"{name} must be a list of strings"), 400
            patterns, errors = normalize_patterns(raw)
            invalid.extend({"group": name, **e} for e in errors)
            patterns = [p for p in patterns if p.lower() != PLACEHOLDER_PATTERN]
            if patterns:
                submitted[name] = patterns
        if invalid:
            return jsonify(error=invalid[0]["error"], invalid=invalid), 400
        if not submitted:
            return jsonify(written=False, status="unchanged", groups={},
                           reclassified=None)

        c = conn()
        repo = RulesRepo(c)
        by_name = {g["group_name"]: g for g in repo.all_sender_groups()}
        missing = sorted(n for n in submitted if n not in by_name)
        if missing:
            return jsonify(error=f"sender group not found: {missing}"), 409
        repo.replace_sender_group_patterns(
            {by_name[n]["id"]: pats for n, pats in submitted.items()})

        groups = {n: repo.get_sender_group(by_name[n]["id"])["patterns"]
                  for n in submitted}

        # The groups are COMMITTED at this point. A reclassify failure must not
        # surface as a bare 500, which a client reads as "nothing was saved": it
        # returns 207 with `status` naming what happened, so the UI can say the
        # people were saved and point to "Reclassify all" in Settings.
        if not c.execute("SELECT EXISTS (SELECT 1 FROM messages)").fetchone()[0]:
            return jsonify(written=True, status="saved", groups=groups,
                           reclassified=None)
        from classification.reclassify import reclassify_all
        try:
            reclassified = reclassify_all(c)
        except Exception as exc:                 # noqa: BLE001 — reported, not fatal
            log.exception("onboarding: groups saved, reclassify failed")
            return jsonify(
                written=True, status="saved_not_retiered", groups=groups,
                reclassified=None,
                error=("Saved, but stored mail was not re-tiered "
                       f"({type(exc).__name__}). Run Reclassify all in Settings."),
            ), 207
        if reclassified.get("errors"):
            return jsonify(
                written=True, status="saved_partially_retiered", groups=groups,
                reclassified=reclassified,
                error=(f"Saved, but {reclassified['errors']} stored message(s) were "
                       "not re-tiered. Run Reclassify all in Settings."),
            ), 207
        return jsonify(written=True, status="saved", groups=groups,
                       reclassified=reclassified)

    # ── threads (spec §4.1.2 "view full conversation") ──────────────────────────

    @app.get("/threads/<path:thread_id>")
    def get_thread(thread_id):
        """All messages in a conversation, ordered oldest→newest (same list shape)."""
        rows = MessageRepo(conn()).list_with_classification(
            thread_id=thread_id, limit=500,
        )
        return jsonify([_message_json(r) for r in rows])

    # ── accounts (onboarding connectivity check, P5: read-only) ─────────────────

    @app.post("/accounts/verify")
    def verify_account():
        """
        Test IMAP login for an account using the Keychain App Password (closes E7).
        Read-only: logs in and straight back out, no poll, no mailbox writes (P5).
        Returns {ok, reason} where reason ∈ {ok, missing_credential, auth_failed,
        network_error}.
        """
        body = request.get_json(silent=True) or {}
        account = (body.get("account") or "").strip()
        if not account:
            return jsonify(error="body must include 'account'"), 400
        from ingestion.imap_client import GmailImapClient
        ok, reason = GmailImapClient(account).verify_login()
        return jsonify(ok=ok, reason=reason)

    @app.get("/accounts")
    def list_accounts_route():
        """
        List connected accounts (frontend gap #3, Settings §4.1.3).

        The Keychain is the source of truth (D41): an account is "connected" iff
        it has a stored App Password under the thresher service. Read-only;
        no secret values are returned. Returns {accounts: [<email>, …]}.
        """
        from ingestion.keychain import list_accounts, KeychainError
        try:
            accounts = list_accounts()
        except KeychainError as exc:
            log.warning("list_accounts failed: %s", exc)
            return jsonify(error=str(exc)), 503
        return jsonify(accounts=accounts)

    @app.post("/accounts")
    def store_account():
        """
        Store an account's App Password in the Keychain (frontend gap #2,
        onboarding §4.1.4 "connect a Gmail account").

        D40: store and verify are SEPARATE calls. This endpoint's side effect is
        the Keychain write and nothing else (P5) — no IMAP connection, no mailbox
        access, no DB write. The client is expected to call /accounts/verify first
        and only POST here on success, but verification is not coupled in here.

        Body: {"account": <email>, "app_password": <secret>}.
        The password is NEVER logged or echoed back in the response.
        """
        body = request.get_json(silent=True) or {}
        account = (body.get("account") or "").strip()
        password = body.get("app_password") or ""
        if not account:
            return jsonify(error="body must include 'account'"), 400
        if not password:
            return jsonify(error="body must include a non-empty 'app_password'"), 400
        # D61 — the retrieval window, resolved to a DATE here at connect time.
        #
        # Stored as an absolute cutoff, never as "N days": a relative value would
        # be re-evaluated on every poll, so the boundary would slide forward and
        # mail could fall out of range while sitting in the queue. Resolving once,
        # here, is what makes the window a fixed line rather than a moving one.
        #
        # Absent ⇒ no cutoff row ⇒ retrieve everything. That is the historic
        # behaviour and the safe default: an account connected before this
        # existed must not suddenly start skipping mail.
        window = body.get("retrieval_window")
        cutoff = None
        if window is not None:
            if window not in RETRIEVAL_WINDOWS:
                return jsonify(
                    error=f"invalid retrieval_window {window!r}; must be one of "
                          f"{sorted(RETRIEVAL_WINDOWS)}"
                ), 400
            days = RETRIEVAL_WINDOWS[window]
            if days is not None:
                cutoff = (datetime.now(timezone.utc)
                          - timedelta(days=days)).isoformat()

        from ingestion.keychain import store_secret, KeychainError
        try:
            store_secret(account, password)
        except KeychainError as exc:
            log.warning("store_secret failed for %s: %s", account, exc)  # no secret in msg
            return jsonify(error=str(exc)), 502

        # Written AFTER the credential lands: a cutoff for an account that failed
        # to connect would silently narrow a later successful attempt.
        if cutoff is not None:
            PreferencesRepo(conn()).set(f"{RETRIEVAL_CUTOFF_KEY_PREFIX}{account}",
                                        cutoff)
        # Ask the poller to poll NOW rather than at its next scheduled wake.
        #
        # THE STORE IS THE CHANNEL. The API and the poller are separate
        # processes with no IPC, deliberately — the supervisor design keeps them
        # independent. So this writes a durable row and the producer reads it on
        # its loop, the same idiom as the D45 delivery claim and the D65 poll
        # heartbeat.
        #
        # A ROW, NOT AN EVENT, and that is what makes the first-run case work:
        # at this moment the poller is very likely NOT running (it exits with
        # EXIT_NOT_CONFIGURED while no account is connected, and the supervisor
        # relaunches it on a 30s tick). A signal sent to a process that does not
        # exist would be lost; a row is still there when it next starts.
        PreferencesRepo(conn()).set(POLL_REQUESTED_KEY,
                                    datetime.now(timezone.utc).isoformat())

        # Echo only the account + a stored flag — never the password.
        return jsonify(account=account, stored=True,
                       retrieval_cutoff=cutoff), 201

    @app.post("/accounts/preview")
    def preview_account_windows():
        """
        How much mail would each retrieval window bring in? (backfill-scope §6.4)

        Answered BEFORE the credential is stored, so the number can inform the
        choice rather than explain it afterwards — "about 3,311 messages" is the
        sentence that changes a decision, where "a large mailbox" does not.

        Takes the App Password in the body because there is nothing in the
        Keychain yet, and deliberately **stores nothing** (P5): no credential, no
        `retrieval_cutoff` row. A preview is a question, and a question must not
        leave state behind for an account the user may decide not to connect.
        The password is never logged and never echoed.

        Read-only against the mailbox (SELECT readonly + UID SEARCH, no FETCH,
        no STORE), the same discipline as `/accounts/verify`.

        502 on an IMAP failure rather than zeroes: a count of 0 from a bad
        credential would read as "your mailbox is empty" at exactly the moment
        the user is deciding how much to import.
        """
        body = request.get_json(silent=True) or {}
        account = (body.get("account") or "").strip()
        password = body.get("app_password") or ""
        if not account:
            return jsonify(error="body must include 'account'"), 400
        if not password:
            return jsonify(error="body must include a non-empty 'app_password'"), 400

        client = _imap_factory(account)
        now = datetime.now(timezone.utc)
        counts = {}
        try:
            for name, days in RETRIEVAL_WINDOWS.items():
                # `everything` (days=None) counts the whole mailbox; the rest
                # resolve to the same absolute cutoff POST /accounts would store,
                # so the number previewed is the number that window retrieves.
                since = None
                if days is not None:
                    since = (now - timedelta(days=days)).strftime("%d-%b-%Y")
                counts[name] = client.count_since(since, password=password)
        except Exception as exc:                # noqa: BLE001 — never leak the secret
            log.warning("account preview failed for %s: %s", account, exc)
            return jsonify(error=f"Could not read the mailbox: {exc}"), 502

        return jsonify(account=account, counts=counts)

    @app.delete("/accounts/<path:account>")
    def disconnect_account(account):
        """
        Disconnect an account (frontend gap #3): remove its Keychain credential.

        Side-effect scope is the Keychain only (P5) — removes a credential, does
        not touch the mailbox or the message store (P1: stored messages remain
        retrievable). 404 if no credential existed for the account.
        """
        account = (account or "").strip()
        if not account:
            return jsonify(error="account must be non-empty"), 400
        from ingestion.keychain import delete_secret, KeychainError
        try:
            deleted = delete_secret(account)
        except KeychainError as exc:
            log.warning("delete_secret failed for %s: %s", account, exc)
            return jsonify(error=str(exc)), 502
        if not deleted:
            return jsonify(error="account not found"), 404
        return jsonify(disconnected=account)

    # ── notification preferences (typed surface, P4) ────────────────────────────

    @app.get("/preferences/notifications")
    def get_notification_preferences():
        """
        Typed read of the notification preferences the Settings screen binds to
        (frontend gap #5). A typed view over specific keys in the generic
        `preferences` table — the raw `GET /preferences` map still exists.

        Returns coerced types (bools/ints), not the raw strings, so the UI
        doesn't have to know each key's storage encoding.
        """
        repo = PreferencesRepo(conn())
        return jsonify(_read_notification_prefs(repo))

    @app.put("/preferences/notifications")
    def set_notification_preferences():
        """
        Validated write of notification preferences (frontend gap #5): bounds-
        checked quiet-hours times (HH:MM, 00:00–23:59) and a boolean audio toggle.
        Patch semantics — only the provided keys are written. Rejects malformed
        values with 400 rather than silently storing junk via PUT /preferences/<key>.
        """
        body = request.get_json(silent=True) or {}
        err, to_write = _validate_notification_prefs(body)
        if err:
            return jsonify(error=err), 400
        repo = PreferencesRepo(conn())
        for key, value in to_write.items():
            repo.set(key, value)
        return jsonify(_read_notification_prefs(repo))

    return app


# ── input validation ────────────────────────────────────────────────────────

def _valid_operators_for_field(field: str) -> set:
    """E22: the field/operator pairing contract. `matches_group` is meaningful
    ONLY against `sender_group`, and `sender_group` matches NOTHING else — the
    engine's _evaluate_rule falls through to matching "" for any other combo,
    a rule that renders as live and silently never fires."""
    if field == "sender_group":
        return {"matches_group"}
    return VALID_RULE_OPERATORS - {"matches_group"}


def _validate_field_operator_pair(field, operator) -> "str | None":
    """Return an error naming the invalid pair and the valid operators for the
    field, or None. Only called with both halves known (create, or post-merge
    on update — the E12 lesson: two individually-valid halves can merge into
    an invalid whole)."""
    if field is None or operator is None:
        return None
    if field not in VALID_RULE_FIELDS or operator not in VALID_RULE_OPERATORS:
        return None   # the vocabulary checks own these
    valid = _valid_operators_for_field(field)
    if operator not in valid:
        return (f"operator {operator!r} is invalid for field {field!r} — such a "
                f"rule would never match; valid operators for {field!r}: "
                f"{sorted(valid)}")
    return None


def _validate_rule(body: dict, *, require_all: bool) -> "str | None":
    """Return an error string if the rule body is invalid, else None.

    require_all=True for create (mandatory fields must be present); False for
    update (validate only the fields that are present).
    """
    required = {"rule_name", "field", "operator", "value"}
    if require_all:
        missing = required - body.keys()
        if missing:
            return f"missing required fields: {sorted(missing)}"
    if "field" in body and body["field"] not in VALID_RULE_FIELDS:
        return f"invalid field; must be one of {sorted(VALID_RULE_FIELDS)}"
    if "operator" in body and body["operator"] not in VALID_RULE_OPERATORS:
        return f"invalid operator; must be one of {sorted(VALID_RULE_OPERATORS)}"
    # E22: when the request carries BOTH halves, check the pairing here (covers
    # create, where require_all guarantees both). Single-sided patches are
    # checked post-merge in the update route.
    if "field" in body and "operator" in body:
        err = _validate_field_operator_pair(body["field"], body["operator"])
        if err:
            return err
    if body.get("set_tier") is not None and body["set_tier"] not in VALID_TIERS:
        return f"invalid set_tier; must be one of {sorted(VALID_TIERS)}"
    if body.get("set_category") is not None and body["set_category"] not in VALID_RULE_SET_CATEGORIES:
        return f"invalid set_category; must be one of {sorted(VALID_RULE_SET_CATEGORIES)}"
    # schema: at least one of set_tier / set_category must be non-null — a rule
    # that can match should always *do* something, and a both-null rule pollutes
    # /explain (P3). On create, both are required to be present-and-non-null. The
    # UPDATE case is enforced post-merge in the route (it needs the existing row to
    # compute the merged result), not here.
    if require_all and body.get("set_tier") is None and body.get("set_category") is None:
        return "at least one of set_tier / set_category must be provided"
    return None


def _validate_sender_group(body: dict, *, require_all: bool) -> "str | None":
    """Return an error string if the sender-group body is invalid, else None.

    D53: a group carries `patterns: [...]`, and PUT replaces the set atomically.
    The legacy single `email_pattern` is still accepted and normalized to a
    one-element list, so an older client isn't broken mid-alpha — but a body
    carrying BOTH with conflicting content is rejected rather than silently
    resolved in the server's favour (the E12 lesson: name the conflict).

    It also NORMALIZES the body's patterns in place (D80–D82): callers that pass
    validation hand the repo the normalized form.
    """
    if require_all:
        # Either shape satisfies the pattern requirement.
        missing = {"group_name", "urgency_floor"} - body.keys()
        if missing:
            return f"missing required fields: {sorted(missing)}"
        if "patterns" not in body and "email_pattern" not in body:
            return "missing required fields: ['patterns'] (or the legacy 'email_pattern')"

    # D80/D81: every pattern is normalized (a bare domain becomes `@domain`) and
    # validated HERE, and the body is rewritten in place with the normalized form,
    # so the repo stores — and the response echoes — what will actually match.
    # Comparisons below run on normalized values, so `example.com` and
    # `@example.com` are the same pattern rather than a conflict.
    if "patterns" in body:
        raw = body["patterns"]
        if not isinstance(raw, list):
            return "patterns must be a list of non-empty strings"
        if any(not isinstance(p, str) for p in raw):
            return "patterns must be a list of non-empty strings"
        cleaned, errors = normalize_patterns(raw)
        if errors:
            return errors[0]["error"]
        # DG3: "Empty set invalid." A group with no patterns has no members, so it
        # can never match — a silent no-op group is worse than a rejected payload.
        if not cleaned:
            return "patterns must contain at least one non-empty pattern"
        body["patterns"] = cleaned
        if "email_pattern" in body:
            legacy = normalize_pattern(str(body["email_pattern"]))
            if legacy and legacy.lower() not in {p.lower() for p in cleaned}:
                return ("conflicting patterns: email_pattern is not in patterns; "
                        "send one or the other")
            body["email_pattern"] = legacy

    if "email_pattern" in body and "patterns" not in body:
        legacy = normalize_pattern(str(body["email_pattern"]))
        if not legacy:
            return "email_pattern must be non-empty"
        err = pattern_error(legacy)
        if err:
            return err
        body["email_pattern"] = legacy

    if "urgency_floor" in body and body["urgency_floor"] not in VALID_TIERS:
        return f"invalid urgency_floor; must be one of {sorted(VALID_TIERS)}"
    return None


# ── notification preferences (typed) ──────────────────────────────────────────

def _parse_hhmm(value: "str") -> "tuple[bool, str | None]":
    """Validate a 'HH:MM' 24-hour time. Returns (ok, normalized) where normalized
    is zero-padded 'HH:MM', or (True, None) for an empty string (= unset)."""
    s = str(value).strip()
    if s == "":
        return (True, None)
    parts = s.split(":")
    if len(parts) != 2 or not (parts[0].isdigit() and parts[1].isdigit()):
        return (False, None)
    hh, mm = int(parts[0]), int(parts[1])
    if not (0 <= hh <= 23 and 0 <= mm <= 59):
        return (False, None)
    return (True, f"{hh:02d}:{mm:02d}")


def _read_notification_prefs(repo) -> dict:
    """Read the typed notification prefs from the preferences table, coercing each
    stored string back to its declared type (time stays a string or null; bool
    becomes a real bool). Missing keys fall back to NOTIFICATION_PREF_DEFAULTS."""
    out = {}
    for key, kind in NOTIFICATION_PREF_KEYS.items():
        raw = repo.get(key)
        if raw is None:
            out[key] = NOTIFICATION_PREF_DEFAULTS[key]
        elif kind == "bool":
            out[key] = str(raw).lower() == "true"
        else:  # time
            out[key] = raw or None
    return out


def _validate_notification_prefs(body: dict) -> "tuple[str | None, dict]":
    """Validate a notification-prefs patch. Returns (error_or_None, {key: str_to_store}).

    Only keys present in the body are validated and returned for writing (patch
    semantics). Times must be 'HH:MM' (or '' to unset); audio_alerts must be a bool.
    Unknown keys are rejected so typos don't silently no-op."""
    to_write = {}
    unknown = set(body.keys()) - set(NOTIFICATION_PREF_KEYS)
    if unknown:
        return (f"unknown notification preference keys: {sorted(unknown)}", {})
    for key, kind in NOTIFICATION_PREF_KEYS.items():
        if key not in body:
            continue
        val = body[key]
        if kind == "bool":
            if not isinstance(val, bool):
                return (f"{key} must be a boolean", {})
            to_write[key] = "true" if val else "false"
        else:  # time
            ok, normalized = _parse_hhmm(val)
            if not ok:
                return (f"{key} must be 'HH:MM' (00:00–23:59) or '' to unset", {})
            to_write[key] = normalized if normalized is not None else ""
    return (None, to_write)


# ── serialization ────────────────────────────────────────────────────────────

def _message_json(row, *, include_body: bool = False) -> dict:
    """Shape a joined message/classification row into a JSON-friendly dict.

    CROSS-QUERY INVARIANT (E10 guard): this serializer is shared by the list,
    search, and detail endpoints, which run *different* queries with *different*
    column sets. Any non-universal column read here MUST be selected by every query
    that feeds this function, and is read defensively via a `row.keys()` membership
    check so a query that legitimately omits it yields None instead of raising.
    The detail (`get_message`) query is the only one that selects body_plain/body_html.
    """
    import json
    keys = row.keys() if hasattr(row, "keys") else []

    def col(name):
        return row[name] if name in keys else None

    d = {
        "id": row["id"],
        "account": row["account"],
        "thread_id": col("thread_id"),
        "sender_name": col("sender_name"),
        "sender_email": row["sender_email"],
        "subject": col("subject"),
        "received_at": row["received_at"],
        "ingested_at": col("ingested_at"),
        "preview": col("preview"),
        "urgency_tier": col("urgency_tier"),
        "category": col("category"),
        "triage_state": col("triage_state"),
    }
    if include_body:
        d["body_plain"] = col("body_plain")
        d["body_html"] = col("body_html")
        # rule_matches is only present on the detail/list-with-classification query.
        if "rule_matches" in keys and row["rule_matches"]:
            d["rule_matches"] = json.loads(row["rule_matches"])
        # D48 (closes OI4): the RFC822 Message-ID, from the raw_headers blob —
        # what a Gmail-web `rfc822msgid:` deep link needs. Detail only (E10:
        # per-query serializers; list rows don't carry raw_headers). Null when
        # the header is absent — the client keeps its control disabled rather
        # than fabricate a link.
        headers = json.loads(row["raw_headers"]) if col("raw_headers") else {}
        d["rfc822_message_id"] = (headers.get("Message-ID")
                                  or headers.get("Message-Id")
                                  or headers.get("message-id"))
    return d