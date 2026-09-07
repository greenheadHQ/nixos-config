"""승인 화면 — tailnet 전용 포트(결정 U1). /authorize(SDK 핸들러) + /approve(비밀 문구 폼).

공개 앱에는 /authorize가 없다(server.py가 제거). 이 앱은 loopback 승인 포트에만 바인딩되고 Tailscale serve(9443)만
그 포트로 프록시하므로, 인터넷에서는 승인 화면에 닿을 수 없다. 추가로 Host 헤더를 승인 URL의 호스트로 고정한다.
비밀 문구는 상수 시간 비교, 실패 N회면 잠금(무차별 대입 완화). 문구가 비어 있으면 어떤 승인도 통과하지 않는다.
"""

from __future__ import annotations

import hmac
import html
import time
from typing import Callable
from urllib.parse import urlparse

from mcp.server.auth.handlers.authorize import AuthorizationHandler
from mcp.server.auth.provider import AuthorizationParams, construct_redirect_uri
from mcp.shared.auth import OAuthClientInformationFull
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.requests import Request
from starlette.responses import HTMLResponse, PlainTextResponse, RedirectResponse, Response
from starlette.routing import Route

from .oauth import FileOAuthProvider


class _InvalidTargetProvider:
    """SDK가 client·callback·PKCE·scope를 검증한 뒤 오류 URL만 만든다. 승인 상태는 생성하지 않는다."""

    def __init__(self, provider: FileOAuthProvider) -> None:
        self._provider = provider

    async def get_client(self, client_id: str) -> OAuthClientInformationFull | None:
        return await self._provider.get_client(client_id)

    async def authorize(self, client: OAuthClientInformationFull, params: AuthorizationParams) -> str:
        return construct_redirect_uri(str(params.redirect_uri), error="invalid_target",
                                      error_description="unsupported resource", state=params.state)


class Lockout:
    def __init__(self, max_failures: int, lock_secs: int, now: Callable[[], float] = time.time) -> None:
        self._max = max_failures
        self._lock = lock_secs
        self._now = now
        self.failures = 0
        self.locked_until = 0.0

    def locked(self) -> bool:
        return self._now() < self.locked_until

    def fail(self) -> None:
        self.failures += 1
        if self.failures >= self._max:
            self.locked_until = self._now() + self._lock
            self.failures = 0

    def ok(self) -> None:
        self.failures = 0


class SecurityHeaders:
    """승인 화면은 프레임에 넣을 수 없고(clickjacking — 공격자가 만든 DCR·PKCE 트랜잭션의 승인 화면을 tailnet 사용자 페이지에
    숨겨 문구 입력을 유도하는 경로 차단), 캐시·리퍼러도 남기지 않는다."""

    # form-action은 넣지 않는다 — 승인 폼의 정상 흐름은 /approve POST 뒤 클라이언트 redirect_uri(외부 origin)로 302하는
    # 것이고, Chromium은 form-action을 그 리다이렉트 목적지에도 적용해 OAuth 콜백을 차단한다. clickjacking 방어는
    # frame-ancestors·X-Frame-Options가 담당한다.
    HEADERS = [
        (b"x-frame-options", b"DENY"),
        (b"content-security-policy", b"frame-ancestors 'none'; default-src 'self'; style-src 'unsafe-inline'"),
        (b"referrer-policy", b"no-referrer"),
        (b"cache-control", b"no-store"),
    ]

    def __init__(self, app) -> None:
        self._app = app

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http":
            await self._app(scope, receive, send)
            return

        async def send_with_headers(message) -> None:
            if message["type"] == "http.response.start":
                message = {**message, "headers": [*message.get("headers", []), *self.HEADERS]}
            await send(message)

        await self._app(scope, receive, send_with_headers)


_PAGE = """<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Anki MCP 승인</title><style>body{{font-family:-apple-system,system-ui,sans-serif;max-width:32rem;margin:3rem auto;padding:0 1rem;color:#222}}
input{{font-size:1.1rem;padding:.5rem;width:100%;box-sizing:border-box}}button{{font-size:1rem;padding:.6rem 1.2rem;margin-top:1rem}}
.deny{{background:none;border:1px solid #999}}.err{{color:#b00020}}code{{background:#f3f3f3;padding:.1rem .3rem}}</style></head><body>
<h1>Anki MCP 연결 승인</h1>
<p><strong>{client}</strong> 이(가) miniPC의 Anki에 접근하려고 합니다.</p>
<p>돌아갈 주소: <code>{redirect}</code><br>권한: <code>{scopes}</code></p>
{error}
<form method="post"><input type="hidden" name="txn" value="{txn}">
<label>승인 문구<br><input type="password" name="passphrase" autocomplete="current-password" autofocus></label>
<div><button type="submit" name="decision" value="approve">승인</button>
<button type="submit" name="decision" value="deny" class="deny">거부</button></div></form>
</body></html>"""


def build_approval_app(
    provider: FileOAuthProvider,
    approval_url: str,
    passphrase: Callable[[], str],
    lockout: Lockout,
) -> Starlette:
    allowed_host = urlparse(approval_url).netloc.lower()
    authorize = AuthorizationHandler(provider)

    def host_ok(request: Request) -> bool:
        host = (request.headers.get("host") or "").lower()
        return host == allowed_host or host.startswith("127.0.0.1")

    async def authorize_route(request: Request) -> Response:
        if not host_ok(request):
            return PlainTextResponse("wrong host", status_code=421)
        params = request.query_params if request.method == "GET" else await request.form()
        if any(not provider.accepts_resource(str(value)) for value in params.getlist("resource")):
            # SDK의 오류 enum에는 invalid_target이 없다. 검증된 callback을 쓰는 요청별 adapter로 보완한다.
            return await AuthorizationHandler(_InvalidTargetProvider(provider)).handle(request)
        return await authorize.handle(request)

    def render(txn: str, info: dict, error: str = "") -> HTMLResponse:
        return HTMLResponse(
            _PAGE.format(
                client=html.escape(str(info["client_name"])),
                redirect=html.escape(info["redirect_uri"]),
                scopes=html.escape(" ".join(info["scopes"])),
                txn=html.escape(txn),
                error=f'<p class="err">{html.escape(error)}</p>' if error else "",
            )
        )

    async def approve_get(request: Request) -> Response:
        if not host_ok(request):
            return PlainTextResponse("wrong host", status_code=421)
        txn = request.query_params.get("txn", "")
        info = provider.pending(txn)
        if not info:
            return PlainTextResponse("승인 요청이 없거나 만료됐습니다. 클라이언트에서 연결을 다시 시작하세요.", status_code=400)
        return render(txn, info)

    async def approve_post(request: Request) -> Response:
        if not host_ok(request):
            return PlainTextResponse("wrong host", status_code=421)
        form = await request.form()
        txn = str(form.get("txn", ""))
        info = provider.pending(txn)
        if not info:
            return PlainTextResponse("승인 요청이 없거나 만료됐습니다.", status_code=400)
        if str(form.get("decision")) == "deny":
            return RedirectResponse(provider.deny_approval(txn), status_code=302)
        if lockout.locked():
            return render(txn, info, "잠시 후 다시 시도하세요 (실패가 반복되어 잠겼습니다).")
        expected = passphrase()
        given = str(form.get("passphrase", ""))
        if not expected or not hmac.compare_digest(expected.encode(), given.encode()):
            lockout.fail()
            return render(txn, info, "승인 문구가 맞지 않습니다." if expected else "승인 문구가 설정되어 있지 않아 승인할 수 없습니다.")
        lockout.ok()
        return RedirectResponse(provider.complete_approval(txn), status_code=302)

    async def health(_: Request) -> Response:
        return PlainTextResponse("ok")

    return Starlette(
        routes=[
            Route("/authorize", authorize_route, methods=["GET", "POST"]),
            Route("/approve", approve_get, methods=["GET"]),
            Route("/approve", approve_post, methods=["POST"]),
            Route("/healthz", health, methods=["GET"]),
        ],
        middleware=[Middleware(SecurityHeaders)],
    )
