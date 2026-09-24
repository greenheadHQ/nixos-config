"""Writes from gated clients apply only after a confirmation from a later user message (#1359)."""

import asyncio
import hashlib

import pytest

from anki_mcp.confirm_gate import (
    BLOCKED_REASON, GATE_POLICY, UNGATED, UNTRACED_POLICY, ConfirmationGate, Origin, gated_client, trace_id)
from anki_mcp.helper import HelperRejected
from anki_mcp.managed import ManagedService
from anki_mcp.operations import OperationService
from test_host_operations import engine
from test_managed_service import FakeManagedHelper
from test_operation_service import Helper, Syncer

TRACE_A = "0af7651916cd43dd8448eb211c80319c"
TRACE_B = "4bf92f3577b34da6a3ce929d0e0e4736"


def parent(trace: str) -> str:
    return f"00-{trace}-b7ad6b7169203331-01"


@pytest.mark.parametrize("header,expected", [
    (parent(TRACE_A), TRACE_A),
    (parent(TRACE_A).upper(), TRACE_A),
    (f" {parent(TRACE_A)} ", TRACE_A),
    (parent("0" * 32), None),
    (f"01-{TRACE_A}-b7ad6b7169203331-01", None),
    (f"00-{TRACE_A}-b7ad6b7169203331", None),
    ("", None),
    (None, None),
])
def test_trace_id_accepts_only_version_00_traceparent(header, expected):
    assert trace_id(header) == expected


def test_gated_client_matches_exact_redirect_host():
    hosts = {"chatgpt.com"}
    assert gated_client(["https://chatgpt.com/connector_platform_oauth_redirect"], hosts)
    assert gated_client(["https://claude.ai/cb", "https://ChatGPT.com/cb"], hosts)
    assert not gated_client(["https://claude.ai/api/mcp/auth_callback"], hosts)
    assert not gated_client(["https://evil.chatgpt.com.example/cb", "https://sub.chatgpt.com/cb"], hosts)
    assert not gated_client(None, hosts)


def origin_of(trace):
    return Origin(True, trace)


def gate_with(origins, *, enabled=True, now=None):
    queue = list(origins)
    clock = now or (lambda: 1000.0)

    async def resolve():
        return queue.pop(0)
    return ConfirmationGate(resolve, enabled=enabled, clock=clock)


@pytest.mark.anyio
async def test_disabled_gate_never_resolves_origin():
    gate = gate_with([], enabled=False)
    assert await gate.origin() == UNGATED


def test_gate_refuses_only_the_message_that_first_produced_the_preview():
    now = [1000.0]
    gate = ConfirmationGate(None, enabled=True, clock=lambda: now[0])
    op = {"state": "prepared", "expires_at": 1600.0}
    gate.preview(op, "op", origin_of(TRACE_A))
    gate.preview(op, "op", origin_of(TRACE_B))  # a later preview keeps the first message
    assert gate.refusal(op, "op", origin_of(TRACE_A))["confirmation_blocked"] == BLOCKED_REASON
    assert gate.refusal(op, "op", origin_of(TRACE_B)) is None
    assert gate.refusal(op, "op", origin_of(None)) is None
    now[0] = 1601.0
    assert gate.refusal(op, "op", origin_of(TRACE_A)) is None


def setup(tmp_path, origins):
    ops, adapter = engine(tmp_path)
    helper = Helper(ops)
    gate = gate_with(origins)
    return OperationService(helper, Syncer(), None, sync_enabled=True, gate=gate), ops, helper


def state(ops, request_id):
    return ops.status(hashlib.sha256(request_id.encode()).hexdigest()[:32])["state"]


ADD_TAGS = ("add_tags", {"note_ids": [1], "tags": ["gate"]})


@pytest.mark.anyio
async def test_gated_small_write_waits_for_a_confirmation_from_a_later_message(tmp_path):
    rid = "gated-small-write-1"
    service, ops, helper = setup(tmp_path, [origin_of(TRACE_A), origin_of(TRACE_A), origin_of(TRACE_B)])
    preview = await service.run(*ADD_TAGS, request_id=rid)
    assert preview["state"] == "prepared" and preview["confirmation_required"] is True
    assert preview["confirmation_policy"] == GATE_POLICY and "/operations/apply" not in helper.calls
    same = await service.run(*ADD_TAGS, request_id=rid, preview_token=preview["preview_token"], confirm=True)
    assert same["confirmation_blocked"] == BLOCKED_REASON
    assert state(ops, rid) == "prepared" and "/operations/apply" not in helper.calls
    applied = await service.run(*ADD_TAGS, request_id=rid, preview_token=preview["preview_token"], confirm=True)
    assert applied["state"] == "applied"


@pytest.mark.anyio
async def test_without_a_trace_writes_still_wait_for_a_confirmation(tmp_path, caplog):
    rid = "gated-no-trace-01"
    service, ops, helper = setup(tmp_path, [origin_of(None), origin_of(None)])
    preview = await service.run(*ADD_TAGS, request_id=rid)
    assert preview["confirmation_policy"] == UNTRACED_POLICY and "same turn" not in preview["next_step"]
    assert state(ops, rid) == "prepared" and "/operations/apply" not in helper.calls
    applied = await service.run(*ADD_TAGS, request_id=rid, preview_token=preview["preview_token"], confirm=True)
    assert applied["state"] == "applied" and "without a message trace" in caplog.text


@pytest.mark.anyio
async def test_restart_forgets_previews_and_only_requires_the_confirmation(tmp_path):
    rid = "gated-restart-001"
    service, ops, helper = setup(tmp_path, [origin_of(TRACE_A)])
    preview = await service.run(*ADD_TAGS, request_id=rid)
    restarted = OperationService(helper, Syncer(), None, sync_enabled=True, gate=gate_with([origin_of(TRACE_A)]))
    applied = await restarted.run(*ADD_TAGS, request_id=rid, preview_token=preview["preview_token"], confirm=True)
    assert applied["state"] == "applied"


@pytest.mark.anyio
async def test_gated_confirmation_never_substitutes_the_journal_token(tmp_path):
    rid = "gated-wrong-token"
    service, ops, _ = setup(tmp_path, [origin_of(TRACE_A), origin_of(TRACE_B), origin_of(TRACE_B)])
    await service.run(*ADD_TAGS, request_id=rid)
    with pytest.raises(HelperRejected, match="preview-token-mismatch"):
        await service.run(*ADD_TAGS, request_id=rid, preview_token="f" * 64, confirm=True)
    assert state(ops, rid) == "prepared"
    unconfirmed = await service.run(*ADD_TAGS, request_id=rid, preview_token="f" * 64, confirm=False)
    assert unconfirmed["confirmation_policy"] == GATE_POLICY and state(ops, rid) == "prepared"


@pytest.mark.anyio
async def test_gated_destructive_preview_uses_the_same_message_rule(tmp_path):
    rid = "gated-delete-0001"
    service, ops, _ = setup(tmp_path, [origin_of(TRACE_A), origin_of(TRACE_A)])
    preview = await service.run("delete_notes", {"note_ids": [1]}, request_id=rid)
    assert preview["confirmation_required"] is True and preview["confirmation_policy"] == GATE_POLICY
    same = await service.run("delete_notes", {"note_ids": [1]}, request_id=rid,
                             preview_token=preview["preview_token"], confirm=True)
    assert same["confirmation_blocked"] == BLOCKED_REASON
    assert state(ops, rid) == "prepared"


@pytest.mark.anyio
async def test_ungated_client_keeps_immediate_small_writes(tmp_path):
    rid = "ungated-write-001"
    service, ops, _ = setup(tmp_path, [UNGATED])
    applied = await service.run(*ADD_TAGS, request_id=rid)
    assert applied["state"] == "applied" and "confirmation_policy" not in applied


@pytest.mark.anyio
async def test_applied_receipt_is_returned_without_a_new_confirmation(tmp_path):
    rid = "gated-idempotent1"
    service, ops, helper = setup(tmp_path, [origin_of(TRACE_A), origin_of(TRACE_B), origin_of(TRACE_B)])
    preview = await service.run(*ADD_TAGS, request_id=rid)
    await service.run(*ADD_TAGS, request_id=rid, preview_token=preview["preview_token"], confirm=True)
    applies = helper.calls.count("/operations/apply")
    receipt = await service.run(*ADD_TAGS, request_id=rid)
    assert receipt["state"] == "applied" and helper.calls.count("/operations/apply") == applies


@pytest.mark.anyio
async def test_gated_managed_restore_waits_for_a_later_message():
    helper = FakeManagedHelper()
    gate = gate_with([origin_of(TRACE_A), origin_of(TRACE_A), origin_of(TRACE_B)])
    service = ManagedService(helper, Syncer(), sync_enabled=True, lock=asyncio.Lock(), gate=gate)
    preview = await service.restore(request_id="managed001")
    assert preview["confirmation_policy"] == GATE_POLICY
    assert "independent human authentication" in preview["next_step"]
    same = await service.restore(request_id="managed001", preview_token="bound-preview", confirm=True)
    assert same["confirmation_blocked"] == BLOCKED_REASON and helper.apply_count == 0
    applied = await service.restore(request_id="managed001", preview_token="bound-preview", confirm=True)
    assert applied["state"] == "applied" and helper.apply_count == 1
