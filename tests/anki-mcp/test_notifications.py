import unicodedata
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
    assert len(payload["message"]) <= 1024
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


@pytest.mark.parametrize("action", ["delete_notes", "delete_decks"])
async def test_deletion_reports_measured_retained_reviews_not_preview_scope(credentials, action):
    _, payload = await send_payload(credentials, operation(
        action=action, summary={"notes": 1, "affected_review_rows": 99},
        result={"state": "applied", "retained_review_rows": 3},
    ))
    assert "기존 복습 기록 3건은 남아 있습니다." in payload["message"]
    assert "99" not in payload["message"]


@pytest.mark.parametrize("action", ["delete_notes", "delete_decks"])
@pytest.mark.parametrize("state,count", [
    ("partial", 3), ("unknown", 3), ("applied", None), ("applied", 0),
    ("applied", True), ("applied", -1), ("applied", "3"),
])
async def test_deletion_does_not_invent_history_retention_from_uncertain_receipt(credentials, action, state, count):
    _, payload = await send_payload(credentials, operation(
        action=action, state=state, summary={"notes": 1, "affected_review_rows": 99},
        result={"state": state, "retained_review_rows": count},
    ))
    assert "복습 기록" not in payload["message"]
    assert "99" not in payload["message"]


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
async def test_legacy_deck_delete_names_request_without_inventing_deleted_card_count(credentials, deck_name):
    _, payload = await send_payload(credentials, operation(
        action="delete_decks",
        summary={"notes": 2, "cards": 5, "decks": [deck_name],
                 "notes_to_remove": 0, "cards_to_remove": 0},
    ))
    text = payload["title"] + "\n" + payload["message"]
    assert "덱" in payload["title"] and "삭제" in payload["title"]
    assert "delete_decks" not in text
    assert f'삭제 요청 덱: "{deck_name}"' in payload["message"]
    assert "삭제된 카드 수는 확인되지 않았습니다." in payload["message"]
    assert "삭제한 덱:" not in payload["message"]
    assert "함께 삭제된 카드:" not in payload["message"]
    assert "대상: 카드" not in payload["message"]
    assert "덱 1개" not in text
    assert "카드 5장을 삭제" not in text and "카드 5장 삭제" not in text
    assert "노트 2개를 삭제" not in text and "노트 2개 삭제" not in text


async def test_deck_delete_reports_named_deck_and_actual_deleted_cards(credentials):
    _, payload = await send_payload(credentials, operation(
        action="delete_decks",
        summary={"notes": 42, "cards": 99, "decks": ["한국어::복습"]},
        result={"state": "applied", "deleted_decks": ["한국어::복습"],
                "retained_decks": [], "deleted_cards": 3, "retained_cards": 0},
    ))
    message = payload["message"]
    assert '삭제한 덱: "한국어::복습"' in message
    assert "함께 삭제된 카드: 3장." in message
    assert "99" not in message and "42" not in message
    assert "대상: 카드" not in message
    assert "삭제 요청 덱:" not in message
    assert message.index("삭제한 덱:") < message.index("함께 삭제된 카드:") < message.index(SYNCED)


@pytest.mark.parametrize("deleted_cards", [0, 3])
async def test_deck_delete_distinguishes_retained_default_and_surviving_cards(credentials, deleted_cards):
    _, payload = await send_payload(credentials, operation(
        action="delete_decks",
        summary={"notes": 42, "cards": 99, "decks": ["필터 덱", "Default"]},
        result={"state": "applied", "deleted_decks": ["필터 덱"],
                "retained_decks": ["Default"], "deleted_cards": deleted_cards, "retained_cards": 5},
    ))
    message = payload["message"]
    assert '삭제한 덱: "필터 덱"' in message
    assert '유지된 덱: "Default"' in message
    assert f"함께 삭제된 카드: {deleted_cards}장." in message
    assert "삭제되지 않은 카드: 5장." in message
    assert '삭제한 덱: "Default"' not in message
    assert "99" not in message and "42" not in message


async def test_default_only_delete_receipt_does_not_call_retained_deck_deleted(credentials):
    _, payload = await send_payload(credentials, operation(
        action="delete_decks", summary={"cards": 99, "decks": ["Default"]},
        result={"state": "applied", "deleted_decks": [], "retained_decks": ["Default"],
                "deleted_cards": 0, "retained_cards": 5},
    ))
    message = payload["message"]
    assert '유지된 덱: "Default"' in message
    assert "삭제한 덱:" not in message
    assert "함께 삭제된 카드: 0장." in message
    assert "삭제되지 않은 카드: 5장." in message
    assert "99" not in message


async def test_multiple_deleted_decks_keep_each_name_and_combined_measured_card_count(credentials):
    names = ["한국어 복습", "Parent::Child", "빈 덱"]
    _, payload = await send_payload(credentials, operation(
        action="delete_decks", summary={"cards": 99, "decks": names},
        result={"state": "applied", "deleted_decks": names, "retained_decks": [],
                "deleted_cards": 7, "retained_cards": 0},
    ))
    message = payload["message"]
    assert "삭제한 덱:" in message
    for name in names:
        assert f'"{name}"' in message
    assert "함께 삭제된 카드: 7장." in message
    assert "99" not in message


async def test_partial_deck_delete_reports_only_readback_and_never_claims_whole_request_completed(credentials):
    _, payload = await send_payload(credentials, operation(
        action="delete_decks", state="partial",
        summary={"cards": 99, "decks": ["삭제됨", "남아 있음"]},
        result={"state": "partial", "deleted_decks": ["삭제됨"], "retained_decks": ["남아 있음"],
                "deleted_cards": 2, "retained_cards": 4},
    ))
    message = payload["message"]
    assert "확인 필요" in payload["title"] and "완료" not in payload["title"]
    assert "요청을 처리했습니다" not in message
    assert "다시 실행하기 전에" in message
    assert '삭제한 덱: "삭제됨"' in message
    assert '유지된 덱: "남아 있음"' in message
    assert "함께 삭제된 카드: 2장." in message
    assert "삭제되지 않은 카드: 4장." in message
    assert "99" not in message


@pytest.mark.parametrize("count", [None, True, False, "7", -1, 2.5])
async def test_invalid_deleted_card_counts_never_become_confirmed_counts(credentials, count):
    _, payload = await send_payload(credentials, operation(
        action="delete_decks", summary={"cards": 99, "decks": ["시험 덱"]},
        result={"state": "applied", "deleted_decks": ["시험 덱"], "retained_decks": [],
                "deleted_cards": count, "retained_cards": count},
    ))
    message = payload["message"]
    assert "삭제된 카드 수는 확인되지 않았습니다." in message
    assert "함께 삭제된 카드:" not in message
    assert "삭제되지 않은 카드:" not in message
    assert "99" not in message


async def test_deck_names_cannot_inject_notification_lines_or_invisible_controls(credentials):
    name = "한국어\n가짜 줄\r\t\x00\x1b\x7f\x85\u202e::덱"
    _, payload = await send_payload(credentials, operation(
        action="delete_decks", summary={"decks": [name], "cards": 99},
        result={"state": "applied", "deleted_decks": [name], "retained_decks": [],
                "deleted_cards": 1, "retained_cards": 0},
    ))
    message = payload["message"]
    named_line = next(line for line in message.splitlines() if line.startswith("삭제한 덱:"))
    assert "한국어" in named_line and "가짜 줄" in named_line and "::덱" in named_line
    assert not any(unicodedata.category(char) in ("Cc", "Cf") for char in message if char != "\n")
    assert not any(line.startswith("가짜 줄") for line in message.splitlines())


@pytest.mark.parametrize("many_names", [False, True])
async def test_long_deck_names_are_shortened_without_losing_counts_sync_or_full_operation_id(credentials, many_names):
    names = ([f"장문 덱 {index} " + "한글😀" * 300 for index in range(30)]
             if many_names else ["장문 덱 " + "한글😀" * 1000])
    _, payload = await send_payload(credentials, operation(
        action="delete_decks", summary={"decks": names, "cards": 99},
        result={"state": "applied", "deleted_decks": names, "retained_decks": ["Default"],
                "deleted_cards": 3, "retained_cards": 5, "retained_review_rows": 999999},
        sync={"state": "blocked"},
    ))
    message = payload["message"]
    assert "삭제한 덱:" in message and "장문 덱" in message
    assert "…" in message or "..." in message
    assert names[0] not in message
    assert '유지된 덱: "Default"' in message
    assert "함께 삭제된 카드: 3장." in message
    assert "삭제되지 않은 카드: 5장." in message
    assert "AnkiWeb 동기화가 중단되어 확인이 필요합니다." in message
    assert "기존 복습 기록 999999건은 남아 있습니다." in message
    assert "변경을 다시 실행하기 전에 작업 번호로 원인을 확인해 주세요." in message


@pytest.mark.parametrize("action", [
    "add_notes", "update_fields", "add_tags", "remove_tags", "create_deck", "move_cards",
    "delete_notes", "suspend_cards", "set_due_date", "set_card_flags", "forget_cards",
    "store_media", "update_deck_options", "model_css_update", "unknown-action",
])
async def test_other_actions_do_not_disclose_deck_names_from_any_receipt_field(credentials, action):
    name = "private-unrelated-deck-name"
    _, payload = await send_payload(credentials, operation(
        action=action, summary={"notes": 2, "cards": 5, "decks": [name]},
        params={"deck_name": name},
        result={"state": "applied", "deleted_decks": [name], "retained_decks": [name]},
    ))
    assert name not in payload["title"] + "\n" + payload["message"]


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


@pytest.mark.parametrize("state,updated", [("applied", 3), ("partial", 1), ("partial", 0)])
async def test_bulk_fields_reports_scope_and_confirmed_success(credentials, state, updated):
    _, payload = await send_payload(credentials, operation(
        action="update_fields_bulk", state=state,
        summary={"notes": 3, "cards": 5},
        result={"state": state, "updated": updated,
                "results": [{"note_id": 998877, "fields": {"Front": "private-content"}}]},
    ))
    assert "카드 내용 일괄 수정" in payload["title"]
    assert "대상: 노트 3개" in payload["message"]
    assert f"노트 {updated}개 수정을 확인했습니다." in payload["message"]
    assert "private-content" not in payload["message"] and "998877" not in payload["message"]
    assert ("완료" in payload["title"]) == (state == "applied")
    assert ("다시 실행하기 전에" in payload["message"]) == (state != "applied")
