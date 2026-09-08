import json
from datetime import datetime, timezone

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
    s = summarize({"result": "success", "runId": "r", "sync": {"action": "normal", "required": "NO_CHANGES", "media": {"state": "synced"},
                   "before": {"notes": 10, "cards": 12, "revlog": 100}, "after": {"notes": 11, "cards": 13, "revlog": 103}}})
    assert s["delta"] == {"notes": 1, "cards": 1, "revlog": 3} and s["action"] == "normal"
    assert s["media_state"] == "synced"
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
async def test_sync_now_reports_failed_when_new_run_dies(tmp_path):
    status = tmp_path / "main.json"
    _write(status, result="success", runId="old", sync={"action": "normal"})
    fake = FakeSystemd(status, on_start=lambda: _write(status, result="running", runId="new", sync={}))

    async def no_sleep(_):
        fake.active = "inactive"  # 새 회차를 기록한 뒤 결과를 남기지 못하고 죽었다

    out = await SyncNow(str(status), "u.service", wait_secs=100, runner=fake, sleep=no_sleep).run()
    assert out["outcome"] == "failed" and out["status"]["runId"] == "new"


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


class Clock:
    def __init__(self): self.now = 1000.5
    def __call__(self): return self.now
    async def sleep(self, seconds): self.now += seconds


def normal(path, run_id, started, *, result="success", mode="normal", action="normal"):
    _write(path, result=result, runId=run_id, mode=mode,
           runStartedAt=datetime.fromtimestamp(started, timezone.utc).isoformat(timespec="microseconds"),
           sync={"action": action, "required": "NO_CHANGES"})


@pytest.mark.anyio
@pytest.mark.parametrize("fault", [None, "same-second", "missing-time", "failure", "full", "bootstrap"])
async def test_fresh_sync_requires_new_normal_success_after_apply(tmp_path, fault):
    path, clock = tmp_path / "main.json", Clock()
    normal(path, "old", 900)
    def land():
        normal(path, "new", 1000 if fault == "same-second" else 1000.6,
               result="error" if fault == "failure" else "success",
               mode="allow-download-if-empty" if fault == "bootstrap" else "normal",
               action="full-sync-required" if fault == "full" else "normal")
        if fault == "missing-time":
            data = json.loads(path.read_text())
            data.pop("runStartedAt")
            path.write_text(json.dumps(data))
    systemd = FakeSystemd(path, on_start=land)
    syncer = SyncNow(str(path), "u.service", 10, runner=systemd, sleep=clock.sleep,
                     monotonic=clock, wall_clock=clock)
    out = await syncer.run_fresh(after=1000.5)
    assert out["outcome"] == ("synced" if fault is None else "blocked")
    assert systemd.started == 1


@pytest.mark.anyio
async def test_fresh_sync_waits_for_active_even_when_status_looks_terminal(tmp_path):
    path, clock = tmp_path / "main.json", Clock()
    normal(path, "old", 900)
    def land(): normal(path, "new", clock.now + 0.1)
    systemd = FakeSystemd(path, active="active", invocation="current", on_start=land)
    async def sleep(seconds):
        assert systemd.started == (0 if systemd.active == "active" else 1)
        await clock.sleep(seconds)
        systemd.active = "inactive"
    result = await SyncNow(str(path), "u.service", 10, runner=systemd, sleep=sleep,
                           monotonic=clock, wall_clock=clock).run_fresh()
    assert result["outcome"] == "synced" and systemd.started == 1


@pytest.mark.anyio
async def test_fresh_sync_deadline_includes_slow_systemctl(tmp_path):
    path, clock = tmp_path / "main.json", Clock()
    systemd = FakeSystemd(path, active="active")
    async def slow(argv):
        clock.now += 6
        return await systemd(argv)
    result = await SyncNow(str(path), "u.service", 5, runner=slow, sleep=clock.sleep,
                           monotonic=clock, wall_clock=clock).run_fresh()
    assert result["outcome"] == "timeout" and systemd.started == 0
