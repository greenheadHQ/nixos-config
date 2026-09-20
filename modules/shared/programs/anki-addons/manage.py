"""Apply pinned add-ons to a writable tree, with whole-tree rollback snapshots.

Never opens a collection or prefs database. Call only while Anki is closed.
The process guard is conservative (any Anki owned by this user blocks writes).
"""

import argparse
import contextlib
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import uuid


MARKER = ".nix-managed.json"
STATE = ".nix-anki-addons"


def read_json(path, default=None):
    return json.loads(path.read_text()) if path.exists() else default


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    path.chmod(0o600)


def checked_tree(root):
    """Do not traverse another manager's symlinks or special files."""
    if root.is_symlink():
        raise ValueError(f"Symlink is not supported: {root}")
    if root.exists() and not root.is_dir():
        raise ValueError(f"Expected directory: {root}")
    for path in root.rglob("*"):
        if path.is_symlink() or not (path.is_dir() or path.is_file()):
            raise ValueError(f"Symlink/special file is not supported: {path}")


def relative_file(name):
    path = Path(name)
    if not name or path.is_absolute() or ".." in path.parts or str(path) != name:
        raise ValueError(f"Invalid managed path: {name}")
    if path.parts[0] == "user_files" or name == "meta.json":
        raise ValueError(f"Runtime file cannot be managed as code: {name}")
    return path


def validate_record(record):
    if not isinstance(record, dict):
        raise ValueError("Invalid ownership record")
    for addon_id, item in record.items():
        if not re.fullmatch(r"[0-9]+", addon_id):
            raise ValueError(f"Invalid AnkiWeb ID: {addon_id}")
        for name in item["files"]:
            relative_file(name)
        if not isinstance(item["config_keys"], list):
            raise ValueError("Invalid config keys")


def copy_writable(source, target):
    shutil.copytree(source, target)
    for path in [target, *target.rglob("*")]:
        path.chmod(0o700 if path.is_dir() else 0o600 | (path.stat().st_mode & stat.S_IXUSR))


def fingerprint(root):
    if not root.exists():
        return None
    result = []
    for path in sorted(root.rglob("*")):
        digest = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
        result.append((str(path.relative_to(root)), digest, bool(path.stat().st_mode & stat.S_IXUSR)))
    return result


def running_anki():
    # On macOS, comm is truncated to 16 columns unless it is the LAST column.
    # Read args separately for Python launchers; never split a full executable
    # path on spaces or match arbitrary test-runner arguments mentioning Anki.
    ps = "/bin/ps" if Path("/bin/ps").exists() else "/usr/bin/ps"
    output = subprocess.check_output(
        [ps, "-axww", "-o", "uid=,pid=,comm="], text=True
    )
    python_pids = set()
    for line in output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) < 3 or int(fields[0]) != os.getuid():
            continue
        executable = Path(fields[2]).name.lower()
        if executable in {"anki", ".anki-wrapped"}:
            return True
        if executable.startswith("python"):
            python_pids.add(fields[1])
    if python_pids:
        output = subprocess.check_output([ps, "-axww", "-o", "uid=,pid=,args="], text=True)
        for line in output.splitlines():
            fields = line.strip().split(None, 2)
            if len(fields) != 3 or int(fields[0]) != os.getuid() or fields[1] not in python_pids:
                continue
            if re.search(r"(?:^|\s)(?:\S*/(?:anki|\.anki-wrapped)|-m (?:anki|aqt))(?:\s|$)", fields[2]):
                return True
    return False


def require_closed():
    if running_anki():
        raise RuntimeError("Close Anki, then run: anki-addons apply")


class Manager:
    def __init__(self, base):
        self.base = Path(base)
        self.target = self.base / "addons21"
        self.state = self.base / STATE
        self.journal = self.state / "pending.json"

    @contextlib.contextmanager
    def lock(self):
        # Reject symlinked parents as well: activation must not follow a moved
        # collection into a different user's or sync service's directory.
        for path in [self.base, *self.base.parents]:
            if path.is_symlink():
                raise ValueError(f"Symlinked base is not supported: {path}")
        checked_tree(self.state)
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.state.chmod(0o700)
        with (self.state / "lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            checked_tree(self.target)
            yield

    def ensure_ready(self):
        if self.journal.exists():
            raise RuntimeError("Interrupted apply detected. Close Anki and run: anki-addons recover")

    def commit(self, stage):
        require_closed()  # Recheck after staging, just before replacing files.
        backup_id = uuid.uuid4().hex
        backup = self.state / backup_id
        had_target = self.target.exists()
        write_json(self.journal, {"backup": backup_id, "had_target": had_target})
        try:
            if had_target:
                self.target.rename(backup)
            stage.rename(self.target)
        except BaseException:
            if backup.exists() and not self.target.exists():
                backup.rename(self.target)
            self.journal.unlink()
            raise
        self.journal.unlink()
        print(f"Applied. Backup: {backup_id}" if had_target else "Applied (first installation).")

    def apply(self, manifest):
        self.ensure_ready()
        old = read_json(self.target / MARKER, {})
        validate_record(old)
        with tempfile.TemporaryDirectory(prefix="stage-", dir=self.state) as tmp:
            stage = Path(tmp) / "addons21"
            if self.target.exists():
                copy_writable(self.target, stage)
            else:
                stage.mkdir(mode=0o700)
            new = {}
            for addon_id, addon in manifest.items():
                if not re.fullmatch(r"[0-9]+", addon_id):
                    raise ValueError(f"Invalid AnkiWeb ID: {addon_id}")
                if not isinstance(addon["config"], dict) or type(addon["enabled"]) is not bool:
                    raise ValueError("Expected config object and enabled boolean")
                source = Path(addon["source"])
                checked_tree(source)
                if not (source / "__init__.py").is_file():
                    raise ValueError(f"Missing add-on source: {source}")
                dest = stage / addon_id
                dest.mkdir(exist_ok=True)
                previous = old.get(addon_id, {"files": [], "config_keys": []})
                old_directories = set()
                for name in previous["files"]:
                    relative = relative_file(name)
                    (dest / relative).unlink(missing_ok=True)
                    old_directories.update(p for p in relative.parents if p != Path("."))
                # A package may replace foo/bar.py with a file named foo.
                # Only prune empty ancestors of previously managed code, never
                # a non-empty directory containing unknown runtime/user files.
                for relative in sorted(old_directories, key=lambda p: len(p.parts), reverse=True):
                    try:
                        (dest / relative).rmdir()
                    except OSError as exc:
                        if exc.errno not in {errno.ENOENT, errno.ENOTEMPTY, errno.EEXIST}:
                            raise
                files = []
                for path in sorted(source.rglob("*")):
                    if not path.is_file():
                        continue
                    rel = path.relative_to(source)
                    name = str(rel)
                    if "__pycache__" in rel.parts or name == "meta.json":
                        continue
                    target = dest / rel
                    if rel.parts[0] == "user_files":
                        if target.exists():
                            continue
                    else:
                        relative_file(name)
                        files.append(name)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(path, target)
                    target.chmod(0o600 | (path.stat().st_mode & stat.S_IXUSR))
                meta = read_json(dest / "meta.json", {})
                settings = meta.get("config", {}).copy()
                for key in previous["config_keys"]:
                    settings.pop(key, None)
                settings.update(addon["config"])
                if settings or "config" in meta:
                    meta["config"] = settings
                meta.update(name=addon["name"], mod=addon["mod"],
                            disabled=not addon["enabled"], update_enabled=False)
                write_json(dest / "meta.json", meta)
                new[addon_id] = {"files": files, "config_keys": sorted(addon["config"])}
            # Ownership is explicit: never delete an unlisted, unmanaged add-on.
            for addon_id in old.keys() - new.keys():
                if (stage / addon_id).exists():
                    shutil.rmtree(stage / addon_id)
            write_json(stage / MARKER, new)
            if fingerprint(stage) == fingerprint(self.target):
                print("Already matches the declaration.")
                return
            self.commit(stage)

    def restore(self, backup_id):
        self.ensure_ready()
        if not re.fullmatch(r"[0-9a-f]{32}", backup_id):
            raise ValueError("Invalid backup ID")
        backup = self.state / backup_id
        if not backup.is_dir():
            raise ValueError("Backup does not exist")
        checked_tree(backup)
        with tempfile.TemporaryDirectory(prefix="restore-", dir=self.state) as tmp:
            stage = Path(tmp) / "addons21"
            copy_writable(backup, stage)
            self.commit(stage)

    def recover(self):
        pending = read_json(self.journal)
        if pending is None:
            raise ValueError("No interrupted apply")
        backup_id = pending["backup"]
        if not re.fullmatch(r"[0-9a-f]{32}", backup_id):
            raise ValueError("Invalid recovery record")
        backup = self.state / backup_id
        if backup.exists():
            if self.target.exists():
                self.target.rename(self.state / uuid.uuid4().hex)
            backup.rename(self.target)
        elif not pending["had_target"] and self.target.exists():
            self.target.rename(self.state / uuid.uuid4().hex)
        elif pending["had_target"] and not self.target.exists():
            raise RuntimeError("Recovery backup and add-on tree are both missing; restore a manual backup")
        self.journal.unlink()
        print("Recovered the pre-apply add-on tree. Review it before applying again.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--base", type=Path, required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("apply").add_argument("--defer-if-running", action="store_true")
    sub.add_parser("restore").add_argument("backup")
    sub.add_parser("recover")
    args = parser.parse_args()
    try:
        if running_anki():
            if args.command == "apply" and args.defer_if_running:
                print("Anki is running: add-on apply deferred. Close Anki, then run: anki-addons apply")
                return 0
            require_closed()
        manager = Manager(args.base.absolute())
        with manager.lock():
            if args.command == "apply":
                manager.apply(read_json(args.manifest))
            elif args.command == "restore":
                manager.restore(args.backup)
            else:
                manager.recover()
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as exc:
        parser.exit(1, f"anki-addons: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
