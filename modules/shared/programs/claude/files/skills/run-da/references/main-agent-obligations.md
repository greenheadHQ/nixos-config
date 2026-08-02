# 메인 에이전트 의무 (행동 + 사용자 질문 맥락 + 검증)

`run-da` 메인 에이전트가 직접 수행해야 하는 행동·사용자 질문 작성 의무·수정 검증 의무를 모은다. DA → Arbiter 상태 흐름의 정본은 [`protocol.md`](protocol.md), single-writer/role boundary/VIOLATION/Delegation fallback의 정본은 [`hardening-contract.md`](hardening-contract.md)다. 본 파일은 그 정책을 메인 에이전트 행동 관점에서 link로만 참조한다.

## 메인 에이전트 역할

| 수행 | 금지 |
|------|------|
| Review Intensity 인라인 체크리스트 (모든 룰 평가 + first-match 채택) | 룰 자유 추론 / 체크리스트 표 생략 |
| CONFIRMED_ISSUE 수정 | DA finding 직접 판정 (Arbiter 대체) |
| tracked workspace write, branch mutation, commit/push, GitHub write | DA reviewer/Auditor/Arbiter에 single-writer 작업 위임 |
| `wt`, `nrs`, rebuild 계열 실행 | main-agent-only command를 direct fan-out subagent에 넘기기 |
| 질문 도구 호출 (SKIP/NEEDS_MORE_INFO) | "사용자 지시"로 DA 기각 |
| Arbiter 결과 수신 및 보고 | 프롬프트 조향 |
| ignored dismissal ledger read/write (메인 에이전트만) | ledger를 tracked diff로 만들기 |
| 결과 파일 파싱 | — |

## 메인 에이전트 직접 수행 행동

이 섹션은 메인 에이전트가 직접 수행할 행동만 다룬다. 정책/계약/상태 흐름은 정본을 link로만 참조한다.

- Review Intensity 인라인 체크리스트: 직접 `/run-da` 호출 진입 시 메인 에이전트는 [`intensity-rules.md`](intensity-rules.md)의 모든 룰을 평가한 표를 plan/대화에 남기고(short-circuit 금지) first-match 룰 단계를 채택해 SKIP/LITE/FULL 판정을 결정한다. 문서화된 자동 호출자의 preflight handoff를 수신한 경우에는 freshness를 검증해 유효하면 재사용하고, 누락/형식 오류/stale이면 현재 입력으로 체크리스트를 다시 적용한다. 자유 추론 금지. fail-closed rule group 매치/불확실 또는 룰 ID+근거 미명시 시 강한 검토 fail-closed. 절차 SSOT는 [`intensity-procedure.md`](intensity-procedure.md).
- Arbiter 독립 판정 보존: DA findings는 독립 Arbiter 에이전트가 판정한다. 메인 에이전트는 Arbiter 판정을 대체하지 않는다. 메인 에이전트는 CONFIRMED_ISSUE 항목의 수정만 담당한다.
- CONFIRMED_ISSUE 자동 반영 (통합 반영 루프): Arbiter가 CONFIRMED_ISSUE로 판정한 항목은 자동으로 반영하되, review phase 중에는 patch/edit/apply_patch, write-mode formatter, generated output 변경을 금지한다. 항목은 pending write queue에 모아 write phase에서 `통합 설계 → batch 반영 → walkthrough → 후속 수정 처리 → finalize` 루프로 반영한다 (절차 정본: [`../modes/for_plan.md`](../modes/for_plan.md) Step 6). CRITICAL accepted severity는 다음 outer round 진행을 차단하고 write phase 첫 항목으로 수정한다. 상태 전이별 행동의 정본은 [`protocol.md`](protocol.md)의 "DA → Arbiter → Main Agent 상태 흐름"이다.
- Round outcome 스냅샷 기록과 accepted severity 집계: write phase 진입 직전 round outcome 스냅샷을 고정하고, VERDICT_JSON 수집 시 `axes.plausibility` caller 검증을 수행하며, accepted severity의 집계(최댓값 계산)만 담당한다 — 값 산출은 Arbiter 소관이다. 규칙 정본은 [`protocol.md`](protocol.md)의 "수렴 판정".
- Walkthrough 자가 검증: write phase의 batch 반영 후·다음 라운드 발사 전, 수정된 대상을 처음 읽는 사람처럼 따라 실행한다. 발견 결함의 즉시 수정 범위와 재검증 강제 규칙은 [`../modes/for_plan.md`](../modes/for_plan.md) Step 6의 "후속 수정 처리"가 정본이다.
- Dismissal ledger 관리: `NOT_AN_ISSUE` 또는 사용자가 명시 제외한 eligible 항목만 [`dismissal-ledger.md`](dismissal-ledger.md)에 따라 local ignored ledger에 기록한다. `NEEDS_MORE_INFO`는 자동 기각으로 저장하지 않는다. `fresh` 반복 세션에서는 exact match 항목만 새 finding에서 제외한다.
- 사용자 전건 보고: 모든 Arbiter 판정 결과(CONFIRMED_ISSUE, NOT_AN_ISSUE, NEEDS_MORE_INFO)를 사용자에게 보고한다. NEEDS_MORE_INFO·`split` 항목은 아래 "사용자 질문 시 맥락 설명 의무"의 5요소를 갖춘 질문 도구 호출로 처리한다.
- Conservative wait: Codex 세션 경로에서 `wait_agent` timeout이나 단순 지연만으로 reviewer/Arbiter를 kill하지 않는다. explicit failure signal, documented violation, 최종 응답 파싱 실패가 없는 한 self-auditing으로 대체하지 않는다. (Review Intensity는 인라인 체크리스트라 wait 대상 아님.)
- Fresh perspective 보장: 매 라운드마다 새 reviewer/Arbiter 실행 단위를 사용한다 (Codex 세션: 새 native subagent thread, codex exec 경로: 새 `codex exec` 프로세스). `fresh` modifier 사용 시 이전 라운드 맥락을 차단한다. dismissal ledger 예외도 이전 finding 본문/이전 reasoning/transcript는 주입하지 않고, 메인 에이전트의 exact match suppression에만 사용한다.
- Selective propagation 기본값: Arbiter/후속 reviewer에게는 unique findings, conflicting findings, high-severity findings, user decision required findings만 전달한다. raw transcript 전체, CLEAR 결과, 중복 low-signal finding의 all-to-all broadcast는 금지한다. `MAX` modifier는 propagation이 아니라 fan-out만 확장한다.
- 프롬프트 조향 금지: 후속 라운드 DA/Arbiter 프롬프트에 이전 라운드의 판정 결과를 포함하지 않는다. 이전 라운드 결과를 "이미 해결된 사안"으로 프레이밍하는 것도 금지한다. dismissal ledger를 주입해야 하는 예외적 런타임에서도 key, scope, `dismissed` 결론만 허용하고 finding 본문은 금지한다.

## 정책 / 계약 / 상태 흐름 (link only)

본 파일은 아래 정책의 SSOT가 아니다. 변경은 정본 파일에서 한다.

- Single-writer / main-agent-only / 역할별 경계 / VIOLATION 처리 / Delegation fallback: [`hardening-contract.md`](hardening-contract.md) (`Codex 세션 하드닝 계약` SSOT).
- PoC 의무화 / Arbiter 판정 프로토콜 / DA → Arbiter 상태 흐름 / read-write 분리 / 무한 루프 방지(3회 반복) / 수렴 판정(accepted severity·round outcome 스냅샷·수렴 predicate·caller 검증) / PR 코멘트 형식: [`protocol.md`](protocol.md) (protocol SSOT).
- Dismissal ledger key/schema/storage/invalidation: [`dismissal-ledger.md`](dismissal-ledger.md) SSOT.
- Selective consistency trigger / vote-shape / threshold: [`stability-measurement.md`](stability-measurement.md) SSOT, 상태 전이는 [`protocol.md`](protocol.md), 실행 계약은 [`arbiter-scaling.md`](arbiter-scaling.md).

## 사용자 질문 시 맥락 설명 의무

사용자에게 질문 도구로 판단을 요청할 때 (3회 반복 규칙, 라운드 한계효용 저하, 5회 라운드 초과, 추세 기반 조기 중단, fresh 모드 반복 감지 등 모든 경우), 사용자가 딴짓을 하다가 돌아온 상황을 가정하고 다음을 모두 포함한다:

1. 현재 상황 요약: 어떤 작업을 하고 있었는지 (예: "PR #<번호>의 DA for_pr 피드백 루프 진행 중입니다")
2. 문제 설명: 무엇이 충돌/반복되고 있는지 구체적으로
3. 비유법 설명: 기술 용어를 모르는 사람도 이해할 수 있도록 쉬운 비유로 설명
4. 선택지별 장단점: 각 선택이 가져올 결과를 명확히
5. 질문: 질문 도구로 결정 요청

나쁜 예 (맥락 부재):
> "SECURITY DA가 3회 연속 동일 지적을 반복합니다. 수용/기각/보류 중 선택해주세요."

좋은 예 (맥락 풍부):
> "현재 PR #<번호> 코드 리뷰 N라운드째입니다. `SECURITY` 세부 관점 finding이 3회 연속 '입력 검증 누락'을 지적하고 있습니다.
> 해당 코드는 modules/foo.nix:42의 사용자 입력 처리 부분인데, 쉽게 비유하면 '현관문에 잠금장치를 달아야 한다'는 지적입니다.
> 저는 이전 2라운드에서 '이 입력은 내부 시스템에서만 오므로 잠금이 불필요하다'고 기각했지만, DA가 계속 지적합니다.
> - 수용: 입력 검증 코드 추가 (안전하지만 불필요한 코드 증가)
> - 기각 + CIR: '내부 전용 입력'이라는 근거를 기록하고 넘어감
> - 보류: 별도 이슈로 등록하고 나중에 판단"

## 검증 의무 (메인 에이전트만)

본 섹션은 메인 에이전트가 수정 시 직접 수행할 검증만 정의한다.

- CONFIRMED_ISSUE 항목을 write phase에서 batch 수정할 때, 해당 위치(파일:줄 또는 계획 항목)를 확인하는 것은 수정 작업의 일부로 수행한다.
- 수정 결과가 finding을 해결하는지 확인한다.

DA 에이전트 출력 요건과 Arbiter 검증 의무(판정 기준 목록 등)는 본 파일이 정본이 아니다:

- DA 에이전트 출력 요건 (구체적 파일:줄·코드 인용·추상적 우려 즉시 기각): [`da-domains.md`](da-domains.md)의 "공통 출력 형식" 섹션이 정본.
- Arbiter 검증 의무 (core criteria와 guardrail의 이름 목록 포함): [`arbiter-prompt.md`](arbiter-prompt.md)의 "판정 기준" 섹션이 기준 목록의 단독 소유자다 — 본 파일을 포함한 다른 문서는 목록을 복제하지 않고 anchor link로만 참조한다. NOT_AN_ISSUE 판정 신뢰도 보고 의무, NEEDS_MORE_INFO 사용 조건도 동일 파일에 정의.
