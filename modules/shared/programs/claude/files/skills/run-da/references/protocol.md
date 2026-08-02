# DA 피드백 프로토콜

DA → Arbiter → Main Agent 상태 흐름, Arbiter 판정 프로토콜, 무한 루프 방지, 결과 기록 형식을 정의한다.

## DA → Arbiter → Main Agent 상태 흐름

| DA 결과 | Arbiter 판정 | stability_status | 메인 에이전트 행동 | 사용자 보고 |
|---------|-------------|------------------|-------------------|-----------|
| finding 있음 | CONFIRMED_ISSUE | N/A / stable (+ low_confidence_warning=false) | pending write queue에 추가. write phase에서 일괄 수정 (CRITICAL은 다음 round 진행 차단) | 수정 필요 테이블 |
| finding 있음 | NOT_AN_ISSUE | N/A / stable (+ low_confidence_warning=false) | 반영 불필요. eligible 항목은 dismissal ledger에 기록 | 무해 테이블 |
| finding 있음 | NEEDS_MORE_INFO | N/A / stable | 사용자 판단 대기 | 질문 도구 |
| finding 있음 | 임의 | N/A / stable + low_confidence_warning=true | fail-closed 승격 (질문 도구 호출) | 질문 도구 + LOW confidence 이력 |
| finding 있음 | (majority verdict) | split | 사용자 판단 대기 (NEEDS_MORE_INFO 경로) | 질문 도구 + vote-shape |
| finding 있음 | — | fragmented / partial_failure / unknown | BLOCKED — 자동 수정 금지 | 질문 도구 또는 중단 보고 |
| finding 없음 | — | — | — | ALL CLEAR (수렴 종료의 특수형 — `walkthrough_status=NOT_REQUIRED`) |
| 이번 라운드 반영 항목 전부 LOW (accepted severity 기준) | CONFIRMED_ISSUE | N/A / stable | write phase 반영 후 수렴 predicate 평가 (아래 "수렴 판정"이 SSOT — walkthrough 후속 수정·최종 delta Intensity 재평가에 따라 재검증이 강제될 수 있다) | predicate 충족 시 CONVERGED 보고 |

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
3. Arbiter 에이전트가 각 finding을 판정 기준([arbiter-prompt.md](arbiter-prompt.md)의 "판정 기준" 섹션이 기준 목록의 단독 소유자)으로 독립 검증한다. Portability는 verdict 결정권 없는 guardrail이다.
4. first-pass Arbiter 결과가 selective consistency trigger 조건([stability-measurement.md](stability-measurement.md) 참조)에 매치되면 N=3 재판정을 실행하고 vote-shape로 stability_status를 결정한다. 자세한 상태 전이는 아래 "Selective consistency 상태 전이" 참조.
5. 메인 에이전트는 사용자에게 전건 보고한다 (vote-shape가 있으면 함께 보고).
6. CONFIRMED_ISSUE + (stability_status=N/A 또는 stable) 항목을 pending write queue에 추가한다. CRITICAL은 진행 차단 항목으로 표시하되 review phase 중 즉시 patch하지 않는다.
7. NEEDS_MORE_INFO 또는 stability_status=split 항목은 사용자 판단을 요청한다. 사용자가 수용한 항목만 pending write queue에 추가한다.
8. stability_status=fragmented 항목은 BLOCKED 상태로 기록하고 자동 수정하지 않는다 (아래 섹션 참조).
9. NOT_AN_ISSUE 또는 사용자가 명시적으로 제외한 eligible 항목은 [`dismissal-ledger.md`](dismissal-ledger.md)에 따라 local ignored dismissal ledger에 기록한다. 이 기록은 active changeset 수정이나 pending write queue가 아니다.
10. Arbiter 상태 전이와 필요한 사용자 판단이 끝난 뒤 write phase로 넘어가 pending write queue를 batch로 반영한다.

### 라운드 read/write 분리

각 outer round는 frozen changeset을 대상으로 한 review phase와, Arbiter 판정 후의 write phase를 분리한다.

- changeset 동결: outer round 시작 시 검토 표면을 고정한다. for_plan은 계획 원문과 관련 파일/맥락, for_pr은 `git diff main...HEAD`와 현재 workspace 상태가 frozen changeset이다.
- review phase 범위: reviewer 실행, reviewer 결과 수집, Arbiter 실행, selective consistency N=3, vote-shape 집계, 전건 보고, 질문 도구 판단 수집까지다.
- review phase 중 patch 금지: 이 구간에는 active changeset을 바꾸는 patch/edit/apply_patch, write-mode formatter, codegen/regeneration으로 생기는 generated output 변경, lockfile 재생성, commit/push를 금지한다. check-only formatter나 diff-only generator처럼 파일 변경이 없으면 허용한다. delegated reviewer/Arbiter의 read-only/no-write 경계는 [`hardening-contract.md`](hardening-contract.md)가 정본이다.
- dismissal ledger 기록: Arbiter 상태 전이와 사용자 전건 보고가 끝난 직후 메인 에이전트가 쓰는 local ignored review metadata다. write phase 산출물이 아니며 pending write queue에 넣지 않는다. ledger write가 tracked diff를 만들면 기록하지 않고 NOTES에 남긴다. 세부 규칙은 [`dismissal-ledger.md`](dismissal-ledger.md)가 정본이다.
- 일괄 수정: CONFIRMED_ISSUE와 사용자가 수용한 NEEDS_MORE_INFO/`split` 항목은 pending write queue에 모아 write phase에서 메인 에이전트가 batch로 반영한다. 정상 confirmed finding 반영을 막는 규칙이 아니라 반영 시점을 라운드 밖으로 옮기는 규칙이다.
- write phase는 통합 반영 루프다: write phase는 "개별 finding 패치의 나열"이 아니라 `통합 설계 → batch 반영 → walkthrough → 후속 수정 처리 → finalize` 순서의 단일 루프로 수행한다. 각 finding을 국소 패치로 덧대면 수용 자체가 만드는 사이드이펙트를 놓친다 — 반영 전 대상 전체를 통독해 finding 간 상호작용과 기존 구조와의 모순을 점검하고, 하나의 통합 변경 설계를 세운 뒤 반영한다. 반영 후에는 수정된 대상을 처음 읽는 사람처럼 순서대로 따라 실행하는 walkthrough 자가 검증을 수행한다. 단계별 상세 절차는 [`../modes/for_plan.md`](../modes/for_plan.md)의 write phase가 정본이다.
- CRITICAL 기본값: CRITICAL finding만 즉시 중단/수정하는 예외는 기본 절차에 두지 않는다. CRITICAL은 다음 outer round 진입을 차단하고, 현재 round의 Arbiter 판정이 닫힌 뒤 write phase 첫 batch 항목으로 반영한다.
- 새 changeset: write phase 후 다음 outer round를 시작하면 "새 changeset" 리뷰로 명시한다. 이전 round의 frozen changeset과 write phase batch delta를 round summary에 기록해 추세 기반 조기 중단의 신규 confirmed finding 계산 기준을 분리한다.
- audit 모드와의 용어 정합: for_plan/for_pr는 read/write phase를 가진 반복 개선 루프이고, audit 모드는 같은 changeset을 일회성 read-only로 검증하는 감사다. 감사는 "`SAFE`까지" 자동 반복 재발사하지 않는다.

### Arbiter 출력 요건

- 각 finding에 대해 사람용 markdown 블록(verdict, 신뢰도, 판정 기준 평가, stability_status, 근거)과 기계 파싱용 VERDICT_JSON 블록(`accepted_severity`·`axes.plausibility` 포함)을 둘 다 반환한다. 형식은 [`arbiter-prompt.md`](arbiter-prompt.md)의 "출력 형식" 섹션 참조.
- VERDICT_JSON 블록은 selective consistency harness(`fleiss-kappa.py`)가 파싱한다. 사람용 markdown wording이 변해도 JSON 스키마는 유지되어야 한다.
- NOT_AN_ISSUE 판정에는 직접 확인 + 반증 근거가 필수다 (모드별 상세: [`arbiter-prompt.md`](arbiter-prompt.md) 참조).
- LOW 신뢰도 NOT_AN_ISSUE는 자동으로 NEEDS_MORE_INFO로 승격된다.
- LOW 신뢰도, NEEDS_MORE_INFO, 이전 outer round 반복 finding은 selective consistency N=3 재판정 trigger 조건이다. trigger 상세는 [`stability-measurement.md`](stability-measurement.md) 참조.

### Selective consistency 상태 전이

first-pass Arbiter 결과가 trigger 조건에 매치되면 동일 입력으로 N=3 재판정을 실행한다. `fleiss-kappa.py`가 VERDICT_JSON 블록 3개에서 vote-shape를 계산하여 stability_status를 채운다. vote-shape 분류 정의는 [`stability-measurement.md`](stability-measurement.md)의 "v1 정책: vote-shape 기반 selective consistency" 섹션이 단일 진실 원천이다.

상태 전이:

| stability_status | majority verdict | low_confidence_warning | 메인 에이전트 행동 |
|------------------|------------------|------------------------|-------------------|
| `stable` (3:0) | unanimous verdict | `false` | 기존 경로 (CONFIRMED→pending write queue, NOT_AN_ISSUE→무해, NEEDS_MORE_INFO→질문 도구) |
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
- `fresh` modifier: selective propagation조차 끊는다. 이전 라운드 맥락을 전달하지 않는다. 단, current changeset에 valid dismissal ledger가 있으면 메인 에이전트가 reviewer 결과 수집 후 Arbiter 입력 전 exact match suppression을 수행할 수 있다. 이때도 reviewer prompt에는 이전 finding 본문/이전 reasoning/transcript를 전달하지 않는다.
- `MAX` modifier: reviewer fan-out만 exhaustive로 확장할 뿐, propagation 기본값은 여전히 selective다.

## 합리화 방지 (Rationalization Prevention)

DA 피드백 루프 자체를 건너뛰려는 합리화를 차단한다.
아래 생각이 떠오르면, 그것이 바로 DA가 필요한 신호이다.

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

증거 없이 "~할 수도 있다" 수준의 지적은 Arbiter가 NOT_AN_ISSUE(현실적 발생 가능성(Plausibility) FAIL — 현실적 발생 경로 제시 불가)로 판정한다. 실행 가능성(Actionability) FAIL은 "수정 방향 불명"으로 한정되며 기각 사유가 아니다 ([`arbiter-prompt.md`](arbiter-prompt.md) 판정 우선순위 참조).

### Arbiter 검증 후 수정 의무

write phase에서 Arbiter가 CONFIRMED_ISSUE로 판정한 항목을 수정할 때:

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
3. 사용자가 "제외 + 근거 기록"을 선택하면 dismissal ledger에 `USER_EXCLUDED`로 기록할 수 있다. 단 `NEEDS_MORE_INFO`를 자동 기각으로 저장하지 말고, 사용자의 명시 결정과 기술적 근거, 적용 scope가 있을 때만 기록한다.

Selective consistency 서브런 카운팅: selective consistency의 N=3 재판정은 동일 outer round 내부의 서브런이다. 3회 반복 규칙과 최대 라운드 카운트에 포함하지 않는다. 즉, outer round 1에서 N=3 재판정을 수행해도 outer round 카운트는 1에 머문다.

### 최대 라운드 수

명시적 상한은 5 outer round다. 5회 이후에도 수렴 종료에 도달하지 못하면
사용자에게 현황을 보고하고 계속 진행 여부를 확인한다(자동 무한 진행 금지). 이때 종료하면 `EARLY_STOP (unconverged)`로 기록한다. selective consistency 서브런은 outer round 카운트에 포함하지 않는다.

라운드 한계효용 판정: 각 outer round 종료 시 직전 outer round 대비 신규 finding 수를 집계한다. 동일성은 3회 반복 규칙과 같은 "세부 관점 + 위치(파일:줄 또는 계획 항목 번호)" 기준을 사용하고, valid dismissal ledger exact match로 suppress된 항목은 새 finding 계산에서 제외한다. 첫 outer round는 비교 대상이 없으므로 전체 finding 수를 신규 finding 수로 기록하되, 연속 저효용 판정은 다음 outer round부터 평가한다.

- 신규 finding 0건: 새 정보가 없다는 한계효용 신호이므로 루프 종료를 제안한다. 이 경로의 종료는 수렴 predicate 통과가 아니면 `EARLY_STOP (unconverged)`로 기록한다. 반복되는 동일 지적이 남아 있으면 3회 반복 규칙 또는 기존 사용자 판단 경로로 닫는다.
- 신규 finding 1~2건: 낮은 신규 정보량으로 기록한다. 이 상태가 2 outer round 연속이면, 다음 round를 시작하기 전에 사용자에게 현재 비용 대비 추가 기대효과를 보고하고 계속/종료를 질문 도구로 확인한다.
- 신규 finding 3건 이상: 한계효용 저하로 보지 않는다. 단 아래 비수렴 추세 또는 5회 상한 조건은 별도로 적용한다.

위 판정은 5회 상한 전의 조기 중단·한계효용 장치다. 5회 상한은 그대로 유지되며, 5회 이후 수렴 종료에 도달하지 못하면 신규 finding 추세와 무관하게 사용자 확인이 필요하다. 질문 도구 미지원 런타임은 [`arbiter-scaling.md`](arbiter-scaling.md)의 "질문 도구 미지원 대응" 자동 종료 규칙을 따른다.

비수렴 추세 조기 중단: 신규 confirmed finding(직전 outer round에 없던 confirmed — 동일성은 3회 반복 규칙과 같은 기준) 수가 직전 대비 감소하지 않는 outer round가 2회 연속이면(따라서 최소 outer round 3부터 평가 가능하며, R1·단일 라운드는 미발동), 5회 상한 전이라도 비수렴으로 간주해 즉시 현황을 사용자에게 보고하고 계속 여부를 확인한다. 수렴까지 반복은 상한/한계효용/비수렴 조기중단/read-write 분리 규칙을 함께 적용한다. 매 라운드의 write phase batch가 새 리뷰 표면을 만들어 finding이 수렴하지 않는 경우가 대표 사례다 — 이때는 라운드 중 표면을 계속 다듬어 finding을 닫으려 하기보다 changeset 동결 유지, batch 범위 축소, 또는 변경 범위 축소를 우선 검토한다. "3회 반복 규칙"이 동일 지적의 반복을 잡는다면, 이 규칙은 매 라운드 다른 새 confirmed finding이 끊이지 않는 비수렴을 잡는다.

## 라운드 요약 기록

각 라운드 종료 시 DA 발견 수, 신규 finding 수, Arbiter 판정 결과, 한계효용 판정을 요약한다:

```text
Round N 요약: DA 발견 X건(신규 X'건 — 직전 라운드에 없던 관점+위치) → Arbiter: CONFIRMED Y건(신규 confirmed Y'건), NOT_AN_ISSUE Z건, NEEDS_MORE_INFO W건
bundle별: Correctness 2건(SECURITY 1, HALLUCINATION 1), Regression CLEAR, ...
changeset: frozen=<계획 원문/commit range/diff 기준>, write_phase=<수정 파일/계획 항목/diffstat/generated output 유무>, next=<R(N+1) 새 changeset 여부>
convergence: round_max_accepted_severity=<NONE|LOW|MEDIUM|HIGH|CRITICAL>, revalidation_required=<true|false>, walkthrough=<CLEAN|NOT_REQUIRED>, walkthrough_followups=<후속 수정/범위 밖 발견 건수>
marginal_utility: new_findings=<X'건>, low_new_streak=<연속 횟수>, decision=<continue|stop_proposed|asked_user|unconverged>
dismissal_ledger: recorded=<NOT_AN_ISSUE/USER_EXCLUDED 기록 수>, suppressed=<fresh exact match로 새 finding에서 제외한 수>, stale_ignored=<stale ledger로 무시한 수>
```

selective consistency가 발동한 라운드는 추가 라인으로 stability_status 분포를 명시한다:

```text
selective: trigger P건 → stable Q건, split R건, fragmented S건, partial_failure T건
```

`split`/`fragmented`/`partial_failure` 항목은 0이 아닐 때만 나열해도 된다. 위 verdict 카운트(Y/Z/W)에서 `split`은 NEEDS_MORE_INFO로, `fragmented`/`partial_failure`는 BLOCKED로 집계된다. stability_status 정의는 [`stability-measurement.md`](stability-measurement.md) 참조.

## 수렴 판정 (accepted severity · round outcome 스냅샷 · 수렴 predicate)

본 섹션이 DA 루프 종료 판정의 SSOT다. 다른 문서(SKILL.md invariants, mode 문서, main-agent-obligations.md, intensity-procedure.md)는 이 predicate를 링크로만 참조하고 재서술하지 않는다.

### accepted severity

- accepted severity는 Arbiter 판정을 거친 항목에만 존재한다. 값은 VERDICT_JSON의 `accepted_severity` 필드다 (산출 주체는 Arbiter — 심각도 조정 시 조정값, 아니면 reviewer 원값. [`arbiter-prompt.md`](arbiter-prompt.md) 출력 요건 참조). 메인 에이전트는 집계(최댓값 계산)만 수행한다 — Arbiter 판정 대체가 아니다.
- selective consistency N=3이 실행된 finding은 harness aggregate가 보존하는 `entries[].accepted_severity` 중 최종 수용 verdict를 지지하는 entry들의 최댓값을 메인이 계산한다 (기각표의 severity가 재검증 수준을 결정하지 않게 한다. 지지 entry에 값이 없으면 reviewer 원심각도로 fail-closed fallback. harness는 변경하지 않는다).
- 실시간 경로에서 write set 진입 가능 verdict의 `accepted_severity` 누락·비정상은 caller 검증의 semantic malformed 전이(1회 재실행 → BLOCKED)가 유일한 처리다 — 검증을 통과한 항목에는 값이 반드시 있으므로 집계 단계의 누락 fallback은 존재하지 않는다. 예외적으로 사용자 수용 경로 등 Arbiter 판정 값 없이 write set에 들어오는 항목은 reviewer 원심각도를, 그것도 불명이면 CRITICAL을 사용한다 (MEDIUM 고정 대체는 CRITICAL의 진행 차단·최우선 처리를 소실시키므로 fail-closed가 아니다).
- 사용자가 수용한 NEEDS_MORE_INFO/`split` 항목도 같은 규칙의 값을 가진다.
- `VerdictRecord`·M-4 등 세션 분석 지표는 변경하지 않는다 — M-4는 종전대로 reviewer 보고 심각도 기반 지표다.

### VERDICT_JSON 기계값의 caller 검증 (메인 에이전트 의무)

`axes.plausibility`·`accepted_severity`·`reviewer_severity`·`rejection_basis`는 verdict·수렴을 결정하는 값의 기록이므로 누락·오염·의미 불일치가 기각/무재검증 방향으로 샐 수 있다. 메인 에이전트는 VERDICT_JSON을 수집하는 모든 지점(first-pass·N=3)에서 다음을 검증한다.

실시간 수집 경로에서는 `schema_version`이 1.1 이상 2.0 미만이어야 한다 — first-pass·N=3 결과는 매번 fresh Arbiter가 현재 출력 계약(1.1)으로 생성하므로, 이 경로의 1.0·버전 누락은 구 산출물이 아니라 출력 계약 위반이며 아래 fail-closed 전이를 따른다 (구버전을 자칭해 검증을 우회하는 경로 차단). 1.0 산출물의 하위호환은 지원하지 않는다.

기계 검증(존재·enum·정합 행렬·manifest)은 공통 검증기 `fleiss-kappa.py --validate-only --expect-findings <ID목록> <result.md>`가 단일 소유한다 — first-pass 결과 수집 시 메인이 Arbiter에 전달했던 finding ID 목록을 manifest로 넘겨 호출하고, N=3 집계 경로는 같은 검증을 내부 적용해 위반 entry를 malformed(→partial_failure/BLOCKED 경로)로 처리한다. 검증 규칙 (구현체: `validate_verdict_entry` 단일 진입점):

- schema: 실시간 결과는 `schema_version` 1.1 이상 2.0 미만 필수 (누락·1.0 포함 위반).
- 필수 필드 + enum: `verdict`·`confidence`는 존재+enum 필수. `axes`는 객체여야 하고 `axes.plausibility ∈ {PASS, FAIL, UNKNOWN, N/A}`, `reviewer_severity ∈ {CRITICAL, HIGH, MEDIUM, LOW}` 필수. `accepted_severity`는 write set 진입 가능 verdict(CONFIRMED_ISSUE·NEEDS_MORE_INFO)에서 필수 — NOT_AN_ISSUE는 write set에 들어가지 않으므로 요구하지 않는다.
- verdict 정합 행렬: `CONFIRMED_ISSUE → plausibility PASS 필수` / `NOT_AN_ISSUE → FAIL 또는 N/A` / `NEEDS_MORE_INFO → PASS 또는 UNKNOWN`. 행렬 밖 조합(예: FAIL+CONFIRMED_ISSUE, UNKNOWN+NOT_AN_ISSUE)은 위반이다.
- 기각 근거 정합: NOT_AN_ISSUE는 `rejection_basis ∈ {FACTUAL_FAIL, RELEVANCE_FAIL, PLAUSIBILITY_FAIL}` 필수. `plausibility=N/A`는 `rejection_basis`가 FACTUAL_FAIL 또는 RELEVANCE_FAIL일 때만 적법하고, PLAUSIBILITY_FAIL이면 `plausibility=FAIL`이어야 한다. NOT_AN_ISSUE가 아닌 verdict에 `rejection_basis`가 있으면 위반이다.
- finding manifest 대조: 파일의 유효 finding ID 집합이 `--expect-findings` 목록과 정확히 일치해야 한다 — 누락(전달한 finding에 판정이 없음)·미지 ID 모두 위반이다 (Arbiter 출력에서 finding이 조용히 사라지는 것을 차단. N=3도 이 manifest 기준으로 missing을 판정한다).

기계 검증기가 볼 수 없는 교차 검증 1개는 메인 에이전트 몫이다:

- `reviewer_severity` 원본 대조: 메인은 자신이 보유한 reviewer 원본 finding의 심각도를 JSON의 `reviewer_severity`와 대조한다 — Arbiter가 원심각도까지 함께 낮춰 써서 조정을 은닉하는 것을 차단한다 (`reviewer_severity` ≠ 원본이면 위반). `accepted_severity`가 `reviewer_severity`와 다르면 심각도 조정이며 사람용 블록에 조정 근거를 서술한다 (조정 자체는 Arbiter 권한).

위반 시 fail-closed (모든 런타임 공통 전이): fresh 실행 단위로 1회 재실행하고, 재실행 결과도 위반이면 해당 finding을 BLOCKED(malformed)로 처리한다. 어떤 런타임에서도 의미적 NEEDS_MORE_INFO 승격·headless 자동 CONFIRMED 승격·LITE 트리거 축소 경로에 태우지 않는다 (런타임 실패 처리 문서는 이 전이를 재서술하지 않고 본 섹션을 참조한다 — [`arbiter-scaling.md`](arbiter-scaling.md)의 semantic malformed 절).

### round outcome 스냅샷 (불변)

write phase 진입 직전(Arbiter 상태 전이와 사용자 판단 종료 시점)에 라운드 결과를 불변 스냅샷으로 고정한다. write phase에서 queue가 소비되어도 이 스냅샷은 불변이며, 수렴 판정과 round summary는 이것만 참조한다:

- `round_write_set`: 이번 라운드에 반영할 항목 (CONFIRMED_ISSUE + 사용자 수용 항목).
- `round_max_accepted_severity`: round_write_set의 accepted severity 최댓값 (빈 set이면 NONE).
- `unresolved_count`: 미처리 NEEDS_MORE_INFO/`split`/BLOCKED 수.

### revalidation_required (단일 파생값)

다음 중 하나라도 참이면 `revalidation_required = true` (재검증 라운드 필요). 각 조건은 안정적 이름으로 참조한다:

1. `severity-gate` — `round_max_accepted_severity`가 MEDIUM 이상.
2. `walkthrough-forced` — walkthrough가 후속 수정 또는 범위 밖 발견을 하나라도 발생시킴 (심각도 분류 없음. walkthrough가 무언가를 발견했다는 사실 자체가 리뷰 표면이 불안정하다는 신호다).
3. `batch-delta-intensity` — write phase 종료 시 최종 batch delta에 Review Intensity 인라인 체크리스트([`intensity-rules.md`](intensity-rules.md) 8룰)를 classification-only로 재적용한 판정이 SKIP이 아님. Intensity는 검토 범위를 정하는 분류이므로 이 게이트에서는 판정을 다음처럼 소비한다 — `SKIP`: 재검증 불요 신호. `LITE`: 재검증 생략이 아니라 LITE가 선택한 bundle로 경량 재검증 라운드를 실행한다 (검토가 필요하다는 분류를 생략 신호로 뒤집지 않는다). `FULL`(fail-closed rule group 매치·불확실 포함): FULL 재검증. 적용 범위는 [`intensity-procedure.md`](intensity-procedure.md)의 "수렴 게이트용 classification-only 적용"이 정의하며(SKIP 사용자 승인·모드 종료는 수행하지 않는다), 재평가 입력은 이번 라운드 write phase가 만든 batch delta뿐이다 — for_pr은 write phase 시작 전에 기록한 `pre_write_sha` 기준 `git diff --stat <pre_write_sha>..HEAD`(finalize commit 후), for_plan은 이번 batch가 수정한 계획 항목·파일 목록. PR 전체 diff(`main...HEAD`)를 입력으로 쓰면 원 changeset이 FULL인 한 LOW-only 수렴이 영구히 불가능해지므로 금지다. 별도 범위 휴리스틱을 두지 않고 기존 분류기를 단일 경계로 재사용한다 — LOW finding을 고치면서 보안·설정·의존성·인터페이스를 건드리면 `RULE-SECURITY`/`RULE-CONFIG-DEPENDENCY`/`RULE-MODULE-SERVICE`가 severity와 무관하게 재검증을 강제한다. LOW-only 재검증 생략은 이 재평가가 SKIP인 국소 delta에만 허용된다.

`walkthrough-forced` 또는 `batch-delta-intensity`가 발동한 재검증 라운드는 최초 라운드의 review unit 선택을 재사용하지 않는다 — `batch-delta-intensity`의 Intensity 재평가 판정(범위 밖 발견이 있으면 그 관점 포함)이 다음 라운드의 unit 선택을 결정한다 (LITE 판정이면 그 LITE가 선택한 bundle). walkthrough의 범위 밖 발견이 미선택 bundle 관점이면 그 bundle이 선택되도록 반영하되, `fresh` 계약 준수를 위해 발견의 본문·위치는 reviewer 프롬프트에 주입하지 않는다 — bundle 선택에만 사용하고 reviewer는 최종 changeset을 독립 검토한다.

### walkthrough_status

- `CLEAN`: 마지막으로 실행된 walkthrough pass가 추가 수정 없이 종료.
- `NOT_REQUIRED`: `round_write_set`이 비어 write phase가 없는 모든 무수정 경로 (finding 0건 ALL CLEAR, 빈 diff 즉시 종료, finding 전건 기각). 이 경로에서는 batch delta가 없으므로 revalidation_required의 `walkthrough-forced`·`batch-delta-intensity` 조건은 false다.

### 수렴 predicate

다음을 모두 충족하면 DA 루프를 수렴 종료한다:

1. `revalidation_required` = false.
2. `unresolved_count` = 0.
3. NOT_AN_ISSUE/사용자 제외 항목 근거 완비: Arbiter가 NOT_AN_ISSUE로 판정하거나 사용자가 제외한 항목에 모두 근거가 있다.
4. `walkthrough_status` ∈ {CLEAN, NOT_REQUIRED}.

finding 0건 ALL CLEAR는 1·2·3이 자명하고 `walkthrough_status=NOT_REQUIRED`인 특수형이다. 이번 라운드 반영 항목이 전부 LOW인 수렴 종료(CONVERGED)는 독립 reviewer 재검증만 생략하는 것이다 — walkthrough 자가 검증은 수행되며, 이 생략은 의도적 트레이드오프다 (LOW 리스크 + 국소 delta 한정 + 통합 반영 설계 + walkthrough가 품질 보완).

최대 라운드 수 섹션의 한계효용 저하, 비수렴 추세, 5회 상한, 신규 finding 0건은 수렴 전에도 루프를 멈출 수 있는 조기 종료 경로이며, 이 경로의 종료는 CONVERGED가 아니라 `EARLY_STOP (unconverged)`로 기록한다 — "신규 finding 0건"은 한계효용 신호일 뿐 수렴 predicate 통과가 아니다.

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

### R1
- changeset: frozen=main...HEAD@abc1234, write_phase=none, next=R2 new changeset after batch fix
- Correctness: 3건 (`HALLUCINATION` CONFIRMED 1, `SECURITY` CONFIRMED 1, `SECURITY` NOT_AN_ISSUE 1)
- Design: CLEAR
- Regression: 1건 (`SIDE_EFFECT` NEEDS_MORE_INFO 1) → 사용자 판단: 수용 → R2에서 fixed
- Maintainability: 1건 (`READABILITY` CONFIRMED 1) → R2에서 fixed
- selective: trigger 1건 → split 1 (vote-shape 2:1, minority=NOT_AN_ISSUE)  ← 선택: selective consistency가 발동된 라운드에만 이 줄을 적음

### R2
...

</details>
```

컬럼 매핑:
- `Needs Info`: `verdict=NEEDS_MORE_INFO` 또는 `stability_status=split` (split는 질문 도구 필수로 분류).
- `Blocked`: `stability_status=fragmented` 또는 partial_failure. [`stability-measurement.md`](stability-measurement.md) 참조.

`Result` 행 유형 (수렴 predicate 결과에 따라 — 아래 세 문자열이 canonical 기본형이다):
- `ALL CLEAR after N rounds` — finding 0건 특수형.
- `CONVERGED after N rounds (low_without_reviewer_rerun_count: k, walkthrough: clean)` — LOW-only 반영 후 수렴 종료. `low_without_reviewer_rerun_count`는 최종 라운드 `round_write_set`에서 반영된 LOW 항목 수다. `walkthrough: clean`은 독립 reviewer 재검증만 생략했고 자가 walkthrough는 통과했음을 명시한다. finding은 있었지만 전건 기각되어 write phase가 없는 무수정 수렴은 `CONVERGED after N rounds (low_without_reviewer_rerun_count: 0, walkthrough: not_required)`로 표기한다.
- `EARLY_STOP (unconverged) after N rounds` — 한계효용·비수렴·5회 상한·신규 0건 조기 종료.

LITE 실행 시 기본형 문자열을 바꾸지 않고 공통 suffix `(NOT_RUN: <bundle 목록>)`을 덧붙인다 — `ALL CLEAR after N rounds (NOT_RUN: Design, ...)` / `CONVERGED after N rounds (..., NOT_RUN: Design, ...)` — 미실행 bundle이 CLEAR로 오인되지 않게 하는 공개 계약이다. Round details에도 각 reviewer bundle의 `NOT_RUN` 상태를 명시한다.
