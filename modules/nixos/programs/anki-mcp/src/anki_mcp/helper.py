"""Authenticated helper client for status and journaled operations.

Operation routes share the host mutation lock. A definite refusal, a busy
response, and a transport failure after possible apply have distinct outcomes.
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


class HelperRejected(RuntimeError):
    """A definite refusal, as opposed to a lost response after possible apply."""


class Helper:
    def __init__(self, url: str, client: httpx.AsyncClient | None = None, timeout: float = 10.0, *, key: str) -> None:
        self._url = url
        self._key, self._timeout = key, timeout
        self._client = client or httpx.AsyncClient(timeout=timeout)

    async def status(self) -> dict[str, Any]:
        return await self._request("GET", "/status")

    async def post(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._request("POST", path, payload)

    async def _request(self, method: str, path: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        try:
            resp = await self._client.request(method, self._url + path, json=payload,
                headers={"Authorization": "Bearer " + self._key}, timeout=self._timeout)
            data = resp.json()
        except (httpx.HTTPError, ValueError) as err:
            raise HelperUnavailable(f"helper unreachable: {err.__class__.__name__}") from err
        if isinstance(data, dict) and resp.status_code == 409 and data.get("error") == "busy":
            raise HelperBusy(str(data.get("busy") or "operation"))
        if isinstance(data, dict) and resp.status_code in (400, 401, 403):
            raise HelperRejected(str(data.get("error") or "request-rejected"))
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
