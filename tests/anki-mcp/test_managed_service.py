"""Managed restore retries preserve the host journal and delivery trust boundary."""

import asyncio
import copy

import pytest

from anki_mcp.helper import HelperRejected, HelperUnavailable
from anki_mcp.managed import DEFAULT_MODEL, ManagedService
from test_operation_service import Syncer


class FakeManagedHelper:
    def __init__(self):
        self.calls = []
        self.records = {}
        self.apply_count = 0
        self.lost_prepare = False
        self.lost_apply = False
        self.lost_delivery = False
        self.apply_state = "applied"
        self.delivery_state = "synced"

    async def post(self, path, payload):
        self.calls.append((path, copy.deepcopy(payload)))
        if path == "/managed/check":
            return {"status": "drift", "model_name": payload["model_name"], "baseline_digest": "a" * 64,
                    "changes": [{"path": "css"}], "freshness": {"mobile_upload_confirmed": False}}
        if path == "/managed/history":
            return {"incidents": [], "model_name": payload["model_name"], "page": payload}
        request_id = payload["request_id"]
        if path.endswith("/status"):
            if request_id not in self.records:
                raise HelperRejected("managed-restore-not-found")
            return copy.deepcopy(self.records[request_id])
        if path.endswith("/prepare"):
            if request_id not in self.records:
                self.records[request_id] = {"state": "prepared", "request_id": request_id,
                    "model_name": payload["model_name"], "preview_token": "bound-preview",
                    "summary": {"changed": ["css"]}, "sync": {"state": "pending"}}
            if self.lost_prepare:
                raise HelperUnavailable("prepare response lost")
        elif path.endswith("/apply"):
            record = self.records[request_id]
            if payload["preview_token"] != record["preview_token"]:
                raise HelperRejected("stale-preview")
            if payload["confirm"] is not True:
                raise AssertionError("confirmation missing")
            self.apply_count += 1
            self.records[request_id] = {**record, "state": self.apply_state, "applied_at": 1000}
            if self.lost_apply:
                raise HelperUnavailable("apply response lost")
        elif path.endswith("/delivery"):
            # A sync receipt never crosses this boundary. Production reads its
            # own completed status, hashes, and preservation proof here.
            assert payload == {"request_id": request_id}
            if self.lost_delivery:
                raise HelperUnavailable("delivery response lost")
            self.records[request_id]["sync"] = {"state": self.delivery_state}
        else:
            raise AssertionError(path)
        return copy.deepcopy(self.records[request_id])


def setup(outcomes=(), *, sync_enabled=True):
    helper, syncer = FakeManagedHelper(), Syncer(outcomes)
    service = ManagedService(helper, syncer, sync_enabled=sync_enabled, lock=asyncio.Lock())
    return service, helper, syncer


async def preview(service, request_id="managed001"):
    return await service.restore(request_id=request_id)


async def confirm(service, request_id="managed001", token="bound-preview"):
    return await service.restore(request_id=request_id, preview_token=token, confirm=True)


@pytest.mark.anyio
async def test_preview_then_confirmation_has_fresh_pre_and_post_sync():
    service, helper, syncer = setup()
    prepared = await preview(service)
    assert prepared["state"] == "prepared" and helper.apply_count == 0
    assert "independent human authentication" in prepared["next_step"]
    result = await confirm(service)
    assert result["state"] == "applied" and result["sync"]["state"] == "synced"
    assert syncer.calls == [None, None, 1000] and helper.apply_count == 1
    assert helper.calls[-1] == ("/managed/restore/delivery", {"request_id": "managed001"})


@pytest.mark.anyio
async def test_confirm_true_on_first_call_cannot_skip_preview():
    service, helper, _ = setup()
    result = await service.restore(confirm=True)
    assert result["state"] == "prepared" and result["request_id"] and helper.apply_count == 0


@pytest.mark.anyio
async def test_token_without_confirmation_is_still_preview_only():
    service, helper, _ = setup()
    await preview(service)
    result = await service.restore(request_id="managed001", preview_token="bound-preview")
    assert result["state"] == "prepared" and helper.apply_count == 0


@pytest.mark.anyio
@pytest.mark.parametrize("outcome", ["blocked", "timeout", "unavailable", "skipped", "trigger-failed"])
async def test_failed_presync_never_prepares_or_applies(outcome):
    service, helper, _ = setup([outcome])
    result = await preview(service)
    assert result["state"] == "not-applied" and result["presync"]["outcome"] == outcome
    assert [path for path, _ in helper.calls] == ["/managed/restore/status"]
    assert "fresh successful sync on every relevant device" in result["next_step"]
    assert "Never select full Download" in result["next_step"]


@pytest.mark.anyio
async def test_presync_failure_at_confirmation_preserves_existing_preview():
    service, helper, _ = setup(["synced", "blocked"])
    await preview(service)
    result = await confirm(service)
    assert result["state"] == "not-applied" and helper.records["managed001"]["state"] == "prepared"
    assert helper.apply_count == 0


@pytest.mark.anyio
async def test_prepare_response_loss_returns_generated_request_id():
    service, helper, _ = setup()
    helper.lost_prepare = True
    result = await service.restore()
    assert result["state"] == "not-applied" and result["preparation_unconfirmed"]
    assert result["request_id"] in helper.records and helper.apply_count == 0
    helper.lost_prepare = False
    reread = await service.status(result["request_id"])
    assert reread["state"] == "prepared"


@pytest.mark.anyio
async def test_lost_apply_response_reconciles_without_reapplying():
    service, helper, syncer = setup()
    await preview(service)
    helper.lost_apply = True
    result = await confirm(service)
    assert result["state"] == "unknown" and helper.apply_count == 1
    assert syncer.calls == [None, None]
    result = await service.restore(request_id="managed001")
    assert result["state"] == "applied" and result["sync"]["state"] == "synced"
    assert helper.apply_count == 1 and syncer.calls == [None, None, 1000]


@pytest.mark.anyio
@pytest.mark.parametrize("state", ["partial", "unknown", "expired"])
async def test_incomplete_terminal_states_are_neither_reapplied_nor_synced(state):
    service, helper, syncer = setup()
    prepared = await preview(service)
    helper.records[prepared["request_id"]]["state"] = state
    result = await confirm(service)
    assert result["state"] == state and helper.apply_count == 0
    assert syncer.calls == [None]
    assert all(not path.endswith(("/apply", "/delivery")) for path, _ in helper.calls)


@pytest.mark.anyio
@pytest.mark.parametrize("state", ["partial", "unknown"])
async def test_uncertain_apply_outcome_never_starts_sync(state):
    service, helper, syncer = setup()
    await preview(service)
    helper.apply_state = state
    result = await confirm(service)
    assert result["state"] == state and helper.apply_count == 1
    assert syncer.calls == [None, None]


@pytest.mark.anyio
async def test_synced_replay_and_status_are_read_only():
    service, helper, syncer = setup()
    await preview(service)
    original = await confirm(service)
    helper.calls.clear()
    result = await service.restore(request_id="managed001")
    assert result == original == await service.status("managed001")
    assert [path for path, _ in helper.calls] == ["/managed/restore/status"] * 2
    assert helper.apply_count == 1 and syncer.calls == [None, None, 1000]


@pytest.mark.anyio
@pytest.mark.parametrize("outcome,state", [("blocked", "blocked"), ("timeout", "pending"), ("synced", "pending")])
async def test_delivery_failure_retry_only_resumes_normal_sync(outcome, state):
    service, helper, syncer = setup(["synced", "synced", outcome, "synced"])
    helper.delivery_state = state
    await preview(service)
    result = await confirm(service)
    assert result["state"] == "applied" and result["sync"]["state"] == state
    assert result["sync_attempt"]["outcome"] == outcome
    helper.delivery_state = "synced"
    result = await service.restore(request_id="managed001")
    assert result["sync"]["state"] == "synced" and helper.apply_count == 1
    assert syncer.calls == [None, None, 1000, 1000]


@pytest.mark.anyio
async def test_sync_success_does_not_override_host_media_failure():
    service, helper, _ = setup()
    await preview(service)
    helper.delivery_state = "pending"
    result = await confirm(service)
    assert result["sync"]["state"] == "pending" and result["sync_attempt"]["outcome"] == "synced"


@pytest.mark.anyio
async def test_delivery_transport_error_keeps_applied_receipt():
    service, helper, _ = setup()
    await preview(service)
    helper.lost_delivery = True
    result = await confirm(service)
    assert result["state"] == "applied" and result["delivery_unconfirmed"] == "HelperUnavailable"
    assert helper.apply_count == 1


@pytest.mark.anyio
async def test_sync_exception_keeps_applied_receipt(monkeypatch):
    service, helper, syncer = setup()
    await preview(service)
    helper.records["managed001"].update(state="applied", applied_at=1000)

    async def fail(**_kwargs):
        raise RuntimeError("systemctl unavailable")

    monkeypatch.setattr(syncer, "run_fresh", fail)
    result = await service.restore(request_id="managed001")
    assert result["state"] == "applied" and result["delivery_unconfirmed"] == "RuntimeError"


@pytest.mark.anyio
async def test_disabled_sync_does_not_claim_delivery():
    service, helper, syncer = setup(sync_enabled=False)
    await preview(service)
    result = await confirm(service)
    assert result["state"] == "applied" and result["sync"]["state"] == "pending"
    assert "not verified" in result["next_step"] and not syncer.calls
    assert all(not path.endswith("/delivery") for path, _ in helper.calls)


@pytest.mark.anyio
async def test_different_model_cannot_reuse_request_or_trigger_delivery():
    service, helper, syncer = setup()
    await preview(service)
    helper.records["managed001"].update(state="applied", applied_at=1000)
    with pytest.raises(ValueError, match="request-id-model-mismatch"):
        await service.restore(model_name="Other", request_id="managed001")
    assert syncer.calls == [None] and helper.apply_count == 0


@pytest.mark.anyio
async def test_stale_token_is_rejected_without_apply():
    service, helper, _ = setup()
    await preview(service)
    with pytest.raises(HelperRejected, match="stale-preview"):
        await confirm(service, token="stale-preview")
    assert helper.apply_count == 0


@pytest.mark.anyio
async def test_concurrent_confirmation_only_applies_once():
    service, helper, syncer = setup()
    await preview(service)
    first, second = await asyncio.gather(confirm(service), confirm(service))
    assert first == second and helper.apply_count == 1 and syncer.calls == [None, None, 1000]


@pytest.mark.anyio
async def test_status_rejection_does_not_mask_unavailability_as_missing(monkeypatch):
    service, helper, syncer = setup()

    async def fail(_path, _payload):
        raise HelperRejected("collection-not-ready")

    monkeypatch.setattr(helper, "post", fail)
    with pytest.raises(HelperRejected, match="collection-not-ready"):
        await preview(service)
    assert not syncer.calls


@pytest.mark.anyio
@pytest.mark.parametrize("kwargs", [
    {"request_id": "short"}, {"request_id": "../escape"}, {"request_id": True},
    {"preview_token": "token"}, {"request_id": "managed001", "preview_token": ""},
    {"confirm": 1}, {"confirm": "true"}, {"model_name": ""},
])
async def test_invalid_arguments_fail_before_helper_or_sync(kwargs):
    service, helper, syncer = setup()
    with pytest.raises(ValueError):
        await service.restore(**kwargs)
    assert not helper.calls and not syncer.calls
