"""server.build()가 두 앱을 올바르게 나누는지와, 실제 OAuth 2.1 흐름(DCR → PKCE authorize → 승인 폼 → 토큰 → Bearer로
/mcp tools/list)이 ASGI 안에서 끝까지 도는지 검증한다. Funnel 앱에는 /authorize가 없고 메타데이터는 승인 URL을 가리킨다."""

import base64
import hashlib
import json
import secrets
from urllib.parse import parse_qs, urlencode, urlparse

import httpx
import pytest
from starlette.routing import Route

from anki_mcp.config import Settings
from anki_mcp.server import build

FQDN = "minipc.example.ts.net"
APPROVAL_HOST = f"{FQDN}:8443"


def _settings(tmp_path) -> Settings:
    (tmp_path / "approval").write_text("ANKI_MCP_APPROVAL_PASSPHRASE=open-sesame\n")
    return Settings(
        port=8790, approval_port=8791,
        public_url=f"https://{FQDN}", approval_url=f"https://{APPROVAL_HOST}",
        anki_connect_url="http://127.0.0.1:1", helper_url="http://127.0.0.1:1",
        state_dir=str(tmp_path), sync_status_file=str(tmp_path / "main.json"), sync_unit="u.service",
        passphrase_file=str(tmp_path / "approval"),
        access_ttl=60, refresh_ttl=600, code_ttl=30, sync_wait=5, lockout_failures=3, lockout_secs=60,
        field_chars=400, page_max=100,
        reg_max_clients=3, reg_max_client_bytes=4096, reg_unused_ttl=86400, reg_burst=5, reg_window=60,
        max_body_bytes=2048,
    )


def _paths(app):
    return sorted(r.path for r in app.router.routes if isinstance(r, Route))


def _pkce():
    verifier = secrets.token_urlsafe(40)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    return verifier, challenge


@pytest.mark.anyio
async def test_funnel_guard_caps_registrations_and_body_size(tmp_path):
    funnel, _ = build(_settings(tmp_path))
    hdrs = {"host": FQDN}
    dcr = {"client_name": "t", "redirect_uris": ["https://client.example/cb"], "token_endpoint_auth_method": "none",
           "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]}
    async with funnel.router.lifespan_context(funnel):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=funnel), base_url=f"https://{FQDN}") as fh:
            for _ in range(3):
                assert (await fh.post("/register", headers=hdrs, json=dcr)).status_code == 201
            full = await fh.post("/register", headers=hdrs, json=dcr)  # 등록 상한(3) — SDK가 400으로 돌려준다
            assert full.status_code == 400 and "full" in full.json()["error_description"]
            # 본문 상한 — Content-Length가 있는 요청은 읽기 전에, 없는(chunked) 요청은 핸들러가 읽는 도중 끊는다
            big = await fh.post("/token", headers=hdrs, content=b"x" * 4096)
            assert big.status_code == 413

            async def chunks():
                yield b"{" + b" " * 1500
                yield b" " * 1500 + b"}"

            chunked = await fh.post("/register", headers={**hdrs, "content-type": "application/json"}, content=chunks())
            assert chunked.status_code == 413
            burst = await fh.post("/register", headers=hdrs, json=dcr)  # 창 안 6번째 시도 → rate limit
            assert burst.status_code == 429
            ok = await fh.post("/token", headers=hdrs, content=b"grant_type=x")
            assert ok.status_code in (400, 401)  # 가드를 통과해 SDK 핸들러까지 닿는다 (핸들러의 거부 응답)


@pytest.mark.anyio
async def test_split_apps_metadata_and_full_oauth_flow(tmp_path):
    funnel, approval = build(_settings(tmp_path))
    funnel_paths = _paths(funnel)
    assert "/authorize" not in funnel_paths
    for p in ("/.well-known/oauth-authorization-server", "/register", "/token", "/revoke", "/mcp"):
        assert p in funnel_paths
    assert _paths(approval) == ["/approve", "/approve", "/authorize", "/healthz"]

    redirect_uri = "https://client.example/cb"
    mcp_headers = {"host": FQDN}
    async with funnel.router.lifespan_context(funnel):  # streamable HTTP 세션 매니저(task group)를 띄운다
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=funnel), base_url=f"https://{FQDN}") as fh, \
                httpx.AsyncClient(transport=httpx.ASGITransport(app=approval), base_url=f"https://{APPROVAL_HOST}") as ah:
            meta = (await fh.get("/.well-known/oauth-authorization-server", headers=mcp_headers)).json()
            assert meta["issuer"].rstrip("/") == f"https://{FQDN}"
            assert meta["authorization_endpoint"] == f"https://{APPROVAL_HOST}/authorize"
            assert meta["token_endpoint"] == f"https://{FQDN}/token"
            assert meta["registration_endpoint"] == f"https://{FQDN}/register"
            assert "S256" in meta["code_challenge_methods_supported"]

            prm = await fh.get("/.well-known/oauth-protected-resource/mcp", headers=mcp_headers)
            assert prm.status_code == 200 and prm.json()["authorization_servers"][0].rstrip("/") == f"https://{FQDN}"

            # 1. DCR — ChatGPT/Claude가 첫 연결에서 하는 것 (public client, PKCE)
            reg = await fh.post("/register", headers=mcp_headers, json={
                "client_name": "t", "redirect_uris": [redirect_uri], "token_endpoint_auth_method": "none",
                "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]})
            assert reg.status_code == 201, reg.text
            client_id = reg.json()["client_id"]
            assert client_id in json.dumps(json.load(open(tmp_path / "oauth-state.json", encoding="utf-8")))

            # 2. 토큰 없이 /mcp → 401 + PRM 안내
            r = await fh.post("/mcp", headers=mcp_headers, json={})
            assert r.status_code == 401 and "resource_metadata" in r.headers.get("www-authenticate", "")

            # 3. /authorize는 승인 앱에만 — PKCE 검증 뒤 승인 폼으로 리다이렉트
            verifier, challenge = _pkce()
            q = urlencode({"response_type": "code", "client_id": client_id, "redirect_uri": redirect_uri,
                           "code_challenge": challenge, "code_challenge_method": "S256", "state": "xyz", "scope": "anki"})
            r = await ah.get(f"/authorize?{q}", headers={"host": APPROVAL_HOST}, follow_redirects=False)
            assert r.status_code in (302, 307), r.text
            loc = r.headers["location"]
            assert loc.startswith(f"https://{APPROVAL_HOST}/approve?txn=")
            txn = parse_qs(urlparse(loc).query)["txn"][0]
            r = await ah.get(f"/approve?txn={txn}", headers={"host": APPROVAL_HOST})
            assert r.status_code == 200 and "client.example" in r.text

            # 4. 승인 문구 → 코드 발급 → 클라이언트 redirect_uri
            r = await ah.post("/approve", headers={"host": APPROVAL_HOST}, follow_redirects=False,
                              data={"txn": txn, "passphrase": "open-sesame", "decision": "approve"})
            assert r.status_code == 302
            cb = parse_qs(urlparse(r.headers["location"]).query)
            assert cb["state"] == ["xyz"]
            code = cb["code"][0]

            # 5. 코드 교환 (Funnel 앱) — 틀린 verifier는 거부
            bad = await fh.post("/token", headers=mcp_headers, data={
                "grant_type": "authorization_code", "code": code, "code_verifier": "wrong" * 10,
                "client_id": client_id, "redirect_uri": redirect_uri})
            assert bad.status_code == 400
            tok = await fh.post("/token", headers=mcp_headers, data={
                "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                "client_id": client_id, "redirect_uri": redirect_uri})
            assert tok.status_code == 200, tok.text
            access = tok.json()["access_token"]
            assert tok.json()["token_type"].lower() == "bearer" and tok.json().get("refresh_token")

            # 6. Bearer로 tools/list (stateless streamable HTTP) — 도구 목록에 조회·추가 도구가 있고 삭제는 없다
            rpc = {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
            hdrs = {**mcp_headers, "authorization": f"Bearer {access}",
                    "accept": "application/json, text/event-stream", "content-type": "application/json"}
            r = await fh.post("/mcp", headers=hdrs, json=rpc)
            assert r.status_code == 200, r.text
            names = {t["name"] for t in r.json()["result"]["tools"]}
            assert {"anki_find_notes", "anki_add_notes", "anki_sync_now"} <= names and "anki_delete_notes" not in names

            # 7. DNS rebinding 방어 — 토큰이 있어도 허용되지 않은 Host면 거부
            r = await fh.post("/mcp", headers={**hdrs, "host": "evil.example"}, json=rpc)
            assert r.status_code == 421

            # 8. 철회 뒤에는 401
            # SDK의 RevocationRequest는 client_secret 필드를 요구한다(public client는 빈 값) — 클라이언트 라이브러리도 그렇게 보낸다
            rv = await fh.post("/revoke", headers=mcp_headers, data={"token": access, "client_id": client_id, "client_secret": ""})
            assert rv.status_code == 200
            r = await fh.post("/mcp", headers=hdrs, json=rpc)
            assert r.status_code == 401
