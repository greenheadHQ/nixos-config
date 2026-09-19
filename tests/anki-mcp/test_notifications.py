from urllib.parse import parse_qs

import httpx
import pytest

from anki_mcp.notifications import Notifications


pytestmark = pytest.mark.anyio
OPERATION_ID = "0123456789abcdef0123456789abcdef"
SYNCED = "AnkiWeb 동기화가 완료됐습니다."
UNCONFIRMED = "AnkiWeb 반영이 아직 확인되지 않았습니다."


def operation(**changes):
    return {
        "operation_id": OPERATION_ID,
        "action": "add_tags",
        "state": "applied",
        "summary": {"notes": 2, "cards": 5},
        "result": {"state": "applied"},
        "sync": {"state": "synced"},
        **changes,
    }


@pytest.fixture
def credentials(tmp_path):
    path = tmp_path / "pushover"
    path.write_text("PUSHOVER_TOKEN=test-app\nPUSHOVER_USER=test-user\n")
    return str(path)


async def send_payload(credentials, receipt, *, http_status=200, body=None):
    requests = []

    def handle(request):
        requests.append(request)
        return httpx.Response(http_status, json={"status": 1} if body is None else body)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
        outcome = await Notifications(credentials, client).send(receipt)
    assert len(requests) == 1
    payload = {key: values[0] for key, values in parse_qs(requests[0].content.decode()).items()}
    assert payload["token"] == "test-app"
    assert payload["user"] == "test-user"
    assert payload["priority"] == "0"
    assert requests[0].url == "https://api.pushover.net/1/messages.json"
    assert payload["message"].endswith(f"문제 문의용 작업 번호: {OPERATION_ID}")
    assert payload["message"].count(OPERATION_ID) == 1
    assert OPERATION_ID not in payload["title"]
    return outcome, payload


@pytest.mark.parametrize(
    "http_status,body,expected",
    [(200, {"status": 1}, "sent"), (200, {"status": 0}, "failed"),
     (400, {"status": 0}, "failed"), (200, [], "unknown"),
     (400, {"status": 1}, "unknown")],
)
async def test_notification_requires_api_success(credentials, http_status, body, expected):
    outcome, _ = await send_payload(credentials, operation(), http_status=http_status, body=body)
    assert outcome == expected


async def test_note_action_uses_readable_name_and_target_count(credentials):
    _, payload = await send_payload(credentials, operation())
    text = payload["title"] + "\n" + payload["message"]
    assert "태그" in payload["title"] and "추가" in payload["title"]
    assert "add_tags" not in text
    assert "대상: 노트 2개" in payload["message"]
    assert "노트 2개를 추가" not in text
    assert SYNCED in payload["message"]


async def test_card_action_counts_cards_as_targets(credentials):
    _, payload = await send_payload(credentials, operation(action="move_cards"))
    assert "카드" in payload["title"] and "이동" in payload["title"]
    assert "move_cards" not in payload["message"]
    assert "대상: 카드 5장" in payload["message"]


async def test_clearing_flags_keeps_the_count_as_scope_and_hides_internal_zero(credentials):
    _, payload = await send_payload(credentials, operation(
        action="set_card_flags", summary={"notes": 2, "cards": 5, "flag": 0},
        result={"state": "applied", "flag": 0, "card_ids": [998871, 998872, 998873, 998874, 998875]},
    ))
    text = payload["title"] + "\n" + payload["message"]
    assert "깃발 해제" in payload["title"]
    assert "깃발 해제 요청을 처리했습니다" in payload["message"]
    assert "대상: 카드 5장" in payload["message"]
    assert "카드 5장의 깃발을" not in text and "카드 5장 변경" not in text
    assert "set_card_flags" not in text and "깃발 0" not in text
    assert "99887" not in text


@pytest.mark.parametrize("added", [0, 1])
async def test_partial_add_reports_confirmed_success_without_claiming_completion(credentials, added):
    _, payload = await send_payload(credentials, operation(
        action="add_notes", state="partial",
        summary={"notes": 0, "cards": 999, "new_notes": 3, "anticipated_cards": True},
        result={"state": "partial", "added": added},
    ))
    message = payload["message"]
    assert "완료" not in payload["title"]
    assert "확인 필요" in payload["title"]
    assert "다시 실행하기 전에" in message
    assert "추가 요청: 노트 3개" in message
    assert f"노트 {added}개 추가를 확인" in message
    assert "999" not in message
    assert "변경이 적용됐습니다" not in message
    assert "요청을 처리했습니다" not in message
    assert SYNCED in message  # Sync completion does not imply the entire mutation succeeded.


async def test_add_uses_confirmed_note_count_not_estimated_card_count(credentials):
    _, payload = await send_payload(credentials, operation(
        action="add_notes", summary={"notes": 0, "cards": 987, "new_notes": 2},
        result={"state": "applied", "added": 2},
    ))
    assert "노트 2개 추가를 확인" in payload["message"]
    assert "987" not in payload["message"]
    assert "노트 0개" not in payload["message"]


async def test_missing_add_readback_does_not_promote_requested_count_to_success(credentials):
    _, payload = await send_payload(credentials, operation(
        action="add_notes", summary={"notes": 0, "cards": 987, "new_notes": 3}, result={},
    ))
    message = payload["message"]
    assert "987" not in message
    assert "3개를 추가했" not in message
    assert "3개 추가를 확인" not in message
    assert "0개를 추가했" not in message


async def test_existing_deck_receipt_does_not_claim_a_new_deck_was_created(credentials):
    _, payload = await send_payload(credentials, operation(
        action="create_deck", summary={"notes": 0, "cards": 0, "decks": ["private-existing-deck"]},
        result={"state": "applied", "deck_id": 998877},
    ))
    text = payload["title"] + "\n" + payload["message"]
    assert "덱" in payload["title"]
    assert "private-existing-deck" not in text
    assert "998877" not in text
    assert "덱 1개" not in text
    assert "생성했습니다" not in text and "생성됐습니다" not in text


@pytest.mark.parametrize("deck_name", ["private-filtered-deck", "Default"])
async def test_deck_delete_does_not_equate_affected_cards_with_deleted_cards(credentials, deck_name):
    _, payload = await send_payload(credentials, operation(
        action="delete_decks",
        summary={"notes": 2, "cards": 5, "decks": [deck_name],
                 "notes_to_remove": 0, "cards_to_remove": 0},
    ))
    text = payload["title"] + "\n" + payload["message"]
    assert "덱" in payload["title"] and "삭제" in payload["title"]
    assert "delete_decks" not in text and deck_name not in text
    assert "덱 1개" not in text
    assert "카드 5장을 삭제" not in text and "카드 5장 삭제" not in text
    assert "노트 2개를 삭제" not in text and "노트 2개 삭제" not in text


@pytest.mark.parametrize("count", [None, True, False, "7", -1, 2.5])
async def test_invalid_target_counts_are_omitted_instead_of_coerced(credentials, count):
    for action in ("add_tags", "move_cards", "add_notes"):
        _, payload = await send_payload(credentials, operation(
            action=action, summary={"notes": count, "cards": count, "new_notes": count},
            result={"state": "applied", "added": count},
        ))
        assert "대상:" not in payload["message"]
        assert "추가 요청:" not in payload["message"]
        assert "개" not in payload["message"]
        assert "카드 0장" not in payload["message"]


async def test_missing_counts_are_not_presented_as_zero(credentials):
    _, payload = await send_payload(credentials, operation(summary={}))
    assert "노트 0개" not in payload["message"]
    assert "카드 0장" not in payload["message"]
    assert "대상:" not in payload["message"]


@pytest.mark.parametrize(
    "sync,expected",
    [({"state": "pending"}, UNCONFIRMED), ({}, UNCONFIRMED),
     ({"state": "private-unrecognized-sync-state"}, UNCONFIRMED),
     ({"state": "blocked"}, "AnkiWeb 동기화가 중단되어 확인이 필요합니다."),
     ({"state": "disabled"}, "자동 동기화가 꺼져 있어 AnkiWeb 반영을 확인하지 않았습니다.")],
)
async def test_sync_states_do_not_overstate_ankiweb_delivery(credentials, sync, expected):
    _, payload = await send_payload(credentials, operation(sync=sync))
    assert expected in payload["message"]
    assert SYNCED not in payload["message"]
    assert "private-unrecognized-sync-state" not in payload["message"]


@pytest.mark.parametrize("sync", [
    {"state": "pending", "media_state": "unknown"},
    {"state": "synced", "media_state": "unknown"},
    {"state": "synced"},
])
async def test_media_requires_explicit_media_delivery_confirmation(credentials, sync):
    _, payload = await send_payload(credentials, operation(
        action="store_media", summary={"bytes": 1234},
        result={"state": "applied", "filename": "private-audio.mp3", "sha256": "private-file-hash"},
        sync=sync,
    ))
    text = payload["title"] + "\n" + payload["message"]
    assert "미디어" in payload["title"] or "파일" in payload["title"]
    assert UNCONFIRMED in payload["message"]
    assert SYNCED not in text
    assert "private-audio.mp3" not in text and "private-file-hash" not in text


async def test_unknown_action_and_receipt_details_never_leak_into_notification(credentials):
    secret = "private-operation-content-" * 100
    _, payload = await send_payload(credentials, operation(
        action=secret,
        fields={"Front": secret}, params={"tags": [secret], "deck_name": secret},
        summary={"notes": 2, "cards": 5, "decks": [secret], "warnings": [secret]},
        result={"error": secret, "filename": secret, "results": [{"error": secret}]},
        sync={"state": "blocked", "error": secret},
    ))
    text = payload["title"] + "\n" + payload["message"]
    assert "private-operation-content" not in text
    assert "Anki" in payload["title"]
    assert len(payload["message"]) < 1024


async def test_notification_timeout_is_unknown_and_sends_only_once(credentials):
    requests = []

    def handle(request):
        requests.append(request)
        raise httpx.ReadTimeout("response lost", request=request)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
        outcome = await Notifications(credentials, client).send(operation(sync={"state": "pending"}))
    assert outcome == "unknown"
    assert len(requests) == 1


async def test_invalid_json_response_is_unknown(credentials):
    def handle(request):
        return httpx.Response(200, content="not-json")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
        outcome = await Notifications(credentials, client).send(operation())
    assert outcome == "unknown"


async def test_disabled_notification_makes_no_request(tmp_path):
    def handle(request):
        pytest.fail("disabled notifications must not contact Pushover")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
        outcome = await Notifications(str(tmp_path / "missing-credentials"), client).send(operation())
    assert outcome == "disabled"
