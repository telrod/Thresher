"""
D83 — the local API refuses what a web page in the user's browser can send.

Binding to 127.0.0.1 stops other machines, not other origins. Two checks in
`create_app`'s `before_request` close the gap, and each has a test here:

  - Host must be loopback. A DNS-rebound page sends its own hostname.
  - Writes (POST/PUT/PATCH) must be JSON. A form or text/plain POST is a CORS
    "simple" request, sent with no preflight, and the handlers would otherwise
    run on an empty body.

Each test asserts both the refusal and the allowed case, so it cannot pass by
refusing everything or by refusing nothing. Each was shown to fail with its
check removed from `_local_only`.
"""

import pytest

from api.app import create_app


@pytest.fixture
def client(connection_factory):
    return create_app(connection_factory=connection_factory).test_client()


def _get(client, host):
    return client.get("/messages", environ_overrides={"HTTP_HOST": host})


@pytest.mark.parametrize("host", [
    "rebind.example.org",
    "attacker.example:8765",
    "attacker.example",
    "127.0.0.1.example.org:8765",   # loopback as a prefix is not loopback
    "localhost.example.org",
    "[::1].example.org",
    "",
])
def test_foreign_host_is_refused(client, host):
    r = _get(client, host)
    assert r.status_code == 403, host
    assert r.get_json() == {"error": "forbidden host"}


@pytest.mark.parametrize("host", [
    "localhost", "localhost:8765",
    "127.0.0.1", "127.0.0.1:8765",
    "[::1]", "[::1]:8765",
    "LOCALHOST:8765",
])
def test_loopback_host_is_allowed(client, host):
    assert _get(client, host).status_code == 200, host


@pytest.mark.parametrize("content_type, data", [
    ("text/plain", "x=1"),
    ("application/x-www-form-urlencoded", "x=1"),
    ("multipart/form-data; boundary=b", "--b--\r\n"),
])
def test_non_json_write_is_refused(client, content_type, data):
    r = client.post("/messages/reclassify-all", data=data,
                    headers={"Content-Type": content_type})
    assert r.status_code == 415, content_type
    assert r.get_json() == {"error": "expected application/json"}


def test_json_write_still_works(client):
    r = client.post("/messages/reclassify-all", json={})
    assert r.status_code == 200
    assert "counted" in r.get_json()
