"""내장 OAuth 2.1 인가 서버 provider — mcp SDK의 OAuthAuthorizationServerProvider 프로토콜 구현 (결정 6, U1).

- 클라이언트: DCR(/register)로 등록되며 파일에 영속한다(ChatGPT·Codex·Claude가 각자 등록).
- 인가: /authorize(승인 포트)에서 SDK 핸들러가 PKCE·redirect_uri를 검증한 뒤 authorize()를 부른다. 여기서는
  대기 트랜잭션을 만들고 승인 화면(/approve?txn=)으로 보낸다. 승인 화면이 비밀 문구를 확인하면
  complete_approval()이 코드를 발급해 클라이언트 redirect_uri로 돌려보낸다.
- 토큰: 불투명 랜덤 토큰. 파일에는 sha256 해시만 저장한다(파일이 새도 토큰을 복원할 수 없다).
  access 만료 후 refresh로 갱신(회전), /revoke로 철회. 매 요청 검증은 SDK 미들웨어가 load_access_token으로 한다.
  한 승인에서 나온 access·refresh(회전 뒤 것까지)는 같은 grant id를 갖고, 어느 하나를 철회하면 grant 전체가 죽는다
  (refresh만 철회했는데 access가 살아 있는 구멍 방지).
- 등록 상한: /register는 인증 없이 인터넷에 열려 있다. 클라이언트 수·레코드 크기에 상한을 두고, 토큰이 하나도
  없는 오래된 등록은 새 등록이 들어올 때 정리한다(정상 클라이언트는 토큰이 살아 있는 한 정리되지 않는다).
"""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import time
from typing import Any, Callable

from mcp.server.auth.provider import (
    AccessToken,
    AuthorizationCode,
    AuthorizationParams,
    RefreshToken,
    RegistrationError,
    TokenError,
    construct_redirect_uri,
)
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken

DEFAULT_SCOPES = ["anki"]
CLIENT_AUTH_METHODS = ("none", "client_secret_post")


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
            expired = [h for h, rec in self._state[bucket].items() if rec.get("expires_at") and rec["expires_at"] < now]
            for h in expired:
                del self._state[bucket][h]
        for code, rec in list(self._codes.items()):
            if rec.expires_at < now:
                del self._codes[code]
        for txn, rec in list(self._pending.items()):
            if rec["created"] + self._code_ttl < now:
                del self._pending[txn]

    # ── 클라이언트 ─────────────────────────────────────────────────────────
    async def get_client(self, client_id: str) -> OAuthClientInformationFull | None:
        raw = self._state["clients"].get(client_id)
        return OAuthClientInformationFull.model_validate(raw) if raw else None

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
        record = client_info.model_dump(mode="json", exclude_none=True)
        if len(json.dumps(record)) > self._max_client_bytes:
            raise RegistrationError("invalid_client_metadata", "client metadata too large")
        self._prune_unused_clients()
        if len(self._state["clients"]) >= self._max_clients:
            raise RegistrationError("invalid_client_metadata", "client registry is full; try again later")
        self._state["clients"][str(client_info.client_id)] = record
        self._save()

    def clients(self) -> list[dict[str, Any]]:
        return [
            {"client_id": cid, "client_name": rec.get("client_name"), "redirect_uris": rec.get("redirect_uris")}
            for cid, rec in self._state["clients"].items()
        ]

    # ── 인가 (승인 화면 연동) ────────────────────────────────────────────────
    async def authorize(self, client: OAuthClientInformationFull, params: AuthorizationParams) -> str:
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
        self._codes.pop(authorization_code.code, None)  # 코드는 1회용
        return self._issue(str(client.client_id), authorization_code.scopes, authorization_code.resource)

    async def load_refresh_token(self, client: OAuthClientInformationFull, refresh_token: str) -> RefreshToken | None:
        self._prune()
        rec = self._state["refresh"].get(_hash(refresh_token))
        if not rec or rec["client_id"] != str(client.client_id):
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
        if not rec or rec["client_id"] != str(client.client_id):
            raise TokenError("invalid_grant", "refresh token is not valid")
        del self._state["refresh"][h]  # 회전: 옛 refresh는 즉시 무효 (_issue가 저장한다)
        return self._issue(str(client.client_id), granted, rec.get("resource"), rec.get("grant"))

    async def load_access_token(self, token: str) -> AccessToken | None:
        self._prune()
        rec = self._state["access"].get(_hash(token))
        if not rec:
            return None
        return AccessToken(
            token=token, client_id=rec["client_id"], scopes=rec["scopes"], expires_at=rec["expires_at"], resource=rec.get("resource")
        )

    async def revoke_token(self, token: AccessToken | RefreshToken) -> None:
        """access든 refresh든 하나를 철회하면 같은 grant의 토큰을 전부 지운다 (RFC 7009 §2.1 권고)."""
        h = _hash(token.token)
        removed = self._state["access"].pop(h, None) or self._state["refresh"].pop(h, None)
        if removed is None:
            return
        grant = removed.get("grant")
        if grant:
            for bucket in ("access", "refresh"):
                for key in [k for k, rec in self._state[bucket].items() if rec.get("grant") == grant]:
                    del self._state[bucket][key]
        self._save()
