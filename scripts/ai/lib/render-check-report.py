#!/usr/bin/env python3
"""Render `sync-codex-config.py check` JSON output as verifier-friendly lines.

Input (stdin): stdout JSON from `sync-codex-config.py check`, 또는 빈 문자열.
Output (stdout): 한 줄에 하나의 directive. verifier가 case 분기로 소비한다.

    OK_LINE <message>    verifier의 `pass "$message"`로 찍힐 성공 라인
    FAIL_LINE <message>  verifier의 `fail "$message"`로 누적될 실패 라인
    INFO_LINE <message>  단순 정보성 stderr echo (errors 카운트 영향 없음)

Exit code:
    0  verifier가 orchestration을 계속한다. 실제 pass/fail은 생성된 라인으로 표현한다.
    2  JSON shape malformed. 이 경우 verifier 쪽에서 `FAIL_LINE` 한 건을 찍고 섹션을 종료한다.

이 helper는 verify-ai-compat.sh의 drift 검증을 단일 Python 블록으로 모아두기 위한 것이다.
Bash + inline Python + awk 3언어 혼재를 피하려는 목적.
"""
from __future__ import annotations

import json
import sys


def main() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        print("FAIL_LINE check.py stdout 비어 있음 (unexpected)")
        return 2

    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"FAIL_LINE check.py 출력 JSON 파싱 실패: {e}")
        return 2

    if not isinstance(payload, dict):
        print("FAIL_LINE check.py JSON이 object가 아님")
        return 2

    state = payload.get("target_state")
    drift = payload.get("drift")

    if state not in ("present", "missing"):
        print(f"FAIL_LINE check.py JSON 예상치 못한 target_state={state!r}")
        return 2
    if not isinstance(drift, list):
        print(f"FAIL_LINE check.py JSON drift 필드가 list 아님: {type(drift).__name__}")
        return 2

    if state == "missing":
        target = payload.get("target", "<unknown>")
        print(f"FAIL_LINE {target} 없음 (target_state=missing) — activation 미실행 상태일 수 있음 (nrs --force 권장)")
        return 0

    # state == "present"
    if not drift:
        print("OK_LINE template이 선언한 모든 leaf가 live와 일치")
        return 0

    # drift present
    print(f"INFO_LINE template ↔ live drift: {len(drift)}건 감지")
    for item in drift:
        if not isinstance(item, dict):
            print(f"FAIL_LINE drift: malformed item {item!r}")
            continue
        path = item.get("path", "?")
        reason = item.get("reason", "?")
        expected = item.get("expected")
        actual = item.get("actual")
        print(f"FAIL_LINE drift: {path}: {reason} expected={expected!r} actual={actual!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
