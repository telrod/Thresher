#!/usr/bin/env python3
"""
Count stored sender-group patterns by what the D80–D82 validation would make of
them. COUNTS ONLY: this prints no pattern text and no group names, so its output
is safe to paste anywhere.

    scripts/count_group_patterns.py                      # the app's database
    scripts/count_group_patterns.py --db path/to/thresher.db

Validation applies on write only, so nothing here changes on its own. These
counts answer whether existing data needs a migration:

  - bare, inert today    no `@` and no `*`: compared against the WHOLE address,
                         so it never matches anything. A cross-cut: these also
                         appear in exactly one of the three lines below.
      of which domains   would be stored as `@domain` on next save
  - format rejected      would fail D81 on next save (after normalization)
      of which domain-
      side globs         a `*` after the `@`
  - consumer rejected    covers a whole shared mail domain (D82)
  - accepted             passes on next save, after normalization

format + consumer + accepted = total.

Patterns are read the way the engine reads them: `sender_group_patterns` rows,
plus the deprecated `email_pattern` column for a group with no rows.

The database is opened READ-ONLY.
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

from classification.patterns import normalize_pattern, pattern_error  # noqa: E402

DEFAULT_DB = Path.home() / "Library" / "Application Support" / "thresher" / "thresher.db"


def stored_patterns(conn: sqlite3.Connection) -> "list[tuple[str, str]]":
    """(source, pattern) for every pattern the engine would use."""
    rows: dict = {}
    for gid, pattern in conn.execute(
            "SELECT group_id, pattern FROM sender_group_patterns ORDER BY id"):
        rows.setdefault(gid, []).append(pattern)
    out = []
    for gid, legacy in conn.execute("SELECT id, email_pattern FROM sender_groups"):
        if gid in rows:
            out.extend(("rows", p) for p in rows[gid])
        elif (legacy or "").strip():
            out.append(("legacy", legacy))
    return out


def tally(patterns: "list[str]") -> dict:
    counts = {"total": 0, "bare": 0, "bare_domain": 0, "format": 0,
              "domain_glob": 0, "consumer": 0, "accepted": 0}
    for raw in patterns:
        p = (raw or "").strip()
        counts["total"] += 1
        if "@" not in p and "*" not in p:
            counts["bare"] += 1
        normalized = normalize_pattern(p)
        if normalized != p:
            counts["bare_domain"] += 1
        err = pattern_error(normalized)
        if err is None:
            counts["accepted"] += 1
        elif "is not a valid pattern" in err:
            counts["format"] += 1
            if "@" in p and "*" in p.split("@", 1)[1]:
                counts["domain_glob"] += 1
        else:
            counts["consumer"] += 1
    return counts


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--db", type=Path, default=DEFAULT_DB)
    args = ap.parse_args(argv)
    if not args.db.exists():
        print(f"no database at {args.db}", file=sys.stderr)
        return 1
    conn = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    try:
        found = stored_patterns(conn)
    finally:
        conn.close()

    for label, source in (("all", None), ("pattern rows", "rows"),
                          ("legacy email_pattern", "legacy")):
        c = tally([p for s, p in found if source is None or s == source])
        print(f"{label}: total {c['total']}")
        print(f"  format rejected        {c['format']}"
              f"   (of which domain-side globs: {c['domain_glob']})")
        print(f"  consumer rejected      {c['consumer']}")
        print(f"  accepted               {c['accepted']}"
              f"   (after normalization)")
        print(f"  bare, inert today      {c['bare']}"
              f"   (cross-cut; of which domains, normalized on next save: "
              f"{c['bare_domain']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
