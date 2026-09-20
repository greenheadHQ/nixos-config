"""Limited restoration of server-owned applied-and-verified note type bytes.

All methods run under the helper mutation lock. This is intentionally separate
from arbitrary schema operations: conversation confirmation is not a root key,
an independent human-authentication UI, or permission to choose a full upload.
The caller supplies a managed name and request ID, never model/file contents.
"""
from __future__ import annotations

import base64
import copy
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import secrets
import sqlite3
import stat
import tempfile
import time
from typing import Any, Callable

from .managed_bundle import (build_bundle, canonical_model, diff_bundle, filename,
                             native_from_definition, read_assets, validate_bundle)
from .operations import OperationError, atomic_json, digest, request_identifier


def _error(reason: str) -> None:
    raise OperationError("managed-restore-" + reason)


def _file_hash(path: Path) -> str:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            _error("backup-not-regular")
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _identities(native: dict) -> dict:
    return {"id": native["id"],
            "fields": [(f.get("id"), f["ord"], f["name"]) for f in native["flds"]],
            "templates": [(t.get("id"), t["ord"], t["name"]) for t in native["tmpls"]]}


def _rows(collection: Any) -> dict:
    return {table: collection.db.all(f"select * from {table} order by id")
            for table in ("notes", "cards", "revlog")}


def _native(collection: Any, model_id: int) -> dict:
    # ModelManager.get() caches dictionaries. Inspect the native backend on
    # each boundary so an independent sync/edit cannot leave a stale approval.
    return json.loads(collection._backend.get_notetype_legacy(model_id))


def _preservation(rows: dict) -> dict:
    return {table: {"count": len(values), "sha256": digest(values)} for table, values in rows.items()}


class AnkiRestoreAdapter:
    """Real Anki APIs; no live SQL writes, collection replacement or sync."""

    def __init__(self, window: Any) -> None:
        self.window = window

    @property
    def col(self) -> Any:
        if self.window.col is None:
            _error("collection-not-open")
        return self.window.col

    @property
    def version(self) -> str:
        from anki.buildinfo import version
        return version

    def capture(self, baseline: dict) -> dict:
        model = _native(self.col, baseline["model_id"])
        if model is None or model["name"] != baseline["model_name"]:
            _error("model-binding-mismatch")
        names = [entry["filename"] for entry in baseline["bundle"]["assets"]]
        assets = read_assets(self.col.media.dir(), names)
        native = copy.deepcopy(model)
        # Unknown native settings are unavailable, never implicitly restorable.
        canonical_model(native)
        return {"model": native, "preservation": _preservation(_rows(self.col)),
                "assets": {name: ({"sha256": hashlib.sha256(assets["files"][name]).hexdigest(),
                                   "size": len(assets["files"][name])} if name in assets["files"] else None)
                           for name in names},
                "asset_bytes": assets["files"]}

    def verify_backup(self, backup: dict, baseline: dict, before: dict) -> dict:
        """Open only an exported copy using this process's exact Anki version.

        The official importer handles compressed modern colpkg files. A note
        type update can generate cards even when only HTML changed, so compare
        complete rows and the backend-recomputed generation rules separately.
        """
        from anki._backend import RustBackend
        from anki.collection import Collection

        source = Path(backup["path"])
        if _file_hash(source) != backup["sha256"]:
            _error("backup-hash-mismatch")
        with tempfile.TemporaryDirectory(prefix="anki-managed-restore-") as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            package = root / "source.colpkg"
            fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "rb") as inp, package.open("xb") as out:
                os.chmod(package, 0o600)
                while block := inp.read(1024 * 1024):
                    out.write(block)
            if _file_hash(package) != backup["sha256"]:
                _error("backup-changed-during-copy")
            backend = RustBackend()
            target = root / "collection.anki2"
            backend.import_collection_package(
                col_path=str(target), backup_path=str(package),
                media_folder=str(root / "collection.media"), media_db=str(root / "collection.media.db2"))
            trial = Collection(str(target), backend=backend)
            try:
                native = _native(trial, baseline["model_id"])
                original = _rows(trial)
                if native != before["model"] or _preservation(original) != before["preservation"]:
                    _error("backup-state-mismatch")
                candidate = native_from_definition(native, baseline["bundle"]["definition"])
                trial.models.update_dict(candidate)
                after = _native(trial, baseline["model_id"])
                if (_rows(trial) != original or _identities(after) != _identities(native)
                        or after["req"] != native["req"]
                        or canonical_model(after) != baseline["bundle"]["definition"]):
                    _error("isolated-preservation-or-generation-failed")
                return {"state": "verified", "anki_version": self.version,
                        "preservation": before["preservation"], "backup_sha256": backup["sha256"]}
            finally:
                trial.close()

    def _write_asset(self, name: str, data: bytes) -> None:
        filename(name)
        directory = os.open(self.col.media.dir(), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        temporary = ".managed-" + secrets.token_hex(16)
        try:
            # Reject a replaced symlink or nonregular file before touching it.
            read_assets(self.col.media.dir(), [name])
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=directory)
            with os.fdopen(fd, "wb") as out:
                out.write(data)
                out.flush()
                os.fsync(out.fileno())
            os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
            os.fsync(directory)
        finally:
            try:
                os.unlink(temporary, dir_fd=directory)
            except FileNotFoundError:
                pass
            os.close(directory)
        # Anki's general add-media API renames conflicting contents. The exact
        # bytes now exist, so it keeps this filename and registers its checksum
        # for upload even if filesystem mtimes happened to match.
        if self.col.media.write_data(name, data) != name:
            _error("media-registration-name-mismatch")
        if read_assets(self.col.media.dir(), [name])["files"].get(name) != data:
            _error("media-readback-mismatch")

    def media_registered(self, baseline: dict) -> bool:
        """Readback for interrupted registration, without repeating any write."""
        if not baseline["asset_bytes"]:
            return True
        from anki.media import media_paths_from_col_path
        path = Path(media_paths_from_col_path(self.col.path)[1])
        if path.is_symlink() or not path.is_file():
            return False
        with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as db:
            for name, data in baseline["asset_bytes"].items():
                entry = db.execute("select csum from media where fname=?", (name,)).fetchone()
                if entry != (hashlib.sha1(data).hexdigest(),):
                    return False
        return True

    def apply(self, baseline: dict, before: dict, progress: Callable[[str, str], None]) -> None:
        for name, data in baseline["asset_bytes"].items():
            progress("asset:" + name, "applying")
            self._write_asset(name, data)
            progress("asset:" + name, "verified")
        progress("model", "applying")
        native = _native(self.col, baseline["model_id"])
        if native != before["model"]:
            _error("native-model-changed-before-apply")
        self.col.models.update_dict(native_from_definition(native, baseline["bundle"]["definition"]))
        self.window.reset()
        after = _native(self.col, baseline["model_id"])
        if (canonical_model(after) != baseline["bundle"]["definition"]
                or _identities(after) != _identities(native) or after["req"] != native["req"]):
            _error("model-readback-mismatch")
        progress("model", "verified")


class ManagedRestore:
    """Durable preview, component journal and independently verified delivery."""

    def __init__(self, root: Path, store: Any, adapter: Any,
                 restore_point: Callable[[str], dict], collection_snapshot: Callable[[], dict],
                 sync_status: Callable[[], dict], ttl: int = 600,
                 clock: Callable[[], float] = time.time) -> None:
        self.root, self.store, self.adapter = Path(root), store, adapter
        self.restore_point, self.collection_snapshot, self.sync_status = restore_point, collection_snapshot, sync_status
        self.ttl, self.clock = ttl, clock
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.root.is_symlink():
            _error("journal-directory-is-symlink")
        os.chmod(self.root, 0o700)
        for path in self.root.glob("*.json"):
            record = self._load_path(path)
            if record["state"] == "applying":
                record.update(state="unknown", error="process-stopped-during-restore-do-not-repeat")
                self._save(record)
            elif record["state"] == "preparing":
                record.update(state="not-applied", error="preparation-interrupted-use-new-request-id")
                self._save(record)

    def _path(self, request_id: str) -> Path:
        request_identifier(request_id)
        return self.root / (hashlib.sha256(request_id.encode()).hexdigest()[:32] + ".json")

    def _load_path(self, path: Path) -> dict:
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "r", encoding="utf-8") as stream:
                record = json.load(stream)
        except FileNotFoundError:
            _error("not-found")
        if (not isinstance(record, dict) or self._path(record.get("request_id")) != path
                or record.get("operation_id") != path.stem):
            _error("invalid-journal")
        return record

    def _read(self, request_id: str) -> dict:
        return self._load_path(self._path(request_id))

    def _save(self, record: dict) -> None:
        atomic_json(self._path(record["request_id"]), record)

    def _public(self, record: dict) -> dict:
        keys = ("operation_id", "request_id", "model_name", "state", "created_at", "expires_at",
                "applied_at", "summary", "components", "verification", "sync", "error")
        result = {key: record[key] for key in keys if key in record}
        result["confirmation_required"] = True
        result["backup"] = {key: record.get("backup", {}).get(key) for key in ("sha256", "mirrored")}
        if result["state"] == "prepared":
            result["preview_token"] = record["preview_token"]
        if result["state"] == "applying":
            result["state"] = "unknown"
        result["client_delivery_confirmed"] = False
        return result

    def status(self, request_id: str) -> dict:
        record = self._read(request_id)
        if record["state"] == "prepared" and self.clock() >= record["expires_at"]:
            record.update(state="expired", error="preview-expired-use-new-request-id")
            self._save(record)
        return self._public(record)

    def has_pending(self, model_name: str) -> bool:
        return any((record := self._load_path(path))["model_name"] == model_name
                   and record["state"] in ("applying", "partial", "unknown")
                   for path in self.root.glob("*.json"))

    @staticmethod
    def _authorization(baseline: dict) -> dict:
        validate_bundle(baseline["bundle"], baseline["asset_bytes"])
        if baseline.get("operator_verified") is not True or not baseline.get("evidence"):
            _error("baseline-not-verified")
        return {key: baseline[key] for key in ("record_id", "model_id", "model_name", "binding")} | {
            "digest": baseline["bundle"]["digest"]}

    def _observe(self, baseline: dict) -> tuple[dict, dict]:
        # Normalize scheduler metadata before observing the live model/rows.
        collection = self.collection_snapshot()
        captured = self.adapter.capture(baseline)
        state = {key: value for key, value in captured.items() if key != "asset_bytes"}
        return {"collection": collection, **state}, captured["asset_bytes"]

    def prepare(self, model_name: str, request_id: str) -> dict:
        path = self._path(request_id)
        if path.exists():
            record = self._read(request_id)
            if record["model_name"] != model_name:
                _error("request-id-payload-mismatch")
            return self.status(request_id)
        if self.has_pending(model_name):
            _error("unresolved-restore-inspect-original-request")
        baseline = self.store.get_baseline(model_name)
        authorization = self._authorization(baseline)
        before, assets = self._observe(baseline)
        native_from_definition(before["model"], baseline["bundle"]["definition"])
        observed = build_bundle(before["model"], assets)
        changed = diff_bundle(baseline["bundle"], observed)
        if not changed:
            _error("already-matches-baseline")
        record = {"operation_id": path.stem, "request_id": request_id, "model_name": model_name,
                  "state": "preparing", "created_at": self.clock(), "authorization": authorization,
                  "before": before, "summary": {"target_digest": baseline["bundle"]["digest"],
                      "changed_items": changed, "preservation": before["preservation"],
                      "scope": "front-back-html-css-registered-js-css-only"},
                  "sync": {"state": "not-started"}, "components": {}}
        self._save(record)
        try:
            backup = self.restore_point(record["operation_id"])
            if backup.get("mirrored") is not True or not backup.get("path"):
                _error("verified-backup-required")
            record["backup"] = backup
            self._save(record)
            after, copied_assets = self._observe(baseline)
            if after != before or copied_assets != assets:
                _error("changed-during-backup")
            # Preimages include confirmed absence. Their bytes live in the
            # private journal, independently of the media-free colpkg backup.
            record["media_before"] = {entry["filename"]: (
                base64.b64encode(assets[entry["filename"]]).decode("ascii")
                if entry["filename"] in assets else None) for entry in baseline["bundle"]["assets"]}
            record["media_before_digest"] = digest(record["media_before"])
            self._save(record)
            record["verification"] = self.adapter.verify_backup(backup, baseline, before)
            if record["verification"].get("state") != "verified":
                _error("isolated-verification-required")
            if self._observe(baseline)[0] != before:
                _error("changed-during-isolated-validation")
            record.update(state="prepared", preview_token=secrets.token_hex(32), expires_at=self.clock() + self.ttl)
            self._save(record)
        except Exception as error:
            record.update(state="not-applied", error="preparation-failed:" + type(error).__name__)
            self._save(record)
            raise
        return self._public(record)

    def _baseline(self, record: dict) -> dict:
        baseline = self.store.get_baseline(record["model_name"])
        if self._authorization(baseline) != record["authorization"]:
            _error("baseline-changed-reprepare")
        return baseline

    def _postcheck(self, record: dict, baseline: dict) -> dict:
        after, assets = self._observe(baseline)
        if (after["preservation"] != record["before"]["preservation"]
                or _identities(after["model"]) != _identities(record["before"]["model"])
                or build_bundle(after["model"], assets) != baseline["bundle"]
                or not self.adapter.media_registered(baseline)):
            _error("postcondition-unconfirmed")
        return after

    def apply(self, request_id: str, token: str, confirm: bool = False) -> dict:
        record = self._read(request_id)
        if record["state"] != "prepared":
            return self.status(request_id)
        if self.clock() >= record["expires_at"]:
            return self.status(request_id)
        if confirm is not True:
            _error("explicit-confirmation-required")
        if (not isinstance(token, str) or len(token) != 64
                or any(c not in "0123456789abcdef" for c in token)
                or not secrets.compare_digest(token, record["preview_token"])):
            _error("preview-token-mismatch")
        baseline = self._baseline(record)
        current, _ = self._observe(baseline)
        if current != record["before"]:
            _error("stale-preview-reprepare")
        if (self.adapter.version != record["verification"]["anki_version"]
                or digest(record["media_before"]) != record["media_before_digest"]
                or _file_hash(Path(record["backup"]["path"])) != record["backup"]["sha256"]):
            _error("verification-or-backup-changed")
        record["state"] = "applying"
        self._save(record)

        def progress(name: str, state: str) -> None:
            record["components"][name] = state
            self._save(record)

        try:
            self.adapter.apply(baseline, record["before"], progress)
            self._postcheck(record, baseline)
            record.update(state="applied", applied_at=self.clock(), sync={"state": "pending"})
            record["components"]["preservation"] = "verified"
        except Exception as error:
            record.update(state="partial" if "verified" in record["components"].values() else "unknown",
                          error="restore-result-unconfirmed:" + type(error).__name__)
        self._save(record)
        return self._public(record)

    def diagnose(self, request_id: str) -> dict:
        """Prove an interrupted result; never re-run a mutation or registration."""
        record = self._read(request_id)
        if record["state"] not in ("unknown", "partial"):
            return self.status(request_id)
        try:
            baseline = self._baseline(record)
            self._postcheck(record, baseline)
        except Exception:
            return self._public(record)
        record.update(state="applied", applied_at=self.clock(), sync={"state": "pending"})
        record.pop("error", None)
        record["components"]["preservation"] = "verified"
        record["verification"]["interrupted_result_verified_at"] = self.clock()
        self._save(record)
        return self._public(record)

    @staticmethod
    def _timestamp(value: Any) -> float:
        if not isinstance(value, str):
            return 0
        try:
            parsed = datetime.fromisoformat(value)
            return parsed.timestamp() if parsed.utcoffset() is not None else 0
        except ValueError:
            return 0

    def delivery(self, request_id: str) -> dict:
        record = self._read(request_id)
        if record["state"] != "applied":
            return self._public(record)
        if record["sync"]["state"] == "synced":
            return self._public(record)
        try:
            baseline = self._baseline(record)
            # Sync may legitimately change usn/mod and include later reviews;
            # preservation was already proved at the local apply boundary.
            current = self.adapter.capture(baseline)
            if build_bundle(current["model"], current["asset_bytes"]) != baseline["bundle"]:
                _error("content-changed-before-delivery-verification")
            status = self.sync_status() or {}
            detail = status.get("sync") or {}
            action = detail.get("action", status.get("action"))
            media = (detail.get("media") or {}).get("state", status.get("media_state"))
            fresh = (self._timestamp(status.get("runStartedAt")) > record["applied_at"]
                     and self._timestamp(status.get("lastSuccessAt")) >= self._timestamp(status.get("runStartedAt")))
            ok = (fresh and bool(status.get("runId")) and status.get("result") == "success"
                  and action in ("normal", "approved-full-upload")
                  and (not baseline["asset_bytes"] or media == "synced"))
            record["sync"] = {"state": "synced" if ok else "blocked" if action == "full-sync-required" else "pending",
                              "run_id": status.get("runId"), "action": action,
                              "media_state": media or "unknown"}
        except Exception as error:
            record["sync"] = {"state": "pending", "error": "delivery-unconfirmed:" + type(error).__name__}
        self._save(record)
        return self._public(record)
