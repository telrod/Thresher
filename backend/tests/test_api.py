"""
Tests for api.app — Flask endpoints via the test client against a seeded DB.

The app factory takes a connection_factory; we point it at the same file-backed
test DB the `connection_factory` fixture initializes.
"""

import pytest

from db.database import (
    Classification, ClassificationRepo, Message, MessageRepo, PreferencesRepo,
    get_connection, init_db,
)
from api.app import create_app


@pytest.fixture
def client(connection_factory, db_path):
    # Seed a couple of classified messages to exercise list/get/triage/explain.
    conn = get_connection(db_path)
    MessageRepo(conn).insert(Message(
        id="acct:1", account="acct", sender_email="boss@example.com",
        sender_name="Dana Whitfield", subject="Q3 numbers",
        body_plain="please review", received_at="2026-06-15T10:00:00+00:00",
        ingested_at="2026-06-15T10:00:00+00:00",
    ))
    ClassificationRepo(conn).upsert(Classification(
        message_id="acct:1", urgency_tier=1, category="work", triage_state="new",
        classified_at="2026-06-15T10:00:00+00:00",
        rule_matches=[{"rule_id": 1, "rule_name": "Leadership → Tier 1",
                       "field": "sender_group", "operator": "matches_group",
                       "value": "leadership"}],
    ))
    MessageRepo(conn).insert(Message(
        id="acct:2", account="acct", sender_email="spam@x.com", sender_name=None,
        subject="WIN A PRIZE", body_plain="click here",
        received_at="2026-06-15T09:00:00+00:00",
        ingested_at="2026-06-15T09:00:00+00:00",
    ))
    ClassificationRepo(conn).upsert(Classification(
        message_id="acct:2", urgency_tier=4, category="unknown", triage_state="new",
        classified_at="2026-06-15T09:00:00+00:00", rule_matches=[],
    ))
    conn.close()

    app = create_app(connection_factory=lambda: get_connection(db_path))
    app.config.update(TESTING=True)
    return app.test_client()


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ok"


def test_list_default_order_groups_by_tier(client):
    """Default list ordering groups by urgency tier (spec §4.1.1), not pure
    recency. (Renamed from the old test_list_messages_newest_first, whose
    'received_at DESC' assumption no longer holds after the tier-grouped reshape.)
    Here acct:1 is Tier 1 and acct:2 is Tier 4, so acct:1 leads."""
    r = client.get("/messages")
    assert r.status_code == 200
    data = r.get_json()
    assert [m["id"] for m in data] == ["acct:1", "acct:2"]
    assert data[0]["urgency_tier"] == 1


def test_list_filter_by_tier(client):
    r = client.get("/messages?tier=4")
    data = r.get_json()
    assert len(data) == 1 and data[0]["id"] == "acct:2"


def test_list_filter_by_triage_state(client):
    assert len(client.get("/messages?triage_state=new").get_json()) == 2
    assert client.get("/messages?triage_state=done").get_json() == []


def test_get_message_includes_body_and_rules(client):
    r = client.get("/messages/acct:1")
    assert r.status_code == 200
    data = r.get_json()
    assert data["body_plain"] == "please review"
    assert data["rule_matches"][0]["value"] == "leadership"


def test_get_missing_message_404(client):
    assert client.get("/messages/nope").status_code == 404


def test_search(client):
    r = client.get("/messages/search?q=prize")
    data = r.get_json()
    assert len(data) == 1 and data[0]["id"] == "acct:2"


def test_search_requires_query(client):
    assert client.get("/messages/search").status_code == 400


def test_explain_endpoint_returns_reasoning(client):
    r = client.get("/messages/acct:1/explain")
    assert r.status_code == 200
    data = r.get_json()
    assert data["urgency_tier"] == 1
    assert "Leadership" in data["explanation"]
    assert data["rule_matches"][0]["field"] == "sender_group"


def test_triage_update(client):
    r = client.post("/messages/acct:1/triage", json={"state": "acknowledged"})
    assert r.status_code == 200
    assert r.get_json()["triage_state"] == "acknowledged"
    # persisted
    assert client.get("/messages/acct:1").get_json()["triage_state"] == "acknowledged"


def test_triage_rejects_invalid_state(client):
    r = client.post("/messages/acct:1/triage", json={"state": "bogus"})
    assert r.status_code == 400


def test_triage_missing_message_404(client):
    r = client.post("/messages/nope/triage", json={"state": "done"})
    assert r.status_code == 404


def test_preferences_get_and_set(client):
    r = client.get("/preferences")
    assert r.status_code == 200
    assert "operating_mode" in r.get_json()

    r = client.put("/preferences/operating_mode", json={"value": "catch-up"})
    assert r.status_code == 200
    assert client.get("/preferences").get_json()["operating_mode"] == "catch-up"


def test_preferences_put_requires_value(client):
    assert client.put("/preferences/foo", json={}).status_code == 400


# ── poll_interval_minutes bounds (polish batch 2, Part A) ────────────────────
#
# PUT /preferences/<key> stored ANY string, so `poll_interval_minutes: 0` would
# hand the poller a spin loop and `-5` a negative wait. The UI enforces 1–15,
# but a pref endpoint that trusts its client is a pref endpoint that will
# eventually be handed junk by curl, an old build, or a future screen.

def test_poll_interval_accepts_both_edges_of_the_supported_range(client):
    for value in ("1", "15"):
        r = client.put("/preferences/poll_interval_minutes", json={"value": value})
        assert r.status_code == 200, f"{value} min should be accepted: {r.get_json()}"
        assert client.get("/preferences").get_json()["poll_interval_minutes"] == value


def test_poll_interval_rejects_zero_which_would_SPIN_the_poller(client):
    r = client.put("/preferences/poll_interval_minutes", json={"value": "0"})
    assert r.status_code == 400
    assert "1" in r.get_json()["error"] and "15" in r.get_json()["error"], \
        "the error must name the supported range, not just refuse"


def test_poll_interval_rejects_a_negative_interval(client):
    assert client.put("/preferences/poll_interval_minutes",
                      json={"value": "-5"}).status_code == 400


def test_poll_interval_rejects_above_the_ceiling(client):
    assert client.put("/preferences/poll_interval_minutes",
                      json={"value": "16"}).status_code == 400


def test_poll_interval_rejects_junk_rather_than_storing_it(client):
    """An unparseable value reaches _resolve_poll_interval, which warns and falls
    back to the default — so the setting would silently not apply."""
    for value in ("", "abc", "5 minutes", "1.5.2"):
        assert client.put("/preferences/poll_interval_minutes",
                          json={"value": value}).status_code == 400, \
            f"junk value {value!r} was stored"


def test_a_rejected_poll_interval_does_not_change_the_stored_value(client):
    """E12's lesson, applied here: validate the value that would be STORED, and
    leave the previous one intact when it fails."""
    client.put("/preferences/poll_interval_minutes", json={"value": "7"})
    client.put("/preferences/poll_interval_minutes", json={"value": "0"})
    assert client.get("/preferences").get_json()["poll_interval_minutes"] == "7"


def test_other_preferences_are_not_subject_to_the_poll_interval_bounds(client):
    """The validation is per-key; a generic pref must still accept any string."""
    assert client.put("/preferences/some_other_key",
                      json={"value": "0"}).status_code == 200


# ── Retrieval-window size preview (backfill-scope §6.4) ──────────────────────
#
# `POST /accounts/preview` answers "how much mail would each window bring in?"
# BEFORE the credential is stored, so the number can inform the choice rather
# than explain it afterwards. Read-only (P5) — the same discipline as
# /accounts/verify, which is the other pre-commit question this app asks.

def _preview_app(db_path, counts=None, error=None):
    """An app whose IMAP layer answers count_since() from a dict of window→count."""
    class _FakeClient:
        def __init__(self, account):
            self.account = account
        def count_since(self, since, *, password=None):
            assert password, "the preview must pass the password explicitly"
            if error is not None:
                raise error
            return (counts or {}).get(since if since is None else "cutoff", 0)
    init_db(db_path, seed=True).close()
    app = create_app(connection_factory=lambda: get_connection(db_path),
                     imap_client_factory=_FakeClient)
    app.config.update(TESTING=True)
    return app.test_client()


def test_account_preview_returns_a_count_per_window(db_path):
    client = _preview_app(db_path, counts={None: 3311, "cutoff": 42})
    r = client.post("/accounts/preview", json={"account": "a@x.example",
                                               "app_password": "pw"})
    assert r.status_code == 200, r.get_json()
    body = r.get_json()
    assert set(body["counts"]) == {"1w", "1m", "3m", "everything"}
    assert body["counts"]["everything"] == 3311


def test_account_preview_requires_a_password_it_does_not_echo(db_path):
    """The preview happens BEFORE the credential is stored, so it must take the
    password in the body — and must never return it."""
    client = _preview_app(db_path, counts={None: 1, "cutoff": 1})
    assert client.post("/accounts/preview",
                       json={"account": "a@x.example"}).status_code == 400
    r = client.post("/accounts/preview", json={"account": "a@x.example",
                                               "app_password": "hunter2"})
    assert "hunter2" not in r.get_data(as_text=True)


def test_account_preview_requires_an_account(db_path):
    client = _preview_app(db_path)
    assert client.post("/accounts/preview",
                       json={"app_password": "pw"}).status_code == 400


def test_account_preview_STORES_NOTHING(db_path):
    """P5 — a preview is a question, not a commitment. It must not write the
    Keychain, and must not leave a retrieval_cutoff behind for an account the
    user may never connect."""
    client = _preview_app(db_path, counts={None: 5, "cutoff": 2})
    client.post("/accounts/preview", json={"account": "ghost@x.example",
                                           "app_password": "pw"})
    prefs = client.get("/preferences").get_json()
    assert not any(k.startswith("retrieval_cutoff:") for k in prefs), \
        "a preview wrote a retrieval cutoff"
    assert "ghost@x.example" not in client.get("/accounts").get_json()["accounts"]


def test_account_preview_reports_a_bad_credential_rather_than_zero(db_path):
    """Zero would read as "your mailbox is empty" at exactly the moment the user
    is deciding how much to import — the most misleading possible answer."""
    from ingestion.imap_client import ImapError
    client = _preview_app(db_path, error=ImapError("auth failed"))
    r = client.post("/accounts/preview", json={"account": "a@x.example",
                                               "app_password": "pw"})
    assert r.status_code == 502
    assert "counts" not in r.get_json()


def test_digest_preview_lists_tier3(connection_factory, db_path):
    # Seed a Tier 3 message received recently so it falls in the 24h window.
    from datetime import datetime, timezone
    from db.database import get_connection
    conn = get_connection(db_path)
    now = datetime.now(timezone.utc).isoformat()
    MessageRepo(conn).insert(Message(
        id="t3:1", account="acct", sender_email="newsletter@x.com", sender_name="News",
        subject="Weekly roundup", received_at=now, ingested_at=now,
    ))
    ClassificationRepo(conn).upsert(Classification(
        message_id="t3:1", urgency_tier=3, category="work", triage_state="new",
        classified_at=now, rule_matches=[],
    ))
    conn.close()

    app = create_app(connection_factory=lambda: get_connection(db_path))
    app.config.update(TESTING=True)
    c = app.test_client()
    r = c.get("/digest/preview")
    assert r.status_code == 200
    data = r.get_json()
    assert data["count"] == 1
    assert data["messages"][0]["id"] == "t3:1"


def test_digest_run_sends(client):
    # The seeded client has no Tier 3 messages, so a run reports nothing to send
    # rather than erroring (and triggers no real notification in tests).
    r = client.post("/digest/run", json={})
    assert r.status_code == 200
    data = r.get_json()
    assert data["sent"] is False
    assert data["message_count"] == 0


def test_rules_endpoint(client):
    r = client.get("/rules")
    assert r.status_code == 200
    data = r.get_json()
    assert isinstance(data["rules"], list) and len(data["rules"]) > 0
    assert isinstance(data["sender_groups"], list)


# ── Phase C: list/search shape + ordering ───────────────────────────────────

def test_list_tier_beats_recency(connection_factory, db_path):
    """A more-recent low-urgency message sorts *below* an older high-urgency one.

    NARROWED BY D57: this is no longer the general rule, and the case that still
    holds it up here is the Tier 1 exemption — `o:oldhigh` is a T1, so it is
    band 0 at any age. Across recency bands a fresh low tier now DOES outrank a
    stale high tier (see test_d57_fresh_low_tier_outranks_stale_high_tier); tier
    remains the primary key only *within* a band. Kept because the T1-vs-newer
    ordering it pins is exactly the invariant D57 had to preserve."""
    conn = get_connection(db_path)
    # newer but Tier 5
    MessageRepo(conn).insert(Message(
        id="o:newlow", account="acct", sender_email="news@x.com",
        subject="newsletter", body_plain="...", received_at="2026-06-16T10:00:00+00:00",
        ingested_at="2026-06-16T10:00:00+00:00",
    ))
    ClassificationRepo(conn).upsert(Classification(
        message_id="o:newlow", urgency_tier=5, category="unknown", triage_state="new",
        classified_at="2026-06-16T10:00:00+00:00", rule_matches=[],
    ))
    # older but Tier 1
    MessageRepo(conn).insert(Message(
        id="o:oldhigh", account="acct", sender_email="boss@example.com",
        subject="urgent", body_plain="...", received_at="2026-06-15T10:00:00+00:00",
        ingested_at="2026-06-15T10:00:00+00:00",
    ))
    ClassificationRepo(conn).upsert(Classification(
        message_id="o:oldhigh", urgency_tier=1, category="work", triage_state="new",
        classified_at="2026-06-15T10:00:00+00:00", rule_matches=[],
    ))
    conn.close()
    app = create_app(connection_factory=lambda: get_connection(db_path))
    app.config.update(TESTING=True)
    c = app.test_client()
    ids = [m["id"] for m in c.get("/messages").get_json()]
    assert ids.index("o:oldhigh") < ids.index("o:newlow")


def test_list_unclassified_sorts_first_no_error(connection_factory, db_path):
    """A message persisted before classification (NULL classification, per the P1
    ordering guarantee) sorts first under SQLite ASC and does not error."""
    conn = get_connection(db_path)
    MessageRepo(conn).insert(Message(
        id="u:1", account="acct", sender_email="pending@x.com", subject="just arrived",
        body_plain="not yet classified", received_at="2026-06-15T08:00:00+00:00",
        ingested_at="2026-06-15T08:00:00+00:00",
    ))
    # deliberately NO classification row
    conn.close()
    app = create_app(connection_factory=lambda: get_connection(db_path))
    app.config.update(TESTING=True)
    c = app.test_client()
    r = c.get("/messages")
    assert r.status_code == 200
    data = r.get_json()
    assert data[0]["id"] == "u:1"            # NULL tier sorts first
    assert data[0]["urgency_tier"] is None   # serialized as null, not a crash


def test_list_excludes_bodies_includes_preview(client):
    """The list view never hauls full bodies but does carry a preview."""
    data = client.get("/messages").get_json()
    row = next(m for m in data if m["id"] == "acct:1")
    assert "body_plain" not in row
    assert "body_html" not in row
    assert row["preview"] == "please review"


def test_search_includes_preview_excludes_bodies_E10_guard(client):
    """E10 regression: search runs a *different* query than list but feeds the same
    serializer — it MUST select `preview` (and still omit bodies)."""
    data = client.get("/messages/search?q=prize").get_json()
    assert len(data) == 1
    row = data[0]
    assert row["id"] == "acct:2"
    assert "preview" in row and row["preview"] == "click here"
    assert "body_plain" not in row and "body_html" not in row


# ── Phase C: detail /explain fold ────────────────────────────────────────────

def test_detail_includes_explanation(client):
    """Detail folds in the human-readable explanation (P3, spec §4.1.2)."""
    data = client.get("/messages/acct:1").get_json()
    assert data["explanation"] is not None
    assert "Urgency tier: 1" in data["explanation"]
    assert "Leadership" in data["explanation"]


def test_detail_unclassified_explanation_null_not_500(connection_factory, db_path):
    """An unclassified message returns explanation: null, never a 500."""
    conn = get_connection(db_path)
    MessageRepo(conn).insert(Message(
        id="u:2", account="acct", sender_email="pending@x.com", subject="arrived",
        body_plain="body", received_at="2026-06-15T08:00:00+00:00",
        ingested_at="2026-06-15T08:00:00+00:00",
    ))
    conn.close()
    app = create_app(connection_factory=lambda: get_connection(db_path))
    app.config.update(TESTING=True)
    c = app.test_client()
    r = c.get("/messages/u:2")
    assert r.status_code == 200
    assert r.get_json()["explanation"] is None


# ── Phase C: rules CRUD + validation ─────────────────────────────────────────

def _valid_rule_body(**overrides):
    body = {
        "rule_name": "Test rule", "priority": 40, "enabled": True,
        "field": "subject", "operator": "contains", "value": "invoice",
        "set_tier": 2,
    }
    body.update(overrides)
    return body


def test_rule_create_appears_in_list_then_update_then_delete(client):
    # create
    r = client.post("/rules", json=_valid_rule_body())
    assert r.status_code == 201
    rule_id = r.get_json()["id"]
    assert rule_id is not None

    # appears in GET /rules
    rules = client.get("/rules").get_json()["rules"]
    assert any(rule["id"] == rule_id for rule in rules)

    # update
    r = client.put(f"/rules/{rule_id}", json={"set_tier": 3})
    assert r.status_code == 200
    assert r.get_json()["set_tier"] == 3

    # delete → gone
    assert client.delete(f"/rules/{rule_id}").status_code == 200
    assert client.put(f"/rules/{rule_id}", json={"set_tier": 1}).status_code == 404
    assert client.delete(f"/rules/{rule_id}").status_code == 404


def test_rule_create_invalid_field(client):
    r = client.post("/rules", json=_valid_rule_body(field="bogus_field"))
    assert r.status_code == 400


def test_rule_create_invalid_operator(client):
    r = client.post("/rules", json=_valid_rule_body(operator="regex"))
    assert r.status_code == 400


def test_rule_create_invalid_tier(client):
    r = client.post("/rules", json=_valid_rule_body(set_tier=9))
    assert r.status_code == 400


def test_rule_create_invalid_category(client):
    r = client.post("/rules", json=_valid_rule_body(set_tier=None, set_category="urgent"))
    assert r.status_code == 400


def test_rule_create_requires_an_effect(client):
    """Create with neither set_tier nor set_category → 400 (must do something)."""
    body = _valid_rule_body()
    body.pop("set_tier")
    r = client.post("/rules", json=body)
    assert r.status_code == 400


def test_rule_update_missing_404(client):
    assert client.put("/rules/999999", json={"set_tier": 2}).status_code == 404


def test_rule_update_omit_both_leaves_intact(client):
    """PUT that omits set_tier/set_category just edits other fields and is allowed
    (the existing effect is left intact)."""
    rule_id = client.post("/rules", json=_valid_rule_body()).get_json()["id"]
    r = client.put(f"/rules/{rule_id}", json={"rule_name": "renamed"})
    assert r.status_code == 200
    body = r.get_json()
    assert body["rule_name"] == "renamed"
    assert body["set_tier"] == 2  # untouched


def test_rule_update_both_null_in_one_request_rejected(client):
    """Setting BOTH set_tier and set_category to null in one request → 400; a rule
    that can match must still do something (P3-friendly)."""
    rule_id = client.post("/rules", json=_valid_rule_body()).get_json()["id"]
    r = client.put(f"/rules/{rule_id}", json={"set_tier": None, "set_category": None})
    assert r.status_code == 400
    # clearing only ONE of them is still allowed (the other still has an effect)
    ok = client.put(f"/rules/{rule_id}", json={"set_tier": None, "set_category": "work"})
    assert ok.status_code == 200


def test_rule_update_clearing_last_effect_rejected_post_merge(client):
    """Post-merge guard: when one field is ALREADY null in the DB, a patch that
    nulls the only remaining effect must be rejected (400) — even though the
    request body sends just one null. This is the case the earlier
    'request explicitly sends both null' check would have missed."""
    # Create a rule whose only effect is set_category (set_tier omitted → NULL).
    body = _valid_rule_body(set_category="work")
    body.pop("set_tier")
    rule_id = client.post("/rules", json=body).get_json()["id"]
    # Sanity: tier is null, category is the lone effect.
    created = next(r for r in client.get("/rules").get_json()["rules"] if r["id"] == rule_id)
    assert created["set_tier"] is None and created["set_category"] == "work"
    # Patch nulls the only remaining effect → merged result is both-null → 400.
    r = client.put(f"/rules/{rule_id}", json={"set_category": None})
    assert r.status_code == 400
    # The rule's effect is unchanged by the rejected write.
    after = next(r for r in client.get("/rules").get_json()["rules"] if r["id"] == rule_id)
    assert after["set_category"] == "work"


# ── Phase C: sender-group CRUD + floor bounds ────────────────────────────────

def _valid_group_body(**overrides):
    body = {"group_name": "vendors", "email_pattern": "*@acme.com", "urgency_floor": 3}
    body.update(overrides)
    return body


def test_sender_group_create_update_delete(client):
    r = client.post("/sender-groups", json=_valid_group_body())
    assert r.status_code == 201
    gid = r.get_json()["id"]
    assert gid is not None

    groups = client.get("/rules").get_json()["sender_groups"]
    assert any(g["id"] == gid for g in groups)

    r = client.put(f"/sender-groups/{gid}", json={"urgency_floor": 2})
    assert r.status_code == 200
    assert r.get_json()["urgency_floor"] == 2

    assert client.delete(f"/sender-groups/{gid}").status_code == 200
    assert client.put(f"/sender-groups/{gid}", json={"urgency_floor": 1}).status_code == 404
    assert client.delete(f"/sender-groups/{gid}").status_code == 404


def test_sender_group_floor_bounds(client):
    assert client.post("/sender-groups", json=_valid_group_body(urgency_floor=0)).status_code == 400
    assert client.post("/sender-groups", json=_valid_group_body(urgency_floor=6)).status_code == 400


def test_sender_group_requires_pattern(client):
    assert client.post("/sender-groups", json=_valid_group_body(email_pattern="  ")).status_code == 400


def test_sender_group_update_floor_bounds(client):
    gid = client.post("/sender-groups", json=_valid_group_body()).get_json()["id"]
    assert client.put(f"/sender-groups/{gid}", json={"urgency_floor": 9}).status_code == 400


# ── Phase C: thread fetch ─────────────────────────────────────────────────────

def test_thread_fetch_returns_only_thread_ordered_asc(connection_factory, db_path):
    """GET /threads/<id> returns just that thread's messages, oldest→newest."""
    conn = get_connection(db_path)
    for n, ts in [(1, "2026-06-15T12:00:00+00:00"), (2, "2026-06-15T10:00:00+00:00"),
                  (3, "2026-06-15T11:00:00+00:00")]:
        MessageRepo(conn).insert(Message(
            id=f"th:{n}", account="acct", thread_id="THREAD-A",
            sender_email="a@b.com", subject=f"msg {n}", body_plain="x",
            received_at=ts, ingested_at=ts,
        ))
        ClassificationRepo(conn).upsert(Classification(
            message_id=f"th:{n}", urgency_tier=3, category="work", triage_state="new",
            classified_at=ts, rule_matches=[],
        ))
    # a message in a different thread that must NOT appear
    MessageRepo(conn).insert(Message(
        id="th:other", account="acct", thread_id="THREAD-B", sender_email="a@b.com",
        subject="other", body_plain="x", received_at="2026-06-15T09:00:00+00:00",
        ingested_at="2026-06-15T09:00:00+00:00",
    ))
    conn.close()
    app = create_app(connection_factory=lambda: get_connection(db_path))
    app.config.update(TESTING=True)
    c = app.test_client()
    data = c.get("/threads/THREAD-A").get_json()
    assert [m["id"] for m in data] == ["th:2", "th:3", "th:1"]  # received_at ASC


# ── Phase C: /accounts/verify (login test, mocked) ───────────────────────────

def test_verify_requires_account(client):
    assert client.post("/accounts/verify", json={}).status_code == 400


def _verify(client, ok, reason):
    """POST /accounts/verify with GmailImapClient.verify_login mocked."""
    from unittest import mock
    with mock.patch("ingestion.imap_client.GmailImapClient.verify_login",
                    return_value=(ok, reason)):
        return client.post("/accounts/verify", json={"account": "you@example.com"})


def test_verify_success(client):
    r = _verify(client, True, "ok")
    assert r.status_code == 200
    assert r.get_json() == {"ok": True, "reason": "ok"}


def test_verify_auth_failed(client):
    r = _verify(client, False, "auth_failed")
    assert r.get_json() == {"ok": False, "reason": "auth_failed"}


def test_verify_network_error(client):
    r = _verify(client, False, "network_error")
    assert r.get_json() == {"ok": False, "reason": "network_error"}


def test_verify_missing_credential(client):
    r = _verify(client, False, "missing_credential")
    assert r.get_json() == {"ok": False, "reason": "missing_credential"}


# ── Wave 1: store / list / disconnect accounts (Keychain, mocked) ─────────────
# The account routes import the keychain helpers inside the function body, so we
# patch them at their definition site (ingestion.keychain.*).

def test_store_account_writes_keychain_and_never_echoes_password(client):
    from unittest import mock
    with mock.patch("ingestion.keychain.store_secret") as store:
        r = client.post("/accounts", json={
            "account": "you@example.com", "app_password": "abcd efgh ijkl mnop",
        })
    assert r.status_code == 201
    body = r.get_json()
    # D61 added `retrieval_cutoff`. Null here because no window was requested —
    # which is the safe default: an account connected without one retrieves
    # everything, exactly as before the feature existed.
    assert body == {"account": "you@example.com", "stored": True,
                    "retrieval_cutoff": None}
    # P5/secret-hygiene: the secret must not appear anywhere in the response.
    assert "abcd efgh ijkl mnop" not in r.get_data(as_text=True)
    # The secret WAS handed to the keychain layer (positionally: account, secret).
    store.assert_called_once_with("you@example.com", "abcd efgh ijkl mnop")


def test_store_account_requires_account(client):
    r = client.post("/accounts", json={"app_password": "x"})
    assert r.status_code == 400


def test_store_account_requires_password(client):
    r = client.post("/accounts", json={"account": "you@example.com"})
    assert r.status_code == 400
    r = client.post("/accounts", json={"account": "you@example.com", "app_password": ""})
    assert r.status_code == 400


def test_store_account_keychain_failure_502(client):
    from unittest import mock
    from ingestion.keychain import KeychainError
    with mock.patch("ingestion.keychain.store_secret", side_effect=KeychainError("boom")):
        r = client.post("/accounts", json={"account": "t@g.com", "app_password": "p"})
    assert r.status_code == 502


def test_list_accounts(client):
    from unittest import mock
    with mock.patch("ingestion.keychain.list_accounts",
                    return_value=["a@gmail.com", "b@gmail.com"]):
        r = client.get("/accounts")
    assert r.status_code == 200
    assert r.get_json() == {"accounts": ["a@gmail.com", "b@gmail.com"]}


def test_list_accounts_keychain_unavailable_503(client):
    from unittest import mock
    from ingestion.keychain import KeychainError
    with mock.patch("ingestion.keychain.list_accounts", side_effect=KeychainError("no security")):
        r = client.get("/accounts")
    assert r.status_code == 503


def test_disconnect_account_deletes_keychain_entry(client):
    from unittest import mock
    with mock.patch("ingestion.keychain.delete_secret", return_value=True) as dele:
        r = client.delete("/accounts/you@example.com")
    assert r.status_code == 200
    assert r.get_json() == {"disconnected": "you@example.com"}
    dele.assert_called_once_with("you@example.com")


def test_disconnect_account_missing_404(client):
    from unittest import mock
    with mock.patch("ingestion.keychain.delete_secret", return_value=False):
        r = client.delete("/accounts/nope@gmail.com")
    assert r.status_code == 404


def test_disconnect_does_not_touch_messages_P1(client):
    """Disconnecting an account removes only the credential — stored messages
    remain retrievable (P1)."""
    from unittest import mock
    with mock.patch("ingestion.keychain.delete_secret", return_value=True):
        client.delete("/accounts/acct")
    # the seeded messages are still listable
    assert len(client.get("/messages").get_json()) == 2


# ── Wave 1: read disabled rules (gap #4) ─────────────────────────────────────

def test_rules_hides_disabled_by_default_but_include_disabled_shows_them(client):
    # Create a disabled rule.
    rid = client.post("/rules", json=_valid_rule_body(enabled=False)).get_json()["id"]
    # Default GET /rules omits it (engine-visible set only).
    default_ids = [r["id"] for r in client.get("/rules").get_json()["rules"]]
    assert rid not in default_ids
    # include_disabled surfaces it, with enabled as the 0/1 int.
    all_rules = client.get("/rules?include_disabled=true").get_json()["rules"]
    row = next(r for r in all_rules if r["id"] == rid)
    assert row["enabled"] == 0
    # Sanity: an enabled rule shows in both.
    rid2 = client.post("/rules", json=_valid_rule_body(enabled=True)).get_json()["id"]
    assert any(r["id"] == rid2 for r in client.get("/rules").get_json()["rules"])
    assert any(r["id"] == rid2 for r in
               client.get("/rules?include_disabled=true").get_json()["rules"])


def test_rules_include_disabled_accepts_truthy_spellings(client):
    rid = client.post("/rules", json=_valid_rule_body(enabled=False)).get_json()["id"]
    for spelling in ("true", "1", "yes", "TRUE"):
        ids = [r["id"] for r in client.get(f"/rules?include_disabled={spelling}").get_json()["rules"]]
        assert rid in ids, spelling


# ── Wave 1: typed notification preferences (gap #5) ──────────────────────────

def test_notification_prefs_defaults_when_unset(client):
    r = client.get("/preferences/notifications")
    assert r.status_code == 200
    assert r.get_json() == {
        "quiet_hours_start": None, "quiet_hours_end": None, "audio_alerts": False,
    }


def test_notification_prefs_roundtrip_typed(client):
    r = client.put("/preferences/notifications", json={
        "quiet_hours_start": "22:00", "quiet_hours_end": "07:30", "audio_alerts": True,
    })
    assert r.status_code == 200
    assert r.get_json() == {
        "quiet_hours_start": "22:00", "quiet_hours_end": "07:30", "audio_alerts": True,
    }
    # Persisted + still typed on re-read.
    again = client.get("/preferences/notifications").get_json()
    assert again["audio_alerts"] is True and again["quiet_hours_start"] == "22:00"


def test_notification_prefs_patch_semantics(client):
    client.put("/preferences/notifications", json={"audio_alerts": True})
    r = client.put("/preferences/notifications", json={"quiet_hours_start": "09:00"})
    body = r.get_json()
    assert body["quiet_hours_start"] == "09:00"
    assert body["audio_alerts"] is True  # untouched by the second patch


def test_notification_prefs_normalizes_and_unsets_time(client):
    # zero-pads / normalizes
    r = client.put("/preferences/notifications", json={"quiet_hours_start": "9:5"})
    assert r.get_json()["quiet_hours_start"] == "09:05"
    # empty string clears it back to null
    r = client.put("/preferences/notifications", json={"quiet_hours_start": ""})
    assert r.get_json()["quiet_hours_start"] is None


def test_notification_prefs_rejects_bad_time(client):
    assert client.put("/preferences/notifications",
                      json={"quiet_hours_start": "25:00"}).status_code == 400
    assert client.put("/preferences/notifications",
                      json={"quiet_hours_end": "12:60"}).status_code == 400
    assert client.put("/preferences/notifications",
                      json={"quiet_hours_start": "noon"}).status_code == 400


def test_notification_prefs_rejects_non_bool_audio(client):
    assert client.put("/preferences/notifications",
                      json={"audio_alerts": "true"}).status_code == 400
    assert client.put("/preferences/notifications",
                      json={"audio_alerts": 1}).status_code == 400


def test_notification_prefs_rejects_unknown_key(client):
    assert client.put("/preferences/notifications",
                      json={"bogus": "x"}).status_code == 400


def test_notification_prefs_coexist_with_generic_preferences(client):
    """The typed surface writes into the same preferences table the generic
    endpoint reads (P4: one source of truth)."""
    client.put("/preferences/notifications", json={"audio_alerts": True})
    assert client.get("/preferences").get_json().get("audio_alerts") == "true"


# ── Amendment 1 (D44): batch rule reorder — PUT /rules/reorder ───────────────
# Position is priority; the server renumbers dense (1..N) in one transaction.
# Priority is ordinal only (see §1 grep) so a dense rank is a faithful reorder.

def _rule_ids(client, include_disabled=True):
    """The current rule ids in stored priority order (what the editor fetches)."""
    q = "?include_disabled=true" if include_disabled else ""
    return [r["id"] for r in client.get(f"/rules{q}").get_json()["rules"]]


def _rule_priorities(client):
    """Map of id → stored priority across ALL rules (enabled and disabled)."""
    return {r["id"]: r["priority"] for r in client.get("/rules?include_disabled=true").get_json()["rules"]}


def test_reorder_happy_path_dense_1_to_n(client):
    """Reorder N rules → priorities are EXACTLY 1..N in the requested order
    (assert dense, not merely sorted)."""
    ids = _rule_ids(client)
    new_order = list(reversed(ids))
    r = client.put("/rules/reorder", json={"ordered_ids": new_order})
    assert r.status_code == 200
    returned = [rule["id"] for rule in r.get_json()["rules"]]
    # Response is already re-sorted by the new priority (GET shape, ORDER BY priority).
    assert returned == new_order
    prio = _rule_priorities(client)
    for index, rule_id in enumerate(new_order):
        assert prio[rule_id] == index + 1        # dense, contiguous, 1-based


def test_reorder_includes_disabled_rules_keeping_their_slot(client):
    """A disabled rule participates in the order and keeps its requested slot."""
    ids = _rule_ids(client)
    disabled_id = ids[0]
    client.put(f"/rules/{disabled_id}", json={"enabled": False})
    # It must still appear in the include_disabled fetch.
    assert disabled_id in _rule_ids(client, include_disabled=True)
    # Put it in the middle of the order; it must land at that exact dense slot.
    remaining = [i for i in ids if i != disabled_id]
    mid = len(remaining) // 2
    new_order = remaining[:mid] + [disabled_id] + remaining[mid:]
    r = client.put("/rules/reorder", json={"ordered_ids": new_order})
    assert r.status_code == 200
    assert _rule_priorities(client)[disabled_id] == mid + 1


def test_reorder_malformed_missing_ordered_ids_400(client):
    assert client.put("/rules/reorder", json={}).status_code == 400


def test_reorder_malformed_duplicate_id_400(client):
    ids = _rule_ids(client)
    r = client.put("/rules/reorder", json={"ordered_ids": ids + [ids[0]]})
    assert r.status_code == 400
    assert ids[0] in r.get_json().get("duplicate", [])


def test_reorder_malformed_unknown_id_is_stale_not_malformed(client):
    """An unknown-but-integer id is a membership problem (409), not a shape
    problem — shape is only about type/uniqueness."""
    ids = _rule_ids(client)
    r = client.put("/rules/reorder", json={"ordered_ids": ids[:-1] + [999999]})
    assert r.status_code == 409


def test_reorder_malformed_non_integer_id_400(client):
    ids = _rule_ids(client)
    r = client.put("/rules/reorder", json={"ordered_ids": [str(i) for i in ids]})
    assert r.status_code == 400


def test_reorder_stale_set_omitted_rule_409_names_missing(client):
    """Client omits a rule that still exists → 409, error body names it as missing."""
    ids = _rule_ids(client)
    r = client.put("/rules/reorder", json={"ordered_ids": ids[1:]})
    assert r.status_code == 409
    assert ids[0] in r.get_json().get("missing", [])


def test_reorder_stale_set_extra_deleted_id_409_names_unexpected(client):
    """A rule is deleted between fetch and reorder; the now-dangling id → 409,
    named as unexpected (E12: state invariant checked against the live table)."""
    ids = _rule_ids(client)
    deleted = ids[-1]
    client.delete(f"/rules/{deleted}")
    r = client.put("/rules/reorder", json={"ordered_ids": ids})
    assert r.status_code == 409
    assert deleted in r.get_json().get("unexpected", [])


def test_reorder_atomicity_rejected_leaves_every_priority_unchanged(client):
    """A rejected reorder mutates NOTHING — read back all priorities and assert
    they are byte-for-byte what they were before the failed call."""
    before = _rule_priorities(client)
    ids = _rule_ids(client)
    # Stale set (omit one) → must roll back with zero side effects.
    r = client.put("/rules/reorder", json={"ordered_ids": ids[1:]})
    assert r.status_code == 409
    assert _rule_priorities(client) == before


def test_reorder_route_does_not_hit_update_rule(client):
    """Route isolation: PUT /rules/reorder must not be captured by
    PUT /rules/<int:rule_id>. update_rule would 400 on the missing rule fields /
    404 on a non-int id; reorder returns its own 200/400/409 with a `rules` key.
    A malformed reorder returns 400 WITH a reorder-shaped body (never a
    rule-validation error), proving it reached reorder_rules, not update_rule."""
    r = client.put("/rules/reorder", json={"ordered_ids": _rule_ids(client)})
    assert r.status_code == 200
    assert "rules" in r.get_json()            # reorder response shape, not a single rule


def test_create_rule_appends_at_max_plus_one(client):
    """POST /rules without an explicit priority lands at MAX(priority)+1."""
    current_max = max(_rule_priorities(client).values())
    r = client.post("/rules", json={
        "rule_name": "appended rule", "field": "subject",
        "operator": "contains", "value": "zzz", "set_tier": 3,
    })
    assert r.status_code == 201
    assert r.get_json()["priority"] == current_max + 1


def test_create_rule_honors_explicit_priority(client):
    """An explicit priority in the create body is still honored (the next reorder
    normalizes everything dense anyway)."""
    r = client.post("/rules", json={
        "rule_name": "explicit prio", "field": "subject",
        "operator": "contains", "value": "yyy", "set_tier": 3, "priority": 7,
    })
    assert r.status_code == 201
    assert r.get_json()["priority"] == 7


# ── GET /notifications feed (D45) ─────────────────────────────────────────────

def test_notifications_feed_returns_only_app_rows(connection_factory, db_path):
    """The feed returns rows the APP should deliver (delivery=app), never the
    osascript rows the user already saw — and advances a cursor past all rows."""
    import json
    from db.database import get_connection
    conn = get_connection(db_path)
    # Seed a message so the FK is satisfiable, then three log rows by hand.
    MessageRepo(conn).insert(Message(
        id="acct:9", account="acct", sender_email="a@b.com", sender_name="A",
        subject="hi", body_plain="x", received_at="2026-07-12T00:00:00+00:00",
        ingested_at="2026-07-12T00:00:00+00:00",
    ))
    def _log(mid, delivery):
        conn.execute(
            "INSERT INTO notification_log (message_id, notification_type, sent_at, payload) VALUES (?,?,?,?)",
            (mid, "tier1_alert", "2026-07-12T00:00:00+00:00",
             json.dumps({"title": "t", "text": "x", "delivery": delivery})),
        )
    _log("acct:9", "osascript")   # backend delivered — NOT in feed
    _log("acct:9", "app")         # app should deliver — in feed
    conn.execute(                 # a quiet-hours defer (no delivery tag) — NOT in feed
        "INSERT INTO notification_log (message_id, notification_type, sent_at, payload) VALUES (?,?,?,?)",
        ("acct:9", "tier2_alert", "2026-07-12T00:00:00+00:00", json.dumps({"title": "t", "text": "x"})),
    )
    conn.commit(); conn.close()

    app = create_app(connection_factory=lambda: get_connection(db_path))
    app.config.update(TESTING=True)
    c = app.test_client()

    body = c.get("/notifications").get_json()
    assert len(body["notifications"]) == 1
    assert body["notifications"][0]["notification_type"] == "tier1_alert"
    assert body["notifications"][0]["message_id"] == "acct:9"
    # cursor advanced past ALL three rows (so osascript/defer rows aren't re-scanned).
    assert body["cursor"] == 3

    # since=cursor → nothing new.
    body2 = c.get(f"/notifications?since={body['cursor']}").get_json()
    assert body2["notifications"] == []
    assert body2["cursor"] == 3


# ── E19 regression: sender-override invariant record in rule_matches ──────────


def test_detail_and_explain_carry_nil_rule_id_override_record_E19(connection_factory, db_path):
    """E19 (dogfood defect batch 1, Part A): the sender-override invariant record
    is appended with rule_id: null — it is an invariant, not a rule. Both
    serializer shapes that carry rule_matches (the detail's folded payload and
    /explain) must deliver that record with every key the Swift RuleMatch
    decodes, rule_id explicitly null (not absent), alongside a normal int-id
    rule record. Built through the REAL engine loaded from the DB — not a
    hand-mocked payload — so this breaks if the engine's record shape drifts."""
    from classification.engine import ClassificationEngine, MessageEnvelope
    from db.database import RulesRepo

    app = create_app(connection_factory=lambda: get_connection(db_path))
    app.config.update(TESTING=True)
    c = app.test_client()

    # Config through the real API: a floor-2 group plus a T4 content rule the
    # invariant will overrule. (Seeded groups can't interfere: their patterns
    # are exact other emails or empty, and empty patterns never match.)
    r = c.post("/sender-groups", json={
        "group_name": "vip-e19", "email_pattern": "*@e19.example", "urgency_floor": 2,
    })
    assert r.status_code == 201
    r = c.post("/rules", json={
        "rule_name": "E19 digest → T4", "field": "subject", "operator": "contains",
        "value": "e19-digest", "set_tier": 4, "enabled": True,
    })
    assert r.status_code == 201

    # Classify through the real engine, loaded the way the pipeline loads it.
    conn = get_connection(db_path)
    repo = RulesRepo(conn)
    engine = ClassificationEngine(rules=repo.all_enabled(),
                                  sender_groups=repo.all_sender_groups())
    envelope = MessageEnvelope(id="acct:e19", sender_email="aunt@e19.example",
                               sender_name="Aunt", subject="e19-digest weekly",
                               body_plain="hello")
    result = engine.classify(envelope)

    # The invariant fired: rule said T4, floor-2 group overrode it.
    assert result.urgency_tier == 2
    overrides = [m for m in result.rule_matches if m["rule_id"] is None]
    assert len(overrides) == 1
    assert overrides[0]["overrode_tier"] == 4
    assert any(isinstance(m["rule_id"], int) for m in result.rule_matches)

    # Persist through the real repos (what the pipeline's _process does).
    MessageRepo(conn).insert(Message(
        id="acct:e19", account="acct", sender_email="aunt@e19.example",
        sender_name="Aunt", subject="e19-digest weekly", body_plain="hello",
        received_at="2026-07-16T10:00:00+00:00",
        ingested_at="2026-07-16T10:00:00+00:00",
    ))
    ClassificationRepo(conn).upsert(Classification(
        message_id="acct:e19", urgency_tier=result.urgency_tier,
        category=result.category, triage_state="new",
        classified_at=result.classified_at, rule_matches=result.rule_matches,
    ))
    conn.close()

    # Both rule_matches-bearing serializer shapes (E10: they are per-query).
    detail = c.get("/messages/acct%3Ae19").get_json()
    explain = c.get("/messages/acct%3Ae19/explain").get_json()
    for payload in (detail, explain):
        matches = payload["rule_matches"]
        nils = [m for m in matches if m["rule_id"] is None]
        assert len(nils) == 1
        rec = nils[0]
        # Every key the Swift RuleMatch decodes, with rule_id present-and-null.
        assert "rule_id" in rec and rec["rule_id"] is None
        assert set(rec) >= {"rule_name", "field", "value", "overrode_tier"}
        assert rec["overrode_tier"] == 4
        # The normal record still carries an int id next to it.
        assert any(isinstance(m["rule_id"], int) for m in matches)
    # explain() itself must render the override record (P3), not choke on it.
    assert "vip-e19" in detail["explanation"]


# ── D48 (closes OI4): rfc822_message_id on the detail serializer ──────────────


def test_detail_exposes_rfc822_message_id_D48(connection_factory, db_path):
    """D48: the detail payload folds in the RFC822 Message-ID from raw_headers —
    what the client's Gmail-web deep link needs. Detail ONLY (E10 guard: list
    and search rows never grow the key); absent header → explicit null so the
    client keeps the control disabled instead of fabricating a link."""
    conn = get_connection(db_path)
    MessageRepo(conn).insert(Message(
        id="acct:d48", account="acct", sender_email="a@example.com",
        subject="with header", body_plain="x",
        received_at="2026-07-17T10:00:00+00:00",
        ingested_at="2026-07-17T10:00:00+00:00",
        raw_headers={"Message-ID": "<d48-probe@example.com>", "Subject": "with header"},
    ))
    MessageRepo(conn).insert(Message(
        id="acct:d48-none", account="acct", sender_email="b@example.com",
        subject="no header", body_plain="y",
        received_at="2026-07-17T10:01:00+00:00",
        ingested_at="2026-07-17T10:01:00+00:00",
        raw_headers={"Subject": "no header"},
    ))
    conn.close()

    app = create_app(connection_factory=lambda: get_connection(db_path))
    app.config.update(TESTING=True)
    c = app.test_client()

    detail = c.get("/messages/acct%3Ad48").get_json()
    assert detail["rfc822_message_id"] == "<d48-probe@example.com>"

    none = c.get("/messages/acct%3Ad48-none").get_json()
    assert "rfc822_message_id" in none and none["rfc822_message_id"] is None

    # E10 guard: the list/search row shape must NOT grow the key.
    rows = c.get("/messages").get_json()
    assert rows and all("rfc822_message_id" not in r for r in rows)


# ── E22: field/operator combos that would silently never match ────────────────


def test_rule_create_rejects_sender_group_with_wrong_operator_E22(client):
    """sender_group + anything but matches_group falls through to matching ""
    in the engine — a rule that renders as live and never fires."""
    r = client.post("/rules", json=_valid_rule_body(
        field="sender_group", operator="equals", value="family"))
    assert r.status_code == 400
    err = r.get_json()["error"]
    assert "equals" in err and "sender_group" in err and "matches_group" in err


def test_rule_create_rejects_matches_group_on_other_fields_E22(client):
    """The reverse direction: matches_group is meaningless off sender_group."""
    r = client.post("/rules", json=_valid_rule_body(
        field="subject", operator="matches_group", value="family"))
    assert r.status_code == 400
    err = r.get_json()["error"]
    assert "matches_group" in err and "subject" in err


def test_rule_create_accepts_the_valid_pair_E22(client):
    r = client.post("/rules", json=_valid_rule_body(
        field="sender_group", operator="matches_group", value="family"))
    assert r.status_code == 201


def test_rule_update_rejects_invalid_pair_post_merge_E22(client):
    """The E12 case: each half valid alone, the MERGED pair invalid. Patching
    only `field` onto a stored `contains` rule must 400, not store a rule the
    engine will never match."""
    r = client.post("/rules", json=_valid_rule_body())   # subject contains …
    rule_id = r.get_json()["id"]

    r = client.put(f"/rules/{rule_id}", json={"field": "sender_group"})
    assert r.status_code == 400
    err = r.get_json()["error"]
    assert "contains" in err and "sender_group" in err and "matches_group" in err

    # And the stored rule is untouched by the rejected patch.
    rules = client.get("/rules?include_disabled=true").get_json()["rules"]
    stored = next(x for x in rules if x["id"] == rule_id)
    assert stored["field"] == "subject" and stored["operator"] == "contains"

    # Patching BOTH halves to the valid pair succeeds.
    r = client.put(f"/rules/{rule_id}",
                   json={"field": "sender_group", "operator": "matches_group"})
    assert r.status_code == 200


# ── D50: multi-state filter + store-wide counts ────────────────────────────────


def test_messages_states_filter_D50(client):
    """states=new,needs_action returns the union in ONE query (tier-first
    ordering preserved); single-state stays compatible; invalid names 400."""
    # Fixture: acct:1 (T1, new) + acct:2 (T4, new). Move acct:2 to done.
    client.post("/messages/acct%3A2/triage", json={"state": "done"})

    both = client.get("/messages?states=new,done").get_json()
    assert {m["id"] for m in both} == {"acct:1", "acct:2"}
    assert [m["id"] for m in both] == ["acct:1", "acct:2"], "tier-first holds"

    only_new = client.get("/messages?states=new").get_json()
    assert {m["id"] for m in only_new} == {"acct:1"}

    r = client.get("/messages?states=new,bogus")
    assert r.status_code == 400
    assert "bogus" in r.get_json()["error"]

    assert client.get("/messages?states=").status_code == 400


def test_message_counts_store_wide_D50(connection_factory, db_path):
    """Counts are whole-store (the list paginates; rendered-row counting would
    lie) and unclassified mail is counted, not vanished (P1)."""
    conn = get_connection(db_path)
    for i in range(3):
        MessageRepo(conn).insert(Message(
            id=f"acct:c{i}", account="acct", sender_email=f"s{i}@example.com",
            subject=f"m{i}", body_plain="x",
            received_at="2026-07-17T10:00:00+00:00",
            ingested_at="2026-07-17T10:00:00+00:00",
        ))
    # classify two of the three: one new, one done; third stays unclassified.
    ClassificationRepo(conn).upsert(Classification(
        message_id="acct:c0", urgency_tier=1, category="work",
        triage_state="new", classified_at="2026-07-17T10:00:01+00:00",
        rule_matches=[]))
    ClassificationRepo(conn).upsert(Classification(
        message_id="acct:c1", urgency_tier=4, category="unknown",
        triage_state="done", classified_at="2026-07-17T10:00:01+00:00",
        rule_matches=[]))
    conn.close()

    app = create_app(connection_factory=lambda: get_connection(db_path))
    app.config.update(TESTING=True)
    c = app.test_client()
    counts = c.get("/messages/counts").get_json()
    assert counts == {"new": 1, "acknowledged": 0, "needs_action": 0,
                      "done": 1, "unclassified": 1,
                      "urgent_new": 1}   # D51: acct:c0 is New at Tier 1
    # And the endpoint isn't swallowed by the <path:message_id> route.
    assert c.get("/messages/counts").status_code == 200


def test_counts_urgent_new_is_new_tier1_and_2_only_D51(connection_factory, db_path):
    """D51 badge derivation: urgent_new counts triage-state-New Tier 1+2 —
    not Ack'd urgent mail, not New low-tier mail."""
    conn = get_connection(db_path)
    fixtures = [("u1", 1, "new"), ("u2", 2, "new"),        # counted
                ("u3", 1, "acknowledged"), ("u4", 2, "done"),  # triaged: no
                ("u5", 3, "new"), ("u6", 4, "new")]            # low-tier: no
    for name, tier, state in fixtures:
        MessageRepo(conn).insert(Message(
            id=f"acct:{name}", account="acct", sender_email=f"{name}@example.com",
            subject=name, body_plain="x",
            received_at="2026-07-17T10:00:00+00:00",
            ingested_at="2026-07-17T10:00:00+00:00"))
        ClassificationRepo(conn).upsert(Classification(
            message_id=f"acct:{name}", urgency_tier=tier, category="work",
            triage_state=state, classified_at="2026-07-17T10:00:01+00:00",
            rule_matches=[]))
    conn.close()

    app = create_app(connection_factory=lambda: get_connection(db_path))
    app.config.update(TESTING=True)
    counts = app.test_client().get("/messages/counts").get_json()
    assert counts["urgent_new"] == 2
    assert counts["new"] == 4


def test_states_filter_unclassified_token_D50_amendment(connection_factory, db_path):
    """D50 amendment (the author, Session 26): Open includes unclassified — a message
    with NO classification row must be visible in the default view (P1: a
    stuck classify failure can't hide under All)."""
    conn = get_connection(db_path)
    MessageRepo(conn).insert(Message(
        id="acct:stuck", account="acct", sender_email="stuck@example.com",
        subject="never classified", body_plain="x",
        received_at="2026-07-17T12:00:00+00:00",
        ingested_at="2026-07-17T12:00:00+00:00"))
    MessageRepo(conn).insert(Message(
        id="acct:fine", account="acct", sender_email="fine@example.com",
        subject="classified new", body_plain="x",
        received_at="2026-07-17T11:00:00+00:00",
        ingested_at="2026-07-17T11:00:00+00:00"))
    ClassificationRepo(conn).upsert(Classification(
        message_id="acct:fine", urgency_tier=2, category="work",
        triage_state="new", classified_at="2026-07-17T11:00:01+00:00",
        rule_matches=[]))
    MessageRepo(conn).insert(Message(
        id="acct:handled", account="acct", sender_email="done@example.com",
        subject="done", body_plain="x",
        received_at="2026-07-17T10:00:00+00:00",
        ingested_at="2026-07-17T10:00:00+00:00"))
    ClassificationRepo(conn).upsert(Classification(
        message_id="acct:handled", urgency_tier=4, category="work",
        triage_state="done", classified_at="2026-07-17T10:00:01+00:00",
        rule_matches=[]))
    conn.close()

    app = create_app(connection_factory=lambda: get_connection(db_path))
    app.config.update(TESTING=True)
    c = app.test_client()

    # The Open query: unclassified rides along; done stays out.
    open_view = c.get("/messages?states=new,needs_action,unclassified").get_json()
    assert {m["id"] for m in open_view} == {"acct:stuck", "acct:fine"}
    # Unclassified alone works too, and pure-NULL matching doesn't leak others.
    only_stuck = c.get("/messages?states=unclassified").get_json()
    assert [m["id"] for m in only_stuck] == ["acct:stuck"]
    # Still rejected: names outside the vocabulary.
    assert c.get("/messages?states=unclassified,bogus").status_code == 400


# ── D53: sender-group patterns over the API ──────────────────────────────────

def test_sender_group_create_with_patterns_D53(client):
    """A group carries `patterns: [...]` on create and echoes them back."""
    r = client.post("/sender-groups", json={
        "group_name": "cousins", "patterns": ["a@x.example", "*@y.example"],
        "urgency_floor": 2})
    assert r.status_code == 201
    body = r.get_json()
    assert body["patterns"] == ["a@x.example", "*@y.example"]
    # The deprecated column mirrors the first pattern for one release, so a
    # rollback to the previous binary still classifies (two-step deprecation).
    assert body["email_pattern"] == "a@x.example"


def test_sender_group_put_REPLACES_the_pattern_set_D53(client):
    """The D44 shape: the client sends the whole set, the server swaps it — no
    per-pattern add/remove endpoints, so no half-updated group is ever visible."""
    gid = client.post("/sender-groups", json={
        "group_name": "swap", "patterns": ["one@x.example", "two@x.example"],
        "urgency_floor": 3}).get_json()["id"]

    r = client.put(f"/sender-groups/{gid}", json={"patterns": ["three@x.example"]})
    assert r.status_code == 200
    assert r.get_json()["patterns"] == ["three@x.example"]


def test_sender_group_rejects_an_EMPTY_pattern_set_D53(client):
    """DG3: "Empty set invalid." A group with no patterns can never match, so a
    silent no-op group is worse than a rejected payload."""
    r = client.post("/sender-groups", json={
        "group_name": "nothing", "patterns": [], "urgency_floor": 2})
    assert r.status_code == 400
    assert "at least one" in r.get_json()["error"]

    gid = client.post("/sender-groups", json={
        "group_name": "shrinkable", "patterns": ["a@x.example"],
        "urgency_floor": 2}).get_json()["id"]
    r = client.put(f"/sender-groups/{gid}", json={"patterns": ["   "]})
    assert r.status_code == 400


def test_sender_group_rejects_conflicting_patterns_and_email_pattern_D53(client):
    """E12 lesson: name the conflict instead of silently preferring one field."""
    r = client.post("/sender-groups", json={
        "group_name": "conflict", "patterns": ["a@x.example"],
        "email_pattern": "b@y.example", "urgency_floor": 2})
    assert r.status_code == 400
    assert "conflicting" in r.get_json()["error"]


def test_sender_group_still_accepts_the_LEGACY_single_email_pattern_D53(client):
    """An older client must not break mid-alpha: a single `email_pattern` is
    accepted and normalized to a one-element `patterns` list."""
    r = client.post("/sender-groups", json={
        "group_name": "legacy", "email_pattern": "solo@x.example",
        "urgency_floor": 4})
    assert r.status_code == 201
    assert r.get_json()["patterns"] == ["solo@x.example"]


def test_every_group_serializer_carries_patterns_E10(client):
    """E10 guard: serializers are per-query, so the group shape must be identical
    everywhere a group is emitted — /rules' embedded list, POST, and PUT."""
    created = client.post("/sender-groups", json={
        "group_name": "parity", "patterns": ["p@x.example", "*@q.example"],
        "urgency_floor": 2}).get_json()
    gid = created["id"]

    listed = [g for g in client.get("/rules").get_json()["sender_groups"]
              if g["id"] == gid][0]
    updated = client.put(f"/sender-groups/{gid}",
                         json={"urgency_floor": 3}).get_json()

    for shape in (created, listed, updated):
        assert "patterns" in shape, f"missing patterns in {shape}"
        assert shape["patterns"] == ["p@x.example", "*@q.example"]


def test_deleting_a_group_cascades_to_its_patterns_D53(client, db_path):
    """ON DELETE CASCADE needs PRAGMA foreign_keys=ON per connection. Verified by
    running, because a pragma that is set but ineffective looks identical in review."""
    from db.database import get_connection

    gid = client.post("/sender-groups", json={
        "group_name": "doomed", "patterns": ["x@x.example", "y@y.example"],
        "urgency_floor": 5}).get_json()["id"]

    conn = get_connection(db_path)
    assert conn.execute("SELECT COUNT(*) FROM sender_group_patterns WHERE group_id = ?",
                        (gid,)).fetchone()[0] == 2

    assert client.delete(f"/sender-groups/{gid}").status_code == 200

    assert conn.execute("SELECT COUNT(*) FROM sender_group_patterns WHERE group_id = ?",
                        (gid,)).fetchone()[0] == 0, "orphaned pattern rows after delete"
    conn.close()


# ── D52: reclassify on demand — the four pinned invariants ───────────────────

def _seed_message(db_path, msg_id="acct:d52", sender="probe@d52.example",
                  subject="hello", state="new", tier=5, category="unknown"):
    """A stored message + classification, written directly so the test controls the
    starting tier/state precisely."""
    from db.database import get_connection
    c = get_connection(db_path)
    c.execute("INSERT OR REPLACE INTO messages (id, account, sender_email, subject, "
              "body_plain, received_at, ingested_at) VALUES (?,?,?,?,?,?,?)",
              (msg_id, "acct", sender, subject, "body",
               "2026-01-01T00:00:00+00:00", "2026-01-01T00:00:00+00:00"))
    c.execute("INSERT OR REPLACE INTO classifications (message_id, urgency_tier, "
              "category, triage_state, classified_at, rule_matches) "
              "VALUES (?,?,?,?,?,'[]')",
              (msg_id, tier, category, state, "2026-01-01T00:00:00+00:00"))
    c.commit()
    return c


def test_reclassify_PRESERVES_TRIAGE_STATE_D52_invariant_1(client, db_path):
    """DG4, verbatim: "a Done message reclassified to T1 stays Done." This is the
    invariant a user would actually notice being broken — their triage decision is
    theirs, not the engine's."""
    c = _seed_message(db_path, state="done", tier=5)
    # A rule that will drag this message to T1, so the classification really changes.
    assert client.post("/rules", json={
        "rule_name": "d52 probe → T1", "field": "sender_email", "operator": "equals",
        "value": "probe@d52.example", "set_tier": 1, "set_category": "work",
        "enabled": True}).status_code == 201

    r = client.post("/messages/acct:d52/reclassify", json={})
    assert r.status_code == 200
    body = r.get_json()

    assert body["urgency_tier"] == 1, "the reclassification should have applied"
    assert body["triage_state"] == "done", "triage state was reset — invariant 1 broken"
    after = c.execute("SELECT triage_state FROM classifications WHERE message_id=?",
                      ("acct:d52",)).fetchone()[0]
    assert after == "done"
    c.close()


def test_reclassify_is_SILENT_no_notifications_D52_invariant_2(client, db_path):
    """DG4: "reclassification is SILENT — no retroactive banners or digest entries."
    Reusing the ingestion pipeline's post-classification hook here would spray
    banners across the user's whole archive."""
    c = _seed_message(db_path, msg_id="acct:d52silent", sender="loud@d52.example",
                      state="new", tier=5)
    before = c.execute("SELECT COUNT(*) FROM notification_log").fetchone()[0]
    # Make it classify T1 — the tier that WOULD notify on ingest.
    assert client.post("/rules", json={
        "rule_name": "d52 silent → T1", "field": "sender_email", "operator": "equals",
        "value": "loud@d52.example", "set_tier": 1, "set_category": "work",
        "enabled": True}).status_code == 201

    assert client.post("/messages/acct:d52silent/reclassify", json={}).get_json()["urgency_tier"] == 1

    after = c.execute("SELECT COUNT(*) FROM notification_log").fetchone()[0]
    assert after == before, "reclassification wrote a notification — invariant 2 broken"
    c.close()


def test_reclassify_OVERWRITES_with_a_dated_audit_never_versions_D52_invariant_3(
        client, db_path):
    """DG4: "overwrite with dated audit, never version". One row per message, and
    `reclassified_at` is what lets /explain say "reclassified <date>" without keeping
    versions."""
    c = _seed_message(db_path, msg_id="acct:d52audit", sender="audit@d52.example")

    body = client.post("/messages/acct:d52audit/reclassify", json={}).get_json()
    assert body["reclassified_at"], "no reclassified_at stamp"

    rows = c.execute("SELECT COUNT(*) FROM classifications WHERE message_id=?",
                     ("acct:d52audit",)).fetchone()[0]
    assert rows == 1, "reclassification created a second row — that is versioning"

    explain = client.get("/messages/acct:d52audit/explain").get_json()
    assert explain["reclassified_at"] == body["reclassified_at"]
    assert explain["classified_at"]
    c.close()


def test_reclassify_never_runs_automatically_D52_invariant_4(client, db_path):
    """DG4: "classify-once-at-ingest remains the default lifecycle — reclassify is
    always explicit user action, never automatic." Editing a rule must NOT
    retroactively touch stored mail; only an explicit call does."""
    c = _seed_message(db_path, msg_id="acct:d52auto", sender="auto@d52.example",
                      tier=5, category="unknown")

    rule_id = client.post("/rules", json={
        "rule_name": "d52 auto → T1", "field": "sender_email", "operator": "equals",
        "value": "auto@d52.example", "set_tier": 1, "set_category": "work",
        "enabled": True}).get_json()["id"]
    client.put(f"/rules/{rule_id}", json={"set_tier": 2})

    still = c.execute("SELECT urgency_tier, reclassified_at FROM classifications "
                      "WHERE message_id=?", ("acct:d52auto",)).fetchone()
    assert still["urgency_tier"] == 5, "a rule edit reclassified stored mail by itself"
    assert still["reclassified_at"] is None
    c.close()


# ── D52 part D: dated classification + staleness arithmetic ──────────────────

def test_rules_changed_since_counts_only_KNOWN_changes_D52(client, db_path):
    """The count is "rules known to have changed since" — a NULL updated_at (pre-D52
    rows) contributes zero. Overclaiming here would make every old classification
    look stale, which is the opposite of what part D is for."""
    c = _seed_message(db_path, msg_id="acct:d52stale", sender="stale@d52.example")
    # The seeded rules predate D52 in spirit: force their updated_at to NULL.
    c.execute("UPDATE rules SET updated_at = NULL")
    c.commit()

    # Classification stamped 2026-01-01; no rule has a known change time.
    assert client.get("/messages/acct:d52stale/explain").get_json()[
        "rules_changed_since"] == 0

    # One rule edited now ⇒ exactly one known change since.
    rid = c.execute("SELECT id FROM rules LIMIT 1").fetchone()[0]
    assert client.put(f"/rules/{rid}", json={"set_tier": 3}).status_code == 200
    assert client.get("/messages/acct:d52stale/explain").get_json()[
        "rules_changed_since"] == 1

    # Reclassifying resets it: the classification is now newer than the edit.
    client.post("/messages/acct:d52stale/reclassify", json={})
    assert client.get("/messages/acct:d52stale/explain").get_json()[
        "rules_changed_since"] == 0
    c.close()


def test_rule_writes_stamp_updated_at_on_every_path_D52(client, db_path):
    """Create, update and REORDER all change what the engine would decide, so all
    three must stamp updated_at — a missed path makes the staleness count lie."""
    from db.database import get_connection
    c = get_connection(db_path)

    created = client.post("/rules", json={
        "rule_name": "d52 stamp", "field": "subject", "operator": "contains",
        "value": "x", "set_tier": 3, "enabled": True}).get_json()
    assert c.execute("SELECT updated_at FROM rules WHERE id=?",
                     (created["id"],)).fetchone()[0], "create did not stamp"

    c.execute("UPDATE rules SET updated_at = NULL WHERE id = ?", (created["id"],))
    c.commit()
    client.put(f"/rules/{created['id']}", json={"enabled": False})
    assert c.execute("SELECT updated_at FROM rules WHERE id=?",
                     (created["id"],)).fetchone()[0], "toggle/update did not stamp"

    c.execute("UPDATE rules SET updated_at = NULL")
    c.commit()
    ids = [r["id"] for r in client.get("/rules?include_disabled=true").get_json()["rules"]]
    assert client.put("/rules/reorder", json={"ordered_ids": ids}).status_code == 200
    stamped = c.execute(
        "SELECT COUNT(*) FROM rules WHERE updated_at IS NOT NULL").fetchone()[0]
    assert stamped == len(ids), "reorder did not stamp every rule it renumbered"
    c.close()


def test_reclassify_a_message_with_NO_classification_row_D52(client, db_path):
    """The D50-amendment case: P1 stores a message before classifying, so an
    unclassified message is legitimate — and is exactly what reclassify should be
    able to fix. It must not 404."""
    from db.database import get_connection
    c = get_connection(db_path)
    c.execute("INSERT INTO messages (id, account, sender_email, subject, body_plain, "
              "received_at, ingested_at) VALUES (?,?,?,?,?,?,?)",
              ("acct:d52none", "acct", "none@d52.example", "s", "b",
               "2026-01-01T00:00:00+00:00", "2026-01-01T00:00:00+00:00"))
    c.commit()

    r = client.post("/messages/acct:d52none/reclassify", json={})
    assert r.status_code == 200
    assert r.get_json()["triage_state"] == "new"
    assert c.execute("SELECT COUNT(*) FROM classifications WHERE message_id=?",
                     ("acct:d52none",)).fetchone()[0] == 1
    c.close()


def test_reclassify_unknown_message_404s_D52(client):
    assert client.post("/messages/nope:0/reclassify", json={}).status_code == 404


# ── D52 part C: bulk reclassify ──────────────────────────────────────────────

def test_bulk_reclassify_preserves_every_triage_state_and_reports_a_summary_D52(
        client, db_path):
    """Invariant 1 at scale, plus the summary the progress UI needs."""
    c = _seed_message(db_path, msg_id="acct:b1", sender="b1@d52.example",
                      state="done", tier=5)
    _seed_message(db_path, msg_id="acct:b2", sender="b2@d52.example",
                  state="needs_action", tier=5)
    before = c.execute("SELECT COUNT(*) FROM notification_log").fetchone()[0]

    assert client.post("/rules", json={
        "rule_name": "bulk → T1", "field": "sender_domain", "operator": "equals",
        "value": "d52.example", "set_tier": 1, "set_category": "work",
        "enabled": True}).status_code == 201

    summary = client.post("/messages/reclassify-all", json={}).get_json()
    assert summary["counted"] >= 2
    assert summary["changed"] >= 2
    assert summary["errors"] == 0
    assert summary["unchanged"] == summary["counted"] - summary["changed"]

    states = dict(c.execute(
        "SELECT message_id, triage_state FROM classifications "
        "WHERE message_id IN ('acct:b1','acct:b2')").fetchall())
    assert states["acct:b1"] == "done"
    assert states["acct:b2"] == "needs_action"
    # Invariant 2 holds for the whole run, not just one message.
    assert c.execute("SELECT COUNT(*) FROM notification_log").fetchone()[0] == before
    c.close()


# ── Build provenance: /version ───────────────────────────────────────────────

def test_version_endpoint_returns_sha_and_start_time(client):
    """The provenance workorder's point: "which code am I running" is a fact you can
    ask for, not something you infer from whether a feature appears."""
    import re
    r = client.get("/version")
    assert r.status_code == 200
    body = r.get_json()
    assert set(body) == {"git_sha", "started_at"}
    assert re.fullmatch(r"[0-9a-f]{7,}(-dirty)?|unknown", body["git_sha"]), body["git_sha"]
    # started_at parses as an ISO-8601 instant.
    from datetime import datetime
    datetime.fromisoformat(body["started_at"])


def test_version_degrades_to_unknown_when_git_is_unavailable(client, monkeypatch):
    """Graceful degradation, per the workorder: no git ⇒ "unknown". Never crash,
    never block startup, never fabricate a SHA."""
    import provenance
    monkeypatch.setattr(provenance, "_GIT_SHA", None)
    monkeypatch.setattr(provenance, "_run_git", lambda *a: None)
    assert provenance.git_sha() == "unknown"
    monkeypatch.setattr(provenance, "_GIT_SHA", None)


def test_version_reports_dirty_when_the_tree_has_uncommitted_changes(monkeypatch):
    """Dirty-tree honesty: a stamp claiming a clean SHA for a dirty build is worse
    than no stamp at all (the artifacts-mislead pattern, at build time)."""
    import provenance
    monkeypatch.setattr(provenance, "_GIT_SHA", None)
    monkeypatch.setattr(provenance, "_run_git",
                        lambda *a: "abc1234" if a[0] == "rev-parse" else " M file.py")
    assert provenance.git_sha() == "abc1234-dirty"
    monkeypatch.setattr(provenance, "_GIT_SHA", None)


def test_version_reports_dirty_when_the_status_check_itself_fails(monkeypatch):
    """If we cannot verify the tree is clean we do NOT claim it is: over-claiming
    cleanliness is the failure mode that misleads."""
    import provenance
    monkeypatch.setattr(provenance, "_GIT_SHA", None)
    monkeypatch.setattr(provenance, "_run_git",
                        lambda *a: "abc1234" if a[0] == "rev-parse" else None)
    assert provenance.git_sha() == "abc1234-dirty"
    monkeypatch.setattr(provenance, "_GIT_SHA", None)


# ── Multi-account: `account` on every serializer + the ?account= filter ──────

def _two_account_store(db_path):
    """Two mailboxes' worth of mail in one store — the shape alpha testing creates."""
    from db.database import get_connection
    c = get_connection(db_path)
    rows = [
        ("you@example.com:1", "you@example.com", "boss@work.example", "Personal one"),
        ("you@example.com:2", "you@example.com", "news@x.example", "Personal two"),
        ("you@example.org:1", "you@example.org", "client@y.example", "Business one"),
    ]
    for mid, acct, sender, subj in rows:
        c.execute("INSERT OR REPLACE INTO messages (id, account, sender_email, subject, "
                  "body_plain, received_at, ingested_at) VALUES (?,?,?,?,?,?,?)",
                  (mid, acct, sender, subj, "body",
                   "2026-01-01T00:00:00+00:00", "2026-01-01T00:00:00+00:00"))
        c.execute("INSERT OR REPLACE INTO classifications (message_id, urgency_tier, "
                  "category, triage_state, classified_at, rule_matches) "
                  "VALUES (?,3,'work','new','2026-01-01T00:00:00+00:00','[]')", (mid,))
    c.commit()
    return c


def test_every_message_serializer_carries_account_E10(client, db_path):
    """E10 guard: serializers are per-query here, so `account` must be present and
    correct on the LIST, the SEARCH and the DETAIL payloads. This is exactly the
    trap E10 named — one endpoint carrying a field is no evidence the others do."""
    _two_account_store(db_path).close()

    listed = client.get("/messages").get_json()
    assert listed, "no rows returned"
    assert all("account" in r for r in listed), "account missing from a list row"

    searched = client.get("/messages/search?q=Business").get_json()
    assert searched and all("account" in r for r in searched), \
        "account missing from a search row"
    assert searched[0]["account"] == "you@example.org"

    detail = client.get("/messages/you@example.org:1").get_json()
    assert detail["account"] == "you@example.org"


def test_account_filter_scopes_the_list_to_one_mailbox(client, db_path):
    _two_account_store(db_path).close()

    # The shared client fixture may already hold mail from other tests' accounts,
    # so assert our two are BOTH present rather than that they're the only ones.
    everything = client.get("/messages?limit=500").get_json()
    accounts = {r["account"] for r in everything}
    assert {"you@example.com", "you@example.org"} <= accounts

    personal = client.get("/messages?account=you@example.com").get_json()
    assert len(personal) == 2
    assert {r["account"] for r in personal} == {"you@example.com"}

    business = client.get("/messages?account=you@example.org").get_json()
    assert len(business) == 1
    assert business[0]["subject"] == "Business one"


def test_an_unknown_account_returns_EMPTY_not_an_error(client, db_path):
    """It is a filter, not an assertion: an account disconnected mid-session must
    yield an empty list, not a 400 the UI has to special-case."""
    _two_account_store(db_path).close()
    r = client.get("/messages?account=nobody@nowhere.example")
    assert r.status_code == 200
    assert r.get_json() == []


def test_the_account_filter_composes_with_the_states_filter(client, db_path):
    """The chips and the account scope must work together, not fight."""
    c = _two_account_store(db_path)
    c.execute("UPDATE classifications SET triage_state='done' "
              "WHERE message_id='you@example.com:1'")
    c.commit(); c.close()

    open_personal = client.get(
        "/messages?account=you@example.com&states=new").get_json()
    assert len(open_personal) == 1
    assert open_personal[0]["id"] == "you@example.com:2"


def test_search_spans_every_account_regardless_of_the_filter(client, db_path):
    """P1's reachability floor is account-blind: search must still find mail in any
    mailbox. The account filter is a LIST concern only."""
    _two_account_store(db_path).close()
    hits = client.get("/messages/search?q=one").get_json()
    assert {h["account"] for h in hits} == {"you@example.com", "you@example.org"}


def test_bulk_reclassify_streams_and_does_not_load_every_body_D52(client, db_path):
    """Regression guard: `reclassify_all` must STREAM the store, not materialise it.

    The original implementation did `SELECT * FROM messages … .fetchall()`, pulling
    every body_plain AND body_html into memory at once. On the real 1,592-message
    store that measured ~20 MB per run, and because CPython does not return freed
    arenas to the OS, RSS climbed 6 → 128 → 181 → 252 MB over six runs and never came
    back — a leak in the one operation explicitly designed to touch the whole store.

    Asserting megabytes would be flaky, so this pins the two structural properties
    that caused it: the query selects only the engine's columns (never body_html), and
    the rows are iterated rather than fetchall()'d.
    """
    import inspect, re
    from classification import reclassify

    # Strip comments and docstrings before grepping: this function's own comment
    # EXPLAINS the old bug and quotes the offending patterns, so a naive source grep
    # matches the explanation rather than the code. (Found by this test failing.)
    src = inspect.getsource(reclassify.reclassify_all)
    src = re.sub(r'"""..*?"""', "", src, flags=re.S)          # docstring
    src = "\n".join(re.sub(r"#.*$", "", ln) for ln in src.splitlines())

    assert "fetchall()" not in src, \
        "reclassify_all must stream the cursor, not fetchall() the whole store"
    assert "SELECT *" not in src, \
        "reclassify_all must select only the columns the engine reads"
    assert "body_html" not in src, \
        "body_html is never read by the engine and must not be loaded"

    # And it still processes everything (the fix must not have narrowed the work).
    _two_account_store(db_path).close()
    summary = client.post("/messages/reclassify-all", json={}).get_json()
    assert summary["counted"] >= 3
    assert summary["errors"] == 0


# ── D57: urgency decays with age (recency-banded ordering) ───────────────────
#
# These tests use dates RELATIVE TO NOW on purpose. The pre-D57 ordering tests
# were written with hardcoded 2026-06 dates, which silently drifted from "recent"
# to "stale" as real time passed — an assertion whose meaning changes with the
# calendar is not a guard. Anything age-sensitive here computes its dates.

from datetime import datetime, timedelta, timezone  # noqa: E402
from urllib.parse import quote  # noqa: E402


def _iso_days_ago(days: float) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()


def _seed(conn, mid, tier, days_ago, state="new"):
    """Insert one message + classification at a given age. Returns the id."""
    ts = _iso_days_ago(days_ago)
    MessageRepo(conn).insert(Message(
        id=mid, account="acct", sender_email=f"{mid}@x.com", subject=mid,
        body_plain="...", received_at=ts, ingested_at=ts,
    ))
    ClassificationRepo(conn).upsert(Classification(
        message_id=mid, urgency_tier=tier, category="work", triage_state=state,
        classified_at=ts, rule_matches=[],
    ))
    return mid


def _client_for(db_path):
    app = create_app(connection_factory=lambda: get_connection(db_path))
    app.config.update(TESTING=True)
    return app.test_client()


def test_d57_fresh_low_tier_outranks_stale_high_tier(connection_factory, db_path):
    """THE D57 case, and the reason it exists: a Tier-2 message from years ago
    must NOT outrank a Tier-4 message from today. Pre-D57 the store had 174 open
    T2s, none newer than two weeks, which filled the entire first page and made
    today's mail unreachable."""
    conn = get_connection(db_path)
    _seed(conn, "d57:stale_t2", tier=2, days_ago=900)
    _seed(conn, "d57:fresh_t4", tier=4, days_ago=1)
    conn.close()
    ids = [m["id"] for m in _client_for(db_path).get("/messages").get_json()]
    assert ids.index("d57:fresh_t4") < ids.index("d57:stale_t2")


def test_d57_tier1_is_exempt_from_decay(connection_factory, db_path):
    """The Tier 1 invariant — 'Tier 1 always surfaces, in any operating mode' —
    outranks the decay rule. A years-old T1 still sorts above today's T2.
    Without the band-0 carve-out, banding would silently break the invariant the
    whole tool is built on."""
    conn = get_connection(db_path)
    _seed(conn, "d57:ancient_t1", tier=1, days_ago=1500)
    _seed(conn, "d57:today_t2", tier=2, days_ago=0.1)
    conn.close()
    ids = [m["id"] for m in _client_for(db_path).get("/messages").get_json()]
    assert ids.index("d57:ancient_t1") < ids.index("d57:today_t2")


def test_d57_tier_still_orders_within_a_band(connection_factory, db_path):
    """Decay REPLACES tier-first only ACROSS bands. Inside one band, urgency is
    still the sort key — otherwise D57 would have thrown away tiering."""
    conn = get_connection(db_path)
    _seed(conn, "d57:same_t4", tier=4, days_ago=3)
    _seed(conn, "d57:same_t2", tier=2, days_ago=5)   # older, but same band
    conn.close()
    ids = [m["id"] for m in _client_for(db_path).get("/messages").get_json()]
    assert ids.index("d57:same_t2") < ids.index("d57:same_t4")


def test_d57_recency_orders_within_a_tier_and_band(connection_factory, db_path):
    """Innermost key is unchanged: newest first."""
    conn = get_connection(db_path)
    _seed(conn, "d57:older", tier=3, days_ago=6)
    _seed(conn, "d57:newer", tier=3, days_ago=2)
    conn.close()
    ids = [m["id"] for m in _client_for(db_path).get("/messages").get_json()]
    assert ids.index("d57:newer") < ids.index("d57:older")


def test_d57_band_boundary_is_not_off_by_one(connection_factory, db_path):
    """The 14-day edge. received_at is stored ISO-8601 WITH an offset while
    SQLite's datetime('now') has none, so a naive TEXT compare misjudges the
    boundary ('T' sorts above ' '). Pinning both sides of the edge catches a
    regression to string comparison."""
    conn = get_connection(db_path)
    _seed(conn, "d57:just_inside", tier=4, days_ago=13.5)   # fresh band
    _seed(conn, "d57:just_outside", tier=2, days_ago=14.5)  # recent band
    conn.close()
    ids = [m["id"] for m in _client_for(db_path).get("/messages").get_json()]
    # Fresh T4 beats a just-stale T2 — only true if the boundary is parsed, not
    # string-compared.
    assert ids.index("d57:just_inside") < ids.index("d57:just_outside")


def test_d57_thread_fetch_still_reads_chronologically(connection_factory, db_path):
    """Banding must not leak into the thread view (spec §4.1.2 reads top-to-
    bottom, received_at ASC) — a conversation is not a priority list."""
    conn = get_connection(db_path)
    for mid, tier, age in (("t:a", 4, 40), ("t:b", 1, 30), ("t:c", 5, 20)):
        ts = _iso_days_ago(age)
        MessageRepo(conn).insert(Message(
            id=mid, account="acct", thread_id="th1", sender_email="x@x.com",
            subject=mid, body_plain="...", received_at=ts, ingested_at=ts,
        ))
        ClassificationRepo(conn).upsert(Classification(
            message_id=mid, urgency_tier=tier, category="work",
            triage_state="new", classified_at=ts, rule_matches=[],
        ))
    conn.close()
    ids = [m["id"] for m in _client_for(db_path).get("/threads/th1").get_json()]
    assert ids == ["t:a", "t:b", "t:c"]   # oldest first, tier ignored


# ── Filters Part 2: date range (since / until) ───────────────────────────────

def test_date_filter_since_is_inclusive_lower_bound(connection_factory, db_path):
    conn = get_connection(db_path)
    _seed(conn, "dt:new", tier=3, days_ago=2)
    _seed(conn, "dt:old", tier=3, days_ago=40)
    conn.close()
    bound = _iso_days_ago(10)
    ids = [m["id"] for m in
           _client_for(db_path).get(f"/messages?since={bound}").get_json()]
    assert "dt:new" in ids and "dt:old" not in ids


def test_date_filter_until_is_the_older_than_x_case(connection_factory, db_path):
    """`until=` alone is 'older than X days' — the inverse window, and the one
    that makes bulk-triaging a backlog possible. Explicitly pinned because it is
    the easiest of the presets to drop."""
    conn = get_connection(db_path)
    _seed(conn, "dt:new", tier=3, days_ago=2)
    _seed(conn, "dt:old", tier=3, days_ago=40)
    conn.close()
    bound = _iso_days_ago(30)
    ids = [m["id"] for m in
           _client_for(db_path).get(f"/messages?until={bound}").get_json()]
    assert ids == ["dt:old"]


def test_date_filter_since_and_until_compose_into_a_window(connection_factory, db_path):
    conn = get_connection(db_path)
    _seed(conn, "dt:before", tier=3, days_ago=60)
    _seed(conn, "dt:inside", tier=3, days_ago=20)
    _seed(conn, "dt:after", tier=3, days_ago=1)
    conn.close()
    q = f"since={_iso_days_ago(30)}&until={_iso_days_ago(10)}"
    ids = [m["id"] for m in _client_for(db_path).get(f"/messages?{q}").get_json()]
    assert ids == ["dt:inside"]


def test_date_filter_composes_with_tier_and_state(connection_factory, db_path):
    """The filters are orthogonal to the D50 chips and must AND together —
    'T4 older than 30 days that is still Open' is the actual backlog query."""
    conn = get_connection(db_path)
    _seed(conn, "dt:hit", tier=4, days_ago=50, state="new")
    _seed(conn, "dt:wrongtier", tier=2, days_ago=50, state="new")
    _seed(conn, "dt:wrongstate", tier=4, days_ago=50, state="done")
    _seed(conn, "dt:toonew", tier=4, days_ago=1, state="new")
    conn.close()
    q = f"tier=4&states=new&until={_iso_days_ago(30)}"
    ids = [m["id"] for m in _client_for(db_path).get(f"/messages?{q}").get_json()]
    assert ids == ["dt:hit"]


def test_date_filter_empty_result_is_empty_list_not_404(connection_factory, db_path):
    conn = get_connection(db_path)
    _seed(conn, "dt:only", tier=3, days_ago=2)
    conn.close()
    r = _client_for(db_path).get(f"/messages?until={_iso_days_ago(365)}")
    assert r.status_code == 200 and r.get_json() == []


def test_date_filter_rejects_malformed_bound(connection_factory, db_path):
    """A typo must 400, not return an empty list. julianday() yields NULL for
    junk and a NULL compare is false, so without validation 'since=lastweek'
    would look like 'you have no mail' — the exact silent-empty-view failure
    D50 added state validation to prevent."""
    c = _client_for(db_path)
    for bad in ("lastweek", "2026-13-45", "", "7 days ago"):
        r = c.get(f"/messages?since={bad}")
        assert r.status_code == 400, f"{bad!r} should be rejected"
        assert "since" in r.get_json()["error"]
    assert c.get(f"/messages?until=nonsense").status_code == 400


def test_date_filter_accepts_bare_date_and_z_suffix(connection_factory, db_path):
    """UI presets and hand-typed bounds both happen; accept the common spellings."""
    c = _client_for(db_path)
    assert c.get("/messages?since=2026-01-01").status_code == 200
    assert c.get("/messages?since=2026-01-01T00:00:00Z").status_code == 200
    assert c.get("/messages?since=2026-01-01T00:00:00+00:00").status_code == 200


def test_date_filter_tolerates_unencoded_plus_offset(connection_factory, db_path):
    """`+` is the URL encoding of a space, so an unencoded `+00:00` offset
    arrives as ` 00:00`. That spelling must still work: it is what a client
    sending a raw ISO string produces, and julianday() returns NULL for it —
    which would drop the filter silently rather than erroring. Found by a test
    whose own URL was 'correct'."""
    conn = get_connection(db_path)
    _seed(conn, "pl:new", tier=3, days_ago=2)
    _seed(conn, "pl:old", tier=3, days_ago=40)
    conn.close()
    c = _client_for(db_path)
    mangled = _iso_days_ago(10).replace("+", " ")     # what the server receives
    r = c.get(f"/messages?since={mangled}")
    assert r.status_code == 200
    ids = [m["id"] for m in r.get_json()]
    assert ids == ["pl:new"], "the bound must filter, not silently no-op"


# ── OI21: the list is a window, and it must say so ───────────────────────────

def test_list_reports_total_count_beyond_the_page(connection_factory, db_path):
    """OI21. The list defaults to limit=100 and the client never paginated, so
    every view silently claimed to be the whole store — which is what
    manufactured the phantom OI20. The page now carries the true total for its
    filter set, so the UI can say 'showing N of M' instead of implying N is M."""
    conn = get_connection(db_path)
    for i in range(120):
        _seed(conn, f"pg:{i:03}", tier=3, days_ago=i % 10)
    conn.close()
    r = _client_for(db_path).get("/messages?states=new")
    assert len(r.get_json()) == 100                    # still a page
    assert r.headers["X-Total-Count"] == "120"         # but it admits the rest


def test_list_total_count_respects_the_active_filters(connection_factory, db_path):
    """The total must be the FILTERED total, not the store-wide one — otherwise
    'showing 100 of 4939' under a tier filter is a lie. This is why the count is
    a separate method from the D50 store-wide chip counts."""
    conn = get_connection(db_path)
    for i in range(30):
        _seed(conn, f"ft:t4:{i:03}", tier=4, days_ago=1)
    for i in range(7):
        _seed(conn, f"ft:t2:{i:03}", tier=2, days_ago=1)
    conn.close()
    c = _client_for(db_path)
    assert c.get("/messages").headers["X-Total-Count"] == "37"
    assert c.get("/messages?tier=2").headers["X-Total-Count"] == "7"
    assert c.get(f"/messages?tier=4&until={_iso_days_ago(0.5)}"
                 ).headers["X-Total-Count"] == "30"


def test_offset_paginates_to_the_genuine_last_row(connection_factory, db_path):
    """The acceptance test OI21 actually asks for: a message past row 100 is
    REACHABLE, proven by reaching it rather than asserted. Walks pages until the
    total is exhausted and checks the set is complete with no duplicates."""
    conn = get_connection(db_path)
    expected = {f"pp:{i:03}" for i in range(250)}
    for i in range(250):
        _seed(conn, f"pp:{i:03}", tier=3, days_ago=i % 30)
    conn.close()
    c = _client_for(db_path)
    seen, offset, total = [], 0, None
    while True:
        r = c.get(f"/messages?limit=100&offset={offset}")
        total = int(r.headers["X-Total-Count"])
        batch = [m["id"] for m in r.get_json()]
        if not batch:
            break
        seen.extend(batch)
        offset += len(batch)
        if offset >= total:
            break
    assert total == 250
    assert len(seen) == 250, "pagination must not skip or stall"
    assert len(set(seen)) == 250, "pages must not overlap"
    assert set(seen) == expected


def test_count_matching_ignores_limit_and_offset(connection_factory, db_path):
    """The total is a property of the FILTER, not of the page being viewed."""
    conn = get_connection(db_path)
    for i in range(40):
        _seed(conn, f"ci:{i:03}", tier=3, days_ago=1)
    repo = MessageRepo(conn)
    assert repo.count_matching(tier=3) == 40
    assert repo.count_matching(tier=3, limit=5, offset=35) == 40
    conn.close()


# ── Part 3: bulk triage ──────────────────────────────────────────────────────

def test_bulk_triage_applies_to_exactly_the_given_ids(connection_factory, db_path):
    conn = get_connection(db_path)
    for i in range(5):
        _seed(conn, f"bk:{i}", tier=4, days_ago=40)
    conn.close()
    c = _client_for(db_path)
    r = c.post("/messages/triage-bulk",
               json={"message_ids": ["bk:0", "bk:2", "bk:4"], "state": "done"})
    assert r.status_code == 200
    assert r.get_json()["updated"] == 3
    states = {m["id"]: m["triage_state"]
              for m in c.get("/messages?states=new,done").get_json()}
    assert states["bk:0"] == states["bk:2"] == states["bk:4"] == "done"
    assert states["bk:1"] == states["bk:3"] == "new"   # untouched


def test_bulk_triage_is_all_or_nothing_on_a_stale_id(connection_factory, db_path):
    """A set containing an unknown id changes NOTHING. The client sends what the
    user saw; if that set has gone stale, a partial apply is the worst outcome —
    the user cannot tell which half landed."""
    conn = get_connection(db_path)
    _seed(conn, "aon:1", tier=4, days_ago=40)
    _seed(conn, "aon:2", tier=4, days_ago=40)
    conn.close()
    c = _client_for(db_path)
    r = c.post("/messages/triage-bulk",
               json={"message_ids": ["aon:1", "aon:ghost", "aon:2"], "state": "done"})
    assert r.status_code == 409
    assert r.get_json()["missing"] == ["aon:ghost"]
    remaining = {m["id"] for m in c.get("/messages?states=new").get_json()}
    assert {"aon:1", "aon:2"} <= remaining, "nothing may have been triaged"


def test_bulk_triage_rolls_back_a_mid_batch_failure(connection_factory, db_path):
    """Atomicity proven by forcing a failure partway, not asserted. This is the
    guard that catches a regression to looping the single-message update, which
    commits per call and would leave the batch half-applied."""
    import sqlite3 as _sqlite3

    conn = get_connection(db_path)
    for i in range(4):
        _seed(conn, f"rb:{i}", tier=4, days_ago=40)
    repo = ClassificationRepo(conn)

    # Force a REAL failure mid-batch rather than mocking the driver: a CHECK
    # constraint on triage_state rejects the write once the transaction is
    # already open and some rows have been updated.
    conn.executescript("""
        CREATE TRIGGER rb_boom BEFORE UPDATE ON classifications
        WHEN NEW.message_id = 'rb:2'
        BEGIN SELECT RAISE(ABORT, 'simulated mid-batch failure'); END;
    """)

    with pytest.raises(_sqlite3.Error):
        repo.update_triage_state_bulk([f"rb:{i}" for i in range(4)], "done")

    still_new = conn.execute(
        "SELECT COUNT(*) FROM classifications WHERE triage_state = 'new'"
    ).fetchone()[0]
    assert still_new == 4, (
        "a failed batch must leave EVERY row untouched — including rb:0 and "
        "rb:1, which the executemany had already updated before rb:2 aborted"
    )
    conn.execute("DROP TRIGGER rb_boom")
    conn.close()


def test_bulk_triage_skips_write_back_by_default(connection_factory, db_path):
    """P5 decision, made explicit. Each single-message write-back is a SELECT +
    a full-mailbox UID SEARCH + a STORE; a realistic bulk Done covers thousands
    of messages, so fanning out is a long mailbox rewrite hidden in a list
    action. Off by default, and the response SAYS so rather than staying silent."""
    conn = get_connection(db_path)
    _seed(conn, "wb:1", tier=4, days_ago=40)
    # Write-back enabled for the account — the skip must come from the bulk
    # policy, not from the account gate being off.
    PreferencesRepo(conn).set("writeback_enabled:acct", "true")
    conn.close()

    calls = []

    def exploding_factory(account):
        calls.append(account)
        raise AssertionError("bulk must not touch the mailbox by default")

    app = create_app(connection_factory=lambda: get_connection(db_path),
                     imap_client_factory=exploding_factory)
    app.config.update(TESTING=True)
    r = app.test_client().post("/messages/triage-bulk",
                               json={"message_ids": ["wb:1"], "state": "done"})
    assert r.status_code == 200
    body = r.get_json()
    assert body["wrote_back"] == 0
    assert body["write_back_skipped"] is True
    assert calls == [], "no IMAP connection may be opened"


def test_bulk_triage_dedups_repeated_ids(connection_factory, db_path):
    conn = get_connection(db_path)
    _seed(conn, "dd:1", tier=4, days_ago=40)
    conn.close()
    r = _client_for(db_path).post(
        "/messages/triage-bulk",
        json={"message_ids": ["dd:1", "dd:1", "dd:1"], "state": "done"})
    assert r.get_json()["updated"] == 1


def test_bulk_triage_validates_its_input(connection_factory, db_path):
    c = _client_for(db_path)
    assert c.post("/messages/triage-bulk",
                  json={"message_ids": ["x"], "state": "bogus"}).status_code == 400
    assert c.post("/messages/triage-bulk",
                  json={"message_ids": [], "state": "done"}).status_code == 400
    assert c.post("/messages/triage-bulk",
                  json={"state": "done"}).status_code == 400
    assert c.post("/messages/triage-bulk",
                  json={"message_ids": [1, 2], "state": "done"}).status_code == 400


def test_bulk_triage_does_not_reclassify_or_notify(connection_factory, db_path):
    """D52's silence invariant applies to bulk too: triage state is the only
    thing that changes. A bulk action that quietly reclassified 4,000 messages —
    or fired 4,000 banners — would be the worst possible surprise."""
    conn = get_connection(db_path)
    _seed(conn, "si:1", tier=2, days_ago=40)
    before = conn.execute(
        "SELECT urgency_tier, category, classified_at, reclassified_at "
        "FROM classifications WHERE message_id = 'si:1'").fetchone()
    log_before = conn.execute("SELECT COUNT(*) FROM notification_log").fetchone()[0]
    conn.close()

    r = _client_for(db_path).post("/messages/triage-bulk",
                                  json={"message_ids": ["si:1"], "state": "done"})
    assert r.status_code == 200

    conn = get_connection(db_path)
    after = conn.execute(
        "SELECT urgency_tier, category, classified_at, reclassified_at, triage_state "
        "FROM classifications WHERE message_id = 'si:1'").fetchone()
    log_after = conn.execute("SELECT COUNT(*) FROM notification_log").fetchone()[0]
    conn.close()

    assert after["triage_state"] == "done"          # the one intended change
    assert after["urgency_tier"] == before["urgency_tier"]
    assert after["category"] == before["category"]
    assert after["classified_at"] == before["classified_at"]
    assert after["reclassified_at"] == before["reclassified_at"]
    assert log_after == log_before, "bulk triage must fire no notifications"


# ── D59: filter-scoped bulk triage ───────────────────────────────────────────
#
# The Session 31 endpoint took an explicit id list, so "everything matching this
# filter" was not expressible in the contract at all — clearing a 4,000-message
# backlog meant Load-more → select 100 → Done, dozens of times. These tests pin
# the new mode's contract, and especially the two things that make it SAFE: one
# shared predicate (so the set shown and the set written are the same set) and a
# required `until` (so the set cannot grow between preview and execute).


def _bulk_filter(c, state="done", **filt):
    """POST a filter-scoped bulk. `until` defaults to now — frozen at CALL time,
    which is what a client does at preview."""
    filt.setdefault("until", datetime.now(timezone.utc).isoformat())
    return c.post("/messages/triage-bulk", json={"state": state, "filter": filt})


def test_d59_shared_predicate_list_count_and_bulk_affect_the_same_set(
        connection_factory, db_path):
    """§1's guard, asserted DIRECTLY rather than as three independent
    expectations that happen to agree.

    The rows the user sees, the "showing N of M" total, and the set the bulk
    UPDATE writes to must all be the same set. Three independent copies of the
    filter predicate is the single most likely way to ship a wrong-set bug, and
    a wrong-set bulk UPDATE is silent — the user is shown one count and a
    different population changes."""
    conn = get_connection(db_path)
    # A deliberately mixed store so the filter has to discriminate on every axis.
    for i in range(12):
        _seed(conn, f"sp:t4old:{i}", tier=4, days_ago=40)
    for i in range(5):
        _seed(conn, f"sp:t4new:{i}", tier=4, days_ago=2)     # too fresh
    for i in range(7):
        _seed(conn, f"sp:t2old:{i}", tier=2, days_ago=40)    # wrong tier
    for i in range(3):
        _seed(conn, f"sp:t4done:{i}", tier=4, days_ago=40, state="done")
    conn.close()
    c = _client_for(db_path)

    bound = _iso_days_ago(30)
    qs = f"tier=4&states=new&until={quote(bound)}"

    # 1. the rows the user sees (ask for more than the page so `seen` is total)
    listed = c.get(f"/messages?{qs}&limit=500").get_json()
    seen_ids = {m["id"] for m in listed}
    # 2. the total the UI reports
    total = int(c.get(f"/messages?{qs}").headers["X-Total-Count"])
    # 3. the set the bulk writes
    r = _bulk_filter(c, state="done", tier=4, states=["new"], until=bound)
    assert r.status_code == 200, r.get_json()
    body = r.get_json()

    assert len(seen_ids) == total == body["matching"] == body["updated"] == 12, (
        f"list={len(seen_ids)} count={total} matching={body['matching']} "
        f"updated={body['updated']} — the callers disagree about the set"
    )
    # And it is the same set by IDENTITY, not merely the same size.
    conn = get_connection(db_path)
    now_done = {r[0] for r in conn.execute(
        "SELECT message_id FROM classifications WHERE triage_state='done'"
    ).fetchall()}
    conn.close()
    assert seen_ids <= now_done, "a listed row was not the row that got updated"
    assert all(i.startswith("sp:t4old:") for i in seen_ids)
    # The three excluded populations are untouched (bar the pre-existing dones).
    assert not any(i.startswith(("sp:t4new:", "sp:t2old:")) for i in now_done)


def test_d59_until_is_required_in_filter_mode(connection_factory, db_path):
    """The race guard's first half. A server-side default would be evaluated at
    EXECUTE time and defeat the entire mechanism, so absence must be an error,
    never a fill-in."""
    c = _client_for(db_path)
    r = c.post("/messages/triage-bulk",
               json={"state": "done", "filter": {"tier": 4}})
    assert r.status_code == 400
    assert "until" in r.get_json()["error"]


def test_d59_mail_arriving_after_the_frozen_until_is_NOT_triaged(
        connection_factory, db_path):
    """THE race guard, proven by running it.

    A poll can land between the user reading "this will mark 3,204 messages
    Done" and the execute. Without the frozen bound, mail that arrived in that
    window is marked Done HAVING NEVER BEEN SEEN — nothing is deleted, so it is
    not a P1 violation, but it is the same shape of harm and it is silent.

    This is the test that fails if someone later "helpfully" defaults `until`
    server-side."""
    conn = get_connection(db_path)
    _seed(conn, "race:old", tier=4, days_ago=40)
    conn.close()
    c = _client_for(db_path)

    # The user is shown a count; the client freezes `until` at this instant.
    frozen = datetime.now(timezone.utc).isoformat()
    assert int(c.get(f"/messages?tier=4&until={quote(frozen)}"
                     ).headers["X-Total-Count"]) == 1

    # …then a poll lands. This message has never been on screen.
    conn = get_connection(db_path)
    _seed(conn, "race:arrived_during", tier=4, days_ago=0)
    conn.close()

    r = _bulk_filter(c, state="done", tier=4, until=frozen)
    assert r.status_code == 200
    assert r.get_json()["updated"] == 1, "only the previewed message may change"

    conn = get_connection(db_path)
    states = dict(conn.execute(
        "SELECT message_id, triage_state FROM classifications").fetchall())
    conn.close()
    assert states["race:old"] == "done"
    assert states["race:arrived_during"] == "new", (
        "mail that arrived after the frozen bound was triaged unseen — the "
        "`until` guard is not holding"
    )


def test_d59_e24_plus_mangled_bound_is_restored_on_the_bulk_endpoint(
        connection_factory, db_path):
    """E24 regression ON THE NEW ENDPOINT. The existing E24 test covers
    GET /messages only.

    `+` is the URL encoding of a space, so a correctly-formed `+00:00` offset
    can arrive as ` 00:00`. julianday() returns NULL for that, a NULL comparison
    is false, and the bound silently vanishes. On the list endpoint that returns
    too many rows; here it would UPDATE the wrong set — the same bug with a far
    worse consequence, which is why both endpoints share `parse_bound`."""
    conn = get_connection(db_path)
    _seed(conn, "e24:old", tier=4, days_ago=40)
    _seed(conn, "e24:fresh", tier=4, days_ago=1)
    conn.close()
    c = _client_for(db_path)

    mangled = _iso_days_ago(30).replace("+", " ")
    assert " " in mangled, "fixture must actually be mangled"
    r = _bulk_filter(c, state="done", tier=4, until=mangled)
    assert r.status_code == 200, r.get_json()
    assert r.get_json()["updated"] == 1, (
        "the mangled bound was dropped instead of restored — the filter widened "
        "and a fresh message was triaged"
    )

    conn = get_connection(db_path)
    states = dict(conn.execute(
        "SELECT message_id, triage_state FROM classifications").fetchall())
    conn.close()
    assert states["e24:old"] == "done"
    assert states["e24:fresh"] == "new"


def test_d59_genuinely_malformed_bound_is_a_400_not_an_empty_update(
        connection_factory, db_path):
    """Restoring `+` must not become "accept anything". A typo is a 400."""
    c = _client_for(db_path)
    r = _bulk_filter(c, state="done", tier=4, until="not-a-date")
    assert r.status_code == 400
    assert "until" in r.get_json()["error"]


def test_d59_exactly_one_mode_per_request(connection_factory, db_path):
    """Both is ambiguous (which set wins?); neither is a request to update
    nothing. In an endpoint this destructive-shaped, guessing beats neither."""
    c = _client_for(db_path)
    both = c.post("/messages/triage-bulk", json={
        "state": "done", "message_ids": ["x:1"],
        "filter": {"tier": 4, "until": _iso_days_ago(1)}})
    assert both.status_code == 400
    assert "both" in both.get_json()["error"]

    neither = c.post("/messages/triage-bulk", json={"state": "done"})
    assert neither.status_code == 400
    assert "either" in neither.get_json()["error"]


def test_d59_unknown_filter_key_is_rejected(connection_factory, db_path):
    """A silently-ignored typo'd key WIDENS the set being updated: `tierr=4`
    dropped means "every tier". Failing loudly is the only safe reading."""
    c = _client_for(db_path)
    r = _bulk_filter(c, state="done", tierr=4)
    assert r.status_code == 400
    assert "tierr" in r.get_json()["error"]


def test_d59_reports_rows_already_in_the_target_state(
        connection_factory, db_path):
    """`updated` alone cannot distinguish "3,204 moved" from "3,204 matched, 900
    already Done" — SQLite counts a no-op UPDATE as a changed row."""
    conn = get_connection(db_path)
    for i in range(4):
        _seed(conn, f"aly:new:{i}", tier=4, days_ago=40)
    for i in range(3):
        _seed(conn, f"aly:done:{i}", tier=4, days_ago=40, state="done")
    conn.close()
    c = _client_for(db_path)
    body = _bulk_filter(c, state="done", tier=4, until=_iso_days_ago(30)).get_json()
    assert body["matching"] == 7
    assert body["already_in_state"] == 3


def test_d59_is_atomic_a_mid_update_failure_changes_zero_rows(
        connection_factory, db_path):
    """Atomicity proven by forcing a real failure, not asserted. One statement
    means there is no half-applied state for the reload-per-poll classifier
    (E11/D37) to observe."""
    conn = get_connection(db_path)
    for i in range(6):
        _seed(conn, f"at:{i}", tier=4, days_ago=40)
    conn.executescript("""
        CREATE TRIGGER at_boom BEFORE UPDATE ON classifications
        WHEN NEW.message_id = 'at:3'
        BEGIN SELECT RAISE(ABORT, 'simulated mid-update failure'); END;
    """)
    conn.commit()
    conn.close()

    c = _client_for(db_path)
    r = _bulk_filter(c, state="done", tier=4, until=_iso_days_ago(30))
    assert r.status_code == 500

    conn = get_connection(db_path)
    states = [row[0] for row in conn.execute(
        "SELECT triage_state FROM classifications").fetchall()]
    conn.close()
    assert states.count("done") == 0, (
        f"a failed bulk left {states.count('done')} row(s) changed; it must be 0"
    )


def test_d59_p1_bulk_done_messages_remain_retrievable(
        connection_factory, db_path):
    """P1 — suppression, never deletion. After a bulk Done, every affected
    message is still returned by search and by the All view. Nothing in this
    feature may delete a message row."""
    conn = get_connection(db_path)
    for i in range(5):
        _seed(conn, f"p1:{i}", tier=4, days_ago=40)
    conn.close()
    c = _client_for(db_path)
    assert _bulk_filter(c, state="done", tier=4,
                        until=_iso_days_ago(30)).get_json()["updated"] == 5

    all_ids = {m["id"] for m in c.get("/messages?limit=500").get_json()}
    assert {f"p1:{i}" for i in range(5)} <= all_ids, "All view must still show them"
    for i in range(5):
        hits = {m["id"] for m in c.get(f"/messages/search?q=p1:{i}").get_json()}
        assert f"p1:{i}" in hits, "a bulk-Done message vanished from search (P1)"


def test_d59_write_back_is_off_by_default_and_the_response_says_so(
        connection_factory, db_path):
    """P5. Filter-scoped selection makes a 12,450-round-trip mailbox rewrite far
    easier to fire, so the default must stay off AND be visible."""
    conn = get_connection(db_path)
    _seed(conn, "wb:1", tier=4, days_ago=40)
    conn.close()

    calls = []

    def _never(account):
        calls.append(account)
        raise AssertionError("write-back must not be attempted by default")

    app = create_app(connection_factory=lambda: get_connection(db_path),
                     imap_client_factory=_never)
    app.config.update(TESTING=True)
    body = app.test_client().post("/messages/triage-bulk", json={
        "state": "done",
        "filter": {"tier": 4, "until": _iso_days_ago(30)},
    }).get_json()
    assert body["updated"] == 1
    assert body["write_back_skipped"] is True
    assert body["wrote_back"] == 0
    assert calls == [], "no IMAP client may even be constructed"


def test_d59_p3_tier_and_rule_matches_survive_a_filter_bulk(
        connection_factory, db_path):
    """P3 — only `triage_state` changes. The stored tier and the rule_matches
    audit trail are what make a classification explainable; a bulk triage that
    quietly rewrote them would break P3 at scale."""
    conn = get_connection(db_path)
    _seed(conn, "p3:1", tier=4, days_ago=40)
    before = conn.execute(
        "SELECT urgency_tier, category, classified_at, rule_matches "
        "FROM classifications WHERE message_id='p3:1'").fetchone()
    log_before = conn.execute("SELECT COUNT(*) FROM notification_log").fetchone()[0]
    conn.close()

    c = _client_for(db_path)
    assert _bulk_filter(c, state="done", tier=4,
                        until=_iso_days_ago(30)).status_code == 200

    conn = get_connection(db_path)
    after = conn.execute(
        "SELECT urgency_tier, category, classified_at, rule_matches, triage_state "
        "FROM classifications WHERE message_id='p3:1'").fetchone()
    log_after = conn.execute("SELECT COUNT(*) FROM notification_log").fetchone()[0]
    conn.close()
    assert after["triage_state"] == "done"
    assert after["urgency_tier"] == before["urgency_tier"]
    assert after["category"] == before["category"]
    assert after["classified_at"] == before["classified_at"]
    assert after["rule_matches"] == before["rule_matches"]
    assert log_after == log_before, "a filter bulk must fire no notifications"


def test_d59_scale_three_thousand_rows_in_one_statement(
        connection_factory, db_path):
    """A green test over a 20-row fixture is not evidence about a 3,000-row
    UPDATE. Builds a realistic backlog and asserts the whole set moves."""
    import time

    conn = get_connection(db_path)
    conn.execute("BEGIN")
    ts_old, ts_new = _iso_days_ago(40), _iso_days_ago(1)
    rows_m, rows_c = [], []
    for i in range(3000):
        rows_m.append((f"sc:{i:05}", "acct", f"s{i}@x.com", f"subj {i}", "body",
                       ts_old, ts_old))
        rows_c.append((f"sc:{i:05}", 4, "work", "new", ts_old, "[]"))
    for i in range(200):                       # fresh mail that must NOT move
        rows_m.append((f"fresh:{i:04}", "acct", f"f{i}@x.com", f"f {i}", "body",
                       ts_new, ts_new))
        rows_c.append((f"fresh:{i:04}", 4, "work", "new", ts_new, "[]"))
    conn.executemany("INSERT INTO messages (id, account, sender_email, subject, "
                     "body_plain, received_at, ingested_at) VALUES (?,?,?,?,?,?,?)",
                     rows_m)
    conn.executemany("INSERT INTO classifications (message_id, urgency_tier, "
                     "category, triage_state, classified_at, rule_matches) "
                     "VALUES (?,?,?,?,?,?)", rows_c)
    conn.commit()
    conn.close()

    c = _client_for(db_path)
    bound = _iso_days_ago(30)
    started = time.monotonic()
    r = _bulk_filter(c, state="done", tier=4, states=["new"], until=bound)
    elapsed = time.monotonic() - started
    assert r.status_code == 200, r.get_json()
    assert r.get_json()["updated"] == 3000
    print(f"\n[D59 scale] 3,000 rows updated in {elapsed:.3f}s")

    conn = get_connection(db_path)
    done = conn.execute("SELECT COUNT(*) FROM classifications "
                        "WHERE triage_state='done'").fetchone()[0]
    fresh_new = conn.execute(
        "SELECT COUNT(*) FROM classifications c JOIN messages m ON m.id=c.message_id "
        "WHERE c.triage_state='new' AND m.id LIKE 'fresh:%'").fetchone()[0]
    conn.close()
    assert done == 3000
    assert fresh_new == 200, "the 200 fresh messages must be untouched"


def test_d59_preferences_expose_fresh_days_for_the_two_week_preset(
        connection_factory, db_path):
    """§B4: the "older than 2 weeks" preset and D57's recency band are the same
    number. Exposing the constant means they cannot drift, and OI29's later
    promotion to a real preference moves both at once."""
    from db.database import FRESH_DAYS
    c = _client_for(db_path)
    assert c.get("/preferences").get_json()["fresh_days"] == str(FRESH_DAYS)


# ── D60: executed-bulk audit log + the 5,000 cap ─────────────────────────────
#
# The log exists because the filter and the frozen `until` bound exist ONLY at
# execute time and cannot be reconstructed afterwards. Undo is deliberately NOT
# built (docs/IDEAS.md); this is the one part of it that cannot be added later.
#
# The properties worth pinning are the ones that make a log trustworthy: it
# records what actually happened, it cannot survive an operation that didn't,
# and nothing depends on it.


def test_d60_bulk_log_records_the_filter_bound_and_counts(
        connection_factory, db_path):
    conn = get_connection(db_path)
    for i in range(4):
        _seed(conn, f"lg:{i}", tier=4, days_ago=40)
    _seed(conn, "lg:done", tier=4, days_ago=40, state="done")
    conn.close()
    c = _client_for(db_path)

    bound = _iso_days_ago(30)
    r = _bulk_filter(c, state="done", tier=4, states=["new", "done"], until=bound)
    assert r.status_code == 200, r.get_json()

    entries = c.get("/bulk-operations").get_json()
    assert len(entries) == 1
    e = entries[0]
    assert e["triage_state"] == "done"
    assert e["updated"] == 5
    assert e["matched"] == 5
    assert e["already_in_state"] == 1, "the one already-Done row is recorded"
    # The filter is stored as an OBJECT, not a rendered sentence: a description
    # of a filter can't be re-executed or compared against another operation.
    assert e["filter"]["tier"] == 4
    assert sorted(e["filter"]["states"]) == ["done", "new"]
    assert e["until"] is not None
    assert e["executed_at"], "every entry is timestamped"


def test_d60_a_failed_bulk_writes_NO_log_row(connection_factory, db_path):
    """Same transaction, proven by forcing a real failure.

    A log that can record an operation which did not happen is worse than no
    log, because it will be believed. This is the test that fails if someone
    later moves the append after the commit "so the log doesn't hold the
    transaction open".
    """
    conn = get_connection(db_path)
    for i in range(5):
        _seed(conn, f"fx:{i}", tier=4, days_ago=40)
    conn.executescript("""
        CREATE TRIGGER fx_boom BEFORE UPDATE ON classifications
        WHEN NEW.message_id = 'fx:3'
        BEGIN SELECT RAISE(ABORT, 'simulated mid-update failure'); END;
    """)
    conn.commit()
    conn.close()

    c = _client_for(db_path)
    assert _bulk_filter(c, state="done", tier=4,
                        until=_iso_days_ago(30)).status_code == 500

    conn = get_connection(db_path)
    rows = conn.execute("SELECT COUNT(*) FROM bulk_operation_log").fetchone()[0]
    changed = conn.execute("SELECT COUNT(*) FROM classifications "
                           "WHERE triage_state='done'").fetchone()[0]
    conn.close()
    assert changed == 0, "precondition: the update really did roll back"
    assert rows == 0, ("a rolled-back bulk left a log row — the append is "
                       "outside the transaction")


def test_d60_nothing_reads_the_log_to_make_a_decision(connection_factory, db_path):
    """The log is a LOG, NOT STATE — asserted by inspection over the source.

    It looks like a convenient cache of "what was recently triaged", and the
    first person wanting a shortcut will reach for it. A log something depends
    on stops being append-only in practice, because then its contents have to be
    CORRECT rather than merely honest.
    """
    import pathlib
    backend = pathlib.Path(__file__).resolve().parents[1]
    readers = []
    for path in backend.rglob("*.py"):
        if "tests" in path.parts or "__pycache__" in path.parts:
            continue
        for n, line in enumerate(path.read_text().splitlines(), 1):
            if "bulk_operation_log" not in line:
                continue
            stripped = line.strip()
            if stripped.startswith("#") or stripped.startswith("--"):
                continue
            if "SELECT" in line.upper() and "COUNT(*)" not in line.upper():
                readers.append(f"{path.relative_to(backend)}:{n}: {stripped[:70]}")
    # The ONLY permitted reader is the repo method backing GET /bulk-operations.
    allowed = [r for r in readers if "recent_bulk_operations" in r
               or "ORDER BY id DESC" in r]
    unexpected = [r for r in readers if r not in allowed]
    assert not unexpected, (
        "something reads bulk_operation_log outside the read-only endpoint:\n"
        + "\n".join(unexpected))


def test_d60_cap_rejects_5001_and_accepts_5000(connection_factory, db_path):
    """The cap bounds the cost of a MISTAKE, not of the query."""
    conn = get_connection(db_path)
    conn.execute("BEGIN")
    ts = _iso_days_ago(40)
    conn.executemany(
        "INSERT INTO messages (id, account, sender_email, subject, body_plain, "
        "received_at, ingested_at) VALUES (?,?,?,?,?,?,?)",
        [(f"cap:{i:05}", "acct", f"s{i}@x.com", f"s {i}", "b", ts, ts)
         for i in range(5001)])
    conn.executemany(
        "INSERT INTO classifications (message_id, urgency_tier, category, "
        "triage_state, classified_at, rule_matches) VALUES (?,?,?,?,?,'[]')",
        [(f"cap:{i:05}", 4, "work", "new", ts) for i in range(5001)])
    conn.commit()
    conn.close()

    c = _client_for(db_path)
    over = _bulk_filter(c, state="done", tier=4, until=_iso_days_ago(30))
    assert over.status_code == 400
    body = over.get_json()
    assert body["matching"] == 5001
    assert body["limit"] == 5000
    assert "5001" in body["error"] and "5000" in body["error"], \
        "the error must name BOTH the count and the limit"

    conn = get_connection(db_path)
    assert conn.execute("SELECT COUNT(*) FROM classifications "
                        "WHERE triage_state='done'").fetchone()[0] == 0, \
        "a rejected bulk changes nothing"
    assert conn.execute("SELECT COUNT(*) FROM bulk_operation_log"
                        ).fetchone()[0] == 0, "and logs nothing"
    # Drop one so the set is exactly at the limit.
    conn.execute("DELETE FROM classifications WHERE message_id='cap:05000'")
    conn.execute("DELETE FROM messages WHERE id='cap:05000'")
    conn.commit()
    conn.close()

    at = _bulk_filter(c, state="done", tier=4, until=_iso_days_ago(30))
    assert at.status_code == 200, at.get_json()
    assert at.get_json()["updated"] == 5000, "exactly at the limit is allowed"


def test_d60_the_cap_counts_the_same_set_the_update_would_affect(
        connection_factory, db_path):
    """The §1 invariant, applied to the cap.

    If the cap counted through a different predicate than the UPDATE uses, it
    would guard a near-miss of the real set — rejecting safe operations or,
    worse, admitting oversized ones.
    """
    conn = get_connection(db_path)
    for i in range(30):
        _seed(conn, f"same:in:{i}", tier=4, days_ago=40)
    for i in range(12):
        _seed(conn, f"same:fresh:{i}", tier=4, days_ago=1)     # excluded by until
    for i in range(7):
        _seed(conn, f"same:t2:{i}", tier=2, days_ago=40)       # excluded by tier
    conn.close()
    c = _client_for(db_path)

    bound = _iso_days_ago(30)
    listed = int(c.get(f"/messages?tier=4&until={quote(bound)}&limit=500"
                       ).headers["X-Total-Count"])
    body = _bulk_filter(c, state="done", tier=4, until=bound).get_json()
    logged = c.get("/bulk-operations").get_json()[0]

    assert listed == body["matching"] == body["updated"] == logged["matched"] == 30, (
        f"list={listed} matching={body['matching']} updated={body['updated']} "
        f"logged={logged['matched']} — the cap, the update and the log disagree"
    )


def test_d60_id_mode_bulk_is_also_logged(connection_factory, db_path):
    """The explicit-id mode is a bulk operation too, and equally unreconstructable
    after the fact — the id list is gone once the request ends."""
    conn = get_connection(db_path)
    for i in range(3):
        _seed(conn, f"idlog:{i}", tier=4, days_ago=40)
    conn.close()
    c = _client_for(db_path)
    r = c.post("/messages/triage-bulk",
               json={"message_ids": ["idlog:0", "idlog:2"], "state": "done"})
    assert r.status_code == 200

    entries = c.get("/bulk-operations").get_json()
    assert len(entries) == 1
    assert entries[0]["updated"] == 2
    assert entries[0]["triage_state"] == "done"
    assert entries[0]["filter"] is None, "id mode has no filter to record"


def test_d60_log_is_newest_first_and_respects_limit(connection_factory, db_path):
    conn = get_connection(db_path)
    for i in range(6):
        _seed(conn, f"ord:{i}", tier=4, days_ago=40)
    conn.close()
    c = _client_for(db_path)
    for i in range(3):
        assert c.post("/messages/triage-bulk",
                      json={"message_ids": [f"ord:{i}"], "state": "done"}
                      ).status_code == 200

    entries = c.get("/bulk-operations").get_json()
    assert [e["id"] for e in entries] == sorted([e["id"] for e in entries],
                                                reverse=True), "newest first"
    assert len(c.get("/bulk-operations?limit=2").get_json()) == 2


# ── /health/accounts — per-account ingestion health (Session 34) ─────────────
# Regression cover for the 2026-08-13 alpha outage: the poller died, the app
# looked healthy for 13 days, and one account had been dead 17 hours before
# the process even exited. The endpoint must make a stopped poller VISIBLE.

def _set_heartbeat(db_path, account, stamp, status="ok", detail=""):
    conn = get_connection(db_path)
    PreferencesRepo(conn).set(f"poll_heartbeat:{account}", f"{stamp}|{status}|{detail}")


def test_health_accounts_ok_when_recently_polled(client, db_path):
    from unittest import mock
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc).isoformat()
    _set_heartbeat(db_path, "a@gmail.com", now)
    with mock.patch("ingestion.keychain.list_accounts", return_value=["a@gmail.com"]):
        r = client.get("/health/accounts")
    body = r.get_json()
    assert r.status_code == 200
    assert body["healthy"] is True
    assert body["accounts"][0]["status"] == "ok"


def test_health_accounts_reports_stale_when_poller_is_dead(client, db_path):
    """THE CASE THAT ACTUALLY HAPPENED: a poller that stopped writing. There is
    no error record — the process died — so staleness is the only signal."""
    from unittest import mock
    from datetime import datetime, timezone, timedelta
    old = (datetime.now(timezone.utc) - timedelta(days=13)).isoformat()
    _set_heartbeat(db_path, "a@gmail.com", old)
    with mock.patch("ingestion.keychain.list_accounts", return_value=["a@gmail.com"]):
        r = client.get("/health/accounts")
    body = r.get_json()
    assert body["healthy"] is False
    assert body["accounts"][0]["status"] == "stale"
    assert body["accounts"][0]["seconds_since"] > 13 * 24 * 3600 - 60


def test_health_accounts_flags_one_dead_account_among_healthy(client, db_path):
    """The 17-hour blind spot: with two mailboxes, one dead and one fine, the
    overall report must NOT read healthy."""
    from unittest import mock
    from datetime import datetime, timezone, timedelta
    now = datetime.now(timezone.utc)
    _set_heartbeat(db_path, "live@gmail.com", now.isoformat())
    _set_heartbeat(db_path, "dead@gmail.com",
                   (now - timedelta(hours=17)).isoformat(), "stopped",
                   "TimeoutError: The read operation timed out")
    with mock.patch("ingestion.keychain.list_accounts",
                    return_value=["live@gmail.com", "dead@gmail.com"]):
        r = client.get("/health/accounts")
    body = r.get_json()
    assert body["healthy"] is False
    by = {a["account"]: a for a in body["accounts"]}
    assert by["live@gmail.com"]["status"] == "ok"
    assert by["dead@gmail.com"]["status"] == "stopped"
    assert "TimeoutError" in by["dead@gmail.com"]["detail"]


def test_health_accounts_never_polled_account_is_not_silently_ok(client):
    """A configured account with no heartbeat must appear as 'never', not be
    omitted — an absent row reads as 'nothing wrong' to a UI."""
    from unittest import mock
    with mock.patch("ingestion.keychain.list_accounts", return_value=["fresh@gmail.com"]):
        r = client.get("/health/accounts")
    body = r.get_json()
    assert body["healthy"] is False
    assert body["accounts"][0]["status"] == "never"


def test_health_accounts_threshold_follows_poll_interval(client, db_path):
    """A widened poll interval must widen the staleness threshold, or the
    warning cries wolf every poll."""
    from unittest import mock
    from datetime import datetime, timezone, timedelta
    conn = get_connection(db_path)
    PreferencesRepo(conn).set("poll_interval_minutes", "60")
    _set_heartbeat(db_path, "a@gmail.com",
                   (datetime.now(timezone.utc) - timedelta(minutes=45)).isoformat())
    with mock.patch("ingestion.keychain.list_accounts", return_value=["a@gmail.com"]):
        r = client.get("/health/accounts")
    # 45 min of silence is fine at a 60-min cadence; it would be stale at 5.
    assert r.get_json()["accounts"][0]["status"] == "ok"


# ── D52 reclassify: the SYNCHRONOUS-DESIGN GUARD (gate item 3.4, Session 36) ──
#
# Part C of the gate-automation plan asked for "a TIMING FLOOR so a regression
# to minutes fails". Building one changed the answer, and the measurements are
# why these tests look nothing like a stopwatch.
#
# WHAT WAS MEASURED (2026-09-01, this machine, real reclassify_all):
#
#   batched commits   300 msgs 0.086s (3,491/s) · 1,200 msgs 0.295s (4,075/s)
#   commit per message 300 msgs 0.075s (3,993/s) · 1,200 msgs 0.268s (4,473/s)
#
# A per-message commit is NOT SLOWER here — 0.9x, inside noise — because the
# store is WAL-mode and a commit costs ~0.7ms on an SSD. `build_engine` costs
# 59 MICROSECONDS, so even rebuilding it per message adds only 0.33s across the
# real 5,568-message store. And an inner O(n) scan adds just 2% at n=200 and 7%
# at n=800 against ~250us/message of real work; it does not clear timer noise
# until several thousand messages.
#
# So a wall-clock guard at any size a test can afford would have been a guard
# that CANNOT FAIL. Three sabotages were run against the first draft — per-
# message commit, per-message engine rebuild, and a genuine O(n^2) scan — and
# ALL THREE PASSED IT. That draft was deleted rather than shipped with a tuned
# threshold, because a threshold tuned until a known-bad version fails is fitted
# to the sabotage, not to the risk.
#
# WHAT ACTUALLY PROTECTS THE SYNCHRONOUS DESIGN is structural, and it is worth
# stating plainly: `reclassify_one` defaults to `engine or build_engine(conn)`,
# so the loop is fast ONLY because `reclassify_all` builds the engine once and
# passes it in. That is a property of the code's shape, checkable exactly and
# without a clock — which is the same reason the streaming guard above greps for
# `fetchall()` instead of asserting megabytes.

def test_reclassify_all_builds_the_engine_ONCE_not_per_message_D52():
    """The property the synchronous design rests on, asserted by counting.

    `reclassify_one` falls back to `build_engine(conn)` when no engine is passed,
    so a refactor that drops the prebuilt engine is silent: every message would
    re-read the rules and sender groups from SQLite and the run would still be
    CORRECT, just steadily slower as rules accumulate. Counting the calls catches
    that exactly, where timing cannot — at 59us a rebuild, the whole regression
    hides inside the noise of a test-sized store.
    """
    from unittest import mock
    from db.database import get_connection
    import classification.reclassify as rc
    import tempfile, os

    d = tempfile.mkdtemp()
    path = os.path.join(d, "engine_count.db")
    init_db(path)
    conn = get_connection(path)
    rows = [(f"acct:e{i}", "acct", f"e{i}@d52.example", "s", "body",
             "2026-01-01T00:00:00+00:00", "2026-01-01T00:00:00+00:00")
            for i in range(25)]
    conn.executemany("INSERT OR REPLACE INTO messages (id, account, sender_email, "
                     "subject, body_plain, received_at, ingested_at) "
                     "VALUES (?,?,?,?,?,?,?)", rows)
    conn.executemany("INSERT OR REPLACE INTO classifications (message_id, "
                     "urgency_tier, category, triage_state, classified_at, "
                     "rule_matches) VALUES (?,5,'unknown','new',"
                     "'2026-01-01T00:00:00+00:00','[]')", [(r[0],) for r in rows])
    conn.commit()

    real = rc.build_engine
    calls = []

    def counting(c):
        calls.append(1)
        return real(c)

    with mock.patch.object(rc, "build_engine", counting):
        summary = rc.reclassify_all(conn)

    assert summary["counted"] == 25
    assert len(calls) == 1, (
        f"build_engine was called {len(calls)} times for 25 messages — it must be "
        f"built ONCE and passed into reclassify_one. Per-message rebuilding stays "
        f"correct and is invisible to a timing test (59us a call), but it makes "
        f"cost grow with the rule count on every run, and D52 skipped a job "
        f"system on the strength of this staying fast.")
    conn.close()


def test_reclassify_all_touches_each_message_exactly_once_D52(client, db_path):
    """The other half of the shape: one pass, not a pass per anything.

    A nested re-scan is the classic way a whole-store operation goes quadratic,
    and it too stays CORRECT while getting slower — the summary counts would
    still be right. Asserting each message is classified exactly once catches the
    shape at any store size, including the 25-message one a test can afford.
    """
    from unittest import mock
    import classification.reclassify as rc

    for i in range(12):
        _seed_message(db_path, msg_id=f"acct:once{i}",
                      sender=f"once{i}@d52.example", state="new", tier=5)

    seen = []
    real_one = rc.reclassify_one

    def counting(conn, row, **kw):
        seen.append(row["id"])
        return real_one(conn, row, **kw)

    with mock.patch.object(rc, "reclassify_one", counting):
        summary = rc.reclassify_all(get_connection(db_path))

    assert summary["errors"] == 0
    assert len(seen) == len(set(seen)), (
        f"reclassify_all classified some message more than once "
        f"({len(seen)} calls for {len(set(seen))} distinct messages) — that is a "
        f"nested scan, the shape that turns 'seconds' into 'minutes' at real "
        f"store sizes while every count in the summary still looks correct.")
    assert len(seen) >= 12


# ── B2: health must judge against the interval the producer is USING ──────────
#
# Observed live 2026-09-06. The interval was changed 5 min -> 1 min in Settings.
# The producer kept its startup value (B1) and polled every 300s, correctly.
# The health check read the STORED preference and expected a beat every 60s, so:
#     "detail": "no poll in 4 min (expected every 1 min)", "status": "stale"
# — repeatedly, and permanently until restart. The health banner exists because a
# poller died silently for 13 days; a warning that fires whenever someone touches
# a setting trains the user to dismiss it BEFORE the one time it is telling the
# truth.

def _set_heartbeat_with_interval(db_path, account, stamp, interval_seconds,
                                 status="ok", detail=""):
    """A heartbeat as the current producer writes it — 4 fields, the last being
    the interval it is actually using."""
    conn = get_connection(db_path)
    PreferencesRepo(conn).set(
        f"poll_heartbeat:{account}",
        f"{stamp}|{status}|{detail}|{interval_seconds:.0f}")


def test_health_not_stale_when_producer_polls_on_time_at_its_own_interval(client, db_path):
    """B2: the producer polls every 300s and says so; the stored pref now says
    1 minute. That is not a stale account — it is a producer that has not picked
    up the change yet, and it is still fetching mail.

    VERIFIED RED against the pre-fix endpoint:
        assert 'stale' == 'ok'   with detail
        "no poll in 4 min (expected every 1 min)"
    which is verbatim the false warning observed at the keyboard."""
    from unittest import mock
    from datetime import datetime, timezone, timedelta
    now = datetime.now(timezone.utc)
    conn = get_connection(db_path)
    PreferencesRepo(conn).set("poll_interval_minutes", "1")   # user just changed it
    # Last poll 4 minutes ago, which is ON TIME for the 300s the producer uses.
    _set_heartbeat_with_interval(
        db_path, "a@gmail.com", (now - timedelta(minutes=4)).isoformat(), 300)

    with mock.patch("ingestion.keychain.list_accounts", return_value=["a@gmail.com"]):
        body = client.get("/health/accounts").get_json()

    assert body["accounts"][0]["status"] == "ok", body["accounts"][0]
    assert body["healthy"] is True


def test_health_still_stale_when_the_producer_really_stopped(client, db_path):
    """The over-correction guard: deriving the expectation from the producer must
    not make a DEAD producer look healthy. Same 300s interval, but the last beat
    is 13 days old — the outage this endpoint exists for."""
    from unittest import mock
    from datetime import datetime, timezone, timedelta
    now = datetime.now(timezone.utc)
    _set_heartbeat_with_interval(
        db_path, "a@gmail.com", (now - timedelta(days=13)).isoformat(), 300)
    with mock.patch("ingestion.keychain.list_accounts", return_value=["a@gmail.com"]):
        body = client.get("/health/accounts").get_json()
    assert body["accounts"][0]["status"] == "stale"
    assert body["healthy"] is False


def test_health_falls_back_to_the_pref_for_a_legacy_heartbeat(client, db_path):
    """A heartbeat written by an older build has 3 fields and no interval. The
    checker must fall back to the stored preference rather than mis-parsing."""
    from unittest import mock
    from datetime import datetime, timezone, timedelta
    now = datetime.now(timezone.utc)
    conn = get_connection(db_path)
    PreferencesRepo(conn).set("poll_interval_minutes", "5")
    _set_heartbeat(db_path, "a@gmail.com", (now - timedelta(minutes=2)).isoformat())
    with mock.patch("ingestion.keychain.list_accounts", return_value=["a@gmail.com"]):
        body = client.get("/health/accounts").get_json()
    assert body["accounts"][0]["status"] == "ok"


def test_health_detail_survives_an_interval_field(client, db_path):
    """The detail field is free-form and the interval is appended after it, so
    the parse must split from the RIGHT and leave the detail intact."""
    from unittest import mock
    from datetime import datetime, timezone, timedelta
    now = datetime.now(timezone.utc)
    _set_heartbeat_with_interval(
        db_path, "a@gmail.com", (now - timedelta(days=13)).isoformat(), 300,
        status="stopped", detail="KeychainError: no password")
    with mock.patch("ingestion.keychain.list_accounts", return_value=["a@gmail.com"]):
        body = client.get("/health/accounts").get_json()
    assert body["accounts"][0]["status"] == "stopped"
    assert body["accounts"][0]["detail"] == "KeychainError: no password"
