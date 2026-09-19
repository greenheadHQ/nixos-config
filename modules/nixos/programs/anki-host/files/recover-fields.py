"""Read selected note fields from a backup into a private file, never a live DB.

The installed root-only wrapper supplies paths and a network namespace without
interfaces. No credential is loaded, collection is synced, or live profile opened.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


class RecoveryError(Exception):
    pass


def _checked_path(path: Path) -> Path:
    if not path.is_absolute() or ".." in path.parts:
        raise RecoveryError("absolute-path-required")
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise RecoveryError("symlink-path-refused")
    return path


@contextlib.contextmanager
def _quiet_backend():
    """Anki/Rust diagnostics must not put imported content on either output FD."""
    sys.stdout.flush()
    sys.stderr.flush()
    saved = [os.dup(fd) for fd in (1, 2)]
    try:
        with open(os.devnull, "wb") as sink:
            for fd in (1, 2):
                os.dup2(sink.fileno(), fd)
            yield
    finally:
        sys.stdout.flush()
        sys.stderr.flush()
        for fd, old in zip((1, 2), saved, strict=True):
            os.dup2(old, fd)
            os.close(old)


def _extract(package: Path, directory: Path, note_ids: list[int]) -> list[dict]:
    # collection.anki2 is a dummy in modern packages. The official importer
    # handles legacy .anki21 and zstd .anki21b without manual schema assumptions.
    with _quiet_backend():
        from anki._backend import RustBackend
        from anki.collection import Collection

        backend = RustBackend()
        collection_path = directory / "collection.anki2"
        backend.import_collection_package(
            col_path=str(collection_path), backup_path=str(package),
            media_folder=str(directory / "collection.media"),
            media_db=str(directory / "collection.media.db2"),
        )
        collection = Collection(str(collection_path), backend=backend)
        try:
            notes = []
            for note_id in note_ids:
                if collection.find_notes(f"nid:{note_id}") != [note_id]:
                    raise RecoveryError("note-not-in-backup")
                note = collection.get_note(note_id)
                model = note.note_type()
                if not model:
                    raise RecoveryError("note-type-not-in-backup")
                pairs = list(note.items())
                if len(pairs) != len(note.fields) or len({name for name, _ in pairs}) != len(pairs):
                    raise RecoveryError("ambiguous-backup-fields")
                notes.append({
                    "note_id": note_id, "guid": note.guid, "model_id": note.mid,
                    "model_name": model["name"], "fields": dict(pairs),
                })
            return notes
        finally:
            collection.close()


def recover_fields(backup: Path, note_ids: list[int], output: Path,
                   allowed_roots: list[Path], *, instance: str) -> dict:
    """No output overwrite; every Collection write is inside a discarded copy."""
    if (not note_ids or len(note_ids) > 100 or len(set(note_ids)) != len(note_ids)
            or any(type(nid) is not int or not 0 < nid < 2**63 for nid in note_ids)):
        raise RecoveryError("invalid-note-ids")
    backup = _checked_path(backup)
    if backup.suffix != ".colpkg" or backup.parent not in allowed_roots:
        raise RecoveryError("backup-outside-allowed-directories")
    output = _checked_path(output)
    parent = output.parent.stat()
    if (not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.geteuid()
            or stat.S_IMODE(parent.st_mode) & 0o077):
        raise RecoveryError("output-directory-must-be-private-and-owned")
    if output.exists():
        raise RecoveryError("output-already-exists")

    # O_NOFOLLOW protects the final component; all trusted backup roots and
    # their ancestors are checked above. Copy through one FD before importing.
    fd = os.open(backup, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source, tempfile.TemporaryDirectory(prefix="anki-field-recovery-") as temp:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size == 0:
            raise RecoveryError("backup-not-regular-or-empty")
        private = Path(temp)
        os.chmod(private, 0o700)
        package = private / "source.colpkg"
        sha = hashlib.sha256()
        with package.open("xb") as dest:
            os.chmod(package, 0o600)
            while block := source.read(1024 * 1024):
                sha.update(block)
                dest.write(block)
        source.seek(0)
        second_sha = hashlib.file_digest(source, "sha256").hexdigest()
        after = os.fstat(source.fileno())
        if (sha.hexdigest() != second_sha
                or (before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                != (after.st_size, after.st_mtime_ns, after.st_ctime_ns)):
            raise RecoveryError("backup-changed-during-copy")
        notes = _extract(package, private, note_ids)

    result = {"format_version": 1, "instance": instance,
              "backup": {"name": backup.name, "sha256": sha.hexdigest(), "bytes": before.st_size,
                         "modified_at_unix": before.st_mtime},
              "notes": notes}
    # The private parent makes creation/unlink safe against another local user.
    out_fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(out_fd, "w", encoding="utf-8") as dest:
            os.fchmod(dest.fileno(), 0o600)
            json.dump(result, dest, ensure_ascii=False, indent=2)
            dest.write("\n")
            dest.flush()
            os.fsync(dest.fileno())
        directory_fd = os.open(output.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException:
        output.unlink(missing_ok=True)
        raise
    # Never include note IDs, field names/values, note-type or backup names here.
    return {"ok": True, "note_count": len(notes), "backup_sha256": sha.hexdigest()}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Recover selected fields to a private JSON file; never applies changes.")
    parser.add_argument("--instance", required=True)
    parser.add_argument("--backup", type=Path, required=True)
    parser.add_argument("--note-id", type=int, action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if os.geteuid() != 0:
            raise RecoveryError("root-required")
        instances = json.loads(os.environ["ANKI_RECOVERY_INSTANCES"])
        if args.instance not in instances:
            raise RecoveryError("unknown-instance")
        state = Path(os.environ["ANKI_RECOVERY_STATE_ROOT"]) / args.instance
        roots = [state / "Anki2" / args.instance / "backups", state / "backups", state / "restore-points",
                 Path(os.environ["ANKI_RECOVERY_DAILY_ROOT"]) / args.instance,
                 Path(os.environ["ANKI_RECOVERY_RESTORE_ROOT"]) / args.instance]
        os.umask(0o077)
        result = recover_fields(args.backup, args.note_id, args.output, roots, instance=args.instance)
        print(json.dumps(result))
        return 0
    except RecoveryError as error:
        print(json.dumps({"ok": False, "error": str(error)}), file=sys.stderr)
    except Exception:
        # Backend exceptions may contain card text or filesystem details.
        print(json.dumps({"ok": False, "error": "backup-recovery-failed"}), file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
