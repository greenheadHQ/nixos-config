# plan-with-questions 설계 노트 (아카이브)

`plan-with-questions` 스킬은 #810에서 완전 제거됐다. 6개월간 22개 파일·약 2,100줄로 비대해진 "프로세스를 소유하는" 오케스트레이터가 통제권을 빼앗고 버그를 낳는다는 판단(Matt Pocock의 *"don't own the process, keep control"* 철학)에 따른 결정이다. 인터뷰는 grill-me, 이슈는 create-issue, 리뷰는 run-da, PR은 create-pr로 분산하고 자동 체인은 의도적으로 포기했다.

다만 아래 3개 설계는 향후 외부 PRD/review 스킬 도입이나 다른 인터뷰 스킬 개선 시 참고 가치가 있어 **개념만** 박제한다. 실제 구현은 제거 커밋 이전 git 이력에 남아있다 (당시 경로: `modules/shared/programs/claude/files/skills/plan-with-questions/references/`).

## 1. de-anchoring 외부 자문 + 2-layer schema

**문제.** 사용자가 메인 LLM의 첫 추천에 anchor되면, 이후 검증에서 결함이 드러나도 재설계를 거부하는 패턴이 생긴다.

**설계.** 사용자에게 옵션을 제시하기 *전에* 외부 LLM(codex exec)에 옵션 평가를 위임한다. 핵심은 **입력 sanitization** — 메인 LLM의 추천·선호 표현("A가 더 간단", "B 권장")을 입력에서 제거하고, 사용자가 미이해 상태로 수락한 선택은 중립 라벨로만 표시한다. 외부 평가가 anchoring-neutral하게 보호된다.

**출력 sanity.** 외부 LLM이 점수 합산·순위·`chosen_*`/`recommended_*`/`winner` 같은 implicit choice 필드를 자체 추가해도 메인 LLM은 무시한다. 명백히 불가능한 옵션도 출력에서 제외하지 않고 "틀릴 수 있는 조건"으로 표시해, 사용자가 "왜 빠졌는지" 추측하지 않게 한다.

## 2. 2-layer 옵션 제시 UX

**문제.** 기술 평가 매트릭스를 그대로 사용자에게 보여주면 인지 부하가 크고, 도메인을 모르는 사용자는 트레이드오프를 직관하지 못한다.

**설계.** 옵션 평가를 두 layer로 분리한다.

- `technical_matrix` (메인 LLM 내부 전용): 요구충족 / 구현비용 / 되돌리기쉬움 / 운영위험 / 검증가능성 / 주요 unknown / 비용시간추정 7키. 사용자에게 절대 노출하지 않는다.
- `user_facing` (사용자 노출 전용): 평이 라벨 + 일상 비유(요리·교통·주방 등 도메인 무관) + **plain_disqualifier** — "이 옵션이 틀릴 수 있는 조건"을 기술 용어 없이 한 문장으로.

**graceful degrade.** `user_facing`이 누락되면 ① technical 필드에서 평이 설명 복구 → ② generic 비유 적용 → ③ 메인 LLM 자체 작성 → ④ 최후엔 옵션 원본 그대로 노출, 순으로 단계적으로 시도한다.

비유 예: 캐시 TTL 60초 옵션을 *"1분짜리 모래시계 — 다 떨어지면 새로 받아온다 / 데이터가 60초 안에 자주 바뀌고 사용자가 즉시 봐야 한다면 부적합"* 으로 제시.

## 3. review-impl 6-classification

**문제.** 구현이 요구사항(문서·PRD·spec)을 충족하는지 리뷰할 때 "됐다/안 됐다" 이분법은 부분 충족이나 과잉 구현을 놓친다.

**설계.** 각 requirement를 구현 상태에 6가지로 매핑한다.

| 라벨 | 의미 |
|---|---|
| satisfied | 코드 + 검증 증거로 충족 (증거 없으면 satisfied 금지) |
| partial | 일부 충족, 일부 누락 (sub-requirement로 분리 권장) |
| missing | 대응 구현 전무 |
| conflicting | 구현이 문서와 모순 (reconcile 방향 권장 필수) |
| overbuilt | 문서가 요구하지 않는 기능·추상화·상태·의존성 존재 |
| deferred | 문서가 명시적으로 미래 연기 선언 |

**핵심 원칙.**

- Evidence 우선 — 모든 분류는 파일:줄 또는 문서 인용으로 뒷받침. "느낌" 분류 금지.
- **Overbuilt 우선 판정** — 동일 코드가 partial/satisfied와 overbuilt 모두 후보면 overbuilt로 분류한다 (retrospective 증거가 더 구체적). YAGNI의 사후 버전.
- review-only — 분류는 보고만 산출, 실제 수정·체크박스 전환은 별도 승인 단계.

overbuilt 감지 신호: 요구 문서 부재, 단일 사용처인데 다방향 일반화, 가상 미래 요구용 확장점, 관찰 가능한 사용자 경로 없음, 중복 구현.
