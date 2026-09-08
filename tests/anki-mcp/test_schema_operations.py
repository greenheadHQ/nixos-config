import json
import os
import stat
from types import SimpleNamespace

import pytest

from anki_host_fixture.operations import OperationError
from anki_host_fixture.schema import SchemaOperations
from test_host_operations import engine


def schema_fixture(tmp_path, monkeypatch):
    ops, adapter = engine(tmp_path)
    p = ops.prepare("model_field_add", {"model_name": "Basic", "field_name": "Extra"}, "schema001")
    counts = {"notes": 10, "cards": 20, "revlog": 30}
    snapshot = {"digest": "d" * 64, "counts": counts}
    sync_calls = []
    def sync(before):
        sync_calls.append(before)
        return {"action": "approved-full-upload", "before": before, "after": counts, "required": "FULL_SYNC"}
    approvals = tmp_path / "approvals"
    approvals.mkdir()
    schema = SchemaOperations(ops, "test", approvals, lambda: snapshot,
                              lambda: {"notes": 10, "revlog": 30}, sync, clock=lambda: 1000)
    # Fixtures run unprivileged: emulate the root-owned approval file metadata;
    # production code still checks the actual fd owner and mode.
    fstat = os.fstat
    monkeypatch.setattr("anki_host_fixture.schema.os.fstat", lambda fd: SimpleNamespace(
        st_mode=fstat(fd).st_mode, st_uid=0, st_size=fstat(fd).st_size))
    current = schema.backup(p["operation_id"])
    approval = {"instance": "test", "operation_id": p["operation_id"], "snapshot_digest": current["snapshot_digest"],
                "baseline": current["baseline"], "counts": dict(current["counts"]),
                "backup_sha256": current["operation"]["backup"]["sha256"], "expires_at": 1500, "nonce": "e" * 32}
    path = approvals / (p["operation_id"] + ".json")
    path.write_text(json.dumps(approval))
    path.chmod(0o640)
    return schema, ops, adapter, snapshot, sync_calls, p, path, approval


def test_mcp_cannot_apply_schema_and_root_approval_is_consumed_once(tmp_path, monkeypatch):
    schema, ops, adapter, snapshot, sync_calls, p, path, approval = schema_fixture(tmp_path, monkeypatch)
    with pytest.raises(OperationError, match="root-schema-approval"):
        ops.apply(p["operation_id"], p["preview_token"], True)
    assert not adapter.calls
    result = schema.apply(p["operation_id"])
    assert result["action"] == "approved-full-upload" and len(adapter.calls) == len(sync_calls) == 1
    assert not path.exists()
    with pytest.raises(OperationError, match="already-synced"):
        schema.apply(p["operation_id"])
    assert len(adapter.calls) == 1


@pytest.mark.parametrize("fault", ["expired", "different-instance", "different-snapshot", "missing-backup", "writable"])
def test_approval_refusal_leaves_collection_unchanged(tmp_path, monkeypatch, fault):
    schema, ops, adapter, snapshot, sync_calls, p, path, approval = schema_fixture(tmp_path, monkeypatch)
    if fault == "expired": approval["expires_at"] = 999
    if fault == "different-instance": approval["instance"] = "other"
    if fault == "different-snapshot": snapshot["digest"] = "f" * 64
    if fault == "missing-backup": approval["backup_sha256"] = None
    path.write_text(json.dumps(approval))
    if fault == "writable": path.chmod(0o666)
    with pytest.raises(OperationError):
        schema.apply(p["operation_id"])
    assert adapter.calls == sync_calls == [] and path.exists()


def test_count_loss_after_local_apply_blocks_upload(tmp_path, monkeypatch):
    schema, ops, adapter, snapshot, sync_calls, p, path, approval = schema_fixture(tmp_path, monkeypatch)
    apply = adapter.apply
    def lose_reviews(spec):
        result = apply(spec)
        snapshot["counts"] = {"notes": 10, "cards": 19, "revlog": 29}
        return result
    adapter.apply = lose_reviews
    result = schema.apply(p["operation_id"])
    assert result["action"] == "schema-counts-blocked"
    assert len(adapter.calls) == 1 and sync_calls == []
    assert result["operation"]["state"] == "applied" and result["operation"]["sync"]["state"] == "blocked"


def test_upload_resume_needs_new_approval_and_does_not_repeat_apply(tmp_path, monkeypatch):
    schema, ops, adapter, snapshot, sync_calls, p, path, approval = schema_fixture(tmp_path, monkeypatch)
    good_sync = schema.sync
    schema.sync = lambda _: {"action": "schema-sync-blocked", "required": "FULL_DOWNLOAD"}
    assert schema.apply(p["operation_id"])["operation"]["sync"]["state"] == "blocked"
    with pytest.raises(FileNotFoundError):
        schema.apply(p["operation_id"])
    approval["nonce"] = "f" * 32
    path.write_text(json.dumps(approval))
    path.chmod(0o640)
    schema.sync = good_sync
    assert schema.apply(p["operation_id"])["action"] == "approved-full-upload"
    assert len(adapter.calls) == 1
