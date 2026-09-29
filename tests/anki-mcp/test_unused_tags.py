"""Operator authorization and journal contracts; real tag semantics live in runtime tests."""

import threading

import httpx
import pytest

from anki_host_fixture.operations import OperationError, atomic_json, validate_spec
from anki_host_fixture.schema import SchemaOperations
from test_host_operations import engine
from test_local_access import credentials, runtime  # noqa: F401


PARAMS = {"tags": ["unused"], "protected_tags": ["keep"]}


def prepare(ops):
    return ops.prepare("remove_unused_tags", PARAMS, "unused-001", operator_authorized=True)


def test_operator_authorization_is_separate_from_schema_and_required_on_retries(tmp_path):
    ops, adapter = engine(tmp_path)
    with pytest.raises(OperationError, match="root-operator-command-required"):
        ops.prepare("remove_unused_tags", PARAMS)
    preview = prepare(ops)
    assert preview["confirmation_required"] and preview["backup_required"]
    assert preview["schema_required"] is False
    assert preview["sync"] == preview["notification"] == {"state": "disabled"}
    for schema in (False, True):
        with pytest.raises(OperationError, match="root-operator-command-required"):
            ops.apply(preview["operation_id"], preview["preview_token"], True, schema_authorized=schema)
    with pytest.raises(OperationError, match="explicit-confirmation-required"):
        ops.apply(preview["operation_id"], preview["preview_token"], operator_authorized=True)
    assert not adapter.calls
    outcome = ops.apply(preview["operation_id"], preview["preview_token"], True, operator_authorized=True)
    assert outcome["state"] == "applied" and outcome["backup"]["mirrored"]
    assert outcome["sync"] == outcome["notification"] == {"state": "disabled"}
    assert prepare(ops) == outcome
    assert ops.apply(preview["operation_id"], "lost-token", operator_authorized=True) == outcome
    assert len(adapter.calls) == 1
    with pytest.raises(OperationError, match="root-operator-command-required"):
        ops.apply(preview["operation_id"], "lost-token", True)
    for kind in ("sync", "notification"):
        with pytest.raises(OperationError, match="operator-local-action-has-no-delivery"):
            ops.record_delivery(preview["operation_id"], kind, {"state": "disabled"})


def test_unused_registry_action_cannot_enter_schema_upload_flow(tmp_path):
    ops, adapter = engine(tmp_path)
    preview = prepare(ops)
    def forbidden(*_):
        pytest.fail("local registry action must not enter schema backup or sync")
    schema = SchemaOperations(ops, "fixture", tmp_path / "approvals", forbidden, forbidden, forbidden)
    for method in (schema.inspect, schema.backup, schema.apply):
        with pytest.raises(OperationError, match="schema-operation-not-ready"):
            method(preview["operation_id"])
    assert not adapter.calls


@pytest.mark.parametrize("fault", ["unmirrored", "stale-after-backup", "expired"])
def test_operator_write_retains_backup_and_preview_guards(tmp_path, fault):
    ops, adapter = engine(tmp_path)
    preview = prepare(ops)
    if fault == "expired":
        ops.clock = lambda: 2000
    else:
        def restore(_):
            if fault == "stale-after-backup":
                adapter.snapshot["fields"] = "changed"
            return {"mirrored": fault != "unmirrored"}
        ops.restore = restore
    with pytest.raises(OperationError):
        ops.apply(preview["operation_id"], preview["preview_token"], True, operator_authorized=True)
    assert not adapter.calls


@pytest.mark.parametrize("failure", ["throw", "restart"])
def test_unknown_operator_write_never_reapplies_or_schedules_delivery(tmp_path, failure):
    ops, adapter = engine(tmp_path)
    preview = prepare(ops)
    if failure == "throw":
        adapter.fail = True
        outcome = ops.apply(preview["operation_id"], preview["preview_token"], True, operator_authorized=True)
        assert outcome["state"] == "unknown"
    else:
        record = ops._read(preview["operation_id"])
        record["state"] = "applying"
        atomic_json(ops._path(preview["operation_id"]), record)
    before = len(adapter.calls)
    restarted, _ = engine(tmp_path)
    restarted.adapter = adapter
    outcome = prepare(restarted)
    assert outcome["state"] == "unknown"
    assert outcome["sync"] == outcome["notification"] == {"state": "disabled"}
    assert restarted.apply(preview["operation_id"], "lost", True, operator_authorized=True) == outcome
    assert len(adapter.calls) == before


@pytest.mark.parametrize("params", [
    {"tags": [], "protected_tags": []}, {"tags": ["bad name"], "protected_tags": []},
    {"tags": ["unused"], "protected_tags": "keep"}, {"tags": ["unused"]},
    {**PARAMS, "all": True}, {**PARAMS, "operator_authorized": True},
])
def test_no_all_clear_or_arbitrary_parameters(params):
    with pytest.raises(OperationError):
        validate_spec("remove_unused_tags", params, 100)


def test_fixed_operator_routes_and_generic_routes_cannot_lend_authority(runtime, monkeypatch, tmp_path):
    ops, adapter = engine(tmp_path)
    monkeypatch.setattr(runtime, "OperationError", OperationError)
    monkeypatch.setattr(runtime, "_ops", lambda: ops)
    monkeypatch.setattr(runtime, "_operations", ops)
    server = runtime._Server(("127.0.0.1", 0), runtime._Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with httpx.Client(base_url=f"http://127.0.0.1:{server.server_port}", trust_env=False) as client:
            op = {"Authorization": "Bearer " + "2" * 64}
            root = {"Authorization": "Bearer " + "4" * 64}
            for role in ("1", "2", "3"):
                for path in ("inspect", "prepare", "apply"):
                    assert client.post("/tags/unused/" + path, json={},
                                       headers={"Authorization": "Bearer " + role * 64}).status_code == 403
            for headers in (op, root):
                response = client.post("/operations/prepare", headers=headers,
                                       json={"action": "remove_unused_tags", "params": PARAMS})
                assert response.status_code == 400
            response = client.post("/tags/unused/prepare", headers=root, json=PARAMS)
            assert response.status_code == 200, response.text
            preview = response.json()["result"]
            payload = {"operation_id": preview["operation_id"], "preview_token": preview["preview_token"], "confirm": True}
            for headers in (op, root):
                response = client.post("/operations/apply", headers=headers, json=payload)
                assert response.status_code == 400
            assert not adapter.calls
            outcome = client.post("/tags/unused/apply", headers=root, json=payload).json()["result"]
            assert outcome["state"] == "applied" and len(adapter.calls) == 1
            other = ops.prepare("add_tags", {"note_ids": [1], "tags": ["keep"]})
            response = client.post("/tags/unused/apply", headers=root,
                                   json={"operation_id": other["operation_id"], "preview_token": other["preview_token"], "confirm": True})
            assert response.status_code == 400 and len(adapter.calls) == 1
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
