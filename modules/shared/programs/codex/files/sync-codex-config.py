#!/usr/bin/env python3
"""Merge repo template into ~/.codex/config.toml and check for drift.

USAGE
-----
- `sync-codex-config.py <template> <target>`               -> merge mode (backward compat)
- `sync-codex-config.py sync <template> <target>`          -> merge mode (explicit)
- `sync-codex-config.py check <template> <target>`         -> read-only drift check

OWNERSHIP POLICY (recursive, leaf-level)
----------------------------------------
* Template-owned leaves: every leaf key the template defines, including leaves
  nested inside template-declared tables (e.g. `[features].voice_transcription`,
  `[plugins."github@openai-curated"].enabled`). These are (re-)applied from the
  template on each activation, and compared by `check` mode.
* User-owned: everything the template does NOT declare at the same path —
  sibling leaves inside the same table, and any top-level key absent from the
  template (`[projects.*]`, future Codex CLI tables). Preserved verbatim.

On a same-path conflict the template ALWAYS wins. Checker and writer share the
`_walk_template_leaves` iterator so their ownership judgement cannot drift.

JSON OUTPUT SCHEMA (check mode)
-------------------------------
    {
      "template": "<template file path>",
      "target": "<target file path>",
      "target_state": "present" | "missing",
      "drift": [
        {"path": "model", "reason": "value_mismatch", "expected": "...", "actual": "..."},
        ...
      ]
    }

`target_state="missing"` always pairs with `drift=[]` (file-level, not leaf-level).
Hard errors (template missing/parse error, target parse error) produce no JSON
and exit with EXIT_ERROR.

REASON ENUM (leaf-only, 3 values)
---------------------------------
  missing_leaf    target lacks the template leaf path (actual == null)
  value_mismatch  both sides have the leaf, values differ
  type_mismatch   both sides have the leaf, types differ

EXIT CODES
----------
  EXIT_OK    = 0  target_state="present" AND drift=[]
  EXIT_DRIFT = 1  target_state="present" AND drift!=[]  OR  target_state="missing"
  EXIT_ERROR = 2  template missing/parse failure, target parse failure
                  (JSON not emitted; stderr carries a human-readable reason)

ATOMIC WRITE (sync mode)
------------------------
Write is atomic (tempfile + os.replace) so a codex process reading the file
concurrently sees either the old or new content, never a partial merge.

If the existing target can be read but is malformed TOML / invalid UTF-8, it is
quarantined to <target>.bad-<ts> and regenerated from the template — a stray
hand-edit must not brick the whole home-manager generation. The same quarantine
path also handles legacy structural states that cannot be read as a regular
file: ``ELOOP`` (symlink loops), ``EISDIR`` (directories or
symlinks-to-directories), and any non-regular ``stat`` result (FIFO, socket,
block/char device, symlink-to-special-file detected via the pre-read
``path.stat()`` check). The generation does not abort just because the target
has drifted from its regular-file invariant. Hard read failures that indicate
permission/I/O problems on a real file (``EACCES``/``EPERM``/``EIO``) still
abort, because silently replacing an unreadable regular file would destroy
user trust and MCP data — except when the path itself is a symlink, in which
case the entry is treated as legacy and quarantined regardless of the
referent's errno.

Symlink semantics: a symlink whose referent is a *readable regular file* is
followed by ``path.read_bytes()``; that referent's user-owned sections (e.g.
``[mcp_servers.*]``, ``[projects.*]``) are merged with the template and
written into the new regular ``~/.codex/config.toml``. The symlink itself is
then replaced via ``os.replace`` in ``write_atomic`` (the no-op probe sees
``ELOOP`` through ``O_NOFOLLOW`` and forces the write path). This is intentional
self-heal behavior: legacy symlinks are upgraded to regular files while
preserving their effective contents. If you want a fresh template-only file,
remove the symlink before running sync.

No-op suppression: sync skips the atomic write (and the summary log) only when
three invariants all hold — the target is a regular file (not a symlink), its
mode is exactly 0o600, and its bytes already equal the serialized merge result.
Any of them failing routes back through write_atomic so that legacy symlinks,
mode drift, and content drift are all repaired in a single code path.
"""

from __future__ import annotations

import argparse
import contextlib
import copy
import datetime as _dt
import errno
import fcntl
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterator, NoReturn, Optional

PREFIX = "sync-codex-config"

EXIT_OK = 0
EXIT_DRIFT = 1
EXIT_ERROR = 2

# read failure 정책의 단일 정의 지점.
# - _SELF_HEAL_ERRNOS        : legacy 구조(symlink loop / plain directory /
#                              symlink-to-directory) — quarantine 후 template 재생성.
# - _UNREADABLE_REGULAR_ERRNOS: 일반 파일의 permission / I/O 장애 — abort 하여
#                              데이터 보존. self-heal path 로 보내지 않는다.
# errno 분류 정책의 authoritative 설명은 모듈 docstring 의 "ATOMIC WRITE (sync mode)"
# 블록(quarantine + self-heal 정책)을 참고한다. "No-op suppression" 블록은 별개로
# regular file/0o600/byte-identical 3조건만 다룬다.
_SELF_HEAL_ERRNOS = (errno.ELOOP, errno.EISDIR)
_UNREADABLE_REGULAR_ERRNOS = (errno.EACCES, errno.EPERM, errno.EIO)


def _errno_tag(e: OSError) -> str:
    # `errno=13/EACCES` 처럼 숫자 + 심볼명을 한 토큰으로 묶어 stderr/quarantine reason 의
    # read-failure 메시지 포맷을 단일화한다.
    return f"errno={e.errno}/{errno.errorcode.get(e.errno, '?')}"


def log(msg: str) -> None:
    print(f"{PREFIX}: {msg}", file=sys.stderr)


def die(msg: str, code: int = EXIT_ERROR) -> NoReturn:
    log(msg)
    sys.exit(code)


try:
    import tomlkit
except ImportError:
    # lazy: tomlkit은 sync/check 실제 실행 시점에만 필요하다. argparse만 쓰는 `--help`는
    # tomlkit 없이도 docstring을 출력할 수 있어야 한다.
    tomlkit = None


def _require_tomlkit() -> None:
    if tomlkit is None:
        die("tomlkit module required (nix: pkgs.python3Packages.tomlkit)")


def load_required_toml(path: Path):
    # Template 또는 필수 입력: 모든 실패를 EXIT_ERROR로 통일.
    try:
        data = path.read_bytes()
    except FileNotFoundError:
        die(f"template not found: {path}")
    except OSError as e:
        die(f"cannot read template {path}: {e}")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        die(f"template not valid UTF-8 ({path}): {e}")
    try:
        return tomlkit.parse(text)
    except Exception as e:
        die(f"template parse failed ({path}): {e}")


def load_optional_toml(path: Path, *, quarantine: bool):
    # errno 정책 요약 (단일 정의: _SELF_HEAL_ERRNOS / _UNREADABLE_REGULAR_ERRNOS).
    # 아래 분류는 path.read_bytes() 가 실패한 경우에만 적용된다. 읽기 가능한 symlink/regular
    # 파일은 정상 read 흐름을 타고, 읽기 가능한 symlink 의 regular file 치환은 이후
    # _noop_probe_target 의 ELOOP/symlink detection 경유 write_atomic 에서 수행된다.
    # - ENOENT                                       -> empty document (첫 실행)
    # - _SELF_HEAL_ERRNOS                            -> quarantine 후 template 재생성
    # - 그 외 read 실패 + path.is_symlink()           -> quarantine 후 template 재생성
    #                                                   (legacy symlink referent 상태와 무관)
    # - 그 외 read 실패 (_UNREADABLE_REGULAR_ERRNOS) -> hard fail (regular file 데이터 보존)
    # - UnicodeDecodeError / TOML 오류                -> quarantine 후 empty (self-heal)

    def _quarantine(reason: str):
        # symlink loop 는 path.exists() 가 False 로 돌아오지만 symlink 엔트리 자체는 존재한다.
        # is_symlink() 또는 exists() 중 하나라도 참이면 rename 시도한다.
        if quarantine and (path.is_symlink() or path.exists()):
            # stamp에 PID를 덧붙여 동일 초에 두 activation이 나란히 quarantine할 때도
            # 고유 경로가 되도록 한다 (초 해상도 stamp만으로는 race 발생 가능).
            stamp = _dt.datetime.now().strftime("%Y%m%dT%H%M%S")
            bad = path.with_name(f"{path.name}.bad-{stamp}-{os.getpid()}")
            try:
                path.rename(bad)
                log(
                    f"existing {path} {reason}; quarantined to {bad}, "
                    f"regenerating from template"
                )
            except OSError as mv_err:
                log(
                    f"existing {path} {reason}; quarantine to {bad} "
                    f"also failed ({mv_err}); regenerating in place"
                )
        else:
            log(f"existing {path} {reason}; regenerating from template")
        return tomlkit.document()

    # TOCTOU-safe single-fd inspection + read: symlink 를 follow 한 referent 까지
    # regular file 인지 확인하고 같은 fd 로 read 해야 path re-lookup race 가 사라진다.
    # stat → read_bytes 두 단계 조회는 그 사이 target 이 FIFO/socket 으로 swap 되면 read
    # 가 여전히 block 될 수 있다 (이전 구현의 한계). 여기서는 O_NONBLOCK 으로 open 하여
    # special file 에서도 즉시 open 이 성공하고, fstat S_ISREG 체크가 false 면 read 없이
    # 바로 quarantine 으로 빠진다. O_NOFOLLOW 는 쓰지 않는다 — readable symlink referent
    # 의 내용 import 는 기존 계약(docstring Symlink semantics) 이므로 symlink 는 follow
    # 한다 (special referent 는 fstat 에서 잡힌다).
    fd = None
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_NONBLOCK)
        pre_st = os.fstat(fd)
        if not stat.S_ISREG(pre_st.st_mode):
            kind = oct(stat.S_IFMT(pre_st.st_mode))
            return _quarantine(f"target is not a regular file (st_ifmt={kind})")
        parts: list[bytes] = []
        while True:
            buf = os.read(fd, 65536)
            if not buf:
                break
            parts.append(buf)
        raw = b"".join(parts)
    except FileNotFoundError:
        return tomlkit.document()
    except OSError as e:
        tag = _errno_tag(e)
        if e.errno in _SELF_HEAL_ERRNOS:
            return _quarantine(f"not readable as regular file ({tag})")
        # open 이 실패했지만 direct entry 가 non-regular / non-symlink 이면 self-heal
        # 대상이다. 특히 Unix socket (S_IFSOCK) 은 Linux 에서 open 이 ENXIO 로 실패해
        # _SELF_HEAL_ERRNOS/_UNREADABLE_REGULAR_ERRNOS 어느 분류에도 들어가지 않으므로,
        # errno 대신 lstat 으로 file kind 를 확인해 S_ISREG/S_ISLNK 가 아니면 quarantine.
        try:
            _lst = path.lstat()
        except OSError:
            _lst = None
        if _lst is not None and not (stat.S_ISREG(_lst.st_mode) or stat.S_ISLNK(_lst.st_mode)):
            return _quarantine(f"not readable as regular file ({tag})")
        # symlink 자체가 존재하면 referent의 상태(EACCES/EPERM/EIO 포함)와 무관하게 self-heal.
        # legacy symlink는 원본 referent를 신뢰하지 않고 template으로 재생성하는 것이 안전.
        if path.is_symlink():
            return _quarantine(f"legacy symlink referent not readable ({tag})")
        if e.errno in _UNREADABLE_REGULAR_ERRNOS:
            die(
                f"cannot read existing {path} ({tag}): {e} — refusing to "
                f"overwrite to avoid data loss. Fix permissions then re-run."
            )
        die(f"cannot read existing {path}: {e}")
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        return _quarantine(f"not valid UTF-8 ({e})")
    try:
        return tomlkit.parse(text)
    except Exception as e:
        return _quarantine(f"TOML parse failed ({e})")


def load_target_for_check(path: Path):
    # check 모드 전용. target 부재는 target_state="missing"으로 처리 (drift 아님).
    # 읽기 실패(EACCES 등)와 TOML/UTF-8 파싱 실패는 EXIT_ERROR (writer처럼 quarantine하지 않음).
    # TOCTOU-safe: load_optional_toml 과 동일하게 fd 기반 single open + fstat + read 로
    # path 재조회 race 를 차단한다. cmd_sync self-heal 과 달리 check 는 read-only contract
    # 라 non-regular/unreadable 은 quarantine 하지 않고 die 한다. symlink 는 follow.
    fd = None
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_NONBLOCK)
        pre_st = os.fstat(fd)
        if not stat.S_ISREG(pre_st.st_mode):
            kind = oct(stat.S_IFMT(pre_st.st_mode))
            die(f"target is not a regular file (st_ifmt={kind}): {path}")
        parts: list[bytes] = []
        while True:
            buf = os.read(fd, 65536)
            if not buf:
                break
            parts.append(buf)
        data = b"".join(parts)
    except FileNotFoundError:
        return None
    except OSError as e:
        tag = _errno_tag(e)
        # Unix socket 등 non-regular entry 는 open 이 ENXIO 로 실패할 수 있다. load_optional_toml
        # 과 동일한 lstat 기반 non-regular 감지로 명시적 메시지를 낸다 (check 는 read-only
        # 라 quarantine 없이 die).
        try:
            _lst = path.lstat()
        except OSError:
            _lst = None
        if _lst is not None and not (stat.S_ISREG(_lst.st_mode) or stat.S_ISLNK(_lst.st_mode)):
            kind = oct(stat.S_IFMT(_lst.st_mode))
            die(f"target is not a regular file (st_ifmt={kind}): {path}")
        die(f"cannot read target {path} ({tag}): {e}")
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        die(f"target not valid UTF-8 ({path}): {e}")
    try:
        return tomlkit.parse(text)
    except Exception as e:
        die(f"target parse failed ({path}): {e}")


def as_table_or_warn(value, *, where: str) -> Optional[dict]:
    if value is None:
        return None
    try:
        iter(value.keys())  # type: ignore[attr-defined]
        return value  # type: ignore[return-value]
    except Exception:
        log(f"ignoring {where}: expected a table, got {type(value).__name__}")
        return None


def _is_table(value) -> bool:
    # tomlkit Table / Inline Table / dict는 모두 Mapping 프로토콜을 따른다.
    try:
        value.keys  # type: ignore[attr-defined]
        return True
    except Exception:
        return False


def _values_equal(a, b) -> bool:
    try:
        return a == b
    except Exception:
        return False


def _walk_template_leaves(tmpl, *, path: tuple[str, ...] = ()) -> Iterator[tuple[tuple[str, ...], Any]]:
    """Yield (path_segments, value) for every template-declared leaf.

    Writer(`merge_template_into`)와 checker(`collect_drift`)가 동일 ownership
    view를 공유하도록 이 helper를 유일 진입점으로 사용한다.

    Leaf 판정은 `_is_table()`로 한다 — 일반 table과 inline table(`{ key = value }`)
    모두 `_is_table` True로 취급되어 재귀 대상이 된다. 따라서 yield되는 값은
    scalar(str/int/float/bool/datetime), array(`[...]`), 그리고 기타 non-mapping TOML
    값이다. 예: `[features] voice_transcription = true`의 `voice_transcription`은
    yield되고, `[plugins.\"github@openai-curated\"] enabled = true`는 `plugins`/`github@...`
    테이블을 재귀한 뒤 `enabled`가 yield된다.

    Path는 `tuple[str, ...]`로 유지한다 — TOML key는 `"gpt-5.2"`처럼 literal `.`를
    포함할 수 있으므로, 내부 canonical contract를 문자열로 평탄화하면 key-space가
    깨진다 (writer/checker가 같은 key를 nested path로 오해). JSON 출력 시점에만
    `_render_dotted_path`로 TOML-quoted key 문법으로 렌더링한다.
    """
    for key in list(tmpl.keys()):
        full_path = path + (key,)
        value = tmpl[key]
        if _is_table(value):
            yield from _walk_template_leaves(value, path=full_path)
        else:
            yield full_path, value


def _get_at_path(doc, path_segments: tuple[str, ...]):
    """path segments를 따라 leaf를 조회. 없으면 (False, None), 있으면 (True, value)."""
    cur = doc
    for part in path_segments:
        if not _is_table(cur) or part not in cur:
            return False, None
        cur = cur[part]
    return True, cur


def _set_at_path(doc, path_segments: tuple[str, ...], value) -> None:
    """path segments에 value 설정. 중간 table이 없으면 생성."""
    cur = doc
    for part in path_segments[:-1]:
        if part not in cur or not _is_table(cur[part]):
            cur[part] = tomlkit.table()
        cur = cur[part]
    cur[path_segments[-1]] = copy.deepcopy(value)


_BARE_KEY_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def _render_dotted_path(path_segments: tuple[str, ...]) -> str:
    """TOML dotted-key 문법으로 segments를 렌더링. bare-key는 그대로, 그 외는 "quoted"."""
    parts = []
    for seg in path_segments:
        if _BARE_KEY_RE.match(seg):
            parts.append(seg)
        else:
            # basic string escape: \" and \\.
            escaped = seg.replace("\\", "\\\\").replace("\"", "\\\"")
            parts.append(f"\"{escaped}\"")
    return ".".join(parts)


def merge_template_into(dest, tmpl) -> int:
    """Template leaf를 dest에 덮어쓴다. template이 선언하지 않은 키는 건드리지 않는다.

    반환: 실제 교체된 leaf 개수.
    """
    changed = 0
    for path_segments, tmpl_val in _walk_template_leaves(tmpl):
        present, existing_val = _get_at_path(dest, path_segments)
        if present and _values_equal(existing_val, tmpl_val):
            continue
        if present:
            log(f"{_render_dotted_path(path_segments)}: template-managed value overriding user edit (template wins)")
        _set_at_path(dest, path_segments, tmpl_val)
        changed += 1
    return changed


def collect_drift(tmpl, target) -> list[dict]:
    """tmpl이 선언한 모든 leaf에 대해 target과 drift를 비교한다.

    reason enum: missing_leaf | value_mismatch | type_mismatch.
    target이 None이어도 이 함수는 호출되지 않는다 (target_state 처리는 cmd_check에서).
    """
    drift: list[dict] = []
    for path_segments, tmpl_val in _walk_template_leaves(tmpl):
        rendered = _render_dotted_path(path_segments)
        present, actual_val = _get_at_path(target, path_segments)
        if not present:
            drift.append({
                "path": rendered,
                "reason": "missing_leaf",
                "expected": _jsonify(tmpl_val),
                "actual": None,
            })
            continue
        if type(tmpl_val) is not type(actual_val) and not _types_compatible(tmpl_val, actual_val):
            drift.append({
                "path": rendered,
                "reason": "type_mismatch",
                "expected": _jsonify(tmpl_val),
                "actual": _jsonify(actual_val),
            })
            continue
        if not _values_equal(tmpl_val, actual_val):
            drift.append({
                "path": rendered,
                "reason": "value_mismatch",
                "expected": _jsonify(tmpl_val),
                "actual": _jsonify(actual_val),
            })
    return drift


def _types_compatible(a, b) -> bool:
    # tomlkit wraps scalars; compare via Python primitive type classes.
    def _pytype(v):
        if isinstance(v, bool):
            return bool
        if isinstance(v, int):
            return int
        if isinstance(v, float):
            return float
        if isinstance(v, str):
            return str
        if isinstance(v, (list, tuple)):
            return list
        return type(v)

    return _pytype(a) is _pytype(b)


def _jsonify(value):
    # tomlkit 값을 json-직렬화 가능한 Python primitive로 변환.
    if isinstance(value, bool):
        return bool(value)
    if isinstance(value, int):
        return int(value)
    if isinstance(value, float):
        return float(value)
    if isinstance(value, str):
        return str(value)
    if isinstance(value, (list, tuple)):
        return [_jsonify(v) for v in value]
    if _is_table(value):
        return {k: _jsonify(v) for k, v in value.items()}
    return str(value)


def repair_reserved_roots(result) -> None:
    # `projects = 1` 같은 비table 최상위 선언은 이후 codex CLI의 `[projects."..."]`
    # append를 깨뜨린다 ("cannot overwrite a value"). table이 아니면 제거해서 다음
    # merge/append가 정상 table을 볼 수 있게 한다.
    for _top_key in ("projects", "mcp_servers"):
        if _top_key in result and not _is_table(result[_top_key]):
            log(
                f"existing {_top_key} is not a table "
                f"({type(result[_top_key]).__name__}); removing to allow append"
            )
            del result[_top_key]


@contextlib.contextmanager
def _sync_lock(target_path: Path) -> Iterator[None]:
    """advisory exclusive lock 으로 같은 sync-codex-config 호출들(activation +
    NO_CHANGES repair) 간 race 를 차단한다.

    POSIX ``fcntl.flock`` 기반이라 추가 의존성이 없고, lockfile 은 target 디렉터리
    안의 ``.sync-codex.lock`` 으로 둔다 (원본 파일은 건드리지 않음).

    Lockfile hardening: lockfile path 자체가 malformed (symlink, FIFO, socket,
    directory 등) 면 ``os.open`` 이 hang 하거나 잘못된 entry 를 잠글 수 있다.
    ``O_NOFOLLOW`` 로 symlink 를 ELOOP 로 차단하고, ``O_NONBLOCK`` 으로 FIFO/socket
    이 영구 block 되지 않게 하며, ``fstat`` 직후 ``S_ISREG`` 로 최종 확인한다. 이 중
    하나라도 어긋나면 lockfile 은 self-heal 대상이 아니므로 ``die`` (cmd_sync 가
    ``~/.codex/config.toml`` 본체에 대해 하는 quarantine 정책과 별개).

    Scope 한정: same-host, advisory, file-descriptor based. 같은 lockfile 을 acquire
    하지 않는 외부 writer (codex CLI 의 trust append, ``sync.sh --user-mcp`` 등) 와의
    race 는 별개 follow-up (#511 코멘트 #4) 영역이다.
    """
    lock_path = target_path.parent / ".sync-codex.lock"
    target_path.parent.mkdir(parents=True, exist_ok=True)
    # umask 에 의존하지 않고 0o600 으로 lockfile 권한 명시.
    flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        fd = os.open(str(lock_path), flags, 0o600)
    except OSError as e:
        die(f"cannot open lockfile {lock_path} ({_errno_tag(e)}): {e}")
    try:
        try:
            st = os.fstat(fd)
        except OSError as e:
            die(f"cannot fstat lockfile {lock_path} ({_errno_tag(e)}): {e}")
        if not stat.S_ISREG(st.st_mode):
            die(
                f"lockfile {lock_path} is not a regular file "
                f"(st_ifmt={oct(stat.S_IFMT(st.st_mode))}) — refusing to lock"
            )
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
        except OSError as e:
            die(f"cannot acquire lock on {lock_path} ({_errno_tag(e)}): {e}")
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        try:
            os.close(fd)
        except OSError:
            pass


def _noop_probe_target(target_path: Path) -> tuple[bool, bool, Optional[bytes]]:
    """TOCTOU-safe inspection for `cmd_sync` no-op decision.

    반환값: ``(is_regular, is_mode_600, existing_bytes)``. ``existing_bytes``는 no-op 자격
    이 있을 때만 채워지며, ``None``이면 caller가 write 경로로 진입한다.

    경로 한 번만 조회하기 위해 ``os.open(O_RDONLY | O_NOFOLLOW)``로 얻은 단일 fd에서
    fstat + read를 수행한다. 경로 재조회가 없으므로 ``lstat`` → ``read_bytes`` 사이의
    symlink/mode swap race가 없다.

    OSError 정책은 모듈 상단의 ``_SELF_HEAL_ERRNOS`` / ``_UNREADABLE_REGULAR_ERRNOS``
    정의를 따른다. ``ENOENT`` 와 ``_SELF_HEAL_ERRNOS`` 는 ``(False, False, None)`` 으로
    돌아가 caller 가 write_atomic 경로로 진입하고, 그 외 OSError 는 ``die`` 한다.
    """
    try:
        # O_NONBLOCK 으로 FIFO/socket 등 special file 에 대한 open 이 영구 block 되지 않게
        # 한다. fstat 의 S_ISREG 체크가 그 뒤에서 special file 을 (False, False, None) 으로
        # 분류해 caller 가 write_atomic 으로 regular file 치환 경로를 타도록 한다.
        fd = os.open(str(target_path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return False, False, None
    except OSError as e:
        if e.errno in _SELF_HEAL_ERRNOS:
            return False, False, None
        die(
            f"cannot open target {target_path} ({_errno_tag(e)}): {e} — refusing to "
            f"overwrite to avoid data loss. Fix permissions then re-run."
        )

    try:
        try:
            st = os.fstat(fd)
        except OSError as e:
            die(f"cannot fstat target {target_path} ({_errno_tag(e)}): {e}")
        is_regular = stat.S_ISREG(st.st_mode)
        is_mode_600 = stat.S_IMODE(st.st_mode) == 0o600
        if not (is_regular and is_mode_600):
            return is_regular, is_mode_600, None
        try:
            # same-fd read: 파일 시작부터 EOF까지 (방금 open한 fd라 offset=0).
            parts: list[bytes] = []
            while True:
                buf = os.read(fd, 65536)
                if not buf:
                    break
                parts.append(buf)
            return is_regular, is_mode_600, b"".join(parts)
        except OSError as e:
            die(f"cannot read target {target_path} ({_errno_tag(e)}): {e}")
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


def write_atomic(target_path: Path, serialized: str) -> None:
    target_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        dir=str(target_path.parent),
        prefix=".config.toml.",
        suffix=".tmp",
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(serialized)
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, target_path)
    except Exception as e:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        die(f"atomic write failed ({target_path}): {e}")


def cmd_sync(template_path: Path, target_path: Path) -> int:
    _require_tomlkit()
    # advisory lock 으로 activation + NO_CHANGES repair 호출 간 race 차단.
    # 외부 writer (codex CLI append, sync.sh --user-mcp) 와의 race 는 별개 follow-up.
    with _sync_lock(target_path):
        return _cmd_sync_locked(template_path, target_path)


def _cmd_sync_locked(template_path: Path, target_path: Path) -> int:
    template = load_required_toml(template_path)
    existing = load_optional_toml(target_path, quarantine=True)

    if template.get("projects") is not None:
        # template이 projects를 선언하면 정책 위반이라 경고만 남기고 무시.
        # user trust는 runtime mutation이 소유한다.
        log("template.projects present — ignored; [projects.*] is user-owned only")

    result = copy.deepcopy(existing)
    repair_reserved_roots(result)

    template_clone = copy.deepcopy(template)
    if "projects" in template_clone:
        del template_clone["projects"]
    merge_template_into(result, template_clone)

    new_text = tomlkit.dumps(result)
    new_bytes = new_text.encode("utf-8")

    # No-op 3조건 계약의 authoritative 설명은 파일 docstring 의 "No-op suppression" 블록과
    # `_noop_probe_target` docstring 에 둔다. 여기서는 caller-side 의도만 간단히 적는다.
    is_regular, is_mode_600, existing_bytes = _noop_probe_target(target_path)
    if is_regular and is_mode_600 and existing_bytes is not None and existing_bytes == new_bytes:
        return EXIT_OK

    write_atomic(target_path, new_text)

    # Summary log.
    projects_tbl = as_table_or_warn(existing.get("projects"), where="existing.projects")
    template_mcps = as_table_or_warn(template.get("mcp_servers"), where="template.mcp_servers") or {}
    existing_mcps = as_table_or_warn(existing.get("mcp_servers"), where="existing.mcp_servers") or {}
    user_mcp_count = sum(1 for k in existing_mcps.keys() if k not in template_mcps)
    template_top_keys = [k for k in template.keys() if k != "projects"]
    user_top_keys = [k for k in existing.keys() if k not in template_top_keys and k != "projects"]
    log(
        f"preserved {len(projects_tbl) if projects_tbl else 0} projects entries, "
        f"{user_mcp_count} user-owned mcp_servers, "
        f"{len(user_top_keys)} unknown top-level keys "
        f"(template-managed top-level: {len(template_top_keys)})"
    )
    return EXIT_OK


def cmd_check(template_path: Path, target_path: Path) -> int:
    _require_tomlkit()
    template = load_required_toml(template_path)
    target = load_target_for_check(target_path)

    if target is None:
        output = {
            "template": str(template_path),
            "target": str(target_path),
            "target_state": "missing",
            "drift": [],
        }
        json.dump(output, sys.stdout, sort_keys=True)
        sys.stdout.write("\n")
        return EXIT_DRIFT

    template_clone = copy.deepcopy(template)
    if "projects" in template_clone:
        del template_clone["projects"]

    drift = collect_drift(template_clone, target)
    output = {
        "template": str(template_path),
        "target": str(target_path),
        "target_state": "present",
        "drift": drift,
    }
    json.dump(output, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")
    return EXIT_DRIFT if drift else EXIT_OK


def _parse_args(argv: list[str]) -> argparse.Namespace:
    # Backward-compat: first positional이 subcommand 이름이 아니면 sync로 라우팅.
    # 기존 activation 호출 `sync-codex-config.py <template> <target>`를 보존한다.
    subcommands = {"sync", "check"}
    if len(argv) >= 1 and argv[0] not in subcommands and not argv[0].startswith("-"):
        argv = ["sync", *argv]

    parser = argparse.ArgumentParser(
        prog=PREFIX,
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="subcommand", required=True)

    p_sync = sub.add_parser("sync", help="merge template into target (atomic write)")
    p_sync.add_argument("template", type=Path)
    p_sync.add_argument("target", type=Path)

    p_check = sub.add_parser("check", help="read-only drift check; emits JSON to stdout")
    p_check.add_argument("template", type=Path)
    p_check.add_argument("target", type=Path)

    return parser.parse_args(argv)


def main() -> int:
    args = _parse_args(sys.argv[1:])
    if args.subcommand == "sync":
        return cmd_sync(args.template, args.target)
    if args.subcommand == "check":
        return cmd_check(args.template, args.target)
    die(f"unknown subcommand: {args.subcommand}")
    return EXIT_ERROR  # unreachable


if __name__ == "__main__":
    sys.exit(main())
