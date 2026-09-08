import asyncio

import pytest

from anki_mcp.helper import HelperRejected, HelperUnavailable
from anki_mcp.operations import OperationService
from anki_host_fixture.operations import OperationError
from test_host_operations import engine


class Helper:
    def __init__(self, ops):
        self.ops = ops
        self.calls = []
        self.lose_apply_response = False
        self.fail_delivery = False

    async def post(self, path, payload):
        self.calls.append(path)
        try:
            if path.endswith("/status"):
                return self.ops.status(payload["operation_id"])
            if path.endswith("/prepare"):
                return self.ops.prepare(payload["action"], payload["params"], payload["request_id"])
            if path.endswith("/apply"):
                result = self.ops.apply(payload["operation_id"], payload["preview_token"], payload["confirm"])
                if self.lose_apply_response:
                    raise HelperUnavailable("response lost")
                return result
            if self.fail_delivery:
                raise HelperUnavailable("delivery receipt lost")
            return self.ops.record_delivery(payload["operation_id"], payload["kind"], payload["receipt"])
        except OperationError as err:
            raise HelperRejected(str(err)) from err


class Syncer:
    def __init__(self, outcomes=()):
        self.outcomes = list(outcomes)
        self.calls = []
        self.media_state = "synced"

    async def run_fresh(self, *, after=None):
        self.calls.append(after)
        outcome = self.outcomes.pop(0) if self.outcomes else "synced"
        return {"outcome": outcome, "status": {"runId": "run-" + str(len(self.calls)),
            "runStartedAt": "2026-09-09T01:00:00.000001+09:00", "result": "success" if outcome == "synced" else "error",
            "action": "normal", "media_state": self.media_state}}


class Notify:
    enabled = True
    def __init__(self, outcome="sent"):
        self.outcome, self.calls = outcome, []

    async def send(self, operation):
        self.calls.append(operation)
        return self.outcome


def setup(tmp_path, outcomes=(), notify=None):
    ops, adapter = engine(tmp_path)
    helper, syncer = Helper(ops), Syncer(outcomes)
    return OperationService(helper, syncer, notify, sync_enabled=True), helper, syncer, adapter


PARAMS = {"note_ids": [1], "tags": ["t"]}


@pytest.mark.anyio
async def test_presync_failure_does_not_prepare_or_apply(tmp_path):
    service, helper, syncer, adapter = setup(tmp_path, ["blocked"])
    result = await service.run("add_tags", PARAMS, request_id="presync01")
    assert result["state"] == "not-applied" and not adapter.calls
    assert "/operations/prepare" not in helper.calls and "/operations/apply" not in helper.calls


@pytest.mark.anyio
async def test_postsync_retry_never_repeats_mutation(tmp_path):
    service, helper, syncer, adapter = setup(tmp_path, ["synced", "timeout", "synced"])
    result = await service.run("add_tags", PARAMS, request_id="postsync1")
    assert result["state"] == "applied" and result["sync"]["state"] == "pending"
    again = await service.run("add_tags", PARAMS, request_id="postsync1")
    assert again["sync"]["state"] == "synced" and len(adapter.calls) == 1
    assert syncer.calls == [None, 1000, 1000]


@pytest.mark.anyio
async def test_first_confirm_true_does_not_skip_preview(tmp_path):
    service, helper, syncer, adapter = setup(tmp_path)
    p = await service.run("delete_notes", {"note_ids": [1]}, request_id="confirm01", confirm=True)
    assert p["state"] == "prepared" and not adapter.calls
    result = await service.run("delete_notes", {"note_ids": [1]}, request_id="confirm01",
                               preview_token=p["preview_token"], confirm=True)
    assert result["state"] == "applied" and len(adapter.calls) == 1
    assert syncer.calls == [None, None, 1000]


@pytest.mark.anyio
async def test_lost_apply_response_is_reconciled_by_same_id(tmp_path):
    service, helper, syncer, adapter = setup(tmp_path)
    helper.lose_apply_response = True
    result = await service.run("add_tags", PARAMS, request_id="lostresp1")
    assert result["state"] == "unknown" and len(adapter.calls) == 1
    assert len(syncer.calls) == 1
    result = await service.run("add_tags", PARAMS, request_id="lostresp1")
    assert result["state"] == "applied" and len(adapter.calls) == 1
    assert helper.calls.count("/operations/apply") == 1


@pytest.mark.anyio
async def test_unknown_journal_result_is_not_synced_or_reapplied(tmp_path):
    service, helper, syncer, adapter = setup(tmp_path)
    adapter.fail = True
    result = await service.run("add_tags", PARAMS, request_id="unknown01")
    assert result["state"] == "unknown"
    again = await service.run("add_tags", PARAMS, request_id="unknown01")
    assert again["state"] == "unknown" and len(adapter.calls) == len(syncer.calls) == 1


@pytest.mark.anyio
async def test_partial_writes_sync_and_notification_has_its_own_result(tmp_path):
    notification = Notify("unknown")
    service, helper, syncer, adapter = setup(tmp_path, notify=notification)
    adapter.result = {"state": "partial", "added": 1}
    result = await service.run("add_tags", PARAMS, request_id="partial01")
    assert result["state"] == "partial" and result["sync"]["state"] == "synced"
    assert result["notification"]["state"] == "unknown"
    await service.run("add_tags", PARAMS, request_id="partial01")
    assert len(adapter.calls) == len(notification.calls) == 1
    assert notification.calls[0]["notification"]["state"] == "sending"


@pytest.mark.anyio
async def test_delivery_record_failure_keeps_applied_result(tmp_path):
    service, helper, syncer, adapter = setup(tmp_path)
    helper.fail_delivery = True
    result = await service.run("add_tags", PARAMS, request_id="delivery1")
    assert result["state"] == "applied" and result["delivery_unconfirmed"] == "HelperUnavailable"
    assert len(adapter.calls) == 1


@pytest.mark.anyio
async def test_concurrent_same_request_applies_only_once(tmp_path):
    service, helper, syncer, adapter = setup(tmp_path)
    first, second = await asyncio.gather(*[
        service.run("add_tags", PARAMS, request_id="parallel1") for _ in range(2)])
    assert first["state"] == second["state"] == "applied" and len(adapter.calls) == 1


@pytest.mark.anyio
async def test_schema_is_only_prepared_by_mcp(tmp_path):
    service, helper, syncer, adapter = setup(tmp_path)
    result = await service.run("model_field_add", {"model_name": "Basic", "field_name": "Extra"}, request_id="schema001")
    assert result["schema_required"] and result["state"] == "prepared" and not adapter.calls


@pytest.mark.anyio
@pytest.mark.parametrize("media_state", [None, "disabled", "not-started"])
async def test_media_requires_explicit_completion_and_retry_only_resyncs(tmp_path, media_state):
    notification = Notify()
    service, helper, syncer, adapter = setup(tmp_path, notify=notification)
    syncer.media_state = media_state
    params = {"filename": "fixture.txt", "data": "YQ=="}
    result = await service.run("store_media", params, request_id="mediawait01")
    assert result["state"] == "applied" and result["sync"]["state"] == "pending"
    assert result["sync"]["media_state"] == (media_state or "unknown")
    assert notification.calls[0]["sync"]["state"] == "pending"
    syncer.media_state = "synced"
    result = await service.run("store_media", params, request_id="mediawait01")
    assert result["sync"]["state"] == result["sync"]["media_state"] == "synced"
    assert len(adapter.calls) == helper.calls.count("/operations/apply") == 1
    assert len(syncer.calls) == 3


@pytest.mark.anyio
@pytest.mark.parametrize("failure", ["blocked", "timeout"])
async def test_media_sync_failure_does_not_claim_completion_or_store_twice(tmp_path, failure):
    service, helper, syncer, adapter = setup(tmp_path, ["synced", failure, "synced"])
    params = {"filename": "fixture.txt", "data": "YQ=="}
    result = await service.run("store_media", params, request_id="mediaretry1")
    assert result["state"] == "applied"
    assert result["sync"]["state"] == ("blocked" if failure == "blocked" else "pending")
    assert result["sync"]["media_state"] == "unknown"
    result = await service.run("store_media", params, request_id="mediaretry1")
    assert result["sync"]["state"] == result["sync"]["media_state"] == "synced"
    assert len(adapter.calls) == helper.calls.count("/operations/apply") == 1
