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
hand-edit must not brick the whole home-manager generation. Read-level failures
that are NOT "file missing" (permission denied, I/O error) DO abort, because
silently replacing an unreadable file would destroy user trust and MCP data.
"""

from __future__ import annotations

import argparse
import copy
import datetime as _dt
import errno
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterator, Optional

PREFIX = "sync-codex-config"

EXIT_OK = 0
EXIT_DRIFT = 1
EXIT_ERROR = 2


def log(msg: str) -> None:
    print(f"{PREFIX}: {msg}", file=sys.stderr)


def die(msg: str, code: int = EXIT_ERROR) -> "None":
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
    # 사용자 파일처럼 없거나 깨져 있을 수 있는 입력.
    # - ENOENT                         -> empty document (첫 실행)
    # - 기타 OSError (EACCES 등)       -> hard fail (데이터 보존)
    # - UnicodeDecodeError / TOML 오류 -> quarantine 후 empty (self-heal)
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        return tomlkit.document()
    except OSError as e:
        if e.errno in (errno.EACCES, errno.EPERM, errno.EIO, errno.EISDIR):
            die(
                f"cannot read existing {path} (errno={e.errno}): {e} — refusing to "
                f"overwrite to avoid data loss. Fix permissions then re-run."
            )
        die(f"cannot read existing {path}: {e}")

    def _quarantine(reason: str):
        if quarantine and path.exists():
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
    try:
        data = path.read_bytes()
    except FileNotFoundError:
        return None
    except OSError as e:
        die(f"cannot read target {path} (errno={e.errno}): {e}")
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

    write_atomic(target_path, tomlkit.dumps(result))

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
