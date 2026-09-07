import base64
import hashlib
import json
import secrets
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from mcp.server.auth.provider import AuthorizationParams, RegistrationError, TokenError
from mcp.shared.auth import OAuthClientInformationFull
from pydantic import AnyUrl

from anki_mcp.approval import Lockout, build_approval_app
from anki_mcp.oauth import FileOAuthProvider

APPROVAL = "https://minipc.example.ts.net:9443"
RESOURCE = "https://minipc.example.ts.net:8443/mcp"


def _provider(path, *, access_ttl=60, refresh_ttl=600, code_ttl=30, max_refresh_rotations=4096, **kwargs):
    return FileOAuthProvider(path, APPROVAL, access_ttl, refresh_ttl, code_ttl,
                             RESOURCE, max_refresh_rotations, **kwargs)


def _client(client_id="c1", auth="none", issued_at=None):
    return OAuthClientInformationFull(
        client_id=client_id,
        client_id_issued_at=issued_at,
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


async def _grant_tokens(provider, client):
    _, challenge = _pkce()
    txn = parse_qs(urlparse(await provider.authorize(client, _params(challenge))).query)["txn"][0]
    code = parse_qs(urlparse(provider.complete_approval(txn)).query)["code"][0]
    return await provider.exchange_authorization_code(client, await provider.load_authorization_code(client, code))


@pytest.mark.anyio
async def test_provider_full_lifecycle_and_persistence(tmp_path):
    path = str(tmp_path / "oauth-state.json")
    clock = {"t": 1000.0}
    prov = _provider(path, now=lambda: clock["t"])
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
    assert access.resource == RESOURCE  # 새 승인에서 resource 생략은 단일 Anki 대상으로 확정한다

    # 파일에는 해시만 — 평문 토큰이 없다
    raw = json.loads(open(path, encoding="utf-8").read())
    assert tokens.access_token not in json.dumps(raw) and tokens.refresh_token not in json.dumps(raw)

    # 재시작 후에도 클라이언트·토큰이 살아 있다
    prov2 = _provider(path, now=lambda: clock["t"])
    assert (await prov2.get_client("c1")) is not None
    assert (await prov2.load_access_token(tokens.access_token)) is not None

    # 만료 뒤 access는 죽고 refresh로 회전
    clock["t"] += 61
    assert await prov2.load_access_token(tokens.access_token) is None
    rt = await prov2.load_refresh_token(client, tokens.refresh_token)
    assert rt is not None
    new_tokens = await prov2.exchange_refresh_token(client, rt, ["anki"])
    # 옛 refresh를 실제로 다시 제출하면 grant가 철회된다. 재사용 경로는 별도 테스트에서 검증한다.
    assert await prov2.load_access_token(new_tokens.access_token) is not None

    # scope 확장은 거부되고, 거부된 요청이 refresh를 소비하지 않는다
    rt2 = await prov2.load_refresh_token(client, new_tokens.refresh_token)
    with pytest.raises(TokenError):
        await prov2.exchange_refresh_token(client, rt2, ["anki", "admin"])
    assert await prov2.load_refresh_token(client, new_tokens.refresh_token) is not None

    # 철회 — access를 철회하면 같은 승인의 refresh도 함께 죽는다
    await prov2.revoke_token(await prov2.load_access_token(new_tokens.access_token))
    assert await prov2.load_access_token(new_tokens.access_token) is None
    assert await prov2.load_refresh_token(client, new_tokens.refresh_token) is None


@pytest.mark.anyio
async def test_revoking_either_token_kills_the_whole_grant(tmp_path):
    prov = _provider(str(tmp_path / "s.json"))
    client = _client()
    await prov.register_client(client)

    async def grant():
        _, challenge = _pkce()
        txn = parse_qs(urlparse(await prov.authorize(client, _params(challenge))).query)["txn"][0]
        code = parse_qs(urlparse(prov.complete_approval(txn)).query)["code"][0]
        return await prov.exchange_authorization_code(client, await prov.load_authorization_code(client, code))

    # refresh를 철회하면 (회전을 거친) access도 죽는다 — grant 하나가 통째로 사라진다
    t1 = await grant()
    rt = await prov.load_refresh_token(client, t1.refresh_token)
    t1b = await prov.exchange_refresh_token(client, rt, ["anki"])
    assert await prov.load_access_token(t1b.access_token) is not None
    await prov.revoke_token(await prov.load_refresh_token(client, t1b.refresh_token))
    assert await prov.load_access_token(t1b.access_token) is None
    assert await prov.load_refresh_token(client, t1b.refresh_token) is None

    # 다른 승인(grant)은 건드리지 않는다; access 철회도 같은 grant의 refresh를 죽인다
    t2 = await grant()
    t3 = await grant()
    await prov.revoke_token(await prov.load_access_token(t2.access_token))
    assert await prov.load_refresh_token(client, t2.refresh_token) is None
    assert await prov.load_access_token(t3.access_token) is not None
    assert await prov.load_refresh_token(client, t3.refresh_token) is not None


@pytest.mark.anyio
async def test_registration_is_capped_and_unused_clients_are_pruned(tmp_path):
    clock = {"t": 10_000.0}
    prov = _provider(str(tmp_path / "s.json"), now=lambda: clock["t"],
                             max_clients=2, max_client_bytes=600, unused_client_ttl=100)
    await prov.register_client(_client("c1", issued_at=int(clock["t"])))
    await prov.register_client(_client("c2", issued_at=int(clock["t"])))
    # 미승인 등록이 상한을 채워도 TTL을 기다리지 않고 새 연결을 시작할 수 있다.
    await prov.register_client(_client("fresh", issued_at=int(clock["t"])))
    assert {c["client_id"] for c in prov.clients()} == {"c2", "fresh"}

    # 토큰 없는 등록은 TTL이 지나면 새 등록이 들어올 때 정리된다
    clock["t"] += 101
    await prov.register_client(_client("c3", issued_at=int(clock["t"])))
    assert {c["client_id"] for c in prov.clients()} == {"c3"}

    # 토큰이 살아 있는 클라이언트는 나이와 무관하게 남는다
    c3 = await prov.get_client("c3")
    _, challenge = _pkce()
    txn = parse_qs(urlparse(await prov.authorize(c3, _params(challenge))).query)["txn"][0]
    code = parse_qs(urlparse(prov.complete_approval(txn)).query)["code"][0]
    await prov.exchange_authorization_code(c3, await prov.load_authorization_code(c3, code))
    clock["t"] += 101
    await prov.register_client(_client("c4", issued_at=int(clock["t"])))
    await prov.register_client(_client("c5", issued_at=int(clock["t"])))
    assert {c["client_id"] for c in prov.clients()} == {"c3", "c5"}

    # 레코드 크기 상한
    fat = _client("c6", issued_at=int(clock["t"]))
    fat.client_name = "x" * 1000
    with pytest.raises(RegistrationError):
        await prov.register_client(fat)


@pytest.mark.anyio
async def test_saturated_registration_preserves_pending_codes_and_tokens(tmp_path):
    path = str(tmp_path / "s.json")
    clock = {"t": 10_000.0}
    prov = _provider(path, now=lambda: clock["t"], max_clients=2)
    for cid in ("old", "newer"):
        await prov.register_client(_client(cid, issued_at=int(clock["t"])))
        clock["t"] += 1
    # 재시작으로 복원된 미승인 등록도 새 승인을 막지 않는다.
    prov = _provider(path, now=lambda: clock["t"], max_clients=2)
    client = _client("legitimate", issued_at=int(clock["t"]))
    await prov.register_client(client)
    assert await prov.get_client("old") is None
    _, challenge = _pkce()
    txn = parse_qs(urlparse(await prov.authorize(client, _params(challenge))).query)["txn"][0]
    for i in range(3):
        await prov.register_client(_client(f"public-{i}", issued_at=int(clock["t"])))
    assert prov.pending(txn) and await prov.get_client(client.client_id)
    code = parse_qs(urlparse(prov.complete_approval(txn)).query)["code"][0]
    await prov.register_client(_client("another", issued_at=int(clock["t"])))
    tokens = await prov.exchange_authorization_code(client, await prov.load_authorization_code(client, code))
    assert await prov.load_access_token(tokens.access_token)
    # 모든 슬롯이 활성 상태면 기존 연결을 지우지 않고 새 등록만 거부한다.
    another = await prov.get_client("another")
    await _grant_tokens(prov, another)
    before = open(path, encoding="utf-8").read()
    with pytest.raises(RegistrationError, match="full"):
        await prov.register_client(_client("blocked", issued_at=int(clock["t"])))
    assert open(path, encoding="utf-8").read() == before
    assert await prov.load_access_token(tokens.access_token)
    assert await prov.load_refresh_token(client, tokens.refresh_token)


@pytest.mark.anyio
async def test_approval_form_requires_passphrase_and_locks_out(tmp_path):
    prov = _provider(str(tmp_path / "s.json"))
    client = _client()
    await prov.register_client(client)
    _, challenge = _pkce()
    url = await prov.authorize(client, _params(challenge))
    txn = parse_qs(urlparse(url).query)["txn"][0]
    secret = {"value": "correct horse"}
    lockout = Lockout(max_failures=2, lock_secs=300)
    app = build_approval_app(prov, APPROVAL, passphrase=lambda: secret["value"], lockout=lockout)
    host = "minipc.example.ts.net:9443"
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as http:
        # 잘못된 Host는 거부 (Funnel을 통해 들어온 요청 방어)
        r = await http.get(f"/approve?txn={txn}", headers={"host": "minipc.example.ts.net"})
        assert r.status_code == 421
        r = await http.get(f"/approve?txn={txn}", headers={"host": host})
        assert r.status_code == 200 and "Test Client" in r.text
        # 프레임 금지 + 캐시 금지 (clickjacking·뒤로가기 캐시)
        csp = r.headers["content-security-policy"]
        assert r.headers["x-frame-options"] == "DENY" and "frame-ancestors 'none'" in csp
        assert r.headers["cache-control"] == "no-store"
        # form-action은 넣지 않는다 — OAuth 콜백(외부 origin 302)을 Chromium이 막는다
        assert "form-action" not in csp
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
    prov = _provider(str(tmp_path / "s.json"))
    client = _client()
    await prov.register_client(client)
    _, challenge = _pkce()
    url = await prov.authorize(client, _params(challenge, state="zz"))
    txn = parse_qs(urlparse(url).query)["txn"][0]
    app = build_approval_app(prov, APPROVAL, passphrase=lambda: "x", lockout=Lockout(5, 60))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as http:
        r = await http.post("/approve", data={"txn": txn, "decision": "deny"}, headers={"host": "minipc.example.ts.net:9443"},
                            follow_redirects=False)
        assert r.status_code == 302
        q = parse_qs(urlparse(r.headers["location"]).query)
        assert q["error"] == ["access_denied"] and q["state"] == ["zz"]


@pytest.mark.anyio
async def test_refresh_replay_survives_restart_and_the_old_token_expiry(tmp_path):
    path = str(tmp_path / "s.json")
    clock = {"t": 1000.0}
    prov = _provider(path, now=lambda: clock["t"])
    client = _client()
    other = _client("other")
    await prov.register_client(client)
    await prov.register_client(other)
    first = await _grant_tokens(prov, client)
    clock["t"] = 1100
    second = await prov.exchange_refresh_token(client, await prov.load_refresh_token(client, first.refresh_token), ["anki"])
    clock["t"] = 1599
    third = await prov.exchange_refresh_token(client, await prov.load_refresh_token(client, second.refresh_token), ["anki"])

    # R1 자체는 만료됐어도 R3와 같은 승인이 살아 있으므로 R1 재사용을 탐지해야 한다.
    clock["t"] = 1601
    prov = _provider(path, now=lambda: clock["t"])
    unrelated = await _grant_tokens(prov, client)
    assert await prov.load_refresh_token(other, first.refresh_token) is None
    assert await prov.load_refresh_token(client, "unknown-token") is None
    assert await prov.load_access_token(third.access_token) is not None
    assert await prov.load_refresh_token(client, first.refresh_token) is None
    assert await prov.load_access_token(third.access_token) is None
    assert await prov.load_refresh_token(client, third.refresh_token) is None
    assert await prov.load_access_token(unrelated.access_token) is not None
    assert await prov.load_refresh_token(client, unrelated.refresh_token) is not None

    restarted = _provider(path, now=lambda: clock["t"])
    assert await restarted.load_access_token(third.access_token) is None
    assert await restarted.load_refresh_token(client, third.refresh_token) is None


@pytest.mark.anyio
async def test_refresh_history_limit_requires_new_approval_without_losing_replay_history(tmp_path):
    path = str(tmp_path / "s.json")
    prov = _provider(path, max_refresh_rotations=2)
    client = _client()
    await prov.register_client(client)
    tokens = await _grant_tokens(prov, client)
    for _ in range(2):
        tokens = await prov.exchange_refresh_token(client, await prov.load_refresh_token(client, tokens.refresh_token), ["anki"])
    current = await prov.load_refresh_token(client, tokens.refresh_token)
    with pytest.raises(TokenError, match="scopes"):
        await prov.exchange_refresh_token(client, current, ["admin"])
    with pytest.raises(TokenError):
        await prov.exchange_refresh_token(_client("other"), current, ["anki"])
    assert await prov.load_access_token(tokens.access_token) is not None
    with pytest.raises(TokenError, match="authorization is required"):
        await prov.exchange_refresh_token(client, current, ["anki"])
    assert await prov.load_access_token(tokens.access_token) is None
    assert await prov.load_refresh_token(client, tokens.refresh_token) is None
    saved = json.loads(open(path, encoding="utf-8").read())
    assert not saved["access"] and not saved["refresh"]
    # 새 grant에는 다시 사용자 승인이 필요하며, 정상 승인 뒤에는 연결할 수 있다.
    fresh = await _grant_tokens(prov, client)
    assert await prov.load_access_token(fresh.access_token) is not None


@pytest.mark.anyio
async def test_inactive_refresh_history_is_pruned_before_reusing_registration_capacity(tmp_path):
    clock = {"t": 1000.0}
    prov = _provider(str(tmp_path / "s.json"), max_clients=1, unused_client_ttl=100, now=lambda: clock["t"])
    client = _client(issued_at=1000)
    await prov.register_client(client)
    first = await _grant_tokens(prov, client)
    await prov.exchange_refresh_token(client, await prov.load_refresh_token(client, first.refresh_token), ["anki"])
    clock["t"] = 1700
    await prov.register_client(_client("next", issued_at=1700))
    assert {c["client_id"] for c in prov.clients()} == {"next"}
