"""
scripts/count_group_patterns.py — counts are right, and NO pattern text leaks.

The script is meant to be run against the maintainer's real database and its
output pasted into a report, so "prints no pattern text" is a privacy guarantee,
not a style choice. The leak check searches the output for every pattern it was
fed; it was proven red by making the script print one (recorded with the commit).
"""

import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

from db import database

_SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "count_group_patterns.py"

# Every fragment that must never appear in the output.
INSERTED = ["acme.example", "x@acme.example", "*@*.org", "not a pattern",
            "@gmail.com", "*@acme.example"]
LEGACY = "example.net"


@pytest.fixture
def fixture_db(tmp_path, monkeypatch):
    path = tmp_path / "counts.db"
    monkeypatch.setattr(database, "_SEED_PATH", tmp_path / "no-local-seed.sql")
    conn = database.init_db(path, seed=True)
    lid = conn.execute(
        "SELECT id FROM sender_groups WHERE group_name = 'leadership'").fetchone()[0]
    for p in INSERTED:
        conn.execute("INSERT INTO sender_group_patterns (group_id, pattern) "
                     "VALUES (?, ?)", (lid, p))
    # family has no pattern rows, so the engine falls back to this column.
    conn.execute("UPDATE sender_groups SET email_pattern = ? "
                 "WHERE group_name = 'family'", (LEGACY,))
    conn.commit()
    conn.close()
    return path


def _run(db):
    r = subprocess.run([sys.executable, str(_SCRIPT), "--db", str(db)],
                       capture_output=True, text=True, check=True)
    return r.stdout


def _section(out, label):
    lines = out.splitlines()
    i = lines.index(next(l for l in lines if l.startswith(f"{label}: ")))
    return "\n".join(lines[i:i + 5])


def test_counts(fixture_db):
    out = _run(fixture_db)
    # Rows: the seed's 2 placeholders + the 6 inserted. Legacy: family only.
    rows = _section(out, "pattern rows")
    assert "total 8" in rows
    assert "format rejected        2   (of which domain-side globs: 1)" in rows
    assert "consumer rejected      1" in rows
    assert "accepted               5" in rows
    assert "bare, inert today      2" in rows
    legacy = _section(out, "legacy email_pattern")
    assert "total 1" in legacy
    assert "bare, inert today      1   (cross-cut; of which domains, normalized on next save: 1)" in legacy


def test_prints_no_pattern_text(fixture_db):
    out = _run(fixture_db).lower()
    for fragment in INSERTED + [LEGACY, "boss@", "colleague@", "leadership", "family"]:
        assert fragment.lower() not in out, f"output leaked {fragment!r}"


def _dump(db):
    """The database's logical content. Compared instead of file bytes because the
    store runs in WAL mode: a write lands in `-wal` and reaches the main file only
    at a checkpoint, so a byte comparison of the main file misses it (measured)."""
    conn = sqlite3.connect(str(db))
    try:
        return list(conn.iterdump())
    finally:
        conn.close()


def test_does_not_modify_the_database(fixture_db):
    before = _dump(fixture_db)
    _run(fixture_db)
    assert _dump(fixture_db) == before
