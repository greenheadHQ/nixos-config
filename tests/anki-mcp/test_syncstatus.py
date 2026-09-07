import json

import pytest

from anki_mcp.syncstatus import SyncNow, UnitState, classify, summarize


def _write(path, **fields):
    path.write_text(json.dumps(fields))


def test_classify_distinguishes_running_and_stale():
    st = {"result": "running", "runId": "abc"}
    assert classify(st, UnitState("active", "abc")) == "running"
    assert classify(st, UnitState("inactive", "")) == "stale-running"
    assert classify({"result": "success", "runId": "abc"}, UnitState("inactive", "")) == "idle"
    assert classify(None, UnitState("inactive", "")) == "idle"


def test_summarize_reports_delta():
    s = summarize({"result": "success", "runId": "r", "sync": {"action": "normal", "required": "NO_CHANGES",
                   "before": {"notes": 10, "cards": 12, "revlog": 100}, "after": {"notes": 11, "cards": 13, "revlog": 103}}})
    assert s["delta"] == {"notes": 1, "cards": 1, "revlog": 3} and s["action"] == "normal"
    assert summarize(None) == {"available": False}


class FakeSystemd:
    """systemctl show/start를 흉내 낸다. start 뒤 n번째 폴링에서 새 회차 결과를 상태 파일에 쓴다."""

    def __init__(self, status_path, active="inactive", invocation="", on_start=None):
        self.path = status_path
        self.active = active
        self.invocation = invocation
        self.on_start = on_start
        self.started = 0

    async def __call__(self, argv):
        if argv[:2] == ["systemctl", "show"]:
            return 0, f"ActiveState={self.active}\nInvocationID={self.invocation}\n", ""
        if argv[:2] == ["systemctl", "start"]:
            self.started += 1
            if self.on_start:
                self.on_start()
            return 0, "", ""
        return 1, "", "unexpected"


@pytest.mark.anyio
async def test_sync_now_completes_when_new_run_lands(tmp_path):
    status = tmp_path / "main.json"
    _write(status, result="success", runId="old", sync={"action": "normal"})

    def land():
        _write(status, result="success", runId="new", lastSuccessAt="t", sync={"action": "normal", "required": "NO_CHANGES",
               "before": {"notes": 1, "cards": 1, "revlog": 1}, "after": {"notes": 1, "cards": 1, "revlog": 2}})

    fake = FakeSystemd(status, on_start=land)

    async def no_sleep(_):
        return None

    out = await SyncNow(str(status), "u.service", wait_secs=10, runner=fake, sleep=no_sleep).run()
    assert out["outcome"] == "completed" and out["status"]["runId"] == "new" and fake.started == 1


@pytest.mark.anyio
async def test_sync_now_joins_running_job_without_triggering(tmp_path):
    status = tmp_path / "main.json"
    _write(status, result="running", runId="cur")
    fake = FakeSystemd(status, active="active", invocation="cur")

    async def no_sleep(_):
        return None

    out = await SyncNow(str(status), "u.service", wait_secs=10, runner=fake, sleep=no_sleep).run()
    assert out["outcome"] == "already-running" and fake.started == 0


@pytest.mark.anyio
async def test_sync_now_reports_skipped_run(tmp_path):
    status = tmp_path / "main.json"
    _write(status, result="success", runId="old")
    fake = FakeSystemd(status)  # start succeeds but nothing ever writes a new run; unit stays inactive

    async def no_sleep(_):
        return None

    out = await SyncNow(str(status), "u.service", wait_secs=10, runner=fake, sleep=no_sleep, poll_interval=5).run()
    assert out["outcome"] == "skipped"


@pytest.mark.anyio
async def test_sync_now_triggers_over_stale_running(tmp_path):
    status = tmp_path / "main.json"
    _write(status, result="running", runId="dead")

    def land():
        _write(status, result="success", runId="fresh", sync={"action": "normal"})

    fake = FakeSystemd(status, active="inactive", invocation="", on_start=land)

    async def no_sleep(_):
        return None

    out = await SyncNow(str(status), "u.service", wait_secs=10, runner=fake, sleep=no_sleep).run()
    assert out["outcome"] == "completed" and fake.started == 1
