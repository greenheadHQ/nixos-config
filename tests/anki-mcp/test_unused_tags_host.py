import importlib.util
import io
import json
import os
from pathlib import Path
from types import SimpleNamespace

import pytest


@pytest.fixture
def host(monkeypatch, tmp_path):
    source = Path(__file__).resolve().parents[2] / "modules/nixos/programs/anki-host/files/unused-tags-host.py"
    spec = importlib.util.spec_from_file_location("unused_tags_host_fixture", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setattr(module.os, "geteuid", lambda: 0)
    monkeypatch.setenv("INSTANCE", "fixture")
    monkeypatch.setenv("HELPER_PORT", "19001")
    monkeypatch.setenv("HELPER_CURL_MAX_TIME", "120")
    monkeypatch.setenv("LOCAL_CREDENTIAL_ROOT", str(tmp_path))
    return module


@pytest.mark.parametrize("argv,path,payload", [
    ([], "/tags/unused/inspect", {"protected_tags": []}),
    (["inspect", "--protect", "keep"], "/tags/unused/inspect", {"protected_tags": ["keep"]}),
    (["preview", "--tags-file", "selected.json", "--protect-file", "protected.json", "--request-id", "cleanup01"],
     "/tags/unused/prepare", {"tags": ["unused"], "protected_tags": ["keep"], "request_id": "cleanup01"}),
    (["apply", "a" * 32, "--preview-token", "b" * 64, "--confirm"], "/tags/unused/apply",
     {"operation_id": "a" * 32, "preview_token": "b" * 64, "confirm": True}),
    (["status", "a" * 32], "/operations/status", {"operation_id": "a" * 32}),
])
def test_private_root_command_uses_only_fixed_paths_and_schema_key(host, monkeypatch, tmp_path, capsys, argv, path, payload):
    reads, calls = [], []
    def read(file, maximum):
        reads.append(file)
        return {"selected.json": b'["unused"]', "protected.json": b'["keep"]'}.get(file.name, b"c" * 64)
    monkeypatch.setattr(host, "private_file", read)
    def call(actual_path, actual_payload, **kwargs):
        calls.append((actual_path, actual_payload, kwargs))
        return {"action": "remove_unused_tags", "state": "applied"}
    monkeypatch.setattr(host, "helper", call)
    host.main(argv)
    assert reads[-1] == tmp_path / "fixture" / "schema"
    assert calls == [(path, payload, {"key": "c" * 64, "port": 19001, "timeout": 120})]
    output = capsys.readouterr()
    assert json.loads(output.out)["state"] == "applied" and "c" * 64 not in output.out + output.err


@pytest.mark.parametrize("argv", [[], ["inspect"], ["preview", "--tags-file", "selected.json"],
                                  ["apply", "a" * 32, "--preview-token", "b" * 64, "--confirm"]])
def test_non_root_stops_before_reading_files(host, monkeypatch, argv):
    monkeypatch.setattr(host.os, "geteuid", lambda: 1000)
    monkeypatch.setattr(host, "private_file", lambda *_: pytest.fail("non-root file read"))
    with pytest.raises(SystemExit):
        host.main(argv)


@pytest.mark.parametrize("argv", [
    ["clear-all"], ["inspect", "--url", "https://invalid"], ["preview", "--tags", "unused"],
    ["apply", "a" * 32, "--preview-token", "b" * 64],
    ["apply", "a" * 32, "--confirm"],
    ["apply", "a" * 32, "--preview-token", "b" * 64, "--conf"],
    ["apply", "../escape", "--preview-token", "b" * 64, "--confirm"],
])
def test_no_generic_or_unconfirmed_command(host, monkeypatch, argv):
    monkeypatch.setattr(host, "private_file", lambda *_: pytest.fail("invalid command read a file"))
    with pytest.raises(SystemExit):
        host.main(argv)


def test_input_files_must_be_private_root_owned_regular_files(host, monkeypatch, tmp_path):
    file = tmp_path / "selected.json"
    file.write_bytes(b'["unused"]')
    file.chmod(0o600)
    actual_stat = os.fstat
    monkeypatch.setattr(host.os, "fstat", lambda fd: SimpleNamespace(
        st_mode=actual_stat(fd).st_mode, st_uid=0, st_size=actual_stat(fd).st_size))
    assert host.private_file(file, 100) == b'["unused"]'
    file.chmod(0o640)
    with pytest.raises(ValueError):
        host.private_file(file, 100)
    file.chmod(0o600)
    with pytest.raises(ValueError):
        host.private_file(file, 2)
    link = tmp_path / "symlink"
    link.symlink_to(file)
    with pytest.raises(OSError):
        host.private_file(link, 100)


def test_loopback_client_disables_proxies_and_redirects(host, monkeypatch):
    handlers_seen, requests = [], []
    def opener(*handlers):
        handlers_seen.extend(handlers)
        def request(value, timeout):
            requests.append((value, timeout))
            return io.BytesIO(b'{"ok":true,"result":{"scope":"local-tag-registry"}}')
        return SimpleNamespace(open=request)
    monkeypatch.setattr(host.urllib.request, "build_opener", opener)
    host.helper("/tags/unused/inspect", {}, key="c" * 64, port=19001, timeout=120)
    assert handlers_seen[0].proxies == {}
    assert handlers_seen[1].redirect_request(None, None, None, None, None, None) is None
    assert requests[0][0].full_url == "http://127.0.0.1:19001/tags/unused/inspect"


def test_unknown_result_is_printed_but_not_claimed_complete(host, monkeypatch, capsys):
    monkeypatch.setattr(host, "private_file", lambda *_: b"c" * 64)
    monkeypatch.setattr(host, "helper", lambda *_a, **_kw: {"action": "remove_unused_tags", "state": "unknown"})
    with pytest.raises(ValueError, match="do-not-repeat") as error:
        host.main(["apply", "a" * 32, "--preview-token", "b" * 64, "--confirm"])
    assert json.loads(capsys.readouterr().out)["state"] == "unknown"
    assert host.STATUS_GUIDANCE in host.describe_error(error.value)


def failing_opener(host, monkeypatch, error):
    def request(*_args, **_kwargs):
        raise error
    monkeypatch.setattr(host.urllib.request, "build_opener", lambda *_: SimpleNamespace(open=request))


@pytest.mark.parametrize("code", [
    "stale-preview-create-a-new-request-id", "selected-tag-or-descendant-is-in-use",
    "unused-tag-selection-includes-protected-name", "unused-tag-selection-must-include-all-descendants",
    "preview-expired-create-a-new-request-id", "restore-point-not-mirrored",
])
def test_helper_rejections_expose_only_fixed_actionable_codes(host, monkeypatch, code):
    error = host.urllib.error.HTTPError("http://private/path", 400, "private reason", {},
        io.BytesIO(json.dumps({"ok": False, "error": code}).encode()))
    failing_opener(host, monkeypatch, error)
    with pytest.raises(ValueError) as caught:
        host.helper("/tags/unused/apply", {}, key="c" * 64, port=19001, timeout=120)
    assert host.describe_error(caught.value) == code


@pytest.mark.parametrize("body", [
    b'{"ok":false,"error":"private-tag-and-credential"}',
    b'{"ok":true,"error":"selected-tag-or-descendant-is-in-use"}',
    b'{"ok":false,"error":"selected-tag-or-descendant-is-in-use","detail":"private"}',
    b'{"ok":false,"error":["selected-tag-or-descendant-is-in-use"]}',
    b'["private"]', b'not-json-private',
    b'{"ok":false,"error":"selected-tag-or-descendant-is-in-use"}' + b' ' * 4096,
])
def test_untrusted_helper_errors_do_not_leak_body_or_claim_known_rejection(host, monkeypatch, body):
    error = host.urllib.error.HTTPError("http://private/path", 400, "private reason", {}, io.BytesIO(body))
    failing_opener(host, monkeypatch, error)
    with pytest.raises(host.urllib.error.HTTPError) as caught:
        host.helper("/tags/unused/prepare", {}, key="c" * 64, port=19001, timeout=120)
    assert host.describe_error(caught.value) == "HTTPError"


def test_error_body_read_has_a_hard_limit(host):
    class Body(io.BytesIO):
        def read(self, size=-1):
            assert size == host.MAX_ERROR_BODY_BYTES + 1
            return super().read(size)
    error = host.urllib.error.HTTPError("http://private", 400, "private", {}, Body(b'x' * 10000))
    assert host.remote_error_code(error) is None


@pytest.mark.parametrize("failure", ["timeout", "connection", "http500", "invalid-json", "invalid-envelope"])
def test_apply_response_uncertainty_requires_same_operation_status(host, monkeypatch, failure):
    if failure in ("invalid-json", "invalid-envelope"):
        body = b'private-not-json' if failure == "invalid-json" else b'{"ok":true,"result":[]}'
        monkeypatch.setattr(host.urllib.request, "build_opener", lambda *_:
                            SimpleNamespace(open=lambda *_a, **_kw: io.BytesIO(body)))
    else:
        error = {
            "timeout": TimeoutError("private timeout detail"),
            "connection": host.urllib.error.URLError("private network detail"),
            "http500": host.urllib.error.HTTPError("http://private", 500, "private", {},
                                                  io.BytesIO(b'{"ok":false,"error":"private"}')),
        }[failure]
        failing_opener(host, monkeypatch, error)
    with pytest.raises(ValueError) as caught:
        host.helper("/tags/unused/apply", {}, key="c" * 64, port=19001, timeout=120)
    message = host.describe_error(caught.value)
    assert message == "apply-response-unknown-check-status-do-not-repeat. " + host.STATUS_GUIDANCE
    assert "private" not in message and "c" * 64 not in message


def test_busy_apply_reports_status_guidance_without_current_operation_details(host, monkeypatch):
    error = host.urllib.error.HTTPError("http://private", 409, "private", {},
        io.BytesIO(b'{"ok":false,"error":"busy","busy":"private-operation-name"}'))
    failing_opener(host, monkeypatch, error)
    with pytest.raises(ValueError) as caught:
        host.helper("/tags/unused/apply", {}, key="c" * 64, port=19001, timeout=120)
    assert host.describe_error(caught.value) == "helper-busy-check-status-do-not-repeat. " + host.STATUS_GUIDANCE


def test_known_local_errors_are_useful_but_arbitrary_value_errors_remain_private(host):
    code = "expected-private-root-owned-regular-file"
    assert host.describe_error(ValueError(code)) == code
    assert host.describe_error(ValueError("private/path or secret")) == "ValueError"
    assert host.describe_error(ValueError(code + ": private/path")) == "ValueError"
