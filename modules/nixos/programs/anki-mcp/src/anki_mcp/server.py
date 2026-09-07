"""두 앱, 두 loopback 포트.

Funnel 앱(port)      : /mcp(Streamable HTTP, Bearer), /.well-known/oauth-authorization-server(authorization_endpoint는
                       승인 URL을 가리킨다), /.well-known/oauth-protected-resource/mcp, /register, /token, /revoke
승인 앱(approval_port): /authorize, /approve — Tailscale serve 9443(tailnet 전용)만 여기로 프록시한다
"""

from __future__ import annotations

import asyncio
import logging
import os
import signal
import sys
from typing import Any
from urllib.parse import parse_qsl, urlsplit

import httpx
import uvicorn
from mcp.server.auth.handlers.metadata import MetadataHandler
from mcp.server.auth.handlers.token import TokenHandler
from mcp.server.auth.middleware.client_auth import ClientAuthenticator
from mcp.server.auth.routes import build_metadata, cors_middleware
from mcp.server.auth.settings import AuthSettings, ClientRegistrationOptions, RevocationOptions
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from pydantic import AnyHttpUrl
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from .ankiconnect import AnkiConnect
from .approval import Lockout, build_approval_app
from .config import Settings, read_passphrase
from .guard import FunnelGuard
from .helper import Helper
from .oauth import CLIENT_AUTH_METHODS, DEFAULT_SCOPES, FileOAuthProvider
from .syncstatus import SyncNow
from .tools import Deps, register_tools

log = logging.getLogger("anki_mcp")

INSTRUCTIONS = (
    "Tools for the user's own Anki collection hosted on their home server (synced with AnkiWeb every 15 minutes). "
    "Read tools are safe. Write tools add/modify notes, tags and decks; every added note is tagged 'mcp::added'. "
    "Mutations fail with 'helper busy' while a sync/backup is in progress — wait a moment and retry. "
    "Nothing here deletes notes or forces a full sync."
)


class PublicClientRevocation:
    """SDK의 RevocationRequest는 `client_secret` 필드가 아예 없으면(공개 클라이언트가 RFC 7009대로 생략하면) 400을 낸다 —
    form 본문에 빈 client_secret을 채워 SDK 핸들러로 넘긴다. 클라이언트 인증·토큰 소유자 검증은 SDK가 그대로 한다."""

    def __init__(self, app: Any) -> None:
        self._app = app

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope["type"] != "http" or scope.get("method") != "POST":
            await self._app(scope, receive, send)
            return
        body = b""
        trailing: list[dict[str, Any]] = []
        while True:
            message = await receive()
            if message["type"] != "http.request":
                trailing.append(message)
                break
            body += message.get("body", b"")
            if not message.get("more_body", False):
                break
        headers = list(scope.get("headers", []))
        ctype = next((v for k, v in headers if k == b"content-type"), b"").decode().lower()
        if ctype.startswith("application/x-www-form-urlencoded"):
            fields = dict(parse_qsl(body.decode(errors="replace"), keep_blank_values=True))
            if "client_secret" not in fields:
                body += (b"&" if body else b"") + b"client_secret="
                headers = [(k, v) for k, v in headers if k != b"content-length"]
                headers.append((b"content-length", str(len(body)).encode()))
                scope = {**scope, "headers": headers}
        replay = [{"type": "http.request", "body": body, "more_body": False}, *trailing]

        async def replay_receive() -> dict[str, Any]:
            if replay:
                return replay.pop(0)
            return await receive()

        await self._app(scope, replay_receive, send)


def build(cfg: Settings):
    provider = FileOAuthProvider(
        state_path=os.path.join(cfg.state_dir, "oauth-state.json"),
        approval_url=cfg.approval_url,
        access_ttl=cfg.access_ttl,
        refresh_ttl=cfg.refresh_ttl,
        code_ttl=cfg.code_ttl,
        resource_url=f"{cfg.public_url}/mcp",
        max_refresh_rotations=cfg.refresh_max_rotations,
        max_clients=cfg.reg_max_clients,
        max_client_bytes=cfg.reg_max_client_bytes,
        unused_client_ttl=cfg.reg_unused_ttl,
    )
    # Host에는 명시 포트도 포함된다. hostname만 허용하면 :8443 MCP 요청이 421로 거절된다.
    public_host = urlsplit(cfg.public_url).netloc
    approval_host = AnyHttpUrl(cfg.approval_url)
    security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=[public_host, "127.0.0.1:*", "localhost:*"],
        allowed_origins=[cfg.public_url, "http://127.0.0.1:*", "http://localhost:*"],
    )
    registration = ClientRegistrationOptions(enabled=True, valid_scopes=DEFAULT_SCOPES, default_scopes=DEFAULT_SCOPES)
    revocation = RevocationOptions(enabled=True)
    mcp = FastMCP(
        "anki",
        instructions=INSTRUCTIONS,
        host="127.0.0.1",
        port=cfg.port,
        streamable_http_path="/mcp",
        json_response=True,
        stateless_http=True,
        auth_server_provider=provider,
        auth=AuthSettings(
            issuer_url=AnyHttpUrl(cfg.public_url),
            resource_server_url=AnyHttpUrl(f"{cfg.public_url}/mcp"),
            client_registration_options=registration,
            revocation_options=revocation,
            required_scopes=DEFAULT_SCOPES,
        ),
        transport_security=security,
    )
    http = httpx.AsyncClient(timeout=60.0)
    deps = Deps(
        anki=AnkiConnect(cfg.anki_connect_url, client=http),
        helper=Helper(cfg.helper_url, client=http),
        syncer=SyncNow(cfg.sync_status_file, cfg.sync_unit, cfg.sync_wait),
        sync_status_file=cfg.sync_status_file,
        field_chars=cfg.field_chars,
        page_max=cfg.page_max,
    )
    register_tools(mcp, deps)

    funnel_app = mcp.streamable_http_app()
    # /authorize는 승인 포트에만 둔다 — Funnel 앱에서 제거
    funnel_app.router.routes = [
        r for r in funnel_app.router.routes if not (isinstance(r, Route) and r.path == "/authorize")
    ]
    # 메타데이터의 authorization_endpoint를 승인 URL로 바꾼다 (SDK는 issuer 기준으로만 만든다)
    metadata = build_metadata(AnyHttpUrl(cfg.public_url), None, registration, revocation)
    metadata.authorization_endpoint = AnyHttpUrl(f"{cfg.approval_url}/authorize")
    # SDK 1.27.1은 Basic을 광고하지만 헤더 해석 전에 본문 client_id를 요구한다.
    # 실제 지원·등록 허용 방식만 광고한다. 공개 PKCE 클라이언트의 none도 명시한다.
    metadata.token_endpoint_auth_methods_supported = list(CLIENT_AUTH_METHODS)
    metadata.revocation_endpoint_auth_methods_supported = list(CLIENT_AUTH_METHODS)
    metadata_route = Route(
        "/.well-known/oauth-authorization-server",
        endpoint=cors_middleware(MetadataHandler(metadata).handle, ["GET", "OPTIONS"]),
        methods=["GET", "OPTIONS"],
    )
    funnel_app.router.routes = [
        metadata_route if (isinstance(r, Route) and r.path == "/.well-known/oauth-authorization-server") else r
        for r in funnel_app.router.routes
    ]
    # SDK 1.27.1은 /token의 resource를 파싱만 한다. 단일 Anki 대상인지 먼저 확인한 뒤 같은 Request를 넘긴다.
    token_handler = TokenHandler(provider, ClientAuthenticator(provider))

    async def token_endpoint(request: Request):
        form = await request.form()
        if any(not provider.accepts_resource(str(value)) for value in form.getlist("resource")):
            return JSONResponse({"error": "invalid_target", "error_description": "unsupported resource"},
                                status_code=400, headers={"Cache-Control": "no-store", "Pragma": "no-cache"})
        return await token_handler.handle(request)

    funnel_app.router.routes = [
        Route("/token", endpoint=cors_middleware(token_endpoint, ["POST", "OPTIONS"]), methods=["POST", "OPTIONS"])
        if (isinstance(r, Route) and r.path == "/token") else r
        for r in funnel_app.router.routes
    ]
    # /revoke: 공개 클라이언트의 secret 생략을 받아준다 (SDK 라우트의 ASGI 앱을 감싼 새 Route로 교체)
    funnel_app.router.routes = [
        Route("/revoke", endpoint=PublicClientRevocation(r.app), methods=["POST", "OPTIONS"])
        if (isinstance(r, Route) and r.path == "/revoke")
        else r
        for r in funnel_app.router.routes
    ]
    # 인터넷에 열린 앱의 바깥 껍질: 본문 상한(413) + 인증 없는 /register의 rate limit(429)
    funnel_app.add_middleware(
        FunnelGuard, max_body_bytes=cfg.max_body_bytes, register_burst=cfg.reg_burst, register_window=cfg.reg_window,
        read_timeout=cfg.body_read_timeout,
    )

    lockout = Lockout(cfg.lockout_failures, cfg.lockout_secs)
    approval_app = build_approval_app(
        provider,
        cfg.approval_url,
        passphrase=lambda: read_passphrase(cfg.passphrase_file),
        lockout=lockout,
    )
    log.info(
        "anki_mcp ready: issuer=%s authorize=%s approval_host=%s clients=%d",
        cfg.public_url,
        metadata.authorization_endpoint,
        approval_host.host,
        len(provider.clients()),
    )
    return funnel_app, approval_app


async def serve(cfg: Settings) -> None:
    funnel_app, approval_app = build(cfg)
    servers = [
        uvicorn.Server(uvicorn.Config(funnel_app, host="127.0.0.1", port=cfg.port, log_level="info",
                                      proxy_headers=True, forwarded_allow_ips="127.0.0.1", lifespan="on",
                                      limit_concurrency=cfg.max_concurrency)),
        uvicorn.Server(uvicorn.Config(approval_app, host="127.0.0.1", port=cfg.approval_port, log_level="info",
                                      proxy_headers=True, forwarded_allow_ips="127.0.0.1")),
    ]
    tasks = [asyncio.create_task(s.serve()) for s in servers]
    await asyncio.sleep(0.5)  # uvicorn이 자체 signal 핸들러를 건 뒤에 우리 것으로 덮는다 — 두 서버를 함께 내린다

    def stop() -> None:
        for s in servers:
            s.should_exit = True

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop)
    await asyncio.gather(*tasks)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(name)s %(levelname)s %(message)s", stream=sys.stdout)
    asyncio.run(serve(Settings.from_env()))
