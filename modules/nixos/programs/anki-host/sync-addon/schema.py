"""One-shot root authorization, separate from the MCP operation credential.

All entry points run under the helper mutation lock on Anki's main thread.
The approval binds the complete local collection and the durable restore point;
the normal sync script remains the sole writer of the sync status file.
"""

from __future__ import annotations

import json
import os
import re
import stat
import time
from pathlib import Path
from typing import Any, Callable

from .operations import OperationError, Operations, identifier


class SchemaOperations:
    def __init__(self, operations: Operations, instance: str, approvals: Path,
                 snapshot: Callable[[], dict[str, Any]], baseline: Callable[[], dict[str, Any]],
                 sync: Callable[[dict[str, Any]], dict[str, Any]],
                 *, clock: Callable[[], float] = time.time) -> None:
        self.ops, self.instance, self.approvals = operations, instance, approvals
        self.snapshot, self.baseline, self.sync, self.clock = snapshot, baseline, sync, clock

    def inspect(self, operation_id: str) -> dict[str, Any]:
        record = self.ops._read(operation_id)
        if not record["schema_required"] or record["state"] not in ("prepared", "applied"):
            raise OperationError("schema-operation-not-ready-or-result-unknown")
        if record["state"] == "prepared":
            self.ops._checked_prepared(operation_id, record["preview_token"], True)
        elif record["sync"].get("state") == "synced":
            raise OperationError("schema-operation-already-synced")
        current, baseline = self.snapshot(), self.baseline()
        counts = current["counts"]
        if (not baseline or counts["notes"] <= 0 or counts["cards"] <= 0
                or any(type(baseline.get(k)) is not int or baseline[k] < 0
                       or counts[k] < baseline[k] for k in ("notes", "revlog"))):
            raise OperationError("schema-upload-counts-gate")
        return {"operation": self.ops._public(record), "snapshot_digest": current["digest"],
                "counts": counts, "baseline": baseline, "instance": self.instance}

    def backup(self, operation_id: str) -> dict[str, Any]:
        before = self.inspect(operation_id)
        record = self.ops._read(operation_id)
        if not record.get("backup"):
            record["backup"] = self.ops.restore(operation_id)
            self.ops._save(record)
        if record["backup"].get("mirrored") is not True:
            raise OperationError("restore-point-not-mirrored")
        after = self.inspect(operation_id)
        if before["snapshot_digest"] != after["snapshot_digest"]:
            raise OperationError("collection-changed-during-schema-backup")
        return after

    def _consume(self, operation_id: str, current: dict[str, Any]) -> None:
        path = self.approvals / (identifier(operation_id) + ".json")
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022 or st.st_size > 16384:
                raise OperationError("invalid-root-approval-file")
            with os.fdopen(fd, "r", closefd=False) as stream:
                approval = json.load(stream)
        finally:
            os.close(fd)
        expected = {"instance": self.instance, "operation_id": operation_id,
                    "snapshot_digest": current["snapshot_digest"], "baseline": current["baseline"],
                    "counts": current["counts"],
                    "backup_sha256": current["operation"].get("backup", {}).get("sha256")}
        if (not isinstance(approval, dict) or set(approval) != set(expected) | {"expires_at", "nonce"}
                or any(approval.get(k) != v for k, v in expected.items())
                or not expected["backup_sha256"]
                or type(approval["expires_at"]) not in (int, float)
                or not self.clock() < approval["expires_at"] <= self.clock() + self.ops.ttl
                or not isinstance(approval["nonce"], str)
                or re.fullmatch(r"[0-9a-f]{32}", approval["nonce"]) is None):
            raise OperationError("root-approval-expired-or-mismatched")
        consumed = path.with_name(operation_id + ".consumed-" + approval["nonce"] + ".json")
        if consumed.exists():
            raise OperationError("root-approval-already-consumed")
        os.rename(path, consumed)
        directory = os.open(self.approvals, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)

    def apply(self, operation_id: str) -> dict[str, Any]:
        current = self.inspect(operation_id)
        self._consume(operation_id, current)
        record = self.ops._read(operation_id)
        if record["state"] == "prepared":
            outcome = self.ops.apply(operation_id, record["preview_token"], True, schema_authorized=True)
            if outcome["state"] != "applied":
                return {"action": "schema-result-unknown", "required": None, "operation": outcome,
                        "before": current["counts"], "after": self.snapshot()["counts"]}
        # A fresh approval may resume delivery of an applied operation, but can
        # never execute the collection mutation a second time.
        after = self.snapshot()["counts"]
        if (after["notes"] <= 0 or after["cards"] <= 0
                or any(after[k] < current["baseline"][k] or after[k] < current["counts"][k]
                       for k in ("notes", "revlog"))):
            result = {"action": "schema-counts-blocked", "required": None,
                      "before": current["counts"], "after": after}
        else:
            try:
                result = self.sync(current["counts"])
            except Exception as err:
                result = {"action": "schema-sync-failed", "required": None,
                          "error": type(err).__name__, "before": current["counts"], "after": after}
        delivered = result["action"] in ("normal", "approved-full-upload")
        result["operation"] = self.ops.record_delivery(operation_id, "sync", {
            "state": "synced" if delivered else "blocked", "action": result["action"],
            "result": "success" if delivered else "root-reapproval-required"})
        return result
