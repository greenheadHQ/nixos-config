"""Funnel 앱의 바깥 껍질 (순수 ASGI 미들웨어).

인터넷에 그대로 열리는 앱이므로 SDK 핸들러가 본문을 읽기 전에 두 가지를 자른다.
- 요청 본문 상한: Content-Length가 크면 413, 길이 없는(chunked) 본문은 읽으면서 누적이 넘는 순간 끊는다.
- /register rate limit: DCR은 인증이 없다 — 창(window) 안 등록 횟수가 burst를 넘으면 429. 재시작하면 초기화되는
  메모리 카운터면 충분하다(상한의 목적은 상태 파일 폭주 방지이지 과금이 아니다).
"""

from __future__ import annotations

import json
import time
from collections import deque
from typing import Any, Callable


def _json_response(status: int, error: str) -> tuple[dict[str, Any], dict[str, Any]]:
    body = json.dumps({"error": error}).encode()
    headers = [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())]
    return (
        {"type": "http.response.start", "status": status, "headers": headers},
        {"type": "http.response.body", "body": body},
    )


class BodyTooLarge(Exception):
    pass


class FunnelGuard:
    def __init__(
        self,
        app: Any,
        max_body_bytes: int,
        register_burst: int,
        register_window: int,
        now: Callable[[], float] = time.time,
    ) -> None:
        self._app = app
        self._max_body = max_body_bytes
        self._burst = register_burst
        self._window = register_window
        self._now = now
        self._registrations: deque[float] = deque()

    def _register_allowed(self) -> bool:
        now = self._now()
        while self._registrations and self._registrations[0] + self._window <= now:
            self._registrations.popleft()
        if len(self._registrations) >= self._burst:
            return False
        self._registrations.append(now)
        return True

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope["type"] != "http":
            await self._app(scope, receive, send)
            return
        headers = {k.decode().lower(): v.decode() for k, v in scope.get("headers", [])}
        length = headers.get("content-length")
        if length and length.isdigit() and int(length) > self._max_body:
            for message in _json_response(413, "request body too large"):
                await send(message)
            return
        if scope.get("path") == "/register" and scope.get("method") == "POST" and not self._register_allowed():
            for message in _json_response(429, "too many client registrations; try again later"):
                await send(message)
            return

        received = 0
        started = False

        async def limited_receive() -> dict[str, Any]:
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > self._max_body:
                    raise BodyTooLarge()
            return message

        async def tracking_send(message: dict[str, Any]) -> None:
            nonlocal started
            if message["type"] == "http.response.start":
                started = True
            await send(message)

        try:
            await self._app(scope, limited_receive, tracking_send)
        except BodyTooLarge:
            if started:
                raise  # 응답이 이미 나가기 시작했으면 되돌릴 수 없다 — 서버가 연결을 끊는다
            for message in _json_response(413, "request body too large"):
                await send(message)
