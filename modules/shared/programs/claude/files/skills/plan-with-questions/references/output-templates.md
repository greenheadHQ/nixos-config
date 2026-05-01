# Output Templates

사용자에게 보여주는 메시지·체크리스트·상태 보고 템플릿. progressive disclosure로 본문에서 분리한 보일러플레이트.

## for_issue Step I-3 블랙박스 체크리스트 카테고리

체크리스트는 카테고리별로 구분한다:

- **A. 요구사항**: 해석이 여러 가지 가능한 부분
- **B. 설계 결정**: 사용자의 선호도/우선순위가 필요한 선택
- **C. 트레이드오프**: 접근법이 2개 이상인 경우
- **D. 사이드이펙트**: 사용자가 인지해야 할 영향
- **E. 기타**: 위 카테고리에 속하지 않는 사항

사용자에게 체크리스트를 보여주고, 모든 항목이 ✅가 될 때까지 또는 사용자가 "충분하다"고 판단할 때까지 스무고개를 반복한다.

## Step 4 / Step I-4 질문 패턴

- **사이드이펙트 인지 확인**: "이렇게 변경하면 ...에도 영향이 갑니다. 인지하고 계셨나요?"
- **트레이드오프 선택**: "A 방식은 ...이 장점이고, B 방식은 ...이 장점입니다. 어느 쪽을 선호하시나요?"
- **판단 기준 요청**: "이 부분은 판단 기준이 필요합니다: ..."
- **범위 확인**: "이 이슈의 범위에 ...도 포함되나요, 아니면 별도 이슈로 분리할까요?"
- **XY Problem 검증**: "해결하려는 근본 문제가 무엇인가요?"

**Step 3.5 외부 자문 결과 표시 시 anti-anchoring 규칙** (필수):

- "(Recommended)" 라벨 금지.
- 옵션 순서를 `decision_id`로 seed한 stable shuffle (같은 decision_id면 같은 순서, 다른 decision_id면 다른 순서).
- 각 옵션에 disqualifier ("틀릴 수 있는 조건") 명시.
- 옵션 보이기 전 "어떤 기준이 가장 중요한가?" 먼저 묻는 judgment-first 패턴.
- 옵션 description 중립화 — "A는 간단하고 추천" → "A는 변경 표면 작지만 후속 확장 시 재작업 가능".

상세는 [`consulting-step.md`](./consulting-step.md) 참조.

## for_issue Step I-6 전환 제안 메시지

이슈 생성 완료 후, 질문 도구로 사용자에게 묻는다. 메시지 본문과 첫 옵션은 **사용자 입력 시점의 자연어 trigger 카테고리**에 따라 달라진다.

trigger 카테고리 정의 (키워드 목록 + 권장 transition 모드)는 [`../SKILL.md`](../SKILL.md#모드-판별)의 "자연어 trigger → transition 매핑" 표 (SSOT)를 참조한다. 본 섹션은 각 카테고리의 사용자 메시지 문안과 옵션 본문만 정의한다. 모든 카테고리는 옵션을 **3개로 통일**한다 (`request_user_input`의 max-3 제약 준수).

### PRD 작성 의도 trigger 매칭 시

> "이슈 등록이 완료되었습니다. 입력에 PRD 작성 의도가 포함되어 있어, 바로 **for_prd 모드로 PRD 작성**을 시작할 수 있습니다. 어떻게 진행할까요?"

옵션 (3개):
- **Yes (for_prd 진입)** → 생성된 이슈 URL(create-issue Step 5의 `ISSUE_URL`)로 `for_prd <ISSUE_URL>` 진입.
- **No (write-handoff로 마무리)** → 이슈 URL을 인자로 `/write-handoff` 실행 후 종료.
- **No (여기서 종료)** → 이슈 URL 반환 후 종료. (사용자가 for_action 우회를 원하면 별도 메시지로 `for_action <ISSUE_URL>` 명시 호출 가능.)

### review-impl 의도 trigger 매칭 시

> "이슈 등록이 완료되었습니다. 입력에 구현 감사·문서 대비 리뷰 의도가 포함되어 있어, **for_action 모드로 진입 후 Post-Implementation 5번 Final review**에서 PRD 10-pass(`references/prd/multi-pass-review.md`) + review-impl overlay(`references/review-impl/implementation-review.md` — 6-classification 라벨링 + overbuilt 우선 분류)를 적용합니다. 어떻게 진행할까요?"

옵션 (3개):
- **Yes (for_action 진입)** → 생성된 이슈 URL로 `for_action <ISSUE_URL>` 진입.
- **No (write-handoff로 마무리)** → 이슈 URL을 인자로 `/write-handoff` 실행 후 종료.
- **No (여기서 종료)** → 이슈 URL 반환 후 종료.

### 일반 텍스트 (위 카테고리 매칭 없음)

> "이슈 등록이 완료되었습니다. 바로 for_action으로 전환하여 작업을 진행하시겠습니까?"

옵션 (3개):
- **Yes** → 생성된 이슈 URL로 `for_action <ISSUE_URL>` 진입.
- **No (write-handoff로 마무리)** → 이슈 URL을 인자로 `/write-handoff` 실행 후 종료 (bare 번호 대신 URL을 전달해 write-handoff 헬퍼의 cwd 의존성을 회피).
- **No (여기서 종료)** → 이슈 URL 반환 후 종료.

## for_prd 모드 자동 트리거 알림 메시지

자동 PRD 후보가 감지되면 1회 알림 + opt-out:

> "이 작업은 phase 추적·재개 상태가 필요해 보이는 장기 작업입니다. **Living PRD 모드**로 진행하고, 간단한 plan으로 줄이려면 알려주세요.
>
> 트리거 신호: [Phase ≥4 / 다중 도메인 / 어느 쪽인지 명시]"

옵션 (질문 도구):
- **PRD 모드로 진행 (default)** → for_prd 모드 진입.
- **간단한 plan으로** → for_action 모드 fallback.

상세는 [`task-size-routing.md`](./task-size-routing.md) 참조.

## Step 9 승인 요청 시 Post-Implementation 범위 표시

plan 파일 Step 8에 다음 중 하나를 명시 (사용자에게 노출):

- 생략 단계 없음: "Post-Implementation 1~7 자동 수행 (default)"
- 일부 생략: "Post-Implementation 자동 수행: 1~5만 (`/create-pr` 생략 — 사용자 명시 요청)"

이 항목은 승인 요청 도구 호출 시 사용자에게 노출되어 tracked write·commit·GitHub PR write 포함 자동 진행 범위에 대한 사용자 동의 근거가 된다.
