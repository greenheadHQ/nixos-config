#!/usr/bin/env python3
# Merge repo template into ~/.codex/config.toml.
#
# Ownership policy (recursive leaf-level):
#   * Template-owned leaves = every leaf key that the template defines,
#                             including leaves nested inside tables the template
#                             declares (e.g. `[features].voice_transcription`,
#                             `[plugins."github@openai-curated"].enabled`,
#                             `[mcp_servers.<name>]` entries the template sets).
#     These are (re-)applied from the template on each activation.
#   * User-owned leaves     = everything the template does NOT declare at the
#                             same path — including sibling leaves inside the
#                             same table (e.g. user-added `[plugins.foo]`,
#                             `[features].my_extra_flag`) and any top-level key
#                             that is not in the template (`[projects.*]`, new
#                             Codex CLI tables we haven't seen yet).
#     These are preserved verbatim.
#
# On a same-path conflict template ALWAYS wins. The policy can be read as
# "template overwrites its own leaves and leaves everything else alone" — we
# do not need to teach the script about every new Codex section just to avoid
# deleting user data.
#
# Write is atomic (tempfile + os.replace) so a codex process reading the file
# concurrently sees either the old or new content, never a partial merge.
#
# If the existing file can be read but is malformed TOML or invalid UTF-8, we
# quarantine it to <target>.bad-<ts> and regenerate from the template — a stray
# hand-edit must not brick the whole home-manager generation. Read-level
# failures that are NOT "file missing" (permission denied, I/O error) DO abort,
# because silently replacing an unreadable file would destroy user trust and
# MCP data.

from __future__ import annotations

import copy
import datetime as _dt
import errno
import os
import sys
import tempfile
from pathlib import Path
from typing import Optional

PREFIX = "sync-codex-config"


def log(msg: str) -> None:
    print(f"{PREFIX}: {msg}", file=sys.stderr)


def die(msg: str, code: int = 2) -> "None":
    log(msg)
    sys.exit(code)


def usage() -> "None":
    die(f"usage: {os.path.basename(sys.argv[0])} <template> <target>", code=2)


try:
    import tomlkit
except ImportError:
    die("tomlkit module required (nix: pkgs.python3Packages.tomlkit)", code=2)


def load_required_toml(path: Path):
    # Template이나 필수 입력: 모든 실패는 hard fail이다.
    try:
        data = path.read_bytes()
    except FileNotFoundError:
        die(f"template not found: {path}", code=1)
    except OSError as e:
        die(f"cannot read template {path}: {e}", code=2)
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        die(f"template not valid UTF-8 ({path}): {e}", code=1)
    try:
        return tomlkit.parse(text)
    except Exception as e:
        die(f"template parse failed ({path}): {e}", code=1)


def load_optional_toml(path: Path, *, quarantine: bool):
    # 사용자 파일처럼 없거나 깨져 있을 수 있는 입력.
    # - ENOENT (파일 없음)            → empty document (첫 실행)
    # - 기타 OSError (EACCES 등)      → hard fail (데이터 보존)
    # - UnicodeDecodeError / TOML 오류 → quarantine 후 empty document (self-heal)
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        return tomlkit.document()
    except OSError as e:
        # ENOENT 이외의 읽기 실패는 원본 보존이 우선이라 hard fail.
        if e.errno in (errno.EACCES, errno.EPERM, errno.EIO, errno.EISDIR):
            die(
                f"cannot read existing {path} (errno={e.errno}): {e} — refusing to "
                f"overwrite to avoid data loss. Fix permissions then re-run.",
                code=2,
            )
        die(f"cannot read existing {path}: {e}", code=2)

    def _quarantine(reason: str) -> "tomlkit.TOMLDocument":
        if quarantine and path.exists():
            stamp = _dt.datetime.now().strftime("%Y%m%dT%H%M%S")
            bad = path.with_name(f"{path.name}.bad-{stamp}")
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


def as_table_or_warn(value, *, where: str) -> Optional[dict]:
    # TOML spec 위반(예: projects = 1)인 경우 방어. None이면 호출부에서 무시.
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
    # tomlkit 값 비교. 비교 중 예외 발생은 "다르다"로 간주.
    try:
        return a == b
    except Exception:
        return False


def merge_template_into(dest, tmpl, *, path: str = "") -> int:
    """Template leaf를 dest에 재귀적으로 덮어쓰고, template이 선언하지 않은 key는
    건드리지 않는다. same-value 덮어쓰기는 stderr 로그에 포함하지 않는다.

    반환: 실제로 교체된 leaf 개수 (debug/observability 목적).
    """
    changed = 0
    for key in list(tmpl.keys()):
        full_path = f"{path}.{key}" if path else key
        tmpl_val = tmpl[key]
        if key not in dest:
            dest[key] = copy.deepcopy(tmpl_val)
            continue
        existing_val = dest[key]
        if _is_table(tmpl_val) and _is_table(existing_val):
            changed += merge_template_into(existing_val, tmpl_val, path=full_path)
            continue
        # scalar, array, or type mismatch: template wins.
        if _values_equal(existing_val, tmpl_val):
            continue
        log(f"{full_path}: template-managed value overriding user edit (template wins)")
        dest[key] = copy.deepcopy(tmpl_val)
        changed += 1
    return changed


def main() -> int:
    if len(sys.argv) != 3:
        usage()

    template_path = Path(sys.argv[1])
    target_path = Path(sys.argv[2])

    template = load_required_toml(template_path)
    existing = load_optional_toml(target_path, quarantine=True)

    if template.get("projects") is not None:
        # template이 projects를 선언하면 정책 위반이므로 경고만 남기고 무시.
        # user trust는 오직 runtime mutation이 소유한다.
        log("template.projects present — ignored; [projects.*] is user-owned only")

    # result는 existing의 deep copy에서 시작한다. 즉 "user 소유 섹션은 기본적으로 보존".
    result = copy.deepcopy(existing)

    # Repair non-table roots. TOML은 `projects = 1` 처럼 top-level scalar 선언이
    # 합법이지만, 이후 codex CLI가 `[projects."..."]`를 append하면 "cannot overwrite
    # a value" 로 parse 실패한다. 같은 이유로 `mcp_servers = 1` 도 append가 깨진다.
    # 여기서 table이 아닌 값이 발견되면 stderr 로그 후 제거해서 다음 merge/append가
    # 정상 table을 볼 수 있게 한다.
    for _top_key in ("projects", "mcp_servers"):
        if _top_key in result and not _is_table(result[_top_key]):
            log(
                f"existing {_top_key} is not a table "
                f"({type(result[_top_key]).__name__}); removing to allow append"
            )
            del result[_top_key]

    # template의 top-level 키를 재귀 merge. projects는 user-owned이므로 skip.
    template_top_keys: list[str] = [k for k in template.keys() if k != "projects"]
    # projects 키는 얕은 사본 내에서만 임시 제거하고 원본 template은 건드리지 않는다.
    template_clone = copy.deepcopy(template)
    if "projects" in template_clone:
        del template_clone["projects"]
    merge_template_into(result, template_clone)

    serialized = tomlkit.dumps(result)

    # atomic write with mode 0600.
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
        die(f"atomic write failed ({target_path}): {e}", code=2)

    # Summary.
    projects_tbl = as_table_or_warn(existing.get("projects"), where="existing.projects")
    template_mcps = as_table_or_warn(template.get("mcp_servers"), where="template.mcp_servers") or {}
    existing_mcps = as_table_or_warn(existing.get("mcp_servers"), where="existing.mcp_servers") or {}
    user_mcp_count = sum(1 for k in existing_mcps.keys() if k not in template_mcps)
    user_top_keys = [k for k in existing.keys() if k not in template_top_keys and k != "projects"]
    log(
        f"preserved {len(projects_tbl) if projects_tbl else 0} projects entries, "
        f"{user_mcp_count} user-owned mcp_servers, "
        f"{len(user_top_keys)} unknown top-level keys "
        f"(template-managed top-level: {len(template_top_keys)})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
