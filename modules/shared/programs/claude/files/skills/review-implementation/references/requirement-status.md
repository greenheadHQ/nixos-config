# Requirement Status Classification

`review-implementation` 스킬이 문서(PRD/phase/spec)의 각 requirement를 실제 구현 상태와 매핑할 때 사용하는 6분류 정의와 classification 룰.

## 6-분류 정의

| 라벨 | 정의 | 전형적 증거 | 권장 action |
|---|---|---|---|
| **satisfied** | 요구사항이 코드 + evidence로 충족됨 | 파일:줄 인용 + test/실행 증거 | 체크박스 `- [x]`로 전환 (fix 모드, validation 성공 시). 없으면 보고만. |
| **partial** | 요구사항의 일부가 충족, 일부 누락 | 충족 부분 + 미충족 부분을 각각 파일:줄로 구분 | 누락 부분 구현 또는 sub-requirement 분리 |
| **missing** | 요구사항에 대응하는 구현이 전혀 없음 | 관련 경로/파일에 해당 로직 부재 | fix 모드: 구현 추가 / review-only: 누락 보고 |
| **conflicting** | 구현이 문서와 모순 (잘못 동작 또는 반대 동작) | 문서 인용 + 모순되는 코드 인용 | fix 모드: 문서 또는 코드 중 어느 쪽이 정답인지 확인 후 정렬 |
| **overbuilt** | 문서가 요구하지 않는 기능/추상화/상태/의존성이 존재 | 해당 코드 위치 + "이를 요구하는 문서 섹션 없음" 증명 | fix 모드: 제거 또는 문서에 근거 추가 / review-only: 보고 |
| **deferred** | 요구사항이 의도적으로 미래 phase로 연기 | 문서에 명시적 "deferred"/"follow-up" 언급 또는 validator 판단 | 상태 유지. `follow-up` 섹션에 기록 |

## Classification 룰

1. **Evidence 우선**: 모든 분류는 파일:줄 인용 또는 문서 인용으로 뒷받침한다. "느낌" 기반 분류 금지.
2. **Satisfied는 엄격하게**: validation(Step 5) 성공 증거가 없으면 `satisfied`로 분류하지 않는다. 최소한 구현 존재 + 테스트 실행 결과 중 하나 필요.
3. **Partial은 세분화**: `partial`이 많아지면 원본 requirement를 sub-requirement로 쪼개 classification 품질을 높인다.
4. **Missing vs Deferred**: 문서가 명시적으로 연기를 선언한 경우에만 `deferred`. 그 외 미구현은 `missing`.
5. **Conflicting은 reconcile 필수**: 코드와 문서 중 무엇이 진실인지 결정 없이 `conflicting`을 남기면 안 된다. fix 모드는 "정답" 쪽으로 정렬하고 reconcile 경로를 report에 기록.
6. **Overbuilt 우선 판정**: 동일 코드가 `partial`/`satisfied`와 `overbuilt` 모두 후보면 `overbuilt`로 분류한다 (retrospective 증거가 더 구체적).

## Overbuilt 감지 체크리스트

다음 항목 중 하나라도 yes면 `overbuilt` 후보:

- [ ] 해당 기능/추상화/상태/의존성을 **요구하는 문서 섹션을 찾을 수 없다**.
- [ ] 현재 사용처가 하나뿐인데 인터페이스가 다방향 일반화되어 있다.
- [ ] 가상의 미래 요구사항을 위해 추가된 확장점 (YAGNI 역방향).
- [ ] 구현 자체는 동작하나 해당 기능에 대한 **관찰 가능한 사용자 경로가 없다**.
- [ ] 문서가 요구하지 않는 별도 workflow/서비스/DB 컬럼이 추가되어 있다.
- [ ] 중복된 구현 (동일 기능을 하는 기존 함수/유틸이 이미 존재).

해당 시 "왜 overbuilt인가"를 파일:줄 + "이를 요구하는 문서 섹션 부재"로 함께 기술한다.

## `review-pr-feedback` 기각 라벨과의 축 구분

`review-pr-feedback`의 기각 분류(`HALLUCINATION`, `STALE_REVIEW`, `DUPLICATE_CONCERN`, `OUT_OF_SCOPE` 등)는 **리뷰어의 지적이 왜 기각되는가**를 나타낸다. 본 스킬의 6분류는 **requirement가 문서 대비 어떤 상태인가**를 나타낸다.

두 축은 혼용하지 않는다. 동일 이슈가 양쪽에서 보이면:

- `review-implementation`의 출력은 `satisfied/partial/missing/conflicting/overbuilt/deferred` 중 하나.
- `review-pr-feedback`의 기각 라벨은 리뷰 코멘트 처리 시점에만 사용.

## `run-da` Design bundle YAGNI와 overbuilt 구분

| 축 | 시점 | 입력 | 판정 기준 |
|---|---|---|---|
| `run-da` Design bundle YAGNI | **Prospective** (구현 전/중) | 계획, diff | "지금 필요하지 않은 복잡성을 도입하고 있는가?" |
| `review-implementation` overbuilt | **Retrospective** (구현 후) | 구현 + 문서 | "이미 구현된 것이 문서의 어떤 requirement에도 매핑되지 않는가?" |

동일 이슈가 양쪽 축에서 포착되면 **overbuilt 우선** (retrospective 증거가 더 구체적). run-da에서 이미 YAGNI로 기각·수정된 항목이 이후 `overbuilt`로 다시 나오면 reconcile 기록 (보통 앞 단계의 기각이 잘못된 경우이므로 재평가).

## Report 내 표기

```markdown
### Requirement: FR-3 — "세션 이력 내보내기"
- **상태**: partial
- **증거**:
  - 충족: `src/export/session.ts:42-78` — JSON export 구현
  - 누락: CSV export (FR-3의 "다중 형식 지원" 조항이 언급)
- **권장**: CSV export 구현 추가 또는 FR-3 scope 축소 결정
```

`[UNVERIFIED]` / `[INFERRED]` / `[CONFLICTING]` 라벨은 evidence 수준을 나타낸다 (정본: `../../write-handoff/references/llm-friendly-checklist.md`). 6분류는 requirement status 축이므로 두 축을 함께 쓴다 — 예: `partial [INFERRED]` = "부분 충족으로 보이나 증거가 근접 추론 수준이다".
