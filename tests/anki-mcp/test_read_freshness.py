"""Collection reads expose sync provenance without performing another sync."""

import json

import httpx
import pytest

from anki_mcp import syncstatus
from test_tools import FakeAnki, make_mcp

SUCCESS = "2026-09-19T10:00:00.123456789+09:00"
ATTEMPT = "2026-09-19T10:05:00+09:00"
LATER = "2026-09-19T10:10:00+09:00"


def write_status(path, **extra):
    path.write_text(json.dumps({"lastSuccessAt": SUCCESS, "lastAttemptAt": ATTEMPT, "result": "error", **extra}))


@pytest.mark.parametrize("result", ["success", "error", "running", "busy-deferred", "full-sync-required", "schema-blocked"])
def test_latest_attempt_never_replaces_last_success(tmp_path, result):
    path = tmp_path / "main.json"
    write_status(path, result=result, sync={"before": "invalid-counts"}, error="private diagnostic")
    freshness = syncstatus.read_freshness(str(path))
    assert freshness["last_successful_sync_at"] == SUCCESS
    assert freshness["last_attempt_at"] == ATTEMPT
    assert freshness["last_attempt_result"] == result
    assert freshness["source"] == "host_collection"
    assert freshness["mobile_upload_confirmed"] is False
    assert "sync AnkiMobile first" in freshness["notice"]
    assert "anki_sync_now and query again" in freshness["notice"]
    assert "not proof a sync is still running" in freshness["notice"]
    assert "private diagnostic" not in json.dumps(freshness)
    assert "invalid-counts" not in json.dumps(freshness)


@pytest.mark.parametrize("contents", [None, "broken JSON", "null", "[]", "{}", '{"result":"running"}',
                                     '{"result":"success","lastAttemptAt":"2026-09-19T10:05:00+09:00"}'])
def test_no_success_evidence_is_unknown_even_when_latest_attempt_says_success(tmp_path, contents):
    path = tmp_path / "main.json"
    if contents is not None:
        path.write_text(contents)
    freshness = syncstatus.read_freshness(str(path))
    assert freshness["last_successful_sync_at"] is None
    assert freshness["mobile_upload_confirmed"] is False
    assert "null means unknown" in freshness["notice"]


@pytest.mark.parametrize("value", [None, True, 1789794000, {}, [], "", "not a time", "2026-09-19", "2026-09-19T10:00:00"])
def test_invalid_or_timezone_free_timestamps_remain_unknown(tmp_path, value):
    path = tmp_path / "main.json"
    write_status(path, lastSuccessAt=value, lastAttemptAt=value, result={"unsafe": "nested"})
    freshness = syncstatus.read_freshness(str(path))
    assert freshness["last_successful_sync_at"] is None
    assert freshness["last_attempt_at"] is None
    assert freshness["last_attempt_result"] is None


class ReadProbe(FakeAnki):
    def __init__(self, on_request=None):
        super().__init__()
        self.requests = []
        self.on_request = on_request

    def handler(self, request):
        body = json.loads(request.content) if request.content else {}
        self.requests.append(body.get("action") or request.url.path)
        if self.on_request:
            self.on_request()
        helper_results = {"/media": {"files": ["diagram.svg"]}, "/deck-options": {"preset_id": 1},
                          "/model-info": {"fields": ["Front", "Back"]}}
        if request.url.path in helper_results:
            assert request.headers["Authorization"] == "Bearer " + "2" * 64
            return httpx.Response(200, json={"ok": True, "result": helper_results[request.url.path]})
        anki_results = {
            "modelNames": ["Basic"], "modelFieldNames": ["Front", "Back"], "modelTemplates": {"Card 1": {}},
            "findCards": [] if body.get("params", {}).get("query") == "none" else [10],
            "cardsInfo": [{"cardId": 10, "note": 1, "question": "Q" * 30, "answer": "A"}], "getTags": ["x"],
        }
        if body.get("action") in anki_results:
            assert body["key"] == "1" * 64
            return httpx.Response(200, json={"result": anki_results[body["action"]], "error": None})
        return super().handler(request)


READ_CASES = [
    ("anki_decks", {}, ["deckNamesAndIds", "getDeckStats"], "decks"),
    ("anki_models", {}, ["modelNames"], "models"),
    ("anki_models", {"name": "Basic"}, ["modelFieldNames", "modelTemplates"], "fields"),
    ("anki_find_notes", {"query": "deck:A", "limit": 2}, ["findNotes", "notesInfo"], "notes"),
    ("anki_find_notes", {"query": "deck:A", "offset": 100}, ["findNotes"], "notes"),
    ("anki_note_info", {"note_ids": [1]}, ["notesInfo"], "notes"),
    ("anki_note_info", {"note_ids": []}, [], "notes"),
    ("anki_find_cards", {"query": "deck:A"}, ["findCards", "cardsInfo"], "cards"),
    ("anki_find_cards", {"query": "none"}, ["findCards"], "cards"),
    ("anki_card_reviews", {"card_ids": [10]}, ["getReviewsOfCards"], "reviews"),
    ("anki_tags", {}, ["getTags"], "tags"),
    ("anki_media", {}, ["/media"], "files"),
    ("anki_deck_options", {"deck_name": "A"}, ["/deck-options"], "preset_id"),
    ("anki_model_info", {"model_name": "Basic"}, ["/model-info"], "fields"),
]


@pytest.mark.anyio
@pytest.mark.parametrize("name,arguments,requests,data_key", READ_CASES)
async def test_read_metadata_precedes_query_and_adds_no_http_or_sync(tmp_path, monkeypatch, name, arguments, requests, data_key):
    path = tmp_path / "main.json"
    write_status(path)
    # A timer may finish a sync while AnkiConnect is servicing a read. Do not
    # attach that newer timestamp to data fetched before the sync completed.
    fake = ReadProbe(lambda: write_status(path, lastSuccessAt=LATER, lastAttemptAt=LATER, result="success"))
    mcp = make_mcp(fake, tmp_path)
    original_read, status_reads = syncstatus.read_status, []

    def counted_read(filename):
        status_reads.append(filename)
        assert not fake.requests
        return original_read(filename)

    monkeypatch.setattr(syncstatus, "read_status", counted_read)
    result = await mcp.call_tool(name, arguments)
    out = result[1] if isinstance(result, tuple) else result
    assert data_key in out
    assert out["freshness"]["last_successful_sync_at"] == SUCCESS
    assert out["freshness"]["last_attempt_result"] == "error"
    assert fake.requests == requests
    assert status_reads == [str(path)]
    assert not fake.operation_calls
    if name == "anki_find_notes" and not arguments.get("offset"):
        assert out["page"]["next_offset"] == 2
        assert out["notes"][0]["fields"]["Front"].startswith("F" * 10 + "…")
    if name == "anki_note_info" and arguments["note_ids"]:
        assert out["notes"][0]["fields"]["Front"] == "F" * 30
    if name == "anki_find_cards" and arguments["query"] != "none":
        assert out["cards"][0]["question"].startswith("Q" * 10 + "…")


@pytest.mark.anyio
@pytest.mark.parametrize("failure", ["missing", "malformed", "invalid-utf8", "permission", "bad-shape"])
async def test_unavailable_sync_metadata_does_not_break_a_successful_note_read(tmp_path, monkeypatch, failure):
    path = tmp_path / "main.json"
    if failure == "malformed":
        path.write_text("{broken")
    elif failure == "invalid-utf8":
        path.write_bytes(b"\xff\xfe")
    elif failure == "bad-shape":
        path.write_text('{"sync":true,"lastSuccessAt":[],"result":false}')
    elif failure == "permission":
        def unreadable(*args, **kwargs):
            raise PermissionError("private path")
        monkeypatch.setattr(syncstatus, "open", unreadable, raising=False)
    fake = ReadProbe()
    result = await make_mcp(fake, tmp_path).call_tool("anki_note_info", {"note_ids": [1]})
    out = result[1] if isinstance(result, tuple) else result
    assert out["notes"][0]["noteId"] == 1
    assert out["freshness"]["last_successful_sync_at"] is None
    assert fake.requests == ["notesInfo"]


@pytest.mark.anyio
async def test_each_read_observes_the_current_status_file_without_caching(tmp_path):
    path = tmp_path / "main.json"
    write_status(path)
    mcp = make_mcp(ReadProbe(), tmp_path)
    result = await mcp.call_tool("anki_note_info", {"note_ids": [1]})
    first = result[1] if isinstance(result, tuple) else result
    write_status(path, result="success", lastSuccessAt=LATER, lastAttemptAt=LATER)
    result = await mcp.call_tool("anki_note_info", {"note_ids": [1]})
    second = result[1] if isinstance(result, tuple) else result
    assert first["freshness"]["last_successful_sync_at"] == SUCCESS
    assert second["freshness"]["last_successful_sync_at"] == LATER
    assert first["freshness"]["last_attempt_result"] == "error"
    assert second["freshness"]["last_attempt_result"] == "success"
