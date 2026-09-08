import json

import httpx
import pytest
from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError

from anki_mcp.ankiconnect import AnkiConnect
from anki_mcp.helper import Helper
from anki_mcp.syncstatus import SyncNow
from anki_mcp.tools import ADDED_TAG, Deps, register_tools


class FakeAnki:
    """AnkiConnect + 헬퍼 /status를 흉내 내는 httpx MockTransport 핸들러. 받은 요청을 기록한다."""

    def __init__(self, busy=None):
        self.calls = []
        self.busy = busy
        self.notes = {
            1: {"noteId": 1, "modelName": "Basic", "tags": ["x"], "cards": [10],
                "fields": {"Front": {"value": "F" * 30, "order": 0}, "Back": {"value": "B", "order": 1}}},
        }

    def handler(self, request: httpx.Request) -> httpx.Response:
        if request.url.path == "/status":
            return httpx.Response(200, json={"ok": True, "result": {"busy": self.busy, "collection_open": True,
                                                                     "login": {"status": "logged-in"}, "addon_version": "t"}})
        body = json.loads(request.content)
        action, params = body["action"], body.get("params", {})
        self.calls.append((action, params))
        if action == "findNotes":
            return httpx.Response(200, json={"result": [1] * 3, "error": None})
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


def make_mcp(fake: FakeAnki, tmp_path):
    client = httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))
    deps = Deps(
        anki=AnkiConnect("http://anki/", client=client),
        helper=Helper("http://helper", client=client),
        syncer=SyncNow(str(tmp_path / "main.json"), "u.service", 1),
        sync_status_file=str(tmp_path / "main.json"),
        field_chars=10,
        page_max=100,
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
    sent = [c for c in fake.calls if c[0] == "addNotes"][0][1]["notes"]
    assert len(sent) == 1 and ADDED_TAG in sent[0]["tags"] and "k" in sent[0]["tags"]
    assert structured["added"] == 1 and structured["results"][1]["error"] == "duplicate"


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
async def test_card_reviews_sends_integer_ids_and_returns_revlog_objects(tmp_path):
    fake = FakeAnki()
    mcp = make_mcp(fake, tmp_path)
    result = await mcp.call_tool("anki_card_reviews", {"card_ids": [10, 11]})
    structured = result[1] if isinstance(result, tuple) else result
    assert [c for c in fake.calls if c[0] == "getReviewsOfCards"][0][1]["cards"] == [10, 11]
    assert structured["reviews"]["10"][0]["ease"] == 3 and structured["reviews"]["11"][0]["type"] == 0


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
            await Helper("http://helper", client=client).status()

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
    assert "anki_delete_notes" not in tools  # 파괴 계층은 PR 2b
