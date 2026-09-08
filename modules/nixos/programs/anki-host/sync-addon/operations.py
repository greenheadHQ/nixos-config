"""Durable mutation boundary, independent of Qt and Anki.

The caller holds the helper mutation lock and runs prepare/apply on Anki's main
thread. A journal is not a collection transaction: after an interrupted apply we
retain an unknown result and refuse to repeat it.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import re
import secrets
import time
import unicodedata
from pathlib import Path
from typing import Any, Callable, Protocol


class OperationError(ValueError):
    """Stable error code safe to return without note contents or credentials."""


def digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                     separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def identifier(value: Any) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{32}", value) is None:
        raise OperationError("invalid-operation-id")
    return value


def request_identifier(value: Any) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{7,127}", value) is None:
        raise OperationError("request-id-must-be-8-to-128-letters-digits-underscores-or-hyphens")
    return value


def ids(value: Any) -> list[int]:
    if not isinstance(value, list) or not value or any(type(i) is not int or i <= 0 for i in value):
        raise OperationError("ids-must-be-a-nonempty-list-of-positive-integers")
    return sorted(set(value))


def text(value: Any, *, empty: bool = False) -> str:
    if not isinstance(value, str) or (not empty and not value.strip()) or "\x00" in value:
        raise OperationError("invalid-text")
    return value


def tags(value: Any) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(v, str) or not v or
                                        any(c.isspace() or unicodedata.category(c).startswith("C") for c in v)
                                        for v in value):
        raise OperationError("tags-must-be-nonempty-and-contain-no-whitespace-or-control-characters")
    return sorted(set(value))


def filename(value: Any) -> str:
    value = text(value)
    if (value in (".", "..") or value.startswith(".") or any(c in value for c in '/\\:')
            or any(unicodedata.category(c).startswith("C") for c in value)
            or unicodedata.normalize("NFC", value) != value or len(value.encode()) > 240
            or value != value.strip()):
        raise OperationError("media-filename-must-be-a-safe-nfc-basename")
    return value


def decode_media(value: Any, limit: int) -> bytes:
    if not isinstance(value, str) or len(value) > 4 * ((limit + 2) // 3):
        raise OperationError("media-too-large")
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as err:
        raise OperationError("invalid-base64") from err
    if not data or len(data) > limit:
        raise OperationError("media-empty-or-too-large")
    return data


def fields(value: Any) -> dict[str, str]:
    if not isinstance(value, dict) or not value:
        raise OperationError("fields-must-be-a-nonempty-object")
    return {text(k): text(v, empty=True) for k, v in value.items()}


# Exact fields are checked here; collection-dependent names and values belong to
# the Anki adapter. There is no arbitrary action/kwargs passthrough.
PARAMETERS = {
    "add_notes": ({"notes", "allow_duplicate"}, set()),
    "update_fields": ({"note_id", "fields"}, set()),
    "add_tags": ({"note_ids", "tags"}, set()),
    "remove_tags": ({"note_ids", "tags"}, set()),
    "create_deck": ({"name"}, set()),
    "move_cards": ({"card_ids", "deck_name"}, set()),
    "delete_notes": ({"note_ids"}, set()),
    "delete_decks": ({"deck_names"}, set()),
    "suspend_cards": ({"card_ids", "suspended"}, set()),
    "set_due_date": ({"card_ids", "days"}, set()),
    "forget_cards": ({"card_ids"}, set()),
    "store_media": ({"filename", "data"}, set()),
    "update_deck_options": ({"deck_name", "changes"}, set()),
    "model_field_add": ({"model_name", "field_name"}, {"index"}),
    "model_field_remove": ({"model_name", "field_name"}, set()),
    "model_field_rename": ({"model_name", "field_name", "new_name"}, set()),
    "model_field_reposition": ({"model_name", "field_name", "index"}, set()),
    "model_template_add": ({"model_name", "template_name", "front", "back"}, set()),
    "model_template_remove": ({"model_name", "template_name"}, set()),
    "model_template_update": ({"model_name", "template_name", "front", "back"}, set()),
    "model_css_update": ({"model_name", "css"}, set()),
}
SCHEMA_ACTIONS = frozenset({"model_field_add", "model_field_remove", "model_field_rename",
                            "model_field_reposition", "model_template_add", "model_template_remove",
                            "model_template_update"})
DESTRUCTIVE_ACTIONS = frozenset({"delete_notes", "delete_decks", "set_due_date", "forget_cards"})


def validate_spec(action: Any, params: Any, media_limit: int) -> dict[str, Any]:
    if not isinstance(action, str) or action not in PARAMETERS or not isinstance(params, dict):
        raise OperationError("unsupported-operation")
    required, optional = PARAMETERS[action]
    if not required <= params.keys() or params.keys() - required - optional:
        raise OperationError("invalid-operation-parameters")
    p = dict(params)
    for key in ("note_ids", "card_ids"):
        if key in p:
            p[key] = ids(p[key])
    if "note_id" in p:
        p["note_id"] = ids([p["note_id"]])[0]
    for key in ("name", "deck_name", "model_name", "field_name", "new_name", "template_name", "front", "back"):
        if key in p:
            p[key] = text(p[key])
    if "css" in p:
        p["css"] = text(p["css"], empty=True)
    if "fields" in p:
        p["fields"] = fields(p["fields"])
    if "tags" in p:
        p["tags"] = tags(p["tags"])
        if not p["tags"]:
            raise OperationError("tags-must-not-be-empty")
    for key in ("suspended", "allow_duplicate"):
        if key in p and type(p[key]) is not bool:
            raise OperationError("invalid-boolean")
    if "index" in p and (type(p["index"]) is not int or p["index"] < 0):
        raise OperationError("invalid-index")
    if "days" in p and (not isinstance(p["days"], str) or re.fullmatch(r"[0-9]+(-[0-9]+)?!?", p["days"]) is None):
        raise OperationError("days-must-be-N-or-N-M-with-optional-exclamation-mark")
    if "deck_names" in p:
        if not isinstance(p["deck_names"], list) or not p["deck_names"]:
            raise OperationError("deck-names-must-not-be-empty")
        p["deck_names"] = sorted(set(text(n) for n in p["deck_names"]))
    if action == "add_notes":
        if not isinstance(p["notes"], list) or not p["notes"]:
            raise OperationError("notes-must-not-be-empty")
        normalized = []
        for note in p["notes"]:
            if not isinstance(note, dict) or set(note) - {"deck_name", "model_name", "fields", "tags"}:
                raise OperationError("invalid-new-note")
            if not {"deck_name", "model_name", "fields"} <= note.keys():
                raise OperationError("invalid-new-note")
            normalized.append({"deck_name": text(note["deck_name"]), "model_name": text(note["model_name"]),
                               "fields": fields(note["fields"]), "tags": tags([*tags(note.get("tags", [])), "mcp::added"])})
        p["notes"] = normalized
    if action == "store_media":
        p["filename"] = filename(p["filename"])
        decode_media(p["data"], media_limit)
    if action == "update_deck_options" and (not isinstance(p["changes"], dict) or not p["changes"]):
        raise OperationError("changes-must-be-a-nonempty-object")
    # Reject NaN/Infinity and non-JSON values before computing an identity.
    try:
        digest(p)
    except (TypeError, ValueError) as err:
        raise OperationError("invalid-json-value") from err
    return {"action": action, "params": p}


def atomic_json(path: Path, value: Any) -> None:
    data = json.dumps(value, ensure_ascii=False, sort_keys=True, allow_nan=False).encode()
    tmp = path.with_name(path.name + ".partial")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        tmp.unlink(missing_ok=True)


class Adapter(Protocol):
    def inspect(self, spec: dict[str, Any]) -> dict[str, Any]:
        """Return snapshot (private) and summary (safe to expose)."""

    def apply(self, spec: dict[str, Any]) -> dict[str, Any]:
        """Return state=applied|partial plus precise per-item outcomes."""


class Operations:
    def __init__(self, root: Path, adapter: Adapter, restore: Callable[[str], dict[str, Any]],
                 *, ttl: int, bulk_limit: int, media_limit: int,
                 clock: Callable[[], float] = time.time) -> None:
        self.root = root
        self.adapter = adapter
        self.restore = restore
        self.ttl = ttl
        self.bulk_limit = bulk_limit
        self.media_limit = media_limit
        self.clock = clock
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        # A fresh engine is created only when the profile opens. No callback from
        # the previous process can still be applying at this point.
        self._recover_pending(restarted=True)

    def _recover_pending(self, *, restarted: bool = False) -> None:
        for path in self.root.glob("*.json"):
            if re.fullmatch(r"[0-9a-f]{32}\.json", path.name) is None:
                continue
            record = self._read(path.stem)
            if restarted and record["state"] == "applying":
                record["state"] = "unknown"
                record["error"] = "process-stopped-during-apply-do-not-repeat"
            elif record["state"] == "prepared" and self.clock() > record["expires_at"]:
                record["state"] = "expired"
                record["error"] = "preview-expired-create-a-new-request-id"
            else:
                continue
            record.pop("spec", None)
            record.pop("preview_token", None)
            self._save(record)

    def _path(self, operation_id: str) -> Path:
        return self.root / (identifier(operation_id) + ".json")

    def _read(self, operation_id: str) -> dict[str, Any]:
        try:
            with self._path(operation_id).open(encoding="utf-8") as stream:
                record = json.load(stream)
        except FileNotFoundError as err:
            raise OperationError("operation-not-found") from err
        if not isinstance(record, dict) or record.get("operation_id") != operation_id:
            raise OperationError("operation-journal-invalid")
        return record

    def _save(self, record: dict[str, Any]) -> None:
        atomic_json(self._path(record["operation_id"]), record)

    def _public(self, record: dict[str, Any]) -> dict[str, Any]:
        allowed = ("operation_id", "request_id", "action", "state", "created_at", "expires_at", "applied_at",
                   "summary", "confirmation_required", "backup_required", "schema_required", "backup",
                   "result", "error", "sync", "notification")
        out = {k: record[k] for k in allowed if k in record}
        if record["state"] == "prepared":
            out["preview_token"] = record["preview_token"]
        if out["state"] == "applying":
            out["state"] = "unknown"
            out["error"] = "apply-in-progress-or-interrupted-do-not-repeat"
        return out

    def status(self, operation_id: str) -> dict[str, Any]:
        return self._public(self._read(operation_id))

    def history(self, limit: int = 20, offset: int = 0) -> dict[str, Any]:
        if type(limit) is not int or not 1 <= limit <= 100 or type(offset) is not int or offset < 0:
            raise OperationError("invalid-operation-history-page")
        records = [self._read(path.stem) for path in self.root.glob("*.json")
                   if re.fullmatch(r"[0-9a-f]{32}\.json", path.name)]
        records.sort(key=lambda record: record["created_at"], reverse=True)
        return {"operations": [self._public(record) for record in records[offset:offset + limit]],
                "total": len(records), "next_offset": offset + limit if offset + limit < len(records) else None}

    def prepare(self, action: str, params: dict[str, Any], request_id: str | None = None) -> dict[str, Any]:
        self._recover_pending()
        spec = validate_spec(action, params, self.media_limit)
        request_id = request_identifier(secrets.token_hex(16) if request_id is None else request_id)
        operation_id = hashlib.sha256(request_id.encode()).hexdigest()[:32]
        if self._path(operation_id).exists():
            old = self._read(operation_id)
            if old["request_id"] != request_id or old["spec_digest"] != digest(spec):
                raise OperationError("request-id-payload-mismatch")
            return self._public(old)
        inspected = self.adapter.inspect(spec)
        summary = inspected["summary"]
        high_impact = max(summary.get("notes", 0), summary.get("cards", 0), summary.get("new_notes", 0)) > self.bulk_limit
        schema = action in SCHEMA_ACTIONS
        requires = high_impact or schema or action in DESTRUCTIVE_ACTIONS or summary.get("shared_preset", False)
        record = {
            "operation_id": operation_id, "request_id": request_id, "action": action,
            "spec_digest": digest(spec), "spec": spec, "snapshot_digest": digest(inspected["snapshot"]),
            "state": "prepared", "created_at": self.clock(), "expires_at": self.clock() + self.ttl,
            "preview_token": secrets.token_hex(32), "confirmation_required": bool(requires),
            "backup_required": bool(requires), "schema_required": schema, "summary": summary,
            "sync": {"state": "not-started"}, "notification": {"state": "not-started"},
        }
        self._save(record)
        return self._public(record)

    def _checked_prepared(self, operation_id: str, token: str, confirm: bool) -> dict[str, Any]:
        record = self._read(operation_id)
        if record["state"] != "prepared":
            return record
        if self.clock() > record["expires_at"]:
            raise OperationError("preview-expired-create-a-new-request-id")
        if (not isinstance(token, str) or re.fullmatch(r"[0-9a-f]{64}", token) is None
                or not secrets.compare_digest(token, record["preview_token"])):
            raise OperationError("preview-token-mismatch")
        if record["confirmation_required"] and confirm is not True:
            raise OperationError("explicit-confirmation-required")
        current = self.adapter.inspect(record["spec"])
        if digest(current["snapshot"]) != record["snapshot_digest"]:
            raise OperationError("stale-preview-create-a-new-request-id")
        return record

    def apply(self, operation_id: str, token: str, confirm: bool = False, *, schema_authorized: bool = False) -> dict[str, Any]:
        record = self._checked_prepared(operation_id, token, confirm)
        if record["state"] != "prepared":
            return self._public(record)
        if record["schema_required"] and not schema_authorized:
            raise OperationError("root-schema-approval-required")
        if record["backup_required"]:
            # Keep a successful restore point when apply is refused after export.
            # The restore callback verifies HDD durability before returning.
            if not record.get("backup"):
                record["backup"] = self.restore(operation_id)
                self._save(record)
            if not record["backup"].get("mirrored"):
                raise OperationError("restore-point-not-mirrored")
            self._checked_prepared(operation_id, token, confirm)
        record["state"] = "applying"
        self._save(record)  # Must reach durable storage before invoking Anki.
        try:
            result = self.adapter.apply(record["spec"])
            if result.get("state") not in ("applied", "partial"):
                raise OperationError("unexpected-apply-result")
            record["state"] = result["state"]
            record["result"] = result
            record["applied_at"] = self.clock()
            record["sync"] = {"state": "pending"}
        except Exception as err:
            # Even an exception may follow a successful/partial collection write.
            record["state"] = "unknown"
            record["error"] = "apply-result-unknown:" + type(err).__name__
        record.pop("spec", None)
        record.pop("preview_token", None)
        self._save(record)
        return self._public(record)

    def record_delivery(self, operation_id: str, kind: str, receipt: dict[str, Any]) -> dict[str, Any]:
        if kind not in ("sync", "notification") or not isinstance(receipt, dict):
            raise OperationError("invalid-delivery-receipt")
        record = self._read(operation_id)
        if record["state"] not in ("applied", "partial"):
            raise OperationError("operation-has-no-confirmed-application")
        if kind == "sync":
            if set(receipt) - {"state", "run_id", "run_started_at", "result", "action"}:
                raise OperationError("invalid-sync-receipt")
            if receipt.get("state") not in ("synced", "pending", "blocked", "disabled"):
                raise OperationError("invalid-sync-state")
        else:
            if set(receipt) != {"state"} or receipt.get("state") not in ("sending", "sent", "failed", "unknown", "disabled"):
                raise OperationError("invalid-notification-receipt")
            if record[kind]["state"] in ("sent", "sending", "unknown"):
                if receipt["state"] == "sending":
                    raise OperationError("notification-already-attempted")
        record[kind] = receipt
        self._save(record)
        return self._public(record)
