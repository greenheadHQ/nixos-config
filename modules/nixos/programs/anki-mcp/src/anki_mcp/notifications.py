"""Pushover write receipts: no note contents, request payloads or credentials."""

import re
from pathlib import Path
from typing import Any

import httpx


# Fixed copy keeps note contents, names and raw errors out of phone notifications.
# Counts in summary describe the request's scope, not confirmed changed rows.
_ACTIONS = {
    "add_notes": ("노트 추가", "노트 추가 요청을 처리했습니다.", "new_notes", "노트", "개"),
    "update_fields": ("카드 내용 수정", "카드 내용 수정 요청을 처리했습니다.", "notes", "노트", "개"),
    "add_tags": ("태그 추가", "태그 추가 요청을 처리했습니다.", "notes", "노트", "개"),
    "remove_tags": ("태그 해제", "태그 해제 요청을 처리했습니다.", "notes", "노트", "개"),
    "create_deck": ("덱 준비", "덱을 사용할 수 있도록 준비했습니다.", None, "", ""),
    "move_cards": ("카드 이동", "카드 이동 요청을 처리했습니다.", "cards", "카드", "장"),
    "delete_notes": ("노트 삭제", "노트 삭제 요청을 처리했습니다.", "notes", "노트", "개"),
    "delete_decks": ("덱 삭제", "덱 삭제 요청을 처리했습니다.", "cards", "카드", "장"),
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


def _content(operation: dict[str, Any]) -> tuple[str, str]:
    action = operation.get("action")
    summary = operation.get("summary", {})
    label, completed, count_key, unit, suffix = _ACTIONS.get(
        action, ("변경", "변경 요청을 처리했습니다.", None, "", ""))
    if action == "set_card_flags" and type(summary.get("flag")) is int and summary["flag"] == 0:
        label, completed = "깃발 해제", "카드의 깃발 해제 요청을 처리했습니다."
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

    count = summary.get(count_key) if count_key else None
    if _count(count):
        scope = "추가 요청" if action == "add_notes" else "대상"
        lines.append(f"{scope}: {unit} {count}{suffix}.")
    if action == "add_notes":
        added = operation.get("result", {}).get("added")
        if _count(added):
            lines.append(f"노트 {added}개 추가를 확인했습니다.")
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
