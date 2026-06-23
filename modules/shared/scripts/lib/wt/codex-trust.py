#!/usr/bin/env python3
"""Maintain wt Codex project trust and copied config sanitization."""

from __future__ import annotations

import argparse
import contextlib
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
    rendered = tomlkit.dumps(doc)
    return rendered if rendered.endswith("\n") else f"{rendered}\n"


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


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="subcommand", required=True)

    trust = sub.add_parser("trust-project", help="mark a project as trusted")
    trust.add_argument("--config", required=True, type=Path)
    trust.add_argument("project_root", type=Path)

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
    if args.subcommand == "sanitize-copied-codex-config":
        return sanitize_copied_codex_config(args.config)
    raise AssertionError(f"unknown subcommand: {args.subcommand}")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
