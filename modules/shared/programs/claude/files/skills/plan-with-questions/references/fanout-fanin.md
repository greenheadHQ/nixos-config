# Fan-out / Fan-in (for_issue, for_action Step 3.5)

`for_issue` 의 레퍼런스 수집은 이 문서의 fan-out / fan-in runtime route를 따른다. `for_action` 의 Step 3.5 외부 자문은 아래 역할 카탈로그에만 연결된다. 호출 경로의 단일 SSOT는 [`consulting-step-shell.md`](./consulting-step-shell.md) 다.

## 역할 카탈로그

fan-out 에이전트에 할당할 수 있는 역할:

| 역할 | 설명 | 모델 권장 |
|------|------|----------|
| 코드베이스 분석 | 관련 파일 / 모듈 / 패턴 탐색 | Sonnet |
| 이슈 또는 PR 검색 | 기존 이슈, closed PR, 중복 확인 | Sonnet |
| 커밋 이력 분석 | 관련 커밋, blame, 변경 맥락 | Sonnet |
| 웹 리서치 | 외부 문서, 라이브러리, 패턴 조사 | Sonnet |
| 의존성 또는 사이드이펙트 | 변경의 영향 범위, 의존 관계 분석 | Sonnet |
| 기술 자문 (Step 3.5) | 옵션별 anchoring-neutral 평가. 상세 schema의 단일 SSOT는 [`consulting-step.md`](./consulting-step.md) 다 (`technical_matrix` + `user_facing` 두 layer + disqualifiers + evidence_gaps) | codex exec high reasoning |

LLM이 작업의 복잡도와 도메인에 따라 에이전트 수 (2-6개) 와 역할을 동적으로 결정한다.

DA 또는 review 에이전트는 run-da의 SSOT contract의 프로파일을 따른다 (reviewer는 standard, Arbiter는 strong). Review Intensity는 fan-out이 아니라 메인 LLM 인라인 체크리스트다.

## 런타임 분기

fan-out / fan-in runtime route의 단일 SSOT는 [run-da의 `runtime-mapping.md`](../../run-da/references/runtime-mapping.md#런타임-도구-매핑) 다.

Direct Codex 세션에서 `$plan-with-questions` 호출이 내부 native subagent fan-out explicit delegation으로 취급되는 권한 계약의 단일 SSOT는 [run-da `hardening-contract.md` 의 `Skill-internal fan-out authorization` 절](../../run-da/references/hardening-contract.md#skill-internal-fan-out-authorization) 이다.

`codex-fan-out` 은 Claude Code 또는 headless 세션에서 쓰는 `codex exec` mechanics만 담당한다. Direct Codex 세션의 native subagent fan-out을 소유하지 않는다.

세션별 처리:

- Claude Code 세션: codex exec 기본. 사전점검의 단일 SSOT는 [`/codex-fan-out` SSOT](../../codex-fan-out/SKILL.md) 의 "사전점검" 섹션이다 (`codex` 와 `codex-exec-supervised` 가용성 + `codex-exec-supervised --check` capability probe). 사전점검 실패 시 Agent tool fallback (`run_in_background: true`).
- headless 세션: codex exec only.
- Codex 세션 (reference fan-out): native subagent fan-out. 권한 범위와 `codex-exec-supervised` fallback 승인 경계는 run-da의 hardening contract를 따른다.
- Codex 세션 (Step 3.5 external consult exception): Step 3.5 외부 자문은 native delegation-denied fallback이 아니다. [`consulting-step-shell.md`](./consulting-step-shell.md) 의 `codex-exec-supervised -C` scratch consult route가 기본 경로다. `--ignore-user-config`, `--ignore-rules`, `--sandbox read-only`, `--ephemeral` trust boundary를 유지한다.

codex exec 실행 시 각 에이전트 프롬프트에 "파일을 수정하지 마라" no-write boundary를 명시한다.

Codex 세션 fan-out delegation 거부 처리: Codex 세션에서 `spawn_agent` 가 정책상 거부되면 단일 SSOT 인 [run-da의 `hardening-contract.md` "Delegation fallback (정책 요약)" 절](../../run-da/references/hardening-contract.md#delegation-fallback-정책-요약) 을 그대로 적용한다. BLOCKED + 사용자 승인 대기 → 승인 시 codex exec subprocess fallback (no-write boundary 동일). 명칭과 정책은 run-da의 SSOT를 따르며 본문에 별도 신설하지 않는다.

## fan-in 통합 전략

worker 산출물 lifecycle 처리(머지 vs 보존 + cleanup): Claude Code/headless의 `codex exec` 경로에서 `$FO_DIR/agent-N-result.md` 파일 처리는 [`/codex-fan-out` SKILL.md의 fan-in 표준 절차](../../codex-fan-out/SKILL.md#fan-in-표준-절차)를 따른다(머지 분기 default). Direct Codex native subagent 결과는 위 [런타임 분기](#런타임-분기)의 hardening contract 경로를 따른다.

아래 5 카테고리는 `plan-with-questions` 호출자가 런타임과 무관하게 적용하는 자체 통합 전략이다(`codex exec` 머지 분기든 Direct Codex 경로든 동일 적용 — `codex-fan-out`의 fan-in 표준 절차는 lifecycle 처리에만 한정되고 카테고리 분류를 대체하지 않는다).

에이전트 결과를 카테고리별로 분류하여 통합한다:

1. 코드 패턴: 코드베이스에서 발견한 관련 패턴, 기존 구현.
2. 관련 이슈 또는 PR: 중복, 선행 작업, 참고 이슈.
3. 외부 레퍼런스: 웹 리서치 결과, 문서, 패턴.
4. 사이드이펙트: 변경이 다른 모듈 또는 기능에 미치는 영향.
5. 기술 자문 매트릭스 (Step 3.5): 옵션별 `technical_matrix` (메인 LLM 내부) + `user_facing` (사용자 노출 비유 layer) + disqualifiers + evidence_gaps. 상세 schema의 단일 SSOT는 [`consulting-step.md`](./consulting-step.md) 다.

중복을 제거하고, 모순이 있으면 명시하여 스무고개 질문에 포함한다.
