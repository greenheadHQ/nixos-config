# Runtime Boundaries

plan-with-questions의 런타임 지원·용어·도구 매핑·미지원 대응 SSOT.

## 지원 런타임

| 런타임 | 지원 여부 |
|--------|----------|
| Claude Code 세션 | 완전 지원 |
| Codex 세션 | **지원** (페이로드 가이드는 아래 섹션 참조) |
| headless 세션 (CI · `claude -p` · `codex exec`) | BLOCKED ("질문 도구 미지원 대응" 섹션) |

codex 환경 가정·활성화 절차는 [`.claude/skills/configuring-codex/SKILL.md`](../../../.claude/skills/configuring-codex/SKILL.md)가 SSOT다.

### Codex 일반 셸 sandbox 한계 (Step 3.5 관련)

`Step 3.5`의 `codex exec --sandbox read-only`는 **모델 shell의 파일시스템 write만** 차단한다. 다음은 차단하지 않는다:
- `~/.config`, `~/.ssh`, `~/.codex`, `/run/agenix`(NixOS) 등 secret 경로 read.
- 외부 API 호출 (네트워크 차단 아님).
- MCP/connector 로딩 — `--ignore-user-config` + `-C scratch`로 user/project config 둘 다 차단해야 완결된다 (`consulting-step.md` SSOT).

따라서 Step 3.5 입력에 무엇을 보낼지에 대한 보안 책임은 호출자(메인 에이전트)에 있다 — repo evidence 중에서 sanitized excerpt만 전달하고, 자문 결과는 untrusted output으로 취급해 Step 4 anti-anchoring schema 검증을 거친다.

### `request_user_input` 페이로드 가이드

`request_user_input`의 옵션 개수/Recommended 라벨은 **schema/server enforcement가 아니라 codex tool description의 LLM convention**이다. 출처:

- `codex-rs/tools/src/request_user_input_tool.rs`의 JSON Schema description 문자열에 "2-3 choices", "questions ... do not exceed 3", "recommended option first" 가이드라인이 박혀 있다 (LLM이 자발적으로 따름).
- `codex-rs/core/templates/collaboration_mode/plan.md`는 "**2-4 options + recommended default**"를 요구. `default.md`는 별도 옵션 개수/라벨 지침 없음 — mode별 prompt template 차이 있음.
- TUI는 첫 옵션을 기본 선택 (커서) 표시하지만 자동 "(Recommended)" 라벨 부여 안 함.
- JSON schema (`ToolRequestUserInputOption`/`ToolRequestUserInputQuestion`)와 `normalize_request_user_input_args`에는 array-level `maxItems`나 `recommended` property가 없다 (PR #617 fact-check 결과).

본 SKILL의 운영 정책:

1. **라운드당 1개 질문 강제 (D1, FR-1)** — `request_user_input`/`AskUserQuestion` 호출 시 `questions` 배열 길이는 1로 고정한다. for_action·for_issue·for_prd 모두 동일 정책이며 별도 자동 축소 로직이 필요 없다 (이전 정책 "for_issue 라운드당 최대 4개를 3개로 자동 축소", "for_action 한번에 모아서"는 모두 폐기). tool description의 "2-3 choices" 가이드는 한 question 내 options 개수에 적용되며, 본 정책의 questions 배열 길이 1과는 별개 차원이다.
2. **Step 3.5 추천 라벨 — D4 합의 알고리즘 호출 (D4, FR-5)** — tool description은 "recommended option first"를 권고하지만 본 SKILL은 [`./consulting-step.md`](./consulting-step.md)의 D4 합의 알고리즘 4단계(schema 한계 내 보수적 합의 정의)를 적용해 후보가 정확히 1개로 좁혀진 합의 PASS 옵션에만 `(Recommended)` 라벨을 부착한다. 합의 미달 옵션에는 어떤 fallback에서도 라벨을 부착하지 않으며, 옵션 dict에서 라벨 문자열이 발견되면 강제 제거한다 (D4 hard rule). 옵션 순서는 `decision_id` 기반 stable shuffle로 결정한다 (anti-anchoring 2번 규칙 보존). 본 정책은 codex/AskUserQuestion tool description LLM convention에 대한 로컬 정책 override다.

### for_action·for_issue 라운드 정책 통일 (D1)

세 모드 모두 라운드당 `questions` 배열 길이 1을 강제한다. modes/*.md(for_action Step 4 / for_issue Step I-4 / for_prd 차용)가 SSOT이며 본 reference는 그 정책을 런타임 도구 호출 차원에서 명시한다. 라운드 수가 늘어나는 trade-off는 D1으로 명시 수용된다 (사용자 인지 부하/turn_abort 회귀 방지가 우선).

PR openai/codex#12735는 collaboration mode 가용성만 확장하고 tool spec/schema는 미변경이므로, 위 가이드는 collaboration mode와 무관하게 schema 차원에서 일관 — 단 prompt template 차원에서는 mode별 차이가 있다 (위 plan.md/default.md 차이).

### 자동 run-da preflight gate의 질문 도구

[`run-da-preflight-gate.md`](./run-da-preflight-gate.md)의 SKIP 승인 질문은 plan-with-questions 인터뷰 질문이 아니라 `run-da` Review Intensity 절차의 일부다. 따라서 질문 도구 미지원 시 이 문서의 BLOCKED 정책을 적용하지 않고, [`run-da`의 질문 도구 미지원 대응](../../run-da/references/arbiter-scaling.md#질문-도구-미지원-대응)을 적용한다. 현재 정책상 SKIP verdict는 질문 도구 승인 없이 완료되지 않으며 자동 LITE 승격으로 처리된다.

## 용어 정책

이 스킬은 Claude Code 세션과 Codex 세션 양쪽에서 호출된다. 본문은 **도구-중립 용어**를 쓰며, 런타임별 실제 도구 binding은 [run-da의 "런타임 도구 매핑" 표](../../run-da/references/runtime-mapping.md#런타임-도구-매핑)를 단일 진실 원천으로 참조한다 (중복 복제 금지).

Direct Codex 세션에서 `$plan-with-questions` 호출이 내부 native subagent fan-out explicit delegation으로 취급되는 권한 계약과 `codex-exec-supervised` fallback 승인 경계는 [run-da `hardening-contract.md`의 `Skill-internal fan-out authorization`](../../run-da/references/hardening-contract.md#skill-internal-fan-out-authorization)이 정본이다. 본 문서는 plan-with-questions 고유 질문/승인/plan 파일 lifecycle만 정의한다.

| 용어 유형 | 처리 |
|----------|------|
| 사용자 질문 실행 지시 | "질문 도구" |
| 사용자 승인 요청 지시 | "승인 요청 도구" (런타임별 실제 도구는 아래 "런타임 도구 매핑" 표의 "계획 승인 요청" 행 참조) — **plan-with-questions 국소 용어** (run-da SSOT 미정의; sibling 자동 전파 대상 아님) |
| 파일 읽기/검색 지시 | "파일 읽기 도구" (또는 명시적 셸 명령 `rg -n` / `sed -n` / `find`) |
| 파일 편집 지시 | "파일 편집 도구" |

## 런타임 도구 매핑 (plan-with-questions 고유)

이 표는 plan-with-questions 고유 행만 정의한다. 사용자 질문/fan-out/파일 읽기·편집은 [run-da 런타임 도구 매핑 표](../../run-da/references/runtime-mapping.md#런타임-도구-매핑)를 단일 진실 원천으로 참조한다 (중복 복제 금지).

**미지원 런타임 처리**: headless 세션은 본 표의 어떤 행에도 도달하지 않는다 (Step 4/Step I-4에서 질문 도구 호출 시점에 BLOCKED). 상세는 위 "지원 런타임" 표와 "질문 도구 미지원 대응" 섹션이 단일 소스다.

| 행동 | Claude Code 세션 | Codex 세션 |
|------|------------------|--------------------------------|
| for_action Step 4.5 공식 plan 파일 초기화 | 파일 편집 도구로 안전 검증된 `.claude/plans/<slug>.md`를 생성 (계획 추적 상태 진입 전) | `apply_patch`로 안전 검증된 `.claude/plans/<slug>.md`를 생성 (chat state 추적 전) |
| 계획 추적 상태 진입 | `EnterPlanMode`로 승인/tracking 상태 진입. canonical plan 파일은 Step 4.5의 기존 경로이며, 런타임이 별도 transient buffer/path를 노출해도 새 canonical plan으로 승격하지 않는다 | `update_plan` (단계별 chat state 추적; 파일 IO 없음). 추적 대상은 Step 4.5의 기존 plan 파일 |
| 계획 파일 review/refine | `Write`/`Edit`로 Step 4.5의 기존 canonical plan 파일을 편집. transient buffer/path가 있으면 승인 전 canonical 파일에 최종 내용을 반영 | `apply_patch`로 Step 4.5의 기존 `.claude/plans/<slug>.md`만 편집 |
| 계획 승인 요청 | `ExitPlanMode`로 계획 파일 제시 및 승인 대기 | 계획 파일 경로/요약을 `request_user_input`으로 제시하고 confirm 대기 |

본문의 "계획 추적 도구", "파일 편집 도구", "승인 요청 도구"는 위 표의 런타임별 실제 도구를 가리킨다. 최종 산출물은 모드별로 다르다:

- **for_action**: `.claude/plans/<slug>.md` 계획 파일.
- **for_prd**: `.claude/prds/prd-<feature>.md` (split mode면 + `.claude/prds/prd-<feature>/phase-NN-<name>.md`) — for_prd 모드가 PRD 규약([`./prd/prd-master-template.md`](./prd/prd-master-template.md) + [`./prd/phase-template.md`](./prd/phase-template.md))을 따라 직접 작성한다. 별도 plan 사본은 만들지 않는다.
- **for_issue**: 산출물이 등록된 이슈. 계획 파일 없음.

`for_prd`는 위 표의 Step 4.5 plan 파일 초기화 행을 사용하지 않는다. PRD mode의 승인·작성 lifecycle은 [`../modes/for_prd.md`](../modes/for_prd.md)가 정의하며 `.claude/prds/`만 산출물로 사용한다.

## 질문 도구 미지원 대응

이 섹션은 Step 4 / Step I-4 / Step 7에서 참조되는 BLOCKED 처리 정책의 단일 소스다.

현재 런타임에서 질문 도구를 호출할 수 없으면 (headless 세션 등 stdin 입력 불가 환경), plan-with-questions는 **BLOCKED 처리**한다. 인터뷰 기반 SKILL의 본질상 사용자 입력 없는 자동 진행이 불가능하므로 자동 전이를 채택하지 않는다.

처리 절차:
1. 현재 단계(Step 4 / Step I-4 / Step 7 등)와 차단 사유(질문 도구 미지원)를 plain-text로 보고한다 (보고 채널이 없는 headless에서는 silent exit한다).
2. SKILL 절차를 종료한다.
3. 사용자가 새 메시지에서 명시 재개("계속 진행" 등)하거나 질문 도구 지원 런타임으로 전환할 때까지 자동 재개하지 않는다. **지원 런타임 전환 방법**: Claude Code 세션 또는 Codex 세션 사용.

이 정책은 [run-da의 "질문 도구 미지원 대응"](../../run-da/references/arbiter-scaling.md#질문-도구-미지원-대응) 섹션과 결을 같이 하지만, plan-with-questions 인터뷰 컨텍스트 전용으로 적용 규칙이 다르다 (자동 승격/LITE 승격/5라운드 종료 같은 DA 흐름 규칙은 적용하지 않는다).
