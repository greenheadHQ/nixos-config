"""Headless Anki sync and journaled MCP operations on one main-thread lock.

Every HTTP route requires an instance-specific runtime credential. AnkiConnect
HTTP exposes authenticated reads; mutations use this helper's operation allowlist.
Maintenance credentials can sync/export; only root's schema credential plus an
unexpired, consumed-once approval can authorize a structural change and Upload.
Normal sync retains its count-loss guard and never chooses full sync direction.

Quick status is an authenticated in-memory projection. Collection queries and
mutations run on the Anki main thread; a timed-out mutation holds its lock until
its callback actually finishes. Runtime limits come from constants.ankiHost via
the Nix service environment. No secret values are packaged in the Nix store.
"""

from __future__ import annotations

import json
import os
import base64
import hashlib
import stat
import subprocess
import sys
import threading
import time
import traceback
from concurrent.futures import Future
from concurrent.futures import TimeoutError as FutureTimeoutError
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable

import aqt
from anki import sync_pb2
from aqt import gui_hooks

from .access import Access
from .operation_adapter import AnkiAdapter
from .operations import Operations, OperationError, digest, filename, identifier
from .schema import SchemaOperations

ADDON_VERSION = os.environ.get("ANKI_HOST_ADDON_VERSION") or "unknown"
BIND = "127.0.0.1"
PORT = int(os.environ.get("ANKI_HOST_HELPER_PORT", "0") or "0")
CRED_FILE = os.environ.get("ANKI_HOST_SYNC_CREDENTIALS") or None
STATE_DIR = os.environ.get("ANKI_HOST_STATE_DIR") or None
ALLOWED_SUBDIRS = ("backups", "restore-points")
# 타임아웃 값은 전부 단일 소스(constants.ankiHost)에서 env로 온다 — 기본값 없음
MAIN_TIMEOUT_SECS = int(os.environ["ANKI_HOST_MAIN_TIMEOUT_SECS"])
BUSY_WAIT_SECS = int(os.environ["ANKI_HOST_BUSY_WAIT_SECS"])
QUERY_TIMEOUT_SECS = int(os.environ["ANKI_HOST_QUERY_TIMEOUT_SECS"])
GUARD_MIN_RETAIN_PCT = int(os.environ["ANKI_HOST_GUARD_MIN_RETAIN_PCT"])
ALLOW_IMPORT = os.environ.get("ANKI_HOST_ALLOW_IMPORT") == "1"
OPERATION_TTL = int(os.environ["ANKI_HOST_OPERATION_TTL_SECS"])
BULK_LIMIT = int(os.environ["ANKI_HOST_BULK_LIMIT"])
MEDIA_LIMIT = int(os.environ["ANKI_HOST_MEDIA_MAX_BYTES"])
BODY_LIMIT = int(os.environ["ANKI_HOST_BODY_MAX_BYTES"])
BODY_TIMEOUT = int(os.environ["ANKI_HOST_BODY_TIMEOUT_SECS"])
MAX_REQUESTS = int(os.environ["ANKI_HOST_MAX_REQUESTS"])
INSTANCE = os.environ["ANKI_HOST_INSTANCE"]
MIRROR_TIMEOUT = int(os.environ["ANKI_HOST_MIRROR_TIMEOUT_SECS"])
ACCESS = Access(os.environ["CREDENTIALS_DIRECTORY"])
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
_operations: Operations | None = None


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


def _submit(fn: Callable[..., Any], *args: Any) -> Future:
    """Anki 컬렉션은 메인 스레드에서만 만진다. 작업을 메인 스레드 큐에 넣고 Future를 돌려준다."""
    fut: Future = Future()

    def run() -> None:
        try:
            fut.set_result(fn(*args))
        except BaseException as err:  # noqa: BLE001 — 호출자에게 그대로 전달
            fut.set_exception(err)

    aqt.mw.taskman.run_on_main(run)
    return fut


def _on_main(fn: Callable[..., Any], *args: Any, timeout: float = MAIN_TIMEOUT_SECS) -> Any:
    return _submit(fn, *args).result(timeout=timeout)


def _require_col() -> None:
    if aqt.mw is None or aqt.mw.col is None:
        raise RuntimeError("collection-not-open")


def _release_mutation() -> None:
    global _busy
    _busy = None
    _lock.release()


def _mutating(name: str, fn: Callable[..., Any], *args: Any) -> Any:
    """변경 작업 상호 배제. 다른 작업이 BUSY_WAIT_SECS 안에 끝나지 않으면 BusyError(→ 409).

    메인 스레드에 넘긴 작업은 취소할 수 없으므로, 타임아웃으로 호출자에게는 실패를 돌려주더라도 락과 busy는
    그 작업이 실제로 끝날 때까지 유지한다 — 재시도·다른 변경 작업이 아직 도는 작업과 겹쳐 컬렉션·AnkiWeb을
    두 번 만지는 일을 막는다. 그동안 다른 호출은 409(busy = "<name>:timed-out")를 받는다.
    """
    global _busy
    if not _lock.acquire(timeout=BUSY_WAIT_SECS):
        raise BusyError(_busy)
    _busy = name
    fut = _submit(fn, *args)
    try:
        result = fut.result(timeout=MAIN_TIMEOUT_SECS)
    except FutureTimeoutError:
        _busy = f"{name}:timed-out"
        fut.add_done_callback(lambda _f: _release_mutation())
        _log(f"{name} exceeded {MAIN_TIMEOUT_SECS}s on the main thread — lock held until it finishes")
        raise RuntimeError("main-thread-timeout") from None
    except BaseException:
        _release_mutation()
        raise
    _release_mutation()
    return result


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
    # 계정 식별자(username)는 _state에 두지 않는다 — /status·/status/full은 무인증 응답이다 (plan 030 결정 10)
    pm = aqt.mw.pm
    if pm.sync_auth() is not None:
        return {"status": "already-logged-in"}
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
    return {"status": "logged-in", "at": _now()}


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





# ── 동기화 ────────────────────────────────────────────────────────────────


def _configure_headless_sync() -> None:
    # The GUI media monitor consumes a backend error only once. Keep the host
    # helper as the sole sync/monitor owner, including already-created profiles.
    pm = aqt.mw.pm
    if pm.auto_syncing_enabled() or pm.periodic_sync_media_minutes() != 0:
        pm.profile["autoSync"] = False
        pm.set_periodic_sync_media_minutes(0)
        pm.save()


def _wait_for_media(deadline: float, *, previous: bool = False) -> None:
    # Runs inside the main-thread mutation callback. Do not process Qt events or
    # start MediaSyncer: another consumer could take a completed backend error.
    while True:
        try:
            status = aqt.mw.col.media_sync_status()
        except Exception as err:
            if not previous:
                raise
            # The old thread has ended; the new sync below retries its transfer.
            _log(f"previous media sync failed: {type(err).__name__}; retrying")
            return
        if not status.active:
            return
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("media-sync-timeout")
        time.sleep(min(0.25, remaining))


def _full_download(auth: Any, out: Any) -> None:
    """빈 로컬에 서버 컬렉션을 통째로 내려받는다 (부트스트랩 전용 — 서버를 덮어쓰는 방향은 없다).

    순서는 aqt.sync.full_download와 같다: close_for_full_sync로 pylib 쪽만 닫아 backend가 DB 파일을 교체하게 하고,
    reopen(after_full_sync=True)로 backend가 새로 연 컬렉션을 다시 붙인다 (export/import의 after_full_sync=False와
    다른 이유). finally인 이유: 다운로드가 실패해도 컬렉션을 다시 열어야 다음 호출이 collection-not-open으로 죽지 않는다.
    미디어는 크기 때문에 백그라운드(sync_media)로 넘기고 완료를 기다리지 않는다 — 진행은 /status/full의 media로 본다.
    """
    mw = aqt.mw
    mw.col.close_for_full_sync()
    try:
        mw.col.full_upload_or_download(auth=auth, server_usn=out.server_media_usn, upload=False)
    finally:
        mw.col.reopen(after_full_sync=True)
    mw.reset()
    if mw.pm.media_syncing_enabled():
        mw.col.sync_media(mw.pm.sync_auth())


def _guard_thresholds() -> tuple[int, int]:
    """급감 게이트 하한 — sync 스크립트가 남기는 상태 파일(STATE_DIR/sync-status.json)의 lastSuccessAt·lastSuccessCounts에서
    계산한다. 스크립트가 유일한 생산자이고 이 함수는 두 필드만 읽는다. 성공 이력이 없거나 파일이 없으면 (0, 0) = 게이트 없음.
    성공 이력이 있으면 하한은 최소 1 — 전부 지워진 컬렉션도 게이트에 걸려야 한다."""
    if not STATE_DIR:
        return (0, 0)
    try:
        with open(os.path.join(STATE_DIR, "sync-status.json"), encoding="utf-8") as stream:
            state = json.load(stream)
    except (OSError, ValueError):
        return (0, 0)
    if not state.get("lastSuccessAt"):
        return (0, 0)
    counts = state.get("lastSuccessCounts") or {}

    def floor_pct(value: Any) -> int:
        n = int(value or 0)
        return max(1, n * GUARD_MIN_RETAIN_PCT // 100) if n > 0 else 0

    return (floor_pct(counts.get("notes")), floor_pct(counts.get("revlog")))


def _sync(mode: str) -> dict[str, Any]:
    """mode: normal | allow-download-if-empty.

    normal: 병합 가능한 변경만 동기화하고 full sync가 요구되면 아무것도 하지 않는다 (타이머·MCP 기본).
    allow-download-if-empty: 로컬이 비어 있을 때(노트 0·복습 기록 0)만 서버본을 내려받는다 (첫 부트스트랩 유닛).
    서버를 덮어쓰는 방향은 이 애드온에 없다 — 복구점 복원은 Mac GUI 경로다(plan 030 Maintenance notes).
    급감 게이트: 상태 파일의 직전 성공 스냅샷에서 계산한 하한(_guard_thresholds)이 하나라도 0보다 크면 로컬이 그 아래일 때
    sync_collection을 부르지 않는다 — 호출 전 판정이라 서버에 아무것도 올라가지 않는다. 빈 컬렉션도 예외가 아니다: AnkiConnect로
    전부 지운 컬렉션은 full sync 요구 없이 증분 sync로 삭제가 AnkiWeb에 전파되므로 비었다는 이유로 게이트를 건너뛰면 안 된다.
    하한이 둘 다 0이면(첫 부트스트랩 전, 복원 절차로 상태 파일을 지운 뒤) 게이트가 없다.
    """
    _require_col()
    # CIR: Collection and both media waits share the existing mutation budget.
    # A timeout leaves delivery unconfirmed; it must not become normal success.
    deadline = time.monotonic() + MAIN_TIMEOUT_SECS
    mw = aqt.mw
    pm = mw.pm
    auth = pm.sync_auth()
    if auth is None:
        raise RuntimeError("not-logged-in")
    before = _snapshot()
    empty = before["notes"] == 0 and before["revlog"] == 0
    min_notes, min_revlog = _guard_thresholds()
    if (min_notes > 0 or min_revlog > 0) and (before["notes"] < min_notes or before["revlog"] < min_revlog):
        result = {
            "at": _now(),
            "mode": mode,
            "required": None,
            "action": "guard-tripped",
            "empty_before": empty,
            "server_message": "",
            "before": before,
            "after": before,
            "guard": {"min_notes": min_notes, "min_revlog": min_revlog},
        }
        _state["last_sync"] = result
        _log(f"sync mode={mode} action=guard-tripped notes={before['notes']}<{min_notes} or revlog={before['revlog']}<{min_revlog}")
        return result
    media_enabled = pm.media_syncing_enabled()
    media_state = "disabled" if not media_enabled else "not-started"
    if media_enabled:
        if (pm.auto_syncing_enabled() or pm.periodic_sync_media_minutes() != 0
                or mw.media_syncer.is_syncing()):
            raise OperationError("media-sync-monitor-not-exclusive")
        # sync_collection reuses an active media thread. Drain it first so the
        # new transfer definitely includes files saved before this invocation.
        _wait_for_media(deadline, previous=True)
    out = mw.col.sync_collection(auth, media_enabled)
    if out.new_endpoint:
        pm.set_current_sync_url(out.new_endpoint)
        pm.save()
        auth = pm.sync_auth()
    # 호출자(anki-host-sync.sh)와의 계약 값 둘 — required(서버 판정)·action(이 함수의 결정). 둘 다 이 층위에서 항상 바인딩된다
    required = ChangesRequired.Name(out.required)
    action: str  # normal | full-download | full-sync-required | unexpected:*  (guard-tripped는 위에서 먼저 반환)
    if out.required == NO_CHANGES:
        if media_enabled:
            _wait_for_media(deadline)
            media_state = "synced"
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
        "media": {"state": media_state},
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
        "bridge_error": _state.get("bridge_error"),
        "anki_version": anki_version,
        "profile": pm.name,
        "logged_in": pm.sync_auth() is not None,
        # 계정 식별자(syncUser)는 상태 응답에 싣지 않는다 — /status와 같은 경계 판정 (plan 결정 10)
        "media_syncing_enabled": pm.media_syncing_enabled(),
        "login": _state["login"],
        "last_sync": _state["last_sync"],
        "counts": _snapshot(),
        "media": _media_status(),
    }


def _status_quick() -> dict[str, Any]:
    """메인 스레드를 타지 않는 즉시 응답 — 준비 대기·로그인 판정·busy 확인용.

    빠른 상태 응답은 필요한 정보로 투영을 좁힌다: login은 status·at·error만(username 제외), last_sync는 시각·모드·결과만
    (덱 이름·카운트 제외). 상세는 /status/full.
    """
    login = _state["login"]
    last = _state["last_sync"]
    return {
        "busy": _busy,
        "addon_version": ADDON_VERSION,
        "bridge_error": _state.get("bridge_error"),
        "collection_open": _state["collection_open"],
        "login": {k: login[k] for k in ("status", "at", "error") if k in login},
        "last_sync": None if last is None else {k: last.get(k) for k in ("at", "mode", "action", "required")},
    }


# ── MCP operations ──────────────────────────────────────────────────────


def _restore_point(operation_id: str) -> dict[str, Any]:
    operation_id = identifier(operation_id)
    path = Path(STATE_DIR) / "restore-points" / (operation_id + ".colpkg")
    receipt_path = path.with_suffix(".receipt.json")
    if not path.exists():
        _export(str(path), include_media=False, legacy=False)
    # The root mirror unit only copies files; it must never call the main-thread
    # HTTP helper while this callback is waiting for the mirror to finish.
    proc = subprocess.run(["systemctl", "start", f"anki-host-mirror-{INSTANCE}@{operation_id}.service"],
                          capture_output=True, timeout=MIRROR_TIMEOUT)
    if proc.returncode != 0:
        raise OperationError("restore-point-mirror-failed")
    st = receipt_path.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022:
        raise OperationError("restore-point-receipt-invalid")
    receipt = json.loads(receipt_path.read_text())
    if (receipt.get("operation_id") != operation_id or receipt.get("instance") != INSTANCE
            or receipt.get("mirrored") is not True or not receipt.get("sha256")):
        raise OperationError("restore-point-receipt-mismatch")
    return receipt


def _ops() -> Operations:
    global _operations
    _require_col()
    if _operations is None:
        _operations = Operations(Path(STATE_DIR) / "operations", AnkiAdapter(aqt.mw, MEDIA_LIMIT), _restore_point,
                                 ttl=OPERATION_TTL, bulk_limit=BULK_LIMIT, media_limit=MEDIA_LIMIT)
    return _operations


def _collection_identity() -> dict[str, Any]:
    """Fingerprint all collection data, including modern binary config tables."""
    _require_col()
    col = aqt.mw.col
    # Anki lazily persists localOffset/rollover on the first scheduler query.
    # Export's count snapshot makes that query too; normalize before hashing so
    # a pristine collection does not invalidate its own verified backup.
    _ = col.sched.day_cutoff
    tables = sorted(set(col.db.list("select name from sqlite_master where type='table'")) & {
        "col", "notes", "cards", "revlog", "graves", "notetypes", "fields", "templates",
        "decks", "deck_config", "config", "tags"})
    hashes = {}
    for table in tables:
        rows = [[{"bytes": value.hex()} if isinstance(value, bytes) else value for value in row]
                for row in col.db.all(f'select * from "{table}"')]
        hashes[table] = digest(sorted(rows, key=lambda row: json.dumps(row, sort_keys=True)))
    return {"digest": digest(hashes), "counts": {
        "notes": col.note_count(), "cards": col.card_count(),
        "revlog": col.db.scalar("select count() from revlog")}}


def _last_success_counts() -> dict[str, Any]:
    try:
        state = json.loads((Path(STATE_DIR) / "sync-status.json").read_text())
    except (OSError, ValueError):
        raise OperationError("last-success-counts-unavailable") from None
    if not state.get("lastSuccessAt"):
        raise OperationError("last-success-counts-unavailable")
    return state.get("lastSuccessCounts") or {}


def _approved_schema_sync(before: dict[str, Any]) -> dict[str, Any]:
    mw = aqt.mw
    auth = mw.pm.sync_auth()
    if auth is None:
        raise OperationError("not-logged-in")
    out = mw.col.sync_collection(auth, mw.pm.media_syncing_enabled())
    if out.new_endpoint:
        mw.pm.set_current_sync_url(out.new_endpoint)
        mw.pm.save()
        auth = mw.pm.sync_auth()
    required = ChangesRequired.Name(out.required)
    action = "schema-sync-blocked"
    if out.required == NO_CHANGES:
        action = "normal"
    elif out.required in (FULL_SYNC, FULL_UPLOAD):
        # The caller checked exact approval, backup and loss gates under the same
        # helper lock immediately before reaching this code.
        mw.col.close_for_full_sync()
        try:
            server_usn = out.server_media_usn if mw.pm.media_syncing_enabled() else None
            mw.col.full_upload_or_download(auth=auth, server_usn=server_usn, upload=True)
        finally:
            mw.col.reopen(after_full_sync=True)
        mw.reset()
        action = "approved-full-upload"
    # FULL_DOWNLOAD is deliberately left blocked, regardless of root approval.
    result = {"at": _now(), "mode": "approved-schema", "required": required, "action": action,
              "before": before, "after": _snapshot(), "empty_before": False, "server_message": ""}
    _state["last_sync"] = result
    return result


def _schema() -> SchemaOperations:
    return SchemaOperations(_ops(), INSTANCE, Path(STATE_DIR) / "approvals", _collection_identity,
                            _last_success_counts, _approved_schema_sync)


def _deck_options(name: str) -> dict[str, Any]:
    result = AnkiAdapter(aqt.mw, MEDIA_LIMIT).deck_options(name)
    result.pop("config")
    return result


def _media(body: dict[str, Any]) -> dict[str, Any]:
    _require_col()
    if body.get("filename") is None:
        contains = body.get("contains", "")
        limit, offset = body.get("limit", 20), body.get("offset", 0)
        if (not isinstance(contains, str) or type(limit) is not int or not 1 <= limit <= 100
                or type(offset) is not int or offset < 0):
            raise OperationError("invalid-media-page")
        names = sorted(n for n in AnkiAdapter(aqt.mw, MEDIA_LIMIT).ac.getMediaFilesNames(pattern="*") if contains in n)
        return {"files": names[offset:offset + limit], "total": len(names),
                "next_offset": offset + limit if offset + limit < len(names) else None}
    name = filename(body["filename"])
    path = Path(aqt.mw.col.media.dir()) / name
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError as err:
        raise OperationError("media-not-found") from err
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > MEDIA_LIMIT:
            raise OperationError("media-too-large-or-not-regular")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            data = stream.read(MEDIA_LIMIT + 1)
        if len(data) > MEDIA_LIMIT:
            raise OperationError("media-too-large")
    finally:
        os.close(fd)
    return {"filename": name, "data": base64.b64encode(data).decode(), "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest()}


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
        if self.headers.get("Transfer-Encoding") or length < 0 or length > BODY_LIMIT:
            raise OperationError("request-body-too-large-or-unsupported")
        if length <= 0:
            return {}
        self.connection.settimeout(BODY_TIMEOUT)
        raw = self.rfile.read(length)
        if len(raw) != length:
            raise OperationError("incomplete-request-body")
        data = json.loads(raw.decode("utf-8"))
        if not isinstance(data, dict):
            raise OperationError("request-body-must-be-an-object")
        return data

    def do_GET(self) -> None:  # noqa: N802
        self._route()

    def do_POST(self) -> None:  # noqa: N802
        self._route()

    def _route(self) -> None:
        path = self.path.split("?", 1)[0]
        try:
            role = ACCESS.role(self.headers.get("Authorization"))
            if role is None:
                self._reply(401, {"ok": False, "error": "local-authentication-required"})
                return
            if not ACCESS.allowed(self.command, path, role):
                self._reply(403, {"ok": False, "error": "role-not-allowed"})
                return
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
            elif path == "/operations/prepare" and self.command == "POST":
                result = _mutating("prepare", lambda: _ops().prepare(body["action"], body["params"], body.get("request_id")))
            elif path == "/operations/apply" and self.command == "POST":
                result = _mutating("apply", lambda: _ops().apply(body["operation_id"], body["preview_token"], body.get("confirm", False)))
            elif path == "/operations/status" and self.command == "POST":
                # Atomic journal reads need no Anki call and still work during a
                # timed-out operation. Initialization waits for collection ready.
                if _operations is None:
                    raise OperationError("collection-not-ready")
                result = _operations.status(body["operation_id"])
            elif path == "/operations/history" and self.command == "POST":
                if _operations is None:
                    raise OperationError("collection-not-ready")
                result = _operations.history(body.get("limit", 20), body.get("offset", 0))
            elif path == "/operations/delivery" and self.command == "POST":
                result = _mutating("delivery", lambda: _ops().record_delivery(body["operation_id"], body["kind"], body["receipt"]))
            elif path == "/schema/inspect" and self.command == "POST":
                result = _mutating("schema-inspect", lambda: _schema().inspect(body["operation_id"]))
            elif path == "/schema/backup" and self.command == "POST":
                result = _mutating("schema-backup", lambda: _schema().backup(body["operation_id"]))
            elif path == "/schema/apply" and self.command == "POST":
                result = _mutating("schema-apply", lambda: _schema().apply(body["operation_id"]))
            elif path == "/deck-options" and self.command == "POST":
                result = _mutating("deck-options", _deck_options, str(body["deck_name"]))
            elif path == "/model-info" and self.command == "POST":
                result = _mutating("model-info", lambda: AnkiAdapter(aqt.mw, MEDIA_LIMIT).model_info(str(body["model_name"])))
            elif path == "/media" and self.command == "POST":
                result = _mutating("media", _media, body)
            else:
                self._reply(404, {"ok": False, "error": "not-found"})
                return
            self._reply(200, {"ok": True, "result": result})
        except BusyError as err:
            self._reply(409, {"ok": False, "error": "busy", "busy": err.current})
        except OperationError as err:
            self._reply(400, {"ok": False, "error": str(err)})
        except Exception as err:  # noqa: BLE001
            # Upstream exceptions can include note contents or request values.
            _log(f"{self.command} {path} failed: {err.__class__.__name__}")
            self._reply(500, {"ok": False, "error": err.__class__.__name__})


class _Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, *args: Any) -> None:
        self.slots = threading.BoundedSemaphore(MAX_REQUESTS)
        super().__init__(*args)

    def process_request(self, request: Any, client_address: Any) -> None:
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        request.settimeout(BODY_TIMEOUT)
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request: Any, client_address: Any) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def _start_server() -> None:
    if _state["server"] is not None or PORT <= 0:
        return
    server = _Server((BIND, PORT), _Handler)
    thread = threading.Thread(target=server.serve_forever, name="anki_host_sync-http", daemon=True)
    thread.start()
    _state["server"] = server
    _log(f"helper {ADDON_VERSION} listening on {BIND}:{PORT}")


def _on_profile_open() -> None:
    # collection_open은 로그인 판정이 끝난 뒤에 세운다 — /status 즉시 응답에서 "준비됨"이 곧 "login.status 확정"이어야
    # 준비 대기(anki_helper_wait_ready)와 로그인 판정이 같은 응답을 안전하게 공유한다 (로그인 진행 중 창 제거).
    try:
        _configure_headless_sync()
        _state["login"] = _ensure_login()
        _log(f"profile '{aqt.mw.pm.name}' open, login: {_state['login'].get('status')}")
    except Exception:  # noqa: BLE001 — 훅 예외는 Anki가 삼키고 훅을 제거하므로 여기서 남긴다
        _log_exc("profile_did_open")
        _state["login"] = {"status": "hook-error", "at": _now()}
    finally:
        try:
            AnkiAdapter(aqt.mw, MEDIA_LIMIT).check_bridge()
            _ops()
            _state["collection_open"] = True
            _state.pop("bridge_error", None)
        except Exception:
            _state["collection_open"] = False
            _state["bridge_error"] = "anki-connect-bridge-unavailable"
            _log("profile readiness blocked: AnkiConnect bridge unavailable or incompatible")


def _on_profile_close() -> None:
    global _operations
    _operations = None
    _state["collection_open"] = False


gui_hooks.profile_did_open.append(_on_profile_open)
gui_hooks.profile_will_close.append(_on_profile_close)

# 서버는 애드온 import 시점에 연다. 프로필이 아직 열리지 않았으면 /status가 collection_open=false를
# 돌려주고 나머지 엔드포인트는 collection-not-open 오류를 낸다.
try:
    _start_server()
except Exception:  # noqa: BLE001
    _log_exc("start_server")
