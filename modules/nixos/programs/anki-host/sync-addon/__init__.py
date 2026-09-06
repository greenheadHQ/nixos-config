"""anki_host_sync — headless Anki용 AnkiWeb 로그인·동기화·스냅샷 헬퍼 애드온.

nixos-config `modules/nixos/programs/anki-host`가 `pkgs.anki.withAddons`로 bake한다.
GUI 없이 도는 Anki 프로세스 안에서 loopback HTTP(JSON)만 연다. 인증은 없다 —
같은 호스트의 서비스 계정만 닿는다는 전제이고, 원격 노출은 이 애드온의 책임이 아니다.

왜 AnkiConnect의 `sync` 액션을 쓰지 않는가: 그 액션은 `mw.onSync()`를 불러 GUI 다이얼로그
경로를 타므로 full sync가 요구되면 offscreen에서 영원히 멈춘다. 여기서는
`col.sync_collection`을 직접 호출해 결과 코드(`required`)를 받고, 방향 결정은 호출자
(systemd sync 서비스 / MCP 서버)가 명시한 mode로만 허용한다.

환경 변수:
  ANKI_HOST_HELPER_PORT      loopback 포트. 없거나 0이면 서버를 열지 않는다.
  ANKI_HOST_SYNC_CREDENTIALS ANKIWEB_USERNAME=/ANKIWEB_PASSWORD= 두 줄 파일. 없으면 로그인하지 않는다.
  ANKI_HOST_EXPORT_DIR       /export·/import-colpkg가 허용하는 유일한 디렉터리.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
import traceback
from concurrent.futures import Future
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable

import aqt
from anki import sync_pb2
from aqt import gui_hooks

ADDON_VERSION = "1.0.0"
BIND = "127.0.0.1"
PORT = int(os.environ.get("ANKI_HOST_HELPER_PORT", "0") or "0")
CRED_FILE = os.environ.get("ANKI_HOST_SYNC_CREDENTIALS") or None
EXPORT_DIR = os.environ.get("ANKI_HOST_EXPORT_DIR") or None
MAIN_TIMEOUT_SECS = 1800  # 첫 전체 다운로드(수백 MB 미디어 제외)도 이 안에 끝난다

ChangesRequired = sync_pb2.SyncCollectionResponse.ChangesRequired
NO_CHANGES = ChangesRequired.NO_CHANGES
NORMAL_SYNC = ChangesRequired.NORMAL_SYNC
FULL_SYNC = ChangesRequired.FULL_SYNC
FULL_DOWNLOAD = ChangesRequired.FULL_DOWNLOAD
FULL_UPLOAD = ChangesRequired.FULL_UPLOAD

_lock = threading.Lock()  # HTTP 요청 직렬화 (sync·export·import는 동시에 돌면 안 된다)
_state: dict[str, Any] = {"login": {"status": "not-attempted"}, "last_sync": None, "server": None}


def _log(msg: str) -> None:
    print(f"[anki_host_sync] {msg}", file=sys.stderr, flush=True)


def _now() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def _on_main(fn: Callable[..., Any], *args: Any, timeout: float = MAIN_TIMEOUT_SECS) -> Any:
    """Anki 컬렉션은 메인 스레드에서만 만진다. 결과를 Future로 받아 HTTP 스레드에 돌려준다."""
    fut: Future = Future()

    def run() -> None:
        try:
            fut.set_result(fn(*args))
        except BaseException as err:  # noqa: BLE001 — 호출자에게 그대로 전달
            fut.set_exception(err)

    aqt.mw.taskman.run_on_main(run)
    return fut.result(timeout=timeout)


# ── 자격·로그인 ────────────────────────────────────────────────────────────


def _read_credentials() -> tuple[str, str] | None:
    if not CRED_FILE or not os.path.exists(CRED_FILE):
        return None
    values: dict[str, str] = {}
    with open(CRED_FILE, encoding="utf-8") as stream:
        for raw in stream:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    username = values.get("ANKIWEB_USERNAME", "")
    password = values.get("ANKIWEB_PASSWORD", "")
    if not username or not password:
        return None
    return username, password


def _ensure_login() -> dict[str, Any]:
    """syncKey가 없을 때만 AnkiWeb에 로그인해 프로필에 저장한다. 비밀번호는 메모리에만 머문다."""
    pm = aqt.mw.pm
    if pm.sync_auth() is not None:
        return {"status": "already-logged-in", "username": pm.profile.get("syncUser")}
    creds = _read_credentials()
    if creds is None:
        return {"status": "no-credentials"}
    username, password = creds
    try:
        auth = aqt.mw.col.sync_login(username=username, password=password, endpoint=pm.sync_endpoint())
    except Exception as err:  # noqa: BLE001
        _log(f"sync login failed: {err.__class__.__name__}")
        return {"status": "login-failed", "error": err.__class__.__name__, "at": _now()}
    pm.set_sync_key(auth.hkey)
    pm.set_sync_username(username)
    pm.save()
    _log("sync auth initialized")
    return {"status": "logged-in", "username": username, "at": _now()}


# ── 스냅샷 ────────────────────────────────────────────────────────────────


def _snapshot() -> dict[str, Any]:
    col = aqt.mw.col
    cutoff_ms = (col.sched.day_cutoff - 86400) * 1000
    by_deck: dict[str, int] = {}
    for did, count in col.db.all(
        "select c.did, count() from revlog r join cards c on c.id = r.cid where r.id > ? group by c.did",
        cutoff_ms,
    ):
        by_deck[col.decks.name(did)] = count
    return {
        "at": _now(),
        "notes": col.note_count(),
        "cards": col.card_count(),
        "revlog": col.db.scalar("select count() from revlog"),
        "today_reviews": col.db.scalar("select count() from revlog where id > ?", cutoff_ms),
        "today_reviews_by_deck": by_deck,
        "day_cutoff": col.sched.day_cutoff,
        "col_mod": col.db.scalar("select mod from col"),
    }


def _media_status() -> dict[str, Any]:
    try:
        status = aqt.mw.col.media_sync_status()
    except Exception as err:  # noqa: BLE001 — 마지막 미디어 sync 오류를 여기서 드러낸다
        return {"active": False, "error": err.__class__.__name__, "detail": str(err)[:200]}
    progress = getattr(status, "progress", None)
    return {
        "active": bool(status.active),
        "checked": getattr(progress, "checked", None),
        "added": getattr(progress, "added", None),
        "removed": getattr(progress, "removed", None),
    }


def _wait_media(seconds: float) -> dict[str, Any]:
    deadline = time.monotonic() + max(0.0, seconds)
    while True:
        status = _on_main(_media_status, timeout=60)
        if not status.get("active") or time.monotonic() >= deadline:
            return status
        time.sleep(1)


# ── 동기화 ────────────────────────────────────────────────────────────────


def _full(auth: Any, out: Any, upload: bool) -> None:
    mw = aqt.mw
    mw.col.close_for_full_sync()
    try:
        mw.col.full_upload_or_download(auth=auth, server_usn=out.server_media_usn, upload=upload)
    finally:
        mw.col.reopen(after_full_sync=True)
    mw.reset()
    if mw.pm.media_syncing_enabled():
        mw.col.sync_media(mw.pm.sync_auth())


def _sync(mode: str) -> dict[str, Any]:
    """mode: normal | allow-download-if-empty | download | upload.

    normal: 병합 가능한 변경만 동기화하고 full sync가 요구되면 아무것도 하지 않는다.
    allow-download-if-empty: 로컬이 비어 있을 때(노트 0·복습 기록 0)만 서버본을 내려받는다 (첫 부트스트랩).
    download / upload: 호출자가 방향을 책임진다. upload는 로컬이 비어 있으면 거부한다.
    """
    mw = aqt.mw
    pm = mw.pm
    auth = pm.sync_auth()
    if auth is None:
        raise RuntimeError("not-logged-in")
    before = _snapshot()
    out = mw.col.sync_collection(auth, pm.media_syncing_enabled())
    if out.new_endpoint:
        pm.set_current_sync_url(out.new_endpoint)
        pm.save()
        auth = pm.sync_auth()
    required = ChangesRequired.Name(out.required)
    action = "none"
    empty = before["notes"] == 0 and before["revlog"] == 0
    if out.required == NO_CHANGES:
        action = "normal"
    elif out.required in (FULL_SYNC, FULL_DOWNLOAD, FULL_UPLOAD):
        if mode == "allow-download-if-empty" and empty and out.required != FULL_UPLOAD:
            _full(auth, out, upload=False)
            action = "full-download"
        elif mode == "download":
            _full(auth, out, upload=False)
            action = "full-download"
        elif mode == "upload":
            if empty:
                raise RuntimeError("refusing-upload-of-empty-collection")
            _full(auth, out, upload=True)
            action = "full-upload"
        else:
            action = "full-sync-required"
    else:
        action = f"unexpected:{required}"
    after = _snapshot()
    result = {
        "at": _now(),
        "mode": mode,
        "required": required,
        "action": action,
        "server_message": out.server_message or "",
        "before": before,
        "after": after,
    }
    _state["last_sync"] = result
    _log(f"sync mode={mode} required={required} action={action}")
    return result


# ── 내보내기·가져오기 (복구점·fixture) ──────────────────────────────────────


def _checked_path(path: str) -> str:
    if not EXPORT_DIR:
        raise RuntimeError("export-dir-not-configured")
    real = os.path.realpath(path)
    root = os.path.realpath(EXPORT_DIR)
    if os.path.commonpath([real, root]) != root:
        raise RuntimeError("path-outside-export-dir")
    return real


def _export(path: str, include_media: bool, legacy: bool) -> dict[str, Any]:
    mw = aqt.mw
    real = _checked_path(path)
    os.makedirs(os.path.dirname(real), exist_ok=True)
    snap = _snapshot()
    try:
        mw.col.export_collection_package(out_path=real, include_media=include_media, legacy=legacy)
    finally:
        mw.col.reopen(after_full_sync=False)
    mw.reset()
    return {"path": real, "bytes": os.path.getsize(real), "include_media": include_media, "legacy": legacy, "counts": snap}


def _import_colpkg(path: str) -> dict[str, Any]:
    """전체 컬렉션 패키지로 이 프로필을 **교체**한다. 격리 fixture 준비 전용."""
    mw = aqt.mw
    pm = mw.pm
    real = _checked_path(path)
    if not os.path.isfile(real):
        raise RuntimeError("file-not-found")
    if pm.sync_auth() is not None:
        raise RuntimeError("refusing-import-into-logged-in-profile")
    folder = pm.profileFolder()
    mw.col.close_for_full_sync()
    try:
        mw.backend.import_collection_package(
            col_path=pm.collectionPath(),
            backup_path=real,
            media_folder=os.path.join(folder, "collection.media"),
            media_db=os.path.join(folder, "collection.media.db2"),
        )
    finally:
        mw.col.reopen(after_full_sync=True)
    mw.reset()
    return {"imported": real, "counts": _snapshot()}


def _status() -> dict[str, Any]:
    pm = aqt.mw.pm
    from anki.buildinfo import version as anki_version

    return {
        "addon_version": ADDON_VERSION,
        "anki_version": anki_version,
        "profile": pm.name,
        "logged_in": pm.sync_auth() is not None,
        "sync_username": pm.profile.get("syncUser"),
        "media_syncing_enabled": pm.media_syncing_enabled(),
        "login": _state["login"],
        "last_sync": _state["last_sync"],
        "counts": _snapshot(),
        "media": _media_status(),
    }


# ── HTTP ──────────────────────────────────────────────────────────────────


class _Handler(BaseHTTPRequestHandler):
    server_version = "anki_host_sync/" + ADDON_VERSION

    def log_message(self, fmt: str, *args: Any) -> None:  # journald에는 결과만 남긴다
        return

    def _reply(self, code: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        data = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        return data if isinstance(data, dict) else {}

    def do_GET(self) -> None:  # noqa: N802
        self._route()

    def do_POST(self) -> None:  # noqa: N802
        self._route()

    def _route(self) -> None:
        path = self.path.split("?", 1)[0]
        try:
            body = self._body()
            with _lock:
                if path == "/status" and self.command == "GET":
                    result = _on_main(_status, timeout=120)
                elif path == "/counts" and self.command == "GET":
                    result = _on_main(_snapshot, timeout=120)
                elif path == "/media-status" and self.command == "GET":
                    result = _on_main(_media_status, timeout=60)
                elif path == "/login" and self.command == "POST":
                    result = _on_main(_ensure_login, timeout=120)
                    _state["login"] = result
                elif path == "/sync" and self.command == "POST":
                    mode = str(body.get("mode", "normal"))
                    if mode not in ("normal", "allow-download-if-empty", "download", "upload"):
                        raise ValueError("unknown-mode")
                    result = _on_main(_sync, mode)
                    result["media"] = _wait_media(float(body.get("wait_media_secs", 0)))
                elif path == "/export" and self.command == "POST":
                    result = _on_main(
                        _export,
                        str(body["path"]),
                        bool(body.get("include_media", True)),
                        bool(body.get("legacy", True)),
                    )
                elif path == "/import-colpkg" and self.command == "POST":
                    result = _on_main(_import_colpkg, str(body["path"]))
                else:
                    self._reply(404, {"ok": False, "error": "not-found"})
                    return
            self._reply(200, {"ok": True, "result": result})
        except Exception as err:  # noqa: BLE001
            _log(f"{self.command} {path} failed: {err.__class__.__name__}: {err}")
            traceback.print_exc(file=sys.stderr)
            self._reply(500, {"ok": False, "error": str(err) or err.__class__.__name__, "type": err.__class__.__name__})


def _start_server() -> None:
    if _state["server"] is not None or PORT <= 0:
        return
    server = ThreadingHTTPServer((BIND, PORT), _Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, name="anki_host_sync-http", daemon=True)
    thread.start()
    _state["server"] = server
    _log(f"helper listening on {BIND}:{PORT}")


def _on_profile_open() -> None:
    _state["login"] = _ensure_login()
    _log(f"login: {_state['login'].get('status')}")
    _start_server()


def _on_profile_close() -> None:
    server = _state.get("server")
    if server is not None:
        server.shutdown()
        _state["server"] = None


gui_hooks.profile_did_open.append(_on_profile_open)
gui_hooks.profile_will_close.append(_on_profile_close)
