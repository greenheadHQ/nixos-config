"""내장 OAuth 2.1 인가 서버 provider — mcp SDK의 OAuthAuthorizationServerProvider 프로토콜 구현.

- 클라이언트: DCR(/register)로 등록되며 파일에 영속한다(ChatGPT·Codex·Claude가 각자 등록).
- 인가: /authorize(승인 포트)에서 SDK 핸들러가 PKCE·redirect_uri를 검증한 뒤 authorize()를 부른다. 여기서는
  대기 트랜잭션을 만들고 승인 화면(/approve?txn=)으로 보낸다. 승인 화면이 비밀 문구를 확인하면
  complete_approval()이 코드를 발급해 클라이언트 redirect_uri로 돌려보낸다.
- 토큰: 불투명 랜덤 토큰. 파일에는 sha256 해시만 저장한다(파일이 새도 토큰을 복원할 수 없다).
  access 만료 후 refresh로 갱신(회전), /revoke로 철회. 매 요청 검증은 SDK 미들웨어가 load_access_token으로 한다.
  토큰 대상은 이 서버의 canonical resource로 고정한다. 대상이 없거나 다른 기존 access·refresh는 거부한다.
  한 승인에서 나온 access·refresh(회전 뒤 것까지)는 같은 grant id를 갖고, 어느 하나를 철회하면 grant 전체가 죽는다
  (refresh만 철회했는데 access가 살아 있는 구멍 방지).
  사용한 refresh 해시는 grant가 살아 있는 동안 보존하고 재사용 시 grant 전체를 철회한다. 회전 상한 초과도 재승인을 요구한다.
- 등록 상한: /register는 인증 없이 인터넷에 열려 있다. 클라이언트 수·레코드 크기에 상한을 두고, 토큰이 하나도
  없는 오래된 등록은 새 등록이 들어올 때 정리한다. 포화 시 비활성 등록 중 가장 오래된 것을 교체하며,
  토큰·인가 코드·승인 대기 중 하나라도 있는 클라이언트는 보존한다.
"""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import time
from typing import Any, Callable
from urllib.parse import urlsplit, urlunsplit

from mcp.server.auth.provider import (
    AccessToken,
    AuthorizationCode,
    AuthorizationParams,
    AuthorizeError,
    RefreshToken,
    RegistrationError,
    TokenError,
    construct_redirect_uri,
)
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken
from pydantic import AnyUrl

DEFAULT_SCOPES = ["anki"]
CLIENT_AUTH_METHODS = ("none", "client_secret_post")


def safe_redirect_uri(uri: Any) -> bool:
    """OAuth 2.1 §2.3: HTTPS 또는 로컬 callback만, fragment·userinfo는 받지 않는다."""
    value = str(uri)
    parsed = urlsplit(value)
    if "#" in value or not parsed.hostname or parsed.username is not None or parsed.password is not None:
        return False
    return parsed.scheme == "https" or (
        parsed.scheme == "http" and parsed.hostname in {"localhost", "127.0.0.1", "::1"}
    )


def canonical_resource(value: str) -> str | None:
    """scheme·host의 대소문자만 정규화한다. 경로·포트·query는 리소스 식별자의 일부다."""
    try:
        parsed = urlsplit(value)
        if (parsed.scheme != "https" or not parsed.hostname or "#" in value
                or parsed.username is not None or parsed.password is not None):
            return None
        return urlunsplit((parsed.scheme, parsed.netloc.lower(), parsed.path, parsed.query, ""))
    except ValueError:
        return None


class RegisteredOAuthClient(OAuthClientInformationFull):
    def validate_redirect_uri(self, redirect_uri: AnyUrl | None) -> AnyUrl:
        # OAuth 2.1 §8.4.2: IP loopback HTTP는 인가 요청에서 수신 포트만 바꿀 수 있다.
        if redirect_uri is not None and safe_redirect_uri(redirect_uri):
            requested = urlsplit(str(redirect_uri))
            if requested.scheme == "http" and requested.hostname in {"127.0.0.1", "::1"}:
                for registered_uri in self.redirect_uris or []:
                    registered = urlsplit(str(registered_uri))
                    if safe_redirect_uri(registered_uri) and (
                        registered.scheme, registered.hostname, registered.path, registered.query
                    ) == (requested.scheme, requested.hostname, requested.path, requested.query):
                        return redirect_uri
        return super().validate_redirect_uri(redirect_uri)


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


class FileOAuthProvider:
    def __init__(
        self,
        state_path: str,
        approval_url: str,
        access_ttl: int,
        refresh_ttl: int,
        code_ttl: int,
        resource_url: str,
        max_refresh_rotations: int,
        now: Callable[[], float] = time.time,
        max_clients: int = 32,
        max_client_bytes: int = 4096,
        unused_client_ttl: int = 86400,
    ) -> None:
        self._path = state_path
        self._approval_url = approval_url.rstrip("/")
        self._access_ttl = access_ttl
        self._refresh_ttl = refresh_ttl
        self._code_ttl = code_ttl
        self._resource_url = canonical_resource(resource_url)
        if self._resource_url is None or max_refresh_rotations < 1:
            raise ValueError("a valid HTTPS resource and positive refresh rotation limit are required")
        self._max_refresh_rotations = max_refresh_rotations
        self._now = now
        self._max_clients = max_clients
        self._max_client_bytes = max_client_bytes
        self._unused_client_ttl = unused_client_ttl
        self._state: dict[str, dict[str, Any]] = {"clients": {}, "access": {}, "refresh": {}}
        self._codes: dict[str, AuthorizationCode] = {}
        self._pending: dict[str, dict[str, Any]] = {}
        self._load()

    # ── 영속 ──────────────────────────────────────────────────────────────
    def _load(self) -> None:
        try:
            with open(self._path, encoding="utf-8") as stream:
                data = json.load(stream)
            for key in self._state:
                self._state[key] = dict(data.get(key) or {})
        except (OSError, ValueError):
            pass

    def _save(self) -> None:
        tmp = f"{self._path}.partial"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(self._state, stream)
        os.replace(tmp, self._path)

    def _prune(self) -> None:
        now = self._now()
        for bucket in ("access", "refresh"):
            # 사용한 refresh는 원래 만료 시각으로 지우지 않는다. 살아 있는 grant의 재사용 탐지에 필요하다.
            expired = [h for h, rec in self._state[bucket].items()
                       if not rec.get("used") and rec.get("expires_at") and rec["expires_at"] < now]
            for h in expired:
                del self._state[bucket][h]
        live_grants = {rec.get("grant") for bucket in ("access", "refresh")
                       for rec in self._state[bucket].values() if not rec.get("used")}
        for h, rec in list(self._state["refresh"].items()):
            if rec.get("used") and rec.get("grant") not in live_grants:
                del self._state["refresh"][h]
        for code, rec in list(self._codes.items()):
            if rec.expires_at < now:
                del self._codes[code]
        for txn, rec in list(self._pending.items()):
            if rec["created"] + self._code_ttl < now:
                del self._pending[txn]

    # ── 클라이언트 ─────────────────────────────────────────────────────────
    async def get_client(self, client_id: str) -> OAuthClientInformationFull | None:
        raw = self._state["clients"].get(client_id)
        if not raw:
            return None
        client = RegisteredOAuthClient.model_validate(raw)
        # 이전 버전에 저장된 위험한 callback으로 오류 응답도 리다이렉트하지 않는다.
        if not client.redirect_uris or not all(safe_redirect_uri(uri) for uri in client.redirect_uris):
            return None
        return client

    def _active_client_ids(self) -> set[str]:
        """토큰·코드·대기 트랜잭션 중 하나라도 있는 클라이언트 — 정리 대상에서 제외한다."""
        ids = {rec["client_id"] for bucket in ("access", "refresh") for rec in self._state[bucket].values()}
        ids.update(code.client_id for code in self._codes.values())
        ids.update(rec["client_id"] for rec in self._pending.values())
        return ids

    def _prune_unused_clients(self) -> None:
        self._prune()
        now = self._now()
        active = self._active_client_ids()
        for cid, rec in list(self._state["clients"].items()):
            issued = rec.get("client_id_issued_at") or 0
            if cid not in active and issued + self._unused_client_ttl < now:
                del self._state["clients"][cid]

    async def register_client(self, client_info: OAuthClientInformationFull) -> None:
        if client_info.token_endpoint_auth_method not in CLIENT_AUTH_METHODS:
            raise RegistrationError("invalid_client_metadata", "supported client authentication methods: none, client_secret_post")
        if not client_info.redirect_uris or not all(safe_redirect_uri(uri) for uri in client_info.redirect_uris):
            raise RegistrationError("invalid_redirect_uri", "redirect URIs must use HTTPS or loopback HTTP, without fragments")
        # RFC 7591 §3.2.1: secret 발급 시 필수. SDK의 interval=0은 즉시 만료이므로 사용하지 않는다.
        if client_info.client_secret and client_info.client_secret_expires_at is None:
            client_info.client_secret_expires_at = 0
        record = client_info.model_dump(mode="json", exclude_none=True)
        if len(json.dumps(record)) > self._max_client_bytes:
            raise RegistrationError("invalid_client_metadata", "client metadata too large")
        self._prune_unused_clients()
        if len(self._state["clients"]) >= self._max_clients:
            # CIR: 미승인 DCR이 TTL 동안 모든 슬롯을 선점해 정상 연결을 막지 않도록 한다.
            # 활성 토큰뿐 아니라 진행 중인 승인·코드 교환도 보호한다. 총 저장량 상한은 유지한다.
            active = self._active_client_ids()
            inactive = [cid for cid in self._state["clients"] if cid not in active]
            if not inactive:
                raise RegistrationError("invalid_client_metadata", "client registry is full; try again later")
            oldest = min(inactive, key=lambda cid: self._state["clients"][cid].get("client_id_issued_at") or 0)
            del self._state["clients"][oldest]
        self._state["clients"][str(client_info.client_id)] = record
        self._save()

    def clients(self) -> list[dict[str, Any]]:
        return [
            {"client_id": cid, "client_name": rec.get("client_name"), "redirect_uris": rec.get("redirect_uris")}
            for cid, rec in self._state["clients"].items()
        ]

    # ── 인가 (승인 화면 연동) ────────────────────────────────────────────────
    def accepts_resource(self, resource: str | None) -> bool:
        # RFC 8707: 새 요청의 생략은 이 단일 리소스로 기본값을 준다. 기존 None 토큰은 별도로 거부한다.
        return not resource or canonical_resource(resource) == self._resource_url

    async def authorize(self, client: OAuthClientInformationFull, params: AuthorizationParams) -> str:
        if not safe_redirect_uri(params.redirect_uri) or not self.accepts_resource(params.resource):
            raise AuthorizeError("invalid_request", "invalid redirect URI or unsupported resource")
        params = params.model_copy(update={"resource": self._resource_url})
        self._prune()
        txn = secrets.token_urlsafe(24)
        self._pending[txn] = {"client_id": str(client.client_id), "params": params, "created": self._now()}
        return f"{self._approval_url}/approve?txn={txn}"

    def pending(self, txn: str) -> dict[str, Any] | None:
        self._prune()
        rec = self._pending.get(txn)
        if not rec:
            return None
        client = self._state["clients"].get(rec["client_id"], {})
        params: AuthorizationParams = rec["params"]
        return {
            "client_id": rec["client_id"],
            "client_name": client.get("client_name") or rec["client_id"],
            "redirect_uri": str(params.redirect_uri),
            "scopes": params.scopes or DEFAULT_SCOPES,
        }

    def complete_approval(self, txn: str) -> str:
        """비밀 문구 확인 뒤에만 호출된다. 코드를 발급하고 클라이언트 redirect_uri(+state)를 돌려준다."""
        rec = self._pending.pop(txn)
        params: AuthorizationParams = rec["params"]
        code = secrets.token_urlsafe(32)
        self._codes[code] = AuthorizationCode(
            code=code,
            scopes=params.scopes or DEFAULT_SCOPES,
            expires_at=self._now() + self._code_ttl,
            client_id=rec["client_id"],
            code_challenge=params.code_challenge,
            redirect_uri=params.redirect_uri,
            redirect_uri_provided_explicitly=params.redirect_uri_provided_explicitly,
            resource=params.resource,
        )
        return construct_redirect_uri(str(params.redirect_uri), code=code, state=params.state)

    def deny_approval(self, txn: str) -> str:
        rec = self._pending.pop(txn)
        params: AuthorizationParams = rec["params"]
        return construct_redirect_uri(str(params.redirect_uri), error="access_denied", state=params.state)

    async def load_authorization_code(
        self, client: OAuthClientInformationFull, authorization_code: str
    ) -> AuthorizationCode | None:
        self._prune()
        code = self._codes.get(authorization_code)
        if code is None or code.client_id != str(client.client_id):
            return None
        return code

    # ── 토큰 ──────────────────────────────────────────────────────────────
    def _issue(self, client_id: str, scopes: list[str], resource: str | None, grant: str | None = None) -> OAuthToken:
        now = int(self._now())
        grant = grant or secrets.token_urlsafe(16)  # 승인 1건 = grant 1개, refresh 회전을 거쳐도 유지
        access = secrets.token_urlsafe(32)
        refresh = secrets.token_urlsafe(32)
        self._state["access"][_hash(access)] = {
            "client_id": client_id,
            "scopes": scopes,
            "expires_at": now + self._access_ttl,
            "resource": resource,
            "grant": grant,
        }
        self._state["refresh"][_hash(refresh)] = {
            "client_id": client_id,
            "scopes": scopes,
            "expires_at": now + self._refresh_ttl,
            "resource": resource,
            "grant": grant,
        }
        self._save()
        return OAuthToken(
            access_token=access,
            token_type="Bearer",
            expires_in=self._access_ttl,
            scope=" ".join(scopes),
            refresh_token=refresh,
        )

    async def exchange_authorization_code(
        self, client: OAuthClientInformationFull, authorization_code: AuthorizationCode
    ) -> OAuthToken:
        if authorization_code.resource != self._resource_url:
            raise TokenError("invalid_grant", "authorization code is not bound to this resource")
        self._codes.pop(authorization_code.code, None)  # 코드는 1회용
        return self._issue(str(client.client_id), authorization_code.scopes, authorization_code.resource)

    async def load_refresh_token(self, client: OAuthClientInformationFull, refresh_token: str) -> RefreshToken | None:
        self._prune()
        rec = self._state["refresh"].get(_hash(refresh_token))
        if not rec or rec["client_id"] != str(client.client_id):
            return None
        if rec.get("used"):
            self._revoke_grant(rec["grant"])
            self._save()
            return None
        if rec.get("resource") != self._resource_url:
            return None
        return RefreshToken(token=refresh_token, client_id=rec["client_id"], scopes=rec["scopes"], expires_at=rec["expires_at"])

    async def exchange_refresh_token(
        self, client: OAuthClientInformationFull, refresh_token: RefreshToken, scopes: list[str]
    ) -> OAuthToken:
        # 검증을 먼저 — 거부되는 요청(scope 확장·모르는 토큰)이 유효한 refresh를 소비하면 안 된다
        granted = scopes or refresh_token.scopes
        if any(s not in refresh_token.scopes for s in granted):
            raise TokenError("invalid_scope", "requested scopes exceed the original grant")
        h = _hash(refresh_token.token)
        rec = self._state["refresh"].get(h)
        if not rec or rec["client_id"] != str(client.client_id) or rec.get("resource") != self._resource_url:
            raise TokenError("invalid_grant", "refresh token is not valid")
        grant = rec.get("grant")
        used = sum(r.get("used", False) for r in self._state["refresh"].values() if r.get("grant") == grant)
        if rec.get("used") or not grant or used >= self._max_refresh_rotations:
            if grant:
                self._revoke_grant(grant)
                self._save()
            raise TokenError("invalid_grant", "refresh grant is no longer valid; authorization is required")
        rec["used"] = True  # 옛 해시와 grant를 보존한다. 재사용되면 새 토큰까지 함께 철회한다.
        return self._issue(str(client.client_id), granted, rec.get("resource"), rec.get("grant"))

    async def load_access_token(self, token: str) -> AccessToken | None:
        self._prune()
        rec = self._state["access"].get(_hash(token))
        if not rec or rec.get("resource") != self._resource_url:
            return None
        return AccessToken(
            token=token, client_id=rec["client_id"], scopes=rec["scopes"], expires_at=rec["expires_at"], resource=rec.get("resource")
        )

    def _revoke_grant(self, grant: str) -> None:
        for bucket in ("access", "refresh"):
            for key in [k for k, rec in self._state[bucket].items() if rec.get("grant") == grant]:
                del self._state[bucket][key]

    async def revoke_token(self, token: AccessToken | RefreshToken) -> None:
        """access든 refresh든 하나를 철회하면 같은 grant의 토큰을 전부 지운다 (RFC 7009 §2.1 권고)."""
        h = _hash(token.token)
        removed = self._state["access"].pop(h, None) or self._state["refresh"].pop(h, None)
        if removed is None:
            return
        grant = removed.get("grant")
        if grant:
            self._revoke_grant(grant)
        self._save()
