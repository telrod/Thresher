"""
scripts/db-fingerprint.py — hashes logical contents, not file bytes.

Phase 3 compares two runs of this on the daily database to show the test
session left it alone. That comparison is only worth something if the hash
moves when one row moves (or "equal" proves nothing) and holds still when the
file changes without the contents changing (or "different" is noise: the
database is in WAL mode, and a checkpoint or VACUUM rewrites bytes, not rows).

Both directions are asserted, each with its precondition checked first — the
row really changed, the bytes really changed — so neither test can pass by
doing nothing.
"""

import re
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

from db import database

_SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "db-fingerprint.py"


@pytest.fixture
def db(tmp_path, monkeypatch):
    path = tmp_path / "thresher.db"
    monkeypatch.setattr(database, "_SEED_PATH", tmp_path / "no-local-seed.sql")
    database.init_db(path, seed=True).close()
    return path


def _fingerprint(db: Path, script: Path = _SCRIPT) -> str:
    r = subprocess.run([sys.executable, str(script), "--db", str(db)],
                       capture_output=True, text=True, check=True)
    assert r.stderr == ""
    assert re.fullmatch(r"[0-9a-f]{64}\n", r.stdout), f"prints more than a hash: {r.stdout!r}"
    return r.stdout.strip()


def _files(db: Path) -> dict:
    return {p.name: p.read_bytes() for p in db.parent.glob(db.name + "*")}


def _stored(db: Path) -> dict:
    """The database and its WAL: what holds content. The -shm is excluded: it
    is SQLite's shared-memory index, which every WAL reader writes, read-only
    connections included, and it holds no rows.

    An empty WAL is dropped too, because it holds no rows either. A read-only
    open creates one when the last writer's close deleted it, which stock
    SQLite does and Apple's build does not. Keeping it made the no-write test
    fail on CI's interpreter while the script wrote nothing."""
    return {k: v for k, v in _files(db).items()
            if not k.endswith("-shm") and not (k.endswith("-wal") and v == b"")}


def test_database_is_in_wal_mode(db):
    # The reason file bytes cannot serve; if this changes, so does the premise.
    with sqlite3.connect(db) as conn:
        assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "wal"


def test_hash_changes_when_one_row_changes_and_returns_when_it_does(db):
    before = _fingerprint(db)
    conn = sqlite3.connect(db)
    (gid, notes), = conn.execute(
        "SELECT id, notes FROM sender_groups ORDER BY id LIMIT 1").fetchall()
    conn.execute("UPDATE sender_groups SET notes = ? WHERE id = ?", (notes + "!", gid))
    conn.commit()
    assert conn.total_changes == 1
    changed = _fingerprint(db)
    conn.execute("UPDATE sender_groups SET notes = ? WHERE id = ?", (notes, gid))
    conn.commit()
    conn.close()

    assert changed != before
    assert _fingerprint(db) == before, "same rows, same hash"


def test_hash_is_stable_across_a_noop_open_and_a_rewrite_of_the_file(db):
    before = _fingerprint(db)
    assert _fingerprint(db) == before, "two runs on the same file"

    # A plain read-write open that changes nothing.
    conn = sqlite3.connect(db)
    conn.execute("SELECT count(*) FROM messages").fetchone()
    conn.close()
    assert _fingerprint(db) == before

    # Rewrite the file without touching a row: the bytes must really move,
    # or this half of the test proves nothing.
    bytes_before = _stored(db)
    conn = sqlite3.connect(db)
    conn.execute("INSERT INTO preferences (key, value, updated_at) "
                 "VALUES ('fp-test', 'x', '2026-01-01')")
    conn.commit()
    conn.execute("DELETE FROM preferences WHERE key = 'fp-test'")
    conn.commit()
    conn.execute("VACUUM")
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()
    assert _stored(db) != bytes_before, "precondition: the file bytes changed"
    assert _fingerprint(db) == before


def test_fingerprinting_writes_no_stored_content(db):
    before = _stored(db)
    _fingerprint(db)
    assert _stored(db) == before


def test_the_no_write_check_catches_a_script_that_writes(db, tmp_path):
    """Verify the check above can fail, rather than trusting that it would."""
    source = _SCRIPT.read_text()
    opener = 'sqlite3.connect(f"{args.db.resolve().as_uri()}?mode=ro", uri=True)'
    assert opener in source, "the script's open changed; update this sabotage"
    writer = tmp_path / "db-fingerprint-writes.py"
    writer.write_text(source.replace(opener, (
        'sqlite3.connect(args.db)\n'
        '    conn.execute("INSERT INTO preferences (key, value, updated_at) '
        "VALUES ('fp-sabotage', 'x', '2026-01-01')\")\n"
        '    conn.commit()')))

    before = _stored(db)
    _fingerprint(db, writer)
    assert _stored(db) != before
