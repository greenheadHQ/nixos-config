"""Root-only runtime credentials, restore-point mirror and schema approval CLI.

All paths/ports come from the Nix wrapper. No request accepts a filesystem path,
URL, upload direction, retention value, or arbitrary systemd unit.
"""

from __future__ import annotations

import argparse
import grp
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import time
import urllib.request
import zipfile
from pathlib import Path
from typing import Any


def operation_id(value: str) -> str:
    if re.fullmatch(r"[0-9a-f]{32}", value) is None:
        raise ValueError("invalid-operation-id")
    return value


def sync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_file(path: Path, data: bytes, group: int = 0, mode: int = 0o600) -> None:
    tmp = path.with_name(path.name + ".partial-" + secrets.token_hex(8))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchown(stream.fileno(), 0, group)
            os.fchmod(stream.fileno(), mode)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
        sync_dir(path.parent)
    finally:
        tmp.unlink(missing_ok=True)


def keys(root: Path) -> None:
    root.mkdir(parents=True, mode=0o700, exist_ok=True)
    for role in ("read", "operation", "maintenance", "schema"):
        path = root / role
        if path.exists():
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                st = os.fstat(fd)
                value = os.read(fd, 128).decode("ascii").strip()
                if (not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o077
                        or re.fullmatch(r"[0-9a-f]{64}", value) is None):
                    raise ValueError("invalid-existing-runtime-credential")
            finally:
                os.close(fd)
        else:
            atomic_file(path, (secrets.token_hex(32) + "\n").encode())


def file_hash(path: Path) -> str:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError("restore-point-not-regular")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            return hashlib.file_digest(stream, "sha256").hexdigest()
    finally:
        os.close(fd)


def mirror(state: Path, archive: Path, instance: str, opid: str, keep: int, group: int) -> None:
    source = state / "restore-points" / (opid + ".colpkg")
    destination = archive / instance / (opid + ".colpkg")
    destination.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    if destination.parent.is_symlink() or source.parent.is_symlink():
        raise ValueError("restore-point-directory-is-symlink")
    tmp = destination.with_suffix(".partial-" + secrets.token_hex(8))
    source_fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(source_fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size <= 0:
            raise ValueError("restore-point-not-regular-or-empty")
        out_fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        sha = hashlib.sha256()
        with os.fdopen(out_fd, "wb") as out, os.fdopen(source_fd, "rb", closefd=False) as inp:
            while chunk := inp.read(1024 * 1024):
                sha.update(chunk)
                out.write(chunk)
            out.flush()
            os.fsync(out.fileno())
        after = os.fstat(source_fd)
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise ValueError("restore-point-changed-during-copy")
        with zipfile.ZipFile(tmp) as package:
            if package.testzip() is not None or not any(n.startswith("collection.anki") for n in package.namelist()):
                raise ValueError("restore-point-invalid-archive")
        checksum = sha.hexdigest()
        if file_hash(tmp) != checksum:
            raise ValueError("restore-point-copy-hash-mismatch")
        # link is atomic and cannot overwrite an existing backup, including a
        # symlink. An idempotent retry accepts only the same verified contents.
        try:
            os.link(tmp, destination)
        except FileExistsError:
            if file_hash(destination) != checksum:
                raise ValueError("existing-hdd-restore-point-mismatch") from None
        sync_dir(destination.parent)
        receipt = {"operation_id": opid, "instance": instance, "mirrored": True,
                   "sha256": checksum, "bytes": before.st_size, "created_at": time.time()}
        atomic_file(source.with_suffix(".receipt.json"), json.dumps(receipt).encode(), group, 0o640)
        # Only successfully mirrored files are eligible for SSD pruning. The
        # current operation stays available even if older mtimes were imported.
        candidates = []
        for candidate in source.parent.glob("*.colpkg"):
            if (re.fullmatch(r"[0-9a-f]{32}\.colpkg", candidate.name) and candidate != source
                    and candidate.with_suffix(".receipt.json").is_file() and not candidate.is_symlink()):
                candidates.append(candidate)
        candidates.sort(key=lambda p: p.stat().st_mtime_ns, reverse=True)
        for old in candidates[max(0, keep - 1):]:
            # Root HDD ownership is the durable authority, not a writable SSD
            # receipt. Validate the retained copy before removing the SSD one.
            retained = destination.parent / old.name
            if retained.is_file() and not retained.is_symlink() and file_hash(old) == file_hash(retained):
                old.unlink()
                old.with_suffix(".receipt.json").unlink(missing_ok=True)
        sync_dir(source.parent)
    finally:
        os.close(source_fd)
        tmp.unlink(missing_ok=True)


def helper(path: str, payload: dict[str, Any], key: str, port: int, timeout: int) -> dict[str, Any]:
    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", json.dumps(payload).encode(),
        {"Content-Type": "application/json", "Authorization": "Bearer " + key})
    # Loopback authorization must not follow environment proxies or redirects.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args: Any, **kwargs: Any) -> None:
            return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=timeout) as response:
        value = json.load(response)
    if not isinstance(value, dict) or value.get("ok") is not True:
        raise ValueError("helper-request-failed")
    return value["result"]


def approve(state: Path, credentials: Path, instance: str, opid: str, group: int, port: int, ttl: int, timeout: int) -> None:
    key = (credentials / "schema").read_text(encoding="ascii").strip()
    if re.fullmatch(r"[0-9a-f]{64}", key) is None:
        raise ValueError("invalid-schema-credential")
    def call(path: str) -> dict[str, Any]:
        return helper(path, {"operation_id": opid}, key, port, timeout)
    operation = call("/operations/status")
    if operation.get("state") == "prepared":
        previous = json.loads((state / "sync-status.json").read_text()).get("runId")
        subprocess.run(["systemctl", "start", f"anki-host-sync-{instance}.service"], check=True)
        status = json.loads((state / "sync-status.json").read_text())
        if (not status.get("runId") or status["runId"] == previous or status.get("result") != "success"
                or status.get("mode") != "normal" or status.get("sync", {}).get("action") != "normal"):
            raise ValueError("fresh-normal-presync-required")
    current = call("/schema/backup")
    approval = {"instance": instance, "operation_id": opid, "snapshot_digest": current["snapshot_digest"],
                "counts": current["counts"], "baseline": current["baseline"],
                "backup_sha256": current["operation"]["backup"]["sha256"],
                "expires_at": time.time() + ttl, "nonce": secrets.token_hex(16)}
    path = state / "approvals" / (opid + ".json")
    atomic_file(path, json.dumps(approval).encode(), group, 0o640)
    subprocess.run(["systemctl", "start", f"anki-host-schema-{instance}@{opid}.service"], check=True)
    outcome = call("/operations/status")
    print(json.dumps(outcome, ensure_ascii=False))
    if outcome.get("state") != "applied" or outcome.get("sync", {}).get("state") != "synced":
        raise ValueError("schema-operation-not-completed-inspect-status")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("keys", "mirror", "approve"))
    parser.add_argument("operation_id", nargs="?", type=operation_id)
    parser.add_argument("--confirm", action="store_true")
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("root-required")
    instance = os.environ["INSTANCE"]
    credentials = Path(os.environ["LOCAL_CREDENTIAL_ROOT"]) / instance
    if args.action == "keys":
        keys(credentials)
        return
    if not args.operation_id:
        parser.error("operation-id-required")
    state = Path(os.environ["STATE_DIR"])
    group = grp.getgrnam(os.environ["STATE_GROUP"]).gr_gid
    if args.action == "mirror":
        mirror(state, Path(os.environ["RESTORE_POINT_ARCHIVE"]), instance, args.operation_id,
               int(os.environ["RESTORE_POINT_KEEP"]), group)
    else:
        if not args.confirm:
            parser.error("--confirm-required-after-reviewing-the-operation-preview")
        approve(state, credentials, instance, args.operation_id, group, int(os.environ["HELPER_PORT"]),
                int(os.environ["OPERATION_TTL_SECS"]), int(os.environ["HELPER_CURL_MAX_TIME"]))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # No helper response, request contents, credentials or traceback in logs.
        raise SystemExit("anki-host-operations failed: " + type(error).__name__) from None
