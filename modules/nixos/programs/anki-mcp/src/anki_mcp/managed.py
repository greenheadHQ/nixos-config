"""Narrow managed-model restore orchestration; the host owns bytes and authority.

The confirmation is dialogue approval submitted by the LLM, not an independent
human authentication channel. It cannot enroll a version or approve arbitrary
schema operations. Content digests, eligibility and restore bytes stay host-owned.
"""

from __future__ import annotations

import asyncio
import re
import secrets
from typing import Any

from .confirm_gate import UNGATED, ConfirmationGate
from .helper import Helper, HelperRejected, HelperUnavailable
from .syncstatus import SyncNow


DEFAULT_MODEL = "CS 재활 Basic"
PREVIEW_NEXT_STEP = (
    "Show the concrete preview and obtain the user's confirmation. Repeat the same request_id "
    "and preview_token with confirm=true. This dialogue confirmation is not independent human authentication."
)
SYNC_NEXT_STEP = (
    "Local restore and AnkiWeb delivery are separate. Inspect this request's status and resolve normal sync. "
    "If full Upload is required, stop for fresh successful sync on every relevant device, pause review/editing, "
    "and obtain explicit Upload approval for this operation through the operator workflow. Never select full "
    "Download automatically or reuse old device/Upload approval. Retry only the same request_id."
)


def request_key(value: str) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{7,127}", value) is None:
        raise ValueError("invalid-request-id")
    return value


class ManagedService:
    def __init__(self, helper: Helper, syncer: SyncNow, *, sync_enabled: bool,
                 lock: asyncio.Lock, gate: ConfirmationGate | None = None) -> None:
        self.helper, self.syncer = helper, syncer
        self.sync_enabled, self.lock, self.gate = sync_enabled, lock, gate

    async def status(self, request_id: str) -> dict[str, Any]:
        """Read the host journal; reading alone never retries mutation or delivery."""
        return await self.helper.post("/managed/restore/status", {"request_id": request_key(request_id)})

    async def _finish(self, operation: dict[str, Any]) -> dict[str, Any]:
        # Unlike ordinary note writes, partial restore must not sync or unblock
        # writes: the complete model/assets and preservation proof are required.
        if operation["state"] != "applied" or operation.get("sync", {}).get("state") == "synced":
            return operation
        if not self.sync_enabled:
            return {**operation, "next_step": "Local restore only; AnkiWeb delivery is not verified because sync is disabled."}
        try:
            attempt = await self.syncer.run_fresh(after=operation["applied_at"])
            # No caller-supplied receipt, digest or success flag reaches this
            # endpoint. The host rereads its own sync status and actual bytes.
            result = await self.helper.post("/managed/restore/delivery", {"request_id": operation["request_id"]})
            if attempt["outcome"] != "synced" or result.get("sync", {}).get("state") != "synced":
                return {**result, "sync_attempt": attempt, "next_step": SYNC_NEXT_STEP}
            return result
        except Exception as err:
            # The mutation may already be durable. Do not make a delivery error
            # look like a failed mutation that can be retried under a new ID.
            return {**operation, "delivery_unconfirmed": type(err).__name__, "next_step": SYNC_NEXT_STEP}

    async def restore(self, *, model_name: str = DEFAULT_MODEL, request_id: str | None = None,
                      preview_token: str | None = None, confirm: bool = False) -> dict[str, Any]:
        if not isinstance(model_name, str) or not model_name:
            raise ValueError("invalid-model-name")
        if type(confirm) is not bool:
            raise ValueError("confirm-must-be-boolean")
        if preview_token is not None and (not isinstance(preview_token, str) or not preview_token):
            raise ValueError("invalid-preview-token")
        if preview_token is not None and request_id is None:
            raise ValueError("confirmation-requires-the-original-request-id")
        request_id = request_key(secrets.token_hex(16) if request_id is None else request_id)
        origin = await self.gate.origin() if self.gate else UNGATED
        gate_key = "managed-restore:" + request_id
        async with self.lock:
            try:
                existing = await self.status(request_id)
            except HelperRejected as err:
                if str(err) != "managed-restore-not-found":
                    raise
                existing = None
            if existing is not None:
                if existing.get("model_name") != model_name:
                    raise ValueError("request-id-model-mismatch")
                if existing["state"] != "prepared":
                    return await self._finish(existing)
            if self.sync_enabled:
                presync = await self.syncer.run_fresh()
                if presync["outcome"] != "synced":
                    return {"state": "not-applied", "request_id": request_id, "model_name": model_name,
                            "presync": presync, "next_step": SYNC_NEXT_STEP}
            try:
                operation = await self.helper.post("/managed/restore/prepare", {
                    "request_id": request_id, "model_name": model_name})
            except HelperUnavailable:
                return {"state": "not-applied", "request_id": request_id, "model_name": model_name,
                        "preparation_unconfirmed": True,
                        "next_step": "The prepare response was lost. Inspect anki_managed_restore_status with this "
                                     "request_id; retry preparation only with the same ID. No apply was requested."}
            if operation["state"] != "prepared":
                return await self._finish(operation)
            gate = self.gate if origin.gated else None
            if preview_token is None or not confirm:
                if gate is not None:
                    return gate.preview(operation, gate_key, origin)
                return {**operation, "next_step": PREVIEW_NEXT_STEP}
            if gate is not None:
                refused = gate.refusal(operation, gate_key, origin)
                if refused:
                    return refused
            try:
                operation = await self.helper.post("/managed/restore/apply", {
                    "request_id": request_id, "preview_token": preview_token, "confirm": True})
            except HelperUnavailable:
                return {"state": "unknown", "request_id": request_id, "model_name": model_name,
                        "next_step": "The apply response was lost. Read anki_managed_restore_status with this request_id; "
                                     "do not submit a new request_id or reapply an unknown/partial operation."}
            if gate is not None:
                gate.forget(gate_key)
            return await self._finish(operation)
