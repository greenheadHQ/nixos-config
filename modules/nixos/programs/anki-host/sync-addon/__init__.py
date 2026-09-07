"""anki_host_sync — headless Anki용 AnkiWeb 로그인·동기화·스냅샷 헬퍼 애드온.

nixos-config `modules/nixos/programs/anki-host`가 `pkgs.anki.withAddons`로 bake한다.
GUI 없이 도는 Anki 프로세스 안에서 loopback HTTP(JSON)만 연다. 인증은 없다.

신뢰 경계: loopback은 이 호스트에서 격리를 보장하지 않는다 — `--network=host` 컨테이너
(uptime-kuma)가 같은 loopback namespace를 공유한다. 그래서 이 애드온은 되돌릴 수 없는 동작을
노출하지 않는다: full sync 방향은 "로컬이 비어 있을 때의 Download"(부트스트랩)만 허용하고,
서버를 덮어쓰는 Upload 모드는 존재하지 않는다. 컬렉션 교체(/import-colpkg)는 AnkiWeb에
로그인된 프로필에서 거부되므로 운영 인스턴스에는 영향이 없다(격리 fixture 전용).

왜 AnkiConnect의 `sync` 액션을 쓰지 않는가: 그 액션은 `mw.onSync()`를 불러 GUI 다이얼로그
경로를 타므로 full sync가 요구되면 offscreen에서 영원히 멈춘다. 여기서는
`col.sync_collection`을 직접 호출해 결과 코드(`required`)를 받는다.

동시성 계약: 컬렉션을 바꾸는 작업(/sync, /export, /import-colpkg)은 서로 배제한다.
대기가 BUSY_WAIT_SECS를 넘으면 무한 대기 대신 HTTP 409와 진행 중인 작업 이름을 돌려주어,
호출자가 "응답 없음"과 "다른 작업 진행 중"을 구분하게 한다.
조회는 둘이다. `/status`는 메인 스레드를 타지 않고 애드온 메모리(`_state`)만 읽어 즉시 답한다
(collection_open·login·last_sync·busy) — 준비 대기 프로브와 로그인 판정은 이것으로 충분하고,
기동 중 메인 스레드가 로그인 네트워크 호출에 잠겨 있어도 작업이 큐에 쌓이지 않는다.
`/status/full`은 메인 스레드에서 counts·media까지 채운다(운영자 조회·PR 2 도구용). busy 중에는 409.

환경 변수 (모두 nixos 모듈이 단일 소스에서 파생해 넣는다):
  ANKI_HOST_HELPER_PORT       loopback 포트. 없거나 0이면 서버를 열지 않는다.
  ANKI_HOST_SYNC_CREDENTIALS  ANKIWEB_USERNAME=/ANKIWEB_PASSWORD= 두 줄 파일. 없으면 로그인하지 않는다.
  ANKI_HOST_STATE_DIR         인스턴스 상태 디렉터리. /export·/import-colpkg는 그 아래
                              `backups/`(일일 백업 스테이징, 정리 대상)와 `restore-points/`
                              (복구점 — 생산자·보존 규칙은 PR 2b)만 허용한다.
  ANKI_HOST_ADDON_VERSION     패키지 버전(nix 파생 version과 같은 값) — /status에 노출.
  ANKI_HOST_MAIN_TIMEOUT_SECS 메인 스레드 작업 타임아웃(필수 — 기본값 없음). 타임아웃 사다리의 가장
                              안쪽 값이며 스크립트 curl·systemd 유닛 값은 이 값에서 파생된다(default.nix).
  ANKI_HOST_ALLOW_IMPORT      "1"이면 /import-colpkg를 연다. 모듈이 AnkiWeb sync를 켜지 않은 인스턴스
                              (격리 fixture용)에만 넣는다 — 운영 인스턴스에는 라우팅 자체가 없다.
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

ADDON_VERSION = os.environ.get("ANKI_HOST_ADDON_VERSION") or "unknown"
BIND = "127.0.0.1"
PORT = int(os.environ.get("ANKI_HOST_HELPER_PORT", "0") or "0")
CRED_FILE = os.environ.get("ANKI_HOST_SYNC_CREDENTIALS") or None
STATE_DIR = os.environ.get("ANKI_HOST_STATE_DIR") or None
ALLOWED_SUBDIRS = ("backups", "restore-points")
MAIN_TIMEOUT_SECS = int(os.environ["ANKI_HOST_MAIN_TIMEOUT_SECS"])  # 단일 소스(constants.ankiHost) — 기본값 없음
ALLOW_IMPORT = os.environ.get("ANKI_HOST_ALLOW_IMPORT") == "1"
QUERY_TIMEOUT_SECS = 120
BUSY_WAIT_SECS = 5
SYNC_MODES = ("normal", "allow-download-if-empty")

ChangesRequired = sync_pb2.SyncCollectionResponse.ChangesRequired
NO_CHANGES = ChangesRequired.NO_CHANGES
FULL_SYNC = ChangesRequired.FULL_SYNC
FULL_DOWNLOAD = ChangesRequired.FULL_DOWNLOAD
FULL_UPLOAD = ChangesRequired.FULL_UPLOAD
# NORMAL_SYNC는 sync_status(파란 버튼 표시)용 값이며 sync_collection의 반환값으로는 오지 않는다.
# 그래서 아래 분기에서 다루지 않고, 혹시 오면 unexpected로 분류한다.

_lock = threading.Lock()  # 컬렉션을 바꾸는 작업의 상호 배제
_busy: str | None = None  # 락을 쥔 작업 이름 (조회 응답과 409 본문에 노출)
_state: dict[str, Any] = {
    "login": {"status": "not-attempted"},
    "last_sync": None,
    "server": None,
    "collection_open": False,
}


class BusyError(RuntimeError):
    def __init__(self, current: str | None) -> None:
        super().__init__("busy")
        self.current = current


def _log(msg: str) -> None:
    # aqt.errors.ErrorHandler가 sys.stderr를 오류 다이얼로그 버퍼로 교체하므로(offscreen에서는 아무도 못 본다)
    # 원본 파일 디스크립터(sys.__stderr__)로 써야 journald에 남는다.
    stream = sys.__stderr__ or sys.stdout
    print(f"[anki_host_sync] {msg}", file=stream, flush=True)


def _log_exc(context: str) -> None:
    stream = sys.__stderr__ or sys.stdout
    print(f"[anki_host_sync] {context} failed:", file=stream, flush=True)
    traceback.print_exc(file=stream)
    stream.flush()


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


def _require_col() -> None:
    if aqt.mw is None or aqt.mw.col is None:
        raise RuntimeError("collection-not-open")


def _mutating(name: str, fn: Callable[..., Any], *args: Any) -> Any:
    """변경 작업 상호 배제. 다른 작업이 BUSY_WAIT_SECS 안에 끝나지 않으면 BusyError(→ 409)."""
    global _busy
    if not _lock.acquire(timeout=BUSY_WAIT_SECS):
        raise BusyError(_busy)
    try:
        _busy = name
        return _on_main(fn, *args)
    finally:
        _busy = None
        _lock.release()


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
    """syncKey가 없을 때만 AnkiWeb에 로그인해 프로필에 저장한다. 비밀번호는 메모리에만 머문다.

    자격 파일을 나중에 채웠다면 서비스 재시작으로 이 훅을 다시 태운다 (계획 Step 14).
    """
    _require_col()
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
    _require_col()
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
    _require_col()
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


def _full_download(auth: Any, out: Any) -> None:
    mw = aqt.mw
    mw.col.close_for_full_sync()
    try:
        mw.col.full_upload_or_download(auth=auth, server_usn=out.server_media_usn, upload=False)
    finally:
        mw.col.reopen(after_full_sync=True)
    mw.reset()
    if mw.pm.media_syncing_enabled():
        mw.col.sync_media(mw.pm.sync_auth())


def _sync(mode: str) -> dict[str, Any]:
    """mode: normal | allow-download-if-empty.

    normal: 병합 가능한 변경만 동기화하고 full sync가 요구되면 아무것도 하지 않는다 (타이머·MCP 기본).
    allow-download-if-empty: 로컬이 비어 있을 때(노트 0·복습 기록 0)만 서버본을 내려받는다 (첫 부트스트랩 유닛).
    서버를 덮어쓰는 방향은 이 애드온에 없다 — 복구점 복원은 Mac GUI 경로다(plan 030 Maintenance notes).
    """
    _require_col()
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
            _full_download(auth, out)
            action = "full-download"
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
        "empty_before": empty,
        "server_message": out.server_message or "",
        "before": before,
        "after": after,
    }
    _state["last_sync"] = result
    _log(f"sync mode={mode} required={required} action={action}")
    return result


# ── 내보내기·가져오기 (복구점·백업·fixture) ─────────────────────────────────


def _checked_path(path: str) -> str:
    """STATE_DIR 아래 허용 하위 디렉터리(backups/, restore-points/) 안의 경로만 통과시킨다."""
    if not STATE_DIR:
        raise RuntimeError("state-dir-not-configured")
    real = os.path.realpath(path)
    for sub in ALLOWED_SUBDIRS:
        root = os.path.realpath(os.path.join(STATE_DIR, sub))
        if os.path.commonpath([real, root]) == root and real != root:
            return real
    raise RuntimeError("path-outside-allowed-dirs")


def _export(path: str, include_media: bool, legacy: bool) -> dict[str, Any]:
    _require_col()
    mw = aqt.mw
    real = _checked_path(path)
    if os.path.exists(real):
        # 새 파일만 만든다 — 아직 HDD로 미러되지 않은 복구점을 같은 이름으로 덮어쓰는 것은 되돌릴 수 없다
        raise RuntimeError("target-exists")
    os.makedirs(os.path.dirname(real), exist_ok=True)
    snap = _snapshot()
    # export_collection_package는 내부에서 close_for_full_sync 후 backend가 컬렉션을 가져가 내보낸다.
    # 끝나면 backend에 열린 컬렉션이 없으므로 reopen(after_full_sync=False)로 다시 연다 (aqt exporting과 같은 순서).
    try:
        mw.col.export_collection_package(out_path=real, include_media=include_media, legacy=legacy)
    finally:
        mw.col.reopen(after_full_sync=False)
    mw.reset()
    return {"path": real, "bytes": os.path.getsize(real), "include_media": include_media, "legacy": legacy, "counts": snap}


def _import_colpkg(path: str) -> dict[str, Any]:
    """전체 컬렉션 패키지로 이 프로필을 **교체**한다. 격리 fixture 준비 전용 (로그인된 프로필은 거부)."""
    _require_col()
    mw = aqt.mw
    pm = mw.pm
    real = _checked_path(path)
    if not os.path.isfile(real):
        raise RuntimeError("file-not-found")
    if pm.sync_auth() is not None:
        raise RuntimeError("refusing-import-into-logged-in-profile")
    folder = pm.profileFolder()
    # backend의 import_collection_package는 컬렉션이 백엔드에서 완전히 닫혀 있어야 한다
    # (close_for_full_sync는 pylib 쪽만 닫아 CollectionAlreadyOpen이 난다 — 실측).
    # aqt의 ColpkgImporter가 unloadCollection/loadCollection으로 하는 것과 같은 순서다.
    mw.col.close(downgrade=False)
    try:
        mw.backend.import_collection_package(
            col_path=pm.collectionPath(),
            backup_path=real,
            media_folder=os.path.join(folder, "collection.media"),
            media_db=os.path.join(folder, "collection.media.db2"),
        )
    finally:
        mw.col.reopen(after_full_sync=False)
    mw.reset()
    return {"imported": real, "counts": _snapshot()}


def _status_full() -> dict[str, Any]:
    """메인 스레드에서 채우는 전체 상태 — counts·media 포함. 준비 판정에는 쓰지 않는다(/status가 담당)."""
    from anki.buildinfo import version as anki_version

    if aqt.mw is None or aqt.mw.col is None:
        return {"addon_version": ADDON_VERSION, "anki_version": anki_version, "collection_open": False, "login": _state["login"]}
    pm = aqt.mw.pm
    return {
        "collection_open": True,
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


def _status_quick() -> dict[str, Any]:
    """메인 스레드를 타지 않는 즉시 응답 — 준비 대기·로그인 판정·busy 확인용."""
    return {
        "busy": _busy,
        "addon_version": ADDON_VERSION,
        "collection_open": _state["collection_open"],
        "login": _state["login"],
        "last_sync": _state["last_sync"],
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
            if path == "/status" and self.command == "GET":
                result = _status_quick()
            elif path == "/status/full" and self.command == "GET":
                if _busy is not None:
                    raise BusyError(_busy)
                result = _on_main(_status_full, timeout=QUERY_TIMEOUT_SECS)
            elif path == "/sync" and self.command == "POST":
                mode = str(body.get("mode", "normal"))
                if mode not in SYNC_MODES:
                    raise ValueError("unknown-mode")
                result = _mutating("sync", _sync, mode)
                result["media"] = _wait_media(float(body.get("wait_media_secs", 0)))
            elif path == "/export" and self.command == "POST":
                result = _mutating(
                    "export",
                    _export,
                    str(body["path"]),
                    bool(body.get("include_media", True)),
                    bool(body.get("legacy", True)),
                )
            elif path == "/import-colpkg" and self.command == "POST" and ALLOW_IMPORT:
                result = _mutating("import-colpkg", _import_colpkg, str(body["path"]))
            else:
                self._reply(404, {"ok": False, "error": "not-found"})
                return
            self._reply(200, {"ok": True, "result": result})
        except BusyError as err:
            self._reply(409, {"ok": False, "error": "busy", "busy": err.current})
        except Exception as err:  # noqa: BLE001
            _log_exc(f"{self.command} {path}")
            self._reply(500, {"ok": False, "error": str(err) or err.__class__.__name__, "type": err.__class__.__name__})


def _start_server() -> None:
    if _state["server"] is not None or PORT <= 0:
        return
    server = ThreadingHTTPServer((BIND, PORT), _Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, name="anki_host_sync-http", daemon=True)
    thread.start()
    _state["server"] = server
    _log(f"helper {ADDON_VERSION} listening on {BIND}:{PORT}")


def _on_profile_open() -> None:
    _state["collection_open"] = True
    try:
        _state["login"] = _ensure_login()
        _log(f"profile '{aqt.mw.pm.name}' open, login: {_state['login'].get('status')}")
    except Exception:  # noqa: BLE001 — 훅 예외는 Anki가 삼키고 훅을 제거하므로 여기서 남긴다
        _log_exc("profile_did_open")
        _state["login"] = {"status": "hook-error", "at": _now()}


def _on_profile_close() -> None:
    _state["collection_open"] = False


gui_hooks.profile_did_open.append(_on_profile_open)
gui_hooks.profile_will_close.append(_on_profile_close)

# 서버는 애드온 import 시점에 연다. 프로필이 아직 열리지 않았으면 /status가 collection_open=false를
# 돌려주고 나머지 엔드포인트는 collection-not-open 오류를 낸다.
try:
    _start_server()
except Exception:  # noqa: BLE001
    _log_exc("start_server")
