"""Bulk field edits keep the existing operation boundary and recovery contract."""

import copy
import json
from types import SimpleNamespace

import pytest
from mcp.server.fastmcp.exceptions import ToolError

from anki_host_fixture.operation_adapter import AnkiAdapter
from anki_host_fixture.operations import Operations, OperationError, validate_spec
from test_operation_adapter import Col
from test_operation_service import Notify, setup
from test_tools import FakeAnki, make_mcp


def updates(*ids):
    return {"notes": [{"note_id": nid, "fields": {"Text": f"updated-{nid}"}} for nid in ids]}


class BulkNote(dict):
    def __init__(self, col, nid):
        super().__init__(col.values[nid])
        self.col, self.id = col, nid

    def card_ids(self):
        return self.col.db.list("select id from cards where nid=?", self.id)

    def note_type(self):
        return self.col.models_by_note[self.id]


def bulk_fixture(tmp_path, count=2):
    col = Col()
    col.get_config = lambda _key, default: default
    col.db.db.execute("delete from notes")
    col.db.db.execute("delete from cards")
    col.db.db.execute("delete from revlog")
    col.values = {nid: {"Text": "{{c1::old}}", "Memo": "preserve me"} for nid in range(1, count + 1)}
    col.models_by_note = {nid: copy.deepcopy(col.model) for nid in col.values}
    for nid in col.values:
        col.db.db.execute("insert into notes values(?,1,?)", (nid, json.dumps(col.values[nid])))
        col.db.db.execute("insert into cards values(?,?,1,0,0)", (nid * 10, nid))
        col.db.db.execute("insert into revlog values(?,?,3)", (nid * 100, nid * 10))

    def get_note(nid):
        if nid not in col.values:
            raise ValueError("missing note")
        return BulkNote(col, nid)

    calls, backups = [], []

    def update(*, note):
        calls.append(copy.deepcopy(note))
        col.values[note["id"]].update(note["fields"])
        col.db.db.execute("update notes set flds=? where id=?", (json.dumps(col.values[note["id"]]), note["id"]))

    def restore(opid):
        backups.append({"operation_id": opid, "notes": copy.deepcopy(col.values)})
        return {"mirrored": True, "sha256": "a" * 64}

    col.get_note = get_note
    ac = SimpleNamespace(updateNoteFields=update)
    adapter = AnkiAdapter(SimpleNamespace(col=col, _anki_host_connect_version=1,
                                          _anki_host_connect=ac, reset=lambda: None), 100)
    ops = Operations(tmp_path / "ops", adapter, restore, ttl=600, bulk_limit=20, media_limit=100)
    return SimpleNamespace(col=col, ac=ac, ops=ops, adapter=adapter, calls=calls, backups=backups)


@pytest.mark.parametrize("notes", [None, {}, [], [None], [{}], [{"note_id": 1}],
                                  [{"note_id": 1, "fields": {"Text": "x"}, "extra": 1}],
                                  [{"note_id": True, "fields": {"Text": "x"}}],
                                  [{"note_id": "1", "fields": {"Text": "x"}}],
                                  [{"note_id": 0, "fields": {"Text": "x"}}],
                                  [{"note_id": 1, "fields": {}}],
                                  [{"note_id": 1, "fields": {"Text": 3}}],
                                  [{"note_id": 1, "fields": {"Text": "x\x00"}}]])
def test_bulk_helper_rejects_malformed_updates(notes):
    with pytest.raises(OperationError):
        validate_spec("update_fields_bulk", {"notes": notes}, 100)


def test_duplicate_note_ids_are_rejected_even_when_payloads_match():
    with pytest.raises(OperationError, match="duplicate-note-id"):
        validate_spec("update_fields_bulk", updates(1, 1), 100)


@pytest.mark.parametrize("action,params", [("update_fields", {"note_id": 1, "fields": {"Text": "new"}}),
                                          ("update_fields_bulk", updates(1, 2))])
def test_small_field_edits_backup_without_extra_confirmation(tmp_path, action, params):
    r = bulk_fixture(tmp_path)
    original = copy.deepcopy(r.col.values)
    cards = r.col.db.all("select * from cards")
    reviews = r.col.db.all("select * from revlog")
    p = r.ops.prepare(action, params, "field-protection")
    assert p["backup_required"] and not p["confirmation_required"]
    assert not r.backups and not r.calls
    result = r.ops.apply(p["operation_id"], p["preview_token"])
    assert result["state"] == "applied" and len(r.backups) == 1
    assert r.backups[0]["notes"] == original
    assert all(note["Memo"] == "preserve me" for note in r.col.values.values())
    assert r.col.db.all("select * from cards") == cards
    assert r.col.db.all("select * from revlog") == reviews


@pytest.mark.parametrize("action,params", [("update_fields", {"note_id": 1, "fields": {"Text": "new"}}),
                                          ("update_fields_bulk", updates(1, 2))])
@pytest.mark.parametrize("failure", ["unmirrored", "exception"])
def test_field_edits_never_write_without_verified_backup(tmp_path, action, params, failure):
    r = bulk_fixture(tmp_path)
    def restore(_):
        if failure == "exception":
            raise OperationError("hdd-unavailable")
        return {"mirrored": False}
    r.ops.restore = restore
    p = r.ops.prepare(action, params, "failed-backup")
    with pytest.raises(OperationError, match="hdd-unavailable|not-mirrored"):
        r.ops.apply(p["operation_id"], p["preview_token"])
    assert not r.calls and r.ops.status(p["operation_id"])["state"] == "prepared"


def test_predeployment_small_field_preview_cannot_bypass_backup(tmp_path):
    r = bulk_fixture(tmp_path)
    p = r.ops.prepare("update_fields", {"note_id": 1, "fields": {"Text": "new"}}, "old-preview")
    record = r.ops._read(p["operation_id"])
    record["backup_required"] = False
    r.ops._save(record)
    result = r.ops.apply(p["operation_id"], p["preview_token"])
    assert result["backup_required"] and len(r.backups) == 1


@pytest.mark.parametrize("count", [20, 21])
def test_bulk_boundary_uses_unique_notes_and_cards(tmp_path, count):
    r = bulk_fixture(tmp_path, count)
    p = r.ops.prepare("update_fields_bulk", updates(*range(1, count + 1)), "bulk-boundary")
    assert p["summary"]["notes"] == p["summary"]["cards"] == count
    assert p["backup_required"] and p["confirmation_required"] is (count > 20)
    if count > 20:
        with pytest.raises(OperationError, match="explicit-confirmation"):
            r.ops.apply(p["operation_id"], p["preview_token"])
        assert not r.backups and not r.calls
    result = r.ops.apply(p["operation_id"], p["preview_token"], count > 20)
    assert result["result"]["updated"] == count
    assert result["result"]["attempted"] == count
    assert len(r.backups) == 1


def test_same_cloze_ordinals_on_different_notes_count_separately(tmp_path):
    r = bulk_fixture(tmp_path)
    params = {"notes": [{"note_id": nid, "fields": {"Text": " ".join("{{c%d::new}}" % i for i in range(2, 12))}}
                        for nid in (1, 2)]}
    p = r.ops.prepare("update_fields_bulk", params, "bulk-cloze")
    assert p["summary"]["notes"] == 2 and p["summary"]["cards"] == 22
    assert p["confirmation_required"] and not r.calls


@pytest.mark.parametrize("invalid", ["unknown-field", "missing-note"])
def test_all_items_are_prevalidated_before_backup_or_mutation(tmp_path, invalid):
    r = bulk_fixture(tmp_path)
    params = updates(1, 2)
    if invalid == "unknown-field":
        params["notes"][1]["fields"] = {"Missing": "bad"}
    else:
        params["notes"][1]["note_id"] = 999
    with pytest.raises(OperationError, match="unknown-note-field|note-not-found"):
        r.ops.prepare("update_fields_bulk", params, "all-validated")
    assert not r.calls and not r.backups and not list(r.ops.root.glob("*.json"))


@pytest.mark.parametrize("changed", ["note", "model", "cards", "reviews"])
@pytest.mark.parametrize("when", ["before-backup", "during-backup"])
def test_bulk_preview_rejects_every_relevant_stale_component(tmp_path, changed, when):
    r = bulk_fixture(tmp_path)
    p = r.ops.prepare("update_fields_bulk", updates(1, 2), "stale-bulk")
    def mutate(_=None):
        if changed == "note":
            r.col.db.db.execute("update notes set flds='external' where id=2")
        elif changed == "model":
            r.col.models_by_note[2]["css"] = ".external{}"
        elif changed == "cards":
            r.col.db.db.execute("insert into cards values(21,2,1,0,1)")
        else:
            r.col.db.db.execute("insert into revlog values(999,20,4)")
        return {"mirrored": True}
    if when == "before-backup":
        mutate()
    else:
        r.ops.restore = mutate
    with pytest.raises(OperationError, match="stale-preview"):
        r.ops.apply(p["operation_id"], p["preview_token"])
    assert not r.calls


@pytest.mark.parametrize("failure", ["before-write", "after-write", "readback-mismatch"])
def test_partial_stops_on_uncertain_item_and_retry_never_repeats(tmp_path, failure):
    r = bulk_fixture(tmp_path, 3)
    update = r.ac.updateNoteFields
    def uncertain(*, note):
        if note["id"] != 2:
            return update(note=note)
        if failure == "after-write":
            update(note=note)
        if failure != "readback-mismatch":
            raise RuntimeError("private exception text must not escape")
    r.ac.updateNoteFields = uncertain
    params = updates(1, 2, 3)
    p = r.ops.prepare("update_fields_bulk", params, "partial-bulk")
    result = r.ops.apply(p["operation_id"], p["preview_token"])
    assert result["state"] == "partial"
    assert result["result"] == {"state": "partial", "updated": 1, "attempted": 2, "results": [
        {"note_id": 1, "state": "applied"},
        {"note_id": 2, "state": "unknown", "error": "field-update-result-unknown"},
        {"note_id": 3, "state": "not-attempted"}]}
    assert r.col.values[3]["Text"] == "{{c1::old}}"
    calls = copy.deepcopy(r.calls)
    assert r.ops.prepare("update_fields_bulk", params, "partial-bulk") == result
    assert r.ops.apply(p["operation_id"], "ignored") == result
    assert r.calls == calls and len(r.backups) == 1
    record = r.ops._path(p["operation_id"]).read_text()
    assert "private exception" not in record and "updated-" not in record
    assert "spec\"" not in record


def test_bulk_success_retry_and_changed_payload_are_bound_to_one_operation(tmp_path):
    r = bulk_fixture(tmp_path)
    params = updates(2, 1)
    p = r.ops.prepare("update_fields_bulk", params, "retry-bulk")
    result = r.ops.apply(p["operation_id"], p["preview_token"])
    assert [entry["note_id"] for entry in result["result"]["results"]] == [2, 1]
    assert r.ops.prepare("update_fields_bulk", params, "retry-bulk") == result
    assert len(r.calls) == 2 and len(r.backups) == 1
    with pytest.raises(OperationError, match="payload-mismatch"):
        r.ops.prepare("update_fields_bulk", updates(1, 2), "retry-bulk")


@pytest.mark.anyio
async def test_bulk_is_one_operation_one_sync_pair_and_one_notification(tmp_path):
    notification = Notify()
    service, helper, syncer, adapter = setup(tmp_path, notify=notification)
    result = await service.run("update_fields_bulk", updates(1, 2, 3), request_id="one-bulk-job")
    again = await service.run("update_fields_bulk", updates(1, 2, 3), request_id="one-bulk-job")
    assert result == again and result["backup_required"]
    assert len(adapter.calls) == len(notification.calls) == 1
    assert syncer.calls == [None, 1000]
    assert helper.calls.count("/operations/apply") == 1


@pytest.mark.anyio
async def test_bulk_tool_contract_and_single_tool_remain_available(tmp_path):
    fake = FakeAnki()
    mcp = make_mcp(fake, tmp_path)
    listed = {tool.name: tool for tool in await mcp.list_tools()}
    assert listed["anki_update_note_fields"].annotations.idempotentHint is True
    assert listed["anki_update_notes_fields"].annotations.readOnlyHint is False
    assert listed["anki_update_notes_fields"].annotations.idempotentHint is True
    payload = {**updates(1, 2), "request_id": "mcp-bulk-job"}
    for _ in range(2):
        result = await mcp.call_tool("anki_update_notes_fields", payload)
        receipt = result[1] if isinstance(result, tuple) else result
        assert receipt["state"] == "applied" and receipt["backup_required"]
    assert fake.operation_calls == [{"action": "update_fields_bulk", "params": updates(1, 2)}]
    assert not fake.calls


@pytest.mark.anyio
@pytest.mark.parametrize("bad", [[], [{"note_id": True, "fields": {"Text": "x"}}],
                                [{"note_id": "1", "fields": {"Text": "x"}}],
                                [{"note_id": 1, "fields": {}}],
                                [{"note_id": 1, "fields": {"Text": "x"}, "extra": 1}]])
async def test_bulk_tool_rejects_bad_structure_before_helper_request(tmp_path, bad):
    fake = FakeAnki()
    mcp = make_mcp(fake, tmp_path)
    with pytest.raises(ToolError):
        await mcp.call_tool("anki_update_notes_fields", {"notes": bad})
    assert not fake.calls and not fake.operation_calls
    assert not list((tmp_path / "operations").glob("*.json"))
