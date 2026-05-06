# Mode: for_action

`$ARGUMENTS`에 이슈 레퍼런스가 있으면 이 모드로 진행한다. 이슈를 resolve하여 내용을 가져오고, 계획 수립까지 진행한다.

## 주의: 즉시 계획 추적 도구 진입 금지

**이 스킬을 호출했다고 해서 즉시 계획 추적 도구로 진입하지 않는다.** 반드시 Step 1-4 분석/질문을 일반 모드에서 완료하고, Step 4.5에서 공식 plan 파일을 초기화한 뒤, Step 5-6 DA를 거쳐 Step 7에서 계획 추적 도구로 진입한다. 일반 모드에서 빌드/명령 실행/로컬 재현으로 계획 가정을 검증해야 hallucination이 억제된다.

- **Claude Code 세션**: 계획 추적 도구 진입 시점부터 write 작업이 제한되므로 검증은 반드시 진입 전에 완료돼야 한다.
- **Codex 세션**: chat state 추적은 write 제한을 강제하지 않지만, Step 7 이후는 "검증 단계 종료 + 계획 파일 review/refine 단계"로 규약되므로 동일하게 Step 1-4 탐색/질문과 Step 5-6 DA 검증을 완료한다.

미지원 런타임(headless)은 Step 4에서 이미 BLOCKED 처리되어 이 단계에 도달하지 않는다 ([`../references/runtime-boundaries.md`](../references/runtime-boundaries.md#질문-도구-미지원-대응)).

## Step 1: 이슈 유효성 판단 [일반 모드]

계획 수립에 앞서, 대상 이슈/작업이 실제로 수행할 가치가 있는지 먼저 판단한다.

이슈 레퍼런스를 resolve하여 내용을 가져온다. 특정 이슈 트래커 CLI에 의존하지 않고, 환경에서 사용 가능한 도구(gh CLI, Linear API/MCP, 웹 검색 등)를 활용한다.

- **이미 해결되었는가?** — 관련 코드, 최근 커밋, closed PR을 탐색하여 이미 해결된 문제가 아닌지 확인한다.
- **YAGNI인가?** — 현재 시점에서 실제로 필요한 변경인지 판단한다. "나중에 필요할 수도 있으니까"는 충분한 근거가 아니다.
- **NGMI인가?** — 현재 아키텍처/기술 제약 상 실현 불가능한 요구인지 확인한다.

유효하지 않다고 판단되면 사용자에게 근거를 제시하고, 계획을 중단할지 여부를 확인한다. 사용자가 그래도 진행하겠다고 하면 계속한다.

**Scope 분해 판단**: 요청이 독립적인 서브시스템(서비스/플랫폼/독립 모듈 단위) 2개 이상을 포함하는 경우, 계획 파일 내 별도 Phase/섹션으로 구분하여 다룬다. 출력은 여전히 단일 계획 파일이며, 별도의 plan-with-questions 사이클로 분리하지 않는다. 분해 여부가 불분명하면 Step 2 코드베이스 탐색 후 판단한다.

**자동 PRD 후보 감지**: Step 1-2 진행 중 [`../references/task-size-routing.md`](../references/task-size-routing.md)의 트리거 신호가 감지되면 사용자에게 1회 알림 + opt-out. 상세 흐름은 [`for_prd.md`](./for_prd.md).

## Step 2: 코드베이스 탐색 + 로컬 재현 [일반 모드]

대상 이슈를 정독하고, 관련 코드베이스를 탐색한다.

- 이슈에 언급된 파일, 모듈, 설정을 코드베이스에서 찾아 현재 상태를 파악한다.
- 관련된 기존 구현, 의존성, 설정 패턴을 확인한다.
- 이슈에 링크된 PR, 커밋, 다른 이슈가 있으면 함께 확인한다.

**로컬 검증 의무:**
- 이슈/작업에서 언급된 문제를 로컬에서 직접 재현한다.
- 관련 명령어 실행, 빌드 시도, 설정 확인 등을 수행한다.
- API/플래그/경로의 존재 여부를 grep/which/--help로 확인한다.
- "~일 것이다", "~로 추정된다" 등 추측 기반 분석을 금지한다.
- 코드베이스를 직접 읽어 확인하지 않은 내용은 이후 단계에서 사용하지 않는다.

## Step 3: 질문 수집 [일반 모드]

분석 과정에서 발견한 모든 불명확점을 수집한다. 다음 관점에서 빠짐없이 점검한다:

- **요구사항 불명확점**: 이슈/작업 설명에서 해석이 여러 가지 가능한 부분
- **판단 기준**: 사용자의 선호도나 우선순위가 필요한 결정 사항
- **사이드이펙트**: 변경이 다른 기능/모듈/플랫폼에 미치는 영향
- **트레이드오프/접근법 비교**: 실행 가능한 접근법이 2개 이상이면, 각 접근법의 장단점을 정리한다 (Step 3.5에서 외부 자문으로 보강. 메인 LLM의 추천은 Step 3.5 결과 도착 후 anti-anchoring 규칙에 따라 표시한다).
- **인지 상태 확인**: 사용자가 특정 제약이나 영향을 알고 있는지 여부
- **XY Problem 검증**: 사용자가 실제 문제(X)가 아닌 자신이 시도한 해결책(Y)에 대해 요청하고 있지는 않은지 점검한다. 의심되면 "해결하려는 근본 문제가 무엇인가요?"를 질문한다.

하나도 빠짐없이 전부 수집한다. "이 정도면 됐겠지"는 금지한다.

## Step 3.5: 외부 LLM 기술 자문 [일반 모드, background 병렬]

Step 3 완료 즉시, 사용자 질문 전(Step 4 직전)에 외부 LLM에 anchoring-neutral 옵션 평가를 위임한다. 이 단계는 anchoring 사례 재발 방지가 목적이다.

- **호출 시점**: Step 3 종료 직후 background 병렬. 메인은 Discovery Summary 정리·plan draft 초안 등 다른 준비를 진행한다.
- **결과 도착 시**: Step 4로 진입.
- **budget**: 30분 이내 (high/xhigh 공통). xhigh는 명시적 심층 요청 시에만.
- **호출 명령 SSOT**: [`../references/consulting-step.md`](../references/consulting-step.md#codex-exec-호출-명령-템플릿-ssot) — codex exec 명령은 본 reference만 정본이다 (`-C` scratch cwd + `--ignore-user-config` + `--sandbox read-only` + `--ephemeral`로 trust boundary 완결). 본 파일은 명령을 복제하지 않는다.
- **입출력 schema·anti-anchoring 4 규칙**: [`../references/consulting-step.md`](../references/consulting-step.md). 자문 단계가 미구현 상태이면 메인 LLM은 Step 3 결과를 직접 사용자에게 제시하되 anti-anchoring 4 규칙(D4 합의 조건부 라벨·옵션 셔플·user_facing.plain_disqualifier 명시·judgment-first)은 즉시 적용한다 — 자문 부재로 D4 알고리즘 Step 1이 fail하므로 D4_FALLBACK_A로 격하되어 어떤 옵션에도 라벨이 부착되지 않는다. 사용자 노출 평이 문구는 [`../references/consulting-step.md`](../references/consulting-step.md) "Fallback enum" 표 D4_FALLBACK_A 행 SSOT를 그대로 사용한다.

Step 3.5는 DA(Step 5)와 목적이 다르다. 3.5는 사용자에게 옵션 제시 전 de-anchoring 전처리, 5는 plan 결함의 사후 검토.

## Step 4: 사용자에게 질문 [일반 모드]

**사용자에게 질문할 때는 질문 도구를 사용한다. 이 규칙은 예외 없이 적용된다.** 질문 도구 미지원 시 [`../references/runtime-boundaries.md`](../references/runtime-boundaries.md#질문-도구-미지원-대응)를 따른다.

**라운드당 질문 1개 강제 (D1)**: 수집한 질문(Step 3) + 외부 자문 매트릭스(Step 3.5)를 한 라운드에 모아서 던지지 않는다. 라운드당 `questions` 배열 길이는 1로 고정한다. 사용자가 한 결정에 집중할 수 있게 하고, 메인 LLM이 user_facing layer를 충분히 풀어 설명할 cognitive room을 확보한다 (이전 "한번에 모아서" 정책은 폐기 — turn_abort 회귀 방지). 사용자의 답변에 따라 추가 질문이 생기면 새 라운드(여전히 questions 배열 길이 1)로 이어간다. 모든 불명확점이 해소될 때까지 라운드를 반복한다.

**사용자 노출은 user_facing layer만 (D2)**: Step 3.5 자문 결과를 사용자에게 표시할 때는 [`../references/consulting-step.md`](../references/consulting-step.md)의 `user_facing` layer(label/description/analogy/plain_disqualifier)만 사용한다. `technical_matrix`(7키 평가 매트릭스)와 raw `disqualifiers`는 메인 LLM 내부 D4 합의 알고리즘 입력으로만 사용하며 사용자에게 노출하지 않는다. user_facing이 자문 출력에 누락되면 D2 fallback 4단계로 graceful degrade한다 ([`../references/consulting-step.md`](../references/consulting-step.md)의 "D2 backward-compat fallback 4단계" SSOT).

**트레이드오프 라운드 — D4 합의 알고리즘 호출 (FR-5)**: 트레이드오프 결정마다 사용자 노출 직전에 [`../references/consulting-step.md`](../references/consulting-step.md)의 D4 합의 알고리즘 4단계를 실행한다. 후보가 정확히 1개로 좁혀진 경우에만 그 옵션에 `(Recommended)` 라벨을 부착한다. 어느 단계든 fail 시(D4_FALLBACK_A/B/C/C_MULTI) 라벨을 부착하지 않는다.

**Fallback 사용자 보고 문구 SSOT**: fallback enum 정의(내부 Decision Log 전용)와 사용자 노출 평이 문구는 [`../references/consulting-step.md`](../references/consulting-step.md)의 "Fallback enum (내부 Decision Log 전용, 사용자 노출 금지)" 표가 단일 진실 원천이다. 본 mode 파일은 그 표를 복제하지 않으며, fallback 발생 시 메인 LLM은 그 표의 사용자 노출 문구를 그대로 사용한다. 사용자에게는 enum 라벨(`D4_FALLBACK_*`)을 노출하지 않는다 — 평이 한국어 문구만 표시.

**D2 텍스트 복구 (D4와 별개 축)**: 자문 출력에 `user_facing` layer가 누락(또는 부분 누락)되면 메인 LLM이 D2 fallback 4단계로 텍스트 복구를 시도한다. 사용자 노출 문구와 D2 stage 정의도 [`../references/consulting-step.md`](../references/consulting-step.md) "Fallback enum" 표 SSOT를 인용한다. 본 fallback은 텍스트 출처 표기일 뿐 D4의 `(Recommended)` 라벨 부착 여부와는 다른 축이다.

**judgment-first 라운드 라벨 부착 절대 금지 (FR-4)**: 트레이드오프 옵션 제시 직전 사용자 기준을 묻는 judgment-first 사전 라운드는 D4 합의 알고리즘을 **실행하지 않는다**. 어떤 옵션에도 `(Recommended)` 라벨을 부착하지 않으며, `user_facing.label`만으로 기준을 평이하게 표시한다. 이는 자문 출력의 합의 결과와 무관하게 무조건 적용된다 (anti-anchoring 효과를 source에서 보호하기 위함).

**D4 hard rule (FR-7)**: AskUserQuestion 도구 description의 추천 라벨 자동 권장은 본 스킬 컨텍스트에서 무시한다. 사용자 노출 직전 옵션 dict에서 합의 미달 옵션의 `(Recommended)` 문자열 또는 등가 표시가 발견되면 강제 제거한다. 본 hard rule은 SKILL.md Invariant 8 + [`../references/consulting-step.md`](../references/consulting-step.md)의 D4 hard rule 단락과 동일하며, 본 mode 파일은 그 SSOT를 callsite로 강제한다.

질문 패턴과 anti-anchoring 표시 규칙은 [`../references/output-templates.md`](../references/output-templates.md#step-4--step-i-4-질문-패턴) 참조.

## Step 4.5: 공식 plan 파일 초기화 [일반 모드, for_action 전용]

모든 사용자 질문이 해소되면 Step 5 DA 전에 공식 `.claude/plans/<slug>.md` 파일을 초기화한다. 이 단계는 `for_action` 전용이다. `for_prd`는 이 단계를 건너뛰고 PRD draft/context를 DA 입력으로 사용한다 ([`for_prd.md`](./for_prd.md) 참조).

**slug/path 안전 규칙:**
- slug는 lowercase `[a-z0-9-]+` basename만 허용한다.
- `.`, `..`, slash(`/`), backslash(`\`), 공백, shell/path metacharacter가 포함된 값은 거부하고 안전한 slug를 다시 생성한다.
- 새 파일 자체가 아직 없을 수 있으므로 repo root와 `.claude/plans/` parent directory처럼 이미 존재해야 하는 경로만 canonicalize한다. 그 parent가 repo 안의 `.claude/plans/`와 일치함을 확인한 뒤 basename slug를 join한다.
- 최종 path containment는 "canonical parent + safe basename"으로 판정한다. 존재하지 않는 최종 파일을 `realpath`/`readlink -f` 대상으로 요구하지 않는다.
- 새 slug를 확정하기 전에 `.claude/plans/` 하위의 기존 plan 파일을 읽어 같은 `Source` + self-referential `Plan File` + non-terminal `Status`(`Complete`/`Superseded` 아님)가 있는지 먼저 찾는다. 하나면 그 파일에 bind하고, 여러 개면 임의 선택하지 않고 `NEEDS_USER`로 사용자 판단을 요청한다.
- 동일 파일이 이미 있으면 먼저 같은 `Source` + self-referential `Plan File`인지 확인한다. 같고 `Status`가 `Complete`/`Superseded`가 아니면 새 파일을 만들지 않고 기존 파일에 bind한 뒤 [`resume-state.md`](../references/resume-state.md)의 Baseline drift 검증을 먼저 수행한다. drift/ambiguity가 없을 때만 그 파일의 `Resume From` / `Last Completed Step` / `DA State`로 재개하고, drift 또는 ambiguity가 있으면 Step 1-2 재실행 또는 `NEEDS_USER` 전이를 따른다.
- 기존 파일이 unrelated collision이거나 같은 source라도 terminal(`Complete`/`Superseded`) 상태라 새 계획이 필요한 경우 `-2`, `-3` 같은 숫자 suffix를 slug 뒤에 붙여 collision을 해소한다. suffix 적용 후에도 같은 안전 검사를 다시 통과해야 한다.

초기 metadata 14필드와 값은 [`../references/plan-file-template.md`](../references/plan-file-template.md#step-45-초기값-for_action)가 SSOT다. Step 4.5에서는 그 표를 그대로 적용한다.

초기 본문은 Step 1-4에서 확인한 사실과 아직 DA 전이라는 상태를 담는 최소 계획이어도 된다. 단, Step 5 DA가 읽을 수 있도록 문제, 목표, non-goal, 변경 후보 파일, 검증 후보, Open Questions 상태는 비워 두지 않는다.

## Step 5-6: 외부 검토 plan-mode + 결과 반영

상세는 [`../references/da-integration.md`](../references/da-integration.md) 참조 (Step 5 preflight gate + Step 6 결과 반영 상태표). 승인된 SKIP이 아니면 `/run-da for_plan`에 Step 4.5에서 만든 plan 파일 경로와 내용을 context로 전달한다. 외부 검토 결과의 중요 변경은 같은 plan 파일의 Decision Log에 기록한다.

## Step 7: 계획 상태 진입 [전환점]

모든 분석, 질문, DA 검토가 완료되었으므로 계획 추적 도구로 진입한다 (런타임별 실제 도구는 [`../references/runtime-boundaries.md`](../references/runtime-boundaries.md#런타임-도구-매핑-plan-with-questions-고유) 참조). headless 세션은 Step 4에서 이미 BLOCKED 처리되어 이 단계에 도달하지 않는다.

- **Claude Code 세션**: 계획 추적 도구로 승인/tracking 상태에 진입한다. canonical plan 파일은 Step 4.5에서 만든 기존 경로이며, 런타임이 별도 transient plan buffer/path를 노출해도 그것을 새 canonical plan으로 승격하지 않는다.
- **Codex 세션**: `update_plan`으로 chat state 추적을 시작하되 파일 IO는 수행하지 않는다. 추적 대상 plan 파일은 Step 4.5에서 만든 기존 `.claude/plans/<slug>.md`다.

## Step 8: 계획 파일 review/refine [계획 추적 상태]

상세 실행 계획을 Step 4.5에서 만든 기존 plan 파일에서 review/refine한다. 파일 형식·14 metadata 필드·Decision Log·Resume From enum은 [`../references/plan-file-template.md`](../references/plan-file-template.md)와 [`../references/resume-state.md`](../references/resume-state.md)가 SSOT다. Step 8은 두 번째 canonical plan 파일을 만들지 않는다. Claude Code 런타임이 transient plan buffer/path를 제공하면, 승인 전 최종 내용이 Step 4.5 canonical 파일에 반영되어 있는지 확인한다.

**핵심 포함 내용** (template 외 본문):
- **변경 대상 파일 목록**: 수정/추가/삭제할 파일과 각 파일에서의 변경 내용
- **실행 순서**: 의존 관계를 고려한 작업 순서
- **검증 방법**: 변경이 올바르게 적용되었는지 확인하는 방법. 검증 수단 선택 가이드는 [`../references/validation-paths.md`](../references/validation-paths.md)를 참조한다 (risk-appropriate mix, hard-coded default 회피).
- **사이드이펙트 대응**: Step 4에서 확인된 사이드이펙트에 대한 처리 방법
- **롤백 가능성**: 문제 발생 시 되돌리는 방법
- **Post-Implementation 자동 수행 범위**: [`../references/post-implementation.md`](../references/post-implementation.md) 1~7번 절차 중 생략할 단계가 있으면 명시. 생략 단계가 없으면 "Post-Implementation 1~7 자동 수행 (default)" 한 줄로 표기. 이 항목은 승인 요청 시 사용자에게 노출되어 tracked write·commit·GitHub PR write 포함 자동 진행 범위 동의 근거가 된다.

**Hallucination 방지 원칙:**
- 계획 파일에는 Step 1-4에서 직접 확인한 사실과 Step 5-6 DA 판정만 포함한다.
- "~일 것이다", "~로 추정된다" 등 추측 표현을 금지한다.
- "추후 결정", "별도 검토 필요", "적절히 처리", "필요에 따라" 등 미결정 표현을 금지한다. 계획의 모든 항목은 구체적 행동으로 서술한다 ("에러 핸들링 추가"가 아니라 "X 함수에서 Y 예외를 catch하여 Z로 처리").
- 단, `[UNVERIFIED]` 라벨처럼 검증 상태를 명시하는 표기는 허용한다 (라벨 체계 상세는 [`../../write-handoff/references/llm-friendly-checklist.md`](../../write-handoff/references/llm-friendly-checklist.md#라벨-체계-anti-hallucination) 참조).
- 확인하지 못한 사항은 계획에 포함하지 않거나 `[UNVERIFIED]` 라벨로 명시.
- 계획 추적 진입 후 새로운 가정이 필요해지면, 먼저 파일 읽기 도구(예: 셸 `rg -n` / `sed -n` 또는 그에 상당하는 도구)로 확인한다 (추적 상태에서도 가능). 그래도 확인 불가하면 승인 요청 도구로 종료 → 검증 → 계획 추적 도구로 재진입한다. 확인 없이 가정을 계획에 추가하지 않는다.

**승인 요청 전 자체 점검:**
- **이슈 커버리지**: 원본 이슈/작업 설명의 모든 요구사항이 계획에 매핑되는가?
- **내부 일관성**: 실행 순서와 파일 간 의존 관계가 모순되지 않는가?

누락이나 모순이 발견되면 계획 추적 상태에서 즉시 수정한다. 추가 확인이 필요하면 승인 요청 도구로 종료 → 검증 → 계획 추적 도구로 재진입한다.

## Step 9: 사용자 승인 요청

계획이 완성되면 승인 요청 도구로 사용자에게 계획 승인을 요청한다 (런타임별 실제 도구는 [`../references/runtime-boundaries.md`](../references/runtime-boundaries.md#런타임-도구-매핑-plan-with-questions-고유) 참조).

사용자가 수정을 요청하면 계획 파일을 편집한 뒤 승인 요청 도구를 다시 호출한다.

계획이 승인되면 (사용자가 수정 요청을 하지 않으면) 추가 확인 없이 즉시 [`../references/post-implementation.md`](../references/post-implementation.md) 1번부터 진행한다. 1~7번 절차는 본 SKILL의 Post-Implementation reference가 정의한 고정 절차이며, Step 8의 "Post-Implementation 자동 수행 범위" 필수 항목이 plan 파일에 포함되어 사용자에게 노출된다. 따라서 계획 승인은 이 자동 진행 범위(tracked write·commit·GitHub PR write 포함)에 대한 사용자 동의로 간주된다.
