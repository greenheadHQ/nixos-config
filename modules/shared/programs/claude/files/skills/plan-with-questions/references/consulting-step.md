# Step 3.5 / Step I-3.5: 외부 LLM 기술 자문

Step 3 직후, 사용자에게 옵션을 제시하기 전 (Step 4 직전) 에 외부 LLM (`codex exec`) 에 anchoring-neutral 옵션 평가를 위임한다. 목적은 사용자가 메인 LLM의 첫 추천에 anchor 되어 이후 DA가 결함을 지적해도 재설계를 거부하는 패턴 (`#490` 사례) 을 차단하는 것이다.

본 reference는 다음의 단일 SSOT 다:

- Step 3.5 의 입력 schema와 출력 JSON schema
- 자문 결과 처리 절차 (옵션 표시 정책)
- `user_facing` 누락 시 텍스트 복구 4단계

codex exec 호출 명령 자체 (셸 호출 1/2/3) 의 단일 SSOT는 [`consulting-step-shell.md`](./consulting-step-shell.md) 로 분리됐다. 본 파일은 명령을 복제하지 않는다.

## 적용 범위

- for_action의 Step 3.5: 트레이드오프 항목이 1개 이상이면 무조건 호출한다.
- for_issue의 Step I-3.5: 블랙박스 체크리스트 "C. 트레이드오프" 에 1+ 항목이면 호출한다. 단순 요구사항 명료화 위주의 인터뷰는 skip 한다.
- for_prd의 P4 (for_action Step 3.5 차용): `for_action` 과 동일하게 트레이드오프 1+ 이면 호출한다. 자체 plan 사본이 없고 PRD를 `.claude/prds/` 에 직접 작성하므로 P4 호출은 PRD 작성 전 한 번이며, phase 별 반복은 적용되지 않는다.

## Step 3.5 는 Step 5 의 DA와 다르다

| 항목 | Step 3.5 (consulting) | Step 5 (DA) |
|------|----------------------|-------------|
| 시점 | 사용자 질문 전 | 사용자 답변 후 |
| 입력 | 옵션 후보 + evidence | for_action의 plan 파일 또는 for_prd의 PRD draft / context |
| 출력 | anchoring-neutral 평가 매트릭스 | 결함 verdict (CONFIRMED / NOT_AN_ISSUE / ...) |
| 목적 | de-anchoring 전처리 | 사후 검증 |

## 입력 (codex exec 프롬프트 구조)

```
## 작업 목표
{이슈 또는 요청 요약. 1-3 문장.}

## Resolved evidence (Step 2 직접 확인)
- 파일: {경로 + 핵심 사실 — `verified` 라벨}
- 명령: {실행 결과}
- 패턴: {기존 코드베이스 컨벤션}

## 제약
{기술 / 시간 / 조직 제약}

## 현 상황 적합성 컨텍스트

자문이 "어떤 옵션이 본 작업의 현 상황에 가장 적합한가" 를 평가할 수 있도록, 결정의 가중치를 결정짓는 사실을 명시한다. 자문은 이 컨텍스트를 사용해 `user_facing` layer의 비유 톤과 `disqualifiers` 적용 강도를 조절한다.

- 시간 제약: {예: "이번 주 내 머지", "다음 분기 전 안정화". 없으면 "없음".}
- 가역성 요구: {예: "1 commit revert 가능해야 함", "DB 마이그레이션은 forward-only 허용"}
- 위험 허용도: {예: "production 영향 없음 (스킬 문서)", "유저 데이터 경로 — 보수적"}
- 사용자 기능 또는 영향 범위: {예: "단일 스킬 본문", "전 호스트 deploy 영향"}
- 기존 패턴 일치도: {예: "유사 결정 선례 N건 — 동일 패턴 우선", "신규 — 패턴 없음"}
- 기타 결정에 영향을 주는 현장 사실: {유연 자유 기재}

## Decision points (메인 LLM 추천 제외)
- decision_id: {식별자}
  decision_type: {tradeoff | requirement_interpretation | scope_boundary | ...}
  user_question: {사용자에게 물을 질문 원안}
  candidates:
    - id: {A/B/C}
      description: {중립 묘사. "간단", "추천" 같은 표현 금지.}

## 검증 surface (가용 도구)
{static / unit / integration / E2E / ... — `./validation-paths.md` catalog 인용}

## Non-goals
{명시적 비목표}
```

제외할 입력 (자문 입력 sanitization — anchoring-neutral 평가 보호):

- 메인 LLM의 추천 또는 선호 표현 ("A가 더 간단해 보임", "B를 권장").
- 사용자가 미이해 상태에서 수락한 선택은 `user-proposed candidate` 라벨로만 표시.

## 출력 JSON schema (고정)

자문 출력은 두 layer로 분리한다 (사용자 노출 레이어 제한):

- `technical_matrix` (메인 LLM 내부 전용) — 7키 평가 매트릭스다. 사용자에게 절대 노출하지 않는다. 메인 LLM의 옵션 분석 입력으로만 사용한다. 기존 `evaluation_matrix` 필드를 명시적으로 재명명한 것이며 의미는 동일하다.
- `user_facing` (사용자 노출 전용) — 비유, 평이한 한국어 description, 평이 disqualifier로 구성한다. AskUserQuestion (또는 등가 도구) 에 그대로 사용한다. 기술 용어 금지, 매트릭스 7키 노출 금지.

```json
{
  "decisions": [
    {
      "decision_id": "<string>",
      "decision_type": "<tradeoff | requirement_interpretation | scope_boundary | ...>",
      "user_question": "<string>",
      "options": [
        {
          "id": "<A | B | C | ...>",
          "description": "<중립 1-2 문장 — 메인 LLM 내부 reference용>",
          "technical_matrix": {
            "요구충족": "<요약>",
            "구현비용": "<요약>",
            "되돌리기쉬움": "<요약>",
            "운영위험": "<요약>",
            "검증가능성": "<요약>",
            "주요unknown": "<요약>",
            "비용시간추정": "<범위 또는 [UNVERIFIED]>"
          },
          "user_facing": {
            "label": "<옵션을 한 줄로 표현하는 평이 라벨 — 기술 용어/약어 금지>",
            "description": "<2-4 문장. 일상 비유 적극 사용. 사용자가 도메인 모르더라도 트레이드오프 직관 가능하게>",
            "analogy": "<핵심 트레이드오프 1-2 문장 비유 — 영양/요리/교통/주방 등 도메인 무관 비유>",
            "plain_disqualifier": "<이 옵션이 틀릴 수 있는 조건을 평이한 한국어로 1 문장. 기술 용어 금지>"
          },
          "disqualifiers": ["<이 옵션이 틀릴 수 있는 조건 (technical)>", "..."],
          "evidence_gaps": ["<verify 필요 사항>", "..."]
        }
      ],
      "validation_needed": "<검증 surface 추천>",
      "ask_user_only_if": "<사용자 판단이 정말 필요한 조건>",
      "can_agent_decide_if": "<에이전트가 판단 가능한 조건>"
    }
  ]
}
```

### 1-shot dummy 예시

자문 프롬프트에 그대로 임베드 가능하다. 메인 LLM은 자문 호출 시 본 dummy를 prompt에 포함해 schema 형태를 강하게 anchoring 한다.

```json
{
  "decisions": [
    {
      "decision_id": "dummy-cache-strategy",
      "decision_type": "tradeoff",
      "user_question": "API 응답 캐시 무효화 정책을 어떻게 할까?",
      "options": [
        {
          "id": "A",
          "description": "TTL 기반 시간 만료 — 60초 후 자동 폐기",
          "technical_matrix": {
            "요구충족": "stale 데이터 60초 허용 시 OK",
            "구현비용": "라이브러리 옵션 1줄",
            "되돌리기쉬움": "TTL 0으로 즉시 비활성화",
            "운영위험": "trafic spike 시 thundering herd",
            "검증가능성": "단위 테스트 가능",
            "주요unknown": "실제 트래픽 패턴",
            "비용시간추정": "0.5h"
          },
          "user_facing": {
            "label": "1분 지나면 새로 받기",
            "description": "냉장고에 음식 1분 두고 그대로 먹는 방식. 빠르고 단순하지만, 60초 사이 누가 음식을 바꿔도 모른다.",
            "analogy": "1분짜리 모래시계 — 다 떨어지면 새로 받아온다",
            "plain_disqualifier": "데이터가 60초 안에 자주 바뀌고, 사용자가 그 변화를 즉시 봐야 한다면 부적합"
          },
          "disqualifiers": ["high-frequency mutation 케이스에서 stale window 허용 불가"],
          "evidence_gaps": ["실제 트래픽 mutation 빈도 미측정"]
        },
        {
          "id": "B",
          "description": "쓰기 발생 시 명시적 invalidate — event-driven",
          "technical_matrix": {
            "요구충족": "stale 0초 보장",
            "구현비용": "쓰기 경로마다 invalidate hook 추가",
            "되돌리기쉬움": "hook 제거로 비활성화 — 코드 분산",
            "운영위험": "invalidate 누락 시 영구 stale",
            "검증가능성": "통합 테스트 필요",
            "주요unknown": "쓰기 경로 누락 가능성",
            "비용시간추정": "3-5h"
          },
          "user_facing": {
            "label": "바뀔 때마다 즉시 갱신",
            "description": "음식이 바뀔 때 누가 알려주면 바로 새로 받는 방식. 항상 최신이지만, 알리는 사람이 한 명이라도 빠뜨리면 영원히 옛날 음식을 먹게 된다.",
            "analogy": "주방장이 메뉴 바꾸면 종업원이 모든 손님 테이블 돌며 알리는 방식",
            "plain_disqualifier": "쓰기 경로가 여러 곳에 흩어져 있고 누락 검증이 어렵다면 부적합"
          },
          "disqualifiers": ["쓰기 경로 발견되지 않은 entry point 존재 시 silent stale"],
          "evidence_gaps": ["전체 쓰기 경로 enumeration 미완료"]
        }
      ],
      "validation_needed": "통합 테스트 + 트래픽 분석",
      "ask_user_only_if": "stale 허용 윈도우와 invalidate 누락 위험 중 어느 쪽이 더 큰 비용인가",
      "can_agent_decide_if": "쓰기 경로 enumeration이 1 commit으로 완결되고 stale 허용 0 요구가 명시되어 있으면 B 자동 선택 가능"
    }
  ]
}
```

자문 출력 schema sanity (메인 LLM 은 codex 출력에서 아래 필드가 발견되면 무시한다 — anchoring-neutral 평가 매트릭스 약속 보호):

- 점수 합산, 순위, ranking, score 필드.
- `chosen_*`, `selected_*`, `recommended_*`, `winner` 같은 implicit choice 필드 (codex 가 자체 추가한 경우도 무시).
- `rationale` 필드를 단일 옵션 정당화로 사용 — `disqualifiers` 또는 `evidence_gaps` 만 표시 가능.

명백히 불가능한 옵션은 출력 단계에서 제외하지 않고 `disqualifiers` 로 표시한다 (사용자가 "왜 이게 빠졌는지" 추측하지 않도록).

프롬프트 정밀화: 호출자는 "출력 JSON schema를 반환하라" 가 아니라 "위 schema에 맞는 JSON instance를 반환하라. schema definition은 출력하지 마라" 라고 명시한다. 1-shot dummy 예시 (위 `dummy-cache-strategy`) 를 프롬프트에 항상 포함한다. 두 layer schema에서 `user_facing` 누락 위험을 줄이기 위함이다.

## codex exec 호출 명령

codex exec 호출 명령 (셸 호출 1/2/3) 의 단일 SSOT는 [`consulting-step-shell.md`](./consulting-step-shell.md) 다. SKILL.md, modes/*.md, 본 reference 모두 명령을 복제하지 않는다.

## Background timing

운영 흐름:

- 호출 시점: Step 3 종료 직후 background로 발사한다 (`run_in_background: true`).
- 메인 LLM이 그 사이 수행할 작업 —
  - Discovery Summary 정리.
  - Plan draft 초안 (변경 대상 파일, 실행 순서, 검증 surface).
  - Step 3 에서 수집한 사용자 질문의 비-트레이드오프 항목 (요구사항 명료화 등) 1차 점검.
- 결과 도착 시: Step 4 (또는 Step I-4 첫 라운드) 사용자 질문 제시. 자문 매트릭스를 입력으로 통합.
- budget: 30분 이내 (high와 xhigh 모두). 초과 시 두 가지 fallback 중 하나 — (a) timeout 알림 후 자문 없이 Step 4 진행 + plan에 `[UNVERIFIED]` 라벨로 자문 부재 명시, 또는 (b) 사용자에게 대기 의사 확인.

## 옵션 표시 정책 (사용자 제시 단계)

자문 결과를 `AskUserQuestion` (또는 등가 도구) 으로 제시할 때 적용하는 단일 규칙은 다음이다.

### disqualifier 표시

각 옵션의 사용자 노출 description에 "이 선택이 틀릴 수 있는 조건" 을 함께 표기한다. 자문 출력의 `user_facing.plain_disqualifier` 를 그대로 사용한다 (technical `disqualifiers` 는 메인 LLM 내부 기록 전용). 평이 disqualifier 누락 시 아래 텍스트 복구 4단계를 적용한다.

상세 메시지 패턴의 단일 SSOT는 [`output-templates.md`](./output-templates.md#step-4--step-i-4-질문-패턴) 다.

## `user_facing` 누락 시 텍스트 복구 4단계

자문 출력에 `user_facing` layer가 누락 또는 부분 누락된 경우 메인 LLM은 graceful degrade로 다음 4단계를 순서대로 시도한다. 어느 단계에서든 사용자 노출 텍스트가 만들어지면 거기서 멈추고 사용자에게 표시한다.

```text
Stage 1. 기존 평가 필드에서 사용자 설명 복구
    - technical_matrix가 있으면 그 값을 우선 사용한다.
      technical_matrix.요구충족 을 평이 한국어로 풀고
      disqualifiers 첫 항목을 plain_disqualifier로 변환한다.
    - 자문 출력이 evaluation_matrix만 제공하면 같은 방식으로 사용자 설명을 만든다
      (필드명만 호환 처리, 동작은 동일).
    - 둘 다 부재 → Stage 2.
    - 텍스트 생성 성공 → 텍스트 복구 OK.

Stage 2. generic 비유 적용
    - Stage 1 텍스트가 여전히 기술 용어 위주이면 도메인 무관 비유 (요리 / 교통 / 주방) 로
      유추 description을 생성한다.
    - 텍스트 생성 성공 → 텍스트 복구 OK.

Stage 3. 메인 LLM 자체 작성
    - Stage 1 또는 2 모두 실패 → 메인 LLM이 description, analogy, plain_disqualifier 3 필드를 자체 생성.
    - 사용자에게는 메인 LLM이 평이하게 풀어 쓴 설명임을 한 줄로 표기한다.

Stage 4. 위 모두 실패 → 자문 결과를 신뢰할 수 없으므로 결정 진행 불가
    - 사용자에게 평이 한국어로 보고:
      "자문 결과 형식이 맞지 않아 옵션 설명을 복구하지 못했어요. 옵션을 그대로 보여드릴게요."
```

## Decision Log 기록

자문 결과로 사용자 선택이 바뀐 경우 기록 target은 모드별로 다르다:

- for_action 모드: plan 파일의 `Decision Log` 에 ADR 미니 기록.
- for_prd 모드: PRD draft 또는 context에 기록하고, PRD 작성 후 master의 `Change Log` 와 특정 phase가 영향받는 경우 phase `Discoveries / Decisions` 에 이관.

durable output (plan, PRD, PR, issue, comment) 에 임시 scratch consult 경로 리터럴을 박지 않는다는 정책의 단일 SSOT는 [`consulting-step-shell.md`](./consulting-step-shell.md#durable-output에-임시-경로-박제-금지-회귀-방지) 다.

plan baseline 형식과의 관계: `plan-file-template.md` 의 Baseline도 같은 durable-output 원칙을 따른다. plan에는 짧은 commit 식별자나 diff digest 대신 자연어 anchor와 dirty 상태 요약을 기록하고, 재개 시 안전하게 비교할 수 없으면 `resume-state.md` 의 fail-closed 절차를 따른다.

for_action의 Decision Log 기록 형식:

```
## DL-N: <decision_id>
- Status: accepted
- Context: Step 3에서 메인 LLM이 옵션 A를 후보로 작성. Step 3.5 외부 자문에서 옵션 A의 disqualifier 발견.
- Decision: 옵션 B 채택.
- Consequences: <영향>
- External Consult: <자문 회차 자연어 요약 + verdict 요약. result.json 같은 임시 경로 리터럴 박제 금지.>
```

## Validation

본 reference의 schema 정의가 정상 동작하는지 확인하는 항목 (codex exec 호출 자체 검증은 [`consulting-step-shell.md`](./consulting-step-shell.md#validation) 의 Validation 절을 참조한다):

- dummy decision (옵션 A / B 2개) 1개로 Step 3.5 round-trip 1회가 성공.
- 출력 JSON 의 schema sanity 확인 (`technical_matrix` 7키 + `user_facing` 4필드 + `disqualifiers`/`evidence_gaps` 배열).
