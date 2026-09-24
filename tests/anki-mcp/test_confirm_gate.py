"""Writes from gated clients apply only after a confirmation from a later user message (#1359)."""

import asyncio
import hashlib

import pytest

from anki_mcp.confirm_gate import (
    GATE_POLICY, UNGATED, ConfirmationGate, Origin, gated_client, trace_id)
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


def test_gate_remembers_first_preview_trace_and_expires():
    now = [1000.0]
    gate = ConfirmationGate(None, enabled=True, clock=lambda: now[0])
    gate.note_preview("op", origin_of(TRACE_A), 1600.0)
    gate.note_preview("op", origin_of(TRACE_B), 1600.0)  # a later preview keeps the first message
    assert gate.blocked("op", origin_of(TRACE_A), 1600.0) == "confirmation-requires-a-new-user-message"
    assert gate.blocked("op", origin_of(TRACE_B), 1600.0) is None
    assert gate.blocked("op", origin_of(None), 1600.0) == "confirmation-trace-unavailable"
    now[0] = 1601.0
    assert gate.blocked("op", origin_of(TRACE_B), 1600.0) == "confirmation-preview-not-recorded"


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
    assert same["confirmation_blocked"] == "confirmation-requires-a-new-user-message"
    assert state(ops, rid) == "prepared" and "/operations/apply" not in helper.calls
    applied = await service.run(*ADD_TAGS, request_id=rid, preview_token=preview["preview_token"], confirm=True)
    assert applied["state"] == "applied"


@pytest.mark.anyio
async def test_gated_confirmation_without_trace_is_refused(tmp_path):
    rid = "gated-no-trace-01"
    service, ops, _ = setup(tmp_path, [origin_of(TRACE_A), origin_of(None)])
    preview = await service.run(*ADD_TAGS, request_id=rid)
    refused = await service.run(*ADD_TAGS, request_id=rid, preview_token=preview["preview_token"], confirm=True)
    assert refused["confirmation_blocked"] == "confirmation-trace-unavailable" and state(ops, rid) == "prepared"


@pytest.mark.anyio
async def test_restart_loses_preview_trace_and_asks_for_one_more_message(tmp_path):
    rid = "gated-restart-001"
    service, ops, helper = setup(tmp_path, [origin_of(TRACE_A)])
    preview = await service.run(*ADD_TAGS, request_id=rid)
    restarted = OperationService(helper, Syncer(), None, sync_enabled=True,
                                 gate=gate_with([origin_of(TRACE_B), origin_of(TRACE_B), origin_of(TRACE_A)]))
    first = await restarted.run(*ADD_TAGS, request_id=rid, preview_token=preview["preview_token"], confirm=True)
    assert first["confirmation_blocked"] == "confirmation-preview-not-recorded" and state(ops, rid) == "prepared"
    again = await restarted.run(*ADD_TAGS, request_id=rid, preview_token=preview["preview_token"], confirm=True)
    assert again["confirmation_blocked"] == "confirmation-requires-a-new-user-message"
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
    assert same["confirmation_blocked"] == "confirmation-requires-a-new-user-message"
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
    assert same["confirmation_blocked"] == "confirmation-requires-a-new-user-message" and helper.apply_count == 0
    applied = await service.restore(request_id="managed001", preview_token="bound-preview", confirm=True)
    assert applied["state"] == "applied" and helper.apply_count == 1
