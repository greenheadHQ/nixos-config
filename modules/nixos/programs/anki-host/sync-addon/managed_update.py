"""Root-only application of the deployed managed source, followed by registration.

Unlike remote restoration, a source update has never been applied and verified.
Only the schema credential may reach this coordinator. Its token binds the old
authority, current collection, exported backup and exact deployed candidate.
The caller holds the existing Anki main-thread mutation lock throughout each
entry point. This module never syncs or chooses an upload/download direction.
"""
from __future__ import annotations

import base64
import copy
from datetime import datetime
import os
from pathlib import Path
import re
import secrets
import stat
import time
from typing import Any, Callable

from .managed_bundle import (build_bundle, canonical_model, diff_bundle, load_bundle,
                             native_from_definition, validate_bundle)
from .managed_drift import ManagedTypeStore
from .managed_restore import AnkiRestoreAdapter, _file_hash, _identities
from .operations import OperationError, atomic_json, digest

HISTORY_FIELD = "노트 변천사"
HISTORY_OPTIONS = ("collapsed", "excludeFromSearch")


def _error(reason: str) -> None:
    raise OperationError("managed-update-" + reason)


def _identifier(value: str) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{32}", value) is None:
        _error("invalid-operation-id")
    return value


def native_from_update(current: dict, definition: dict) -> dict:
    """Root policy: content and two history-field options; preserve native IDs.

    Do not broaden native_from_definition(): the ordinary MCP restore still
    rejects every field-option change, browser format and structural change.
    """
    target = canonical_model(definition)
    original = canonical_model(current)
    comparison = copy.deepcopy(target)
    changed_options = {}
    for index, (before, after) in enumerate(zip(original["flds"], target["flds"])):
        if before["name"] == after["name"] == HISTORY_FIELD:
            changed_options[index] = {key: after[key] for key in HISTORY_OPTIONS}
            for key in HISTORY_OPTIONS:
                comparison["flds"][index][key] = before[key]
    try:
        result = native_from_definition(current, comparison)
    except ValueError:
        _error("unsupported-model-change")
    for index, options in changed_options.items():
        result["flds"][index].update(options)
    return result


class AnkiUpdateAdapter(AnkiRestoreAdapter):
    def materialize(self, current: dict, definition: dict) -> dict:
        return native_from_update(current, definition)


class ManagedUpdate:
    """A durable apply-and-register operation with no caller-selected target."""

    def __init__(self, root: Path, store: Any, adapter: Any,
                 restore_point: Callable[[str], dict], collection_snapshot: Callable[[], dict],
                 sync_status: Callable[[], dict], *, source: Path, model_name: str,
                 publish: Callable[[dict, dict], dict], source_revision: str = "unknown",
                 ttl: int = 600, clock: Callable[[], float] = time.time) -> None:
        self.root, self.store, self.adapter = Path(root), store, adapter
        self.restore_point, self.collection_snapshot, self.sync_status = restore_point, collection_snapshot, sync_status
        self.source, self.model_name, self.publish = Path(source), model_name, publish
        self.source_revision, self.ttl, self.clock = source_revision, ttl, clock
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        metadata = self.root.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid():
            _error("unsafe-journal-directory")
        self.root.chmod(0o700)
        for path in self.root.glob("*.json"):
            record = self._load(path)
            if record["state"] in ("applying", "registering"):
                record.update(state="unknown", error="managed-update-interrupted-inspect-original-operation")
                self._save(record)
            elif record["state"] == "preparing":
                record.update(state="not-applied", error="managed-update-preparation-interrupted")
                self._save(record)

    def _path(self, operation_id: str) -> Path:
        return self.root / (_identifier(operation_id) + ".json")

    def _load(self, path: Path) -> dict:
        try:
            record = ManagedTypeStore._read(path)
        except FileNotFoundError:
            _error("not-found")
        if (record.get("version") != 1 or self._path(record.get("operation_id")) != path
                or record.get("model_name") != self.model_name
                or record.get("state") not in ("preparing", "prepared", "applying", "registering",
                                               "applied", "partial", "unknown", "not-applied", "expired")
                or type(record.get("registered")) is not bool
                or (record["state"] == "applied" and not record["registered"])):
            _error("invalid-journal")
        return record

    def _read(self, operation_id: str) -> dict:
        return self._load(self._path(operation_id))

    def _save(self, record: dict) -> None:
        atomic_json(self._path(record["operation_id"]), record)

    def _public(self, record: dict) -> dict:
        keys = ("operation_id", "model_name", "state", "registered", "created_at", "expires_at",
                "applied_at", "registered_at", "summary", "components", "verification", "sync", "error")
        result = {key: record[key] for key in keys if key in record}
        result["confirmation_required"] = True
        result["backup"] = {key: record.get("backup", {}).get(key) for key in ("sha256", "mirrored")}
        if record["state"] == "prepared":
            result["preview_token"] = record["preview_token"]
        if record["state"] in ("applying", "registering"):
            result["state"] = "unknown"
        result["client_delivery_confirmed"] = False
        return result

    def status(self, operation_id: str) -> dict:
        record = self._read(operation_id)
        if record["state"] == "prepared" and self.clock() >= record["expires_at"]:
            record.update(state="expired", error="managed-update-preview-expired")
            self._save(record)
        return self._public(record)

    def has_pending(self, model_name: str, *, exclude_operation_id: str | None = None) -> bool:
        return any((record := self._load(path))["model_name"] == model_name
                   and record["operation_id"] != exclude_operation_id
                   and record["state"] in ("applying", "registering", "partial", "unknown")
                   for path in self.root.glob("*.json"))

    @staticmethod
    def _timestamp(value: Any) -> float:
        if not isinstance(value, str):
            return 0
        try:
            parsed = datetime.fromisoformat(value)
            return parsed.timestamp() if parsed.utcoffset() is not None else 0
        except ValueError:
            return 0

    def _ready(self) -> dict:
        status = self.sync_status() or {}
        detail = status.get("sync") or {}
        action = detail.get("action", status.get("action"))
        media = (detail.get("media") or {}).get("state", status.get("media_state"))
        start = self._timestamp(status.get("runStartedAt"))
        success = self._timestamp(status.get("lastSuccessAt"))
        now = self.clock()
        if (status.get("result") != "success" or status.get("mode") != "normal"
                or not status.get("runId") or action != "normal" or media != "synced"
                or not 0 < start <= success <= now or now - start > self.ttl):
            _error("fresh-normal-sync-required")
        return {"run_id": status["runId"], "started_at": start, "succeeded_at": success}

    @staticmethod
    def _authorization(baseline: dict) -> dict:
        validate_bundle(baseline["bundle"], baseline["asset_bytes"])
        if baseline.get("operator_verified") is not True or not baseline.get("evidence"):
            _error("verified-baseline-required")
        return {key: baseline[key] for key in ("record_id", "model_id", "model_name", "binding")} | {
            "digest": baseline["bundle"]["digest"]}

    def _source(self, model_id: int) -> dict:
        try:
            bundle, assets = load_bundle(self.source)
        except (OSError, ValueError, KeyError, TypeError):
            _error("source-unavailable")
        if bundle["definition"]["name"] != self.model_name:
            _error("source-model-mismatch")
        return {"model_name": self.model_name, "model_id": model_id, "bundle": bundle, "asset_bytes": assets}

    def _target(self, record: dict, *, check_source: bool = True) -> dict:
        target = {"model_name": self.model_name, "model_id": record["authorization"]["model_id"],
                  "bundle": record["target_bundle"],
                  "asset_bytes": ManagedTypeStore._decode_assets(record["target_assets"])}
        validate_bundle(target["bundle"], target["asset_bytes"])
        if check_source and self._source(target["model_id"])["bundle"] != target["bundle"]:
            _error("source-changed-reprepare")
        return target

    def _observe(self, target: dict) -> tuple[dict, dict]:
        collection = self.collection_snapshot()
        captured = self.adapter.capture(target)
        return {"collection": collection, **{key: value for key, value in captured.items() if key != "asset_bytes"}}, captured["asset_bytes"]

    def _normal(self) -> dict:
        if self.store.inspect(self.model_name)["status"] != "normal":
            _error("normal-baseline-required")
        return self.store.get_baseline(self.model_name)

    def prepare(self, operation_id: str, devices_ready: bool = False) -> dict:
        path = self._path(operation_id)
        if devices_ready is not True:
            _error("device-sync-and-edit-pause-confirmation-required")
        if path.exists():
            return self.status(operation_id)
        if self.has_pending(self.model_name):
            _error("unresolved-update-inspect-original-operation")
        presync = self._ready()
        baseline = self._normal()
        authorization = self._authorization(baseline)
        if operation_id == authorization["record_id"]:
            _error("operation-id-conflicts-with-baseline")
        target = self._source(authorization["model_id"])
        before, assets = self._observe(target)
        self.adapter.materialize(before["model"], target["bundle"]["definition"])
        changed = diff_bundle(baseline["bundle"], target["bundle"])
        if not changed:
            _error("already-matches-deployed-source")
        record = {"version": 1, "operation_id": operation_id, "model_name": self.model_name,
                  "state": "preparing", "registered": False, "created_at": self.clock(),
                  "authorization": authorization, "before": before, "presync": presync,
                  "target_bundle": target["bundle"],
                  "target_assets": ManagedTypeStore._encode_assets(target["asset_bytes"]),
                  "source_revision": self.source_revision,
                  "summary": {"baseline_digest": authorization["digest"], "target_digest": target["bundle"]["digest"],
                              "changed_items": changed, "preservation": before["preservation"],
                              "scope": "front-back-css-assets-and-history-collapse-search-options"},
                  "sync": {"state": "pending"}, "components": {}}
        self._save(record)
        try:
            backup = self.restore_point(operation_id)
            if backup.get("mirrored") is not True or not backup.get("path"):
                _error("verified-mirrored-backup-required")
            record["backup"] = backup
            self._save(record)
            after, copied = self._observe(target)
            if after != before or copied != assets:
                _error("state-changed-during-backup")
            record["media_before"] = {entry["filename"]: (
                base64.b64encode(assets[entry["filename"]]).decode("ascii")
                if entry["filename"] in assets else None) for entry in target["bundle"]["assets"]}
            record["media_before_digest"] = digest(record["media_before"])
            self._save(record)
            record["verification"] = self.adapter.verify_backup(backup, target, before)
            if (record["verification"].get("state") != "verified"
                    or record["verification"].get("anki_version") != self.adapter.version
                    or record["verification"].get("preservation") != before["preservation"]):
                _error("isolated-verification-required")
            if self._observe(target)[0] != before:
                _error("state-changed-during-verification")
            self._target(record)
            if self._authorization(self.store.get_baseline(self.model_name)) != authorization:
                _error("baseline-changed-reprepare")
            # Device confirmation and presync must remain fresh through apply;
            # time spent exporting/testing does not extend that window.
            record.update(state="prepared", preview_token=secrets.token_hex(32),
                          expires_at=min(record["created_at"], presync["started_at"]) + self.ttl)
            self._save(record)
        except Exception:
            record.update(state="not-applied", error="managed-update-preparation-failed")
            self._save(record)
            raise
        return self.status(operation_id)

    def _authority(self, record: dict, *, allow_published: bool = False) -> dict:
        baseline = self.store.get_baseline(self.model_name)
        if allow_published and baseline["record_id"] == record["operation_id"]:
            if (baseline["model_id"] != record["authorization"]["model_id"]
                    or baseline["binding"] != record["authorization"]["binding"]
                    or baseline["bundle"] != record["target_bundle"]
                    or baseline["evidence"].get("update_operation_id") != record["operation_id"]):
                _error("published-baseline-mismatch")
        elif self._authorization(baseline) != record["authorization"]:
            _error("baseline-changed-reprepare")
        return baseline

    def _postcheck(self, record: dict, target: dict) -> None:
        after, assets = self._observe(target)
        if (after["preservation"] != record["before"]["preservation"]
                or _identities(after["model"]) != _identities(record["before"]["model"])
                or after["model"]["req"] != record["before"]["model"]["req"]
                or build_bundle(after["model"], assets) != target["bundle"]
                or not self.adapter.media_registered(target)):
            _error("postcondition-unconfirmed")

    def _publish(self, record: dict, target: dict) -> None:
        self._authority(record, allow_published=True)
        self._postcheck(record, target)
        record["state"] = "registering"
        self._save(record)
        result = self.publish(record, target)
        if (result.get("record_id") != record["operation_id"]
                or result.get("model_id") != target["model_id"] or result.get("digest") != target["bundle"]["digest"]):
            _error("registration-unconfirmed")
        if self._authority(record, allow_published=True)["record_id"] != record["operation_id"]:
            _error("registration-unconfirmed")
        record.update(state="applied", registered=True, registered_at=self.clock(),
                      sync={"state": "pending"})
        record["components"]["preservation"] = "verified"
        record["components"]["baseline"] = "verified"
        record.pop("error", None)
        self._save(record)

    def apply(self, operation_id: str, preview_token: str, confirm: bool = False) -> dict:
        record = self._read(operation_id)
        if record["state"] != "prepared" or self.clock() >= record["expires_at"]:
            return self.status(operation_id)
        if confirm is not True:
            _error("explicit-confirmation-required")
        if (not isinstance(preview_token, str) or re.fullmatch(r"[0-9a-f]{64}", preview_token) is None
                or not secrets.compare_digest(preview_token, record["preview_token"])):
            _error("preview-token-mismatch")
        self._ready()
        self._normal()
        self._authority(record)
        target = self._target(record)
        current, _ = self._observe(target)
        if current != record["before"]:
            _error("stale-preview-reprepare")
        if (self.adapter.version != record["verification"]["anki_version"]
                or digest(record["media_before"]) != record["media_before_digest"]
                or _file_hash(Path(record["backup"]["path"])) != record["backup"]["sha256"]):
            _error("verification-or-backup-changed")
        record.update(state="applying", confirmed_at=self.clock())
        self._save(record)

        def progress(name: str, state: str) -> None:
            record["components"][name] = state
            self._save(record)

        try:
            self.adapter.apply(target, record["before"], progress)
            self._postcheck(record, target)
            record["applied_at"] = self.clock()
            self._publish(record, target)
        except Exception:
            record.update(state="partial" if "verified" in record["components"].values() else "unknown",
                          error="managed-update-result-unconfirmed")
            self._save(record)
        return self._public(record)

    def diagnose(self, operation_id: str) -> dict:
        """Finish a previously confirmed registration only after exact readback.

        Never repeat model/asset writes or sync. A process can stop after Anki
        applied bytes or after baseline publication but before the final receipt.
        """
        record = self._read(operation_id)
        if record["state"] not in ("partial", "unknown"):
            return self.status(operation_id)
        try:
            if not record.get("confirmed_at"):
                _error("confirmation-record-missing")
            # A later deployment is a new candidate, not the authority for an
            # already confirmed operation. Diagnose only its saved target.
            target = self._target(record, check_source=False)
            if (self.adapter.version != record["verification"]["anki_version"]
                    or _file_hash(Path(record["backup"]["path"])) != record["backup"]["sha256"]):
                _error("verification-or-backup-changed")
            self._authority(record, allow_published=True)
            self._postcheck(record, target)
            record.setdefault("applied_at", self.clock())
            self._publish(record, target)
        except Exception:
            # Keep a failed publication blocked, even if its intermediate save
            # changed the local record to 'registering'.
            record.update(state="unknown", error="managed-update-diagnosis-unconfirmed")
            self._save(record)
        return self._public(record)

    def delivery(self, operation_id: str) -> dict:
        record = self._read(operation_id)
        if record["state"] != "applied" or record["sync"]["state"] == "synced":
            return self.status(operation_id)
        try:
            if self._authority(record, allow_published=True)["record_id"] != record["operation_id"]:
                _error("registration-unconfirmed")
            target = self._target(record, check_source=False)
            current = self.adapter.capture(target)
            if (build_bundle(current["model"], current["asset_bytes"]) != target["bundle"]
                    or not self.adapter.media_registered(target)):
                _error("content-changed-before-delivery")
            status = self.sync_status() or {}
            detail = status.get("sync") or {}
            action = detail.get("action", status.get("action"))
            media = (detail.get("media") or {}).get("state", status.get("media_state"))
            fresh = (self._timestamp(status.get("runStartedAt")) > record["registered_at"]
                     and self._timestamp(status.get("lastSuccessAt")) >= self._timestamp(status.get("runStartedAt")))
            ok = (fresh and bool(status.get("runId")) and status.get("result") == "success"
                  and status.get("mode") == "normal" and action == "normal"
                  and (not target["asset_bytes"] or media == "synced"))
            blocked = action in ("full-sync-required", "schema-sync-blocked") or status.get("result") in ("failed", "error")
            record["sync"] = {"state": "synced" if ok else "blocked" if blocked else "pending",
                              "run_id": status.get("runId"), "action": action, "media_state": media or "unknown"}
        except Exception:
            record["sync"] = {"state": "pending", "error": "managed-update-delivery-unconfirmed"}
        self._save(record)
        return self._public(record)
