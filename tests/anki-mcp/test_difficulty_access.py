"""Exercise the authenticated helper route without opening a user's collection."""

import importlib
import threading

import httpx
import pytest

from anki_host_fixture.access import Access
from test_local_access import credentials, runtime  # noqa: F401


@pytest.fixture
def client(runtime):
    runtime.aqt.mw.col = object()
    server = runtime._Server(("127.0.0.1", 0), runtime._Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with httpx.Client(base_url=f"http://127.0.0.1:{server.server_port}", trust_env=False) as http:
            yield http
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def headers(role):
    number = {"read": "1", "operation": "2", "maintenance": "3", "schema": "4"}[role]
    return {"Authorization": "Bearer " + number * 64}


def policy(runtime):
    return importlib.import_module(runtime.__name__ + ".difficulty")


def test_difficulty_route_has_read_authority_but_no_maintenance_or_method_passthrough(credentials):
    access = Access(str(credentials))
    for role in (None, "read", "operation", "maintenance", "schema"):
        assert access.allowed("POST", "/difficulty/query", role) is (role in ("read", "operation", "schema"))
        for method in ("GET", "PUT", "DELETE"):
            assert not access.allowed(method, "/difficulty/query", role)
        assert not access.allowed("POST", "/difficulty/reassess", role)


def test_http_authentication_and_role_checks_run_before_policy(client, runtime, monkeypatch):
    monkeypatch.setattr(policy(runtime), "card_payload", lambda *_args, **_kwargs: pytest.fail("unauthorized query"))
    assert client.post("/difficulty/query", json={"card_ids": [10]}).status_code == 401
    assert client.post("/difficulty/query", headers={"Authorization": "Bearer " + "f" * 64},
                       json={"card_ids": [10]}).status_code == 401
    assert client.post("/difficulty/query", headers=headers("maintenance"), json={"card_ids": [10]}).status_code == 403
    assert client.get("/difficulty/query", headers=headers("read")).status_code == 403


@pytest.mark.parametrize("body", [
    {}, {"card_ids": []}, {"card_ids": [True]}, {"card_ids": [0]}, {"card_ids": [-1]},
    {"card_ids": [10.0]}, {"card_ids": ["10"]}, {"card_ids": list(range(1, 102))},
    {"card_ids": [10], "model_name": "Basic"}, {"card_ids": [10], "cutoff": 0},
    {"card_ids": [10], "confirm": True},
])
def test_invalid_queries_cannot_override_scope_or_reach_collection(client, runtime, monkeypatch, body):
    monkeypatch.setattr(policy(runtime), "card_payload", lambda *_args, **_kwargs: pytest.fail("invalid query"))
    response = client.post("/difficulty/query", headers=headers("read"), json=body)
    assert response.status_code == 400


@pytest.mark.parametrize("role", ["read", "operation", "schema"])
def test_query_reads_only_normalized_explicit_cards_and_never_enters_operation_or_sync(
    client, runtime, monkeypatch, role,
):
    collection, seen = object(), []
    runtime.aqt.mw.col = collection

    def read(col, cid, *, now):
        assert col is collection and type(now) is int and now > 0
        seen.append(cid)
        return {"schema_version": 1, "card_id": str(cid), "generated_at": now, "source": "local", "signals": []}

    monkeypatch.setattr(policy(runtime), "card_payload", read)
    monkeypatch.setattr(runtime, "_ops", lambda: pytest.fail("query entered operation journal"))
    monkeypatch.setattr(runtime, "_sync", lambda *_args: pytest.fail("query triggered sync"))
    response = client.post("/difficulty/query", headers=headers(role), json={"card_ids": [11, 10, 11]})
    assert response.status_code == 200, response.text
    assert seen == [10, 11]
    assert [card["card_id"] for card in response.json()["result"]["cards"]] == ["10", "11"]
    assert runtime._busy is None


def test_busy_collection_refuses_query_before_accessing_policy(client, runtime, monkeypatch):
    monkeypatch.setattr(policy(runtime), "card_payload", lambda *_args, **_kwargs: pytest.fail("query overlapped sync"))
    monkeypatch.setattr(runtime, "_busy", "sync")
    monkeypatch.setattr(runtime, "BUSY_WAIT_SECS", 0.01)
    runtime._lock.acquire()
    try:
        response = client.post("/difficulty/query", headers=headers("read"), json={"card_ids": [10]})
        assert response.status_code == 409 and response.json()["busy"] == "sync"
    finally:
        runtime._lock.release()


def test_invalid_policy_data_is_a_definite_rejection_without_note_contents(client, runtime, monkeypatch):
    difficulty = policy(runtime)

    def invalid(*_args, **_kwargs):
        raise difficulty.DifficultyError("invalid-difficulty-anchor")

    monkeypatch.setattr(difficulty, "card_payload", invalid)
    response = client.post("/difficulty/query", headers=headers("read"), json={"card_ids": [10]})
    assert response.status_code == 400
    assert response.json() == {"ok": False, "error": "invalid-difficulty-anchor"}
