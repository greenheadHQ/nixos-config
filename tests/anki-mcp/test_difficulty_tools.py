"""The badge tools expose evidence and reuse the existing mutation receipt boundary."""

import json

import httpx
import pytest
from mcp.server.fastmcp.exceptions import ToolError

from anki_mcp import syncstatus
from test_tools import FakeAnki, make_mcp


class DifficultyAnki(FakeAnki):
    def __init__(self, *, during_query=None, lose_apply_response=False):
        super().__init__()
        self.requests = []
        self.during_query = during_query
        self.lose_apply_response = lose_apply_response

    def handler(self, request):
        self.requests.append(request.url.path)
        if request.url.path == "/difficulty/query":
            assert request.headers["Authorization"] == "Bearer " + "2" * 64
            body = json.loads(request.content)
            if self.during_query:
                self.during_query()
            return httpx.Response(200, json={"ok": True, "result": {
                "cards": [{"schema_version": 1, "card_id": str(cid), "generated_at": 1700000000000,
                           "source": "local", "signals": []} for cid in body["card_ids"]],
            }})
        response = super().handler(request)
        if self.lose_apply_response and request.url.path == "/operations/apply":
            raise httpx.ReadError("synthetic lost response", request=request)
        return response

    def inspect(self, spec):
        if spec["action"] == "reassess_difficulty":
            cards = spec["params"]["card_ids"]
            return {"snapshot": {"cards": cards}, "summary": {"notes": 1, "cards": len(cards), "new_notes": 0}}
        return super().inspect(spec)


def structured(result):
    return result[1] if isinstance(result, tuple) else result


@pytest.mark.anyio
async def test_difficulty_read_captures_sync_boundary_before_query_and_never_mutates(tmp_path, monkeypatch):
    status = tmp_path / "main.json"
    before, after = "2026-10-03T01:00:00+09:00", "2026-10-04T01:00:00+09:00"
    status.write_text(json.dumps({"lastSuccessAt": before, "lastAttemptAt": before, "result": "error"}))
    fake = DifficultyAnki(during_query=lambda: status.write_text(json.dumps({
        "lastSuccessAt": after, "lastAttemptAt": after, "result": "success"})))
    mcp = make_mcp(fake, tmp_path)
    original_read = syncstatus.read_status
    reads = []

    def read_before_request(path):
        assert not fake.requests
        reads.append(path)
        return original_read(path)

    monkeypatch.setattr(syncstatus, "read_status", read_before_request)
    out = structured(await mcp.call_tool("anki_card_difficulty", {"card_ids": [10, 11]}))
    assert [card["card_id"] for card in out["cards"]] == ["10", "11"]
    assert all(card["generated_at"] == 1700000000000 for card in out["cards"])
    assert out["freshness"]["last_successful_sync_at"] == before
    assert out["freshness"]["last_attempt_result"] == "error"
    assert out["freshness"]["mobile_upload_confirmed"] is False
    assert fake.requests == ["/difficulty/query"] and reads == [str(status)]
    assert not fake.calls and not fake.helper_calls and not fake.operation_calls


@pytest.mark.anyio
@pytest.mark.parametrize("name", ["anki_card_difficulty", "anki_reassess_difficulty"])
@pytest.mark.parametrize("card_ids", [[], [True], [0], [-1], [10.0], ["10"], list(range(1, 102))])
async def test_card_ids_are_strict_bounded_and_rejected_before_io(tmp_path, name, card_ids):
    fake = DifficultyAnki()
    mcp = make_mcp(fake, tmp_path)
    with pytest.raises(ToolError):
        await mcp.call_tool(name, {"card_ids": card_ids})
    assert not fake.requests and not fake.operation_calls


@pytest.mark.anyio
async def test_difficulty_read_accepts_the_documented_maximum_and_unknown_sync_boundary(tmp_path):
    fake = DifficultyAnki()
    out = structured(await make_mcp(fake, tmp_path).call_tool(
        "anki_card_difficulty", {"card_ids": list(range(1, 101))}))
    assert len(out["cards"]) == 100
    assert out["freshness"]["last_successful_sync_at"] is None
    assert out["freshness"]["last_attempt_result"] is None
    assert fake.requests == ["/difficulty/query"] and not fake.operation_calls


@pytest.mark.anyio
async def test_reassessment_reuses_its_receipt_and_rejects_changed_targets(tmp_path):
    fake = DifficultyAnki()
    mcp = make_mcp(fake, tmp_path)
    args = {"card_ids": [11, 10, 11], "request_id": "difficulty-retry-01"}
    first = structured(await mcp.call_tool("anki_reassess_difficulty", args))
    again = structured(await mcp.call_tool("anki_reassess_difficulty", args))
    assert first["state"] == again["state"] == "applied"
    assert first["operation_id"] == again["operation_id"]
    assert first["action"] == "reassess_difficulty" and first["schema_required"] is False
    assert fake.operation_calls == [{"action": "reassess_difficulty", "params": {"card_ids": [10, 11]}}]
    assert fake.requests.count("/operations/apply") == 1
    assert not fake.calls
    with pytest.raises(ToolError, match="request-id-payload-mismatch"):
        await mcp.call_tool("anki_reassess_difficulty", {**args, "card_ids": [12]})
    assert len(fake.operation_calls) == 1


@pytest.mark.anyio
@pytest.mark.parametrize("count", [20, 21])
async def test_reassessment_bulk_boundary_keeps_preview_and_restore_protection(tmp_path, count):
    fake = DifficultyAnki()
    mcp = make_mcp(fake, tmp_path)
    args = {"card_ids": list(range(1, count + 1)), "request_id": "difficulty-bulk-01", "confirm": True}
    preview = structured(await mcp.call_tool("anki_reassess_difficulty", args))
    if count == 20:
        assert preview["state"] == "applied" and len(fake.operation_calls) == 1
        assert not preview["confirmation_required"] and not preview["backup_required"]
    else:
        assert preview["state"] == "prepared" and not fake.operation_calls
        assert preview["confirmation_required"] and preview["backup_required"]
        fake.engine.restore = lambda _: {"mirrored": False}
        confirmed = {**args, "preview_token": preview["preview_token"]}
        with pytest.raises(ToolError, match="restore-point-not-mirrored"):
            await mcp.call_tool("anki_reassess_difficulty", confirmed)
        assert not fake.operation_calls


@pytest.mark.anyio
async def test_confirmed_bulk_reassessment_applies_once_with_a_verified_restore_point(tmp_path):
    fake = DifficultyAnki()
    mcp = make_mcp(fake, tmp_path)
    args = {"card_ids": list(range(1, 22)), "request_id": "difficulty-confirmed-01"}
    preview = structured(await mcp.call_tool("anki_reassess_difficulty", args))
    assert preview["state"] == "prepared" and not fake.operation_calls
    confirmed = {**args, "preview_token": preview["preview_token"], "confirm": True}
    out = structured(await mcp.call_tool("anki_reassess_difficulty", confirmed))
    assert out["state"] == "applied" and out["backup"]["mirrored"] is True
    assert fake.operation_calls == [{"action": "reassess_difficulty", "params": {"card_ids": list(range(1, 22))}}]
    assert fake.requests.count("/operations/apply") == 1


@pytest.mark.anyio
async def test_lost_reassessment_response_is_unknown_and_same_request_recovers_without_reapplying(tmp_path):
    fake = DifficultyAnki(lose_apply_response=True)
    mcp = make_mcp(fake, tmp_path)
    args = {"card_ids": [10], "request_id": "difficulty-lost-01"}
    lost = structured(await mcp.call_tool("anki_reassess_difficulty", args))
    assert lost["state"] == "unknown" and len(fake.operation_calls) == 1
    recovered = structured(await mcp.call_tool("anki_reassess_difficulty", args))
    assert recovered["state"] == "applied" and recovered["operation_id"] == lost["operation_id"]
    assert len(fake.operation_calls) == fake.requests.count("/operations/apply") == 1


@pytest.mark.anyio
async def test_difficulty_metadata_preserves_evidence_and_user_choice_contract(tmp_path):
    catalog = {tool.name: tool for tool in await make_mcp(DifficultyAnki(), tmp_path).list_tools()}
    read, change = catalog["anki_card_difficulty"], catalog["anki_reassess_difficulty"]
    assert read.annotations.readOnlyHint is True and change.annotations.readOnlyHint is False
    for tool in (read, change):
        assert tool.annotations.destructiveHint is False
        assert tool.annotations.idempotentHint is True
        assert tool.annotations.openWorldHint is False
        cards = tool.inputSchema["properties"]["card_ids"]
        assert cards["minItems"] == 1 and cards["maxItems"] == 100
        assert cards["items"]["type"] == "integer" and cards["items"]["exclusiveMinimum"] == 0
    assert "Again" in read.description and "Hard" in read.description and "motivation" in read.description
    assert "synced" in read.description and "Unuploaded" in read.description
    assert "explain why and ask before calling" in change.description
    assert "ordinary edits do not reset" in change.description
    assert "request_id" in change.description and "capacity" in change.description
