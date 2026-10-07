#!/usr/bin/env python3
"""
Print a fingerprint of a Thresher database's LOGICAL contents, and nothing else.

    scripts/db-fingerprint.py                      # the app's database
    scripts/db-fingerprint.py --db path/to/thresher.db

Phase 3 runs this on the daily database before switching to a test user and
again after, before the daily app is relaunched: equal output means the test
session did not touch it.

File bytes cannot serve: the database runs in WAL mode, so the same contents
can sit split between `thresher.db` and `thresher.db-wal` in different ways,
and a checkpoint rewrites the main file without changing a row. This hashes the
schema and every row of every table instead, in a fixed order.

The output is one SHA-256 hex digest. No table names, counts or row text are
printed, so it is safe to paste anywhere.

The database is opened READ-ONLY.
"""

from __future__ import annotations

import argparse
import hashlib
import sqlite3
import sys
from pathlib import Path

DEFAULT_DB = Path.home() / "Library" / "Application Support" / "thresher" / "thresher.db"


def _quote(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def fingerprint(conn: sqlite3.Connection) -> str:
    h = hashlib.sha256()

    def feed(*values) -> None:
        # repr() keeps types apart (1 vs '1' vs b'1' vs 1.0) and is exact for
        # floats; the separator keeps adjacent values from running together.
        h.update(repr(values).encode("utf-8"))
        h.update(b"\x00")

    schema = conn.execute(
        "SELECT type, name, tbl_name, sql FROM sqlite_master "
        "ORDER BY type, name").fetchall()          # the schema, not the rows
    for entry in schema:
        feed("schema", *entry)

    for kind, name, _tbl, _sql in schema:
        if kind != "table":
            continue
        ncols = len(conn.execute(f"PRAGMA table_info({_quote(name)})").fetchall())
        order = ", ".join(str(i) for i in range(1, ncols + 1))
        feed("table", name)
        # Iterate the cursor: one row in memory at a time, never fetchall().
        for row in conn.execute(f"SELECT * FROM {_quote(name)} ORDER BY {order}"):
            feed(*row)
    return h.hexdigest()


def main(argv: "list[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    args = parser.parse_args(argv)
    if not args.db.is_file():
        print(f"no database at {args.db}", file=sys.stderr)
        return 1
    conn = sqlite3.connect(f"{args.db.resolve().as_uri()}?mode=ro", uri=True)
    try:
        print(fingerprint(conn))
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
