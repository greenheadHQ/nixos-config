# Mode: for_issue

`$ARGUMENTS`에 이슈 레퍼런스가 없으면 이 모드로 진행한다.
brainstorming의 핵심(요구사항 탐색, 블랙박스 해소)을 내재화하고, 최종 산출물은 `/create-issue`로 생성한 이슈 + LLM 이행 가이드이다.

DA는 for_issue에서 실행하지 않는다. 스무고개 루프가 DA의 역할(불명확점 해소, 품질 보장)을 대체한다. 계획 추적 도구 미사용 (산출물이 계획 파일이 아닌 이슈).

## Step I-1: fan-out 레퍼런스 수집 [일반 모드]

`$ARGUMENTS`의 텍스트 설명 또는 대화 컨텍스트를 분석하여, [`../references/fanout-fanin.md`](../references/fanout-fanin.md#역할-카탈로그)의 역할 카탈로그에서 적절한 역할을 선택하고 에이전트를 병렬 발사한다.

에이전트 수와 역할은 작업의 범위/복잡도에 따라 동적으로 결정한다 (2-6개). 런타임 분기와 codex exec 호출 패턴은 [`../references/fanout-fanin.md`](../references/fanout-fanin.md#런타임-분기) 참조.

## Step I-2: fan-in 결과 통합 [일반 모드]

에이전트 결과를 [`../references/fanout-fanin.md`](../references/fanout-fanin.md#fan-in-통합-전략)의 통합 전략에 따라 카테고리별로 분류한다. 중복을 제거하고, 모순점을 식별한다.

## Step I-3: 블랙박스 체크리스트 동적 생성 [일반 모드]

fan-in 결과에서 미해결 항목(블랙박스 제로 원칙의 "블랙박스" — 모호하거나 결정되지 않은 사항)을 체크리스트 형태로 구조화한다. 카테고리(A 요구사항 / B 설계 결정 / C 트레이드오프 / D 사이드이펙트 / E 기타)는 [`../references/output-templates.md`](../references/output-templates.md#for_issue-step-i-3-블랙박스-체크리스트-카테고리) 참조.

사용자에게 체크리스트를 보여주고, 모든 항목이 ✅가 될 때까지 또는 사용자가 "충분하다"고 판단할 때까지 스무고개를 반복한다.

## Step I-3.5: 외부 LLM 기술 자문 [일반 모드, background 병렬]

블랙박스 체크리스트 중 "C. 트레이드오프" 항목이 1개 이상이면 외부 LLM(`codex exec`)에 anchoring-neutral 옵션 평가를 위임한다. for_action Step 3.5와 동일한 anti-anchoring 규칙을 적용한다.

- **호출 시점**: Step I-3 체크리스트 생성 직후 background 병렬. 메인은 Step I-4 라운드 1 질문 후보를 정리한다.
- **결과 도착 시**: Step I-4 첫 라운드 질문에 anchoring-neutral 옵션을 통합한다.
- **상세 입출력 schema·codex exec 호출 명령·anti-anchoring 4 규칙**: [`../references/consulting-step.md`](../references/consulting-step.md) (단일 SSOT — 본 파일은 명령을 복제하지 않는다).

트레이드오프 항목이 없으면 Step I-3.5는 skip한다 (단순 요구사항 명료화 위주의 인터뷰).

## Step I-4: 스무고개 피드백 루프 [일반 모드]

**사용자에게 질문할 때는 질문 도구를 사용한다.** 질문 도구 미지원 시 [`../references/runtime-boundaries.md`](../references/runtime-boundaries.md#질문-도구-미지원-대응)를 따른다.

질문 도구로 한 라운드에 최대 4개 질문을 묻는다. 우선순위가 높은(아키텍처 결정, 핵심 요구사항) 질문부터 시작한다. (for_action Step 4의 "한번에 모아서"와 달리 라운드당 제한을 두는 이유: for_issue는 반복 라운드로 점진적으로 이슈를 정의하므로 과부하 방지가 필요하다.)

각 라운드 후:
1. 답변된 체크리스트 항목을 ✅로 업데이트
2. 답변에서 파생된 새 불명확점이 있으면 체크리스트에 추가
3. 남은 항목이 있으면 다음 라운드 진행
4. 모든 항목 ✅ 또는 사용자 "충분" → Step I-5로

질문 패턴과 anti-anchoring 표시 규칙은 [`../references/output-templates.md`](../references/output-templates.md#step-4--step-i-4-질문-패턴) 참조.

## Step I-5: 이슈 생성 [일반 모드]

스무고개 결과를 바탕으로 `/create-issue` 스킬을 실행하여 이슈를 등록한다. write-handoff 실행 여부는 Step I-6에서 통합 선택지로 제안하므로, create-issue 호출 시 내부 write-handoff 제안을 생략한다.

## Step I-6: 후속 모드 전환 제안 [일반 모드]

이슈 생성 완료 후, 질문 도구로 사용자에게 묻는다 (메시지·옵션은 [`../references/output-templates.md`](../references/output-templates.md#for_issue-step-i-6-전환-제안-메시지) 참조). 입력 시점의 **자연어 trigger 카테고리**에 따라 첫 옵션의 권장 모드가 달라진다 (이슈 본문에 별도 marker는 추가하지 않는다 — 모드 결정은 사용자 입력의 trigger 카테고리만으로 충분).

trigger 카테고리 정의 (키워드 목록 + transition 매핑)는 [`../SKILL.md`](../SKILL.md#모드-판별)의 "자연어 trigger → transition 매핑" 표 (SSOT)를 참조한다. Step I-6은 그 표가 정한 권장 모드를 첫 옵션으로 제시한다:

- **PRD 작성 의도** → 권장: **for_prd 직접 진입** (생성된 이슈 URL + PRD 의도 결합). 또는 for_action 진입 후 Step 1-2 baseline에서 Phase ≥4 감지 시 자동 for_prd 후보 알림.
- **review-impl 의도** → 권장: **for_action 진입** (Post-Implementation 5번 Final review에서 [`../references/prd/multi-pass-review.md`](../references/prd/multi-pass-review.md)의 PRD 10-pass + [`../references/review-impl/implementation-review.md`](../references/review-impl/implementation-review.md) overlay(6-classification 라벨링 + overbuilt 우선 분류) 적용).
- **위 카테고리 매칭 없음** → 표준 for_action transition 또는 write-handoff/종료.

옵션은 모든 카테고리에서 **3개로 통일** (Codex Plan mode `request_user_input` max-3 제약):
- **Yes** → trigger 카테고리에 따라 자동 권장 모드(`for_prd <ISSUE_URL>` 또는 `for_action <ISSUE_URL>`)로 진입.
- **No (write-handoff로 마무리)** → 생성된 **이슈 URL(`ISSUE_URL`)** 을 인자로 `/write-handoff` 스킬을 실행하여 LLM 이행 가이드를 작성한 뒤 종료한다 (bare 번호 대신 URL을 전달해 write-handoff 헬퍼의 cwd 의존성을 회피).
- **No (여기서 종료)** → 생성된 이슈 URL을 반환하고 종료한다.

PRD 카테고리에서 사용자가 for_action 우회 진입을 원하면 별도 메시지로 `for_action <ISSUE_URL>`을 명시 호출하면 된다 (3-옵션 제약으로 본 prompt에는 fallback 옵션 미포함).
