"""Private applied baselines and deterministic, freshly observed drift records.

The caller holds Anki's mutation lock and supplies ``observe(name, model_id,
asset_names)``. It returns model_id, bundle, asset_bytes and missing; it must
raise when a collection/asset cannot be read, or a restore is still unverified.
This module owns neither Qt nor credentials. Registration is an operator-only
entry point: it requires independent evidence verification and a fresh exact
readback, and must never be exposed as an ordinary MCP mutation.
"""

from __future__ import annotations

import base64
import contextlib
import copy
import fcntl
import hashlib
import json
import os
import re
import stat
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Iterable

from .managed_bundle import diff_bundle, validate_bundle


class ManagedDriftError(ValueError):
    """A managed baseline cannot be trusted or a requested action is invalid."""


def _json(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                      allow_nan=False).encode("utf-8")


def _digest(value: Any) -> str:
    return hashlib.sha256(_json(value)).hexdigest()


def _identifier(value: str) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{32}", value) is None:
        raise ManagedDriftError("managed-invalid-record-id")
    return value


class ManagedTypeStore:
    """All public reports omit raw definitions, asset bytes, and private evidence.

    ``collection_binding()`` returns a stable JSON identity independent of the
    model's content hash. ``latest_bundle(name)`` is optional source metadata;
    its failure cannot change a valid local observation to drift. It is not
    evidence of a fresh GitHub lookup. Notification callbacks receive only safe
    report metadata and return {state: sent|failed|unknown}. Failed sends require
    an explicit retry; unknown outcomes are never automatically resent.
    """

    def __init__(self, state_dir: Path, *, instance: str,
                 collection_binding: Callable[[], Any], managed_specs: Iterable[str],
                 observe: Callable[[str, int, list[str]], dict[str, Any]],
                 last_sync: Callable[[], dict[str, Any]] | None = None,
                 notify: Callable[[dict[str, Any]], dict[str, Any]] | None = None,
                 latest_bundle: Callable[[str], dict[str, Any]] | None = None,
                 clock: Callable[[], float] = time.time) -> None:
        self.root = Path(state_dir)
        self.instance = instance
        self.collection_binding = collection_binding
        self.managed = frozenset(managed_specs)
        self.observe = observe
        self.last_sync = last_sync
        self.notify = notify
        self.latest_bundle = latest_bundle
        self.clock = clock
        self._directory(self.root)
        self._directory(self.root / "baselines")
        self._directory(self.root / "incidents")

    @staticmethod
    def _directory(path: Path) -> None:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        st = path.lstat()
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid():
            raise ManagedDriftError("managed-unsafe-state-directory")
        path.chmod(0o700)

    @contextlib.contextmanager
    def _lock(self):
        fd = os.open(self.root / ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid():
                raise ManagedDriftError("managed-unsafe-lock")
            os.fchmod(fd, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)

    def _write(self, path: Path, value: dict[str, Any]) -> None:
        data = _json(value)
        temporary = path.with_name("." + uuid.uuid4().hex + ".tmp")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            temporary.unlink(missing_ok=True)

    @staticmethod
    def _read(path: Path) -> dict[str, Any]:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            st = os.fstat(fd)
            if (not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid()
                    or st.st_mode & 0o077):
                raise ManagedDriftError("managed-unsafe-state-file")
            with os.fdopen(fd, "r", closefd=False) as stream:
                result = json.load(stream)
            if not isinstance(result, dict):
                raise ManagedDriftError("managed-invalid-state-file")
            return result
        finally:
            os.close(fd)

    def _state(self) -> dict[str, Any]:
        try:
            state = self._read(self.root / "state.json")
        except FileNotFoundError:
            # No state is a legitimate unregistered installation. Lost state is
            # not reconstructed from a same-named model or an archived baseline.
            return {"version": 1, "baselines": {}, "models": {}}
        if (state.get("version") != 1 or not isinstance(state.get("baselines"), dict)
                or not isinstance(state.get("models"), dict)):
            raise ManagedDriftError("managed-invalid-state")
        return state

    def _save_state(self, state: dict[str, Any]) -> None:
        self._write(self.root / "state.json", state)

    @staticmethod
    def _encode_assets(assets: dict[str, bytes]) -> dict[str, str]:
        return {name: base64.b64encode(value).decode("ascii") for name, value in assets.items()}

    @staticmethod
    def _decode_assets(assets: dict[str, str]) -> dict[str, bytes]:
        return {name: base64.b64decode(value, validate=True) for name, value in assets.items()}

    def _baseline(self, name: str, state: dict[str, Any]) -> dict[str, Any]:
        record_id = state["baselines"].get(name)
        if not record_id:
            raise ManagedDriftError("managed-baseline-missing")
        record = self._read(self.root / "baselines" / (_identifier(record_id) + ".json"))
        check = dict(record)
        checksum = check.pop("record_checksum", None)
        if (checksum != _digest(check) or record.get("version") != 1 or record.get("record_id") != record_id
                or record.get("model_name") != name or record.get("instance") != self.instance
                or record.get("binding") != self.collection_binding()
                or record.get("operator_verified") is not True
                or type(record.get("model_id")) is not int or record["model_id"] <= 0):
            raise ManagedDriftError("managed-baseline-invalid-or-binding-changed")
        assets = self._decode_assets(record["assets_base64"])
        validate_bundle(record["bundle"], assets)
        record["asset_bytes"] = assets
        return record

    def get_baseline(self, model_name: str) -> dict[str, Any]:
        """Internal restore input: only the currently eligible applied record."""
        if model_name not in self.managed:
            raise ManagedDriftError("managed-model-not-managed")
        with self._lock():
            return self._baseline(model_name, self._state())

    def _observed(self, name: str, model_id: int, bundle: dict[str, Any]) -> dict[str, Any]:
        names = [asset["filename"] for asset in bundle["assets"]]
        current = self.observe(name, model_id, names)
        if current.get("model_id") != model_id or type(current.get("model_id")) is not int:
            raise ManagedDriftError("managed-model-binding-changed")
        assets = current["asset_bytes"]
        missing = current.get("missing", [])
        if (not isinstance(missing, list) or any(not isinstance(n, str) for n in missing)
                or len(missing) != len(set(missing)) or set(missing) != set(names) - set(assets)
                or set(assets) - set(names)):
            raise ManagedDriftError("managed-asset-observation-incomplete")
        validate_bundle(current["bundle"], assets)
        return current

    def register_verified(self, model_name: str, model_id: int, bundle: dict[str, Any],
                          asset_bytes: dict[str, bytes], *, evidence: dict[str, Any],
                          verify_registration: Callable[..., bool]) -> dict[str, Any]:
        """Operator entry; a hash match alone never creates restore authority."""
        if model_name not in self.managed or type(model_id) is not int or model_id <= 0:
            raise ManagedDriftError("managed-registration-target-invalid")
        validate_bundle(bundle, asset_bytes)
        if bundle["definition"]["name"] != model_name:
            raise ManagedDriftError("managed-registration-target-invalid")
        if not isinstance(evidence, dict) or not evidence:
            raise ManagedDriftError("managed-registration-evidence-required")
        with self._lock():
            state = self._state()
            binding = self.collection_binding()
            if binding is None or binding == "" or binding == {}:
                raise ManagedDriftError("managed-collection-binding-required")
            if model_name in state["baselines"]:
                previous = self._baseline(model_name, state)
                if previous["model_id"] != model_id:
                    raise ManagedDriftError("managed-registration-rebinding-forbidden")
            if verify_registration(model_name, model_id, bundle, asset_bytes, evidence) is not True:
                raise ManagedDriftError("managed-registration-not-verified")
            current = self._observed(model_name, model_id, bundle)
            if current["missing"] or current["bundle"]["digest"] != bundle["digest"]:
                raise ManagedDriftError("managed-registration-readback-mismatch")
            if binding != self.collection_binding():
                raise ManagedDriftError("managed-collection-binding-changed")
            record_id = uuid.uuid4().hex
            record = {"version": 1, "record_id": record_id, "model_name": model_name,
                      "model_id": model_id, "instance": self.instance, "binding": binding,
                      "bundle": copy.deepcopy(bundle), "assets_base64": self._encode_assets(asset_bytes),
                      "evidence": copy.deepcopy(evidence), "operator_verified": True,
                      "applied_verified_at": self.clock()}
            record["record_checksum"] = _digest(record)
            self._write(self.root / "baselines" / (record_id + ".json"), record)
            state["baselines"][model_name] = record_id
            self._save_state(state)
            return {"record_id": record_id, "model_name": model_name,
                    "model_id": model_id, "digest": bundle["digest"]}

    def _incident(self, incident_id: str) -> dict[str, Any]:
        path = self.root / "incidents" / (_identifier(incident_id) + ".json")
        value = self._read(path)
        if value.get("incident_id") != incident_id or value.get("version") != 1:
            raise ManagedDriftError("managed-incident-invalid")
        # A durable 'sending' receipt means a process died without recording the
        # provider outcome. It may already have delivered: do not send it twice.
        if value["notification"]["state"] == "sending":
            value["notification"] = {"state": "unknown", "updated_at": self.clock(),
                                     "reason": "interrupted-send"}
            self._write(path, value)
        return value

    @staticmethod
    def _notification_payload(incident: dict[str, Any]) -> dict[str, Any]:
        return {key: incident[key] for key in ("incident_id", "model_name", "changed_paths",
                                               "first_observed_at", "baseline_digest")}

    def _send(self, incident: dict[str, Any]) -> None:
        if self.notify is None:
            return
        path = self.root / "incidents" / (incident["incident_id"] + ".json")
        incident["notification"] = {"state": "sending", "updated_at": self.clock()}
        self._write(path, incident)
        try:
            outcome = self.notify(self._notification_payload(incident))
            status = outcome.get("state") if isinstance(outcome, dict) else None
            if status not in ("sent", "failed", "unknown"):
                status = "unknown"
        except Exception:
            status = "unknown"
        incident["notification"] = {"state": status, "updated_at": self.clock()}
        self._write(path, incident)

    def retry_notification(self, incident_id: str) -> dict[str, Any]:
        """Only a known failed send may be explicitly retried; unknown is final."""
        with self._lock():
            incident = self._incident(incident_id)
            if incident.get("resolved_at") is not None or incident["notification"]["state"] != "failed":
                raise ManagedDriftError("managed-notification-retry-not-allowed")
            if self.notify is None:
                raise ManagedDriftError("managed-notification-unconfigured")
            self._send(incident)
            return {"incident_id": incident_id, "notification": incident["notification"]}

    def _source(self, name: str, baseline_digest: str | None) -> dict[str, Any]:
        if self.latest_bundle is None:
            return {"state": "unavailable", "update_pending": None}
        try:
            bundle = self.latest_bundle(name)
            validate_bundle(bundle)
            return {"state": "available-source", "digest": bundle["digest"],
                    "update_pending": (bundle["digest"] != baseline_digest)
                    if baseline_digest is not None else None}
        except Exception:
            return {"state": "unavailable", "update_pending": None}

    def inspect(self, model_name: str, *, notify: bool = True) -> dict[str, Any]:
        """Always reread runtime; callers must not use a report as a write permit."""
        if model_name not in self.managed:
            return {"model_name": model_name, "status": "unmanaged", "write_blocked": False}
        now = self.clock()
        result: dict[str, Any] = {"model_name": model_name, "status": "unavailable",
                                  "observed_at": now, "write_blocked": True,
                                  "baseline_digest": None, "observation_scope": "host-local",
                                  "client_sync_notice": "Unsynced client changes may not yet be visible."}
        try:
            result["last_sync"] = self.last_sync() if self.last_sync else None
        except Exception:
            result["last_sync"] = {"state": "unavailable"}
        try:
            with self._lock():
                state = self._state()
                self._prune_resolved(state)
                baseline = self._baseline(model_name, state)
                result.update(baseline_digest=baseline["bundle"]["digest"],
                              baseline_record_id=baseline["record_id"], model_id=baseline["model_id"])
                observed = self._observed(model_name, baseline["model_id"], baseline["bundle"])
                if baseline["binding"] != self.collection_binding():
                    raise ManagedDriftError("managed-collection-binding-changed")
                paths = diff_bundle(baseline["bundle"], observed["bundle"])
                metadata = state["models"].setdefault(model_name, {"last_normal_at": None,
                                                                   "open_incidents": []})
                # Resolution is durable before the index update. If that index
                # write was interrupted, an old pointer must not absorb a later
                # recurrence into an already resolved incident.
                metadata["open_incidents"] = [entry for entry in metadata["open_incidents"]
                                              if self._incident(entry).get("resolved_at") is None]
                result["last_normal_at"] = metadata["last_normal_at"]
                result["observed_digest"] = observed["bundle"]["digest"]
                result["changed_paths"] = paths
                if not paths:
                    for incident_id in metadata["open_incidents"]:
                        incident = self._incident(incident_id)
                        if incident.get("resolved_at") is None:
                            incident.update(resolved_at=now, resolution="observed-applied-baseline")
                            self._write(self.root / "incidents" / (incident_id + ".json"), incident)
                    metadata.update(last_normal_at=now, open_incidents=[])
                    result.update(status="normal", write_blocked=False, last_normal_at=now)
                else:
                    fingerprint = _digest({"baseline": baseline["record_id"],
                                           "observed": observed["bundle"]["digest"]})
                    incident = None
                    for incident_id in metadata["open_incidents"]:
                        candidate = self._incident(incident_id)
                        if candidate["fingerprint"] == fingerprint:
                            incident = candidate
                            break
                    if incident is None:
                        incident_id = uuid.uuid4().hex
                        incident = {"version": 1, "incident_id": incident_id, "model_name": model_name,
                                    "fingerprint": fingerprint, "baseline_record_id": baseline["record_id"],
                                    "baseline_digest": baseline["bundle"]["digest"],
                                    "first_observed_at": now, "last_normal_at": metadata["last_normal_at"],
                                    "changed_paths": paths, "observed_bundle": observed["bundle"],
                                    "observed_assets_base64": self._encode_assets(observed["asset_bytes"]),
                                    "missing_assets": observed["missing"], "resolved_at": None,
                                    "notification": {"state": "pending", "updated_at": now}}
                        self._write(self.root / "incidents" / (incident_id + ".json"), incident)
                        metadata["open_incidents"].append(incident_id)
                    self._save_state(state)
                    if notify and incident["notification"]["state"] == "pending":
                        self._send(incident)
                    result.update(status="drift", incident_id=incident["incident_id"],
                                  notification=incident["notification"],
                                  next_choices=["restore-verified-version", "review-app-change-for-git"])
                self._save_state(state)
        except Exception as err:
            # Exception messages can contain private paths/raw template text.
            reason = str(err) if isinstance(err, ManagedDriftError) else ""
            if re.fullmatch(r"managed-[a-z0-9-]{1,100}", reason) is None:
                reason = "managed-observation-unavailable"
            result.update(status="unavailable", write_blocked=True,
                          reason=reason, error_type=type(err).__name__)
        result["source"] = self._source(model_name, result["baseline_digest"])
        result["github_latest"] = {"state": "not-checked"}
        return result

    def history(self, model_name: str, *, limit: int = 20, offset: int = 0) -> dict[str, Any]:
        """Paginate safe incident metadata, never saved templates or asset bytes."""
        if type(limit) is not int or not 1 <= limit <= 100 or type(offset) is not int or offset < 0:
            raise ManagedDriftError("managed-history-invalid-pagination")
        result = {"model_name": model_name, "status": "unmanaged", "total": 0,
                  "incidents": [], "next_offset": None}
        if model_name not in self.managed:
            return result
        with self._lock():
            self._prune_resolved(self._state())
            incidents = [self._incident(path.stem)
                         for path in (self.root / "incidents").glob("*.json")]
            incidents = [entry for entry in incidents if entry["model_name"] == model_name]
            incidents.sort(key=lambda entry: (entry["first_observed_at"], entry["incident_id"]), reverse=True)
            fields = ("incident_id", "model_name", "baseline_record_id", "baseline_digest",
                      "first_observed_at", "last_normal_at", "changed_paths", "resolved_at", "resolution")
            page = []
            for entry in incidents[offset:offset + limit]:
                item = {key: entry.get(key) for key in fields}
                item["notification"] = {key: entry["notification"].get(key)
                                        for key in ("state", "updated_at")}
                page.append(item)
            result.update(status="managed", total=len(incidents), incidents=page,
                          next_offset=offset + len(page) if offset + len(page) < len(incidents) else None)
            return result

    def _prune_resolved(self, state: dict[str, Any]) -> list[str]:
        """Caller holds the store lock; baseline/restore records never expire here."""
        removed = []
        cutoff = self.clock() - 90 * 24 * 60 * 60
        changed = False
        for model in state["models"].values():
            unresolved = [entry for entry in model["open_incidents"]
                          if self._incident(entry).get("resolved_at") is None]
            if unresolved != model["open_incidents"]:
                model["open_incidents"] = unresolved
                changed = True
        if changed:
            # Clear interrupted-resolution index entries durably before deletion;
            # a later restart must never reference already expired detail files.
            self._save_state(state)
        for path in sorted((self.root / "incidents").glob("*.json")):
            incident = self._incident(path.stem)
            resolved = incident.get("resolved_at")
            if type(resolved) in (int, float) and resolved <= cutoff:
                path.unlink()
                removed.append(path.stem)
        if removed:
            directory = os.open(self.root / "incidents", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        return removed

    def prune_resolved(self) -> list[str]:
        """Only resolved incident details expire, 90 days after resolution."""
        with self._lock():
            return self._prune_resolved(self._state())
