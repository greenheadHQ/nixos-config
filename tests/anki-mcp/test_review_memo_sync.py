"""The last memo read precedes OperationService's pre-sync and prepare."""

import copy

import pytest

from anki_mcp.helper import HelperRejected
from anki_mcp.operations import OperationService
from test_bulk_fields import bulk_fixture
from test_operation_service import Helper, Syncer


@pytest.mark.anyio
@pytest.mark.parametrize("action", ["update_fields", "update_fields_bulk"])
@pytest.mark.parametrize("guarded,incoming", [(False, True), (True, True), (True, False)],
                         ids=["unguarded-loss-control", "guarded-changed", "guarded-unchanged"])
async def test_memo_cleanup_across_presync(tmp_path, action, guarded, incoming):
    r = bulk_fixture(tmp_path, 3)
    selected = [1, 2] if action == "update_fields_bulk" else [1]
    observed = {nid: r.col.get_note(nid)["Memo"] for nid in selected}
    original = copy.deepcopy(r.col.values)
    cards = r.col.db.all("select * from cards order by id")
    reviews = r.col.db.all("select * from revlog order by id")
    events = ["read"]
    prepare_values = []
    notes_after_sync = []

    class ObservedHelper(Helper):
        async def post(self, path, payload):
            if path == "/operations/prepare":
                events.append("prepare")
                prepare_values.append(r.col.get_note(selected[-1])["Memo"])
            return await super().post(path, payload)

    class IncomingMemoSync(Syncer):
        async def run_fresh(self, *, after=None):
            if after is None:
                if incoming:
                    r.ac.updateNoteFields(note={"id": selected[-1], "fields": {"Memo": "new question B"}})
                notes_after_sync.append(copy.deepcopy(r.col.values))
                events.append("pre-sync")
            return await super().run_fresh(after=after)

    helper, syncer = ObservedHelper(r.ops), IncomingMemoSync()
    service = OperationService(helper, syncer, None, sync_enabled=True)
    updates = [{"note_id": nid, "fields": {"Memo": ""},
                **({"expected_fields": {"Memo": observed[nid]}} if guarded else {})}
               for nid in selected]
    params = {"notes": updates} if action == "update_fields_bulk" else updates[0]
    if guarded and incoming:
        with pytest.raises(HelperRejected, match="^expected-field-value-mismatch$"):
            await service.run(action, params, request_id="memo-presync-guard")
        assert r.col.values == notes_after_sync[0]
        assert helper.calls == ["/operations/status", "/operations/prepare"]
        assert syncer.calls == [None]
        assert not r.backups and not list(r.ops.root.glob("*.json"))
        # The only write was the synthetic incoming device edit, even when the
        # changed note occurs last in the bulk request.
        assert r.calls == [{"id": selected[-1], "fields": {"Memo": "new question B"}}]
    else:
        result = await service.run(action, params, request_id="memo-presync-clear")
        assert result["state"] == "applied" and result["sync"]["state"] == "synced"
        assert len(r.backups) == 1
        assert all(r.col.values[nid]["Memo"] == "" for nid in selected)
        if incoming:
            # Explicit negative control: omitting expected_fields is still a
            # supported unconditional edit, so it erases unseen B in this fixture.
            assert r.backups[0]["notes"][selected[-1]]["Memo"] == "new question B"
    assert events == ["read", "pre-sync", "prepare"]
    assert prepare_values == ["new question B" if incoming else observed[selected[-1]]]
    assert r.col.values[3] == original[3]
    assert all(r.col.values[nid]["Text"] == original[nid]["Text"] for nid in original)
    assert r.col.db.all("select * from cards order by id") == cards
    assert r.col.db.all("select * from revlog order by id") == reviews
