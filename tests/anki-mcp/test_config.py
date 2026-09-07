import pytest

from anki_mcp.config import Settings

BASE = {
    "ANKI_MCP_PORT": "8790", "ANKI_MCP_APPROVAL_PORT": "8791",
    "ANKI_MCP_PUBLIC_URL": "https://minipc.example.ts.net:8443/", "ANKI_MCP_APPROVAL_URL": "https://minipc.example.ts.net:9443",
    "ANKI_CONNECT_URL": "http://127.0.0.1:8765", "ANKI_HELPER_URL": "http://127.0.0.1:8766",
    "STATE_DIRECTORY": "/tmp/s", "ANKI_SYNC_STATUS_FILE": "/run/anki-host-status/main.json", "ANKI_SYNC_UNIT": "u.service",
    "ANKI_MCP_ACCESS_TTL_SECS": "3600", "ANKI_MCP_REFRESH_TTL_SECS": "2592000", "ANKI_MCP_CODE_TTL_SECS": "300",
    "ANKI_MCP_SYNC_WAIT_SECS": "180", "ANKI_MCP_LOCKOUT_FAILURES": "5", "ANKI_MCP_LOCKOUT_SECS": "300",
    "ANKI_MCP_FIELD_CHARS": "400", "ANKI_MCP_PAGE_MAX": "100",
    "ANKI_MCP_REG_MAX_CLIENTS": "32", "ANKI_MCP_REG_MAX_CLIENT_BYTES": "4096", "ANKI_MCP_REG_UNUSED_TTL_SECS": "86400",
    "ANKI_MCP_REG_BURST": "10", "ANKI_MCP_REG_WINDOW_SECS": "600", "ANKI_MCP_MAX_BODY_BYTES": "262144",
    "ANKI_MCP_BODY_READ_TIMEOUT_SECS": "30", "ANKI_MCP_MAX_CONCURRENCY": "64",
}


def _env(monkeypatch, **override):
    for k, v in {**BASE, **override}.items():
        monkeypatch.setenv(k, v)


def test_from_env_reads_every_value_and_strips_trailing_slash(monkeypatch):
    _env(monkeypatch)
    s = Settings.from_env()
    assert s.public_url == "https://minipc.example.ts.net:8443" and s.reg_max_clients == 32 and s.max_body_bytes == 262144
    assert s.body_read_timeout == 30 and s.max_concurrency == 64


def test_from_env_rejects_plain_http_issuer_and_approval_urls(monkeypatch):
    # OAuth issuer·승인 URL은 코드·토큰이 흐르는 경로 — http://는 시작 시점에 거부한다
    _env(monkeypatch, ANKI_MCP_PUBLIC_URL="http://minipc.example.ts.net")
    with pytest.raises(SystemExit):
        Settings.from_env()
    _env(monkeypatch, ANKI_MCP_APPROVAL_URL="http://minipc.example.ts.net:9443")
    with pytest.raises(SystemExit):
        Settings.from_env()


def test_from_env_fails_closed_on_missing_or_non_integer_values(monkeypatch):
    _env(monkeypatch, ANKI_MCP_REG_BURST="ten")
    with pytest.raises(SystemExit):
        Settings.from_env()
    _env(monkeypatch)
    monkeypatch.delenv("ANKI_MCP_MAX_BODY_BYTES")
    with pytest.raises(SystemExit):
        Settings.from_env()
