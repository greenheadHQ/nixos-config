"""env → Settings. 값은 전부 nixos 모듈(anki-mcp/default.nix)이 constants 단일 소스에서 주입한다 — 기본값 없음."""

from __future__ import annotations

import os
from dataclasses import dataclass


def _req(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit(f"anki_mcp: required environment variable {name} is missing")
    return value


def _https(name: str) -> str:
    value = _req(name).rstrip("/")
    if not value.startswith("https://"):
        raise SystemExit(f"anki_mcp: {name} must be an https:// URL (OAuth issuer/approval URLs carry codes and tokens)")
    return value


def _int(name: str) -> int:
    try:
        return int(_req(name))
    except ValueError as err:
        raise SystemExit(f"anki_mcp: {name} must be an integer") from err


@dataclass(frozen=True)
class Settings:
    port: int  # Cloudflare Tunnel → 이 loopback 포트 (/mcp, 메타데이터, /register, /token, /revoke)
    approval_port: int  # tailnet serve → 이 loopback 포트 (/authorize, /approve)
    public_url: str  # OAuth issuer = 공개 HTTPS URL
    approval_url: str  # 승인 화면 base URL — authorization_endpoint가 여기를 가리킨다
    anki_connect_url: str
    helper_url: str
    state_dir: str  # OAuth 영속 상태 (StateDirectory, 0700)
    sync_status_file: str  # sync 스크립트가 남기는 상태 사본 (결정 15 — /run 게시판)
    sync_unit: str  # "지금 동기화"가 트리거하는 systemd 유닛 (polkit이 start만 허용)
    passphrase_file: str  # LoadCredential 경로 — ANKI_MCP_APPROVAL_PASSPHRASE=... 한 줄
    access_ttl: int
    refresh_ttl: int
    refresh_max_rotations: int
    code_ttl: int
    sync_wait: int
    lockout_failures: int
    lockout_secs: int
    field_chars: int
    page_max: int
    reg_max_clients: int  # DCR 등록 상한 — 인증 없는 /register가 상태 파일을 무한히 키우지 못하게
    reg_max_client_bytes: int  # 클라이언트 레코드 한 건의 JSON 상한
    reg_unused_ttl: int  # 토큰 없는 등록을 정리하기까지의 시간
    reg_burst: int  # 등록 rate limit: 창(reg_window) 안 허용 횟수
    reg_window: int
    max_body_bytes: int  # 공개·승인 앱 요청 본문 상한 (413)
    body_read_timeout: int  # 인증 전 본문 선읽기 기한(초) — 미완결 본문(slowloris) 방어 (408)
    max_concurrency: int  # 공개·승인 앱 각각의 동시 처리 상한 — 인증 전 버퍼의 합산 메모리를 묶는다

    @classmethod
    def from_env(cls) -> "Settings":
        cred_dir = os.environ.get("CREDENTIALS_DIRECTORY", "")
        return cls(
            port=_int("ANKI_MCP_PORT"),
            approval_port=_int("ANKI_MCP_APPROVAL_PORT"),
            public_url=_https("ANKI_MCP_PUBLIC_URL"),
            approval_url=_https("ANKI_MCP_APPROVAL_URL"),
            anki_connect_url=_req("ANKI_CONNECT_URL").rstrip("/"),
            helper_url=_req("ANKI_HELPER_URL").rstrip("/"),
            state_dir=_req("STATE_DIRECTORY"),
            sync_status_file=_req("ANKI_SYNC_STATUS_FILE"),
            sync_unit=_req("ANKI_SYNC_UNIT"),
            passphrase_file=os.path.join(cred_dir, "approval") if cred_dir else "",
            access_ttl=_int("ANKI_MCP_ACCESS_TTL_SECS"),
            refresh_ttl=_int("ANKI_MCP_REFRESH_TTL_SECS"),
            refresh_max_rotations=_int("ANKI_MCP_REFRESH_MAX_ROTATIONS"),
            code_ttl=_int("ANKI_MCP_CODE_TTL_SECS"),
            sync_wait=_int("ANKI_MCP_SYNC_WAIT_SECS"),
            lockout_failures=_int("ANKI_MCP_LOCKOUT_FAILURES"),
            lockout_secs=_int("ANKI_MCP_LOCKOUT_SECS"),
            field_chars=_int("ANKI_MCP_FIELD_CHARS"),
            page_max=_int("ANKI_MCP_PAGE_MAX"),
            reg_max_clients=_int("ANKI_MCP_REG_MAX_CLIENTS"),
            reg_max_client_bytes=_int("ANKI_MCP_REG_MAX_CLIENT_BYTES"),
            reg_unused_ttl=_int("ANKI_MCP_REG_UNUSED_TTL_SECS"),
            reg_burst=_int("ANKI_MCP_REG_BURST"),
            reg_window=_int("ANKI_MCP_REG_WINDOW_SECS"),
            max_body_bytes=_int("ANKI_MCP_MAX_BODY_BYTES"),
            body_read_timeout=_int("ANKI_MCP_BODY_READ_TIMEOUT_SECS"),
            max_concurrency=_int("ANKI_MCP_MAX_CONCURRENCY"),
        )


def read_passphrase(path: str) -> str:
    """ANKI_MCP_APPROVAL_PASSPHRASE=<값> 형식(다른 agenix 시크릿과 같은 shell 변수 형식). 없거나 비면 빈 문자열 —
    승인 화면은 빈 문구를 절대 통과시키지 않는다(fail-closed)."""
    if not path or not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8") as stream:
        for raw in stream:
            line = raw.strip()
            if line.startswith("ANKI_MCP_APPROVAL_PASSPHRASE="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    return ""
