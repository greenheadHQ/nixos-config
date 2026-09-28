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
    with pytest.raises(ValueError, match="do-not-repeat"):
        host.main(["apply", "a" * 32, "--preview-token", "b" * 64, "--confirm"])
    assert json.loads(capsys.readouterr().out)["state"] == "unknown"
