"""anki_host_sync 헬퍼 애드온(loopback) — /status 즉시 응답으로 준비·로그인·busy를 본다.

결정 10: 헬퍼의 변경 작업 락은 AnkiConnect 경유 변경을 덮지 않으므로, MCP 변경 도구는 호출 전에 여기서 busy를
확인하고 busy면 진행 중 작업 이름과 함께 실패한다(재시도는 사용자 몫).
"""

from __future__ import annotations

from typing import Any

import httpx


class HelperBusy(RuntimeError):
    def __init__(self, current: str) -> None:
        super().__init__(f"helper busy: {current}")
        self.current = current


class HelperUnavailable(RuntimeError):
    pass


class Helper:
    def __init__(self, url: str, client: httpx.AsyncClient | None = None, timeout: float = 10.0) -> None:
        self._url = url
        self._client = client or httpx.AsyncClient(timeout=timeout)

    async def status(self) -> dict[str, Any]:
        try:
            resp = await self._client.get(f"{self._url}/status")
            data = resp.json()
        except (httpx.HTTPError, ValueError) as err:
            raise HelperUnavailable(f"helper unreachable: {err.__class__.__name__}") from err
        if not resp.is_success or not isinstance(data, dict):
            raise HelperUnavailable(f"helper error: HTTP {resp.status_code}, unexpected response shape")
        if not data.get("ok") or not isinstance(data.get("result"), dict):
            raise HelperUnavailable(f"helper error: {data.get('error') or 'missing result'}")
        return data["result"]

    async def ensure_not_busy(self) -> dict[str, Any]:
        st = await self.status()
        if st.get("busy"):
            raise HelperBusy(str(st["busy"]))
        if not st.get("collection_open"):
            raise HelperUnavailable("collection not open (instance starting?)")
        return st

    async def aclose(self) -> None:
        await self._client.aclose()
