"""Root enrollment CLI routes narrowly without exposing local credentials."""

import importlib.util
import hashlib
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
    monkeypatch.setenv("STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setattr(host.os, "geteuid", lambda: 0)
    monkeypatch.setattr(host.time, "time", lambda: 1000)


@pytest.mark.parametrize("argv,path,payload,role", [
    (["inspect"], "/managed/check", {}, "read"),
    (["enrollment-preview"], "/managed/enrollment/prepare", {}, "schema"),
    (["register", "a" * 32, "--preview-token", "b" * 64, "--confirm"], "/managed/enrollment/apply",
     {"operation_id": "a" * 32, "preview_token": "b" * 64, "confirm": True}, "schema"),
    (["retry-notification", "c" * 32], "/managed/notification/retry", {"incident_id": "c" * 32}, "schema"),
    (["diagnose-restore", "restore001"], "/managed/restore/diagnose", {"request_id": "restore001"}, "schema"),
    (["update-status", "a" * 32], "/managed/update/status", {"operation_id": "a" * 32}, "schema"),
    (["diagnose-update", "a" * 32], "/managed/update/diagnose", {"operation_id": "a" * 32}, "schema"),
])
def test_exact_root_command_routes(host, monkeypatch, tmp_path, capsys, argv, path, payload, role):
    environment(host, monkeypatch, tmp_path)
    reads, calls = [], []
    monkeypatch.setattr(host, "read_credential", lambda value: reads.append(value) or "d" * 64)

    def call(actual_path, actual_payload, **kwargs):
        calls.append((actual_path, actual_payload, kwargs))
        return receipt() if actual_path.startswith("/managed/update/") else {"status": "fixture-result"}

    monkeypatch.setattr(host, "helper", call)
    host.main(argv)
    assert reads == [tmp_path / "test" / role]
    assert calls == [(path, payload, {"key": "d" * 64, "port": 19001, "timeout": 120})]
    output = capsys.readouterr()
    assert json.loads(output.out) == (receipt() if path.startswith("/managed/update/") else {"status": "fixture-result"})
    assert "d" * 64 not in output.out + output.err


@pytest.mark.parametrize("argv", [
    ["inspect"], ["enrollment-preview"],
    ["register", "a" * 32, "--preview-token", "b" * 64, "--confirm"],
    ["retry-notification", "a" * 32], ["diagnose-restore", "restore001"],
    ["update-preview", "--devices-ready"],
    ["update", "a" * 32, "--preview-token", "b" * 64, "--confirm"],
    ["update-status", "a" * 32], ["diagnose-update", "a" * 32],
    ["difficulty-preview", "--devices-ready", "--request-id", "mobile001"],
    ["difficulty-apply", "a" * 32, "--preview-token", "b" * 64, "--confirm"],
    ["difficulty-status", "a" * 32],
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
    ["update-preview"], ["update-preview", "--devices-rea"],
    ["update-preview", "--devices-ready", "--operation-id", "a" * 32],
    ["update-preview", "--devices-ready", "--url", "https://example.invalid"],
    ["update", "a" * 32, "--confirm"],
    ["update", "a" * 32, "--preview-token", "b" * 64],
    ["update", "a" * 32, "--preview-token", "b" * 64, "--confirm", "--full-upload"],
    ["update", "a" * 32, "--preview-token", "b" * 64, "--confirm", "--digest", "c" * 64],
    ["update", "a" * 32, "--preview-token", "b" * 64, "--confirm", "--source", "/tmp/model.json"],
    ["update-status", "../escape"], ["diagnose-update", "a" * 32, "--confirm"],
    ["difficulty-preview"], ["difficulty-preview", "--devices-ready"],
    ["difficulty-preview", "--request-id", "mobile001"],
    ["difficulty-preview", "--devices-rea", "--request-id", "mobile001"],
    ["difficulty-preview", "--devices-ready", "--request-id", "short"],
    ["difficulty-preview", "--devices-ready", "--request-id", "mobile001", "--enabled", "--disabled"],
    ["difficulty-preview", "--devices-ready", "--request-id", "mobile001", "--code", "arbitrary"],
    ["difficulty-preview", "--devices-ready", "--request-id", "mobile001", "--settings", "{}"],
    ["difficulty-preview", "--devices-ready", "--request-id", "mobile001", "--url", "http://elsewhere"],
    ["difficulty-apply", "a" * 32, "--confirm"],
    ["difficulty-apply", "a" * 32, "--preview-token", "b" * 64],
    ["difficulty-apply", "a" * 32, "--preview-token", "b" * 64, "--conf"],
    ["difficulty-apply", "../escape", "--preview-token", "b" * 64, "--confirm"],
    ["difficulty-apply", "a" * 32, "--preview-token", "invalid", "--confirm"],
    ["difficulty-apply", "a" * 32, "--preview-token", "b" * 64, "--confirm", "--payload", "{}"],
    ["difficulty-status", "../escape"], ["difficulty-status", "a" * 32, "--confirm"],
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


def receipt(state="prepared", registered=False, sync="pending"):
    return {"operation_id": "a" * 32, "state": state, "registered": registered, "sync": {"state": sync}}


def sync_status(tmp_path, **changes):
    state = tmp_path / "state"
    state.mkdir(exist_ok=True)
    value = {"runId": "new", "runStartedAt": "1970-01-01T00:16:41.123456789+00:00",
             "result": "success", "mode": "normal", "sync": {"action": "normal"}}
    value.update(changes)
    (state / "sync-status.json").write_text(json.dumps(value))


def test_update_preview_syncs_before_prepare_and_prints_recovery_id(host, monkeypatch, tmp_path, capsys):
    environment(host, monkeypatch, tmp_path)
    sync_status(tmp_path, runId="old")
    events = []
    monkeypatch.setattr(host, "read_credential", lambda path: "d" * 64)
    monkeypatch.setattr(host.secrets, "token_hex", lambda size: "a" * 32 if size == 16 else pytest.fail("wrong id size"))

    def start(argv, **kwargs):
        assert argv == ["systemctl", "start", "anki-host-sync-test.service"]
        assert kwargs == {"check": True, "capture_output": True}
        events.append("sync")
        sync_status(tmp_path)

    expected = receipt() | {"preview_token": "b" * 64, "summary": {"changed_items": ["css"]},
                            "backup": {"sha256": "e" * 64, "mirrored": True},
                            "verification": {"state": "verified"}, "expires_at": 1600}

    def call(path, payload, **kwargs):
        assert events == ["sync"]
        assert path == "/managed/update/prepare"
        assert payload == {"operation_id": "a" * 32, "devices_ready": True}
        assert kwargs == {"key": "d" * 64, "port": 19001, "timeout": 120}
        output = capsys.readouterr()
        assert output.out == "" and output.err == "operation_id: " + "a" * 32 + "\n"
        events.append("prepare")
        return expected

    monkeypatch.setattr(host.subprocess, "run", start)
    monkeypatch.setattr(host, "helper", call)
    host.main(["update-preview", "--devices-ready"])
    assert json.loads(capsys.readouterr().out) == expected
    assert events == ["sync", "prepare"]


@pytest.mark.parametrize("changes", [{"runId": "old"}, {"runId": ""}, {"result": "error"},
    {"mode": "approved-schema"}, {"sync": {"action": "full-download"}},
    {"sync": {"action": "full-sync-required"}}, {"result": "busy-deferred"}, {"sync": []},
    {"runStartedAt": "1970-01-01T00:16:39+00:00"}, {"runStartedAt": "1970-01-01T00:16:41"},
    {"runStartedAt": None}, {"runId": 123}])
def test_preview_refuses_stale_failed_or_non_normal_sync(host, monkeypatch, tmp_path, changes):
    environment(host, monkeypatch, tmp_path)
    sync_status(tmp_path, runId="old")
    monkeypatch.setattr(host, "read_credential", lambda path: "d" * 64)
    monkeypatch.setattr(host.subprocess, "run", lambda *_a, **_kw: sync_status(tmp_path, **changes))
    monkeypatch.setattr(host, "helper", lambda *_a, **_kw: pytest.fail("prepare before fresh normal sync"))
    with pytest.raises(host.CommandError, match="fresh-normal-sync-required"):
        host.main(["update-preview", "--devices-ready"])


def test_lost_preview_response_leaves_operation_id_without_retry(host, monkeypatch, tmp_path, capsys):
    environment(host, monkeypatch, tmp_path)
    calls = []
    monkeypatch.setattr(host, "read_credential", lambda path: "d" * 64)
    monkeypatch.setattr(host, "normal_sync", lambda *_a: None)
    monkeypatch.setattr(host.secrets, "token_hex", lambda _size: "a" * 32)

    def lose(path, payload, **kwargs):
        calls.append(path)
        raise host.urllib.error.URLError("private response text")

    monkeypatch.setattr(host, "helper", lose)
    with pytest.raises(host.urllib.error.URLError):
        host.main(["update-preview", "--devices-ready"])
    assert calls == ["/managed/update/prepare"]
    output = capsys.readouterr()
    assert output.out == "" and output.err == "operation_id: " + "a" * 32 + "\n"


@pytest.mark.parametrize("state,registered", [("prepared", False), ("partial", False), ("unknown", False),
    ("expired", False), ("not-applied", False), ("applied", False)])
def test_update_without_verified_registration_never_syncs(host, monkeypatch, tmp_path, capsys, state, registered):
    environment(host, monkeypatch, tmp_path)
    monkeypatch.setattr(host, "read_credential", lambda path: "d" * 64)
    monkeypatch.setattr(host.subprocess, "run", lambda *_a, **_kw: pytest.fail("unverified update synced"))
    calls = []
    result = receipt(state, registered)

    def call(path, payload, **kwargs):
        calls.append(path)
        assert path == "/managed/update/apply"
        assert payload == {"operation_id": "a" * 32, "preview_token": "b" * 64, "confirm": True}
        return result

    monkeypatch.setattr(host, "helper", call)
    with pytest.raises(SystemExit) as error:
        host.main(["update", "a" * 32, "--preview-token", "b" * 64, "--confirm"])
    assert error.value.code == 1
    assert calls == ["/managed/update/apply"]
    assert json.loads(capsys.readouterr().out) == result


@pytest.mark.parametrize("failure,delivery", [(None, "synced"), (None, "pending"),
    ("process", "blocked"), ("timeout", "pending"), ("stale", "pending"), (None, "lost")])
def test_applied_update_checks_delivery_even_when_sync_fails(host, monkeypatch, tmp_path, capsys, failure, delivery):
    environment(host, monkeypatch, tmp_path)
    sync_status(tmp_path, runId="old")
    monkeypatch.setattr(host, "read_credential", lambda path: "d" * 64)
    events = []
    applied = receipt("applied", True)

    def start(argv, **kwargs):
        assert argv == ["systemctl", "start", "anki-host-sync-test.service"]
        assert kwargs == {"check": True, "capture_output": True}
        events.append("normal-sync")
        if failure == "process":
            raise host.subprocess.CalledProcessError(1, argv, output=b"private body")
        if failure == "timeout":
            raise host.subprocess.TimeoutExpired(argv, 1, output=b"private body")
        sync_status(tmp_path, runId="old" if failure == "stale" else "new")

    def call(path, payload, **kwargs):
        events.append(path)
        if path == "/managed/update/apply":
            return applied.copy()
        assert path == "/managed/update/delivery" and payload == {"operation_id": "a" * 32}
        if delivery == "lost":
            raise host.urllib.error.URLError("private response text")
        return receipt("applied", True, delivery)

    monkeypatch.setattr(host.subprocess, "run", start)
    monkeypatch.setattr(host, "helper", call)
    argv = ["update", "a" * 32, "--preview-token", "b" * 64, "--confirm"]
    if delivery == "synced":
        host.main(argv)
    else:
        with pytest.raises(SystemExit) as error:
            host.main(argv)
        assert error.value.code == 1
    assert events == ["/managed/update/apply", "normal-sync", "/managed/update/delivery"]
    output = capsys.readouterr()
    assert json.loads(output.out) == (applied if delivery == "lost" else receipt("applied", True, delivery))
    assert "private" not in output.out + output.err and "d" * 64 not in output.out + output.err


@pytest.mark.parametrize("error_code,expected", [("busy", "busy"),
    ("managed-enrollment-model-missing", "managed-enrollment-model-missing"),
    ("managed-enrollment-source-does-not-match-runtime", "managed-enrollment-source-does-not-match-runtime"),
    ("managed-enrollment-verification-failed", "managed-enrollment-verification-failed"),
    ("managed-enrollment-state-changed", "managed-enrollment-state-changed"),
    ("managed-enrollment-confirmation-expired-or-invalid", "managed-enrollment-confirmation-expired-or-invalid"),
    ("managed-enrollment-preview-stale", "managed-enrollment-preview-stale"),
    ("managed-enrollment-source-changed", "managed-enrollment-source-changed"),
    ("managed-enrollment-preview-stale: private note", "helper-request-failed"),
    ("managed-enrollment-unknown-future-code", "helper-request-failed"),
    ("managed-update-stale-preview-reprepare", "managed-update-stale-preview-reprepare"),
    ("managed-update-stale-preview-reprepare: private note", "helper-request-failed"),
    ("difficulty-mobile-devices-must-be-ready", "difficulty-mobile-devices-must-be-ready"),
    ("difficulty-mobile-reviewer-must-be-closed", "difficulty-mobile-reviewer-must-be-closed"),
    ("difficulty-mobile-devices-must-be-ready: private note", "helper-request-failed"),
    ("request-id-payload-mismatch", "request-id-payload-mismatch"),
    ("stale-preview-create-a-new-request-id", "stale-preview-create-a-new-request-id"),
    ("restore-point-not-mirrored", "restore-point-not-mirrored"),
    ("private note contents", "helper-request-failed"),
    ("busy\nsecret", "helper-request-failed"), (["busy"], "helper-request-failed")])
def test_http_errors_expose_only_exact_public_codes(host, monkeypatch, error_code, expected):
    def request(*_a, **_kw):
        body = io.BytesIO(json.dumps({"ok": False, "error": error_code, "private": "a" * 64}).encode())
        raise host.urllib.error.HTTPError("http://127.0.0.1:19001", 400, "private reason", {}, body)
    monkeypatch.setattr(host.urllib.request, "build_opener", lambda *_handlers: SimpleNamespace(open=request))
    with pytest.raises(host.CommandError) as error:
        host.helper("/managed/update/status", {"operation_id": "b" * 32}, key="a" * 64, port=19001, timeout=1)
    assert str(error.value) == expected


@pytest.mark.parametrize("change", [{"operation_id": "c" * 32}, {"state": "applying"},
    {"registered": "true"}, {"sync": []}, {"sync": {"state": "unknown"}}])
def test_update_result_requires_matching_operation_and_known_states(host, change):
    with pytest.raises(host.CommandError, match="helper-request-failed"):
        host.update_result(receipt() | change, "a" * 32)


def test_update_result_filters_error_details_in_successful_transport(host):
    value = receipt("unknown") | {"error": "private note body"}
    value["sync"]["error"] = "managed-update-delivery-unconfirmed"
    result = host.update_result(value, "a" * 32)
    assert result["error"] == "helper-request-failed"
    assert result["sync"]["error"] == "managed-update-delivery-unconfirmed"
    assert value["error"] == "private note body"


def difficulty_receipt(state="prepared", operation_id="a" * 32, request_id="mobile001", **changes):
    return {"operation_id": operation_id, "request_id": request_id,
            "action": "configure_difficulty_mobile", "state": state,
            "confirmation_required": True, "backup_required": True, "schema_required": False,
            "sync": {"state": "disabled"}, "notification": {"state": "disabled"}, **changes}


@pytest.mark.parametrize("flags,enabled", [([], True), (["--enabled"], True), (["--disabled"], False)])
def test_difficulty_preview_presyncs_and_keeps_recoverable_request(host, monkeypatch, tmp_path, capsys, flags, enabled):
    environment(host, monkeypatch, tmp_path)
    sync_status(tmp_path, runId="old")
    events, reads = [], []
    operation_id = hashlib.sha256(b"mobile001").hexdigest()[:32]
    expected = difficulty_receipt(operation_id=operation_id, preview_token="b" * 64)
    monkeypatch.setattr(host, "read_credential", lambda value: reads.append(value) or "d" * 64)

    def start(argv, **kwargs):
        assert argv == ["systemctl", "start", "anki-host-sync-test.service"]
        assert kwargs == {"check": True, "capture_output": True}
        recovery = capsys.readouterr()
        assert "operation_id: " + operation_id in recovery.err
        assert "same request ID and flags" in recovery.err
        events.append("sync")
        sync_status(tmp_path)

    def call(path, payload, **kwargs):
        assert events == ["sync"]
        assert path == "/difficulty/mobile/prepare"
        assert payload == {"enabled": enabled, "devices_ready": True, "request_id": "mobile001"}
        assert kwargs == {"key": "d" * 64, "port": 19001, "timeout": 120}
        events.append("prepare")
        return expected

    monkeypatch.setattr(host.subprocess, "run", start)
    monkeypatch.setattr(host, "helper", call)
    host.main(["difficulty-preview", "--devices-ready", "--request-id", "mobile001", *flags])
    assert reads == [tmp_path / "test" / "schema"]
    result = json.loads(capsys.readouterr().out)
    assert result == expected | {"mobile_delivery": {"state": "not-checked", "device_sync_required": True}}
    assert events == ["sync", "prepare"]


def test_difficulty_preview_failure_never_prepares_without_fresh_normal_sync(host, monkeypatch, tmp_path, capsys):
    environment(host, monkeypatch, tmp_path)
    sync_status(tmp_path, runId="old")
    monkeypatch.setattr(host, "read_credential", lambda _path: "d" * 64)
    monkeypatch.setattr(host.subprocess, "run", lambda *_a, **_kw: None)
    monkeypatch.setattr(host, "helper", lambda *_a, **_kw: pytest.fail("prepare before fresh normal sync"))
    with pytest.raises(host.CommandError, match="fresh-normal-sync-required"):
        host.main(["difficulty-preview", "--devices-ready", "--request-id", "mobile001"])
    assert "same request ID and flags" in capsys.readouterr().err


def test_lost_difficulty_preview_is_not_automatically_retried(host, monkeypatch, tmp_path, capsys):
    environment(host, monkeypatch, tmp_path)
    calls = []
    monkeypatch.setattr(host, "read_credential", lambda _path: "d" * 64)
    monkeypatch.setattr(host, "normal_sync", lambda *_a: {})

    def lose(path, payload, **kwargs):
        calls.append((path, payload))
        raise host.urllib.error.URLError("private response text")

    monkeypatch.setattr(host, "helper", lose)
    with pytest.raises(host.urllib.error.URLError):
        host.main(["difficulty-preview", "--devices-ready", "--request-id", "mobile001"])
    assert calls == [("/difficulty/mobile/prepare", {"enabled": True, "devices_ready": True, "request_id": "mobile001"})]
    output = capsys.readouterr()
    assert output.out == "" and "private" not in output.err
    assert hashlib.sha256(b"mobile001").hexdigest()[:32] in output.err


def test_difficulty_status_uses_schema_key_without_sync_or_delivery_claim(host, monkeypatch, tmp_path, capsys):
    environment(host, monkeypatch, tmp_path)
    monkeypatch.delenv("STATE_DIR")
    reads, calls = [], []
    monkeypatch.setattr(host, "read_credential", lambda path: reads.append(path) or "d" * 64)
    monkeypatch.setattr(host, "normal_sync", lambda *_a: pytest.fail("status started sync"))

    def call(path, payload, **kwargs):
        calls.append((path, payload, kwargs))
        return difficulty_receipt("applied")

    monkeypatch.setattr(host, "helper", call)
    host.main(["difficulty-status", "a" * 32])
    assert reads == [tmp_path / "test" / "schema"]
    assert calls == [("/operations/status", {"operation_id": "a" * 32},
                      {"key": "d" * 64, "port": 19001, "timeout": 120})]
    assert json.loads(capsys.readouterr().out) == difficulty_receipt("applied") | {
        "mobile_delivery": {"state": "not-checked", "device_sync_required": True}}


@pytest.mark.parametrize("failure", [None, "process", "timeout", "stale", "not-normal"])
def test_difficulty_apply_only_claims_verified_host_normal_sync(host, monkeypatch, tmp_path, capsys, failure):
    environment(host, monkeypatch, tmp_path)
    sync_status(tmp_path, runId="old")
    monkeypatch.setattr(host, "read_credential", lambda _path: "d" * 64)
    events = []
    receipt = difficulty_receipt("applied")

    def call(path, payload, **kwargs):
        events.append(path)
        assert path == "/difficulty/mobile/apply"
        assert payload == {"operation_id": "a" * 32, "preview_token": "b" * 64, "confirm": True}
        return receipt

    def start(argv, **kwargs):
        assert argv == ["systemctl", "start", "anki-host-sync-test.service"]
        events.append("normal-sync")
        if failure == "process":
            raise host.subprocess.CalledProcessError(1, argv, output=b"private process body")
        if failure == "timeout":
            raise host.subprocess.TimeoutExpired(argv, 1, output=b"private process body")
        sync_status(tmp_path, runId="old" if failure == "stale" else "new",
                    sync={"action": "full-upload" if failure == "not-normal" else "normal"})

    monkeypatch.setattr(host, "helper", call)
    monkeypatch.setattr(host.subprocess, "run", start)
    argv = ["difficulty-apply", "a" * 32, "--preview-token", "b" * 64, "--confirm"]
    if failure is None:
        host.main(argv)
    else:
        with pytest.raises(SystemExit) as error:
            host.main(argv)
        assert error.value.code == 1
    output = capsys.readouterr()
    result = json.loads(output.out)
    assert result["sync"] == {"state": "disabled"}
    assert result["mobile_delivery"]["device_sync_required"] is True
    if failure is None:
        assert result["mobile_delivery"] == {
            "state": "host-normal-sync-completed", "device_sync_required": True,
            "run_id": "new", "run_started_at": "1970-01-01T00:16:41.123456789+00:00",
            "result": "success", "action": "normal"}
    else:
        assert result["mobile_delivery"]["state"] == "unconfirmed"
        assert "difficulty-status " + "a" * 32 in output.err
    assert "private" not in output.out + output.err and "d" * 64 not in output.out + output.err
    assert events == ["/difficulty/mobile/apply", "normal-sync"]
    assert "mobile_delivery" not in receipt  # CLI observations do not mutate the operation journal.


@pytest.mark.parametrize("state", ["prepared", "partial", "unknown", "expired"])
def test_difficulty_unconfirmed_apply_never_syncs_and_directs_status(host, monkeypatch, tmp_path, capsys, state):
    environment(host, monkeypatch, tmp_path)
    monkeypatch.setattr(host, "read_credential", lambda _path: "d" * 64)
    monkeypatch.setattr(host, "normal_sync", lambda *_a: pytest.fail("unconfirmed operation synced"))
    monkeypatch.setattr(host, "helper", lambda *_a, **_kw: difficulty_receipt(state))
    with pytest.raises(SystemExit) as error:
        host.main(["difficulty-apply", "a" * 32, "--preview-token", "b" * 64, "--confirm"])
    assert error.value.code == 1
    output = capsys.readouterr()
    assert json.loads(output.out)["mobile_delivery"]["state"] == "not-attempted"
    assert "difficulty-status " + "a" * 32 in output.err


@pytest.mark.parametrize("failure", ["timeout", "connection", "http500", "invalid-json", "invalid-envelope"])
def test_uncertain_difficulty_apply_uses_same_operation_status_guidance(host, monkeypatch, tmp_path, capsys, failure):
    environment(host, monkeypatch, tmp_path)
    monkeypatch.setattr(host, "read_credential", lambda _path: "d" * 64)
    monkeypatch.setattr(host, "normal_sync", lambda *_a: pytest.fail("uncertain operation synced"))
    calls = []

    def request(*_a, **_kw):
        calls.append("apply")
        if failure in ("invalid-json", "invalid-envelope"):
            return io.BytesIO(b"private" if failure == "invalid-json" else b'{"ok":true,"result":[]}')
        raise {"timeout": TimeoutError("private"), "connection": host.urllib.error.URLError("private"),
               "http500": host.urllib.error.HTTPError("http://private", 500, "private", {}, io.BytesIO(b"private"))}[failure]

    monkeypatch.setattr(host.urllib.request, "build_opener", lambda *_a: SimpleNamespace(open=request))
    with pytest.raises(Exception):
        host.main(["difficulty-apply", "a" * 32, "--preview-token", "b" * 64, "--confirm"])
    output = capsys.readouterr()
    assert calls == ["apply"] and output.out == ""
    assert "difficulty-status " + "a" * 32 in output.err
    assert "do not create a new request ID" in output.err and "private" not in output.err


@pytest.mark.parametrize("command", ["difficulty-apply", "difficulty-status"])
def test_difficulty_cli_rejects_foreign_receipt_before_output_or_sync(host, monkeypatch, tmp_path, capsys, command):
    environment(host, monkeypatch, tmp_path)
    monkeypatch.setattr(host, "read_credential", lambda _path: "d" * 64)
    monkeypatch.setattr(host, "normal_sync", lambda *_a: pytest.fail("foreign operation synced"))
    monkeypatch.setattr(host, "helper", lambda *_a, **_kw: difficulty_receipt("applied", action="remove_unused_tags"))
    args = [command, "a" * 32]
    if command == "difficulty-apply":
        args += ["--preview-token", "b" * 64, "--confirm"]
    with pytest.raises(host.CommandError, match="unexpected-operation-action"):
        host.main(args)
    assert capsys.readouterr().out == ""


@pytest.mark.parametrize("change", [{"operation_id": "c" * 32}, {"state": "applying"},
    {"sync": []}, {"sync": {"state": "synced"}}, {"request_id": "different01"}])
def test_difficulty_result_rejects_mismatched_receipts(host, change):
    with pytest.raises(host.CommandError, match="helper-request-failed"):
        host.difficulty_result(difficulty_receipt(**change), "a" * 32, "mobile001")


def test_difficulty_receipt_redacts_nested_unknown_errors_without_mutating_journal(host):
    value = difficulty_receipt("unknown", error="apply-result-unknown:private",
                               result={"state": "unknown", "items": [{"error": "private note body"}]})
    value["sync"]["error"] = "operation-not-found"
    result = host.difficulty_result(value, "a" * 32)
    assert result["error"] == result["result"]["items"][0]["error"] == "helper-request-failed"
    assert result["sync"]["error"] == "operation-not-found"
    assert value["result"]["items"][0]["error"] == "private note body"


@pytest.mark.parametrize("code", [
    "invalid-mobile-summary", "mobile-summary-capacity-exceeded", "duplicate-review-id",
    "custom-data-capacity-exceeded", "custom-scheduling-already-configured",
    "managed-difficulty-model-missing", "invalid-custom-data", "invalid-cutoff",
    "invalid-reassessment-anchor", "reassessment-anchor-changed", "invalid-rollover",
    "unmanaged-difficulty-card", "invalid-difficulty-mobile-request",
])
def test_difficulty_errors_use_exact_public_vocabulary(host, code):
    assert str(host.helper_error({"error": code})) == code
    assert str(host.helper_error({"error": code + ": private data"})) == "helper-request-failed"
