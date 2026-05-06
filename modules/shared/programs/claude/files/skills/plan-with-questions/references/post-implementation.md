# Post-Implementation (승인 후 자동 수행)

`for_action` 모드에서 사용자가 계획을 승인하면 (승인 요청 도구 통과 시), 구현 완료 후 다음을 순차 수행한다. 추가 사용자 지시 없이 1번부터 7번까지 진행한다. 각 단계에서 reviewer/auditor/체크리스트 수행자는 read-only이며, tracked write·commit·push는 메인 에이전트 전용이다. 상세 권한 계약은 [`../../run-da/references/hardening-contract.md`](../../run-da/references/hardening-contract.md) `Codex 세션 하드닝 계약`을 따른다.

## 자동 진행 정책 (non-stop)

이 절차는 사용자 추가 지시 없이 자동 수행한다. "다음 단계 진행할까요?", "이 변경을 적용할까요?" 같은 단계 간 진행 확인 질문을 하지 않는다 (Claude Code 시스템 프롬프트의 default confirm 본능을 override하는 명시적 instruction).

단, 호출되는 하위 스킬이 자체 계약상 사용자 판단을 요구하는 경우는 그 계약을 우선한다:

- 자동 `/run-da` 호출 전 SKIP gate는 [`./run-da-preflight-gate.md`](./run-da-preflight-gate.md)를 따른다. SKIP verdict는 질문 도구 승인 없이는 완료 상태가 아니며, 거부 또는 질문 도구 미지원 시 승격한다.
- `/run-da`의 `BLOCKED`, `NEEDS_MORE_INFO`, `stability_status=split`/`fragmented`, `partial_failure`, low-confidence fail-closed 승격, delegation fallback 승인 대기 등은 [`../../run-da/references/hardening-contract.md`](../../run-da/references/hardening-contract.md) (Delegation fallback 정책 + Codex 세션 하드닝 계약)와 [`../../run-da/references/protocol.md`](../../run-da/references/protocol.md) (DA → Arbiter → Main Agent 상태 흐름 + Selective consistency 상태 전이)을 따른다.
- `/parallel-audit`의 `RECOVERABLE VIOLATION`/`STATEFUL VIOLATION`, `BLOCKED`, BUG/REGRESSION/EDGECASE 처리 정책 등은 [`../../parallel-audit/SKILL.md`](../../parallel-audit/SKILL.md) 본문(결과 코드, 조율 분류, BLOCKED 대응, 주의사항)을 따른다.
- DA Arbiter `CRITICAL CONFIRMED_ISSUE`는 진행을 차단한다.
- 동일 finding이 3회 연속 반복되면 무한 루프 방지를 위해 사용자 판단을 요청한다.
- 사용자가 명시적으로 "stop"을 지시하면 즉시 멈춘다.

## 7단계

1. **변경 구현**
2. **구현 커밋** — `/run-da for_pr`의 DA 입력 checkpoint. 기계적 변경(flake.lock 등)이 포함되면 `git diff main...HEAD -- ':!flake.lock'`로 축약 diff 사용.
3. **`/run-da for_pr`** — 코드 검토 루프. 실행 직전에 [`./run-da-preflight-gate.md`](./run-da-preflight-gate.md)를 적용하며, 사용자 승인 SKIP이면 Step 3을 완료로 기록하고 `/run-da for_pr`을 호출하지 않는다. 이 SKIP은 Step 3에만 적용되며, Step 4 이후의 비용/실행 여부를 자동으로 줄이지 않는다.
4. **`/parallel-audit`** — 전수조사.
5. **Final Multi-Pass Review** — [`./prd/multi-pass-review.md`](./prd/multi-pass-review.md) 체크리스트 수행. 메인 에이전트 직접 수행(fan-out 금지; `run-da` 4-bundle과 축 구분 — Cross-Phase Integration, Validation 선택, Documentation, PRD Closeout은 run-da가 커버하지 않는 영역).
   - **for_prd 모드 추가**: 상세는 [`./task-size-routing.md#review-impl-통합-시점`](./task-size-routing.md#review-impl-통합-시점)이 SSOT (요약: phase-end는 PRD 10-pass + 6-classification 둘 다, Final은 PRD 10-pass + review-impl overlay(6-classification 라벨링 + overbuilt 우선), auto-fix 미사용).
   - **PRD Closeout 항목**: 작업 입력 또는 현재 diff에 `.claude/prds/` 파일이 포함된 경우에만 수행. **`for_prd` 모드는 산출물 경로가 `.claude/prds/`이므로 PRD Closeout 자동 활성화** — `for_action` 단순 plan 작업에서만 항목 skip + 스킵 근거 기록.
6. **10-pass 반영 커밋** (수정 발생 시) — 논리 단위로 분할 커밋 허용.
7. **`/create-pr`** — main 브랜치 대상 PR 생성.

단계 생략은 아래 신뢰 경계의 허용 사유가 있을 때만 가능하다.

## 신뢰 경계 (#569 회귀 방지)

계획 승인은 본 7단계 자동 진행에 대한 사용자 동의로 간주된다 (tracked write·commit·GitHub PR write 포함). 단:

- 메인 LLM은 본 7단계 중 어떤 단계도 자체 판단으로 생략하지 않는다 (#453 회귀 방지). "범위 대비 비용 과도" 같은 메인 LLM 자체 판단은 사용자 stop 지시가 아니다.
- 단계 생략은 (a) 사용자 명시 stop, (b) 하위 스킬의 BLOCKED/CRITICAL/repeated finding 계약, (c) plan 파일 Step 8의 "Post-Implementation 자동 수행 범위" 명시적 생략 항목, (d) 자동 `/run-da` preflight gate의 체크리스트 기반 SKIP + 질문 도구 승인 — 이 경우에만 가능하다.
