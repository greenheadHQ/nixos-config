import json

import httpx
import pytest
from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError

from anki_mcp.ankiconnect import AnkiConnect
from anki_mcp.helper import Helper
from anki_mcp.syncstatus import SyncNow
from anki_mcp.operations import OperationService
from anki_mcp.tools import ADDED_TAG, Deps, register_tools
from anki_mcp.upload import UploadTickets
from anki_host_fixture.operations import Operations, OperationError


class FakeAnki:
    """AnkiConnect + 헬퍼 /status를 흉내 내는 httpx MockTransport 핸들러. 받은 요청을 기록한다."""

    def __init__(self, busy=None):
        self.calls = []
        self.operation_calls = []
        self.helper_calls = []
        self.busy = busy
        self.notes = {
            1: {"noteId": 1, "modelName": "Basic", "tags": ["x"], "cards": [10],
                "fields": {"Front": {"value": "F" * 30, "order": 0}, "Back": {"value": "B", "order": 1}}},
        }

    def handler(self, request: httpx.Request) -> httpx.Response:
        if request.url.host == "helper":
            assert request.headers["Authorization"] == "Bearer " + "2" * 64
        if request.url.path == "/status":
            return httpx.Response(200, json={"ok": True, "result": {"busy": self.busy, "collection_open": True,
                                                                     "login": {"status": "logged-in"}, "addon_version": "t"}})
        body = json.loads(request.content)
        if request.url.path.startswith("/operations/"):
            path = request.url.path.rsplit("/", 1)[1]
            self.helper_calls.append((path, body))
            if self.busy and path not in ("status", "history"):
                return httpx.Response(409, json={"ok": False, "error": "busy", "busy": self.busy})
            try:
                if path == "status":
                    result = self.engine.status(body["operation_id"])
                elif path == "history":
                    result = self.engine.history(body.get("limit", 20), body.get("offset", 0), body.get("note_id"))
                elif path == "prepare":
                    result = self.engine.prepare(body["action"], body["params"], body.get("request_id"))
                elif path == "apply":
                    result = self.engine.apply(body["operation_id"], body["preview_token"], body.get("confirm", False))
                else:
                    result = self.engine.record_delivery(body["operation_id"], body["kind"], body["receipt"])
                return httpx.Response(200, json={"ok": True, "result": result})
            except OperationError as err:
                return httpx.Response(400, json={"ok": False, "error": str(err)})
        assert body["key"] == "1" * 64
        action, params = body["action"], body.get("params", {})
        self.calls.append((action, params))
        if action == "findNotes":
            return httpx.Response(200, json={"result": [1] * 3, "error": None})
        if action == "findCards":
            return httpx.Response(200, json={"result": [10], "error": None})
        if action == "cardsInfo":
            return httpx.Response(200, json={"result": [{"cardId": 10, "note": 1, "flags": 12}], "error": None})
        if action == "notesInfo":
            return httpx.Response(200, json={"result": [self.notes[i] for i in params["notes"]], "error": None})
        if action == "canAddNotesWithErrorDetail":
            return httpx.Response(200, json={"result": [{"canAdd": i != 1, "error": None if i != 1 else "duplicate"}
                                                        for i, _ in enumerate(params["notes"])], "error": None})
        if action == "addNotes":
            return httpx.Response(200, json={"result": [100 + i for i, _ in enumerate(params["notes"])], "error": None})
        if action == "getNumCardsReviewedToday":
            return httpx.Response(200, json={"result": 7, "error": None})
        if action == "deckNamesAndIds":
            return httpx.Response(200, json={"result": {"A": 1}, "error": None})
        if action == "getDeckStats":
            return httpx.Response(200, json={"result": {"1": {"deck_id": 1, "new_count": 2, "learn_count": 0,
                                                              "review_count": 5, "total_in_deck": 9}}, "error": None})
        if action == "addTags":
            return httpx.Response(200, json={"result": None, "error": None})
        if action == "getReviewsOfCards":
            # 실제 애드온은 revlog.cid(정수)와 비교한다 — 문자열 id는 빈 결과를 낸다
            if not all(isinstance(c, int) for c in params["cards"]):
                return httpx.Response(200, json={"result": {c: [] for c in params["cards"]}, "error": None})
            return httpx.Response(200, json={"result": {str(c): [{"id": 1700000000000, "usn": -1, "ease": 3, "ivl": 1,
                                                                   "lastIvl": 0, "factor": 2500, "time": 5000, "type": 0}]
                                                        for c in params["cards"]}, "error": None})
        return httpx.Response(200, json={"result": None, "error": f"unsupported: {action}"})

    def inspect(self, spec):
        return {"snapshot": {"fixture": True}, "summary": {"notes": 1, "cards": 1, "new_notes": 0}}

    def apply(self, spec):
        self.operation_calls.append(spec)
        if spec["action"] == "add_notes":
            return {"state": "partial", "added": 1,
                    "results": [{"noteId": 100, "error": None}, {"noteId": None, "error": "duplicate"}]}
        return {"state": "applied"}


def make_mcp(fake: FakeAnki, tmp_path):
    client = httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))
    helper = Helper("http://helper", client=client, key="2" * 64)
    fake.engine = Operations(tmp_path / "operations", fake, lambda _: {"mirrored": True},
                             ttl=600, bulk_limit=20, media_limit=5 * 1024 * 1024)
    async def no_host_commands(argv):
        raise AssertionError("unit tests must never run systemctl")
    syncer = SyncNow(str(tmp_path / "main.json"), "u.service", 1, runner=no_host_commands)
    deps = Deps(
        anki=AnkiConnect("http://anki/", client=client, key="1" * 64),
        helper=helper,
        syncer=syncer,
        sync_status_file=str(tmp_path / "main.json"),
        field_chars=10,
        page_max=100,
        operations=OperationService(helper, syncer, None, sync_enabled=False), media_max_bytes=5 * 1024 * 1024,
        public_url="https://anki.example", uploads=UploadTickets(120),
    )
    mcp = FastMCP("t")
    register_tools(mcp, deps)
    return mcp


@pytest.mark.anyio
async def test_add_notes_appends_tag_and_reports_duplicates(tmp_path):
    fake = FakeAnki()
    mcp = make_mcp(fake, tmp_path)
    result = await mcp.call_tool("anki_add_notes", {"notes": [
        {"deck_name": "A", "model_name": "Basic", "fields": {"Front": "1", "Back": "2"}, "tags": ["k"]},
        {"deck_name": "A", "model_name": "Basic", "fields": {"Front": "dup", "Back": "2"}},
    ]})
    structured = result[1] if isinstance(result, tuple) else result
    sent = fake.operation_calls[0]["params"]["notes"]
    assert len(sent) == 2 and ADDED_TAG in sent[0]["tags"] and "k" in sent[0]["tags"]
    assert structured["result"]["added"] == 1 and structured["result"]["results"][1]["error"] == "duplicate"
    assert not [c for c in fake.calls if c[0] == "addNotes"]


@pytest.mark.anyio
async def test_mutation_is_refused_while_helper_busy(tmp_path):
    fake = FakeAnki(busy="export")
    mcp = make_mcp(fake, tmp_path)
    with pytest.raises(ToolError, match="helper busy: export"):
        await mcp.call_tool("anki_add_tags", {"note_ids": [1], "tags": ["t"]})
    assert not [c for c in fake.calls if c[0] == "addTags"]


@pytest.mark.anyio
async def test_find_notes_paginates_and_truncates(tmp_path):
    fake = FakeAnki()
    mcp = make_mcp(fake, tmp_path)
    result = await mcp.call_tool("anki_find_notes", {"query": "deck:A", "limit": 2, "offset": 0})
    structured = result[1] if isinstance(result, tuple) else result
    assert structured["page"]["total"] == 3 and structured["page"]["next_offset"] == 2
    assert structured["notes"][0]["fields"]["Front"].startswith("FFFFFFFFFF…")
    assert [c for c in fake.calls if c[0] == "notesInfo"][0][1]["notes"] == [1, 1]


@pytest.mark.anyio
@pytest.mark.parametrize("name,params,actions", [
    ("anki_find_notes", {"query": "deck:A", "limit": 1}, ["findNotes", "notesInfo"]),
    ("anki_note_info", {"note_ids": [1]}, ["notesInfo"]),
])
async def test_note_tools_return_all_sibling_links_without_extra_requests(tmp_path, name, params, actions):
    fake = FakeAnki()
    fake.notes[1]["cards"] = [10, 9007199254740993, 9223372036854775807, "11", True, 0]
    result = await make_mcp(fake, tmp_path).call_tool(name, params)
    structured = result[1] if isinstance(result, tuple) else result
    note = structured["notes"][0]
    assert note["noteId"] == 1 and note["cards"] == fake.notes[1]["cards"]
    assert note["cardLinks"] == [
        {"cardId": str(cid), "cardUrl": f"https://anki.example/c/{cid}"}
        for cid in fake.notes[1]["cards"][:3]
    ]
    assert [action for action, _ in fake.calls] == actions
    assert fake.operation_calls == []


@pytest.mark.anyio
async def test_card_reviews_sends_integer_ids_and_returns_revlog_objects(tmp_path):
    fake = FakeAnki()
    mcp = make_mcp(fake, tmp_path)
    result = await mcp.call_tool("anki_card_reviews", {"card_ids": [10, 11]})
    structured = result[1] if isinstance(result, tuple) else result
    assert [c for c in fake.calls if c[0] == "getReviewsOfCards"][0][1]["cards"] == [10, 11]
    assert structured["reviews"]["10"][0]["ease"] == 3 and structured["reviews"]["11"][0]["type"] == 0


@pytest.mark.anyio
@pytest.mark.parametrize("name,argument,data_key", [
    ("anki_note_info", "note_ids", "notes"),
    ("anki_card_reviews", "card_ids", "reviews"),
])
async def test_explicit_ids_can_follow_next_offset_without_missing_or_repeating_items(tmp_path, name, argument, data_key):
    fake = FakeAnki()
    ids = list(range(1, 102))
    fake.notes = {i: {"noteId": i, "fields": {}, "cards": []} for i in ids}
    mcp = make_mcp(fake, tmp_path)

    def unpack(result):
        return result[1] if isinstance(result, tuple) else result

    first = unpack(await mcp.call_tool(name, {argument: ids}))
    assert first["page"] == {"total": 101, "offset": 0, "limit": 100, "next_offset": 100}
    assert len(first[data_key]) == 100
    second = unpack(await mcp.call_tool(name, {argument: ids, "offset": first["page"]["next_offset"]}))
    assert second["page"] == {"total": 101, "offset": 100, "limit": 100, "next_offset": None}
    returned = ([n["noteId"] for page in (first, second) for n in page[data_key]] if data_key == "notes"
                else [int(card) for page in (first, second) for card in page[data_key]])
    assert returned == ids

    catalog = {tool.name: tool for tool in await mcp.list_tools()}
    schema = catalog[name].inputSchema
    assert schema["properties"]["offset"]["type"] == "integer"
    assert schema["properties"]["offset"]["default"] == 0
    assert "offset" not in schema.get("required", [])
    assert "same" in schema["properties"]["offset"]["description"]
    assert "next_offset" in schema["properties"]["offset"]["description"]


@pytest.mark.anyio
@pytest.mark.parametrize("name,argument,data_key", [
    ("anki_note_info", "note_ids", "notes"),
    ("anki_card_reviews", "card_ids", "reviews"),
])
@pytest.mark.parametrize("ids,offset,expected_ids,next_offset", [
    ([], 0, [], None),
    ([9, 3, 7], 1, [3, 7], None),
    ([9, 3, 7], 3, [], None),
    ([9, 3, 7], 50, [], None),
    ([9, 3, 7], -1, [9, 3, 7], None),
    (list(range(1, 101)), 0, list(range(1, 101)), None),
])
async def test_explicit_id_pagination_keeps_input_order_and_empty_page_contract(
    tmp_path, name, argument, data_key, ids, offset, expected_ids, next_offset,
):
    fake = FakeAnki()
    fake.notes = {i: {"noteId": i, "fields": {}, "cards": []} for i in ids}
    result = await make_mcp(fake, tmp_path).call_tool(name, {argument: ids, "offset": offset})
    structured = result[1] if isinstance(result, tuple) else result
    returned = ([note["noteId"] for note in structured[data_key]] if data_key == "notes"
                else [int(card) for card in structured[data_key]])
    assert returned == expected_ids
    assert structured["page"]["total"] == len(ids)
    assert structured["page"]["next_offset"] == next_offset
    if not expected_ids:
        assert not fake.calls


@pytest.mark.anyio
async def test_tags_with_whitespace_or_empty_are_rejected_before_any_request(tmp_path):
    fake = FakeAnki()
    mcp = make_mcp(fake, tmp_path)
    for bad in (["foo bar"], [""], ["ok", "a\tb"]):
        with pytest.raises(ToolError, match="whitespace"):
            await mcp.call_tool("anki_add_tags", {"note_ids": [1], "tags": bad})
        with pytest.raises(ToolError, match="whitespace"):
            await mcp.call_tool("anki_remove_tags", {"note_ids": [1], "tags": bad})
    with pytest.raises(ToolError, match="whitespace"):
        await mcp.call_tool("anki_add_notes", {"notes": [
            {"deck_name": "A", "model_name": "Basic", "fields": {"Front": "1"}, "tags": ["two words"]}]})
    assert not [c for c in fake.calls if c[0] in ("addTags", "removeTags", "addNotes", "canAddNotesWithErrorDetail")]


@pytest.mark.anyio
async def test_helper_status_rejects_unexpected_response_shapes():
    from anki_mcp.helper import Helper, HelperUnavailable

    async def check(body, status=200):
        client = httpx.AsyncClient(transport=httpx.MockTransport(lambda req: httpx.Response(status, content=body)))
        with pytest.raises(HelperUnavailable):
            await Helper("http://helper", client=client, key="2" * 64).status()

    await check(b"null")
    await check(b"[1, 2]")
    await check(b'{"ok": true}')  # result 없음
    await check(b'{"ok": true, "result": {"busy": null}}', status=503)
    await check(b"not json")


@pytest.mark.anyio
async def test_tool_annotations_mark_read_and_write(tmp_path):
    mcp = make_mcp(FakeAnki(), tmp_path)
    tools = {t.name: t for t in await mcp.list_tools()}
    assert tools["anki_find_notes"].annotations.readOnlyHint is True
    assert tools["anki_add_notes"].annotations.readOnlyHint is False
    assert tools["anki_add_notes"].annotations.destructiveHint is False
    assert tools["anki_delete_notes"].annotations.destructiveHint is True
    assert tools["anki_set_due_date"].annotations.idempotentHint is False
    assert tools["anki_operation_status"].annotations.readOnlyHint is True
    assert tools["anki_recent_operations"].annotations.readOnlyHint is True
    assert tools["anki_set_card_flags"].annotations.readOnlyHint is False
    assert tools["anki_set_card_flags"].annotations.idempotentHint is True


@pytest.mark.anyio
async def test_recent_operations_keeps_default_response_and_filters_while_busy(tmp_path):
    fake = FakeAnki(busy="export")
    mcp = make_mcp(fake, tmp_path)
    for note_id in (1, 2):
        fake.engine._save({
            "operation_id": f"{note_id:032x}", "request_id": f"history-{note_id}",
            "action": "update_fields", "state": "applied", "created_at": note_id,
            "summary": {"notes": 1, "note_ids": [note_id]}, "result": {"note_id": note_id},
            "backup": {"path": "private-path"},
        })
    result = await mcp.call_tool("anki_recent_operations", {})
    unfiltered = result[1] if isinstance(result, tuple) else result
    assert unfiltered == fake.engine.history()
    assert fake.helper_calls[-1] == ("history", {"limit": 20, "offset": 0})
    result = await mcp.call_tool("anki_recent_operations", {"note_id": 1, "limit": 1, "offset": 0})
    filtered = result[1] if isinstance(result, tuple) else result
    assert filtered == {
        "note_id": 1,
        "operations": [{"operation_id": f"{1:032x}", "request_id": "history-1", "action": "update_fields",
                        "state": "applied", "created_at": 1}],
        "total": 1, "next_offset": None, "undetermined": 0,
    }
    assert fake.helper_calls[-1] == ("history", {"limit": 1, "offset": 0, "note_id": 1})
    assert not fake.calls and not fake.operation_calls


@pytest.mark.anyio
@pytest.mark.parametrize("note_id", [0, -1, True, "1", 1.0, [], {}])
async def test_recent_operations_rejects_invalid_note_id_before_helper(tmp_path, note_id):
    fake = FakeAnki()
    mcp = make_mcp(fake, tmp_path)
    with pytest.raises(ToolError):
        await mcp.call_tool("anki_recent_operations", {"note_id": note_id})
    assert not fake.helper_calls and not fake.calls


@pytest.mark.anyio
@pytest.mark.parametrize("echo", [{}, {"note_id": 2}, {"note_id": True}, {"note_id": "1"}])
async def test_recent_operations_refuses_unfiltered_or_mismatched_helper_response(tmp_path, echo):
    class OldHelper(FakeAnki):
        def handler(self, request):
            if request.url.path == "/operations/history":
                return httpx.Response(200, json={"ok": True, "result": {
                    "operations": [{"summary": "unfiltered-private-detail"}], "total": 1, "next_offset": None, **echo,
                }})
            return super().handler(request)
    mcp = make_mcp(OldHelper(), tmp_path)
    with pytest.raises(ToolError, match="note-operation-history-unavailable-update-host") as error:
        await mcp.call_tool("anki_recent_operations", {"note_id": 1})
    assert "unfiltered-private-detail" not in str(error.value)


@pytest.mark.anyio
async def test_deletion_tools_explain_retained_history_and_pre_deletion_scope(tmp_path):
    tools = {t.name: t for t in await make_mcp(FakeAnki(), tmp_path).list_tools()}
    status_description = " ".join(tools["anki_status"].description.split())
    assert "including deleted cards and manual scheduling entries" in status_description
    assert "not unique cards or only answered reviews" in status_description
    for name in ("anki_delete_notes", "anki_delete_decks"):
        description = " ".join(tools[name].description.split())
        assert "review history is" in description and "retained" in description
        assert "pre-deletion scope" in description and "not a deleted-row count" in description
        assert "measured after deletion" in description and "today_reviews" in description


@pytest.mark.anyio
async def test_flag_search_preserves_query_and_returns_current_user_flag(tmp_path):
    fake = FakeAnki()
    mcp = make_mcp(fake, tmp_path)
    result = await mcp.call_tool("anki_find_cards", {"query": "flag:4"})
    structured = result[1] if isinstance(result, tuple) else result
    assert ("findCards", {"query": "flag:4"}) in fake.calls
    assert structured["cards"][0]["flag"] == 4
    assert structured["cards"][0]["cardId"] == 10
    assert structured["cards"][0]["cardUrl"] == "https://anki.example/c/10"
    assert [action for action, _ in fake.calls] == ["findCards", "cardsInfo"]
    assert fake.operation_calls == []


@pytest.mark.anyio
async def test_flag_tool_uses_helper_and_repeated_request_does_not_reapply(tmp_path):
    fake = FakeAnki()
    mcp = make_mcp(fake, tmp_path)
    params = {"card_ids": [10, 10], "flag": 0, "request_id": "clearflag01"}
    for _ in range(2):
        result = await mcp.call_tool("anki_set_card_flags", params)
        structured = result[1] if isinstance(result, tuple) else result
        assert structured["state"] == "applied"
    assert fake.operation_calls == [{"action": "set_card_flags", "params": {"card_ids": [10], "flag": 0}}]
    assert not fake.calls  # No AnkiConnect HTTP mutation.


@pytest.mark.anyio
@pytest.mark.parametrize("invalid", [{"flag": v} for v in (-1, 8, True, "4", 1.5)]
                         + [{"card_ids": [v]} for v in (True, 0, -1, "10")])
async def test_flag_tool_rejects_invalid_input_before_request(tmp_path, invalid):
    fake = FakeAnki()
    mcp = make_mcp(fake, tmp_path)
    with pytest.raises(ToolError):
        await mcp.call_tool("anki_set_card_flags", {"card_ids": [10], "flag": 4, **invalid})
    assert not fake.operation_calls and not fake.calls
    assert not list((tmp_path / "operations").glob("*.json"))


@pytest.mark.anyio
async def test_review_memo_full_read_preserves_long_multiple_paragraphs(tmp_path):
    fake = FakeAnki()
    memo = "<p>첫 번째 질문: 왜 그런가요?</p>\n\n" + "긴 설명과 예시. " * 200 + "\n<p>두 번째 질문</p>"
    fake.notes[1]["fields"]["검토 메모"] = {"value": memo, "order": 2}
    mcp = make_mcp(fake, tmp_path)
    search = await mcp.call_tool("anki_find_notes", {"query": "tag:marked"})
    search = search[1] if isinstance(search, tuple) else search
    assert "truncated" in search["notes"][0]["fields"]["검토 메모"]
    full = await mcp.call_tool("anki_note_info", {"note_ids": [1]})
    full = full[1] if isinstance(full, tuple) else full
    assert full["notes"][0]["fields"]["검토 메모"] == memo
