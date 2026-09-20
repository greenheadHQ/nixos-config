"""Root enrollment CLI routes narrowly without exposing local credentials."""

import importlib.util
import io
import json
import os
from pathlib import Path
from types import SimpleNamespace

import pytest


@pytest.fixture
def host():
    path = Path(__file__).resolve().parents[2] / "modules/nixos/programs/anki-host/files/managed-host.py"
    spec = importlib.util.spec_from_file_location("managed_host_fixture", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def environment(host, monkeypatch, tmp_path):
    monkeypatch.setenv("INSTANCE", "test")
    monkeypatch.setenv("HELPER_PORT", "19001")
    monkeypatch.setenv("HELPER_CURL_MAX_TIME", "120")
    monkeypatch.setenv("LOCAL_CREDENTIAL_ROOT", str(tmp_path))
    monkeypatch.setattr(host.os, "geteuid", lambda: 0)


@pytest.mark.parametrize("argv,path,payload,role", [
    (["inspect"], "/managed/check", {}, "read"),
    (["enrollment-preview"], "/managed/enrollment/prepare", {}, "schema"),
    (["register", "a" * 32, "--preview-token", "b" * 64, "--confirm"], "/managed/enrollment/apply",
     {"operation_id": "a" * 32, "preview_token": "b" * 64, "confirm": True}, "schema"),
    (["retry-notification", "c" * 32], "/managed/notification/retry", {"incident_id": "c" * 32}, "schema"),
    (["diagnose-restore", "restore001"], "/managed/restore/diagnose", {"request_id": "restore001"}, "schema"),
])
def test_exact_root_command_routes(host, monkeypatch, tmp_path, capsys, argv, path, payload, role):
    environment(host, monkeypatch, tmp_path)
    reads, calls = [], []
    monkeypatch.setattr(host, "read_credential", lambda value: reads.append(value) or "d" * 64)

    def call(actual_path, actual_payload, **kwargs):
        calls.append((actual_path, actual_payload, kwargs))
        return {"status": "fixture-result"}

    monkeypatch.setattr(host, "helper", call)
    host.main(argv)
    assert reads == [tmp_path / "test" / role]
    assert calls == [(path, payload, {"key": "d" * 64, "port": 19001, "timeout": 120})]
    output = capsys.readouterr()
    assert json.loads(output.out) == {"status": "fixture-result"}
    assert "d" * 64 not in output.out + output.err


@pytest.mark.parametrize("argv", [
    ["inspect"], ["enrollment-preview"],
    ["register", "a" * 32, "--preview-token", "b" * 64, "--confirm"],
    ["retry-notification", "a" * 32], ["diagnose-restore", "restore001"],
])
def test_non_root_never_reads_credentials_or_sends_request(host, monkeypatch, argv):
    monkeypatch.setattr(host.os, "geteuid", lambda: 1000)
    monkeypatch.setattr(host, "read_credential", lambda _path: pytest.fail("credential read as non-root"))
    monkeypatch.setattr(host, "helper", lambda *_a, **_kw: pytest.fail("non-root request"))
    with pytest.raises(SystemExit) as result:
        host.main(argv)
    assert result.value.code == 2


@pytest.mark.parametrize("argv", [
    ["register", "a" * 32, "--preview-token", "b" * 64],
    ["register", "a" * 32, "--confirm"],
    ["register", "a" * 32, "--preview-token", "b" * 64, "--conf"],
    ["register", "../escape", "--preview-token", "b" * 64, "--confirm"],
    ["register", "a" * 32, "--preview-token", "bad", "--confirm"],
    ["register", "a" * 32, "--preview-token", "b" * 64, "--confirm", "--digest", "c" * 64],
    ["register", "a" * 32, "--preview-token", "b" * 64, "--confirm", "--payload", "{}"],
    ["full-upload"], ["inspect", "--url", "https://example.invalid"],
    ["enrollment-preview", "--model", "Other"], ["retry-notification", "../escape"],
    ["diagnose-restore", "short"], ["diagnose-restore", "restore001", "--confirm"],
])
def test_unknown_or_incomplete_commands_fail_before_credentials(host, monkeypatch, argv):
    monkeypatch.setattr(host, "read_credential", lambda _path: pytest.fail("unexpected credential read"))
    with pytest.raises(SystemExit) as result:
        host.main(argv)
    assert result.value.code == 2


@pytest.mark.parametrize("name,value", [("INSTANCE", "../escape"), ("HELPER_PORT", "0"),
                                        ("HELPER_PORT", "65536"), ("HELPER_CURL_MAX_TIME", "0")])
def test_invalid_wrapper_boundary_is_rejected(host, monkeypatch, tmp_path, name, value):
    environment(host, monkeypatch, tmp_path)
    monkeypatch.setenv(name, value)
    monkeypatch.setattr(host, "read_credential", lambda _path: pytest.fail("unexpected credential read"))
    with pytest.raises(ValueError):
        host.main(["inspect"])


def root_owned(monkeypatch, host):
    original = os.fstat

    def root_metadata(fd):
        result = original(fd)
        return SimpleNamespace(st_mode=result.st_mode, st_uid=0, st_size=result.st_size)

    monkeypatch.setattr(host.os, "fstat", root_metadata)


def test_credential_read_accepts_only_private_root_owned_regular_file(host, monkeypatch, tmp_path):
    secret = tmp_path / "schema"
    secret.write_text("a" * 64 + "\n")
    secret.chmod(0o600)
    root_owned(monkeypatch, host)
    assert host.read_credential(secret) == "a" * 64
    secret.chmod(0o640)
    with pytest.raises(ValueError, match="credential-file"):
        host.read_credential(secret)


@pytest.mark.parametrize("value", ["a" * 63, "a" * 66, "z" * 64, "a" * 64 + "\nextra"])
def test_invalid_credential_contents_are_rejected(host, monkeypatch, tmp_path, value):
    secret = tmp_path / "schema"
    secret.write_text(value)
    secret.chmod(0o600)
    root_owned(monkeypatch, host)
    with pytest.raises(ValueError, match="credential"):
        host.read_credential(secret)


def test_foreign_owned_credential_is_rejected(host, monkeypatch, tmp_path):
    secret = tmp_path / "schema"
    secret.write_text("a" * 64)
    secret.chmod(0o600)
    monkeypatch.setattr(host.os, "fstat", lambda _fd: SimpleNamespace(st_mode=0o100600, st_uid=1000, st_size=64))
    with pytest.raises(ValueError, match="credential-file"):
        host.read_credential(secret)


def test_symlink_and_directory_credentials_are_rejected(host, monkeypatch, tmp_path):
    secret = tmp_path / "schema"
    secret.symlink_to(tmp_path / "target")
    (tmp_path / "target").write_text("a" * 64)
    root_owned(monkeypatch, host)
    with pytest.raises(OSError):
        host.read_credential(secret)
    with pytest.raises(ValueError, match="credential-file"):
        host.read_credential(tmp_path)


def test_http_request_ignores_proxy_and_cannot_forward_credentials_on_redirect(host, monkeypatch):
    handlers_seen, requests = [], []

    def opener(*handlers):
        handlers_seen.extend(handlers)

        def request(value, timeout):
            requests.append((value, timeout))
            return io.BytesIO(b'{"ok":true,"result":{"status":"normal"}}')

        return SimpleNamespace(open=request)

    monkeypatch.setenv("http_proxy", "http://unexpected.invalid")
    monkeypatch.setattr(host.urllib.request, "build_opener", opener)
    result = host.helper("/managed/check", {}, key="a" * 64, port=19001, timeout=120)
    assert result == {"status": "normal"}
    assert handlers_seen[0].proxies == {}
    assert handlers_seen[1].redirect_request(None, None, None, None, None, None) is None
    request, timeout = requests[0]
    assert request.full_url == "http://127.0.0.1:19001/managed/check" and timeout == 120
    assert request.method == "POST" and request.get_header("Authorization") == "Bearer " + "a" * 64
    assert json.loads(request.data) == {}


@pytest.mark.parametrize("response", [{"ok": False, "error": "private error"},
                                    {"ok": True}, {"ok": True, "result": []}, []])
def test_malformed_helper_results_are_not_success(host, monkeypatch, response):
    monkeypatch.setattr(host.urllib.request, "build_opener", lambda *_handlers:
        SimpleNamespace(open=lambda *_args, **_kwargs: io.BytesIO(json.dumps(response).encode())))
    with pytest.raises(ValueError, match="helper-request-failed"):
        host.helper("/managed/check", {}, key="a" * 64, port=19001, timeout=1)
