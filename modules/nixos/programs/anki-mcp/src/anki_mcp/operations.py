"""MCP operation orchestration; the helper owns the durable mutation journal."""

from __future__ import annotations

import asyncio
import hashlib
import re
import secrets
from typing import Any

from .helper import Helper, HelperRejected, HelperUnavailable
from .notifications import Notifications
from .syncstatus import SyncNow


class OperationService:
    def __init__(self, helper: Helper, syncer: SyncNow, notifications: Notifications | None,
                 *, sync_enabled: bool) -> None:
        self.helper, self.syncer, self.notifications = helper, syncer, notifications
        self.sync_enabled = sync_enabled
        self.lock = asyncio.Lock()

    async def status(self, operation_id: str) -> dict[str, Any]:
        return await self.helper.post("/operations/status", {"operation_id": operation_id})

    async def _delivery(self, operation: dict[str, Any], kind: str, receipt: dict[str, Any]) -> dict[str, Any]:
        return await self.helper.post("/operations/delivery", {
            "operation_id": operation["operation_id"], "kind": kind, "receipt": receipt})

    async def _finish(self, operation: dict[str, Any]) -> dict[str, Any]:
        if operation["state"] not in ("applied", "partial"):
            return operation
        if operation.get("schema_required"):
            return operation  # Delivery of schema changes remains root-only.
        try:
            if operation.get("sync", {}).get("state") not in ("synced", "disabled"):
                if self.sync_enabled:
                    sync = await self.syncer.run_fresh(after=operation["applied_at"])
                    status = sync.get("status", {})
                    receipt = {"state": "synced" if sync["outcome"] == "synced" else "pending",
                               "run_id": status.get("runId"), "run_started_at": status.get("runStartedAt"),
                               "result": status.get("result"), "action": status.get("action")}
                    if sync["outcome"] == "blocked":
                        receipt["state"] = "blocked"
                    if operation["action"] == "store_media":
                        media_state = status.get("media_state") if sync["outcome"] == "synced" else None
                        receipt["media_state"] = media_state if media_state in ("synced", "disabled", "not-started") else "unknown"
                        if receipt["state"] == "synced" and media_state != "synced":
                            receipt["state"] = "pending"
                else:
                    receipt = {"state": "disabled"}
                operation = await self._delivery(operation, "sync", receipt)
            notification = operation.get("notification", {}).get("state")
            if notification == "not-started":
                if not self.notifications or not self.notifications.enabled:
                    return await self._delivery(operation, "notification", {"state": "disabled"})
                operation = await self._delivery(operation, "notification", {"state": "sending"})
                outcome = await self.notifications.send(operation)
                operation = await self._delivery(operation, "notification", {"state": outcome})
            return operation
        except Exception as err:
            # An applied receipt must never turn into a generic tool failure that
            # encourages repeating the collection mutation.
            return {**operation, "delivery_unconfirmed": type(err).__name__,
                    "next_step": "Read operation status; retry with the same request_id only."}

    async def run(self, action: str, params: dict[str, Any], *, request_id: str | None = None,
                  preview_token: str | None = None, confirm: bool = False) -> dict[str, Any]:
        if preview_token and not request_id:
            raise ValueError("confirmation-requires-the-original-request-id")
        request_id = secrets.token_hex(16) if request_id is None else request_id
        if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{7,127}", request_id) is None:
            raise ValueError("invalid-request-id")
        operation_id = hashlib.sha256(request_id.encode()).hexdigest()[:32]
        async with self.lock:
            try:
                existing = await self.status(operation_id)
            except HelperRejected as err:
                if str(err) != "operation-not-found":
                    raise
                existing = None
            payload = {"action": action, "params": params, "request_id": request_id}
            if existing and existing["state"] != "prepared":
                # The helper verifies the payload digest before returning a
                # terminal receipt, even though it no longer retains the body.
                operation = await self.helper.post("/operations/prepare", payload)
                return await self._finish(operation)
            if self.sync_enabled:
                presync = await self.syncer.run_fresh()
                if presync["outcome"] != "synced":
                    return {"state": "not-applied", "request_id": request_id, "operation_id": operation_id,
                            "presync": presync, "next_step": "Resolve normal sync before applying changes."}
            operation = await self.helper.post("/operations/prepare", payload)
            if operation["state"] != "prepared":
                return await self._finish(operation)
            if operation["schema_required"]:
                return {**operation, "next_step": "Review the preview, then run the root anki-host-approve command."}
            if operation["confirmation_required"] and (not preview_token or confirm is not True):
                return {**operation, "next_step": "Show this preview and obtain confirmation; repeat the same request_id and preview_token with confirm=true."}
            try:
                operation = await self.helper.post("/operations/apply", {
                    "operation_id": operation_id, "preview_token": preview_token or operation["preview_token"],
                    "confirm": confirm})
            except HelperUnavailable:
                return {"state": "unknown", "operation_id": operation_id, "request_id": request_id,
                        "next_step": "The apply response was lost. Read operation status; do not submit a new request_id."}
            return await self._finish(operation)
