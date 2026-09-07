import asyncio

import pytest

from anki_mcp.guard import FunnelGuard


def _scope(path="/mcp", method="POST", headers=()):
    return {"type": "http", "path": path, "method": method, "headers": [(k.encode(), v.encode()) for k, v in headers]}


async def _run(guard, scope, messages, timeout=2.0):
    """messages를 순서대로 돌려주는 receive; 소진되면 영원히 대기한다(우리 가드가 더 읽으려 하면 timeout으로 드러난다)."""
    queue = list(messages)
    sent = []

    async def receive():
        if queue:
            return queue.pop(0)
        await asyncio.sleep(3600)

    async def send(message):
        sent.append(message)

    await asyncio.wait_for(guard(scope, receive, send), timeout)
    return sent


async def _echo(scope, receive, send):
    body = b""
    while True:
        m = await receive()
        body += m.get("body", b"")
        if not m.get("more_body", False):
            break
    await send({"type": "http.response.start", "status": 200, "headers": []})
    await send({"type": "http.response.body", "body": b"len=%d" % len(body)})


@pytest.mark.anyio
async def test_oversize_in_final_message_replies_413_without_waiting_for_more():
    # uvicorn은 chunked 본문 전체를 한 메시지(more_body=False)로 넘길 수 있다 — 더 읽으려 하면 영원히 멈춘다(실측)
    guard = FunnelGuard(_echo, max_body_bytes=100, register_burst=5, register_window=60)
    sent = await _run(guard, _scope(), [{"type": "http.request", "body": b"x" * 300, "more_body": False}])
    assert sent[0]["status"] == 413


@pytest.mark.anyio
async def test_oversize_mid_stream_drains_the_rest_then_replies_413():
    guard = FunnelGuard(_echo, max_body_bytes=100, register_burst=5, register_window=60)
    msgs = [{"type": "http.request", "body": b"x" * 150, "more_body": True},
            {"type": "http.request", "body": b"y" * 50, "more_body": True},
            {"type": "http.request", "body": b"", "more_body": False}]
    sent = await _run(guard, _scope(), msgs)
    assert sent[0]["status"] == 413


@pytest.mark.anyio
async def test_within_limit_body_is_replayed_to_the_app_intact():
    guard = FunnelGuard(_echo, max_body_bytes=100, register_burst=5, register_window=60)
    msgs = [{"type": "http.request", "body": b"a" * 40, "more_body": True},
            {"type": "http.request", "body": b"b" * 40, "more_body": False}]
    sent = await _run(guard, _scope(), msgs)
    assert sent[0]["status"] == 200 and sent[1]["body"] == b"len=80"


@pytest.mark.anyio
async def test_declared_oversize_is_refused_before_reading_and_registration_is_rate_limited():
    guard = FunnelGuard(_echo, max_body_bytes=100, register_burst=1, register_window=60, now=lambda: 0.0)
    sent = await _run(guard, _scope(headers=[("content-length", "5000")]), [])
    assert sent[0]["status"] == 413
    assert (await _run(guard, _scope(path="/register"), [{"type": "http.request", "body": b"{}", "more_body": False}]))[0]["status"] == 200
    assert (await _run(guard, _scope(path="/register"), []))[0]["status"] == 429


@pytest.mark.anyio
async def test_incomplete_body_times_out_with_408_instead_of_buffering_forever():
    # 본문 선읽기는 인증 전에 일어난다 — 본문을 끝맺지 않는 연결(slowloris)은 read_timeout에 408로 끊어야 한다
    guard = FunnelGuard(_echo, max_body_bytes=1000, register_burst=5, register_window=60, read_timeout=0.05)
    sent = await _run(guard, _scope(), [{"type": "http.request", "body": b"partial", "more_body": True}])
    assert sent[0]["status"] == 408
