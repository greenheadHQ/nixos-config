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
PUBLIC_HOST = f"{FQDN}:8443"
APPROVAL_HOST = f"{FQDN}:9443"


def _settings(tmp_path) -> Settings:
    (tmp_path / "approval").write_text("ANKI_MCP_APPROVAL_PASSPHRASE=open-sesame\n")
    return Settings(
        port=8790, approval_port=8791,
        public_url=f"https://{PUBLIC_HOST}", approval_url=f"https://{APPROVAL_HOST}",
        anki_connect_url="http://127.0.0.1:1", helper_url="http://127.0.0.1:1",
        state_dir=str(tmp_path), sync_status_file=str(tmp_path / "main.json"), sync_unit="u.service",
        passphrase_file=str(tmp_path / "approval"),
        access_ttl=60, refresh_ttl=600, code_ttl=30, sync_wait=5, lockout_failures=3, lockout_secs=60,
        field_chars=400, page_max=100,
        reg_max_clients=3, reg_max_client_bytes=4096, reg_unused_ttl=86400, reg_burst=5, reg_window=60,
        max_body_bytes=2048, body_read_timeout=30, max_concurrency=64,
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
    hdrs = {"host": PUBLIC_HOST}
    dcr = {"client_name": "t", "redirect_uris": ["https://client.example/cb"], "token_endpoint_auth_method": "none",
           "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]}
    async with funnel.router.lifespan_context(funnel):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=funnel), base_url=f"https://{PUBLIC_HOST}") as fh:
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
            # /mcp도 SDK의 광역 except(500)가 아니라 가드의 413이어야 한다

            async def chunks2():
                yield b"{" + b" " * 1500
                yield b" " * 1500 + b"}"

            chunked_mcp = await fh.post("/mcp", headers={**hdrs, "content-type": "application/json"}, content=chunks2())
            assert chunked_mcp.status_code == 413
            burst = await fh.post("/register", headers=hdrs, json=dcr)  # 창 안 6번째 시도 → rate limit
            assert burst.status_code == 429
            ok = await fh.post("/token", headers=hdrs, content=b"grant_type=x")
            assert ok.status_code in (400, 401)  # 가드를 통과해 SDK 핸들러까지 닿는다 (핸들러의 거부 응답)


@pytest.mark.anyio
@pytest.mark.parametrize("auth_method", ["none", "client_secret_post", None])
async def test_split_apps_metadata_and_full_oauth_flow(tmp_path, auth_method):
    funnel, approval = build(_settings(tmp_path))
    funnel_paths = _paths(funnel)
    assert "/authorize" not in funnel_paths
    for p in ("/.well-known/oauth-authorization-server", "/register", "/token", "/revoke", "/mcp"):
        assert p in funnel_paths
    assert _paths(approval) == ["/approve", "/approve", "/authorize", "/healthz"]

    redirect_uri = "https://client.example/cb"
    mcp_headers = {"host": PUBLIC_HOST}
    async with funnel.router.lifespan_context(funnel):  # streamable HTTP 세션 매니저(task group)를 띄운다
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=funnel), base_url=f"https://{PUBLIC_HOST}") as fh, \
                httpx.AsyncClient(transport=httpx.ASGITransport(app=approval), base_url=f"https://{APPROVAL_HOST}") as ah:
            meta = (await fh.get("/.well-known/oauth-authorization-server", headers=mcp_headers)).json()
            assert meta["issuer"].rstrip("/") == f"https://{PUBLIC_HOST}"
            assert meta["authorization_endpoint"] == f"https://{APPROVAL_HOST}/authorize"
            assert meta["token_endpoint"] == f"https://{PUBLIC_HOST}/token"
            assert meta["registration_endpoint"] == f"https://{PUBLIC_HOST}/register"
            assert "S256" in meta["code_challenge_methods_supported"]
            assert meta["token_endpoint_auth_methods_supported"] == ["none", "client_secret_post"]
            assert meta["revocation_endpoint_auth_methods_supported"] == ["none", "client_secret_post"]

            prm = await fh.get("/.well-known/oauth-protected-resource/mcp", headers=mcp_headers)
            assert prm.status_code == 200 and prm.json()["authorization_servers"][0].rstrip("/") == f"https://{PUBLIC_HOST}"
            assert prm.json()["resource"] == f"https://{PUBLIC_HOST}/mcp"

            # 1. DCR — 공개 클라이언트·본문 secret·방식 생략(SDK 기본 post)을 모두 검증한다.
            reg = await fh.post("/register", headers=mcp_headers, json={
                "client_name": "t", "redirect_uris": [redirect_uri],
                **({"token_endpoint_auth_method": auth_method} if auth_method is not None else {}),
                "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]})
            assert reg.status_code == 201, reg.text
            client_id = reg.json()["client_id"]
            assert reg.json()["token_endpoint_auth_method"] == (auth_method or "client_secret_post")
            credentials = {"client_id": client_id}
            if auth_method != "none":
                credentials["client_secret"] = reg.json()["client_secret"]
            assert client_id in json.dumps(json.load(open(tmp_path / "oauth-state.json", encoding="utf-8")))

            # 2. 토큰 없이 /mcp → 401 + PRM 안내
            r = await fh.post("/mcp", headers=mcp_headers, json={})
            assert r.status_code == 401 and "resource_metadata" in r.headers.get("www-authenticate", "")
            assert f"https://{PUBLIC_HOST}/.well-known/oauth-protected-resource/mcp" in r.headers["www-authenticate"]
            for path in ("/authorize", "/approve"):
                assert (await fh.get(path)).status_code == 404
            assert (await ah.get("/authorize", headers={"host": PUBLIC_HOST})).status_code == 421

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
                **credentials, "redirect_uri": redirect_uri})
            assert bad.status_code == 400
            if auth_method != "none":
                bad_secret = await fh.post("/token", headers=mcp_headers, data={
                    "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                    **credentials, "client_secret": "incorrect", "redirect_uri": redirect_uri})
                assert bad_secret.status_code == 401
            tok = await fh.post("/token", headers=mcp_headers, data={
                "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                **credentials, "redirect_uri": redirect_uri})
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

            # 7. Host·Origin의 포트도 일치해야 한다. 다른 포트나 포트 생략은 토큰이 있어도 거부한다.
            for wrong_host in ("evil.example", FQDN, f"{FQDN}:443", APPROVAL_HOST):
                r = await fh.post("/mcp", headers={**hdrs, "host": wrong_host}, json=rpc)
                assert r.status_code == 421
            r = await fh.post("/mcp", headers={**hdrs, "origin": f"https://{PUBLIC_HOST}"}, json=rpc)
            assert r.status_code == 200
            r = await fh.post("/mcp", headers={**hdrs, "origin": f"https://{FQDN}"}, json=rpc)
            assert r.status_code == 403

            rotated = await fh.post("/token", headers=mcp_headers, data={
                "grant_type": "refresh_token", "refresh_token": tok.json()["refresh_token"], **credentials})
            assert rotated.status_code == 200
            old_refresh = await fh.post("/token", headers=mcp_headers, data={
                "grant_type": "refresh_token", "refresh_token": tok.json()["refresh_token"], **credentials})
            assert old_refresh.status_code == 400

            # 8. 공개 클라이언트가 RFC 7009대로 client_secret 없이 철회 → 200이고, access·refresh(같은 grant)가 함께 죽는다
            if auth_method != "none":
                bad_revoke = await fh.post("/revoke", headers=mcp_headers, data={
                    "token": access, **credentials, "client_secret": "incorrect"})
                assert bad_revoke.status_code == 401
            rv = await fh.post("/revoke", headers=mcp_headers, data={"token": access, **credentials})
            assert rv.status_code == 200, rv.text
            r = await fh.post("/mcp", headers=hdrs, json=rpc)
            assert r.status_code == 401
            dead = await fh.post("/token", headers=mcp_headers, data={
                "grant_type": "refresh_token", "refresh_token": rotated.json()["refresh_token"], **credentials})
            assert dead.status_code == 400


@pytest.mark.anyio
@pytest.mark.parametrize("auth_method", ["client_secret_basic", "private_key_jwt"])
async def test_unsupported_client_auth_does_not_change_registration_state(tmp_path, auth_method):
    funnel, _ = build(_settings(tmp_path))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=funnel), base_url=f"https://{PUBLIC_HOST}") as http:
        registration = {"redirect_uris": ["https://client.example/cb"], "token_endpoint_auth_method": "none",
                        "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]}
        assert (await http.post("/register", json=registration)).status_code == 201
        state = tmp_path / "oauth-state.json"
        before = state.read_bytes()
        response = await http.post("/register", json={**registration, "token_endpoint_auth_method": auth_method})
        assert response.status_code == 400
        assert response.json()["error"] == "invalid_client_metadata"
        assert state.read_bytes() == before
