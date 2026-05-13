# Runtime Boundaries

plan-with-questions의 런타임 지원, 용어, 도구 매핑, 미지원 대응의 단일 SSOT 다.

## 지원 런타임

| 런타임 | 지원 여부 |
|--------|----------|
| Claude Code 세션 | 완전 지원 |
| Codex 세션 | 지원 (페이로드 가이드는 아래 섹션 참조) |
| headless 세션 (CI, `claude -p`, `codex exec`) | BLOCKED (아래 "질문 도구 미지원 대응" 섹션 참조) |

codex 환경 가정과 활성화 절차의 단일 SSOT는 [`.claude/skills/configuring-codex/SKILL.md`](../../../.claude/skills/configuring-codex/SKILL.md) 다.

### Codex 일반 셸 sandbox 한계 (Step 3.5 관련)

`Step 3.5` 의 `codex exec --sandbox read-only` 는 모델 shell의 파일시스템 write만 차단한다. 다음은 차단하지 않는다:

- `~/.config`, `~/.ssh`, `~/.codex`, `/run/agenix` (NixOS) 등 secret 경로의 read.
- 외부 API 호출 (네트워크 차단 아님).
- MCP 또는 connector 로딩 — `--ignore-user-config` + `-C scratch` 로 user와 project config 둘 다 차단해야 완결된다. 호출 명령과 trust boundary flag의 단일 SSOT는 [`consulting-step-shell.md`](./consulting-step-shell.md) 다 (schema와 옵션 표시 정책은 [`consulting-step.md`](./consulting-step.md)).

따라서 Step 3.5 입력에 무엇을 보낼지에 대한 보안 책임은 호출자 (메인 에이전트) 에 있다. repo evidence 중에서 sanitized excerpt만 전달하고, 자문 결과는 untrusted output으로 취급해 Step 4 의 schema 검증을 거친다.

### `request_user_input` 페이로드 가이드

`request_user_input` 의 옵션 개수 가이드라인은 schema 또는 server enforcement가 아니라 codex tool description의 LLM convention이다. 출처:

- `codex-rs/tools/src/request_user_input_tool.rs` 의 JSON Schema description 문자열에 "2-3 choices", "questions ... do not exceed 3", "recommended option first" 가이드라인이 박혀 있다 (LLM이 자발적으로 따른다).
- `codex-rs/core/templates/collaboration_mode/plan.md` 는 "2-4 options + recommended default" 를 요구한다. `default.md` 는 별도 옵션 개수 또는 라벨 지침이 없다 (mode 별 prompt template 차이가 있다).
- TUI는 첫 옵션을 기본 선택 (커서) 으로 표시한다.
- JSON schema (`ToolRequestUserInputOption`, `ToolRequestUserInputQuestion`) 와 `normalize_request_user_input_args` 에는 array-level `maxItems` 또는 `recommended` property가 없다.

본 스킬의 운영 정책:

- 라운드당 하나의 질문: `request_user_input` 또는 `AskUserQuestion` 호출 시 `questions` 배열 길이는 1 로 고정한다. for_action과 for_issue와 for_prd 모두 동일 정책이며 별도 자동 축소 로직이 필요 없다. tool description의 "2-3 choices" 가이드는 한 question 내 options 개수에 적용되며, 본 정책의 questions 배열 길이와는 별개 차원이다.

옵션 순서와 라벨 표시는 본 스킬에서 명시적 정책을 두지 않으며, 도구 default 와 메인 LLM 의 평이한 한국어 표현에 맡긴다. 옵션의 트레이드오프 명료성은 자문 출력의 `user_facing.plain_disqualifier` 표시 (옵션 표시 정책) 로 확보한다.

### for_action과 for_issue와 for_prd의 라운드 정책 통일

세 모드 모두 라운드당 `questions` 배열 길이 1 을 강제한다. modes/*.md의 정책 (for_action의 Step 4, for_issue의 Step I-4, for_prd의 차용 단계) 이 SSOT 다. 본 reference는 그 정책을 런타임 도구 호출 차원에서 명시할 뿐이다. 라운드 수가 늘어나는 trade-off는 명시적으로 수용된다 (사용자 인지 부하와 turn_abort 위험 감소가 우선이다).

### 자동 run-da preflight gate의 질문 도구

[`run-da-preflight-gate.md`](./run-da-preflight-gate.md) 의 SKIP 승인 질문은 plan-with-questions의 인터뷰 질문이 아니라 `run-da` 의 Review Intensity 절차의 일부다. 따라서 질문 도구 미지원 시 본 문서의 BLOCKED 정책을 적용하지 않고, 단일 SSOT 인 [`run-da` 의 질문 도구 미지원 대응](../../run-da/references/arbiter-scaling.md#질문-도구-미지원-대응) 을 적용한다. 현재 정책상 SKIP verdict는 질문 도구 승인 없이 완료되지 않으며 자동 LITE 승격으로 처리된다.

## 용어 정책

이 스킬은 Claude Code 세션과 Codex 세션 양쪽에서 호출된다. 본문은 도구-중립 용어 를 쓴다. 런타임별 실제 도구 binding의 단일 SSOT는 [run-da의 "런타임 도구 매핑" 표](../../run-da/references/runtime-mapping.md#런타임-도구-매핑) 다 (중복 복제 금지).

Direct Codex 세션에서 `$plan-with-questions` 호출이 내부 native subagent fan-out explicit delegation으로 취급되는 권한 계약과, `codex-exec-supervised` fallback 승인 경계의 단일 SSOT는 [run-da `hardening-contract.md` 의 `Skill-internal fan-out authorization` 절](../../run-da/references/hardening-contract.md#skill-internal-fan-out-authorization) 이다. 본 문서는 plan-with-questions 고유의 질문 / 승인 / plan 파일 lifecycle만 정의한다.

| 용어 유형 | 처리 |
|----------|------|
| 사용자 질문 실행 지시 | "질문 도구" |
| 사용자 승인 요청 지시 | "승인 요청 도구" (런타임별 실제 도구는 아래 "런타임 도구 매핑" 표의 "계획 승인 요청" 행 참조) |
| 파일 읽기 / 검색 지시 | "파일 읽기 도구" (또는 명시적 셸 명령 `rg -n` / `sed -n` / `find`) |
| 파일 편집 지시 | "파일 편집 도구" |

"승인 요청 도구" 는 plan-with-questions 국소 용어 다 (run-da의 SSOT에 미정의. sibling 자동 전파 대상이 아니다).

## 런타임 도구 매핑 (plan-with-questions 고유)

이 표는 plan-with-questions 고유 행만 정의한다. 사용자 질문, fan-out, 파일 읽기와 편집의 단일 SSOT는 [run-da 런타임 도구 매핑 표](../../run-da/references/runtime-mapping.md#런타임-도구-매핑) 다 (중복 복제 금지).

미지원 런타임 처리: headless 세션은 본 표의 어떤 행에도 도달하지 않는다 (Step 4 / Step I-4에서 질문 도구 호출 시점에 BLOCKED). 상세 SSOT는 위 "지원 런타임" 표와 아래 "질문 도구 미지원 대응" 섹션이다.

| 행동 | Claude Code 세션 | Codex 세션 |
|------|------------------|------------|
| Step 4.5 공식 plan 파일 초기화 (for_action) | 파일 편집 도구로 안전 검증된 `.claude/plans/<slug>.md` 를 생성 (계획 추적 상태 진입 전) | `apply_patch` 로 안전 검증된 `.claude/plans/<slug>.md` 를 생성 (chat state 추적 전) |
| 계획 추적 상태 진입 | `EnterPlanMode` 로 승인 / tracking 상태 진입 | `update_plan` (단계별 chat state 추적, 파일 IO 없음) |
| 계획 파일 review / refine | `Write` 또는 `Edit` 로 Step 4.5 의 기존 SSOT plan 파일을 편집 | `apply_patch` 로 Step 4.5 의 기존 `.claude/plans/<slug>.md` 만 편집 |
| 계획 승인 요청 | `ExitPlanMode` 로 계획 파일 제시 및 승인 대기 | 계획 파일 경로 / 요약을 `request_user_input` 으로 제시하고 confirm 대기 |

위 표의 "계획 추적 상태 진입" 행 보충 — Step 4.5 의 기존 경로가 SSOT plan이다. 런타임이 별도 transient buffer 또는 path를 노출해도 새 SSOT plan으로 승격하지 않는다. 추적 대상은 Step 4.5 의 기존 plan 파일이다.

위 표의 "계획 파일 review / refine" 행 보충 — transient buffer 또는 path가 있으면 승인 전 SSOT 파일에 최종 내용을 반영한다.

본문의 "계획 추적 도구", "파일 편집 도구", "승인 요청 도구" 는 위 표의 런타임별 실제 도구를 가리킨다. 최종 산출물은 모드별로 다르다:

- for_action 모드: `.claude/plans/<slug>.md` 계획 파일.
- for_prd 모드: `.claude/prds/prd-<feature>.md` (split mode 면 `.claude/prds/prd-<feature>/phase-NN-<name>.md` 도 함께). for_prd 모드가 PRD 규약 ([`prd/prd-master-template.md`](./prd/prd-master-template.md) + [`prd/phase-template.md`](./prd/phase-template.md)) 을 따라 직접 작성한다. 별도 plan 사본은 만들지 않는다.
- for_issue 모드: 산출물이 등록된 이슈. 계획 파일은 없다.

`for_prd` 는 위 표의 Step 4.5 plan 파일 초기화 행을 사용하지 않는다. PRD mode의 승인 / 작성 lifecycle의 단일 SSOT는 [`../modes/for_prd.md`](../modes/for_prd.md) 이며 `.claude/prds/` 만 산출물로 사용한다.

## 질문 도구 미지원 대응

이 섹션은 Step 4, Step I-4, Step 7 에서 참조되는 BLOCKED 처리 정책의 단일 SSOT 다.

현재 런타임에서 질문 도구를 호출할 수 없으면 (headless 세션 등 stdin 입력 불가 환경) plan-with-questions는 BLOCKED 처리한다. 인터뷰 기반 스킬의 본질상 사용자 입력 없는 자동 진행이 불가능하므로 자동 전이를 채택하지 않는다.

처리 절차:

1. 현재 단계 (Step 4 / Step I-4 / Step 7 등) 와 차단 사유 (질문 도구 미지원) 를 plain-text로 보고한다. 보고 채널이 없는 headless에서는 silent exit 한다.
2. 스킬 절차를 종료한다.
3. 사용자가 새 메시지에서 명시 재개 ("계속 진행" 등) 하거나 질문 도구 지원 런타임으로 전환할 때까지 자동 재개하지 않는다.

지원 런타임 전환 방법: Claude Code 세션 또는 Codex 세션을 사용한다.

이 정책은 [run-da의 "질문 도구 미지원 대응"](../../run-da/references/arbiter-scaling.md#질문-도구-미지원-대응) 섹션과 결을 같이 한다. 다만 plan-with-questions 인터뷰 컨텍스트 전용으로 적용 규칙이 다르다 (자동 승격, LITE 승격, 5라운드 종료 같은 DA 흐름 규칙은 적용하지 않는다).
