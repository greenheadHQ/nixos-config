#!/usr/bin/env python3
"""Validate staged Gitleaks config extension paths stay inside staged material."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
from typing import Any

try:
    import tomllib  # type: ignore[attr-defined]
except ModuleNotFoundError:  # pragma: no cover - used on older Python
    tomllib = None

try:
    import tomlkit  # type: ignore[import-not-found]
except ModuleNotFoundError:  # pragma: no cover - optional fallback
    tomlkit = None


def die(message: str) -> None:
    print(f"validate-gitleaks-staged-policy: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_toml(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    try:
        if tomllib is not None:
            return tomllib.loads(text)
        if tomlkit is not None:
            return tomlkit.loads(text).unwrap()
    except Exception as exc:  # noqa: BLE001 - fail closed with parser detail
        die(f"invalid TOML in {path}: {exc}")
    die("tomllib/tomlkit is not available")


def git_ls_stage(path: str, env: dict[str, str]) -> tuple[str, str]:
    result = subprocess.run(
        ["git", "ls-files", "-s", "--", path],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    if result.returncode != 0:
        die(f"git ls-files failed for {path}: {result.stderr.strip()}")
    lines = [line for line in result.stdout.splitlines() if line]
    if len(lines) != 1:
        die(f"{path} must have exactly one stage-0 index entry")
    parts = lines[0].split()
    if len(parts) < 4 or parts[2] != "0":
        die(f"{path} must be a stage-0 index entry")
    return parts[0], parts[1]


def require_regular_config(rel_path: str, snapshot: Path, env: dict[str, str]) -> Path:
    if rel_path.startswith("/") or rel_path == "" or ".." in Path(rel_path).parts:
        die(f"extend.path escapes staged snapshot: {rel_path}")
    target = (snapshot / rel_path).resolve()
    try:
        target.relative_to(snapshot)
    except ValueError:
        die(f"extend.path resolves outside staged snapshot: {rel_path}")
    mode, _oid = git_ls_stage(rel_path, env)
    if mode != "100644":
        die(f"{rel_path} must be a staged regular 100644 file, got mode {mode}")
    if not target.is_file() or target.is_symlink():
        die(f"{rel_path} must materialize as a regular file")
    return target


def validate_config(rel_path: str, snapshot: Path, env: dict[str, str], seen: set[str]) -> None:
    if rel_path in seen:
        die(f"extend.path cycle detected at {rel_path}")
    seen.add(rel_path)

    config_path = require_regular_config(rel_path, snapshot, env)
    data = parse_toml(config_path)
    extend = data.get("extend")
    if not isinstance(extend, dict):
        return

    extend_path = extend.get("path")
    if extend_path is None:
        return
    if not isinstance(extend_path, str):
        die(f"extend.path in {rel_path} must be a string")

    validate_config(extend_path, snapshot, env, seen)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--git-dir", required=True)
    parser.add_argument("--index", required=True)
    args = parser.parse_args()

    snapshot = Path(args.snapshot).resolve()
    if not snapshot.is_dir():
        die(f"snapshot does not exist: {snapshot}")

    env = os.environ.copy()
    env["GIT_DIR"] = str(Path(args.git_dir).resolve())
    env["GIT_WORK_TREE"] = str(snapshot)
    env["GIT_INDEX_FILE"] = str(Path(args.index).resolve())

    validate_config(".gitleaks.toml", snapshot, env, set())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
