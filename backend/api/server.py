"""
thresher API server entrypoint.

Usage:
    cd backend
    python3 -m api.server                 # serve on 127.0.0.1:8765
    python3 -m api.server --port 9000
    python3 -m api.server --host 0.0.0.0   # (not recommended; local-first by default)

Binds to localhost by default — this is a single-user, local-first tool (spec
§5.4: data processed/stored locally), so the API is not exposed off-device.
"""

import argparse
import logging

from db.database import init_db, default_db_path
from api.app import create_app


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="thresher-api")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )

    # Ensure the DB exists/seeded before serving (idempotent).
    init_db(default_db_path(), seed=True).close()

    app = create_app()
    # Provenance first, so the SHA is the first thing in the log for this process —
    # a stale runtime should be visible without having to suspect it.
    from provenance import log_startup_line
    log_startup_line("api")
    logging.getLogger("thresher").info(
        "Serving thresher API on http://%s:%d", args.host, args.port)
    app.run(host=args.host, port=args.port)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())