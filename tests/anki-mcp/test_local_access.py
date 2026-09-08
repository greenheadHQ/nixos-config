import importlib.util
import json
import sys
import threading
import types
from pathlib import Path

import httpx
import pytest

from anki_host_fixture.access import Access


@pytest.fixture
def credentials(tmp_path):
    for i, role in enumerate(("read", "operation", "maintenance", "schema"), 1):
        (tmp_path / role).write_text(str(i) * 64)
    return tmp_path


def test_roles_and_malformed_credentials(credentials):
    access = Access(str(credentials))
    for header in (None, "", "Bearer wrong", "Bearer " + "한" * 64, "Bearer " + "f" * 64):
        assert access.role(header) is None
    assert access.role("Bearer " + "1" * 64) == "read"
    for role in access.keys:
        assert access.allowed("GET", "/status", role)
        assert access.allowed("POST", "/sync", role) is (role == "maintenance")
        assert access.allowed("POST", "/schema/apply", role) is (role == "schema")
        assert access.allowed("POST", "/operations/apply", role) is (role in ("operation", "schema"))
        assert not access.allowed("GET", "/operations/apply", role)
    assert not access.allowed("GET", "/status", None)


@pytest.mark.parametrize("value", [None, "", "short", "z" * 64])
def test_missing_key_prevents_helper_initialization(credentials, value):
    path = credentials / "schema"
    if value is None:
        path.unlink()
    else:
        path.write_text(value)
    with pytest.raises((RuntimeError, OSError)):
        Access(str(credentials))


@pytest.fixture
def runtime(monkeypatch, credentials):
    aqt = types.ModuleType("aqt")
    aqt.mw = types.SimpleNamespace(taskman=types.SimpleNamespace(run_on_main=lambda fn: fn()))
    aqt.gui_hooks = types.SimpleNamespace(profile_did_open=[], profile_will_close=[])
    anki = types.ModuleType("anki")
    changes = types.SimpleNamespace(NO_CHANGES=0, FULL_SYNC=1, FULL_DOWNLOAD=2, FULL_UPLOAD=3)
    changes.Name = lambda n: ("NO_CHANGES", "FULL_SYNC", "FULL_DOWNLOAD", "FULL_UPLOAD")[n]
    anki.sync_pb2 = types.SimpleNamespace(SyncCollectionResponse=types.SimpleNamespace(ChangesRequired=changes))
    monkeypatch.setitem(sys.modules, "aqt", aqt)
    monkeypatch.setitem(sys.modules, "anki", anki)
    values = {"MAIN_TIMEOUT_SECS": "1", "BUSY_WAIT_SECS": "1", "QUERY_TIMEOUT_SECS": "1",
              "GUARD_MIN_RETAIN_PCT": "80", "OPERATION_TTL_SECS": "600", "BULK_LIMIT": "20",
              "MEDIA_MAX_BYTES": "5", "BODY_MAX_BYTES": "1024", "BODY_TIMEOUT_SECS": "1",
              "MAX_REQUESTS": "8", "INSTANCE": "test", "MIRROR_TIMEOUT_SECS": "2", "HELPER_PORT": "0",
              "STATE_DIR": str(credentials / "state")}
    for key, value in values.items():
        monkeypatch.setenv("ANKI_HOST_" + key, value)
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(credentials))
    path = Path(__file__).resolve().parents[2] / "modules/nixos/programs/anki-host/sync-addon/__init__.py"
    spec = importlib.util.spec_from_file_location("anki_host_runtime_fixture", path, submodule_search_locations=[str(path.parent)])
    module = importlib.util.module_from_spec(spec)
    monkeypatch.setitem(sys.modules, spec.name, module)
    spec.loader.exec_module(module)
    return module


def test_http_denies_missing_and_wrong_roles_before_dispatch(runtime):
    server = runtime._Server(("127.0.0.1", 0), runtime._Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with httpx.Client(base_url=f"http://127.0.0.1:{server.server_port}", trust_env=False) as client:
            assert client.get("/status").status_code == 401
            assert client.get("/status", headers={"Authorization": "Bearer " + "f" * 64}).status_code == 401
            read = {"Authorization": "Bearer " + "1" * 64}
            op = {"Authorization": "Bearer " + "2" * 64}
            assert client.get("/status", headers=read).json()["ok"] is True
            assert client.post("/operations/apply", headers=read, json={}).status_code == 403
            assert client.post("/sync", headers=op, json={"mode": "normal"}).status_code == 403
            assert client.post("/schema/apply", headers=op, json={}).status_code == 403
            assert client.post("/operations/apply", headers=op, content=b"x" * 1025).status_code == 400
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def test_timeout_keeps_mutation_lock_until_late_callback_finishes(runtime, monkeypatch):
    started, release, finished = threading.Event(), threading.Event(), threading.Event()
    workers = []
    def schedule(fn):
        worker = threading.Thread(target=fn, daemon=True)
        workers.append(worker)
        worker.start()
    runtime.aqt.mw.taskman.run_on_main = schedule
    monkeypatch.setattr(runtime, "MAIN_TIMEOUT_SECS", 0.03)
    monkeypatch.setattr(runtime, "BUSY_WAIT_SECS", 0.01)
    calls = []
    def slow():
        started.set()
        release.wait(2)
        calls.append("write")
        finished.set()
    try:
        with pytest.raises(RuntimeError, match="main-thread-timeout"):
            runtime._mutating("apply", slow)
        assert started.is_set() and runtime._busy == "apply:timed-out"
        for name in ("sync", "export", "apply"):
            with pytest.raises(runtime.BusyError):
                runtime._mutating(name, lambda: calls.append("overlap"))
        assert calls == []
    finally:
        release.set()
        assert finished.wait(2)
        for worker in workers:
            worker.join(timeout=2)
    assert calls == ["write"] and runtime._busy is None
    assert runtime._mutating("sync", lambda: "next") == "next"


@pytest.mark.parametrize("failure", ["missing", "version", "method", None])
def test_profile_readiness_requires_compatible_bridge(runtime, monkeypatch, failure):
    from types import SimpleNamespace
    methods = runtime.AnkiAdapter.check_bridge.__globals__["REQUIRED_METHODS"]
    bridge = SimpleNamespace(**{name: lambda **_: None for name in methods})
    window = runtime.aqt.mw
    window.pm = SimpleNamespace(name="test")
    window._anki_host_connect_version = 2 if failure == "version" else 1
    if failure != "missing":
        window._anki_host_connect = bridge
    if failure == "method":
        del bridge.setDueDate
    monkeypatch.setattr(runtime, "_ensure_login", lambda: {"status": "no-credentials"})
    monkeypatch.setattr(runtime, "_ops", lambda: None)
    runtime._on_profile_open()
    assert runtime._status_quick()["collection_open"] is (failure is None)
    assert bool(runtime._status_quick()["bridge_error"]) is (failure is not None)


@pytest.mark.parametrize('required,media,fail', [(0, True, False), (1, True, False), (3, False, False), (2, True, False), (3, True, True)])
def test_schema_sync_direction_and_reopen_contract(runtime, monkeypatch, required, media, fail):
    from types import SimpleNamespace
    events = []
    def upload(**kwargs):
        events.append(('upload', kwargs))
        if fail:
            raise RuntimeError('synthetic upload failure')
    col = SimpleNamespace(sync_collection=lambda auth, enabled: SimpleNamespace(required=required, new_endpoint='', server_media_usn=42),
          close_for_full_sync=lambda: events.append(('close', None)), full_upload_or_download=upload,
          reopen=lambda **kw: events.append(('reopen', kw)), sync_media=lambda auth: events.append(('media', auth)))
    runtime.aqt.mw.col = col
    runtime.aqt.mw.pm = SimpleNamespace(sync_auth=lambda: 'fixture-auth', media_syncing_enabled=lambda: media)
    runtime.aqt.mw.reset = lambda: events.append(('reset', None))
    monkeypatch.setattr(runtime, '_snapshot', lambda: {'notes': 2, 'cards': 2, 'revlog': 3})
    if fail:
        with pytest.raises(RuntimeError, match='synthetic'):
            runtime._approved_schema_sync({'notes': 2, 'cards': 2, 'revlog': 3})
    else:
        result = runtime._approved_schema_sync({'notes': 2, 'cards': 2, 'revlog': 3})
        assert result['action'] == ('normal' if required == 0 else 'approved-full-upload' if required in (1, 3) else 'schema-sync-blocked')
    if required in (1, 3):
        assert events[:3] == [('close', None), ('upload', {'auth': 'fixture-auth', 'server_usn': 42 if media else None, 'upload': True}),
                             ('reopen', {'after_full_sync': True})]
    else:
        assert not any(e[0] in ('close', 'upload', 'reopen') for e in events)
