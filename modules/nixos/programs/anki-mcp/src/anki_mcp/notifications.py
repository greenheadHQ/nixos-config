"""Pushover write receipts: deletion deck names, never note contents or credentials."""

import json
import re
import unicodedata
from pathlib import Path
from typing import Any

import httpx


# Only deck deletion names are included by the user's explicit choice.
# Fixed copy keeps note contents, other names and raw errors out of notifications.
# Counts in summary describe the request's scope, not confirmed changed rows.
_ACTIONS = {
    "add_notes": ("노트 추가", "노트 추가 요청을 처리했습니다.", "new_notes", "노트", "개"),
    "update_fields": ("카드 내용 수정", "카드 내용 수정 요청을 처리했습니다.", "notes", "노트", "개"),
    "update_fields_bulk": ("카드 내용 일괄 수정", "카드 내용 일괄 수정 요청을 처리했습니다.", "notes", "노트", "개"),
    "add_tags": ("태그 추가", "태그 추가 요청을 처리했습니다.", "notes", "노트", "개"),
    "remove_tags": ("태그 해제", "태그 해제 요청을 처리했습니다.", "notes", "노트", "개"),
    "create_deck": ("덱 준비", "덱을 사용할 수 있도록 준비했습니다.", None, "", ""),
    "move_cards": ("카드 이동", "카드 이동 요청을 처리했습니다.", "cards", "카드", "장"),
    "delete_notes": ("노트 삭제", "노트 삭제 요청을 처리했습니다.", "notes", "노트", "개"),
    "delete_decks": ("덱 삭제", "덱 삭제 요청을 처리했습니다.", None, "", ""),
    "suspend_cards": ("학습 제외 설정", "카드의 학습 제외 설정을 적용했습니다.", "cards", "카드", "장"),
    "set_due_date": ("복습 날짜 설정", "카드의 복습 날짜 설정을 적용했습니다.", "cards", "카드", "장"),
    "set_card_flags": ("깃발 설정", "카드의 깃발 설정을 적용했습니다.", "cards", "카드", "장"),
    "forget_cards": ("새 카드로 되돌리기", "카드를 새 카드 상태로 되돌리는 요청을 처리했습니다.", "cards", "카드", "장"),
    "store_media": ("첨부 파일 저장", "첨부 파일 저장을 확인했습니다.", None, "", ""),
    "update_deck_options": ("덱 학습 설정", "덱의 학습 설정을 적용했습니다.", "cards", "카드", "장"),
    "model_css_update": ("카드 표시 수정", "카드의 표시 스타일을 수정했습니다.", "cards", "카드", "장"),
}


def _count(value: Any) -> bool:
    return type(value) is int and value >= 0


def _names(value: Any, budget: int = 500) -> str:
    if not isinstance(value, list) or not all(isinstance(name, str) and name for name in value):
        return ""
    # JSON quoting makes control characters visible instead of injecting lines.
    text = ", ".join(json.dumps(name, ensure_ascii=False) for name in value)
    text = "".join(ascii(char)[1:-1] if unicodedata.category(char) in ("Cc", "Cf", "Zl", "Zp") else char
                   for char in text)
    if len(text) > budget:
        tail = "… (이름 일부 생략; 전체는 작업 번호로 조회)"
        return text[:budget - len(tail)] + tail
    return text


def _deck_deletion_lines(operation: dict[str, Any]) -> list[str]:
    result = operation.get("result", {})
    deleted = _names(result.get("deleted_decks"), 350)
    retained = _names(result.get("retained_decks"), 150)
    lines = []
    if deleted:
        lines.append(f"삭제한 덱: {deleted}")
    if retained:
        lines.append(f"유지된 덱: {retained}")
    if not lines:
        requested = _names(operation.get("summary", {}).get("decks"))
        lines.append(f"삭제 요청 덱: {requested}" if requested else "삭제 요청 덱 이름을 확인하지 못했습니다.")
    deleted_cards = result.get("deleted_cards")
    if _count(deleted_cards):
        lines.append(f"함께 삭제된 카드: {deleted_cards}장.")
    else:
        lines.append("삭제된 카드 수는 확인되지 않았습니다.")
    retained_cards = result.get("retained_cards")
    if _count(retained_cards) and retained_cards:
        lines.append(f"삭제되지 않은 카드: {retained_cards}장.")
    return lines


def _content(operation: dict[str, Any]) -> tuple[str, str]:
    action = operation.get("action")
    summary = operation.get("summary", {})
    label, completed, count_key, unit, suffix = _ACTIONS.get(
        action, ("변경", "변경 요청을 처리했습니다.", None, "", ""))
    if action == "set_card_flags" and type(summary.get("flag")) is int and summary["flag"] == 0:
        label, completed = "깃발 해제", "카드의 깃발 해제 요청을 처리했습니다."
    if action == "delete_decks" and operation.get("result", {}).get("retained_decks"):
        label = "덱 정리"
    state = operation.get("state")
    sync = operation.get("sync", {})
    sync_state = sync.get("state")
    if action == "store_media" and sync_state == "synced" and sync.get("media_state") != "synced":
        sync_state = "pending"
    if state != "applied":
        title = f"Anki {label} 확인 필요"
        lines = ["요청을 모두 완료했는지 확인하지 못했습니다."]
    elif sync_state not in ("synced", "disabled"):
        title = f"Anki {label} · 동기화 확인 필요"
        lines = [completed]
    else:
        title = f"Anki {label} 완료"
        lines = [completed]

    if action == "delete_decks":
        details = _deck_deletion_lines(operation)
        lines = details if state == "applied" else lines + details
        if state == "applied" and sync_state in ("synced", "disabled") and not _count(operation.get("result", {}).get("deleted_cards")):
            title = "Anki 덱 삭제 결과"

    count = summary.get(count_key) if count_key else None
    if _count(count):
        scope = "추가 요청" if action == "add_notes" else "대상"
        lines.append(f"{scope}: {unit} {count}{suffix}.")
    if action == "add_notes":
        added = operation.get("result", {}).get("added")
        if _count(added):
            lines.append(f"노트 {added}개 추가를 확인했습니다.")
    if action == "update_fields_bulk":
        updated = operation.get("result", {}).get("updated")
        if _count(updated):
            lines.append(f"노트 {updated}개 수정을 확인했습니다.")
    if action in ("delete_notes", "delete_decks") and state == "applied":
        retained_reviews = operation.get("result", {}).get("retained_review_rows")
        if _count(retained_reviews) and retained_reviews:
            lines.append(f"기존 복습 기록 {retained_reviews}건은 남아 있습니다.")
    if state != "applied":
        lines.append("같은 변경을 다시 실행하기 전에 작업 번호로 결과를 확인해 주세요.")

    if sync_state == "synced":
        lines.append("AnkiWeb 동기화가 완료됐습니다.")
    elif sync_state == "disabled":
        lines.append("자동 동기화가 꺼져 있어 AnkiWeb 반영을 확인하지 않았습니다.")
    elif sync_state == "blocked":
        lines.append("AnkiWeb 동기화가 중단되어 확인이 필요합니다.")
        lines.append("변경을 다시 실행하기 전에 작업 번호로 원인을 확인해 주세요.")
    else:
        lines.append("AnkiWeb 반영이 아직 확인되지 않았습니다.")
        lines.append("작업 번호로 동기화 상태를 확인해 주세요.")

    opid = operation.get("operation_id", "")
    if isinstance(opid, str) and re.fullmatch(r"[0-9a-f]{32}", opid):
        lines.extend(["", f"문제 문의용 작업 번호: {opid}"])
    return title, "\n".join(lines)


class Notifications:
    def __init__(self, credential_file: str, client: httpx.AsyncClient) -> None:
        self.client = client
        self.values = {}
        try:
            for line in Path(credential_file).read_text().splitlines():
                if line.startswith(("PUSHOVER_TOKEN=", "PUSHOVER_USER=")):
                    key, value = line.split("=", 1)
                    self.values[key] = value.strip().strip('"').strip("'")
        except OSError:
            pass

    @property
    def enabled(self) -> bool:
        return bool(self.values.get("PUSHOVER_TOKEN") and self.values.get("PUSHOVER_USER"))

    async def send(self, operation: dict[str, Any]) -> str:
        if not self.enabled:
            return "disabled"
        title, message = _content(operation)
        try:
            response = await self.client.post("https://api.pushover.net/1/messages.json", data={
                "token": self.values["PUSHOVER_TOKEN"], "user": self.values["PUSHOVER_USER"],
                "title": title, "message": message, "priority": "0"}, timeout=15)
        except httpx.HTTPError:
            return "unknown"  # A timeout can happen after delivery.
        try:
            body = response.json()
        except ValueError:
            return "unknown"
        if response.is_success and isinstance(body, dict) and body.get("status") == 1:
            return "sent"
        return "failed" if isinstance(body, dict) and body.get("status") == 0 else "unknown"
