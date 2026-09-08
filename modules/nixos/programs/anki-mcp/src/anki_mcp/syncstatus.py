"""\"지금 동기화\" — 결정 13·15.

헬퍼 /sync를 직접 부르지 않고 `anki-host-sync-<instance>.service`를 트리거한다(polkit이 이 유저에게 start만 허용).
결과는 sync 스크립트가 /run 게시판에 남기는 상태 사본(결정 15)에서 읽는다. 상태 파일만으로는 "실행 중"과
"죽은 흔적"을 구분할 수 없으므로 `systemctl show -p ActiveState,InvocationID`로 유닛을 실측해 대조한다:

  - 유닛 active + InvocationID == runId + result running → 이미 진행 중. 새 회차는 생기지 않는다(systemd가 진행
    중인 job에 합류) — 그 사실을 그대로 알린다.
  - 유닛 inactive + result running → 죽은 흔적. 트리거 가능.
  - 트리거 뒤: runId가 바뀌고 result ≠ running → 그 회차의 결과. 유닛이 inactive로 돌아왔는데 runId가 그대로면
    건너뛴 회차(락 경합·ConditionPathExists 스킵) — 무한 폴링 대신 그 사실을 알린다.
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Awaitable, Callable

CmdRunner = Callable[[list[str]], Awaitable[tuple[int, str, str]]]


async def run_cmd(argv: list[str]) -> tuple[int, str, str]:
    def _run() -> tuple[int, str, str]:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        return proc.returncode, proc.stdout, proc.stderr

    return await asyncio.to_thread(_run)


def read_status(path: str) -> dict[str, Any] | None:
    try:
        with open(path, encoding="utf-8") as stream:
            data = json.load(stream)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def summarize(state: dict[str, Any] | None) -> dict[str, Any]:
    """상태 사본을 도구 응답용으로 요약한다 — 어휘는 anki-host-sync.sh 상단 표."""
    if not state:
        return {"available": False}
    sync = state.get("sync") or {}
    before = sync.get("before") or {}
    after = sync.get("after") or {}

    def delta(key: str) -> int | None:
        if key in before and key in after:
            return int(after[key]) - int(before[key])
        return None

    return {
        "available": True,
        "result": state.get("result"),
        "mode": state.get("mode"),
        "error": state.get("error"),
        "runId": state.get("runId"),
        "runStartedAt": state.get("runStartedAt"),
        "lastAttemptAt": state.get("lastAttemptAt"),
        "lastSuccessAt": state.get("lastSuccessAt"),
        "lastSuccessCounts": state.get("lastSuccessCounts"),
        "action": sync.get("action"),
        "required": sync.get("required"),
        "counts_after": {k: after.get(k) for k in ("notes", "cards", "revlog", "today_reviews")} if after else None,
        "delta": {k: delta(k) for k in ("notes", "cards", "revlog")} if before and after else None,
    }


@dataclass
class UnitState:
    active_state: str
    invocation_id: str

    @property
    def running(self) -> bool:
        return self.active_state in ("active", "activating", "deactivating")


async def unit_state(unit: str, runner: CmdRunner = run_cmd) -> UnitState:
    rc, out, err = await runner(["systemctl", "show", "-p", "ActiveState,InvocationID", unit])
    if rc != 0:
        raise RuntimeError(f"systemctl show failed: {err.strip()[:200]}")
    values: dict[str, str] = {}
    for line in out.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            values[k.strip()] = v.strip()
    return UnitState(values.get("ActiveState", "unknown"), values.get("InvocationID", ""))


def classify(state: dict[str, Any] | None, unit: UnitState) -> str:
    """'running' | 'stale-running' | 'idle'."""
    if state and state.get("result") == "running":
        if unit.running and unit.invocation_id and unit.invocation_id == state.get("runId"):
            return "running"
        if not unit.running:
            return "stale-running"
        return "running"  # active but runId mismatch — treat as running (another invocation in flight)
    return "idle"


class SyncNow:
    def __init__(
        self,
        status_file: str,
        unit: str,
        wait_secs: int,
        runner: CmdRunner = run_cmd,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
        poll_interval: float = 2.0,
        monotonic: Callable[[], float] = time.monotonic,
        wall_clock: Callable[[], float] = time.time,
    ) -> None:
        self._status_file = status_file
        self._unit = unit
        self._wait = wait_secs
        self._run = runner
        self._sleep = sleep
        self._poll = poll_interval
        self._monotonic, self._wall_clock = monotonic, wall_clock

    async def run_fresh(self, *, after: float | None = None) -> dict[str, Any]:
        """Wait for existing work, then require a new successful normal run."""
        deadline = self._monotonic() + self._wait
        earliest = max(after or 0, self._wall_clock())

        async def bounded(awaitable):
            return await asyncio.wait_for(awaitable, max(0.001, deadline - self._monotonic()))

        async def pause():
            await bounded(self._sleep(min(self._poll, max(0.001, deadline - self._monotonic()))))

        try:
            while (await bounded(unit_state(self._unit, self._run))).running:
                if self._monotonic() >= deadline:
                    raise TimeoutError
                await pause()
            before_run_id = (read_status(self._status_file) or {}).get("runId")
            rc, _out, _err = await bounded(self._run(["systemctl", "start", "--no-block", self._unit]))
            if rc != 0:
                return {"outcome": "trigger-failed", "status": summarize(read_status(self._status_file))}
            while self._monotonic() < deadline:
                await pause()
                state = read_status(self._status_file)
                unit = await bounded(unit_state(self._unit, self._run))
                if state and state.get("runId") and state["runId"] != before_run_id and state.get("result") != "running":
                    status = summarize(state)
                    try:
                        started = datetime.fromisoformat(state["runStartedAt"]).timestamp()
                    except (KeyError, TypeError, ValueError):
                        started = 0
                    ok = (state.get("result") == "success" and state.get("mode") == "normal"
                          and status.get("action") == "normal" and started > earliest)
                    return {"outcome": "synced" if ok else "blocked", "status": status}
                if not unit.running:
                    return {"outcome": "skipped", "status": summarize(state)}
        except (TimeoutError, subprocess.TimeoutExpired):
            pass
        except (OSError, RuntimeError):
            return {"outcome": "unavailable", "status": summarize(read_status(self._status_file))}
        return {"outcome": "timeout", "status": summarize(read_status(self._status_file))}

    async def run(self) -> dict[str, Any]:
        before = read_status(self._status_file)
        unit = await unit_state(self._unit, self._run)
        kind = classify(before, unit)
        before_run_id = (before or {}).get("runId")
        if kind == "running":
            return {
                "outcome": "already-running",
                "detail": "a sync run is already in progress; systemd merges start requests into the running job, "
                "so changes made just now will be picked up by the next run",
                "status": summarize(before),
            }
        rc, _out, err = await self._run(["systemctl", "start", "--no-block", self._unit])
        if rc != 0:
            return {"outcome": "trigger-failed", "detail": err.strip()[:300], "status": summarize(before)}
        waited = 0.0
        while waited < self._wait:
            await self._sleep(self._poll)
            waited += self._poll
            now = read_status(self._status_file)
            run_id = (now or {}).get("runId")
            if now and run_id != before_run_id and now.get("result") != "running":
                return {"outcome": "completed", "status": summarize(now)}
            unit = await unit_state(self._unit, self._run)
            if not unit.running:
                if run_id == before_run_id:
                    return {
                        "outcome": "skipped",
                        "detail": "the unit finished without writing a new run — another run held the lock "
                        "(bootstrap/timer overlap) or the unit's start condition was not met; try again shortly",
                        "status": summarize(now),
                    }
                # 새 회차가 기록됐는데 유닛이 이미 멈췄다 — 마지막 기록이 방금 도착했을 수 있으니 한 번 더 읽는다
                now = read_status(self._status_file)
                if now and now.get("result") != "running":
                    return {"outcome": "completed", "status": summarize(now)}
                return {
                    "outcome": "failed",
                    "detail": "the unit exited before recording a result (crashed or was killed); "
                    "check `journalctl -u " + self._unit + "`",
                    "status": summarize(now),
                }
        return {"outcome": "timeout", "detail": f"no result within {self._wait}s; the run may still be in progress",
                "status": summarize(read_status(self._status_file))}
