"""
POST /onboarding/people and sender-group pattern validation (D78–D82).

WHY THIS EXISTS
---------------
A fresh install cannot produce a Tier 1: both Tier 1 rules match sender groups,
and those ship with a placeholder that matches nobody (CLAUDE.md). The onboarding
Ask step fixes that by writing real members through this endpoint. These tests
pin that the members it writes actually MATCH — not merely that rows exist, and
not merely that "classification works", which the per-group fallback can satisfy
while the groups are inert.

THE SEED
--------
Every test seeds `seed.example.sql` EXPLICITLY. `init_db(seed=True)` prefers a
local `seed.sql` when one exists, and a test measured against that would pin a
rule set that ships to nobody. `test_seed_is_the_shipped_example` checks it.

SELF-TESTS
----------
`test_no_members_means_no_tier_1` is the control for every positive T1 test: the
same corpus with nothing written must give zero Tier 1, or a positive result
proves nothing. `test_without_reclassify_stored_mail_keeps_its_tier` disables the
endpoint's reclassify step and asserts the stored message stays out of Tier 1.
The normalization, consumer-domain and domain-side-glob guards were each proven
red by sabotaging the source during development (recorded with the commit).
"""

import pytest

from db import database
from db.database import (
    ClassificationRepo, Message, MessageRepo, RulesRepo, get_connection, init_db,
)
from api.app import create_app
from classification.reclassify import reclassify_one

ADDRESS = "dana@acme.example"
CORPUS = [
    ("m1", ADDRESS),
    ("m2", ADDRESS),
    ("m3", "someone@acme.example"),
    ("m4", "someone@notacme.example"),
    ("m5", "someone@mail.acme.example"),
    ("m6", "news@example.org"),
]


@pytest.fixture
def db_file(tmp_path, monkeypatch):
    path = tmp_path / "onboarding.db"
    # Force the shipped example seed, whatever is on this machine.
    monkeypatch.setattr(database, "_SEED_PATH", tmp_path / "no-local-seed.sql")
    init_db(path, seed=True).close()
    return path


@pytest.fixture
def client(db_file):
    app = create_app(connection_factory=lambda: get_connection(db_file))
    app.config.update(TESTING=True)
    return app.test_client()


def _conn(db_file):
    return get_connection(db_file)


def _ingest(db_file, corpus=CORPUS):
    """Store and classify each message with the CURRENT groups, as ingest does."""
    conn = _conn(db_file)
    try:
        for mid, sender in corpus:
            MessageRepo(conn).insert(Message(
                id=mid, account="acct", sender_email=sender,
                received_at="2026-10-01T09:00:00+00:00",
                ingested_at="2026-10-01T09:00:00+00:00",
                subject="status", body_plain="hello",
            ))
            reclassify_one(conn, MessageRepo(conn).get(mid))
    finally:
        conn.close()


def _tier(db_file, mid):
    conn = _conn(db_file)
    try:
        return ClassificationRepo(conn).get(mid)["urgency_tier"]
    finally:
        conn.close()


def _group(db_file, name):
    conn = _conn(db_file)
    try:
        return next(g for g in RulesRepo(conn).all_sender_groups()
                    if g["group_name"] == name)
    finally:
        conn.close()


def _snapshot(db_file):
    """Everything the endpoint could write, in a comparable form."""
    conn = _conn(db_file)
    try:
        groups = [tuple(r) for r in conn.execute(
            "SELECT * FROM sender_groups ORDER BY id")]
        rows = [tuple(r) for r in conn.execute(
            "SELECT * FROM sender_group_patterns ORDER BY id")]
        return groups, rows
    finally:
        conn.close()


def _post(client, body):
    return client.post("/onboarding/people", json=body)


# ── the seed ──────────────────────────────────────────────────────────────────

def test_seed_is_the_shipped_example(db_file):
    assert _group(db_file, "leadership")["patterns"] == ["boss@example.com"]
    assert _group(db_file, "family")["patterns"] == []


# ── address: positive and its control ─────────────────────────────────────────

def test_no_members_means_no_tier_1(db_file):
    _ingest(db_file)
    assert [m for m, _ in CORPUS if _tier(db_file, m) == 1] == []


def test_an_address_reaches_tier_1(client, db_file):
    r = _post(client, {"leadership": [ADDRESS]})
    assert r.status_code == 200, r.get_json()
    _ingest(db_file)
    t1 = [m for m, _ in CORPUS if _tier(db_file, m) == 1]
    assert t1 == ["m1", "m2"]


def test_write_creates_pattern_rows(client, db_file):
    _post(client, {"leadership": [ADDRESS], "family": ["kin@example.net"]})
    conn = _conn(db_file)
    try:
        rows = conn.execute(
            "SELECT g.group_name, p.pattern FROM sender_group_patterns p "
            "JOIN sender_groups g ON g.id = p.group_id "
            "WHERE g.group_name IN ('leadership', 'family') ORDER BY p.id"
        ).fetchall()
    finally:
        conn.close()
    assert [tuple(r) for r in rows] == [("leadership", ADDRESS),
                                       ("family", "kin@example.net")]


# ── placeholder and replace semantics ─────────────────────────────────────────

def test_placeholder_is_dropped(client, db_file):
    r = _post(client, {"leadership": [ADDRESS]})
    assert r.get_json()["groups"]["leadership"] == [ADDRESS]
    assert "boss@example.com" not in _group(db_file, "leadership")["patterns"]


def test_submitted_placeholder_is_dropped_alongside_a_valid_entry(client, db_file):
    r = _post(client, {"leadership": ["boss@example.com", ADDRESS]})
    assert r.status_code == 200
    assert r.get_json()["groups"]["leadership"] == [ADDRESS]
    assert _group(db_file, "leadership")["patterns"] == [ADDRESS]


def test_submitted_set_replaces_the_group(client, db_file):
    _post(client, {"leadership": ["a@acme.example", "b@acme.example"]})
    _post(client, {"leadership": ["a@acme.example", "c@acme.example"]})
    assert _group(db_file, "leadership")["patterns"] == ["a@acme.example",
                                                         "c@acme.example"]


@pytest.mark.parametrize("body", [
    {},
    {"leadership": [], "family": []},
    {"leadership": ["   "]},
    {"leadership": ["boss@example.com"]},     # only the placeholder ⇒ empty
])
def test_an_empty_request_writes_nothing(client, db_file, body):
    before = _snapshot(db_file)
    r = _post(client, body)
    assert r.status_code == 200
    assert r.get_json()["written"] is False
    assert r.get_json()["status"] == "unchanged"
    assert _snapshot(db_file) == before


def test_an_empty_group_is_left_unchanged(client, db_file):
    _post(client, {"family": ["kin@example.net"]})
    _post(client, {"leadership": [ADDRESS], "family": []})
    assert _group(db_file, "family")["patterns"] == ["kin@example.net"]


# ── normalization ─────────────────────────────────────────────────────────────

def test_bare_domain_is_stored_as_at_domain_and_matches_exactly(client, db_file):
    r = _post(client, {"leadership": ["acme.example"]})
    assert r.get_json()["groups"]["leadership"] == ["@acme.example"]
    _ingest(db_file)
    assert _tier(db_file, "m3") == 1                 # someone@acme.example
    assert _tier(db_file, "m4") != 1                 # someone@notacme.example
    assert _tier(db_file, "m5") != 1                 # someone@mail.acme.example


def test_legacy_email_pattern_is_normalized(client):
    r = client.post("/sender-groups", json={
        "group_name": "vendors", "urgency_floor": 3, "email_pattern": "acme.example"})
    assert r.status_code == 201, r.get_json()
    body = r.get_json()
    assert body["patterns"] == ["@acme.example"]
    assert body["email_pattern"] == "@acme.example"


def test_settings_put_is_normalized_and_validated(client, db_file):
    gid = _group(db_file, "leadership")["id"]
    r = client.put(f"/sender-groups/{gid}", json={"patterns": ["acme.example"]})
    assert r.status_code == 200
    assert r.get_json()["patterns"] == ["@acme.example"]
    r = client.put(f"/sender-groups/{gid}", json={"patterns": ["gmail.com"]})
    assert r.status_code == 400
    assert "'@gmail.com'" in r.get_json()["error"]


# ── format validation ─────────────────────────────────────────────────────────

@pytest.mark.parametrize("entry", ["not a pattern", "a@b@acme.example", "acme", "@"])
def test_unrecognized_forms_are_rejected_by_name(client, entry):
    r = _post(client, {"leadership": [entry]})
    assert r.status_code == 400
    assert f"'{entry}' is not a valid pattern" in r.get_json()["error"]


@pytest.mark.parametrize("entry", ["*@*", "*@*.org"])
def test_domain_side_globs_fail_format(client, entry):
    r = _post(client, {"leadership": [entry]})
    assert r.status_code == 400
    assert f"'{entry}' is not a valid pattern" in r.get_json()["error"]


@pytest.mark.parametrize("entry", ["*@acme.example", "j*@acme.example"])
def test_local_part_globs_are_accepted(client, entry):
    r = _post(client, {"leadership": [entry]})
    assert r.status_code == 200, r.get_json()
    assert r.get_json()["groups"]["leadership"] == [entry]


# ── consumer domains ──────────────────────────────────────────────────────────

@pytest.mark.parametrize("entry,stored", [
    ("gmail.com", "@gmail.com"),
    ("@gmail.com", "@gmail.com"),
    ("*@gmail.com", "*@gmail.com"),
])
def test_whole_consumer_domain_is_rejected(client, entry, stored):
    r = _post(client, {"family": [entry]})
    assert r.status_code == 400
    error = r.get_json()["error"]
    assert f"'{stored}' would match everyone at gmail.com" in error


def test_unanchored_consumer_glob_fails_format(client):
    r = _post(client, {"family": ["*gmail.com"]})
    assert r.status_code == 400
    assert "'*gmail.com' is not a valid pattern" in r.get_json()["error"]


def test_a_full_consumer_address_is_accepted(client):
    r = _post(client, {"family": ["someone@gmail.com"]})
    assert r.status_code == 200, r.get_json()
    assert r.get_json()["groups"]["family"] == ["someone@gmail.com"]


# ── atomicity ─────────────────────────────────────────────────────────────────

def test_one_invalid_entry_writes_nothing_and_names_it(client, db_file):
    before = _snapshot(db_file)
    r = _post(client, {"leadership": [ADDRESS], "family": ["kin@example.net", "gmail.com"]})
    assert r.status_code == 400
    body = r.get_json()
    assert body["invalid"] == [{"group": "family", "entry": "gmail.com",
                                "error": body["invalid"][0]["error"]}]
    assert "gmail.com" in body["error"]
    assert _snapshot(db_file) == before


# ── reclassify ────────────────────────────────────────────────────────────────

def test_stored_mail_is_reclassified(client, db_file):
    _ingest(db_file)
    assert _tier(db_file, "m1") != 1
    r = _post(client, {"leadership": [ADDRESS]})
    assert r.get_json()["reclassified"]["counted"] == len(CORPUS)
    assert _tier(db_file, "m1") == 1


def test_without_reclassify_stored_mail_keeps_its_tier(client, db_file, monkeypatch):
    import classification.reclassify as reclassify
    # A stand-in that re-tiers nothing, with the summary shape the endpoint reads.
    monkeypatch.setattr(reclassify, "reclassify_all", lambda conn: {
        "counted": 0, "changed": 0, "unchanged": 0, "errors": 0, "failed_ids": []})
    _ingest(db_file)
    _post(client, {"leadership": [ADDRESS]})
    assert _tier(db_file, "m1") != 1


def test_empty_store_is_not_reclassified(client):
    r = _post(client, {"leadership": [ADDRESS]})
    assert r.status_code == 200
    assert r.get_json()["status"] == "saved"
    assert r.get_json()["reclassified"] is None


def test_reclassify_failure_reports_saved_but_not_retiered(client, db_file, monkeypatch):
    """The groups commit BEFORE reclassify runs. A failure there must say so, not
    surface as a bare 500 that reads as "nothing was saved"."""
    import classification.reclassify as reclassify

    def boom(conn):
        raise RuntimeError("simulated")
    monkeypatch.setattr(reclassify, "reclassify_all", boom)
    _ingest(db_file)
    r = _post(client, {"leadership": [ADDRESS]})
    assert r.status_code == 207
    body = r.get_json()
    assert body["written"] is True
    assert body["status"] == "saved_not_retiered"
    assert "not re-tiered" in body["error"]
    assert _group(db_file, "leadership")["patterns"] == [ADDRESS]


def test_partial_reclassify_reports_partially_retiered(client, db_file, monkeypatch):
    import classification.reclassify as reclassify
    real = reclassify.reclassify_all

    def partial(conn):
        summary = real(conn)
        summary["errors"] = 1
        return summary
    monkeypatch.setattr(reclassify, "reclassify_all", partial)
    _ingest(db_file)
    r = _post(client, {"leadership": [ADDRESS]})
    assert r.status_code == 207
    assert r.get_json()["status"] == "saved_partially_retiered"
