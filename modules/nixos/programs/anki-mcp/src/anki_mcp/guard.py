"""Funnel 앱의 바깥 껍질 (순수 ASGI 미들웨어).

인터넷에 그대로 열리는 앱이므로 SDK 핸들러가 본문을 읽기 전에 두 가지를 자른다.
- 요청 본문 상한: Content-Length가 크면 바로 413. 아니면 본문을 상한까지 여기서 미리 읽고 넘으면 413, 안 넘으면 읽은
  본문을 앱에 되돌려준다 — SDK 핸들러 안에서 예외로 끊으면 SDK의 광역 except가 500으로 바꾸므로(streamable_http.py),
  판정은 앱에 들어가기 전에 끝내야 한다. MCP 요청은 JSON 한 덩어리라 버퍼링 비용은 상한(수백 KB)으로 묶인다.
- /register rate limit: DCR은 인증이 없다 — 창(window) 안 등록 횟수가 burst를 넘으면 429. 재시작하면 초기화되는
  메모리 카운터면 충분하다(상한의 목적은 상태 파일 폭주 방지이지 과금이 아니다).
"""

from __future__ import annotations

import json
import time
from collections import deque
from typing import Any, Callable


DRAIN_FACTOR = 4  # 413 전에 읽어 버리는 본문의 상한 배수 — 이보다 크면 응답만 보내고 끊는다


def _json_response(status: int, error: str) -> tuple[dict[str, Any], dict[str, Any]]:
    body = json.dumps({"error": error}).encode()
    headers = [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())]
    return (
        {"type": "http.response.start", "status": status, "headers": headers},
        {"type": "http.response.body", "body": body},
    )


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

    async def _drain(self, receive: Any, already: int, announced: int | None) -> None:
        """413을 보내기 전에 남은 본문을 읽어 버린다 — 읽지 않은 요청 데이터가 남은 소켓을 서버가 닫으면 RST가 나가
        클라이언트가 응답을 받기 전에 연결이 끊긴다(실측). 상한의 몇 배를 넘는 본문은 읽지 않고 그냥 끊는다."""
        budget = self._max_body * DRAIN_FACTOR - already
        if announced is not None and announced > self._max_body * DRAIN_FACTOR:
            return
        while budget > 0:
            message = await receive()
            if message["type"] != "http.request":
                return
            budget -= len(message.get("body", b""))
            if not message.get("more_body", False):
                return

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope["type"] != "http":
            await self._app(scope, receive, send)
            return
        headers = {k.decode().lower(): v.decode() for k, v in scope.get("headers", [])}
        length = headers.get("content-length")
        if length and length.isdigit() and int(length) > self._max_body:
            await self._drain(receive, 0, int(length))
            for message in _json_response(413, "request body too large"):
                await send(message)
            return
        if scope.get("path") == "/register" and scope.get("method") == "POST" and not self._register_allowed():
            for message in _json_response(429, "too many client registrations; try again later"):
                await send(message)
            return

        body = b""
        trailing: list[dict[str, Any]] = []  # 본문 뒤에 온 다른 메시지(disconnect 등)는 앱에 그대로 전달
        while True:
            message = await receive()
            if message["type"] != "http.request":
                trailing.append(message)
                break
            body += message.get("body", b"")
            if len(body) > self._max_body:
                if message.get("more_body", False):  # 이 메시지가 마지막이면 더 읽을 것이 없다 — 기다리면 영원히 멈춘다
                    await self._drain(receive, len(body), None)
                for reply in _json_response(413, "request body too large"):
                    await send(reply)
                return
            if not message.get("more_body", False):
                break
        replay = [{"type": "http.request", "body": body, "more_body": False}, *trailing]

        async def replay_receive() -> dict[str, Any]:
            if replay:
                return replay.pop(0)
            return await receive()

        await self._app(scope, replay_receive, send)
