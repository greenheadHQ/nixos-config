"""두 앱, 두 loopback 포트.

Funnel 앱(port)      : /mcp(Streamable HTTP, Bearer), /.well-known/oauth-authorization-server(authorization_endpoint는
                       승인 URL을 가리킨다), /.well-known/oauth-protected-resource/mcp, /register, /token, /revoke
승인 앱(approval_port): /authorize, /approve — Tailscale serve 8443(tailnet 전용)만 여기로 프록시한다
"""

from __future__ import annotations

import asyncio
import logging
import os
import signal
import sys

import httpx
import uvicorn
from mcp.server.auth.handlers.metadata import MetadataHandler
from mcp.server.auth.routes import build_metadata, cors_middleware
from mcp.server.auth.settings import AuthSettings, ClientRegistrationOptions, RevocationOptions
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from pydantic import AnyHttpUrl
from starlette.routing import Route

from .ankiconnect import AnkiConnect
from .approval import Lockout, build_approval_app
from .config import Settings, read_passphrase
from .helper import Helper
from .oauth import DEFAULT_SCOPES, FileOAuthProvider
from .syncstatus import SyncNow
from .tools import Deps, register_tools

log = logging.getLogger("anki_mcp")

INSTRUCTIONS = (
    "Tools for the user's own Anki collection hosted on their home server (synced with AnkiWeb every 15 minutes). "
    "Read tools are safe. Write tools add/modify notes, tags and decks; every added note is tagged 'mcp::added'. "
    "Mutations fail with 'helper busy' while a sync/backup is in progress — wait a moment and retry. "
    "Nothing here deletes notes or forces a full sync."
)


def build(cfg: Settings):
    provider = FileOAuthProvider(
        state_path=os.path.join(cfg.state_dir, "oauth-state.json"),
        approval_url=cfg.approval_url,
        access_ttl=cfg.access_ttl,
        refresh_ttl=cfg.refresh_ttl,
        code_ttl=cfg.code_ttl,
    )
    public_host = AnyHttpUrl(cfg.public_url).host or ""
    approval_host = AnyHttpUrl(cfg.approval_url)
    security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=[public_host, f"{public_host}:443", "127.0.0.1:*", "localhost:*"],
        allowed_origins=[cfg.public_url, f"https://{public_host}:443", "http://127.0.0.1:*", "http://localhost:*"],
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
    metadata_route = Route(
        "/.well-known/oauth-authorization-server",
        endpoint=cors_middleware(MetadataHandler(metadata).handle, ["GET", "OPTIONS"]),
        methods=["GET", "OPTIONS"],
    )
    funnel_app.router.routes = [
        metadata_route if (isinstance(r, Route) and r.path == "/.well-known/oauth-authorization-server") else r
        for r in funnel_app.router.routes
    ]

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
                                      proxy_headers=True, forwarded_allow_ips="127.0.0.1", lifespan="on")),
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
