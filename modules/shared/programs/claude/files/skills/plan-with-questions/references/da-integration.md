# External Review Integration (Step 5 호출 + Step 6 결과 반영)

`for_action` 모드의 Step 5 와 Step 6 에서 사용하는 `/run-da for_plan` 호출 계약과 결과 반영 상태표다. `for_prd` 는 같은 DA 호출을 쓰되 plan 파일 대신 PRD draft 또는 context를 입력과 반영 대상으로 사용한다.

## Step 5: 외부 검토 plan-mode 실행 [일반 모드]

`for_action` 모드에서 모든 사용자 질문이 해소되고 Step 4.5 의 공식 plan 파일이 초기화되면, 계획 추적 도구 진입 전에 [`run-da-preflight-gate.md`](./run-da-preflight-gate.md) 를 적용한다. 그 결과가 승인된 SKIP이 아니면 `/run-da for_plan` 을 실행한다.

### preflight gate

`for_action` 모드에서 DA 생략 여부를 자유 판단하지 않는다. [`run-da-preflight-gate.md`](./run-da-preflight-gate.md) 가 정의한 자동 호출 전 gate에서 `run-da` Review Intensity 체크리스트를 적용한다. SKIP verdict는 질문 도구 승인 없이는 완료 상태가 아니다.

### 런타임 분기는 run-da를 따른다

3-way 분기:

- Codex 세션: native subagent.
- Claude Code 세션: codex exec (사전점검 후 불가 시 Agent tool fallback).
- headless 세션: codex exec.

### 기본 경로는 lean default

`/run-da for_plan` 의 자동 FULL은 4 reviewer bundle 기본 리뷰다. 8개 세부 도메인 exhaustive path는 명시적 `full` modifier가 있을 때만 쓴다.

### YAGNI 경계

변경이 "단순" 해 보인다는 자유 추론은 SKIP 근거가 아니다. preflight gate가 `run-da` SSOT 체크리스트로 SKIP을 판정하고 사용자가 승인한 경우에만 `/run-da for_plan` 호출을 완료 상태로 대체한다.

### 책임 분리

Review Intensity 판단 (SKIP / LITE / FULL) 은 `run-da` SSOT가 정한다. plan-with-questions는 preflight gate의 호출자이며, 룰 표를 복제하거나 변형하지 않는다.

### thread cap 준수

Codex 세션에서는 current session의 open-thread cap (`agents.max_threads`, unset 기본 6) 을 넘기지 않는다. completed reviewer 또는 Arbiter thread를 다음 round / retry 전에 `close_agent` 로 닫아야 한다.

### Codex 세션 hardening 계약 준수

`/run-da for_plan` 의 reviewer는 standard review profile, Arbiter는 strong review profile을 따른다. Review Intensity는 메인 LLM 인라인 체크리스트라 별도 review profile이 적용되지 않는다. `wait_agent` timeout 만으로 중간 kill 또는 self-auditing 대체를 하지 않는다. reviewer의 PoC는 repo 밖 scratch에 한정한다.

### main-agent-only 유지

single-writer / main-agent-only boundary는 `run-da` 의 SSOT contract를 그대로 따른다. tracked write, branch mutation, commit / push, GitHub write, `wt` / `nrs` / rebuild 계열은 for_plan subagent가 직접 실행하지 않는다. 상세 용어와 violation 처리 규칙의 단일 SSOT는 [`../../run-da/references/hardening-contract.md`](../../run-da/references/hardening-contract.md) 의 "Codex 세션 하드닝 계약" 절이다.

### 타이밍

반드시 계획 추적 도구 진입 전에 본 단계 (preflight gate 또는 `/run-da for_plan`) 를 완료한다.

### for_action 입력 계약

Step 4.5 에서 만든 공식 `.claude/plans/<slug>.md` 경로와 파일 내용을 DA 입력 context에 포함한다. `/run-da for_plan` 뒤에 path argument 나 modifier를 추가하지 않는다.

### for_action fail-closed precondition

Step 4.5 의 plan 파일이 없거나 SSOT path가 `.claude/plans/` 밖이면 `/run-da for_plan` 을 호출하지 않고 BLOCKED 처리한다. slug 재생성 또는 파일 초기화를 먼저 완료한다.

### for_action의 DA State 전이

`/run-da for_plan` 실행 직전과 직후의 plan 파일 상태 전이:

- 실행 직전: 같은 plan 파일의 `DA State` 를 `RUNNING` 으로 바꾼다. `Change Log` 에는 외부 검토가 시작됐다는 자연어 상태만 기록한다. 개별 run의 상관관계 값은 live session memory 또는 scratch 에만 두고 durable markdown에는 쓰지 않는다.
- verdict 수신 직후 (Step 6 반영 전): `DA State=APPLYING`, `Resume From=for_action.step6_da_apply` 로 갱신한다. durable verdict summary 또는 stable artifact name을 `Change Log` 에 기록한다.
- Step 6 반영 조건: 같은 active session에서 runtime-only 상관관계가 현재 verdict 임을 확인할 수 있을 때만 반영한다.
- 세션 재개 후 상관관계 확인 불가: 세션이 재개됐는데 상관관계를 확인할 수 없거나 verdict 기록이 불충분하면 같은 plan 파일을 입력으로 외부 검토를 재실행한다. 늦게 도착한 이전 verdict는 stale result 로만 기록하고 적용하지 않는다.
- 승인된 SKIP: preflight gate에서 사용자 승인 SKIP이 완료되면 다음을 기록한다:
  - `DA State=SKIPPED`
  - `Resume From=for_action.step7_plan_mode_entry`
  - `Last Completed Step=for_action.step6_da_apply`

### for_prd 예외

`for_prd` 는 for_action의 Step 4.5 (plan 파일 초기화) 를 skip 한다. 따라서 `.claude/plans/` precondition을 적용하지 않는다. P6의 preflight 또는 DA 입력은 PRD draft 또는 context, candidate phase structure, P1-P5 evidence 다.

## Durable wording guardrails

Durable plan / PRD / PR / issue / comment 텍스트는 guard pattern 정의를 중복하지 않는다. pattern의 단일 SSOT는 [`pinning-patterns.sh`](../../../lib/pinning-patterns.sh) 다. 본 파일의 예시는 illustrative이며 해당 helper로 validation 해야 한다.

plan의 `Change Log` 항목에 사용할 guard-safe 예시:

- `외부 검토 plan-mode 시작`
- `외부 검토 결과 반영: verdict summary recorded`
- `이전 외부 검토 결과 도착: stale result ignored`

## Step 6: DA 결과 반영 [일반 모드]

외부 검토 plan-mode의 Arbiter 판정 결과와 selective consistency 집계 (해당 시) 를 함께 처리한다. 상세 상태 전이의 단일 SSOT는 [`../../run-da/references/protocol.md`](../../run-da/references/protocol.md) 의 "DA → Arbiter → Main Agent 상태 흐름" 과 "Selective consistency 상태 전이" 절이다.

### verdict × stability_status 행동 표

| verdict × stability_status | 메인 에이전트 행동 |
|----------------------------|-------------------|
| CONFIRMED_ISSUE (stability=`N/A` 또는 `stable`, `low_confidence_warning=false`) | 현재 모드의 계획 artifact에 자동 반영 |
| NOT_AN_ISSUE (stability=`N/A` 또는 `stable`, `low_confidence_warning=false`) | 반영 불필요 (Arbiter 판정 신뢰) |
| NEEDS_MORE_INFO (stability=`N/A` 또는 `stable`) | 질문 도구로 사용자 판단 요청 |
| 임의 verdict + `stability_status=stable` + `low_confidence_warning=true` | fail-closed 승격: 질문 도구로 사용자 판단 요청 |
| majority verdict + `stability_status=split` | 질문 도구로 사용자 판단 요청 (vote-shape 2:1 과 minority verdict 함께 제시) |
| `stability_status=fragmented` 또는 partial_failure | BLOCKED |

`stability_status=fragmented` 또는 partial_failure의 BLOCKED 세부 처리:

- 질문 도구 지원 시 — 사용자 판단 요청 (비유법 포함).
- 질문 도구 미지원 시 — 자동 승격 금지하고 중단 보고.

`임의 verdict + low_confidence_warning=true` 의 의미: unanimous 여도 low-confidence 이력이 있으면 사용자 판단을 요청한다.

### DA 결과 반영 target

- for_action 모드: Step 4.5 에서 만든 같은 plan 파일을 편집한다. 중요 변경, confirmed rejection, BLOCKED / NEEDS_USER 전이는 `Decision Log` 에 ADR 미니 형식으로 기록한다. 상세 형식의 단일 SSOT는 [`plan-file-template.md`](./plan-file-template.md) 의 Decision Log 섹션이다. 반영 완료 후 `DA State` 를 `CONFIRMED` / `SKIPPED` / `BLOCKED` / `NEEDS_USER` 중 하나로 기록한다.
- for_prd 모드: PRD draft 또는 context와 candidate phase structure에 DA 결과를 반영한다. PRD 파일 작성 후에는 PRD master의 `Change Log` 에 반영 이력을 남긴다. split mode에서 특정 phase가 영향받는 경우 해당 phase의 `Discoveries / Decisions` 에도 남긴다. `.claude/plans/` 파일을 만들지 않는다.
- for_prd의 P6 / P7 resume: PRD 파일 작성 전 세션이 끊기면 durable DA artifact가 없다. 따라서 `for_prd.p6_da` 부터 재실행하고, 이전 transient verdict는 적용하지 않는다.
