"""loopback AnkiConnect(API version 6) 클라이언트. 컬렉션을 만지는 유일한 경로다 — 파일 접근 없음."""

from __future__ import annotations

from typing import Any

import httpx


class AnkiConnectError(RuntimeError):
    """AnkiConnect가 error 필드를 돌려줬거나 연결에 실패했다."""


class AnkiConnect:
    def __init__(self, url: str, client: httpx.AsyncClient | None = None, timeout: float = 60.0) -> None:
        self._url = url
        self._client = client or httpx.AsyncClient(timeout=timeout)

    async def invoke(self, action: str, **params: Any) -> Any:
        body: dict[str, Any] = {"action": action, "version": 6}
        if params:
            body["params"] = params
        try:
            resp = await self._client.post(self._url, json=body)
        except httpx.HTTPError as err:
            raise AnkiConnectError(f"anki-connect unreachable: {err.__class__.__name__}") from err
        if resp.status_code != 200:
            raise AnkiConnectError(f"anki-connect http {resp.status_code}")
        try:
            data = resp.json()
        except ValueError as err:
            raise AnkiConnectError("anki-connect returned non-JSON") from err
        if not isinstance(data, dict) or "result" not in data:
            raise AnkiConnectError("anki-connect returned an unexpected shape")
        if data.get("error"):
            raise AnkiConnectError(str(data["error"]))
        return data["result"]

    async def aclose(self) -> None:
        await self._client.aclose()
