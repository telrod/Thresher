"""
Shared pytest fixtures for the thresher backend.

Puts the backend root on sys.path so tests import the same way the modules
import each other (`from db.database import ...`), and provides an initialized
in-memory-ish SQLite database seeded with the default rules/sender groups.
"""

import sys
from pathlib import Path

import pytest

# backend/ is the import root (modules use flat top-level imports, no __init__.py).
_BACKEND_ROOT = Path(__file__).resolve().parents[1]
if str(_BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(_BACKEND_ROOT))

from db.database import init_db  # noqa: E402  (after sys.path setup)


@pytest.fixture
def db_path(tmp_path):
    """A throwaway on-disk SQLite path (file-backed so multiple connections share it)."""
    return tmp_path / "test_inbox.db"


@pytest.fixture
def conn(db_path):
    """An initialized + seeded connection to a fresh test database."""
    connection = init_db(db_path, seed=True)
    yield connection
    connection.close()


@pytest.fixture
def connection_factory(db_path):
    """
    Factory the pipeline uses to make one connection per thread. The schema is
    initialized once up front; subsequent calls just open new connections to the
    same file.
    """
    init_db(db_path, seed=True).close()
    from db.database import get_connection

    def factory():
        return get_connection(db_path)

    return factory