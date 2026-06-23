#!/usr/bin/env python3
"""Maintain Claude local plugin registrations for wt worktrees."""

from __future__ import annotations

import argparse
import contextlib
import copy
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
from typing import Iterator

WT_MANAGED_METADATA_KEY = "wtManaged"
WT_MANAGED_METADATA_VERSION = 1
WT_MANAGED_SKILL_LINK_PREFIX = "wt-plugin--"


def warn(message: str) -> None:
    print(f"warning: {message}", file=sys.stderr)


def resolve_path(value: str, *, strict: bool = False) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    path = Path(value).expanduser()
    try:
        return str(path.resolve(strict=strict))
    except OSError:
        if strict:
            return None
        return str(path.resolve(strict=False))


def read_regular_text(path: Path, description: str, action: str) -> str | None:
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.EISDIR):
            warn(f"{description} is not a regular file; {action}: {path}")
            return None
        warn(f"cannot read {description}; {action}: {path}: {exc}")
        return None

    try:
        try:
            st = os.fstat(fd)
        except OSError as exc:
            warn(f"cannot inspect {description}; {action}: {path}: {exc}")
            return None
        if not stat.S_ISREG(st.st_mode):
            warn(f"{description} is not a regular file; {action}: {path}")
            return None

        chunks: list[bytes] = []
        while True:
            try:
                chunk = os.read(fd, 65536)
            except OSError as exc:
                warn(f"cannot read {description}; {action}: {path}: {exc}")
                return None
            if not chunk:
                break
            chunks.append(chunk)
        try:
            return b"".join(chunks).decode("utf-8")
        except UnicodeDecodeError as exc:
            warn(f"{description} is not UTF-8; {action}: {path}: {exc}")
            return None
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


def load_json(path: Path, description: str, action: str) -> object | None:
    content = read_regular_text(path, description, action)
    if content is None:
        return None
    try:
        return json.loads(content)
    except json.JSONDecodeError as exc:
        warn(f"{description} JSON is invalid; {action}: {path}: {exc}")
        return None


def enabled_plugin_keys(settings_path: Path) -> list[str] | None:
    payload = load_json(settings_path, "settings.local.json", "skipping plugin inheritance")
    if payload is None:
        return None
    if not isinstance(payload, dict):
        warn(f"settings.local.json is not an object; skipping plugin inheritance: {settings_path}")
        return None
    if "enabledPlugins" not in payload:
        return []
    enabled = payload.get("enabledPlugins")
    if not isinstance(enabled, dict):
        warn(f"settings.local.json enabledPlugins is not an object; skipping plugin inheritance: {settings_path}")
        return None
    return [key for key, value in enabled.items() if isinstance(key, str) and bool(value)]


@contextlib.contextmanager
def manifest_lock(manifest_path: Path) -> Iterator[bool]:
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = manifest_path.with_name(f".{manifest_path.name}.lock")
    flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        fd = os.open(str(lock_path), flags, 0o600)
    except OSError as exc:
        warn(f"cannot open plugin manifest lock; skipping update: {lock_path}: {exc}")
        yield False
        return

    try:
        try:
            st = os.fstat(fd)
        except OSError as exc:
            warn(f"cannot inspect plugin manifest lock; skipping update: {lock_path}: {exc}")
            yield False
            return
        if not stat.S_ISREG(st.st_mode):
            warn(f"plugin manifest lock is not a regular file; skipping update: {lock_path}")
            yield False
            return
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
        except OSError as exc:
            warn(f"cannot acquire plugin manifest lock; skipping update: {lock_path}: {exc}")
            yield False
            return
        yield True
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        try:
            os.close(fd)
        except OSError:
            pass


def matches_resolved_local_project_entry(entry: object, canonical_project: str) -> bool:
    if not isinstance(entry, dict):
        return False
    if entry.get("scope") != "local":
        return False
    project_path = resolve_path(entry.get("projectPath", ""), strict=False)
    return project_path == canonical_project


def matches_recorded_local_project_entry_literal(entry: object, recorded_project: str) -> bool:
    if not isinstance(entry, dict):
        return False
    if entry.get("scope") != "local":
        return False
    project_path = entry.get("projectPath")
    if not isinstance(project_path, str) or not project_path:
        return False
    return str(Path(project_path).expanduser()).rstrip("/") == recorded_project


def wt_managed_metadata(entry: object) -> dict[str, object] | None:
    if not isinstance(entry, dict):
        return None
    metadata = entry.get("metadata")
    if not isinstance(metadata, dict):
        return None
    marker = metadata.get(WT_MANAGED_METADATA_KEY)
    return marker if isinstance(marker, dict) else None


def is_wt_managed_entry(entry: object) -> bool:
    marker = wt_managed_metadata(entry)
    return bool(marker and marker.get("version") == WT_MANAGED_METADATA_VERSION)


def matches_managed_resolved_project_entry(entry: object, canonical_project: str) -> bool:
    return is_wt_managed_entry(entry) and matches_resolved_local_project_entry(
        entry, canonical_project
    )


def matches_managed_recorded_project_entry_literal(
    entry: object, recorded_project: str
) -> bool:
    return is_wt_managed_entry(entry) and matches_recorded_local_project_entry_literal(
        entry, recorded_project
    )


def install_path(entry: object) -> str | None:
    if not isinstance(entry, dict):
        return None
    value = entry.get("installPath")
    return value if isinstance(value, str) and value else None


def target_install_path(entry: object, source_root: str, target_root: str) -> str | None:
    value = install_path(entry)
    if value is None:
        return None
    resolved = resolve_path(value, strict=False)
    if resolved is None:
        return value
    try:
        relative = Path(resolved).relative_to(Path(source_root))
    except ValueError:
        return value
    return str(Path(target_root) / relative)


def is_replaceable_inherited_target_entry(
    entry: object,
    target_root: str,
    source_entries: list[object],
    source_root: str,
) -> bool:
    if matches_managed_resolved_project_entry(entry, target_root):
        return True
    if not matches_resolved_local_project_entry(entry, target_root):
        return False
    target_entry_install_path = install_path(entry)
    if target_entry_install_path is None:
        return False
    return any(
        target_entry_install_path in {install_path(source), target_install_path_for_source}
        for source in source_entries
        for target_install_path_for_source in [target_install_path(source, source_root, target_root)]
    )


def mark_wt_managed_entry(
    entry: dict[str, object],
    source_root: str,
    source_entry: object,
) -> None:
    metadata = entry.get("metadata")
    if isinstance(metadata, dict):
        next_metadata = copy.deepcopy(metadata)
    else:
        next_metadata = {}
    next_metadata[WT_MANAGED_METADATA_KEY] = {
        "version": WT_MANAGED_METADATA_VERSION,
        "sourceProjectPath": source_root,
        "sourceInstallPath": install_path(source_entry) or "",
    }
    entry["metadata"] = next_metadata


def atomic_write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)

    fd = -1
    tmp_name = ""
    try:
        fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
    finally:
        if fd >= 0:
            os.close(fd)
        if tmp_name:
            try:
                os.unlink(tmp_name)
            except FileNotFoundError:
                pass


def remove_target_entries(
    plugins: dict[str, object],
    target_root: str,
    matcher,
) -> bool:
    changed = False
    for key in list(plugins.keys()):
        entries = plugins.get(key, [])
        if not isinstance(entries, list):
            continue
        retained = [entry for entry in entries if not matcher(entry, target_root)]
        if retained != entries:
            changed = True
            if retained:
                plugins[key] = retained
            else:
                del plugins[key]
    return changed


def load_manifest(manifest_path: Path) -> dict[str, object] | None:
    payload = load_json(manifest_path, "installed_plugins.json", "leaving it unchanged")
    if payload is None:
        return None
    if not isinstance(payload, dict):
        warn(f"installed_plugins.json is not an object; leaving it unchanged: {manifest_path}")
        return None
    plugins = payload.get("plugins")
    if plugins is None:
        payload["plugins"] = {}
    elif not isinstance(plugins, dict):
        warn(f"installed_plugins.json plugins field is not an object; leaving it unchanged: {manifest_path}")
        return None
    return payload


def safe_filename_component(value: str) -> str:
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:10]
    slug = "".join(char if char.isalnum() or char in "._-" else "_" for char in value)
    slug = slug.strip("._-") or "item"
    return f"{slug[:60]}-{digest}"


def managed_plugin_skill_name(plugin_key_value: str, skill_name: str) -> str:
    return (
        f"{WT_MANAGED_SKILL_LINK_PREFIX}"
        f"{safe_filename_component(plugin_key_value)}--{safe_filename_component(skill_name)}"
    )


def ensure_agents_skills_dir(target_root: Path) -> Path | None:
    agents_dir = target_root / ".agents"
    skills_dir = agents_dir / "skills"
    if agents_dir.is_symlink() or (agents_dir.exists() and not agents_dir.is_dir()):
        warn(f"worktree .agents is not a regular directory; skipping plugin skill projection: {agents_dir}")
        return None
    if skills_dir.is_symlink() or (skills_dir.exists() and not skills_dir.is_dir()):
        warn(f"worktree .agents/skills is not a regular directory; skipping plugin skill projection: {skills_dir}")
        return None
    skills_dir.mkdir(parents=True, exist_ok=True)
    return skills_dir


def reconcile_plugin_skill_links(target_root: str, desired_links: dict[str, str]) -> None:
    target_dir = ensure_agents_skills_dir(Path(target_root))
    if target_dir is None:
        return

    for existing_link in sorted(target_dir.glob(f"{WT_MANAGED_SKILL_LINK_PREFIX}*")):
        if existing_link.name not in desired_links:
            remove_managed_plugin_skill_path(existing_link)

    for link_name, source_target in sorted(desired_links.items()):
        target_link = target_dir / link_name
        if target_link.parent != target_dir:
            warn(f"plugin skill link name is not confined to .agents/skills; skipping: {link_name}")
            continue
        if target_link.exists() and not target_link.is_symlink():
            warn(f"plugin skill target exists and is not a symlink; replacing managed path: {target_link}")
            remove_managed_plugin_skill_path(target_link)
        if target_link.is_symlink():
            if os.readlink(target_link) == source_target:
                continue
            target_link.unlink()
        os.symlink(source_target, target_link)


def remove_managed_plugin_skill_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)
    elif path.exists():
        warn(f"managed plugin skill path has unsupported type; skipping cleanup: {path}")


def desired_plugin_skill_links(
    plugin_key_value: str,
    source_entries: list[object],
) -> dict[str, str]:
    desired: dict[str, str] = {}
    for entry in source_entries:
        plugin_install_path = install_path(entry)
        if plugin_install_path is None:
            continue
        source_skills_dir = Path(plugin_install_path).expanduser() / "skills"
        if not source_skills_dir.is_dir():
            continue
        for source_skill_dir in sorted(source_skills_dir.iterdir(), key=lambda path: path.name):
            if not source_skill_dir.is_dir() or not (source_skill_dir / "SKILL.md").is_file():
                continue
            desired[managed_plugin_skill_name(plugin_key_value, source_skill_dir.name)] = str(
                source_skill_dir.resolve()
            )
    return desired


def inherit_local_plugins(args: argparse.Namespace) -> int:
    settings_path = Path(args.settings)
    manifest_path = Path(args.manifest)
    source_root = resolve_path(args.source_root, strict=True)
    target_root = resolve_path(args.target_root, strict=True)

    if source_root is None:
        warn(f"source repo root does not exist; skipping plugin inheritance: {args.source_root}")
        return 0
    if target_root is None:
        warn(f"target worktree path does not exist; skipping plugin inheritance: {args.target_root}")
        return 0
    if not manifest_path.exists():
        warn(f"Claude plugin manifest missing; skipping local plugin inheritance: {manifest_path}")
        return 0

    keys = enabled_plugin_keys(settings_path) if settings_path.is_file() else []
    if keys is None:
        return 0
    with manifest_lock(manifest_path) as locked:
        if not locked:
            return 0
        manifest = load_manifest(manifest_path)
        if manifest is None:
            return 0
        plugins = manifest["plugins"]
        assert isinstance(plugins, dict)

        changed = remove_target_entries(
            plugins, target_root, matches_managed_resolved_project_entry
        )
        desired_skill_links: dict[str, str] = {}
        if not keys:
            reconcile_plugin_skill_links(target_root, desired_skill_links)
            if changed:
                atomic_write_json(manifest_path, manifest)
            return 0

        for key in keys:
            entries = plugins.get(key, [])
            if not isinstance(entries, list):
                warn(f"plugin manifest entry is not a list; skipping plugin: {key}")
                continue

            source_entries = [
                entry for entry in entries if matches_resolved_local_project_entry(entry, source_root)
            ]
            if not source_entries:
                warn(f"enabled local plugin has no source repo manifest entry; skipping plugin: {key}")
                continue

            retained = [
                entry
                for entry in entries
                if not is_replaceable_inherited_target_entry(entry, target_root, source_entries, source_root)
            ]
            if retained != entries:
                entries = retained
                changed = True

            inherited = []
            for entry in source_entries:
                clone = copy.deepcopy(entry)
                clone["projectPath"] = target_root
                rewritten_install_path = target_install_path(entry, source_root, target_root)
                if rewritten_install_path is not None:
                    clone["installPath"] = rewritten_install_path
                mark_wt_managed_entry(clone, source_root, entry)
                inherited.append(clone)

            next_entries = entries + inherited
            if next_entries != entries:
                plugins[key] = next_entries
                changed = True
            desired_skill_links.update(desired_plugin_skill_links(key, inherited))

        reconcile_plugin_skill_links(target_root, desired_skill_links)

        if changed:
            atomic_write_json(manifest_path, manifest)
    return 0


def remove_local_plugins(args: argparse.Namespace) -> int:
    manifest_path = Path(args.manifest)
    if args.target_root_before_removal:
        target_root = args.target_root_before_removal.rstrip("/")
        # The path may be deleted and later recreated as a symlink to another
        # project; compare the recorded manifest string instead of resolving.
        is_target_entry = matches_managed_recorded_project_entry_literal
    else:
        target_root = resolve_path(args.target_root, strict=False)
        is_target_entry = matches_managed_resolved_project_entry
    if target_root is None or not manifest_path.exists():
        return 0

    with manifest_lock(manifest_path) as locked:
        if not locked:
            return 1
        manifest = load_manifest(manifest_path)
        if manifest is None:
            return 1
        plugins = manifest["plugins"]
        assert isinstance(plugins, dict)

        changed = remove_target_entries(plugins, target_root, is_target_entry)

        if changed:
            atomic_write_json(manifest_path, manifest)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    inherit_parser = subparsers.add_parser("inherit-local")
    inherit_parser.add_argument("--settings", required=True)
    inherit_parser.add_argument("--manifest", required=True)
    inherit_parser.add_argument("--source-root", required=True)
    inherit_parser.add_argument("--target-root", required=True)
    inherit_parser.set_defaults(func=inherit_local_plugins)

    remove_parser = subparsers.add_parser("remove-local")
    remove_parser.add_argument("--manifest", required=True)
    remove_parser.add_argument("--target-root", required=True)
    remove_parser.add_argument("--target-root-before-removal")
    remove_parser.set_defaults(func=remove_local_plugins)

    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
