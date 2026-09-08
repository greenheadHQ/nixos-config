"""Pushover write receipts: no note contents, request payloads or credentials."""

from pathlib import Path
from typing import Any

import httpx


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
        summary = operation.get("summary", {})
        sync = operation.get("sync", {}).get("state", "pending")
        message = (f"작업 {operation['operation_id']} ({operation['action']}): "
                   f"노트 {summary.get('notes', 0)}개, 카드 {summary.get('cards', 0)}장 영향. "
                   + ("일부만 적용됐습니다. 결과를 확인하세요. " if operation["state"] == "partial" else "변경이 적용됐습니다. ")
                   + ("AnkiWeb 동기화 완료." if sync == "synced" else "AnkiWeb 동기화 확인이 필요합니다."))
        try:
            response = await self.client.post("https://api.pushover.net/1/messages.json", data={
                "token": self.values["PUSHOVER_TOKEN"], "user": self.values["PUSHOVER_USER"],
                "title": "Anki 변경 결과", "message": message, "priority": "0"}, timeout=15)
        except httpx.HTTPError:
            return "unknown"  # A timeout can happen after delivery.
        try:
            body = response.json()
        except ValueError:
            return "unknown"
        if response.is_success and isinstance(body, dict) and body.get("status") == 1:
            return "sent"
        return "failed" if isinstance(body, dict) and body.get("status") == 0 else "unknown"
