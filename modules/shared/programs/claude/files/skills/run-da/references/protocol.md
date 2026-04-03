# DA 피드백 프로토콜

DA → Arbiter → Main Agent 상태 흐름, Arbiter 판정 프로토콜, 무한 루프 방지, 결과 기록 형식을 정의한다.

## DA → Arbiter → Main Agent 상태 흐름

| DA 결과 | Arbiter 판정 | 메인 에이전트 행동 | 사용자 보고 |
|---------|-------------|-------------------|-----------|
| finding 있음 | CONFIRMED_ISSUE | 자동 수정 (CRITICAL은 진행 차단) | 수정 필요 테이블 |
| finding 있음 | NOT_AN_ISSUE | 반영 불필요 | 무해 테이블 |
| finding 있음 | NEEDS_MORE_INFO | 사용자 판단 대기 | AskUserQuestion |
| finding 없음 | — | — | ALL CLEAR |

### 기존 용어 매핑

| 기존 | 신규 대응 |
|------|----------|
| 발견(Discovered) | DA findings 개수 |
| 해결(Resolved) | CONFIRMED_ISSUE → 수정 완료 |
| 기각(Rejected) | NOT_AN_ISSUE (Arbiter 판정) |
| 보류(Deferred) | NEEDS_MORE_INFO → 사용자 결정 |

## Arbiter 판정 프로토콜

### 판정 흐름

1. DA 에이전트가 findings를 반환한다 (각 finding에 보고용 ID 포함).
2. findings 개수에 따라 Arbiter 수를 결정한다 ([arbiter-scaling.md](arbiter-scaling.md)).
3. Arbiter 에이전트가 각 finding을 4가지 기준으로 독립 검증한다 ([arbiter-prompt.md](arbiter-prompt.md)).
4. 메인 에이전트는 사용자에게 전건 보고한다.
5. CONFIRMED_ISSUE 항목을 자동 수정한다 (CRITICAL은 즉시, 진행 차단).
6. NEEDS_MORE_INFO 항목은 사용자 판단을 요청한다.

### Arbiter 출력 요건

- 각 finding에 대해 verdict, 신뢰도, 4가지 기준 평가, 근거를 반환한다.
- NOT_AN_ISSUE 판정에는 직접 확인 + 반증 근거가 필수다 (모드별 상세: [arbiter-prompt.md](arbiter-prompt.md) 참조).
- LOW 신뢰도 NOT_AN_ISSUE는 자동으로 NEEDS_MORE_INFO로 승격된다.

## Reviewer output propagation

기본 propagation은 **all-to-all broadcast가 아니라 selective propagation**이다.
`run-da`의 기본 FULL path가 4 reviewer bundle로 줄어든 뒤에도, 비용 절감 효과를 유지하려면
후속 라운드와 Arbiter 입력을 선택적으로 좁혀야 한다.

### 전달 원칙

- Arbiter나 next-round reviewer에게 **모든 reviewer 원문/모든 CLEAR 결과/모든 저신호 finding**을 전달하지 않는다.
- 기본 전달 대상은 다음 네 종류다:
  - unique findings
  - conflicting findings
  - high-severity findings
  - user decision required findings
- minority finding이라도 구체적 파일:줄 근거가 있고 high-confidence/high-severity면 유지한다.
- 이미 해결된 finding, 중복 low-severity finding, 다른 bundle과 무관한 CLEAR transcript는 전달하지 않는다.

### 적용 위치

- **Arbiter 입력**: reviewer 원문 전체가 아니라, 위 규칙으로 추린 escalated finding set만 전달한다.
- **후속 reviewer 입력**: 다음 라운드에서도 raw transcript 전체를 브로드캐스트하지 않는다.
  열려 있는 finding 중 해당 bundle에 실질적으로 관련된 항목만 전달한다.
- **`fresh` modifier**: selective propagation조차 끊는다. 이전 라운드 맥락을 전달하지 않는다.
- **`full` modifier**: reviewer fan-out만 exhaustive로 확장할 뿐, propagation 기본값은 여전히 selective다.

## 합리화 방지 (Rationalization Prevention)

DA 피드백 루프 **자체를 건너뛰려는** 합리화를 차단한다.
아래 생각이 떠오르면, 그것이 바로 DA가 필요한 신호이다.
SKILL.md 상단의 경고 헤딩도 참조하라.

> "기각 금지" 섹션은 DA 진행 중 개별 지적의 기각 사유를 제한하고,
> 이 섹션은 DA 실행 여부 자체의 합리화를 차단한다. 범위가 다르다.

| 합리화 패턴 | 왜 틀렸는가 |
|---|---|
| "이건 단순한 수정이라 DA가 필요 없다" | 단순한 수정에서 가장 많은 사이드이펙트가 발생한다. Review Intensity 판단은 너의 역할이 아니다 — 독립 에이전트가 수행한다. **예외**: 독립 에이전트가 SKIP을 판정하고, 사용자가 AskUserQuestion으로 승인한 경우만 합리화가 아니다. 독립 에이전트를 거치지 않은 생략 시도는 여전히 금지한다. |
| "이미 충분히 검토했다" | 너의 검토와 독립 검증은 다르다. 확증 편향은 자기 검토에서 가장 강하다. 그래서 독립 에이전트가 있다 |
| "사용자가 빨리 하라고 했다" | 사용자 지시는 DA 면제 근거가 아니다. 품질은 비협상적이다 |
| "설정값 변경뿐이다" | 소량 설정 변경이 빌드 병목, 서비스 중단, OOM을 유발할 수 있다. 독립 에이전트가 SKIP/LITE/FULL을 판단한다 |
| "테스트가 통과했으니 괜찮다" | 테스트는 작성된 시나리오만 검증한다. DA는 미작성 시나리오를 찾는다 |

**글자를 어기는 것이 정신을 어기는 것이다.** 위 패턴의 변형/우회도 동일하게 금지한다.

## PoC/레퍼런스 의무화 규칙

### DA 에이전트 의무

DA 에이전트가 위반을 지적할 때 반드시 다음 중 하나를 제시해야 한다:

| 유형 | 형식 | 예시 |
|------|------|------|
| 코드 위치 | `파일:줄` | `modules/darwin/default.nix:42` |
| 계획 항목 | `계획 Step N` | `계획 Step 3의 "캐시 무효화" 부분` |
| 재현 시나리오 | 입력 → 기대 → 실제 | "빈 리스트 입력 시 NPE 발생" |
| 레퍼런스 | 공식 문서/RFC 링크 | "Nix manual Section 15.1에 따르면..." |

증거 없이 "~할 수도 있다" 수준의 지적은 Arbiter가 NOT_AN_ISSUE(실행 가능성 FAIL)로 판정한다.

### Arbiter 검증 후 수정 의무

Arbiter가 CONFIRMED_ISSUE로 판정한 항목을 수정할 때:

- 수정 전 해당 위치(for_pr: 파일:줄 / for_plan: 관련 파일 또는 계획 항목)를 직접 확인한다 (수정 작업의 일부).
- 수정한 코드/계획의 diff를 명시한다.
- 수정 결과가 finding을 해결하는지 확인한다.

## 무한 루프 방지

### 3회 반복 규칙

동일한 지적(세부 관점 + 위치(파일:줄 또는 계획 항목 번호) 기준)이 3회 연속 라운드에서 반복되면:

1. 해당 지적과 이전 라운드의 Arbiter 판정 이력을 요약한다.
2. 사용자에게 AskUserQuestion으로 3가지 선택지를 제시한다:
   - **수용**: 지적대로 수정한다.
   - **제외 + 근거 기록**: 기술적 근거를 CIR로 남기고 현재 루프에서 제외한다.
   - **보류**: 별도 이슈로 등록하고 현재 루프에서 제외한다.

### 최대 라운드 수

명시적 제한은 두지 않되, 5회 라운드 이후에도 CLEAR에 도달하지 못하면
사용자에게 현황을 보고하고 계속 진행 여부를 확인한다.

## 라운드 요약 기록

각 라운드 종료 시 DA 발견 수와 Arbiter 판정 결과를 요약한다:

```text
Round N 요약: DA 발견 X건 → Arbiter: CONFIRMED Y건, NOT_AN_ISSUE Z건, NEEDS_MORE_INFO W건
bundle별: Correctness 2건(SECURITY 1, HALLUCINATION 1), Regression CLEAR, ...
```

## 탈출 조건

다음을 모두 충족하면 DA 루프를 종료한다:

1. **선택된 reviewer 모두 CLEAR**: 실행된 모든 reviewer bundle 또는 세부 도메인에서 위반 미발견 (`NOT_RUN` 제외).
2. **미처리 항목 0건**: NEEDS_MORE_INFO 상태의 finding이 없다.
3. **NOT_AN_ISSUE/제외 항목 근거 완비**: Arbiter가 NOT_AN_ISSUE로 판정하거나 사용자가 제외한 항목에 모두 근거가 있다.

## PR 코멘트 게시 형식

DA 피드백 루프가 완료되면 PR 본문 또는 코멘트에 결과를 게시한다:

```markdown
## DA Feedback Summary

| Round | DA Found | Confirmed | Not Issue | Needs Info | Fixed |
|-------|----------|-----------|-----------|------------|-------|
| R1    | 5        | 3         | 1         | 1          | 0     |
| R2    | 1        | 1         | 0         | 0          | 4     |
| R3    | 0        | —         | —         | —          | 1     |

**Intensity**: FULL (or LITE — see below)
**Result**: ALL CLEAR after 3 rounds

<details>
<summary>Round details</summary>

### Round 1
- Correctness: 3건 (`HALLUCINATION` CONFIRMED 1, `SECURITY` CONFIRMED 1, `SECURITY` NOT_AN_ISSUE 1)
- Design: CLEAR
- Regression: 1건 (`SIDE_EFFECT` NEEDS_MORE_INFO 1) → 사용자 판단: 수용 → R2에서 fixed
- Maintainability: 1건 (`READABILITY` CONFIRMED 1) → R2에서 fixed

### Round 2
...

</details>
```

LITE 실행 시 `Result` 행은 `ALL SELECTED CLEAR (NOT_RUN: Design, ...)`로 표기하고,
Round details에도 각 reviewer bundle의 `NOT_RUN` 상태를 명시한다.
