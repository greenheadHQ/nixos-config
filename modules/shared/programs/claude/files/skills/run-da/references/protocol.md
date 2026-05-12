# DA 피드백 프로토콜

DA → Arbiter → Main Agent 상태 흐름, Arbiter 판정 프로토콜, 무한 루프 방지, 결과 기록 형식을 정의한다.

## DA → Arbiter → Main Agent 상태 흐름

| DA 결과 | Arbiter 판정 | stability_status | 메인 에이전트 행동 | 사용자 보고 |
|---------|-------------|------------------|-------------------|-----------|
| finding 있음 | CONFIRMED_ISSUE | N/A / stable (+ low_confidence_warning=false) | 자동 수정 (CRITICAL은 진행 차단) | 수정 필요 테이블 |
| finding 있음 | NOT_AN_ISSUE | N/A / stable (+ low_confidence_warning=false) | 반영 불필요 | 무해 테이블 |
| finding 있음 | NEEDS_MORE_INFO | N/A / stable | 사용자 판단 대기 | 질문 도구 |
| finding 있음 | 임의 | N/A / stable + low_confidence_warning=true | fail-closed 승격 (질문 도구 호출) | 질문 도구 + LOW confidence 이력 |
| finding 있음 | (majority verdict) | split | 사용자 판단 대기 (NEEDS_MORE_INFO 경로) | 질문 도구 + vote-shape |
| finding 있음 | — | fragmented / partial_failure / unknown | BLOCKED — 자동 수정 금지 | 질문 도구 또는 중단 보고 |
| finding 없음 | — | — | — | ALL CLEAR |

stability_status 의미, selective consistency 트리거, `unknown` sentinel 정의는 [`stability-measurement.md`](stability-measurement.md) 참조. `partial_failure`는 `fleiss-kappa.py` 출력의 top-level 플래그와 `missing`/`file_level_failures`/`per_file_malformed` 필드로 전달되며 해당 finding은 `per_finding`에 포함되지 않는다 — caller는 이를 finding별 BLOCKED로 매핑한다.

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
3. Arbiter 에이전트가 각 finding을 5가지 기준으로 독립 검증한다 ([arbiter-prompt.md](arbiter-prompt.md)). Portability는 verdict 결정권 없는 guardrail이다.
4. first-pass Arbiter 결과가 selective consistency trigger 조건([stability-measurement.md](stability-measurement.md) 참조)에 매치되면 N=3 재판정을 실행하고 vote-shape로 stability_status를 결정한다. 자세한 상태 전이는 아래 "Selective consistency 상태 전이" 참조.
5. 메인 에이전트는 사용자에게 전건 보고한다 (vote-shape가 있으면 함께 보고).
6. CONFIRMED_ISSUE + (stability_status=N/A 또는 stable) 항목을 자동 수정한다 (CRITICAL은 즉시, 진행 차단).
7. NEEDS_MORE_INFO 또는 stability_status=split 항목은 사용자 판단을 요청한다.
8. stability_status=fragmented 항목은 BLOCKED 상태로 기록하고 자동 수정하지 않는다 (아래 섹션 참조).

### Arbiter 출력 요건

- 각 finding에 대해 사람용 markdown 블록(verdict, 신뢰도, 5가지 기준 평가, stability_status, 근거)과 기계 파싱용 VERDICT_JSON 블록을 둘 다 반환한다. 형식은 [`arbiter-prompt.md`](arbiter-prompt.md)의 "출력 형식" 섹션 참조.
- VERDICT_JSON 블록은 selective consistency harness(`fleiss-kappa.py`)가 파싱한다. 사람용 markdown wording이 변해도 JSON 스키마는 유지되어야 한다.
- NOT_AN_ISSUE 판정에는 직접 확인 + 반증 근거가 필수다 (모드별 상세: [`arbiter-prompt.md`](arbiter-prompt.md) 참조).
- LOW 신뢰도 NOT_AN_ISSUE는 자동으로 NEEDS_MORE_INFO로 승격된다.
- LOW 신뢰도, NEEDS_MORE_INFO, 이전 outer round 반복 finding은 selective consistency N=3 재판정 trigger 조건이다. trigger 상세는 [`stability-measurement.md`](stability-measurement.md) 참조.

### Selective consistency 상태 전이

first-pass Arbiter 결과가 trigger 조건에 매치되면 동일 입력으로 N=3 재판정을 실행한다. `fleiss-kappa.py`가 VERDICT_JSON 블록 3개에서 vote-shape를 계산하여 stability_status를 채운다. vote-shape 분류 정의는 [`stability-measurement.md`](stability-measurement.md)의 "v1 정책: vote-shape 기반 selective consistency" 섹션이 단일 진실 원천이다.

상태 전이:

| stability_status | majority verdict | low_confidence_warning | 메인 에이전트 행동 |
|------------------|------------------|------------------------|-------------------|
| `stable` (3:0) | unanimous verdict | `false` | 기존 경로 (CONFIRMED→수정, NOT_AN_ISSUE→무해, NEEDS_MORE_INFO→질문 도구) |
| `stable` (3:0) | unanimous verdict | `true` | fail-closed 승격: NEEDS_MORE_INFO 경로로 사용자 판단 요청. unanimous이어도 어떤 Arbiter가 LOW confidence를 보고했으면 기존 "LOW confidence NOT_AN_ISSUE 자동 NEEDS_MORE_INFO 승격" 계약을 유지한다. fleiss-kappa.py 출력의 `low_confidence_warning`/`min_confidence` 필드로 전달된다. |
| `split` (2:1) | majority verdict (정보 표시) | any | NEEDS_MORE_INFO 경로로 사용자 판단 요청. vote-shape와 minority verdict도 함께 보고. |
| `fragmented` (1:1:1) | — | any | BLOCKED. 질문 도구 지원 런타임: 사용자에게 판단 요청 (비유법 설명 포함). 질문 도구 미지원 런타임: 자동 승격 금지, 중단 보고 후 명시적 rerun 전에는 재개하지 않음. |

질문 도구 미지원 런타임 주의: 기존 "NEEDS_MORE_INFO 자동 CONFIRMED_ISSUE 승격" 규칙은 first-pass single Arbiter 판정에만 적용된다. selective consistency에서 나온 `split`/`fragmented`는 이 자동 승격 경로를 따르지 않는다 — fragmented는 BLOCKED, split는 명시적 rerun 대기. 상세는 [`arbiter-scaling.md`](arbiter-scaling.md)의 "질문 도구 미지원 대응" 섹션 참조.

Threshold 숫자는 이 문서에서 재서술하지 않는다. `STABLE_MIN`/`ESCALATE_MIN` 값과 vote-shape 분류 규칙은 [`stability-measurement.md`](stability-measurement.md)가 단일 진실 원천이다.

## Reviewer output propagation

기본 propagation은 all-to-all broadcast가 아니라 selective propagation이다.
`run-da`의 기본 FULL path가 4 reviewer bundle로 줄어든 뒤에도, 비용 절감 효과를 유지하려면
후속 라운드와 Arbiter 입력을 선택적으로 좁혀야 한다.

### 전달 원칙

- Arbiter나 next-round reviewer에게 모든 reviewer 원문/모든 CLEAR 결과/모든 저신호 finding을 전달하지 않는다.
- 기본 전달 대상은 다음 네 종류다:
  - unique findings
  - conflicting findings
  - high-severity findings
  - user decision required findings
- minority finding이라도 구체적 파일:줄 근거가 있고 high-confidence/high-severity면 유지한다.
- 이미 해결된 finding, 중복 low-severity finding, 다른 bundle과 무관한 CLEAR transcript는 전달하지 않는다.

### 적용 위치

- Arbiter 입력: reviewer 원문 전체가 아니라, 위 규칙으로 추린 escalated finding set만 전달한다.
- 후속 reviewer 입력: 다음 라운드에서도 raw transcript 전체를 브로드캐스트하지 않는다.
  열려 있는 finding 중 해당 bundle에 실질적으로 관련된 항목만 전달한다.
- `fresh` modifier: selective propagation조차 끊는다. 이전 라운드 맥락을 전달하지 않는다.
- `full` modifier: reviewer fan-out만 exhaustive로 확장할 뿐, propagation 기본값은 여전히 selective다.

## 합리화 방지 (Rationalization Prevention)

DA 피드백 루프 자체를 건너뛰려는 합리화를 차단한다.
아래 생각이 떠오르면, 그것이 바로 DA가 필요한 신호이다.
SKILL.md 상단의 경고 헤딩도 참조하라.

> "기각 금지" 섹션은 DA 진행 중 개별 지적의 기각 사유를 제한하고,
> 이 섹션은 DA 실행 여부 자체의 합리화를 차단한다. 범위가 다르다.

| 합리화 패턴 | 왜 틀렸는가 |
|---|---|
| "이건 단순한 수정이라 DA가 필요 없다" | 단순한 수정에서 가장 많은 사이드이펙트가 발생한다. Review Intensity 판단은 너의 자유 추론이 아니다 — `intensity-rules.md`의 룰 표를 기계적 체크리스트로 적용해야 한다(모든 룰 평가 + first-match 채택). 예외: 체크리스트가 SKIP을 판정하고, 사용자가 질문 도구로 승인한 경우만 합리화가 아니다. 체크리스트 표를 생략한 생략 시도는 여전히 금지한다. |
| "이미 충분히 검토했다" | 너의 검토와 독립 Arbiter 검증은 다르다. 확증 편향은 자기 검토에서 가장 강하다. 그래서 독립 Arbiter 에이전트가 있다 |
| "사용자가 빨리 하라고 했다" | 사용자 지시는 DA 면제 근거가 아니다. 품질은 비협상적이다 |
| "설정값 변경뿐이다" | 소량 설정 변경이 빌드 병목, 서비스 중단, OOM을 유발할 수 있다. `intensity-rules.md`의 `RULE-CONFIG-DEPENDENCY`는 강한 검토(FULL)로 라우팅한다 |
| "코드 양이 적다" | 변경 분량과 영향 범위는 무관하다. NixOS 설정 한 줄이 시스템 전체에 파급될 수 있다. 체크리스트 평가에서 변경 분량을 근거로 fail-closed rule group(보안/모듈/설정·의존성)을 우회하지 마라 |
| "테스트가 통과했으니 괜찮다" | 테스트는 작성된 시나리오만 검증한다. DA는 미작성 시나리오를 찾는다 |

글자를 어기는 것이 정신을 어기는 것이다. 위 패턴의 변형/우회도 동일하게 금지한다.

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

동일한 지적(세부 관점 + 위치(파일:줄 또는 계획 항목 번호) 기준)이 3회 연속 outer round에서 반복되면:

1. 해당 지적과 이전 라운드의 Arbiter 판정 이력을 요약한다.
2. 사용자에게 질문 도구로 3가지 선택지를 제시한다:
   - 수용: 지적대로 수정한다.
   - 제외 + 근거 기록: 기술적 근거를 CIR로 남기고 현재 루프에서 제외한다.
   - 보류: 별도 이슈로 등록하고 현재 루프에서 제외한다.

Selective consistency 서브런 카운팅: selective consistency의 N=3 재판정은 동일 outer round 내부의 서브런이다. 3회 반복 규칙과 최대 라운드 카운트에 포함하지 않는다. 즉, outer round 1에서 N=3 재판정을 수행해도 outer round 카운트는 1에 머문다.

### 최대 라운드 수

명시적 제한은 두지 않되, 5회 outer round 이후에도 CLEAR에 도달하지 못하면
사용자에게 현황을 보고하고 계속 진행 여부를 확인한다. selective consistency 서브런은 outer round 카운트에 포함하지 않는다.

## 라운드 요약 기록

각 라운드 종료 시 DA 발견 수와 Arbiter 판정 결과를 요약한다:

```text
Round N 요약: DA 발견 X건 → Arbiter: CONFIRMED Y건, NOT_AN_ISSUE Z건, NEEDS_MORE_INFO W건
bundle별: Correctness 2건(SECURITY 1, HALLUCINATION 1), Regression CLEAR, ...
```

selective consistency가 발동한 라운드는 추가 라인으로 stability_status 분포를 명시한다:

```text
selective: trigger P건 → stable Q건, split R건, fragmented S건, partial_failure T건
```

`split`/`fragmented`/`partial_failure` 항목은 0이 아닐 때만 나열해도 된다. 위 verdict 카운트(Y/Z/W)에서 `split`은 NEEDS_MORE_INFO로, `fragmented`/`partial_failure`는 BLOCKED로 집계된다. stability_status 정의는 [`stability-measurement.md`](stability-measurement.md) 참조.

## 탈출 조건

다음을 모두 충족하면 DA 루프를 종료한다:

1. 선택된 reviewer 모두 CLEAR: 실행된 모든 reviewer bundle 또는 세부 도메인에서 위반 미발견 (`NOT_RUN` 제외).
2. 미처리 항목 0건: NEEDS_MORE_INFO 상태의 finding이 없다.
3. NOT_AN_ISSUE/제외 항목 근거 완비: Arbiter가 NOT_AN_ISSUE로 판정하거나 사용자가 제외한 항목에 모두 근거가 있다.

## PR 코멘트 게시 형식

DA 피드백 루프가 완료되면 결과를 PR 코멘트로 게시한다 (PR 본문에는 박지 않는다 — `create-pr/SKILL.md`의 `DA 피드백 분리` 정책 참조):

```markdown
## DA Feedback Summary

| Round | DA Found | Confirmed | Not Issue | Needs Info | Blocked | Fixed |
|-------|----------|-----------|-----------|------------|---------|-------|
| R1    | 5        | 3         | 1         | 1          | 0       | 0     |
| R2    | 1        | 1         | 0         | 0          | 0       | 4     |
| R3    | 0        | —         | —         | —          | —       | 1     |

**Review Intensity**: FULL (or LITE — see below) — 메인 LLM 인라인 체크리스트 결과.
**Result**: ALL CLEAR after 3 rounds

<details>
<summary>Round details</summary>

### Round 1
- Correctness: 3건 (`HALLUCINATION` CONFIRMED 1, `SECURITY` CONFIRMED 1, `SECURITY` NOT_AN_ISSUE 1)
- Design: CLEAR
- Regression: 1건 (`SIDE_EFFECT` NEEDS_MORE_INFO 1) → 사용자 판단: 수용 → R2에서 fixed
- Maintainability: 1건 (`READABILITY` CONFIRMED 1) → R2에서 fixed
- selective: trigger 1건 → split 1 (vote-shape 2:1, minority=NOT_AN_ISSUE)  ← 선택: selective consistency가 발동된 라운드에만 이 줄을 적음

### Round 2
...

</details>
```

컬럼 매핑:
- `Needs Info`: `verdict=NEEDS_MORE_INFO` 또는 `stability_status=split` (split는 질문 도구 필수로 분류).
- `Blocked`: `stability_status=fragmented` 또는 partial_failure. [`stability-measurement.md`](stability-measurement.md) 참조.

LITE 실행 시 `Result` 행은 `ALL SELECTED CLEAR (NOT_RUN: Design, ...)`로 표기하고,
Round details에도 각 reviewer bundle의 `NOT_RUN` 상태를 명시한다.
