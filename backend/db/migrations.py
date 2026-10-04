"""
Versioned schema migrations — the project's first real migration machinery (D53).

Why this exists
---------------
`init_db` applies `schema.sql` with `CREATE TABLE IF NOT EXISTS`, which is fine for
a fresh database and does **nothing** for one that already exists. So every schema
change since the alpha opened has been unreachable on the live DB: OI5's `rules`
CHECK landed only on fresh installs, and D52's `rules.updated_at` would have had
the same problem. DG3 made the machinery explicit scope: "versioned schema
(schema_version), migrations run once at startup; OI5's legacy-CHECK debt sweeps
into the same mechanism — one migration system, two debts paid."

Design
------
- **Version marker: `PRAGMA user_version`.** SQLite gives us a durable integer in
  the file header for free, so no bookkeeping table is needed. Consistent with the
  project's drop-the-dependency pattern (Redis → `queue.Queue`, keyring →
  `security`, Alamofire → `URLSession`).
- **One transaction per migration.** A migration either fully applies and stamps
  its version, or rolls back leaving the version untouched. The classifier reloads
  rules every poll (E11/D37), so a half-applied schema is not a theoretical
  concern — it would be read by the next poll.
- **Every migration is idempotency-guarded** (checks for the column/table before
  adding it), so running twice is a no-op. Belt and braces alongside the version
  check: the version says "don't run", the guard says "and if you did, no harm".
- **Backup before touching a non-empty database.** The first migration ever run by
  this project runs against the author's real alpha mail. Backup-before-migrate is written
  into the code, not left to whoever remembers to do it.
- **Loud logging.** Session 27 opened with a stale runtime that nothing announced;
  the version before, each migration applied, and the version after are all logged.

Adding a migration
------------------
Append to `MIGRATIONS` with the next version number, write the body as
`_mNNN_description(conn)`, and add the matching DDL to `schema.sql` so fresh
databases get it directly. Both paths must end in the same schema.
"""

from __future__ import annotations

import logging
import shutil
import sqlite3
from pathlib import Path
from typing import Callable, NamedTuple, Optional

log = logging.getLogger("thresher.migrations")


class Migration(NamedTuple):
    version: int
    description: str
    apply: Callable[[sqlite3.Connection], None]


class MigrationError(RuntimeError):
    """A migration failed. The database is unchanged: the transaction rolled back
    and `user_version` was not advanced, so the next startup retries cleanly."""


# ── Introspection helpers (used by the idempotency guards) ────────────────────

def _table_exists(conn: sqlite3.Connection, table: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
    ).fetchone()
    return row is not None


def _column_exists(conn: sqlite3.Connection, table: str, column: str) -> bool:
    if not _table_exists(conn, table):
        return False
    cols = [r["name"] for r in conn.execute(f"PRAGMA table_info({table})")]
    return column in cols


def _table_sql(conn: sqlite3.Connection, table: str) -> str:
    row = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (table,)
    ).fetchone()
    return (row["sql"] if row and row["sql"] else "")


def user_version(conn: sqlite3.Connection) -> int:
    return conn.execute("PRAGMA user_version").fetchone()[0]


def _set_user_version(conn: sqlite3.Connection, version: int) -> None:
    # PRAGMA doesn't accept bound parameters; version is an int we control.
    conn.execute(f"PRAGMA user_version = {int(version)}")


def _has_mail(conn: sqlite3.Connection) -> bool:
    """True if the store holds any mail.

    Mail — not rules — is the test for "is there user data here". A freshly created
    database is seeded with 11 rules and 4 sender groups by `seed.sql`, so a
    rules-based emptiness test would call every fresh install non-empty. Mail only
    ever arrives from a real poll, which makes it the honest signal both for
    "is this worth backing up" and for "is this a fresh database".
    """
    if not _table_exists(conn, "messages"):
        return False
    return conn.execute("SELECT 1 FROM messages LIMIT 1").fetchone() is not None


# ── Migration 1 — sender_group_patterns (D53) ────────────────────────────────

def _m001_sender_group_patterns(conn: sqlite3.Connection) -> None:
    """Child table for multi-pattern sender groups; each group's existing
    `email_pattern` becomes its first pattern row.

    `sender_groups.email_pattern` is deliberately NOT dropped here — a two-step
    deprecation, so rolling back to the previous binary still classifies. The
    engine stops reading it in the same release that adds this table.
    """
    if not _table_exists(conn, "sender_group_patterns"):
        conn.execute("""
            CREATE TABLE sender_group_patterns (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                group_id  INTEGER NOT NULL REFERENCES sender_groups(id) ON DELETE CASCADE,
                pattern   TEXT NOT NULL,
                UNIQUE (group_id, pattern)
            )
        """)
        conn.execute(
            "CREATE INDEX idx_sgp_group_id ON sender_group_patterns(group_id)"
        )
        log.info("  created sender_group_patterns")

    # Backfill: one pattern row per group with a non-empty email_pattern. The
    # UNIQUE constraint plus this NOT EXISTS make the backfill re-runnable.
    # Groups with an empty pattern get no row (they matched nothing before, and an
    # invented pattern would be worse than none).
    cur = conn.execute("""
        INSERT INTO sender_group_patterns (group_id, pattern)
        SELECT g.id, TRIM(g.email_pattern)
        FROM sender_groups g
        WHERE TRIM(COALESCE(g.email_pattern, '')) <> ''
          AND NOT EXISTS (
              SELECT 1 FROM sender_group_patterns p
              WHERE p.group_id = g.id AND p.pattern = TRIM(g.email_pattern)
          )
    """)
    log.info("  backfilled %d pattern row(s) from sender_groups.email_pattern",
             cur.rowcount if cur.rowcount and cur.rowcount > 0 else 0)


# ── Migration 2 — rules.sender_group_id (D55: match-by-id) ───────────────────

def _m002_rules_sender_group_id(conn: sqlite3.Connection) -> None:
    """Give `matches_group` rules a real foreign key to their group.

    Match-by-name silently orphans rules when a group is renamed (the D55 gap).
    Resolution uses the SAME case-insensitive comparison the engine now uses, which
    is what makes a mixed-case group name like "Me" resolvable at all (OI19/D55).

    Rules whose value resolves to zero groups, or to more than one, are left NULL
    and reported by `unmapped_group_rules()` — never guessed. The engine keeps a
    name-based fallback when the id is NULL, so this migration is non-breaking.
    """
    if not _column_exists(conn, "rules", "sender_group_id"):
        conn.execute(
            "ALTER TABLE rules ADD COLUMN sender_group_id INTEGER "
            "REFERENCES sender_groups(id) ON DELETE SET NULL"
        )
        log.info("  added rules.sender_group_id")

    # Resolve unambiguous matches only: exactly one group whose normalized name
    # equals the rule's normalized value. TRIM+LOWER mirrors engine._norm_group
    # (SQLite has no casefold; for the ASCII group names in play LOWER is
    # equivalent, and the engine remains the authority at match time).
    cur = conn.execute("""
        UPDATE rules
           SET sender_group_id = (
               SELECT g.id FROM sender_groups g
                WHERE LOWER(TRIM(g.group_name)) = LOWER(TRIM(rules.value))
           )
         WHERE operator = 'matches_group'
           AND sender_group_id IS NULL
           AND (SELECT COUNT(*) FROM sender_groups g
                 WHERE LOWER(TRIM(g.group_name)) = LOWER(TRIM(rules.value))) = 1
    """)
    log.info("  mapped %d matches_group rule(s) to a group id",
             cur.rowcount if cur.rowcount and cur.rowcount > 0 else 0)


# ── Migration 3 — OI5: the rules both-null CHECK on legacy DBs ───────────────

def _m003_rules_both_null_check(conn: sqlite3.Connection) -> None:
    """OI5, swept into the same mechanism per DG3 ("two debts paid").

    Legacy DBs kept a constraint-free `rules` table because `schema.sql` is applied
    with CREATE TABLE IF NOT EXISTS. SQLite can't ALTER a table to add a CHECK, so
    the table is rebuilt: create → copy → drop → rename, all inside the caller's
    transaction, preserving ids (and therefore priority order).

    Refuses to run if any existing row violates the constraint: a migration must
    never delete or mutate a user's rules to make itself fit.
    """
    if "CHECK (set_tier IS NOT NULL OR set_category IS NOT NULL)" in _table_sql(conn, "rules"):
        log.info("  rules already carries the both-null CHECK — nothing to do")
        return

    violators = conn.execute(
        "SELECT COUNT(*) FROM rules WHERE set_tier IS NULL AND set_category IS NULL"
    ).fetchone()[0]
    if violators:
        raise MigrationError(
            f"{violators} existing rule(s) have both set_tier and set_category NULL, "
            "which the new CHECK forbids. Refusing to rebuild the rules table: fix or "
            "delete those rules deliberately, then re-run. No data was changed."
        )

    # Carry EVERY optional column the live table happens to have, so the rebuild can
    # never silently drop one another migration added. Enumerated from the table
    # itself rather than hardcoded, because hardcoding makes this body depend on
    # migration ORDER — and a later migration adding a column would then be quietly
    # discarded if this one ever re-ran after it.
    OPTIONAL = {
        "sender_group_id": "INTEGER REFERENCES sender_groups(id) ON DELETE SET NULL",
        "updated_at":      "TEXT",
    }
    present = [c for c in OPTIONAL if _column_exists(conn, "rules", c)]
    extra_ddl = "".join(f",\n            {c} {OPTIONAL[c]}" for c in present)
    cols = ("id, rule_name, priority, enabled, field, operator, value, "
            "set_tier, set_category, notes"
            + "".join(f", {c}" for c in present))

    conn.execute(f"""
        CREATE TABLE rules_new (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            rule_name       TEXT NOT NULL,
            priority        INTEGER NOT NULL DEFAULT 100,
            enabled         INTEGER NOT NULL DEFAULT 1,
            field           TEXT NOT NULL,
            operator        TEXT NOT NULL,
            value           TEXT NOT NULL,
            set_tier        INTEGER CHECK (set_tier BETWEEN 1 AND 5),
            set_category    TEXT CHECK (set_category IN ('work', 'personal')),
            notes           TEXT{extra_ddl},
            CHECK (set_tier IS NOT NULL OR set_category IS NOT NULL)
        )
    """)
    conn.execute(f"INSERT INTO rules_new ({cols}) SELECT {cols} FROM rules")
    moved = conn.execute("SELECT COUNT(*) FROM rules_new").fetchone()[0]
    conn.execute("DROP TABLE rules")
    conn.execute("ALTER TABLE rules_new RENAME TO rules")
    log.info("  rebuilt rules with the both-null CHECK (%d rule(s) preserved)", moved)


# ── Migration 4 — rules.updated_at (D52 part D: staleness copy) ──────────────

def _m004_rules_updated_at(conn: sqlite3.Connection) -> None:
    """When a rule last changed, so the explain panel can say how stale a stored
    classification is ("N rules have changed since").

    Existing rows are backfilled **NULL**, deliberately. There is no record of when
    they were last edited, and stamping `datetime('now')` would make every stored
    classification instantly look stale — the exact opposite of what the staleness
    copy is for. NULL reads as "not known to have changed since", and contributes
    zero to the count.
    """
    if not _column_exists(conn, "rules", "updated_at"):
        conn.execute("ALTER TABLE rules ADD COLUMN updated_at TEXT")
        log.info("  added rules.updated_at (existing rows left NULL, deliberately)")


# ── Migration 5 — classifications.reclassified_at (D52 invariant 3) ──────────

def _m005_classifications_reclassified_at(conn: sqlite3.Connection) -> None:
    """Records that a classification was RE-run, and when.

    D52 invariant 3 is "overwrite with dated audit, never version": there is no
    history table and no second row. This single column is what lets the audit
    distinguish "classified <date>" from "reclassified <date>" without keeping
    versions. NULL means classified once at ingest and never re-run — which is also
    invariant 4's default lifecycle.
    """
    if not _table_exists(conn, "classifications"):
        # Nothing to alter. `_column_exists` already returns False for a missing
        # table, so without this guard the ALTER would raise on a database that
        # predates the table — a migration must not assume every table exists.
        log.info("  classifications table absent — nothing to alter")
        return
    if not _column_exists(conn, "classifications", "reclassified_at"):
        conn.execute("ALTER TABLE classifications ADD COLUMN reclassified_at TEXT")
        log.info("  added classifications.reclassified_at")


def _m006_bulk_operation_log(conn: sqlite3.Connection) -> None:
    """Append-only record of every executed bulk operation (D60).

    The filter and the frozen `until` bound exist only at execute time and are
    not reconstructable afterwards — which is why this is built now, while undo
    deliberately is not (docs/IDEAS.md). It is a LOG, NOT STATE: nothing updates
    or deletes these rows, and no code path may read the table to make a
    decision. See the fuller note on the DDL in schema.sql; both paths must
    converge on the same shape, so keep the two definitions identical.

    Idempotency-guarded like every other migration body: CREATE TABLE IF NOT
    EXISTS is already safe, but the explicit check keeps the log line honest
    about whether this run actually did anything.
    """
    if _table_exists(conn, "bulk_operation_log"):
        log.info("  bulk_operation_log already present — nothing to create")
        return
    conn.execute(
        """
        CREATE TABLE bulk_operation_log (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            executed_at     TEXT NOT NULL,
            triage_state    TEXT NOT NULL,
            filter_json     TEXT,
            until_bound     TEXT,
            account         TEXT,
            matched_count   INTEGER NOT NULL,
            updated_count   INTEGER NOT NULL,
            already_count   INTEGER NOT NULL DEFAULT 0
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_bulk_log_executed_at "
        "ON bulk_operation_log(executed_at DESC)"
    )
    log.info("  created bulk_operation_log (+ executed_at index)")


def _m007_writeback_log(conn: sqlite3.Connection) -> None:
    """Append-only record of every mailbox write-back ATTEMPT (D63).

    Write-back is the only outward-facing side effect this app has (P5), and it
    left no trace: the `wrote_back` flag was returned to the client and
    discarded. When one was noticed firing unexpectedly, "how many messages has
    this touched?" had no answer — the blast radius was unbounded and
    unknowable. That is what this fixes.

    Failures are logged too (`ok = 0`): a log of only successes would understate
    what was attempted against the real mailbox. Keep this definition identical
    to the DDL in schema.sql — both paths must converge.
    """
    if _table_exists(conn, "writeback_log"):
        log.info("  writeback_log already present — nothing to create")
        return
    conn.execute(
        """
        CREATE TABLE writeback_log (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            attempted_at    TEXT NOT NULL,
            account         TEXT NOT NULL,
            message_id      TEXT NOT NULL,
            rfc822_id       TEXT,
            action          TEXT NOT NULL,
            triage_state    TEXT,
            ok              INTEGER NOT NULL,
            detail          TEXT
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_writeback_log_at "
                 "ON writeback_log(attempted_at DESC)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_writeback_log_message "
                 "ON writeback_log(message_id)")
    log.info("  created writeback_log (+ 2 indices)")


MIGRATIONS: list[Migration] = [
    Migration(1, "sender_group_patterns child table + backfill", _m001_sender_group_patterns),
    Migration(2, "rules.sender_group_id (match-by-id)", _m002_rules_sender_group_id),
    Migration(3, "OI5: rules both-null CHECK on legacy DBs", _m003_rules_both_null_check),
    Migration(4, "rules.updated_at (D52 staleness)", _m004_rules_updated_at),
    Migration(5, "classifications.reclassified_at (D52 audit)",
              _m005_classifications_reclassified_at),
    Migration(6, "bulk_operation_log (D60 executed-bulk audit)",
              _m006_bulk_operation_log),
    Migration(7, "writeback_log (D63 mailbox side-effect audit)",
              _m007_writeback_log),
]

CURRENT_VERSION = max(m.version for m in MIGRATIONS)


# ── Runner ────────────────────────────────────────────────────────────────────

def migrate(conn: sqlite3.Connection, *, db_path: Optional[Path] = None,
            backup: bool = True) -> list[int]:
    """Apply every migration newer than the database's `user_version`.

    Returns the list of versions applied (empty when already current). Each
    migration runs in its own transaction: on failure it rolls back, the version is
    left alone, and `MigrationError` is raised — so a retry starts from a known
    state rather than a partial one.
    """
    start = user_version(conn)
    pending = [m for m in MIGRATIONS if m.version > start]

    if not pending:
        log.info("Schema up to date at version %d — no migrations to run", start)
        return []

    fresh = not _has_mail(conn)
    log.info("Schema version %d → %d: %d migration(s) pending%s",
             start, CURRENT_VERSION, len(pending),
             " (fresh database)" if fresh else "")

    if backup and not fresh and db_path is not None:
        target = Path(f"{db_path}.pre-v{CURRENT_VERSION}.backup")
        try:
            # Checkpoint WAL first so the copied file is self-contained.
            conn.execute("PRAGMA wal_checkpoint(FULL)")
            shutil.copy2(db_path, target)
            log.info("Pre-migration backup written: %s", target)
        except Exception as exc:            # noqa: BLE001 — never migrate unbacked
            raise MigrationError(
                f"could not write the pre-migration backup to {target}: {exc}. "
                "Refusing to migrate an unbacked database."
            ) from exc

    applied: list[int] = []
    for m in pending:
        log.info("Applying migration %d — %s", m.version, m.description)
        try:
            conn.execute("BEGIN")
            m.apply(conn)
            _set_user_version(conn, m.version)
            conn.commit()
        except Exception as exc:            # noqa: BLE001 — reported, not swallowed
            conn.rollback()
            log.error("Migration %d FAILED (%s); rolled back, schema still at %d",
                      m.version, exc, user_version(conn))
            raise MigrationError(
                f"migration {m.version} ({m.description}) failed: {exc}"
            ) from exc
        applied.append(m.version)
        log.info("Migration %d applied; schema now at version %d",
                 m.version, user_version(conn))

    log.info("Migrations complete: applied %s; schema at version %d",
             applied, user_version(conn))
    return applied


def stamp_fresh(conn: sqlite3.Connection) -> bool:
    """Stamp a brand-new database at CURRENT_VERSION without running migrations.

    A database created by `schema.sql` in this release already HAS the current
    shape, so the migrations would be redundant at best. At worst they would be
    wrong: migration 1 backfills `sender_group_patterns` from the legacy
    `email_pattern` column, and on a freshly seeded DB the seed is the authority on
    what the patterns should be. Running data backfills against fresh seed rows is
    a category error, not an optimization.

    "Fresh" means: version 0 AND the current-release tables already exist AND there
    is no mail in the store. A pre-D53 database fails the table test; a live alpha
    database fails the mail test. Returns True if it stamped.
    """
    if user_version(conn) != 0:
        return False
    # The marker table for this release's schema. A pre-migration DB lacks it.
    if not _table_exists(conn, "sender_group_patterns"):
        return False
    if _has_mail(conn):
        return False

    _set_user_version(conn, CURRENT_VERSION)
    conn.commit()
    log.info("Fresh database stamped at schema version %d (no migrations needed)",
             CURRENT_VERSION)
    return True


def unmapped_group_rules(conn: sqlite3.Connection) -> list[dict]:
    """`matches_group` rules with no resolved `sender_group_id`, and why.

    Reported rather than guessed (the migration leaves them NULL). "no_match" means
    the value names no group; "ambiguous" means several groups' names normalize to
    the same string.
    """
    if not _column_exists(conn, "rules", "sender_group_id"):
        return []
    rows = conn.execute("""
        SELECT r.id, r.rule_name, r.value,
               (SELECT COUNT(*) FROM sender_groups g
                 WHERE LOWER(TRIM(g.group_name)) = LOWER(TRIM(r.value))) AS candidates
          FROM rules r
         WHERE r.operator = 'matches_group' AND r.sender_group_id IS NULL
         ORDER BY r.priority
    """).fetchall()
    return [{"id": r["id"], "rule_name": r["rule_name"], "value": r["value"],
             "candidates": r["candidates"],
             "reason": "ambiguous" if r["candidates"] > 1 else "no_match"}
            for r in rows]
