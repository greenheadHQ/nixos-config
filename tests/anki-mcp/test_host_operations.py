import copy
import json

import pytest

from anki_host_fixture.operations import Operations, OperationError, atomic_json, decode_media, filename


class Adapter:
    def __init__(self, count=1):
        self.count = count
        self.snapshot = {"cards": list(range(count)), "fields": "original", "reviews": ["unchanged"]}
        self.calls = []
        self.result = {"state": "applied", "changed": True}
        self.fail = False

    def inspect(self, spec):
        return {"snapshot": copy.deepcopy(self.snapshot),
                "summary": {"notes": 1, "cards": self.count, "new_notes": 0}}

    def apply(self, spec):
        self.calls.append(spec)
        self.snapshot["fields"] = "applied"
        if self.fail:
            raise RuntimeError("mutation happened before response failed")
        return self.result


def engine(tmp_path, count=1, restore=None):
    adapter = Adapter(count)
    ops = Operations(tmp_path / "ops", adapter,
                     restore or (lambda opid: {"mirrored": True, "sha256": "a" * 64, "operation_id": opid}),
                     ttl=600, bulk_limit=20, media_limit=5, clock=lambda: 1000)
    return ops, adapter


@pytest.mark.parametrize("count,confirmed", [(19, False), (20, False), (21, True)])
def test_real_card_impact_drives_bulk_boundary(tmp_path, count, confirmed):
    ops, adapter = engine(tmp_path, count)
    preview = ops.prepare("add_tags", {"note_ids": [1, 1], "tags": ["t"]}, "boundary1")
    assert preview["confirmation_required"] is confirmed
    if confirmed:
        with pytest.raises(OperationError, match="explicit-confirmation"):
            ops.apply(preview["operation_id"], preview["preview_token"])
        assert not adapter.calls
    result = ops.apply(preview["operation_id"], preview["preview_token"], confirmed)
    assert result["state"] == "applied" and len(adapter.calls) == 1
    assert adapter.calls[0]["params"]["note_ids"] == [1]


def test_deletion_always_requires_confirmation_and_verified_restore(tmp_path):
    ops, adapter = engine(tmp_path, restore=lambda _: {"mirrored": False})
    p = ops.prepare("delete_notes", {"note_ids": [1]}, "delete001")
    assert p["backup_required"] and p["confirmation_required"]
    with pytest.raises(OperationError, match="not-mirrored"):
        ops.apply(p["operation_id"], p["preview_token"], True)
    assert not adapter.calls


@pytest.mark.parametrize("where", ["before-export", "during-export"])
def test_stale_snapshot_never_applies(tmp_path, where):
    ops, adapter = engine(tmp_path)
    p = ops.prepare("delete_notes", {"note_ids": [1]}, "stale001")
    def change(_):
        adapter.snapshot["cards"].append(999)
        return {"mirrored": True}
    if where == "before-export":
        change(None)
    else:
        ops.restore = change
    with pytest.raises(OperationError, match="stale-preview"):
        ops.apply(p["operation_id"], p["preview_token"], True)
    assert not adapter.calls


def test_retry_is_bound_to_payload_and_does_not_reapply(tmp_path):
    ops, adapter = engine(tmp_path)
    params = {"note_ids": [1], "tags": ["secret-body"]}
    p = ops.prepare("add_tags", params, "request01")
    outcome = ops.apply(p["operation_id"], p["preview_token"])
    restarted, _ = engine(tmp_path)
    restarted.adapter = adapter
    assert restarted.prepare("add_tags", params, "request01") == outcome
    assert restarted.apply(p["operation_id"], "irrelevant") == outcome
    assert len(adapter.calls) == 1
    with pytest.raises(OperationError, match="payload-mismatch"):
        restarted.prepare("add_tags", {**params, "tags": ["different"]}, "request01")
    record = json.loads(ops._path(p["operation_id"]).read_text())
    assert "spec" not in record and "preview_token" not in record
    assert "secret-body" not in json.dumps(record)


@pytest.mark.parametrize("crash", ["before-call", "after-write"])
def test_interrupted_apply_is_unknown_and_never_repeated(tmp_path, crash):
    ops, adapter = engine(tmp_path)
    params = {"note_ids": [1], "tags": ["x"]}
    p = ops.prepare("add_tags", params, "crash001")
    if crash == "before-call":
        record = ops._read(p["operation_id"])
        record["state"] = "applying"
        atomic_json(ops._path(p["operation_id"]), record)
    else:
        adapter.fail = True
        assert ops.apply(p["operation_id"], p["preview_token"])["state"] == "unknown"
    before = len(adapter.calls)
    assert ops.prepare("add_tags", params, "crash001")["state"] == "unknown"
    assert ops.apply(p["operation_id"], p["preview_token"])["state"] == "unknown"
    assert len(adapter.calls) == before


def test_partial_result_and_delivery_cannot_overwrite_mutation(tmp_path):
    ops, adapter = engine(tmp_path)
    adapter.result = {"state": "partial", "added": 1, "results": [{"noteId": 42}, {"noteId": None}]}
    p = ops.prepare("add_tags", {"note_ids": [1], "tags": ["x"]}, "partial01")
    result = ops.apply(p["operation_id"], p["preview_token"])
    assert result["state"] == "partial"
    with pytest.raises(OperationError, match="invalid-sync-receipt"):
        ops.record_delivery(p["operation_id"], "sync", {"state": "synced", "spec": {}})
    assert ops.status(p["operation_id"])["state"] == "partial"


def test_preview_expiry_and_unicode_token_fail_before_apply(tmp_path):
    ops, adapter = engine(tmp_path)
    p = ops.prepare("delete_notes", {"note_ids": [1]}, "expired01")
    with pytest.raises(OperationError, match="token-mismatch"):
        ops.apply(p["operation_id"], "비밀", True)
    ops.clock = lambda: 1601
    with pytest.raises(OperationError, match="expired"):
        ops.apply(p["operation_id"], p["preview_token"], True)
    assert not adapter.calls


@pytest.mark.parametrize("name", ["../a", "/a", "a\\b", "C:a", ".hidden", "a\n", "a\x00", " a", "e\u0301.png"])
def test_media_path_refusal(name):
    with pytest.raises(OperationError):
        filename(name)


def test_media_decoded_boundary_and_strict_base64():
    assert decode_media("MTIzNDU=", 5) == b"12345"
    for value in ("MTIzNDU2", "MTIzNDU=\n", "not base64", ""):
        with pytest.raises(OperationError):
            decode_media(value, 5)
