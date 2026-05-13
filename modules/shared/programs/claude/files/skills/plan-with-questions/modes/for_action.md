# Mode: for_action

`$ARGUMENTS` 에 이슈 레퍼런스가 있으면 이 모드로 진행한다. 이슈를 resolve 하여 내용을 가져오고, 계획 수립까지 진행한다.

## 주의: 즉시 계획 추적 도구 진입 금지

이 스킬을 호출했다고 해서 즉시 계획 추적 도구로 진입하지 않는다.

다음 순서를 반드시 지킨다:

1. Step 1-4 분석 / 질문을 일반 모드에서 완료한다.
2. Step 4.5 에서 공식 plan 파일을 초기화한다.
3. Step 5-6 DA를 거친다.
4. Step 7 에서 계획 추적 도구로 진입한다.

일반 모드에서 빌드, 명령 실행, 로컬 재현으로 계획 가정을 검증해야 hallucination이 억제된다.

런타임별 보충:

- Claude Code 세션: 계획 추적 도구 진입 시점부터 write 작업이 제한된다. 따라서 검증은 반드시 진입 전에 완료해야 한다.
- Codex 세션: chat state 추적은 write 제한을 강제하지는 않는다. 다만 Step 7 이후는 "검증 단계 종료 + 계획 파일 review / refine 단계" 로 규약된다. 따라서 동일하게 Step 1-4 의 탐색 / 질문과 Step 5-6 의 DA 검증을 완료한다.

미지원 런타임 (headless) 은 Step 4 에서 이미 BLOCKED 처리되어 이 단계에 도달하지 않는다. 단일 SSOT는 [`../references/runtime-boundaries.md`](../references/runtime-boundaries.md#질문-도구-미지원-대응) 다.

## Step 1: 이슈 유효성 판단 [일반 모드]

계획 수립에 앞서, 대상 이슈 또는 작업이 실제로 수행할 가치가 있는지 먼저 판단한다.

이슈 레퍼런스를 resolve 하여 내용을 가져온다. 특정 이슈 트래커 CLI에 의존하지 않고, 환경에서 사용 가능한 도구 (gh CLI, Linear API / MCP, 웹 검색 등) 를 활용한다.

세 가지 질문으로 유효성을 점검한다:

- 이미 해결되었는가?: 관련 코드, 최근 커밋, closed PR을 탐색하여 이미 해결된 문제가 아닌지 확인한다.
- YAGNI 인가?: 현재 시점에서 실제로 필요한 변경인지 판단한다. "나중에 필요할 수도 있으니까" 는 충분한 근거가 아니다.
- NGMI 인가?: 현재 아키텍처 또는 기술 제약 상 실현 불가능한 요구인지 확인한다.

유효하지 않다고 판단되면 사용자에게 근거를 제시하고, 계획을 중단할지 여부를 확인한다. 사용자가 그래도 진행하겠다고 하면 계속한다.

Scope 분해 판단: 요청이 독립적인 서브시스템 (서비스 / 플랫폼 / 독립 모듈 단위) 2개 이상을 포함하는 경우, 계획 파일 내 별도 Phase 또는 섹션으로 구분하여 다룬다. 출력은 여전히 단일 계획 파일이며, 별도의 plan-with-questions 사이클로 분리하지 않는다. 분해 여부가 불분명하면 Step 2 의 코드베이스 탐색 후 판단한다.

자동 PRD 후보 감지: Step 1-2 진행 중 [`../references/task-size-routing.md`](../references/task-size-routing.md) 의 트리거 신호가 감지되면 사용자에게 1회 알림 + opt-out을 제공한다. 상세 흐름은 [`for_prd.md`](./for_prd.md) 를 참조한다.

## Step 2: 코드베이스 탐색 + 로컬 재현 [일반 모드]

대상 이슈를 정독하고, 관련 코드베이스를 탐색한다.

탐색 항목:

- 이슈에 언급된 파일, 모듈, 설정을 코드베이스에서 찾아 현재 상태를 파악한다.
- 관련된 기존 구현, 의존성, 설정 패턴을 확인한다.
- 이슈에 링크된 PR, 커밋, 다른 이슈가 있으면 함께 확인한다.

로컬 검증 의무:

- 이슈 또는 작업에서 언급된 문제를 로컬에서 직접 재현한다.
- 관련 명령어 실행, 빌드 시도, 설정 확인 등을 수행한다.
- API / 플래그 / 경로의 존재 여부를 `grep` / `which` / `--help` 로 확인한다.
- "~일 것이다", "~로 추정된다" 등 추측 기반 분석을 금지한다.
- 코드베이스를 직접 읽어 확인하지 않은 내용은 이후 단계에서 사용하지 않는다.

## Step 3: 질문 수집 [일반 모드]

분석 과정에서 발견한 모든 불명확 점을 수집한다. 다음 관점에서 빠짐없이 점검한다:

- 요구사항 불명확 점: 이슈 또는 작업 설명에서 해석이 여러 가지 가능한 부분.
- 판단 기준: 사용자의 선호도나 우선순위가 필요한 결정 사항.
- 사이드이펙트: 변경이 다른 기능 / 모듈 / 플랫폼에 미치는 영향.
- 트레이드오프 / 접근법 비교: 실행 가능한 접근법이 2개 이상이면 각 접근법의 장단점을 정리한다. Step 3.5 에서 외부 자문으로 보강하고, 메인 LLM은 Step 3.5 결과 도착 후 옵션 표시 정책에 따라 옵션을 사용자에게 제시한다.
- 인지 상태 확인: 사용자가 특정 제약이나 영향을 알고 있는지 여부.
- XY Problem 검증: 사용자가 실제 문제 (X) 가 아닌 자신이 시도한 해결책 (Y) 에 대해 요청하고 있지는 않은지 점검한다. 의심되면 "해결하려는 근본 문제가 무엇인가요?" 를 질문한다.

하나도 빠짐없이 전부 수집한다. "이 정도면 됐겠지" 는 금지한다.

## Step 3.5: 외부 LLM 기술 자문 [일반 모드, background 병렬]

Step 3 완료 직후, 사용자 질문 전 (Step 4 직전) 에 외부 LLM에 anchoring-neutral 옵션 평가를 위임한다. 이 단계의 목적은 메인 LLM 의 첫 인상이 사용자에게 anchor 되기 전에 중립 평가 매트릭스를 확보하는 것이다.

운영 정보:

- 호출 시점: Step 3 종료 직후 background 병렬로 실행한다. 메인은 Discovery Summary 정리와 plan draft 초안 등 다른 준비를 진행한다.
- 결과 도착 시: Step 4 로 진입한다.
- budget: 30분 이내 (high / xhigh 공통). xhigh는 명시적 심층 요청 시에만 사용한다.

SSOT 참조:

- codex exec 호출 명령: 단일 SSOT는 [`../references/consulting-step-shell.md`](../references/consulting-step-shell.md) 다. `-C` scratch cwd + `--ignore-user-config` + `--sandbox read-only` + `--ephemeral` 로 trust boundary를 완결한다. 본 mode 파일은 명령을 복제하지 않는다.
- 입출력 schema, 옵션 표시 정책, 텍스트 복구: 단일 SSOT는 [`../references/consulting-step.md`](../references/consulting-step.md) 다.
- 자문 단계 미구현 또는 실패 fallback: 메인 LLM은 Step 3 결과를 직접 사용자에게 제시하되, 자문 부재를 사용자에게 평이 한국어로 한 줄 알린다 ("자문이 완료되지 못했어요. 옵션을 그대로 보여드릴게요."). plan 에는 `[UNVERIFIED]` 라벨로 자문 부재를 기록한다.

Step 3.5 는 Step 5 의 DA와 목적이 다르다. Step 3.5 는 사용자에게 옵션 제시 전 anchoring-neutral 평가 매트릭스 확보이고, Step 5 는 plan 결함의 사후 검토다.

## Step 4: 사용자에게 질문 [일반 모드]

사용자에게 질문할 때는 질문 도구를 사용한다. 이 규칙은 예외 없이 적용된다. 질문 도구 미지원 런타임 대응의 단일 SSOT는 [`../references/runtime-boundaries.md`](../references/runtime-boundaries.md#질문-도구-미지원-대응) 다.

라운드당 하나의 질문: 수집한 질문 (Step 3) 과 외부 자문 매트릭스 (Step 3.5) 를 한 라운드에 모아서 던지지 않는다. 라운드당 `questions` 배열 길이는 1 로 고정한다. 이렇게 하면 (a) 사용자가 한 결정에 집중할 수 있고, (b) 메인 LLM이 사용자 노출 텍스트를 충분히 풀어 설명할 cognitive room을 확보한다. 인지 부하와 turn_abort 위험을 줄이기 위함이다. 사용자의 답변에 따라 추가 질문이 생기면 새 라운드 (여전히 `questions` 배열 길이 1) 로 이어간다. 모든 불명확 점이 해소될 때까지 라운드를 반복한다.

### 트레이드오프 라운드 정책

트레이드오프 라운드에서 적용되는 정책의 단일 SSOT는 [`../references/consulting-step.md`](../references/consulting-step.md) 다. 본 mode 파일은 정책 본문을 복제하지 않는다.

메인 LLM은 사용자 노출 직전 SSOT의 다음 절차를 적용한다 (각 절차의 본문 풀이는 SSOT만 본다):

- 사용자 노출 레이어 제한 (`user_facing` layer만 노출)
- 옵션 표시 정책 (`user_facing.plain_disqualifier` 표시)
- `user_facing` 누락 시 텍스트 복구 4단계

질문 패턴의 단일 SSOT는 [`../references/output-templates.md`](../references/output-templates.md#step-4--step-i-4-질문-패턴) 다.

## Step 4.5: 공식 plan 파일 초기화 [일반 모드, for_action 전용]

모든 사용자 질문이 해소되면 Step 5 의 DA 전에 공식 `.claude/plans/<slug>.md` 파일을 초기화한다. 이 단계는 for_action 전용이다. for_prd는 이 단계를 건너뛰고 PRD draft 또는 context를 DA 입력으로 사용한다 ([`for_prd.md`](./for_prd.md) 참조).

slug와 path 안전 규칙:

- slug는 lowercase `[a-z0-9-]+` basename만 허용한다.
- `.`, `..`, slash (`/`), backslash (`\`), 공백, shell 또는 path metacharacter가 포함된 값은 거부하고 안전한 slug를 다시 생성한다.
- 새 파일 자체가 아직 없을 수 있으므로 repo root와 `.claude/plans/` parent directory 처럼 이미 존재해야 하는 경로만 canonicalize 한다. 그 parent가 repo 안의 `.claude/plans/` 와 일치함을 확인한 뒤 basename slug를 join 한다.
- 최종 path containment는 "canonical parent + safe basename" 으로 판정한다. 존재하지 않는 최종 파일을 `realpath` 또는 `readlink -f` 대상으로 요구하지 않는다.
- 새 slug를 확정하기 전에 `.claude/plans/` 하위의 기존 plan 파일을 읽어 같은 `Source` 와 self-referential `Plan File` 그리고 non-terminal `Status` (`Complete` 또는 `Superseded` 아님) 가 있는지 먼저 찾는다. 하나면 그 파일에 bind 하고, 여러 개면 임의 선택하지 않고 `NEEDS_USER` 로 사용자 판단을 요청한다.
- 동일 파일이 이미 있으면 먼저 같은 `Source` 와 self-referential `Plan File` 인지 확인한다. 같고 `Status` 가 `Complete` 또는 `Superseded` 가 아니면 새 파일을 만들지 않고 기존 파일에 bind 한 뒤 [`../references/resume-state.md`](../references/resume-state.md) 의 baseline drift 검증을 먼저 수행한다. drift 나 ambiguity가 없을 때만 그 파일의 `Resume From` / `Last Completed Step` / `DA State` 로 재개하고, drift 또는 ambiguity가 있으면 Step 1-2 재실행 또는 `NEEDS_USER` 전이를 따른다.
- 기존 파일이 unrelated collision 이거나 같은 source 라도 terminal (`Complete` 또는 `Superseded`) 상태라 새 계획이 필요한 경우 `-2`, `-3` 같은 숫자 suffix를 slug 뒤에 붙여 collision을 해소한다. suffix 적용 후에도 같은 안전 검사를 다시 통과해야 한다.

초기 metadata 14 필드와 값의 단일 SSOT는 [`../references/plan-file-template.md`](../references/plan-file-template.md#step-45-초기값-for_action) 다. Step 4.5 에서는 그 표를 그대로 적용한다.

초기 본문은 Step 1-4 에서 확인한 사실과 아직 DA 전이라는 상태를 담는 최소 계획이어도 된다. 단, Step 5 의 DA가 읽을 수 있도록 문제, 목표, non-goal, 변경 후보 파일, 검증 후보, Open Questions 상태는 비워 두지 않는다.

## Step 5-6: 외부 검토 plan-mode + 결과 반영

Step 5 의 preflight gate와 Step 6 의 결과 반영 상태표의 단일 SSOT는 [`../references/da-integration.md`](../references/da-integration.md) 다. 승인된 SKIP이 아니면 `/run-da for_plan` 에 Step 4.5 에서 만든 plan 파일 경로와 내용을 context로 전달한다. 외부 검토 결과의 중요 변경은 같은 plan 파일의 Decision Log에 기록한다.

## Step 7: 계획 상태 진입 [전환점]

모든 분석, 질문, DA 검토가 완료되었으므로 계획 추적 도구로 진입한다. 런타임별 실제 도구는 [`../references/runtime-boundaries.md`](../references/runtime-boundaries.md#런타임-도구-매핑-plan-with-questions-고유) 를 참조한다. headless 세션은 Step 4 에서 이미 BLOCKED 처리되어 이 단계에 도달하지 않는다.

- Claude Code 세션: 계획 추적 도구로 승인 / tracking 상태에 진입한다. SSOT plan 파일은 Step 4.5 에서 만든 기존 경로다. 런타임이 별도 transient plan buffer 또는 path를 노출해도 그것을 새 SSOT plan으로 승격하지 않는다.
- Codex 세션: `update_plan` 으로 chat state 추적을 시작하되 파일 IO는 수행하지 않는다. 추적 대상 plan 파일은 Step 4.5 에서 만든 기존 `.claude/plans/<slug>.md` 다.

## Step 8: 계획 파일 review / refine [계획 추적 상태]

상세 실행 계획을 Step 4.5 에서 만든 기존 plan 파일에서 review와 refine 한다. 파일 형식, 14 metadata 필드, Decision Log, Resume From enum의 단일 SSOT는 [`../references/plan-file-template.md`](../references/plan-file-template.md) 와 [`../references/resume-state.md`](../references/resume-state.md) 다. Step 8 은 두 번째 SSOT plan 파일을 만들지 않는다. Claude Code 런타임이 transient plan buffer 또는 path를 제공하면, 승인 전 최종 내용이 Step 4.5 의 SSOT 파일에 반영되어 있는지 확인한다.

핵심 포함 내용 (template 외 본문):

- 변경 대상 파일 목록: 수정 / 추가 / 삭제할 파일과 각 파일에서의 변경 내용.
- 실행 순서: 의존 관계를 고려한 작업 순서.
- 검증 방법: 변경이 올바르게 적용되었는지 확인하는 방법. 검증 수단 선택 가이드의 단일 SSOT는 [`../references/validation-paths.md`](../references/validation-paths.md) 다 (risk-appropriate mix, hard-coded default 회피).
- 사이드이펙트 대응: Step 4 에서 확인된 사이드이펙트에 대한 처리 방법.
- 롤백 가능성: 문제 발생 시 되돌리는 방법.
- Post-Implementation 자동 수행 범위: [`../references/post-implementation.md`](../references/post-implementation.md) 의 1번 ~ 7번 절차 중 생략할 단계가 있으면 명시한다. 생략 단계가 없으면 "Post-Implementation 1~7 자동 수행 (default)" 한 줄로 표기한다. 이 항목은 승인 요청 시 사용자에게 노출되어 tracked write, commit, GitHub PR write 포함 자동 진행 범위 동의 근거가 된다.

Hallucination 방지 원칙:

- 계획 파일에는 Step 1-4 에서 직접 확인한 사실과 Step 5-6 의 DA 판정만 포함한다.
- "~일 것이다", "~로 추정된다" 등 추측 표현을 금지한다.
- "추후 결정", "별도 검토 필요", "적절히 처리", "필요에 따라" 등 미결정 표현을 금지한다. 계획의 모든 항목은 구체적 행동으로 서술한다 ("에러 핸들링 추가" 가 아니라 "X 함수에서 Y 예외를 catch 하여 Z로 처리").
- 단, `[UNVERIFIED]` 라벨처럼 검증 상태를 명시하는 표기는 허용한다. 라벨 체계 상세의 단일 SSOT는 [`../../write-handoff/references/llm-friendly-checklist.md`](../../write-handoff/references/llm-friendly-checklist.md#라벨-체계-anti-hallucination) 다.
- 확인하지 못한 사항은 계획에 포함하지 않거나 `[UNVERIFIED]` 라벨로 명시한다.
- 계획 추적 진입 후 새로운 가정이 필요해지면, 먼저 파일 읽기 도구 (예: 셸 `rg -n` / `sed -n` 또는 그에 상당하는 도구) 로 확인한다 (추적 상태에서도 가능하다). 그래도 확인 불가하면 승인 요청 도구로 종료하고 검증 후 계획 추적 도구로 재진입한다. 확인 없이 가정을 계획에 추가하지 않는다.

승인 요청 전 자체 점검:

- 이슈 커버리지: 원본 이슈 또는 작업 설명의 모든 요구사항이 계획에 매핑되는가?
- 내부 일관성: 실행 순서와 파일 간 의존 관계가 모순되지 않는가?

누락이나 모순이 발견되면 계획 추적 상태에서 즉시 수정한다. 추가 확인이 필요하면 승인 요청 도구로 종료하고 검증 후 계획 추적 도구로 재진입한다.

## Step 9: 사용자 승인 요청

계획이 완성되면 승인 요청 도구로 사용자에게 계획 승인을 요청한다. 런타임별 실제 도구는 [`../references/runtime-boundaries.md`](../references/runtime-boundaries.md#런타임-도구-매핑-plan-with-questions-고유) 를 참조한다.

사용자가 수정을 요청하면 계획 파일을 편집한 뒤 승인 요청 도구를 다시 호출한다.

계획이 승인되면 (사용자가 수정 요청을 하지 않으면) 추가 확인 없이 즉시 [`../references/post-implementation.md`](../references/post-implementation.md) 의 1번부터 진행한다. 1번 ~ 7번 절차는 본 스킬의 Post-Implementation reference가 정의한 고정 절차이며, Step 8 의 "Post-Implementation 자동 수행 범위" 필수 항목이 plan 파일에 포함되어 사용자에게 노출된다. 따라서 계획 승인은 이 자동 진행 범위 (tracked write, commit, GitHub PR write 포함) 에 대한 사용자 동의로 간주된다.
