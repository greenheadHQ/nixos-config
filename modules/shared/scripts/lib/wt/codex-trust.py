#!/usr/bin/env python3
"""Maintain wt Codex project trust and copied config sanitization."""

from __future__ import annotations

import argparse
import contextlib
import datetime
import fcntl
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
from collections.abc import MutableMapping
from typing import Iterator

# Keep the retired command name split so the public stale-reference scan can
# assert that no runnable/documented legacy command literal remains.
RETIRED_PROJECTION_COMMAND = "codex" + "-sync"

# wt가 만든 worktree만 GC 대상으로 좁히는 경로 표지. 이 세그먼트가 없는 항목은
# 디렉토리가 없어도 건드리지 않는다 — 다른 호스트 경로나 마이그레이션 잔재는
# 사용자가 판단할 영역이고, wt가 만든 적 없는 등록을 대신 지울 근거가 없다.
WORKTREE_PATH_SEGMENT = "/.claude/worktrees/"


def warn(message: str) -> None:
    print(f"warning: {message}", file=sys.stderr)


def require_tomlkit():
    try:
        import tomlkit
    except ModuleNotFoundError as exc:
        raise RuntimeError("tomlkit is required for Codex trust registration") from exc
    return tomlkit


def load_toml_doc(content: str, label: str):
    tomlkit = require_tomlkit()
    try:
        return tomlkit.parse(content)
    except Exception as exc:  # noqa: BLE001 - tomlkit has broad parse errors.
        raise RuntimeError(f"{label} TOML parse failed: {exc}") from exc


@contextlib.contextmanager
def config_lock(config_path: Path) -> Iterator[None]:
    # Shared with the remaining global Codex config sync path so concurrent
    # activation and wt bootstrap never rewrite the same config independently.
    lock_path = config_path.parent / ".sync-codex.lock"
    config_path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        fd = os.open(str(lock_path), flags, 0o600)
    except OSError as exc:
        raise RuntimeError(f"cannot open lockfile {lock_path}: {exc}") from exc
    try:
        try:
            st = os.fstat(fd)
        except OSError as exc:
            raise RuntimeError(f"cannot inspect lockfile {lock_path}: {exc}") from exc
        if not stat.S_ISREG(st.st_mode):
            raise RuntimeError(f"lockfile is not a regular file: {lock_path}")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
        except OSError as exc:
            raise RuntimeError(f"cannot acquire lock {lock_path}: {exc}") from exc
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


def read_existing(config_path: Path) -> str:
    try:
        config_path.lstat()
    except FileNotFoundError:
        return ""
    return read_regular_utf8(config_path, "config")


def write_atomic(config_path: Path, content: str) -> None:
    config_path.parent.mkdir(parents=True, exist_ok=True)
    fd = -1
    tmp_name = ""
    try:
        fd, tmp_name = tempfile.mkstemp(
            dir=config_path.parent,
            prefix=".config.toml.",
            suffix=".tmp",
        )
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, config_path)
    finally:
        if fd >= 0:
            os.close(fd)
        if tmp_name:
            try:
                os.unlink(tmp_name)
            except FileNotFoundError:
                pass


def read_regular_utf8(path: Path, label: str) -> str:
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as exc:
        raise RuntimeError(f"cannot open {label} {path}: {exc}") from exc

    try:
        try:
            st = os.fstat(fd)
        except OSError as exc:
            raise RuntimeError(f"cannot inspect {label} {path}: {exc}") from exc
        if not stat.S_ISREG(st.st_mode):
            raise RuntimeError(f"{label} is not a regular file: {path}")

        chunks: list[bytes] = []
        while True:
            try:
                chunk = os.read(fd, 65536)
            except OSError as exc:
                raise RuntimeError(f"cannot read {label} {path}: {exc}") from exc
            if not chunk:
                break
            chunks.append(chunk)
        try:
            return b"".join(chunks).decode("utf-8")
        except UnicodeDecodeError as exc:
            raise RuntimeError(f"{label} is not UTF-8: {path}: {exc}") from exc
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


def sanitize_copied_codex_config(config_path: Path) -> int:
    try:
        st = config_path.lstat()
    except FileNotFoundError:
        return 0
    except OSError as exc:
        warn(f"retired Codex project MCP block cleanup skipped: cannot inspect {config_path}: {exc}")
        return 1

    if not stat.S_ISREG(st.st_mode):
        try:
            if stat.S_ISDIR(st.st_mode):
                shutil.rmtree(config_path)
            else:
                config_path.unlink()
        except OSError as exc:
            warn(f"retired Codex project MCP block cleanup failed: cannot remove {config_path}: {exc}")
            return 1
        warn("worktree .codex/config.toml이 regular file이 아니라 제거했습니다")
        return 0

    begin = f"# BEGIN {RETIRED_PROJECTION_COMMAND} managed mcp"
    end = f"# END {RETIRED_PROJECTION_COMMAND} managed mcp"

    try:
        content = read_regular_utf8(config_path, "worktree Codex config")
    except RuntimeError as exc:
        warn(f"retired Codex project MCP block cleanup skipped: {exc}")
        return 1

    out: list[str] = []
    in_block = False
    found = False
    for line in content.splitlines():
        if line == begin:
            in_block = True
            found = True
            continue
        if line == end and in_block:
            in_block = False
            continue
        if not in_block:
            out.append(line)

    if in_block:
        warn(f"retired Codex project MCP block cleanup skipped: unterminated block: {config_path}")
        return 1

    if found:
        rendered = "\n".join(out).rstrip()
        text = rendered + ("\n" if rendered else "")
        try:
            write_atomic(config_path, text)
        except OSError as exc:
            warn(f"retired Codex project MCP block cleanup failed: cannot write {config_path}: {exc}")
            return 1
    return 0


def is_regular_mode_600(config_path: Path) -> bool:
    try:
        st = config_path.lstat()
    except OSError:
        return False
    return stat.S_ISREG(st.st_mode) and stat.S_IMODE(st.st_mode) == 0o600


def render_doc(doc) -> str:
    tomlkit = require_tomlkit()
    rendered = tomlkit.dumps(doc)
    return rendered if rendered.endswith("\n") else f"{rendered}\n"


def projects_table(doc):
    """Return the [projects] table when it is a mapping we can edit, else None."""
    projects = doc.get("projects")
    if projects is None or not isinstance(projects, MutableMapping):
        return None
    return projects


def normalize_project_key(project_root: str) -> str:
    # trust-project는 resolve(strict=True) 결과를 키로 쓰지만, 해제 시점에는 디렉토리가
    # 이미 없어 resolve가 실패하거나 엉뚱한 경로를 만든다. 그래서 호출자가 넘긴 문자열을
    # 그대로 쓰되 등록 때와 같은 끝 슬래시 정규화만 맞춘다 ("/"는 통째로 지우지 않는다).
    return str(project_root).rstrip("/") or str(project_root)


def render_trusted_project(content: str, project_path: str, doc=None) -> str:
    tomlkit = require_tomlkit()
    from tomlkit.items import InlineTable

    if doc is None:
        doc = load_toml_doc(content, "existing config") if content else tomlkit.document()
    projects = doc.get("projects")
    if projects is None:
        projects = tomlkit.table()
        doc["projects"] = projects
    if not isinstance(projects, MutableMapping):
        raise RuntimeError("projects table cannot be safely merged")

    project_entry = projects.get(project_path)
    if project_entry is None:
        project_entry = tomlkit.inline_table() if isinstance(projects, InlineTable) else tomlkit.table()
        projects[project_path] = project_entry
    if not isinstance(project_entry, MutableMapping):
        raise RuntimeError("project trust entry cannot be safely merged")

    project_entry["trust_level"] = "trusted"
    return render_doc(doc)


def ensure_project_trusted(config_path: Path, project_root: Path) -> int:
    try:
        project_path = str(project_root.resolve(strict=True)).rstrip("/")
    except OSError as exc:
        warn(f"project path does not exist; skipping Codex trust registration: {project_root}: {exc}")
        return 0

    try:
        with config_lock(config_path):
            content = read_existing(config_path)
            doc = load_toml_doc(content, "existing config") if content else None
            rendered = render_trusted_project(content, project_path, doc)
            load_toml_doc(rendered, "rendered config")
            if rendered != content or not is_regular_mode_600(config_path):
                try:
                    write_atomic(config_path, rendered)
                except OSError as exc:
                    raise RuntimeError(f"cannot write config {config_path}: {exc}") from exc
    except RuntimeError as exc:
        warn(f"Codex trust registration skipped: {exc}")
        return 1
    return 0


def remove_project_trust(config_path: Path, project_root: str) -> int:
    """Drop one [projects."<path>"] entry. Missing key (or config) is a no-op."""
    project_path = normalize_project_key(project_root)

    try:
        with config_lock(config_path):
            content = read_existing(config_path)
            if not content:
                return 0
            doc = load_toml_doc(content, "existing config")
            projects = projects_table(doc)
            if projects is None or project_path not in projects:
                return 0
            del projects[project_path]
            rendered = render_doc(doc)
            load_toml_doc(rendered, "rendered config")
            if rendered != content:
                try:
                    write_atomic(config_path, rendered)
                except OSError as exc:
                    raise RuntimeError(f"cannot write config {config_path}: {exc}") from exc
    except RuntimeError as exc:
        warn(f"Codex trust 해제 건너뜀: {exc}")
        return 1
    return 0


def backup_path_for_gc(config_path: Path) -> Path:
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return config_path.with_name(f"{config_path.name}.bak-gc-{stamp}")


def gc_worktree_projects(config_path: Path, dry_run: bool) -> int:
    """Remove [projects] entries for wt worktrees whose directory is gone."""
    try:
        with config_lock(config_path):
            content = read_existing(config_path)
            doc = load_toml_doc(content, "existing config") if content else None
            projects = projects_table(doc) if doc is not None else None
            if projects is None:
                # "[projects]가 없다"와 "있는데 table이 아니라 못 읽는다"를 요약만으로는
                # 구분할 수 없다. 후자는 사용자가 손봐야 하는 상태라 따로 알린다.
                if doc is not None and doc.get("projects") is not None:
                    warn(f"projects table을 읽을 수 없어 GC를 건너뜁니다: {config_path}")
                print(f"{'would remove' if dry_run else 'removed'} 0 (kept 0)", file=sys.stderr)
                return 0

            stale = [
                key
                for key in list(projects.keys())
                if WORKTREE_PATH_SEGMENT in str(key) and not os.path.isdir(str(key))
            ]
            kept = len(projects) - len(stale)
            for key in stale:
                print(str(key), file=sys.stderr)

            if stale and not dry_run:
                for key in stale:
                    del projects[key]
                rendered = render_doc(doc)
                load_toml_doc(rendered, "rendered config")
                # 되돌릴 수 없는 일괄 삭제라 원본을 먼저 남긴다. copy2는 mode까지 옮기는데,
                # 원본이 0600보다 넓으면(Codex가 직접 만든 config 등) 지운 항목까지 담긴
                # 전체 사본이 그 넓은 권한으로 남는다 — 새 config는 write_atomic이 0600으로
                # 쓰므로 백업만 뒤처진다. 백업도 0600으로 좁히고, 좁히지 못하면 config를
                # 교체하지 않는다 (남기지 못할 백업으로 되돌릴 수 없는 삭제를 하지 않는다).
                backup = backup_path_for_gc(config_path)
                try:
                    shutil.copy2(config_path, backup)
                    os.chmod(backup, 0o600)
                except OSError as exc:
                    raise RuntimeError(f"cannot write backup {backup}: {exc}") from exc
                try:
                    write_atomic(config_path, rendered)
                except OSError as exc:
                    raise RuntimeError(f"cannot write config {config_path}: {exc}") from exc

            # dry-run과 실제 실행의 요약이 같으면 로그만 보고 "이미 지웠다"로 오해한다.
            # 무엇을 한 실행인지 요약 한 줄로 구분되게 한다.
            print(
                f"{'would remove' if dry_run else 'removed'} {len(stale)} (kept {kept})",
                file=sys.stderr,
            )
    except RuntimeError as exc:
        warn(f"Codex trust GC 건너뜀: {exc}")
        return 1
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="subcommand", required=True)

    trust = sub.add_parser("trust-project", help="mark a project as trusted")
    trust.add_argument("--config", required=True, type=Path)
    trust.add_argument("project_root", type=Path)

    untrust = sub.add_parser(
        "untrust-project",
        help="drop a project trust entry (no-op when absent)",
    )
    untrust.add_argument("--config", required=True, type=Path)
    untrust.add_argument("project_root")

    gc = sub.add_parser(
        "gc-worktree-projects",
        help="drop trust entries for wt worktrees whose directory no longer exists",
    )
    gc.add_argument("--config", required=True, type=Path)
    gc.add_argument("--dry-run", action="store_true")

    sanitize = sub.add_parser(
        "sanitize-copied-codex-config",
        help="remove unsafe copied config path and retired worktree project MCP block",
    )
    sanitize.add_argument("config", type=Path)

    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.subcommand == "trust-project":
        return ensure_project_trusted(args.config, args.project_root)
    if args.subcommand == "untrust-project":
        return remove_project_trust(args.config, args.project_root)
    if args.subcommand == "gc-worktree-projects":
        return gc_worktree_projects(args.config, args.dry_run)
    if args.subcommand == "sanitize-copied-codex-config":
        return sanitize_copied_codex_config(args.config)
    raise AssertionError(f"unknown subcommand: {args.subcommand}")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
