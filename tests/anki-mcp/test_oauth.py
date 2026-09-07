import base64
import hashlib
import json
import secrets
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from mcp.server.auth.provider import AuthorizationParams
from mcp.shared.auth import OAuthClientInformationFull
from pydantic import AnyUrl

from anki_mcp.approval import Lockout, build_approval_app
from anki_mcp.oauth import FileOAuthProvider

APPROVAL = "https://minipc.example.ts.net:8443"


def _client(client_id="c1", auth="none"):
    return OAuthClientInformationFull(
        client_id=client_id,
        client_name="Test Client",
        redirect_uris=[AnyUrl("https://client.example/cb")],
        token_endpoint_auth_method=auth,
        grant_types=["authorization_code", "refresh_token"],
    )


def _pkce():
    verifier = secrets.token_urlsafe(40)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    return verifier, challenge


def _params(challenge, state="st"):
    return AuthorizationParams(
        state=state, scopes=["anki"], code_challenge=challenge,
        redirect_uri=AnyUrl("https://client.example/cb"), redirect_uri_provided_explicitly=True, resource=None,
    )


@pytest.mark.anyio
async def test_provider_full_lifecycle_and_persistence(tmp_path):
    path = str(tmp_path / "oauth-state.json")
    clock = {"t": 1000.0}
    prov = FileOAuthProvider(path, APPROVAL, access_ttl=60, refresh_ttl=600, code_ttl=30, now=lambda: clock["t"])
    client = _client()
    await prov.register_client(client)
    assert (await prov.get_client("c1")).client_name == "Test Client"

    _, challenge = _pkce()
    url = await prov.authorize(client, _params(challenge))
    txn = parse_qs(urlparse(url).query)["txn"][0]
    assert url.startswith(f"{APPROVAL}/approve?txn=")
    assert prov.pending(txn)["client_name"] == "Test Client"

    redirect = prov.complete_approval(txn)
    q = parse_qs(urlparse(redirect).query)
    code = q["code"][0]
    assert q["state"] == ["st"] and prov.pending(txn) is None

    auth_code = await prov.load_authorization_code(client, code)
    assert auth_code and auth_code.code_challenge == challenge
    assert await prov.load_authorization_code(_client("other"), code) is None

    tokens = await prov.exchange_authorization_code(client, auth_code)
    assert await prov.load_authorization_code(client, code) is None  # 1회용
    access = await prov.load_access_token(tokens.access_token)
    assert access and access.client_id == "c1" and access.scopes == ["anki"]

    # 파일에는 해시만 — 평문 토큰이 없다
    raw = json.loads(open(path, encoding="utf-8").read())
    assert tokens.access_token not in json.dumps(raw) and tokens.refresh_token not in json.dumps(raw)

    # 재시작 후에도 클라이언트·토큰이 살아 있다
    prov2 = FileOAuthProvider(path, APPROVAL, access_ttl=60, refresh_ttl=600, code_ttl=30, now=lambda: clock["t"])
    assert (await prov2.get_client("c1")) is not None
    assert (await prov2.load_access_token(tokens.access_token)) is not None

    # 만료 뒤 access는 죽고 refresh로 회전
    clock["t"] += 61
    assert await prov2.load_access_token(tokens.access_token) is None
    rt = await prov2.load_refresh_token(client, tokens.refresh_token)
    assert rt is not None
    new_tokens = await prov2.exchange_refresh_token(client, rt, ["anki"])
    assert await prov2.load_refresh_token(client, tokens.refresh_token) is None  # 옛 refresh 무효
    assert await prov2.load_access_token(new_tokens.access_token) is not None

    # 철회
    await prov2.revoke_token(await prov2.load_access_token(new_tokens.access_token))
    assert await prov2.load_access_token(new_tokens.access_token) is None

    with pytest.raises(ValueError):
        rt2 = await prov2.load_refresh_token(client, new_tokens.refresh_token)
        await prov2.exchange_refresh_token(client, rt2, ["anki", "admin"])


@pytest.mark.anyio
async def test_approval_form_requires_passphrase_and_locks_out(tmp_path):
    prov = FileOAuthProvider(str(tmp_path / "s.json"), APPROVAL, 60, 600, 30)
    client = _client()
    await prov.register_client(client)
    _, challenge = _pkce()
    url = await prov.authorize(client, _params(challenge))
    txn = parse_qs(urlparse(url).query)["txn"][0]
    secret = {"value": "correct horse"}
    lockout = Lockout(max_failures=2, lock_secs=300)
    app = build_approval_app(prov, APPROVAL, passphrase=lambda: secret["value"], lockout=lockout)
    host = "minipc.example.ts.net:8443"
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as http:
        # 잘못된 Host는 거부 (Funnel을 통해 들어온 요청 방어)
        r = await http.get(f"/approve?txn={txn}", headers={"host": "minipc.example.ts.net"})
        assert r.status_code == 421
        r = await http.get(f"/approve?txn={txn}", headers={"host": host})
        assert r.status_code == 200 and "Test Client" in r.text
        # 틀린 문구 → 폼 재표시, 2회면 잠금
        r = await http.post("/approve", data={"txn": txn, "passphrase": "nope", "decision": "approve"}, headers={"host": host})
        assert r.status_code == 200 and "맞지 않습니다" in r.text
        r = await http.post("/approve", data={"txn": txn, "passphrase": "nope", "decision": "approve"}, headers={"host": host})
        assert lockout.locked()
        r = await http.post("/approve", data={"txn": txn, "passphrase": "correct horse", "decision": "approve"}, headers={"host": host})
        assert r.status_code == 200 and "잠겼습니다" in r.text
        lockout.locked_until = 0
        # 빈 문구 설정이면 어떤 입력도 통과하지 않는다
        secret["value"] = ""
        r = await http.post("/approve", data={"txn": txn, "passphrase": "", "decision": "approve"}, headers={"host": host})
        assert r.status_code == 200 and "설정되어 있지 않아" in r.text
        secret["value"] = "correct horse"
        r = await http.post("/approve", data={"txn": txn, "passphrase": "correct horse", "decision": "approve"},
                            headers={"host": host}, follow_redirects=False)
        assert r.status_code == 302
        q = parse_qs(urlparse(r.headers["location"]).query)
        assert "code" in q and q["state"] == ["st"]
        # 같은 txn 재사용 불가
        r = await http.get(f"/approve?txn={txn}", headers={"host": host})
        assert r.status_code == 400


@pytest.mark.anyio
async def test_deny_redirects_with_access_denied(tmp_path):
    prov = FileOAuthProvider(str(tmp_path / "s.json"), APPROVAL, 60, 600, 30)
    client = _client()
    await prov.register_client(client)
    _, challenge = _pkce()
    url = await prov.authorize(client, _params(challenge, state="zz"))
    txn = parse_qs(urlparse(url).query)["txn"][0]
    app = build_approval_app(prov, APPROVAL, passphrase=lambda: "x", lockout=Lockout(5, 60))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as http:
        r = await http.post("/approve", data={"txn": txn, "decision": "deny"}, headers={"host": "minipc.example.ts.net:8443"},
                            follow_redirects=False)
        assert r.status_code == 302
        q = parse_qs(urlparse(r.headers["location"]).query)
        assert q["error"] == ["access_denied"] and q["state"] == ["zz"]
