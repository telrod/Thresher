"""
Migration framework tests (D53) — the machinery, not just its first customer.

The framework's whole job is to be trustworthy against a database that already
holds a user's real mail, so these tests exercise the properties that matter when
that's true: a fresh DB doesn't run data backfills, a legacy DB does, running twice
changes nothing, and a failure leaves the schema and the data exactly as they were.

The "legacy DB" fixtures are built from the PRE-migration DDL on purpose. Testing
migrations against the current schema would prove nothing — the interesting case is
the shape that exists on disk in the wild.
"""

import sqlite3

import pytest

from db.database import get_connection, init_db
from db.migrations import (
    CURRENT_VERSION,
    MIGRATIONS,
    MigrationError,
    Migration,
    migrate,
    stamp_fresh,
    unmapped_group_rules,
    user_version,
)

# The sender_groups / rules DDL as it existed BEFORE D53: no child table, no
# sender_group_id, and (the OI5 debt) no both-null CHECK on rules.
_LEGACY_DDL = """
CREATE TABLE messages (
    id TEXT PRIMARY KEY, account TEXT NOT NULL, thread_id TEXT,
    sender_name TEXT, sender_email TEXT NOT NULL, subject TEXT,
    body_plain TEXT, body_html TEXT, received_at TEXT NOT NULL,
    ingested_at TEXT NOT NULL, raw_headers TEXT
);
CREATE TABLE classifications (
    message_id TEXT PRIMARY KEY REFERENCES messages(id),
    urgency_tier INTEGER NOT NULL CHECK (urgency_tier BETWEEN 1 AND 5),
    category TEXT NOT NULL CHECK (category IN ('work', 'personal', 'unknown')),
    triage_state TEXT NOT NULL DEFAULT 'new'
        CHECK (triage_state IN ('new', 'acknowledged', 'needs_action', 'done')),
    classified_at TEXT NOT NULL,
    rule_matches TEXT NOT NULL
);
CREATE TABLE sender_groups (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    group_name TEXT NOT NULL,
    email_pattern TEXT NOT NULL,
    urgency_floor INTEGER NOT NULL CHECK (urgency_floor BETWEEN 1 AND 5),
    notes TEXT
);
CREATE TABLE rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_name TEXT NOT NULL,
    priority INTEGER NOT NULL DEFAULT 100,
    enabled INTEGER NOT NULL DEFAULT 1,
    field TEXT NOT NULL,
    operator TEXT NOT NULL,
    value TEXT NOT NULL,
    set_tier INTEGER CHECK (set_tier BETWEEN 1 AND 5),
    set_category TEXT CHECK (set_category IN ('work', 'personal')),
    notes TEXT
);
"""


def _legacy_db(path, *, with_mail=True):
    """A v0 database in the pre-D53 shape, with the live DB's group/rule content."""
    conn = get_connection(path)
    conn.executescript(_LEGACY_DDL)
    conn.executemany(
        "INSERT INTO sender_groups (group_name, email_pattern, urgency_floor, notes) "
        "VALUES (?, ?, ?, NULL)",
        [("leadership", "boss@example.com", 1),
         ("family", "colleague@example.com", 1),
         ("close_colleagues", "*@example.com", 2),
         ("recruiters", "", 2),               # the empty-pattern placeholder case
         ("Me", "*@example.org", 1)],        # the mixed-case group (OI19/D55)
    )
    conn.executemany(
        "INSERT INTO rules (rule_name, priority, enabled, field, operator, value, "
        "set_tier, set_category, notes) VALUES (?, ?, 1, ?, ?, ?, ?, ?, NULL)",
        [("Leadership → T1", 1, "sender_group", "matches_group", "leadership", 1, "work"),
         ("Family → T1", 2, "sender_group", "matches_group", "family", 2, "personal"),
         ("Unknown sender → T4", 11, "sender_group", "matches_group", "unknown", 4, None),
         ("Testing - example.org", 12, "sender_group", "matches_group", "Me", 1, "personal")],
    )
    if with_mail:
        conn.execute(
            "INSERT INTO messages (id, account, sender_email, received_at, ingested_at) "
            "VALUES ('a:1', 'a', 's@x.com', '2026-01-01T00:00:00+00:00', "
            "'2026-01-01T00:00:00+00:00')"
        )
    conn.commit()
    return conn


# ── The version marker ────────────────────────────────────────────────────────

def test_a_fresh_db_lands_at_current_version_with_no_migrations_run(db_path):
    """`init_db` on a brand-new file produces the current shape from schema.sql, so
    it is STAMPED, not migrated. Running the data backfills against freshly seeded
    rows would be a category error: the seed is the authority on a fresh DB."""
    conn = init_db(db_path, seed=True)
    assert user_version(conn) == CURRENT_VERSION
    # And the current-release shape really is present.
    assert conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='sender_group_patterns'"
    ).fetchone()
    conn.close()


def test_stamp_fresh_refuses_a_database_that_holds_mail(db_path):
    """The guard that keeps a real store off the stamping path: a DB with mail is
    never 'fresh', even at version 0, so it must migrate rather than be stamped."""
    conn = _legacy_db(db_path, with_mail=True)
    assert user_version(conn) == 0
    assert stamp_fresh(conn) is False
    assert user_version(conn) == 0
    conn.close()


# ── The legacy → current path ────────────────────────────────────────────────

def test_a_legacy_v0_db_migrates_to_current(db_path):
    conn = _legacy_db(db_path)
    assert user_version(conn) == 0

    applied = migrate(conn, db_path=db_path, backup=False)

    assert applied == [m.version for m in MIGRATIONS]
    assert user_version(conn) == CURRENT_VERSION
    conn.close()


def test_migration_1_backfills_one_pattern_per_nonempty_group(db_path):
    conn = _legacy_db(db_path)
    migrate(conn, db_path=db_path, backup=False)

    rows = conn.execute(
        "SELECT g.group_name, p.pattern FROM sender_group_patterns p "
        "JOIN sender_groups g ON g.id = p.group_id ORDER BY g.group_name"
    ).fetchall()
    got = {(r["group_name"], r["pattern"]) for r in rows}
    assert got == {
        ("leadership", "boss@example.com"),
        ("family", "colleague@example.com"),
        ("close_colleagues", "*@example.com"),
        ("Me", "*@example.org"),
    }
    # The empty-pattern placeholder gets NO row — an invented pattern would be
    # worse than none (it matched nothing before the migration either).
    assert not any(name == "recruiters" for name, _ in got)
    conn.close()


def test_migration_1_does_not_drop_the_legacy_column(db_path):
    """Two-step deprecation: `email_pattern` survives this release so a rollback to
    the previous binary still classifies."""
    conn = _legacy_db(db_path)
    migrate(conn, db_path=db_path, backup=False)
    cols = [r["name"] for r in conn.execute("PRAGMA table_info(sender_groups)")]
    assert "email_pattern" in cols
    conn.close()


def test_migration_2_maps_unambiguous_rules_including_the_mixed_case_group(db_path):
    """The D55 payoff: "Me" resolves because the comparison is case-insensitive.
    Under the old case-sensitive matcher this rule was the one that never matched."""
    conn = _legacy_db(db_path)
    migrate(conn, db_path=db_path, backup=False)

    me_group = conn.execute(
        "SELECT id FROM sender_groups WHERE group_name = 'Me'").fetchone()["id"]
    rule = conn.execute(
        "SELECT sender_group_id FROM rules WHERE value = 'Me'").fetchone()
    assert rule["sender_group_id"] == me_group
    conn.close()


def test_migration_2_leaves_an_unresolvable_rule_null_and_reports_it(db_path):
    """'unknown' names no group. The migration must not guess — it leaves the id
    NULL and the rule is reported, which is how the live DB's rule 10 behaves."""
    conn = _legacy_db(db_path)
    migrate(conn, db_path=db_path, backup=False)

    row = conn.execute(
        "SELECT sender_group_id FROM rules WHERE value = 'unknown'").fetchone()
    assert row["sender_group_id"] is None

    reported = unmapped_group_rules(conn)
    assert [r["value"] for r in reported] == ["unknown"]
    assert reported[0]["reason"] == "no_match"
    assert reported[0]["candidates"] == 0
    conn.close()


def test_migration_2_flags_an_AMBIGUOUS_name_rather_than_picking_one(db_path):
    """Two groups whose names differ only by case both match one rule value. The
    migration must leave it NULL and call it ambiguous — picking either would be a
    silent guess about which group the user meant."""
    conn = _legacy_db(db_path)
    conn.execute("INSERT INTO sender_groups (group_name, email_pattern, urgency_floor) "
                 "VALUES ('ME', '*@other.example', 3)")
    conn.commit()

    migrate(conn, db_path=db_path, backup=False)

    row = conn.execute(
        "SELECT sender_group_id FROM rules WHERE value = 'Me'").fetchone()
    assert row["sender_group_id"] is None
    reported = {r["value"]: r for r in unmapped_group_rules(conn)}
    assert reported["Me"]["reason"] == "ambiguous"
    assert reported["Me"]["candidates"] == 2
    conn.close()


# ── OI5 ───────────────────────────────────────────────────────────────────────

def test_migration_3_adds_the_both_null_CHECK_and_preserves_every_rule(db_path):
    """OI5 closed through the same mechanism (DG3: 'two debts paid'). The rebuild
    must keep every rule, its id, and therefore its priority order."""
    conn = _legacy_db(db_path)
    before = conn.execute(
        "SELECT id, rule_name, priority, value FROM rules ORDER BY id").fetchall()
    assert "CHECK (set_tier IS NOT NULL OR set_category IS NOT NULL)" not in \
        conn.execute("SELECT sql FROM sqlite_master WHERE name='rules'").fetchone()["sql"]

    migrate(conn, db_path=db_path, backup=False)

    sql = conn.execute("SELECT sql FROM sqlite_master WHERE name='rules'").fetchone()["sql"]
    assert "CHECK (set_tier IS NOT NULL OR set_category IS NOT NULL)" in sql

    after = conn.execute(
        "SELECT id, rule_name, priority, value FROM rules ORDER BY id").fetchall()
    assert [tuple(r) for r in after] == [tuple(r) for r in before]

    # The constraint is live, not merely present in the DDL text.
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("INSERT INTO rules (rule_name, priority, enabled, field, operator, "
                     "value, set_tier, set_category) "
                     "VALUES ('no effect', 99, 1, 'subject', 'contains', 'x', NULL, NULL)")
    conn.close()


def test_migration_3_keeps_the_column_added_by_migration_2(db_path):
    """The rebuild must not silently drop a column an earlier migration added."""
    conn = _legacy_db(db_path)
    migrate(conn, db_path=db_path, backup=False)
    cols = [r["name"] for r in conn.execute("PRAGMA table_info(rules)")]
    assert "sender_group_id" in cols
    # …and the mapping survived the rebuild.
    assert conn.execute(
        "SELECT sender_group_id FROM rules WHERE value='Me'").fetchone()[0] is not None
    conn.close()


def test_migration_3_REFUSES_to_rebuild_when_a_rule_would_violate_the_CHECK(db_path):
    """A migration must never mutate or delete user data to make itself fit. With a
    both-null rule present the rebuild stops, and nothing is lost."""
    conn = _legacy_db(db_path)
    conn.execute("INSERT INTO rules (rule_name, priority, enabled, field, operator, "
                 "value, set_tier, set_category) "
                 "VALUES ('legacy no-effect', 50, 1, 'subject', 'contains', 'x', NULL, NULL)")
    conn.commit()
    rules_before = conn.execute("SELECT COUNT(*) FROM rules").fetchone()[0]

    with pytest.raises(MigrationError, match="both set_tier and set_category NULL"):
        migrate(conn, db_path=db_path, backup=False)

    # The offending rule is still there, untouched.
    assert conn.execute("SELECT COUNT(*) FROM rules").fetchone()[0] == rules_before
    # Migrations 1 and 2 committed; 3 did not, so the version stops just below it.
    assert user_version(conn) == 2
    conn.close()


# ── Idempotency and failure atomicity ────────────────────────────────────────

def test_running_migrate_twice_is_a_no_op(db_path):
    conn = _legacy_db(db_path)
    first = migrate(conn, db_path=db_path, backup=False)
    assert first

    patterns_after_first = conn.execute(
        "SELECT COUNT(*) FROM sender_group_patterns").fetchone()[0]

    second = migrate(conn, db_path=db_path, backup=False)
    assert second == [], "a second run must apply nothing"
    assert conn.execute("SELECT COUNT(*) FROM sender_group_patterns").fetchone()[0] \
        == patterns_after_first, "the backfill must not duplicate rows"
    assert user_version(conn) == CURRENT_VERSION
    conn.close()


def test_each_migration_body_is_independently_idempotent(db_path):
    """Belt and braces: the version check says 'don't run again', and the guards say
    'and if you did, no harm'. Applying every body a second time by hand must not
    raise or duplicate anything."""
    conn = _legacy_db(db_path)
    migrate(conn, db_path=db_path, backup=False)
    before = conn.execute("SELECT COUNT(*) FROM sender_group_patterns").fetchone()[0]

    for m in MIGRATIONS:
        m.apply(conn)          # no transaction wrapper: bodies must be safe alone
    conn.commit()

    assert conn.execute("SELECT COUNT(*) FROM sender_group_patterns").fetchone()[0] == before
    conn.close()


def test_a_failing_migration_rolls_back_and_leaves_the_version_alone(db_path, monkeypatch):
    """Atomicity is the property that makes this safe to point at real mail: a
    failure must leave the schema and the data exactly as they were, so the next
    startup retries from a known state instead of a partial one."""
    conn = _legacy_db(db_path)

    def _boom(c):
        c.execute("INSERT INTO sender_groups (group_name, email_pattern, urgency_floor) "
                  "VALUES ('halfway', '*@x.com', 3)")
        raise RuntimeError("simulated failure mid-migration")

    monkeypatch.setattr("db.migrations.MIGRATIONS",
                        [Migration(1, "deliberately failing", _boom)])

    with pytest.raises(MigrationError, match="simulated failure"):
        migrate(conn, db_path=db_path, backup=False)

    assert user_version(conn) == 0, "a failed migration must not advance the version"
    assert conn.execute(
        "SELECT COUNT(*) FROM sender_groups WHERE group_name='halfway'"
    ).fetchone()[0] == 0, "the partial write must have rolled back"
    conn.close()


def test_migrate_writes_a_backup_before_touching_a_db_with_mail(db_path):
    """Backup-before-migrate lives in the code, not in an operator's memory."""
    conn = _legacy_db(db_path, with_mail=True)
    migrate(conn, db_path=db_path)          # backup enabled (the default)
    conn.close()

    backup = db_path.parent / f"{db_path.name}.pre-v{CURRENT_VERSION}.backup"
    assert backup.exists(), f"expected a pre-migration backup at {backup}"
    # The backup is a readable database holding the pre-migration shape.
    b = sqlite3.connect(str(backup))
    assert b.execute("SELECT COUNT(*) FROM sender_groups").fetchone()[0] == 5
    assert b.execute(
        "SELECT COUNT(*) FROM sqlite_master WHERE name='sender_group_patterns'"
    ).fetchone()[0] == 0, "the backup must predate the migration"
    b.close()


def test_no_backup_is_written_for_a_fresh_database(db_path):
    """Nothing to protect, so no clutter: the backup exists for user data."""
    conn = _legacy_db(db_path, with_mail=False)
    migrate(conn, db_path=db_path)
    conn.close()
    assert not (db_path.parent / f"{db_path.name}.pre-v{CURRENT_VERSION}.backup").exists()


# ── Migrations 4 & 5 (D52) ───────────────────────────────────────────────────

def test_migration_4_adds_updated_at_and_backfills_NULL_deliberately(db_path):
    """D52 part D. Existing rows are left NULL on purpose: there is no record of
    when they were last edited, and stamping "now" would make every stored
    classification look instantly stale — the opposite of what the staleness copy
    is for. NULL reads as "not known to have changed"."""
    conn = _legacy_db(db_path)
    migrate(conn, db_path=db_path, backup=False)

    cols = [r["name"] for r in conn.execute("PRAGMA table_info(rules)")]
    assert "updated_at" in cols
    nulls = conn.execute(
        "SELECT COUNT(*) FROM rules WHERE updated_at IS NULL").fetchone()[0]
    total = conn.execute("SELECT COUNT(*) FROM rules").fetchone()[0]
    assert nulls == total, "pre-existing rules must NOT be given an invented edit time"
    conn.close()


def test_migration_5_adds_reclassified_at(db_path):
    """D52 invariant 3: one column, so the audit can say "reclassified <date>"
    without keeping versions."""
    conn = _legacy_db(db_path)
    migrate(conn, db_path=db_path, backup=False)
    cols = [r["name"] for r in conn.execute("PRAGMA table_info(classifications)")]
    assert "reclassified_at" in cols
    conn.close()


def test_migration_5_tolerates_a_missing_classifications_table(db_path):
    """A migration must not assume every table exists. Found by running: the first
    version raised OperationalError against a fixture without the table."""
    conn = get_connection(db_path)
    conn.executescript("""
        CREATE TABLE messages (id TEXT PRIMARY KEY, account TEXT NOT NULL,
            sender_email TEXT NOT NULL, received_at TEXT NOT NULL,
            ingested_at TEXT NOT NULL);
        CREATE TABLE sender_groups (id INTEGER PRIMARY KEY AUTOINCREMENT,
            group_name TEXT NOT NULL, email_pattern TEXT NOT NULL,
            urgency_floor INTEGER NOT NULL CHECK (urgency_floor BETWEEN 1 AND 5),
            notes TEXT);
        CREATE TABLE rules (id INTEGER PRIMARY KEY AUTOINCREMENT,
            rule_name TEXT NOT NULL, priority INTEGER NOT NULL DEFAULT 100,
            enabled INTEGER NOT NULL DEFAULT 1, field TEXT NOT NULL,
            operator TEXT NOT NULL, value TEXT NOT NULL,
            set_tier INTEGER, set_category TEXT, notes TEXT);
    """)
    conn.commit()

    migrate(conn, db_path=db_path, backup=False)   # must not raise
    assert user_version(conn) == CURRENT_VERSION
    conn.close()


def test_the_OI5_rebuild_carries_updated_at_when_it_runs_after_migration_4(db_path):
    """The rebuild enumerates optional columns from the live table rather than
    hardcoding them, so re-running it after a later migration can't silently drop
    that migration's column. Exercised by applying every body a second time."""
    conn = _legacy_db(db_path)
    migrate(conn, db_path=db_path, backup=False)
    for m in MIGRATIONS:
        m.apply(conn)                # migration 3 rebuilds again, now post-4
    conn.commit()

    cols = [r["name"] for r in conn.execute("PRAGMA table_info(rules)")]
    assert "updated_at" in cols, "the rebuild dropped a later migration's column"
    assert "sender_group_id" in cols
    conn.close()


# ── Seeding a BUNDLED install (D68) ──────────────────────────────────────────

def test_init_db_seeds_from_the_EXAMPLE_when_there_is_no_local_seed(tmp_path, monkeypatch):
    """The bundled app ships seed.example.sql and NEVER seed.sql — the real one
    holds actual contacts and is gitignored so it cannot travel inside an app
    bundle. So the example is the only seed a fresh install has.

    Found by running the bundled backend rather than by reading it: `init_db`
    read `seed.sql` unconditionally and a fresh install died with
    FileNotFoundError on first launch.
    """
    from db import database
    monkeypatch.setattr(database, "_SEED_PATH", tmp_path / "absent-seed.sql")
    conn = database.init_db(tmp_path / "t.db", seed=True)
    try:
        assert conn.execute("SELECT COUNT(*) FROM preferences").fetchone()[0] > 0, \
            "a bundled install came up with no preferences at all"
        assert conn.execute("SELECT COUNT(*) FROM rules").fetchone()[0] > 0, \
            "a bundled install came up with no rules — everything would tier to unknown"
    finally:
        conn.close()


def test_a_LOCAL_seed_still_wins_when_present(tmp_path, monkeypatch):
    """A developer's real seed must not be displaced by the example."""
    from db import database  # noqa: F811
    # A realistic local seed: the example's content plus a marker, so this tests
    # precedence rather than tripping over a seed that isn't viable.
    from pathlib import Path
    example = Path(database.__file__).parent / "seed.example.sql"
    marker = tmp_path / "local-seed.sql"
    marker.write_text(
        example.read_text()
        + "\nINSERT INTO preferences (key, value, updated_at) "
          "VALUES ('seed_marker', 'local', datetime('now'));\n")
    monkeypatch.setattr(database, "_SEED_PATH", marker)
    conn = database.init_db(tmp_path / "t.db", seed=True)
    try:
        row = conn.execute(
            "SELECT value FROM preferences WHERE key='seed_marker'").fetchone()
        assert row is not None and row[0] == "local", \
            "the example seed displaced a present local seed"
    finally:
        conn.close()


def test_NO_seed_at_all_RAISES_rather_than_coming_up_empty(tmp_path, monkeypatch):
    """A classifier with no rules tiers everything to `unknown`, which reads as a
    classification bug rather than a missing file. Fail loudly instead."""
    from db import database
    monkeypatch.setattr(database, "_SEED_PATH", tmp_path / "nope.sql")
    monkeypatch.setattr(database, "_SEED_EXAMPLE_PATH", tmp_path / "also-nope.sql")
    with pytest.raises(FileNotFoundError):
        database.init_db(tmp_path / "t.db", seed=True)


def test_a_FRESH_CLONE_seeds_a_USABLE_classifier_OI1(tmp_path, monkeypatch):
    """OI1's real question: not "is a file read?" but "does a fresh clone WORK?"

    The three tests above prove the fallback picks the right FILE. This proves
    the resulting database actually classifies mail, which is the thing OI1
    exists to protect and the thing a path test cannot see. It matters more than
    usual right now: the public-repo cutover build IS a fresh clone, so this is
    the author's own daily mail tool on day one, not a hypothetical stranger's.

    VERIFIED RED against the pre-D68 defect (`seed_path = _SEED_PATH`, reading
    seed.sql unconditionally): fails with
    `FileNotFoundError: .../absent-seed.sql` at init — which is precisely the
    first-launch crash OI1 describes, and it happens before any assertion here
    can run.

    Content findings recorded so a future seed edit cannot quietly regress them
    (measured 2026-09-02, migration-prep batch 1 Part A):
      - 4 sender groups, 10 rules, 6 preferences;
      - `sender_group_patterns` was EMPTY, working only through the per-group
        fallback to the deprecated `email_pattern` column. CONVERTED 2026-09-06
        (OI36) — see test_a_fresh_clone_has_real_sender_group_pattern_ROWS,
        which is the assertion this test cannot make: everything here passes
        just as well through the fallback, which is exactly why it would not
        have caught the column being dropped;
      - `family` and `recruiters` ship with NO pattern deliberately
        ("Placeholder: add ... via Settings"), so their rules match nothing
        until the user fills them in. That is a documented choice, not a stub.
    """
    from db import database
    from classification.reclassify import build_engine
    from classification.engine import MessageEnvelope

    monkeypatch.setattr(database, "_SEED_PATH", tmp_path / "absent-seed.sql")
    conn = database.init_db(tmp_path / "fresh.db", seed=True)
    try:
        engine = build_engine(conn)

        def tier(sender, subject):
            return engine.classify(MessageEnvelope(
                id="a:1", sender_email=sender, sender_name=None,
                subject=subject, body_plain=None)).urgency_tier

        # A seeded GROUP rule resolves through the legacy-pattern fallback.
        assert tier("boss@example.com", "status update") == 1, \
            "leadership → Tier 1 did not match; the group pattern fallback is broken"
        assert tier("colleague@example.com", "quick q") == 2

        # A seeded SUBJECT rule fires for a sender in no group at all — the case
        # that must work for a user who has not configured anything yet.
        assert tier("nobody@nowhere.net", "URGENT: server down") == 2
        assert tier("nobody@nowhere.net", "JIRA-123 assigned") == 3

        # And unmatched mail lands somewhere sane rather than erroring.
        assert tier("stranger@nowhere.net", "weekly newsletter") == 4

        # The classifier is genuinely rule-driven, not accidentally uniform: a
        # seed whose every message tiered the same would pass the assertions
        # above one at a time and still be useless.
        tiers = {tier("boss@example.com", "status update"),
                 tier("nobody@nowhere.net", "JIRA-123 assigned"),
                 tier("stranger@nowhere.net", "weekly newsletter")}
        assert len(tiers) >= 3, f"a fresh clone tiers everything alike: {tiers}"
    finally:
        conn.close()


def test_a_fresh_clone_has_real_sender_group_pattern_ROWS(tmp_path, monkeypatch):
    """OI36: membership must live in `sender_group_patterns`, not only in the
    deprecated `email_pattern` column.

    THE TEST ABOVE CANNOT CATCH THIS. It asserts classification works, and the
    per-group fallback in `all_sender_groups` satisfies that with an empty child
    table — so it would stay green through the exact change this guards against.
    D53 says `email_pattern` is dropped in a later migration; against an
    unconverted seed that drop leaves every group with zero patterns,
    `matches_group` matches nothing, and leadership/family mail silently stops
    being Tier 1. Measured 2026-09-02: blanking the column takes
    boss@example.com from T1 to T4, with no error anywhere.

    This ships into a public repo where a contributor will eventually read the
    deprecation comment and act on it.

    VERIFIED RED by emptying the child table (`DELETE FROM
    sender_group_patterns`) after seeding:
        AssertionError: a fresh clone has NO sender_group_patterns rows —
        every group depends on the deprecated email_pattern column (OI36)
        assert 0 > 0
    """
    from db import database

    monkeypatch.setattr(database, "_SEED_PATH", tmp_path / "absent-seed.sql")
    conn = database.init_db(tmp_path / "fresh.db", seed=True)
    try:
        total = conn.execute(
            "SELECT count(*) FROM sender_group_patterns").fetchone()[0]
        assert total > 0, (
            "a fresh clone has NO sender_group_patterns rows — every group "
            "depends on the deprecated email_pattern column (OI36)")

        # Every group that HAS a legacy pattern must have it as a row too.
        # (`family`/`recruiters` ship memberless on purpose, so this is keyed on
        # the column rather than asserting all four groups have rows.)
        missing = conn.execute("""
            SELECT g.group_name
            FROM sender_groups g
            WHERE trim(coalesce(g.email_pattern, '')) <> ''
              AND NOT EXISTS (SELECT 1 FROM sender_group_patterns p
                              WHERE p.group_id = g.id)
        """).fetchall()
        assert not missing, (
            f"groups whose membership exists ONLY in the deprecated column: "
            f"{[r[0] for r in missing]}")

        # And the rows say the same thing the column says — a conversion that
        # invented or dropped a member would pass the count check above.
        mismatched = conn.execute("""
            SELECT g.group_name, g.email_pattern
            FROM sender_groups g
            WHERE trim(coalesce(g.email_pattern, '')) <> ''
              AND NOT EXISTS (SELECT 1 FROM sender_group_patterns p
                              WHERE p.group_id = g.id
                                AND p.pattern = g.email_pattern)
        """).fetchall()
        assert not mismatched, f"converted patterns do not match the column: {mismatched}"
    finally:
        conn.close()


def test_the_legacy_email_pattern_fallback_still_works(tmp_path):
    """§4.3: the conversion must not remove the fallback.

    A database seeded the old way — membership only in `email_pattern`, no child
    rows — must still classify. This is the two-step deprecation being real:
    this order finishes the conversion, it does not begin the drop.
    """
    from db import database
    from db.database import RulesRepo

    conn = database.init_db(tmp_path / "legacy.db", seed=False)
    try:
        conn.execute("INSERT INTO sender_groups (group_name, email_pattern, "
                     "urgency_floor, notes) VALUES ('leadership', "
                     "'boss@example.com', 1, 'legacy-style row')")
        conn.commit()
        # No sender_group_patterns rows at all for this group.
        assert conn.execute("SELECT count(*) FROM sender_group_patterns").fetchone()[0] == 0

        groups = RulesRepo(conn).all_sender_groups()
        leadership = [g for g in groups if g["group_name"] == "leadership"][0]
        assert leadership["patterns"] == ["boss@example.com"], (
            "the per-group fallback to the deprecated column was removed — a "
            "database seeded before the conversion would lose every member")
    finally:
        conn.close()


def test_a_fresh_seed_TIERS_MAIL_ACROSS_MULTIPLE_TIERS(tmp_path, monkeypatch):
    """§5 verification: a fresh install must produce a VISIBLY TIERED list.

    THE ASSERTION IS TIER DISTRIBUTION, NOT "CLASSIFICATION WORKS". The
    2026-09-07 cold start ingested 15 real messages and classified all 15 as
    T4/unknown — the seeded rules targeted example.com and memberless groups, so
    nothing could match and everything fell to the engine default. A
    "classification ran" check passes cleanly against that, which is exactly how
    it shipped: the app worked and was useless.

    Fixtures are synthetic and generic — no real address, no real domain (§5.6).

    VERIFIED RED against the pre-fix seed: every message below lands in ONE
    tier, and `len(tiers) >= 3` fails with {4}.
    """
    from db import database
    from classification.reclassify import build_engine
    from classification.engine import MessageEnvelope

    monkeypatch.setattr(database, "_SEED_PATH", tmp_path / "absent-seed.sql")
    conn = database.init_db(tmp_path / "fresh.db", seed=True)
    try:
        engine = build_engine(conn)

        def tier(sender, subject):
            return engine.classify(MessageEnvelope(
                id="a:1", sender_email=sender, sender_name=None,
                subject=subject, body_plain=None)).urgency_tier

        # Time-sensitive machine mail — the case a new user most needs surfaced.
        assert tier("accounts@service.example", "Your verification code") == 2
        assert tier("alerts@service.example", "Security alert for your account") == 2
        assert tier("help@service.example", "Password reset requested") == 2
        assert tier("cal@service.example", "Invitation: Standup @ Mon 9am") == 2

        # Automated-looking senders — bulk-ish, deliberately NOT claimed as
        # "bulk mail" (the engine cannot see List-Unsubscribe).
        assert tier("no-reply@shop.example", "Your weekly digest") == 5
        assert tier("noreply@shop.example", "Sale ends today") == 5
        assert tier("digital-no-reply@shop.example", "Your order shipped") == 5, \
            "the contains-rule must catch prefixed no-reply addresses"
        assert tier("newsletter@news.example", "This week in tech") == 5

        # Ordinary direct mail from a human falls through to the default.
        ordinary = tier("someone@personal.example", "Lunch tomorrow?")

        tiers = {
            tier("accounts@service.example", "Your verification code"),
            tier("no-reply@shop.example", "Your weekly digest"),
            ordinary,
        }
        assert len(tiers) >= 3, (
            f"a fresh install does not visibly tier mail — everything landed in "
            f"{tiers}. This is the cold-start finding: the app works and is useless.")
    finally:
        conn.close()


def test_a_fresh_seed_CAN_ACTUALLY_ALERT(tmp_path, monkeypatch):
    """A fresh install must be able to alert on something.

    THE DEFECT THIS GUARDS: seeding `focus` gave a new user GUARANTEED SILENCE.
    Focus alerts on Tier 1 only, and both seeded T1 rules target sender groups
    that ship memberless (deliberately — ask/propose populate them later), so no
    T1 rule could fire and nothing could ever alert. The cold start confirmed it:
    22 real messages, zero notifications, and not one of them qualifying.

    This asserts the PAIRING, not the literal value: whatever mode is seeded must
    admit a tier the seeded rules can actually produce. Asserting
    `mode == 'catch-up'` alone would still pass if every T2 rule were deleted.

    VERIFIED RED by seeding 'focus': the reachable-tier set is {2, 3, 5} and the
    alerting set for focus is {1}, so the intersection is empty and this fails
    with the message below.
    """
    from db import database
    from classification.reclassify import build_engine
    from classification.engine import MessageEnvelope
    from notifications.service import _MODE_ALERT_TIERS

    monkeypatch.setattr(database, "_SEED_PATH", tmp_path / "absent-seed.sql")
    conn = database.init_db(tmp_path / "fresh.db", seed=True)
    try:
        mode = conn.execute(
            "SELECT value FROM preferences WHERE key='operating_mode'").fetchone()[0]
        alert_tiers = _MODE_ALERT_TIERS[mode]

        engine = build_engine(conn)

        def tier(sender, subject):
            return engine.classify(MessageEnvelope(
                id="a:1", sender_email=sender, sender_name=None,
                subject=subject, body_plain=None)).urgency_tier

        # Tiers a stranger's mail can actually reach with the seeded rules and
        # no configuration — memberless groups mean T1 is NOT among them.
        reachable = {
            tier("accounts@service.example", "Your verification code"),
            tier("nobody@nowhere.example", "JIRA-1 assigned"),
            tier("no-reply@shop.example", "Weekly digest"),
        }

        assert alert_tiers & reachable, (
            f"a fresh install cannot alert on anything: mode {mode!r} alerts on "
            f"tiers {sorted(alert_tiers)}, but the seeded rules can only reach "
            f"{sorted(reachable)} without configuration")
    finally:
        conn.close()
