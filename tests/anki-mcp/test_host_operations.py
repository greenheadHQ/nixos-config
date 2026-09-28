import copy
import json

import pytest

from anki_host_fixture.operations import Operations, OperationError, atomic_json, decode_media, filename, validate_spec


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


def history_receipt(ops, number=1, **changes):
    record = {
        "operation_id": f"{number:032x}", "request_id": f"history-{number}",
        "action": "add_tags", "state": "applied", "created_at": number,
        "summary": {"notes": 1, "note_ids": [42]},
    }
    record.update(changes)
    atomic_json(ops._path(record["operation_id"]), record)
    return record


@pytest.mark.parametrize("action,summary,result", [
    ("update_fields", {}, {"note_id": 42}),
    ("update_fields_bulk", {}, {"results": [{"note_id": 42, "state": "applied"}]}),
    ("add_notes", {"notes": 0, "note_ids": []}, {"results": [{"noteId": None}, {"noteId": 42}]}),
    ("add_tags", {"notes": 1, "note_ids": [42]}, {}),
    ("remove_tags", {"notes": 1, "note_ids": [42]}, {}),
    ("delete_notes", {"notes": 1, "note_ids": [42]}, {}),
    ("delete_decks", {"notes": 1, "note_ids": [42]}, {}),
    ("move_cards", {"notes": 1, "note_ids": [42]}, {}),
    ("suspend_cards", {"notes": 1, "note_ids": [42]}, {}),
    ("set_card_flags", {"notes": 1, "note_ids": [42]}, {}),
    ("set_due_date", {"notes": 1, "note_ids": [42]}, {}),
])
def test_note_history_matches_known_targets_without_anki_calls(tmp_path, action, summary, result):
    ops, adapter = engine(tmp_path)
    history_receipt(ops, action=action, summary=summary, result=result)
    def no_anki(*_):
        raise AssertionError("history must only read receipts")
    adapter.inspect = adapter.apply = no_anki
    found = ops.history(note_id=42)
    assert found["note_id"] == 42
    assert found["total"] == 1 and found["undetermined"] == 0
    assert found["operations"][0]["action"] == action
    assert ops.history(note_id=43)["total"] == 0


@pytest.mark.parametrize("action", ["model_field_add", "model_css_update", "update_deck_options"])
@pytest.mark.parametrize("note_id", [42, 200])
def test_note_history_excludes_indirect_changes_before_matching_or_counting(tmp_path, action, note_id):
    ops, _ = engine(tmp_path)
    history_receipt(ops, action=action, summary={"notes": 200, "note_ids": list(range(1, 101)),
                                                "ids_truncated": True})
    assert ops.history(note_id=note_id) == {
        "note_id": note_id, "operations": [], "total": 0, "next_offset": None, "undetermined": 0,
    }


def test_note_history_filters_before_paging_and_counts_uncertain_receipts(tmp_path):
    ops, _ = engine(tmp_path)
    for number, note_id in enumerate([42, 7, 42, 7, 42], 1):
        history_receipt(ops, number, summary={"notes": 1, "note_ids": [note_id]})
    history_receipt(ops, 6, summary={"notes": 200, "note_ids": list(range(100, 200)), "ids_truncated": True})
    page = ops.history(limit=2, note_id=42)
    assert [entry["created_at"] for entry in page["operations"]] == [5, 3]
    assert page["total"] == 3 and page["next_offset"] == 2 and page["undetermined"] == 1
    last = ops.history(limit=2, offset=2, note_id=42)
    assert [entry["created_at"] for entry in last["operations"]] == [1]
    assert last["total"] == 3 and last["next_offset"] is None and last["undetermined"] == 1
    assert ops.history(offset=3, note_id=42)["operations"] == []


def test_note_history_distinguishes_note_and_card_id_caps_and_ignores_spec(tmp_path):
    ops, _ = engine(tmp_path)
    history_receipt(ops, 1, summary={"notes": 1, "note_ids": [7], "cards": 200, "ids_truncated": True})
    history_receipt(ops, 2, state="prepared", preview_token="secret-token",
                    summary={"notes": 101, "note_ids": list(range(100, 200)), "ids_truncated": True},
                    spec={"params": {"note_ids": [42], "fields": {"Front": "secret-body"}}})
    history_receipt(ops, 3, action="add_notes", state="unknown", summary={"notes": 0, "note_ids": []})
    found = ops.history(note_id=42)
    assert found["total"] == 0 and found["undetermined"] == 1
    assert "secret" not in json.dumps(found)
    assert ops.history(note_id=7)["total"] == 1


@pytest.mark.parametrize("state", ["applied", "unknown", "not-attempted"])
def test_note_history_bulk_reports_per_note_state_and_resolves_capped_summary(tmp_path, state):
    ops, _ = engine(tmp_path)
    history_receipt(ops, action="update_fields_bulk", state="partial",
                    summary={"notes": 101, "note_ids": list(range(1, 101)), "ids_truncated": True},
                    result={"results": [{"note_id": note_id, "state": state} for note_id in range(1, 102)]})
    found = ops.history(note_id=101)
    assert found["total"] == 1 and found["undetermined"] == 0
    assert found["operations"][0]["state"] == "partial"
    assert found["operations"][0]["note_state"] == state
    missing = ops.history(note_id=102)
    assert missing["total"] == 0 and missing["undetermined"] == 0


def test_note_history_incomplete_bulk_result_does_not_resolve_capped_summary(tmp_path):
    ops, _ = engine(tmp_path)
    history_receipt(ops, action="update_fields_bulk", state="unknown",
                    summary={"notes": 101, "note_ids": list(range(1, 101)), "ids_truncated": True},
                    result={"results": [{"note_id": 1, "state": "applied"}]})
    assert ops.history(note_id=101)["undetermined"] == 1


@pytest.mark.parametrize("state", ["prepared", "expired", "applied", "applying"])
def test_note_history_is_compact_and_preserves_unfiltered_receipts(tmp_path, state):
    ops, _ = engine(tmp_path)
    record = history_receipt(ops, state=state, applied_at=2, preview_token="private-token",
                             spec={"fields": {"Front": "private-body"}},
                             result={"note_id": 42, "detail": "private-result"},
                             backup={"path": "private-path"}, link_check={"detail": "private-links"},
                             sync={"state": "synced", "detail": "private-sync"})
    found = ops.history(note_id=42)
    assert found["operations"] == [{
        "operation_id": record["operation_id"], "request_id": "history-1", "action": "add_tags",
        "state": "unknown" if state == "applying" else state, "created_at": 1, "applied_at": 2,
        "sync": {"state": "synced"},
    }]
    assert "private" not in json.dumps(found)
    unfiltered = ops.history()
    assert unfiltered == {"operations": [ops.status(record["operation_id"])], "total": 1, "next_offset": None}
    assert unfiltered["operations"][0]["backup"] == record["backup"]
    assert unfiltered["operations"][0]["link_check"] == record["link_check"]
    assert ops._read(record["operation_id"]) == record


@pytest.mark.parametrize("note_id", [0, -1, True, "42", 42.0, [], {}])
def test_note_history_rejects_invalid_note_id(tmp_path, note_id):
    ops, _ = engine(tmp_path)
    with pytest.raises(OperationError, match="invalid-operation-history-page"):
        ops.history(note_id=note_id)


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


@pytest.mark.parametrize("flag", [-1, 8, True, False, "4", 1.5, None])
def test_flag_validation_is_strict_at_helper_boundary(flag):
    with pytest.raises(OperationError, match="flag-must-be"):
        validate_spec("set_card_flags", {"card_ids": [10], "flag": flag}, 5)
