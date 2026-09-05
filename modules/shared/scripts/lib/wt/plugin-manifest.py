#!/usr/bin/env python3
"""Maintain Claude local plugin registrations for wt worktrees."""

from __future__ import annotations

import argparse
import contextlib
import copy
import datetime
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
# wt가 worktree를 만드는 자리(`<repo>/.claude/worktrees/<name>`)의 마지막 두 조각.
# orphan GC 범위를 이 자리 아래로만 한정하는 데 쓴다.
WT_WORKTREE_BASE_PARTS = (".claude", "worktrees")
# 경로 존재 판정 결과. "없다"와 "확인하지 못했다"를 구분해, 되돌릴 수 없는 삭제를
# 확인된 부재에만 허용한다.
PRESENCE_MISSING = "missing"
PRESENCE_PRESENT = "present"
PRESENCE_UNKNOWN = "unknown"


def warn(message: str) -> None:
    print(f"warning: {message}", file=sys.stderr)


def info(message: str) -> None:
    print(message, file=sys.stderr)


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


def orphan_gc_base(target_root: str) -> str | None:
    """제거 대상 worktree가 놓인 wt worktree base를 돌려준다 (아니면 None).

    GC 범위를 CLI 인자로 따로 받지 않고 대상 경로에서 유도한다. 호출부(bootstrap.sh)는
    이미 `<repo>/.claude/worktrees/<name>`만 넘기므로 추가 인자 없이 같은 저장소의
    worktree base로 범위가 좁혀지고, 그 밖의 경로로 helper를 직접 부르면 (마지막 두
    조각이 다르므로) GC 자체가 꺼진다. wt가 만드는 대상은 항상 base 바로 아래이므로
    부모 한 단계만 본다 — GC가 훑는 범위는 이렇게 얻은 base 아래 전체다.
    """
    parent = Path(target_root).expanduser().parent
    if parent.parts[-2:] != WT_WORKTREE_BASE_PARTS:
        return None
    return resolve_path(str(parent), strict=False)


def path_presence(path: Path) -> tuple[str, str]:
    """경로 존재 여부를 확인된 만큼만 돌려준다 (missing / present / unknown).

    `os.path.lexists`는 "없다"와 "stat 자체를 못 했다"(EACCES·EIO 등)를 모두 False로
    뭉갠다. 그 신호로 지우면 base를 읽지 못하는 동안 살아 있는 worktree의 등록까지
    되돌릴 수 없이 사라진다. 확인하지 못한 상태는 unknown으로 남겨 보존한다
    (fail-closed — wt의 재생성 잠금 가드와 같은 원칙).
    """
    try:
        os.lstat(path)
    except (FileNotFoundError, NotADirectoryError):
        return PRESENCE_MISSING, ""
    except OSError as exc:
        return PRESENCE_UNKNOWN, str(exc)
    return PRESENCE_PRESENT, ""


def collect_orphan_worktree_entries(
    plugins: dict[str, object],
    worktree_base: str,
    skip_paths: set[str],
) -> tuple[list[tuple[str, int, str]], list[str]]:
    """worktree base 아래를 가리키지만 그 경로가 사라진 local entry를 모은다.

    wtManaged 표식을 요구하지 않는다. 표식은 wt가 심어준 entry에만 있어서, 표식 도입
    전에 생겼거나 사용자가 직접 등록한 entry는 디렉토리가 사라져도 어떤 제거 조건에도
    걸리지 않고 manifest에 영구히 남았다. 경로 소멸 자체가 "이 등록은 더 이상 가리킬
    대상이 없다"는 충분한 근거이므로 표식 없이도 지운다.

    base 바로 아래(1단계)만이 아니라 그 아래 전체를 본다 — 브랜치명 때문에
    `.claude/worktrees/feat/x` 같은 깊은 경로도 실제로 생기고, 같은 개념의 형제 GC
    (codex-trust.py)도 경로에 base가 들어가는지로 판정한다.

    돌려주는 값은 (제거 후보 (plugin key, index, projectPath) 목록, 판정 실패 목록).
    """
    victims: list[tuple[str, int, str]] = []
    undetermined: list[str] = []
    for key in list(plugins.keys()):
        entries = plugins.get(key, [])
        if not isinstance(entries, list):
            continue
        for index, entry in enumerate(entries):
            if not isinstance(entry, dict) or entry.get("scope") != "local":
                continue
            project_path = entry.get("projectPath")
            if not isinstance(project_path, str) or not project_path:
                continue
            expanded = Path(project_path).expanduser()
            literal = str(expanded).rstrip("/")
            # resolve(strict=False)는 사라진 경로도 조상 symlink(macOS `/tmp` →
            # `/private/tmp` 등)까지 펴주므로 base와 같은 표현으로 비교된다.
            canonical = resolve_path(project_path, strict=False) or literal
            if literal in skip_paths or canonical in skip_paths:
                continue
            if not canonical.startswith(worktree_base + os.sep):
                continue
            state, detail = path_presence(expanded)
            if state == PRESENCE_UNKNOWN:
                undetermined.append(f"{project_path}: {detail}")
                continue
            if state == PRESENCE_MISSING:
                victims.append((key, index, project_path))
    return victims, undetermined


def apply_orphan_removals(
    plugins: dict[str, object], victims: list[tuple[str, int, str]]
) -> None:
    """collect가 고른 entry를 인덱스로 제거한다 (판정을 다시 하지 않는다)."""
    by_key: dict[str, set[int]] = {}
    for key, index, _ in victims:
        by_key.setdefault(key, set()).add(index)
    for key, indexes in by_key.items():
        entries = plugins.get(key)
        if not isinstance(entries, list):
            continue
        retained = [entry for index, entry in enumerate(entries) if index not in indexes]
        if retained:
            plugins[key] = retained
        else:
            del plugins[key]


def backup_path_for_gc(manifest_path: Path) -> Path:
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return manifest_path.with_name(f"{manifest_path.name}.bak-gc-{stamp}")


def write_gc_backup(manifest_path: Path) -> Path | None:
    """GC 직전 manifest 사본을 남긴다 (실패하면 None — 호출부가 GC를 건너뛴다).

    copy2는 원본 mode를 그대로 옮기는데, 지운 항목까지 담긴 전체 사본이 manifest보다
    넓은 권한으로 남지 않도록 0600으로 좁힌다 (형제 helper codex-trust.py와 같은 계약).
    """
    backup = backup_path_for_gc(manifest_path)
    try:
        shutil.copy2(manifest_path, backup)
        os.chmod(backup, 0o600)
    except OSError as exc:
        warn(f"cannot write plugin manifest backup; keeping orphan entries: {backup}: {exc}")
        return None
    return backup


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
            try:
                remove_managed_plugin_skill_path(existing_link)
            except OSError as exc:
                warn(f"cannot remove stale managed plugin skill path; skipping: {existing_link}: {exc}")

    for link_name, source_target in sorted(desired_links.items()):
        target_link = target_dir / link_name
        if target_link.parent != target_dir:
            warn(f"plugin skill link name is not confined to .agents/skills; skipping: {link_name}")
            continue
        if target_link.exists() and not target_link.is_symlink():
            warn(f"plugin skill target exists and is not a symlink; replacing managed path: {target_link}")
            try:
                remove_managed_plugin_skill_path(target_link)
            except OSError as exc:
                warn(f"cannot replace managed plugin skill path; skipping: {target_link}: {exc}")
                continue
        if target_link.is_symlink():
            try:
                current_target = os.readlink(target_link)
            except OSError as exc:
                warn(f"cannot inspect managed plugin skill symlink; skipping: {target_link}: {exc}")
                continue
            if current_target == source_target:
                continue
            try:
                target_link.unlink()
            except OSError as exc:
                warn(f"cannot update managed plugin skill symlink; skipping: {target_link}: {exc}")
                continue
        try:
            os.symlink(source_target, target_link)
        except OSError as exc:
            warn(f"cannot create managed plugin skill symlink; skipping: {target_link}: {exc}")


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

        # 제거 대상과 무관한 orphan도 같은 락·같은 쓰기 안에서 전수 정리한다. manifest
        # 쓰기는 락 안에서 한 번뿐이라 여기 얹는 비용이 사실상 0이고, wt cleanup은 대상
        # 하나만 지우므로 "그 worktree만" 정리하면 이미 사라진 형제 entry는 그것을 지웠던
        # 실행이 다시 오지 않는 한 영원히 남는다 (실제로 12건이 그렇게 쌓였다).
        worktree_base = orphan_gc_base(target_root)
        if worktree_base is not None:
            # 이번 대상 자신은 GC에서 뺀다. 보호 경로(`wt cleanup --auto`)는 디렉토리를
            # 지운 뒤 이 helper를 부르므로, 빼지 않으면 대상의 표식 없는(사용자 수동)
            # 등록까지 함께 사라져 강제 경로(`--yes`, 제거 전 호출)와 계약이 갈린다.
            # 대상에는 위의 exact-match 제거만 적용하고, 강제 경로가 남긴 잔재는 다음
            # 실행의 전수 GC가 회수한다.
            skip_paths = {target_root, resolve_path(target_root, strict=False) or target_root}
            victims, undetermined = collect_orphan_worktree_entries(
                plugins, worktree_base, skip_paths
            )
            for detail in undetermined:
                warn(f"cannot check worktree path; keeping its plugin entry: {detail}")
            if victims:
                # 되돌릴 수 없는 일괄 삭제라, 무엇을 지웠는지 경로까지 남기고 원본 사본을
                # 먼저 뜬다. 사본을 남기지 못하면 GC 자체를 건너뛴다 (대상 entry 제거는
                # 그대로 진행 — wt cleanup의 본 계약이다).
                backup = write_gc_backup(manifest_path)
                if backup is not None:
                    apply_orphan_removals(plugins, victims)
                    changed = True
                    for _, _, project_path in victims:
                        info(f"plugin manifest orphan: {project_path}")
                    info(
                        f"plugin manifest: removed {len(victims)} orphan worktree entries "
                        f"under {worktree_base} (backup: {backup})"
                    )

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
