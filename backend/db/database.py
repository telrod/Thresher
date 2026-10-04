"""
thresher database module
Initializes SQLite, exposes a connection factory, and provides typed model classes.

Constitution refs:
  P1 — Never drop: all writes are additive; no DELETE without explicit user action
  P3 — Transparent: rule_matches stored with every classification
  P4 — Configurable: preferences table is the single source of truth for all settings
"""

import sqlite3
import json
import os
import logging
from pathlib import Path
from datetime import datetime, timezone
from dataclasses import dataclass, field
from typing import Optional

log = logging.getLogger(__name__)


# ── Typed errors ─────────────────────────────────────────────────────────────
# Reorder (D44) distinguishes two failure modes so the route can map them to
# distinct HTTP codes (400 vs 409). See RulesRepo.reorder.

class ReorderError(Exception):
    """Base for reorder rejections. `mismatch` carries legibility detail (P3)."""

    def __init__(self, message: str, *, mismatch: Optional[dict] = None):
        super().__init__(message)
        self.mismatch = mismatch or {}


class MalformedReorder(ReorderError):
    """The request shape is bad: duplicates, non-integer ids, or missing payload."""


class StaleReorderSet(ReorderError):
    """Shape is valid but membership doesn't match the live table — the client's
    fetched set drifted (a rule was created or deleted since). Client remedy:
    refetch and re-present."""

# ── Paths ──────────────────────────────────────────────────────────────────────

_HERE = Path(__file__).parent
_SCHEMA_PATH = _HERE / "schema.sql"
_SEED_PATH   = _HERE / "seed.sql"
# D68: the BUNDLED backend ships seed.example.sql, never seed.sql — the real one
# holds actual contacts and is gitignored precisely so it does not travel. So a
# fresh install has only the example, and falling back to it is what makes first
# run work at all. Found by running the bundled backend, which crashed with
# FileNotFoundError before this existed.
_SEED_EXAMPLE_PATH = _HERE / "seed.example.sql"

def default_db_path() -> Path:
    """Return the default location for the SQLite database file."""
    data_dir = Path.home() / "Library" / "Application Support" / "thresher"
    data_dir.mkdir(parents=True, exist_ok=True)
    return data_dir / "thresher.db"


def _utcnow() -> str:
    """ISO-8601 UTC timestamp — the format every other stored time uses."""
    return datetime.now(timezone.utc).isoformat()


# D57 — urgency decays with age. Recency bands for the default list ordering;
# see list_with_classification's docstring for the full rationale. Tier 1 is
# band 0 at ANY age, which is what keeps the Tier 1 invariant intact while
# tiers 2–5 lose their claim on the top of the list as they get old.
FRESH_DAYS = 14
RECENT_DAYS = 90

# julianday(), not a string compare: received_at is stored ISO-8601 with an
# offset ("2026-07-28T00:32:42+00:00") while datetime('now') yields a space-
# separated, offset-less string. Comparing those as TEXT is wrong at the
# boundary — 'T' (0x54) sorts above ' ' (0x20), so a naive compare silently
# biases toward "newer". julianday parses both, so the band edges land where
# the docstring says they do.
_AGE_BAND_SQL = f"""
    CASE WHEN c.urgency_tier = 1 THEN 0
         WHEN julianday(m.received_at) >= julianday('now', '-{FRESH_DAYS} day')  THEN 1
         WHEN julianday(m.received_at) >= julianday('now', '-{RECENT_DAYS} day') THEN 2
         ELSE 3 END
"""


def message_filter_clause(
    *,
    tier: Optional[int] = None,
    category: Optional[str] = None,
    triage_state: Optional[str] = None,
    triage_states: Optional[list] = None,
    account: Optional[str] = None,
    thread_id: Optional[str] = None,
    since: Optional[str] = None,
    until: Optional[str] = None,
) -> tuple:
    """Build the message-filter WHERE clause. Returns `(sql_fragment, params)`.

    **INVARIANT — one predicate, one filter.** This is the ONLY place the message
    filter is expressed in SQL. Its callers, all of which must describe the SAME
    set for the same filters:

      1. `MessageRepo.list_with_classification` — the rows the user sees.
      2. `MessageRepo.count_matching`           — the "showing N of M" total.
      3. `ClassificationRepo.update_triage_state_by_filter` — the filter-scoped
         bulk triage (D59), which UPDATES whatever this clause selects.
      4. `ClassificationRepo.count_matching_for_triage` — the same set counted
         two ways (total, and how many already hold the target state) so the
         bulk response can distinguish "N moved" from "N matched, M no-ops".
      5. `api.app._triage_bulk_by_filter` — resolves the affected ids ONLY when
         write-back was requested, since that needs per-message Message-IDs.
         The default path never materialises the set (the Session 29
         `fetchall()` lesson).

    No caller may append a filter condition of its own. Callers 1 and 2 drifting
    apart would make an honest-count affordance dishonest (OI21's whole point);
    3 or 5 drifting from either is worse — the set the user was shown and the
    set the server writes to would differ, and a wrong-set bulk UPDATE is silent.

    Add a caller here when you add one. The count is load-bearing documentation:
    an out-of-date list is how a sixth copy of this predicate gets written.

    The fragment names the tables as `m` (messages) and `c` (classifications), so
    every caller must use those aliases and LEFT JOIN classifications onto
    messages. It is either `""` (no filters) or starts with `WHERE `.
    """
    clauses, params = [], []
    if tier is not None:
        clauses.append("c.urgency_tier = ?"); params.append(tier)
    if category is not None:
        clauses.append("c.category = ?"); params.append(category)
    if triage_state is not None:
        clauses.append("c.triage_state = ?"); params.append(triage_state)
    if account is not None:
        # Multi-account: scope to one mailbox. A filter, not an assertion — an
        # unknown account yields an empty set rather than an error, so a
        # just-disconnected account can't 500 the list view.
        clauses.append("m.account = ?"); params.append(account)
    if triage_states:
        # D50 amendment (the author, Session 26): "unclassified" is a valid token —
        # messages with NO classification row (triage_state IS NULL via the
        # LEFT JOIN). The Open view includes it: a stuck classify failure must
        # be visible by default, not parked under All (P1).
        concrete = [s for s in triage_states if s != "unclassified"]
        conds = []
        if concrete:
            placeholders = ",".join("?" * len(concrete))
            conds.append(f"c.triage_state IN ({placeholders})")
            params.extend(concrete)
        if "unclassified" in triage_states:
            conds.append("c.triage_state IS NULL")
        clauses.append("(" + " OR ".join(conds) + ")")
    if thread_id is not None:
        clauses.append("m.thread_id = ?"); params.append(thread_id)
    if since is not None:
        # julianday on both sides for the same reason as _AGE_BAND_SQL: the
        # caller's bound and the stored value need not share a text format.
        clauses.append("julianday(m.received_at) >= julianday(?)")
        params.append(since)
    if until is not None:
        clauses.append("julianday(m.received_at) < julianday(?)")
        params.append(until)
    return (f"WHERE {' AND '.join(clauses)}" if clauses else ""), params


# ── Connection factory ─────────────────────────────────────────────────────────

def get_connection(db_path: Optional[Path] = None) -> sqlite3.Connection:
    """
    Open (or create) the SQLite database and return a connection.
    Enables WAL mode, foreign keys, and row_factory for dict-like access.
    """
    path = db_path or default_db_path()
    conn = sqlite3.connect(str(path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def init_db(db_path: Optional[Path] = None, seed: bool = True,
            migrate_schema: bool = True) -> sqlite3.Connection:
    """
    Initialize the database: apply schema, optionally seed defaults, then run any
    pending migrations (D53).

    Safe to call on an already-initialized database. The schema script uses
    CREATE IF NOT EXISTS, which is exactly why the migration step exists: an
    existing table is never altered by re-running the script, so every schema
    change after a database's creation reaches it through `db.migrations` instead.
    Both paths must converge on the same shape — a fresh DB gets the DDL from
    `schema.sql` and is stamped at CURRENT_VERSION with no migrations run.
    """
    conn = get_connection(db_path)
    schema_sql = _SCHEMA_PATH.read_text()
    conn.executescript(schema_sql)

    if seed:
        # Only seed if tables are empty (fresh install)
        row = conn.execute("SELECT COUNT(*) FROM preferences").fetchone()
        if row[0] == 0:
            # Local seed wins when present (a developer's real senders); the
            # committed example is the fallback and the only thing a shipped app
            # has. Absent BOTH is a genuine broken install, so it raises rather
            # than silently coming up with no rules — a classifier with no rules
            # tiers everything to unknown, which looks like a classification bug
            # rather than a missing file.
            seed_path = _SEED_PATH if _SEED_PATH.exists() else _SEED_EXAMPLE_PATH
            if not seed_path.exists():
                raise FileNotFoundError(
                    f"no seed file: expected {_SEED_PATH} or {_SEED_EXAMPLE_PATH}")
            conn.executescript(seed_path.read_text())
            log.info("Database seeded with defaults from %s.", seed_path.name)

    conn.commit()

    if migrate_schema:
        # Imported here, not at module scope: migrations import nothing from this
        # module, but keeping the dependency one-directional at import time avoids
        # any future cycle as the migration list grows.
        from db.migrations import migrate, stamp_fresh

        # A brand-new database already has the current shape from schema.sql, so it
        # is stamped rather than migrated — running data-backfill migrations against
        # freshly seeded rows would be wrong, not merely wasteful.
        if not stamp_fresh(conn):
            migrate(conn, db_path=db_path or default_db_path())

    log.info("Database initialized at %s", db_path or default_db_path())
    return conn


# ── Typed dataclasses (mirrors schema) ────────────────────────────────────────

@dataclass
class Message:
    id: str
    account: str
    sender_email: str
    received_at: str
    ingested_at: str
    thread_id: Optional[str] = None
    sender_name: Optional[str] = None
    subject: Optional[str] = None
    body_plain: Optional[str] = None
    body_html: Optional[str] = None
    raw_headers: Optional[dict] = None   # stored as JSON

    def to_dict(self) -> dict:
        d = self.__dict__.copy()
        if d.get("raw_headers") and not isinstance(d["raw_headers"], str):
            d["raw_headers"] = json.dumps(d["raw_headers"])
        return d


@dataclass
class Classification:
    message_id: str
    urgency_tier: int           # 1–5
    category: str               # 'work' | 'personal' | 'unknown'
    triage_state: str           # 'new' | 'acknowledged' | 'needs_action' | 'done'
    classified_at: str          # ISO-8601
    rule_matches: list          # [{rule_id, rule_name, field, value}]

    def to_dict(self) -> dict:
        d = self.__dict__.copy()
        d["rule_matches"] = json.dumps(d["rule_matches"])
        return d


@dataclass
class SenderGroup:
    id: Optional[int]
    group_name: str
    email_pattern: str
    urgency_floor: int
    notes: Optional[str] = None


@dataclass
class Rule:
    id: Optional[int]
    rule_name: str
    priority: int
    enabled: bool
    field: str      # 'sender_email' | 'sender_domain' | 'subject' | 'body' | 'sender_group'
    operator: str   # 'equals' | 'contains' | 'starts_with' | 'ends_with' | 'matches_group'
    value: str
    set_tier: Optional[int] = None
    set_category: Optional[str] = None
    notes: Optional[str] = None


# ── Repository helpers ─────────────────────────────────────────────────────────

class MessageRepo:
    """CRUD for messages. Writes are insert-only (P1: never drop)."""

    def __init__(self, conn: sqlite3.Connection):
        self.conn = conn

    def insert(self, msg: Message) -> bool:
        """Insert a message (idempotent). Returns True if a new row was stored,
        False when the id already existed (dedup) — the pipeline uses this to
        report newly-stored vs dedup-skipped counts (gate-defects Part D)."""
        d = msg.to_dict()
        cur = self.conn.execute(
            """
            INSERT OR IGNORE INTO messages
                (id, account, thread_id, sender_name, sender_email,
                 subject, body_plain, body_html, received_at, ingested_at, raw_headers)
            VALUES
                (:id, :account, :thread_id, :sender_name, :sender_email,
                 :subject, :body_plain, :body_html, :received_at, :ingested_at, :raw_headers)
            """,
            d,
        )
        self.conn.commit()
        return cur.rowcount == 1

    def get(self, message_id: str) -> Optional[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM messages WHERE id = ?", (message_id,)
        ).fetchone()

    def triage_counts(self) -> dict:
        """
        Store-wide message counts per triage state (D50 chip counts), plus
        `unclassified` for messages with no classification row (P1: they are a
        real state and must not vanish from the accounting). Whole-store by
        design: the list endpoint paginates (limit cap 500), so counting
        rendered rows would lie once the store outgrows a page — the E10-style
        "confirm the reality" check that motivated this method.
        """
        rows = self.conn.execute(
            """
            SELECT COALESCE(c.triage_state, 'unclassified') AS state,
                   COUNT(*) AS n
            FROM messages m
            LEFT JOIN classifications c ON c.message_id = m.id
            GROUP BY state
            """
        ).fetchall()
        counts = {"new": 0, "acknowledged": 0, "needs_action": 0, "done": 0,
                  "unclassified": 0}
        for r in rows:
            counts[r["state"]] = r["n"]
        # D51: the dock badge's derivation — untriaged (state New) Tier 1+2,
        # the Open view's urgent tail. Derived entirely from existing triage
        # state; no new "seen" concept.
        counts["urgent_new"] = self.conn.execute(
            "SELECT COUNT(*) FROM classifications "
            "WHERE triage_state = 'new' AND urgency_tier <= 2"
        ).fetchone()[0]
        return counts

    def count_matching(self, **filters) -> int:
        """
        How many messages match these filters, ignoring limit/offset.

        Separate from `triage_counts` on purpose: the chips want STORE-WIDE
        per-state totals (that is what D50 added them for), while the list's
        "showing N of M" wants the total for the *current* filtered view. Same
        number only when nothing is filtered — so answering both from one method
        would make the honest-count affordance dishonest the moment a filter is
        applied, which is the exact failure OI21 is about.

        Takes the same keyword filters as `list_with_classification` so the two
        cannot drift; `limit`/`offset` are accepted and ignored. Caller 2 of the
        shared predicate — see `message_filter_clause`.
        """
        filters.pop("limit", None)
        filters.pop("offset", None)
        rows = self.list_with_classification(
            **filters, limit=-1, offset=0, _count_only=True
        )
        return rows[0][0]

    def max_uid_for_account(self, account: str) -> int:
        """
        Highest ingested IMAP UID for an account — seeds the poll cursor at
        startup (gate-defects Part C) so a poll resumes above what's already
        stored instead of re-downloading the whole mailbox and relying on dedup.

        Derived from the `{account}:{uid}` synthetic PK: the `account` column
        scopes the scan, and only the numeric suffix after "account:" is parsed
        (substr is 1-based; the suffix starts at len(account)+2). No dedicated
        uid column exists — flagged in the work-order close-out rather than
        bolting on a migration without need. Returns 0 for an unknown/empty
        account.
        """
        row = self.conn.execute(
            "SELECT COALESCE(MAX(CAST(substr(id, ?) AS INTEGER)), 0) "
            "FROM messages WHERE account = ?",
            (len(account) + 2, account),
        ).fetchone()
        return row[0]

    def exists(self, message_id: str) -> bool:
        row = self.conn.execute(
            "SELECT 1 FROM messages WHERE id = ?", (message_id,)
        ).fetchone()
        return row is not None

    def list_with_classification(
        self,
        *,
        tier: Optional[int] = None,
        category: Optional[str] = None,
        triage_state: Optional[str] = None,
        triage_states: Optional[list] = None,
        account: Optional[str] = None,
        thread_id: Optional[str] = None,
        since: Optional[str] = None,
        until: Optional[str] = None,
        limit: int = 100,
        offset: int = 0,
        _count_only: bool = False,
    ) -> list[sqlite3.Row]:
        """
        Return messages joined with their classification, with optional filters.
        Powers the UI message list (spec §4.1.1).

        `triage_states` (D50) is the multi-value variant — the Open view needs
        new+needs_action in ONE query so tier-first ordering holds across the
        combined set. Mutually additive with `triage_state` (callers use one).

        `since`/`until` are ISO-8601 bounds on received_at (D57 / filters Part 2):
        explicit bounds, never named windows — "last 7 days" is a UI preset that
        resolves to a bound here, so the API stays composable and testable.
        `since` is inclusive, `until` exclusive; "older than X days" is the
        `until`-only case, which is what makes bulk-triaging a backlog possible.

        **Ordering (D57 — urgency decays with age).** Default is recency-BANDED,
        not tier-first: band, then tier, then received_at DESC. The bands are

            0  tier 1, at any age  — EXEMT from decay (the Tier 1 invariant:
                                     "Tier 1 always surfaces, in any operating
                                     mode"). Without this carve-out a stale T1
                                     would sort below a fresh T4 and the
                                     invariant would break silently.
            1  <= 14 days old      — fresh
            2  <= 90 days old      — recent
            3  older               — stale

        Why: tier-first alone let a 2021 T2 fossil outrank mail from this morning,
        and with the list's page-one window that made new mail unreachable (OI21).
        Age does NOT change the stored tier — classification stays honest and
        auditable (P3); only presentation order decays. When `thread_id` is given
        (a single-conversation fetch, spec §4.1.2 "view full conversation"), order
        chronologically (received_at ASC) so the thread reads top-to-bottom.
        """
        # Caller 1 of the shared predicate (see `message_filter_clause`): the
        # rows the user sees. The filter lives there, not here, so this query,
        # the count, and the filter-scoped bulk update cannot describe different
        # sets.
        where, params = message_filter_clause(
            tier=tier, category=category, triage_state=triage_state,
            triage_states=triage_states, account=account, thread_id=thread_id,
            since=since, until=until,
        )
        if _count_only:
            # `count_matching` reuses this method purely to share the WHERE
            # clause — two filter implementations would drift, and a "showing N
            # of M" whose M disagrees with the rows is worse than no M at all.
            return self.conn.execute(
                f"SELECT COUNT(*) FROM messages m "
                f"LEFT JOIN classifications c ON c.message_id = m.id {where}",
                params,
            ).fetchall()
        if thread_id is not None:
            order = "m.received_at ASC"
        else:
            order = f"{_AGE_BAND_SQL} ASC, c.urgency_tier ASC, m.received_at DESC"
        params.extend([limit, offset])
        # Explicit column list (no body_plain/body_html — the list view never hauls
        # full bodies); `preview` is the first 200 chars of the plain body. This shape
        # MUST stay parallel to search() — see the cross-query invariant in api.app
        # _message_json (E10 guard).
        return self.conn.execute(
            f"""
            SELECT m.id, m.account, m.thread_id, m.sender_name, m.sender_email,
                   m.subject, m.received_at, m.ingested_at,
                   substr(m.body_plain, 1, 200) AS preview,
                   c.urgency_tier, c.category, c.triage_state,
                   c.classified_at, c.rule_matches
            FROM messages m
            LEFT JOIN classifications c ON c.message_id = m.id
            {where}
            ORDER BY {order}
            LIMIT ? OFFSET ?
            """,
            params,
        ).fetchall()

    def search(self, query: str, *, limit: int = 100) -> list[sqlite3.Row]:
        """
        Substring search over sender, subject, and body. Satisfies P1's
        reachability acceptance test: any email ever received can be retrieved,
        even if archived/deleted in the source mailbox.
        """
        like = f"%{query}%"
        # Same non-body shape as list_with_classification (incl. `preview`) so the
        # shared _message_json serializer never reaches for a column this query
        # didn't select — the cross-query invariant / E10 guard.
        return self.conn.execute(
            """
            SELECT m.id, m.account, m.thread_id, m.sender_name, m.sender_email,
                   m.subject, m.received_at, m.ingested_at,
                   substr(m.body_plain, 1, 200) AS preview,
                   c.urgency_tier, c.category, c.triage_state,
                   c.classified_at, c.rule_matches
            FROM messages m
            LEFT JOIN classifications c ON c.message_id = m.id
            WHERE m.sender_email LIKE ? OR m.sender_name LIKE ?
               OR m.subject LIKE ? OR m.body_plain LIKE ?
            ORDER BY m.received_at DESC
            LIMIT ?
            """,
            (like, like, like, like, limit),
        ).fetchall()


class ClassificationRepo:
    """CRUD for classifications. Includes the rule_matches audit trail (P3)."""

    def __init__(self, conn: sqlite3.Connection):
        self.conn = conn

    def upsert(self, cls: Classification, *, commit: bool = True) -> None:
        """Insert or update a classification.

        NOTE (D52 invariant 1): the ON CONFLICT clause deliberately does NOT update
        `triage_state`. A reclassification must never reset the user's triage
        decision — a Done message reclassified to T1 stays Done.

        `commit=False` lets a bulk reclassify batch its commits (D52 part C).
        """
        d = cls.to_dict()
        self.conn.execute(
            """
            INSERT INTO classifications
                (message_id, urgency_tier, category, triage_state, classified_at, rule_matches)
            VALUES
                (:message_id, :urgency_tier, :category, :triage_state, :classified_at, :rule_matches)
            ON CONFLICT(message_id) DO UPDATE SET
                urgency_tier  = excluded.urgency_tier,
                category      = excluded.category,
                classified_at = excluded.classified_at,
                rule_matches  = excluded.rule_matches
            """,
            d,
        )
        if commit:
            self.conn.commit()

    def update_triage_state(self, message_id: str, new_state: str) -> None:
        valid = {"new", "acknowledged", "needs_action", "done"}
        if new_state not in valid:
            raise ValueError(f"Invalid triage state: {new_state!r}. Must be one of {valid}")
        self.conn.execute(
            "UPDATE classifications SET triage_state = ? WHERE message_id = ?",
            (new_state, message_id),
        )
        self.conn.commit()

    def update_triage_state_bulk(self, message_ids: list, new_state: str, *,
                                 audit: Optional[dict] = None) -> int:
        """Move many messages to one triage state ATOMICALLY. Returns rows changed.

        Not a loop over `update_triage_state`: that method commits per call, so
        looping it would apply the batch in N independent transactions and a
        mid-run failure would leave the store half-triaged — the partial-apply
        hazard D44 called out for reorder, in a path that touches far more rows.
        Here the whole set lands in ONE transaction, committed only if every
        row succeeds.

        Triage state is the only column touched: no reclassification, no
        notification (D52's silence invariant, which applies just as much to a
        bulk action as to a single one).

        `audit` (D60) is written to `bulk_operation_log` inside this same
        transaction. The id mode is logged for the same reason the filter mode
        is: the id list is gone once the request ends, so "what did that
        operation do?" is unanswerable afterwards without a record.
        """
        valid = {"new", "acknowledged", "needs_action", "done"}
        if new_state not in valid:
            raise ValueError(f"Invalid triage state: {new_state!r}. Must be one of {valid}")
        if not message_ids:
            return 0
        try:
            with self.conn:      # BEGIN … COMMIT, or ROLLBACK on any exception
                cur = self.conn.executemany(
                    "UPDATE classifications SET triage_state = ? WHERE message_id = ?",
                    [(new_state, mid) for mid in message_ids],
                )
                updated = cur.rowcount
                if audit is not None:
                    self._append_bulk_log(new_state, updated=updated, **audit)
                return updated
        except Exception:
            log.exception("bulk triage of %d message(s) rolled back", len(message_ids))
            raise

    def count_matching_for_triage(self, new_state: str, **filters) -> tuple:
        """`(matching, already_in_state)` for a filter set — the bulk preview.

        `already_in_state` is what makes the response's affected count
        interpretable: an UPDATE that sets a row to the value it already holds
        still reports it as changed by `rowcount`, so without this the caller
        cannot tell "3,204 messages moved" from "3,204 matched, 900 of which
        were already Done". Same predicate as the update itself (caller 3).
        """
        where, params = message_filter_clause(**filters)
        joined = ("SELECT COUNT(*) FROM messages m "
                  "LEFT JOIN classifications c ON c.message_id = m.id ")
        matching = self.conn.execute(joined + where, params).fetchone()[0]
        # AND onto the shared clause rather than rebuilding it: this is a
        # sub-question about the SAME set, not a second filter.
        already_where = (f"{where} AND c.triage_state = ?" if where
                         else "WHERE c.triage_state = ?")
        already = self.conn.execute(
            joined + already_where, [*params, new_state]
        ).fetchone()[0]
        return matching, already

    def update_triage_state_by_filter(self, new_state: str, *,
                                      audit: Optional[dict] = None,
                                      **filters) -> int:
        """Move every message MATCHING A FILTER to one triage state. Returns rows
        changed.

        `audit` (D60), when given, is written to `bulk_operation_log` INSIDE this
        method's transaction — see `_append_bulk_log`. Optional rather than
        required so the repo stays usable from a test or a script without
        manufacturing a log entry, but the API layer always passes it.

        Caller 3 of the shared predicate (see `message_filter_clause`) — the
        D59 filter-scoped bulk. The point of the whole feature: "mark everything
        matching this filter Done" was not expressible when the endpoint took an
        explicit id list, so clearing a 4,000-message backlog meant Load-more →
        select 100 → Done, dozens of times.

        ONE statement, not a loop and not a resolve-then-update-by-id: the
        matching set is computed inside the same statement that writes it, so
        there is no window in which the set could shift. That also makes it
        atomic for free — D44's lesson (intermediate states are observable by
        the reload-per-poll classifier, E11/D37) applies with much more force
        here than it did to a handful of reordered rules.

        The set MUST be frozen by an upper bound on received_at (`until`); the
        API layer requires it and explains why. This method does not default it —
        a default evaluated here would be evaluated at EXECUTE time, which is
        precisely the race the bound exists to close.

        P1: suppression, never deletion. This only ever writes
        `classifications.triage_state` — no message row is touched, so every
        affected message stays retrievable in All and in search. P3: the stored
        tier and `rule_matches` are untouched, so classification stays auditable.
        """
        valid = {"new", "acknowledged", "needs_action", "done"}
        if new_state not in valid:
            raise ValueError(f"Invalid triage state: {new_state!r}. Must be one of {valid}")
        where, params = message_filter_clause(**filters)
        # The subquery carries the join because the shared clause references both
        # aliases; UPDATE itself cannot join in SQLite.
        sql = (
            "UPDATE classifications SET triage_state = ? "
            "WHERE message_id IN ("
            "  SELECT m.id FROM messages m "
            "  LEFT JOIN classifications c ON c.message_id = m.id "
            f"  {where}"
            ")"
        )
        try:
            with self.conn:      # BEGIN … COMMIT, or ROLLBACK on any exception
                cur = self.conn.execute(sql, [new_state, *params])
                updated = cur.rowcount
                if audit is not None:
                    # INSIDE the transaction, deliberately (D60/B2). If the log
                    # were written after the commit, a crash in between would
                    # leave an applied operation with no record — and a log that
                    # can disagree with what happened is worse than none, because
                    # it will be believed.
                    self._append_bulk_log(new_state, updated=updated, **audit)
                return updated
        except Exception:
            log.exception("filter-scoped bulk triage rolled back; filters=%r", filters)
            raise

    def _append_bulk_log(self, new_state: str, *, updated: int, matched: int,
                         already: int, filter_json: Optional[str] = None,
                         until_bound: Optional[str] = None,
                         account: Optional[str] = None) -> None:
        """Append one row to `bulk_operation_log`. Never called outside a
        transaction — see the caller.

        Deliberately takes no connection of its own and does no commit: it is a
        participant in someone else's transaction, and giving it independent
        commit semantics is exactly how the log and the operation would drift.
        """
        self.conn.execute(
            "INSERT INTO bulk_operation_log "
            "(executed_at, triage_state, filter_json, until_bound, account, "
            " matched_count, updated_count, already_count) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (_utcnow(), new_state, filter_json, until_bound, account,
             matched, updated, already),
        )

    def recent_bulk_operations(self, *, limit: int = 50) -> list:
        """Newest-first slice of the bulk log — the B3 read path.

        The ONLY reader of this table, and it answers a human's question ("what
        did that operation do?"). Nothing in the codebase consults it to make a
        decision; see the schema comment for why that must stay true.
        """
        return self.conn.execute(
            "SELECT * FROM bulk_operation_log ORDER BY id DESC LIMIT ?",
            (limit,),
        ).fetchall()

    def get(self, message_id: str) -> Optional[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM classifications WHERE message_id = ?", (message_id,)
        ).fetchone()


class PreferencesRepo:
    """Read/write user preferences (P4: everything configurable)."""

    def __init__(self, conn: sqlite3.Connection):
        self.conn = conn

    def get(self, key: str, default: Optional[str] = None) -> Optional[str]:
        row = self.conn.execute(
            "SELECT value FROM preferences WHERE key = ?", (key,)
        ).fetchone()
        return row["value"] if row else default

    def set(self, key: str, value: str) -> None:
        self.conn.execute(
            """
            INSERT INTO preferences (key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            """,
            (key, value, datetime.now(timezone.utc).isoformat()),
        )
        self.conn.commit()

    def all(self) -> dict:
        rows = self.conn.execute("SELECT key, value FROM preferences").fetchall()
        return {r["key"]: r["value"] for r in rows}


class RulesRepo:
    """Read/write classification rules (P4). Returns rules ordered by priority."""

    def __init__(self, conn: sqlite3.Connection):
        self.conn = conn

    def all_enabled(self) -> list[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM rules WHERE enabled = 1 ORDER BY priority ASC"
        ).fetchall()

    def all_rules(self) -> list[sqlite3.Row]:
        """All rules, enabled AND disabled, ordered by priority.

        The engine evaluates only `all_enabled`, but the Settings rules editor
        needs disabled rows too — otherwise a toggled-off rule becomes invisible
        and can never be re-enabled from the UI (frontend gap #4)."""
        return self.conn.execute(
            "SELECT * FROM rules ORDER BY priority ASC"
        ).fetchall()

    def all_sender_groups(self) -> list[dict]:
        """Every sender group, each carrying its D53 `patterns` list.

        Returns dicts rather than `sqlite3.Row` because a Row is immutable and the
        patterns come from a second table. Callers index them the same way
        (`g["group_name"]`), so the engine and the serializers are unaffected.

        TWO queries, never one-per-group: the engine rebuilds this on every poll
        (E11/D37), so an N+1 here would be a per-poll cost that grows with the
        user's group count.
        """
        groups = self.conn.execute(
            "SELECT * FROM sender_groups ORDER BY urgency_floor ASC"
        ).fetchall()

        patterns: dict[int, list[str]] = {}
        try:
            for row in self.conn.execute(
                "SELECT group_id, pattern FROM sender_group_patterns ORDER BY id ASC"
            ):
                patterns.setdefault(row["group_id"], []).append(row["pattern"])
        except sqlite3.OperationalError:
            # Table absent: an unmigrated database. The engine falls back to the
            # deprecated `email_pattern` column, so classification still works —
            # the two-step deprecation being real rather than nominal.
            log.warning("sender_group_patterns missing; falling back to the "
                        "deprecated email_pattern column")

        out = []
        for g in groups:
            d = dict(g)
            # Fall back per-group, not globally: a group added before the migration
            # backfilled (or one whose patterns were all deleted) still resolves to
            # its legacy pattern rather than silently losing its members.
            d["patterns"] = patterns.get(g["id"]) or (
                [g["email_pattern"]] if (g["email_pattern"] or "").strip() else []
            )
            out.append(d)
        return out

    # ── rules CRUD (P4) ──────────────────────────────────────────────────────
    # Deleting a *rule* or *sender group* is config management (explicit user
    # action), which P4 permits; P1's "never delete" applies to email messages,
    # not config rows.

    _RULE_COLUMNS = (
        "rule_name", "priority", "enabled", "field", "operator", "value",
        "set_tier", "set_category", "notes",
    )

    def get_rule(self, rule_id: int) -> Optional[sqlite3.Row]:
        return self.conn.execute(
            "SELECT * FROM rules WHERE id = ?", (rule_id,)
        ).fetchone()

    def resolve_sender_group_id(self, field, operator, value) -> Optional[int]:
        """Resolve a `matches_group` rule's group NAME to its id, or None.

        Part 3 of the gate-defects workorder. The D53 migration bound existing
        rules by id, but nothing bound rules created or edited afterwards:
        `create_rule` never inserted the column and `update_rule` never listed
        it, so every rule saved through the UI/API kept `sender_group_id` NULL
        and fell back to name matching — which silently orphans the rule the
        moment its group is renamed (the D55 known gap; rule 18 hit it live on
        2026-08-01).

        Two deliberate non-behaviours:

        * A name that matches no group resolves to None rather than to a guess.
          Rule 10 (`value='unknown'`) is the live example — no group has ever
          been named "unknown", so it has always been inert. Inventing a
          binding would upgrade a visibly-dead rule into a silently-wrong one.
        * Only `matches_group` rules are touched. A subject rule whose value
          happens to equal a group name must not acquire a binding.

        Comparison goes through the ENGINE's normalizer, not a bare `lower()`:
        `_norm_group` strips and casefolds, and using anything else here would
        let a rule bind by id under one rule and match by name under another
        (the OI19/D55 lesson, in reverse).
        """
        if field != "sender_group" or operator != "matches_group":
            return None
        from classification.engine import _norm_group
        wanted = _norm_group(value)
        if not wanted:
            return None
        for row in self.conn.execute(
            "SELECT id, group_name FROM sender_groups"
        ).fetchall():
            if _norm_group(row["group_name"]) == wanted:
                return row["id"]
        return None

    def create_rule(self, fields: dict) -> sqlite3.Row:
        """Insert a rule and return the created row (incl. its new id).

        Under dense numbering (D44) a new rule APPENDS: the default priority is
        MAX(priority)+1, not the old fixed 100. An explicit `priority` in the
        body is still honored — the next reorder normalizes everything dense
        anyway.
        """
        if "priority" in fields:
            priority = fields["priority"]
        else:
            priority = self.conn.execute(
                "SELECT COALESCE(MAX(priority), 0) + 1 FROM rules"
            ).fetchone()[0]
        cur = self.conn.execute(
            """
            INSERT INTO rules
                (rule_name, priority, enabled, field, operator, value,
                 set_tier, set_category, notes, sender_group_id, updated_at)
            VALUES
                (:rule_name, :priority, :enabled, :field, :operator, :value,
                 :set_tier, :set_category, :notes, :sender_group_id,
                 :updated_at)
            """,
            {
                "rule_name":    fields["rule_name"],
                "priority":     priority,
                "enabled":      1 if fields.get("enabled", True) else 0,
                "field":        fields["field"],
                "operator":     fields["operator"],
                "value":        fields["value"],
                "set_tier":     fields.get("set_tier"),
                "set_category": fields.get("set_category"),
                "notes":        fields.get("notes"),
                # Part 3: bind by id at SAVE time, not only in the D53
                # migration, so a rename can never orphan a rule created later.
                # An explicit sender_group_id in the payload wins; otherwise it
                # is resolved from the group name (None if it resolves to
                # nothing — flagged, never guessed).
                "sender_group_id": fields.get(
                    "sender_group_id",
                    self.resolve_sender_group_id(
                        fields["field"], fields["operator"], fields["value"])),
                # D52: a brand-new rule counts as "changed now" — mail classified
                # before it existed genuinely is stale with respect to it.
                "updated_at":   _utcnow(),
            },
        )
        self.conn.commit()
        return self.get_rule(cur.lastrowid)

    def update_rule(self, rule_id: int, fields: dict) -> Optional[sqlite3.Row]:
        """Update only the provided columns. Returns the updated row, or None if absent.

        Part 3: if this edit can change which sender group the rule targets,
        `sender_group_id` is re-resolved from the POST-MERGE field/operator/value
        — the E12 lesson. A partial PUT that changes only `value` still has to
        rebind, and validating against the submitted fragment alone would miss
        that the rule is a `matches_group` rule at all.
        """
        existing = self.get_rule(rule_id)
        if existing is None:
            return None

        sets, params = [], []
        for col in self._RULE_COLUMNS:
            if col in fields:
                val = fields[col]
                if col == "enabled":
                    val = 1 if val else 0
                sets.append(f"{col} = ?"); params.append(val)

        # Rebind the group id whenever any input to the binding is in play.
        if "sender_group_id" in fields:
            sets.append("sender_group_id = ?")
            params.append(fields["sender_group_id"])
        elif {"field", "operator", "value"} & fields.keys():
            merged = {k: (fields[k] if k in fields else existing[k])
                      for k in ("field", "operator", "value")}
            sets.append("sender_group_id = ?")
            params.append(self.resolve_sender_group_id(
                merged["field"], merged["operator"], merged["value"]))
        if sets:
            params.append(rule_id)
            self.conn.execute(
                f"UPDATE rules SET {', '.join(sets)}, updated_at = ? WHERE id = ?",
                params[:-1] + [_utcnow(), params[-1]],
            )
            self.conn.commit()
        return self.get_rule(rule_id)

    def delete_rule(self, rule_id: int) -> bool:
        """Hard-delete a rule (config management, allowed). Returns False if absent."""
        if self.get_rule(rule_id) is None:
            return False
        self.conn.execute("DELETE FROM rules WHERE id = ?", (rule_id,))
        self.conn.commit()
        return True

    def reorder(self, ordered_ids: list) -> list[sqlite3.Row]:
        """Apply a new rule ordering (D44). Position is priority: the client sends
        the complete new order as a list of rule ids and the server assigns
        `priority = index + 1` (dense, 1..N) to every rule in ONE transaction —
        all-or-nothing, so the reload-per-poll classifier (D37/E11) never sees a
        half-applied order.

        `ordered_ids` must be an EXACT permutation of ALL rule ids (enabled and
        disabled — disabled rules hold their place). The permutation check runs
        INSIDE the transaction against the live table (E12: state invariant, not
        request-shape validation — it spans what the client fetched *then* and what
        the DB holds *now*).

        Raises MalformedReorder (bad shape) or StaleReorderSet (shape valid but
        membership drifted); rolls back on either so no priority changes.
        Returns the full reordered rule set on success.
        """
        # ── Shape validation (malformed): list of unique integers ──────────────
        if not isinstance(ordered_ids, list) or not ordered_ids:
            raise MalformedReorder("ordered_ids must be a non-empty array of rule ids")
        # bool is an int subclass — reject it explicitly so True/False can't pose as ids.
        if any(isinstance(i, bool) or not isinstance(i, int) for i in ordered_ids):
            raise MalformedReorder("ordered_ids must contain only integer rule ids")
        if len(set(ordered_ids)) != len(ordered_ids):
            dupes = sorted({i for i in ordered_ids if ordered_ids.count(i) > 1})
            raise MalformedReorder(
                "ordered_ids contains duplicate ids",
                mismatch={"duplicate": dupes},
            )

        try:
            # BEGIN — sqlite3 opens a transaction implicitly on the first DML/DQL
            # under the default isolation level; the read below and the writes
            # commit or roll back together.
            live_ids = [
                r["id"] for r in self.conn.execute("SELECT id FROM rules").fetchall()
            ]
            requested = set(ordered_ids)
            live = set(live_ids)
            if requested != live:
                # Stale set: valid shape, wrong membership. Name the mismatch (P3).
                raise StaleReorderSet(
                    "ordered_ids is not an exact permutation of the current rule set; "
                    "refetch and retry",
                    mismatch={
                        "unexpected": sorted(requested - live),  # ids the client sent that no longer exist
                        "missing":    sorted(live - requested),  # live ids the client omitted
                    },
                )
            self.conn.executemany(
                "UPDATE rules SET priority = ?, updated_at = ? WHERE id = ?",
                [(index + 1, _utcnow(), rule_id)
                 for index, rule_id in enumerate(ordered_ids)],
            )
            self.conn.commit()
        except ReorderError:
            self.conn.rollback()
            raise
        return self.all_rules()

    # ── sender-group CRUD (P4 + sender-override invariant) ────────────────────

    _GROUP_COLUMNS = ("group_name", "email_pattern", "urgency_floor", "notes")

    @staticmethod
    def _normalize_patterns(raw) -> list[str]:
        """Trim, drop empties, de-duplicate, preserve order.

        De-duplication matters at the repo layer as well as in the UNIQUE index: a
        payload repeating a pattern is a client slip, not a reason to 409.
        """
        out: list[str] = []
        for p in raw or []:
            s = (p or "").strip()
            if s and s not in out:
                out.append(s)
        return out

    def get_sender_group(self, group_id: int) -> Optional[dict]:
        """One group with its `patterns` list (a dict — a Row can't carry it)."""
        row = self.conn.execute(
            "SELECT * FROM sender_groups WHERE id = ?", (group_id,)
        ).fetchone()
        if row is None:
            return None
        d = dict(row)
        try:
            d["patterns"] = [
                r["pattern"] for r in self.conn.execute(
                    "SELECT pattern FROM sender_group_patterns WHERE group_id = ? "
                    "ORDER BY id ASC", (group_id,))
            ]
        except sqlite3.OperationalError:
            d["patterns"] = []
        if not d["patterns"] and (d.get("email_pattern") or "").strip():
            d["patterns"] = [d["email_pattern"].strip()]
        return d

    def create_sender_group(self, fields: dict) -> dict:
        """Create a group and its pattern set in ONE transaction.

        Accepts either the D53 `patterns` list or a legacy single `email_pattern`
        (normalized to a one-element list), so an older client isn't broken
        mid-alpha. `email_pattern` is still written — the deprecated column holds
        the first pattern for one release so a rollback still classifies.
        """
        patterns = self._normalize_patterns(
            fields.get("patterns")
            if fields.get("patterns") is not None
            else [fields.get("email_pattern")]
        )
        try:
            self.conn.execute("BEGIN")
            cur = self.conn.execute(
                """
                INSERT INTO sender_groups (group_name, email_pattern, urgency_floor, notes)
                VALUES (:group_name, :email_pattern, :urgency_floor, :notes)
                """,
                {
                    "group_name":    fields["group_name"],
                    # Legacy column mirrors the first pattern (two-step deprecation).
                    "email_pattern": patterns[0] if patterns else "",
                    "urgency_floor": fields["urgency_floor"],
                    "notes":         fields.get("notes"),
                },
            )
            group_id = cur.lastrowid
            self.conn.executemany(
                "INSERT INTO sender_group_patterns (group_id, pattern) VALUES (?, ?)",
                [(group_id, p) for p in patterns],
            )
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise
        return self.get_sender_group(group_id)

    def update_sender_group(self, group_id: int, fields: dict) -> Optional[dict]:
        """Update a group; if `patterns` is present, REPLACE the whole set atomically.

        The D44 shape: the client sends the complete set and the server swaps it in
        one transaction — no per-pattern add/remove calls, so the engine's
        reload-per-poll never observes a half-updated group. Omitting `patterns`
        leaves the existing set untouched (a name-or-floor-only edit).
        """
        if self.get_sender_group(group_id) is None:
            return None

        replace_patterns = "patterns" in fields
        patterns = self._normalize_patterns(fields.get("patterns")) if replace_patterns else None

        sets, params = [], []
        for col in self._GROUP_COLUMNS:
            if col in fields:
                sets.append(f"{col} = ?"); params.append(fields[col])
        # Keep the deprecated column in step with the new first pattern.
        if replace_patterns and "email_pattern" not in fields:
            sets.append("email_pattern = ?")
            params.append(patterns[0] if patterns else "")

        try:
            self.conn.execute("BEGIN")
            if sets:
                self.conn.execute(
                    f"UPDATE sender_groups SET {', '.join(sets)} WHERE id = ?",
                    params + [group_id],
                )
            if replace_patterns:
                self.conn.execute(
                    "DELETE FROM sender_group_patterns WHERE group_id = ?", (group_id,))
                self.conn.executemany(
                    "INSERT INTO sender_group_patterns (group_id, pattern) VALUES (?, ?)",
                    [(group_id, p) for p in patterns],
                )
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise
        return self.get_sender_group(group_id)

    def replace_sender_group_patterns(self, sets: dict) -> None:
        """Replace the pattern sets of several groups in ONE transaction (D78).

        `sets` maps group_id → the complete new pattern list. Either every group
        changes or none does: onboarding writes leadership and family together,
        and a half-applied pair would be a state the user never asked for.
        Patterns are written as given; callers normalize and validate first.
        """
        try:
            self.conn.execute("BEGIN")
            for group_id, patterns in sets.items():
                self.conn.execute(
                    "UPDATE sender_groups SET email_pattern = ? WHERE id = ?",
                    (patterns[0] if patterns else "", group_id))
                self.conn.execute(
                    "DELETE FROM sender_group_patterns WHERE group_id = ?", (group_id,))
                self.conn.executemany(
                    "INSERT INTO sender_group_patterns (group_id, pattern) VALUES (?, ?)",
                    [(group_id, p) for p in patterns],
                )
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise

    def delete_sender_group(self, group_id: int) -> bool:
        if self.get_sender_group(group_id) is None:
            return False
        self.conn.execute("DELETE FROM sender_groups WHERE id = ?", (group_id,))
        self.conn.commit()
        return True
