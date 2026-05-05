# Phase 4: Bias Measurement

Parent PRD: [PRD: plan-with-questions Question UX](../prd-pwq-question-ux.md)
Status: Complete
Last Updated: 2026-05-05

## Objective

`references/bias-measurement.md` + `scripts/ai/measure-anchoring-bias.sh` (또는 동등 위치 스크립트)의 라벨 측정 metric을 새 라벨 정책 ("허용 조건 컨텍스트 외 라벨 0건")에 맞춰 갱신한다. anti-anchoring 1번 규칙 폐기에 따른 metric 인프라 drift 차단.

## Context From Master PRD

- Goals covered: G-6 (anchoring 측정 metric 동시 갱신)
- Success Criteria: SC-5
- Requirements covered: FR-8
- Key scenarios touched: Scenario 1 (라벨 부착 시 measure 통과 확인)

## Phase Discovery Gate

코드 편집 전에 재확인한다:
- [x] 관련 코드/파일: `modules/shared/programs/claude/files/skills/plan-with-questions/references/bias-measurement.md`, `scripts/ai/measure-anchoring-bias.sh` (repo-tracked default; `~/.claude/scripts/` global override는 사용자 host 설정에 따른 optional 경로)
- [x] Phase 1, 2, 3 산출물 — 라벨 정책 변경 + Anti-anchoring 1번 폐기가 모두 반영됨
- [x] 관련 docs/spec: `~/.claude/skills/plan-with-questions/references/consulting-step.md` Anti-anchoring 4 규칙 (Phase 1 결과)
- [x] 관련 command: `bash`/`zsh` (스크립트 실행), `rg`
- [x] Master PRD assumption 유효
- [x] 스크립트 실제 경로를 `find ~/.claude -name "measure-anchoring-bias.sh"`로 1차 확인 후 implementation 진입

## Scope

### In Scope

- `references/bias-measurement.md` 라벨 측정 metric 단락 — "라벨 0건" 가정에서 "허용 조건 컨텍스트 외 라벨 0건"으로 갱신.
- `scripts/ai/measure-anchoring-bias.sh` 또는 동등 위치 스크립트 — 라벨 grep 패턴을 새 정책에 맞춰 갱신 (예: "(Recommended) — 자문+합의 결과" 컨텍스트는 통과, 그 외는 검출).
- bias-measurement.md에 새 baseline 산출 절차 단락 추가 (현 정책: "합의 미달 라벨 0건"이 baseline).

### Out of Scope

- F-OQ-2: D4 anchoring 효과 손상 정량 측정 방법의 *세부 baseline* — 본 phase는 metric 변경만, 세부 baseline은 dogfooding 누적 후 별도 follow-up issue.
- 다른 anchoring metric (framing/defect/resistance 후보 탐지) 변경 — Anti-anchoring 1번 폐기와 무관, 본 phase 범위 외.

## Implementation Checklist

- [x] `find . -name "measure-anchoring-bias.sh"` 등 repo-relative 검색으로 스크립트 위치 확인 (PR 작업 시점 default — `scripts/ai/measure-anchoring-bias.sh`로 확인됨). `~/.claude` global override는 사용자 host 설정에 따라 optional.
- [x] `references/bias-measurement.md` "anchoring metric" 또는 동등 단락 — 현재 "라벨 0건 grep" 단락 확인 후 "허용 조건 컨텍스트 외 라벨 0건"으로 갱신.
- [x] `references/bias-measurement.md` 새 baseline 산출 절차 단락 추가 — Phase 1 합의 알고리즘 통과한 라벨은 통과, 그 외는 검출.
- [x] 스크립트 grep 패턴 갱신 — `(Recommended)` 단순 매칭에서 컨텍스트 인식 매칭 (예: "(Recommended)" 다음 줄 또는 같은 line에 "자문+합의" 또는 "합의 결과" 키워드가 있으면 통과)으로 변경. 또는 `rg "Recommended"` + `rg -A 2 "Recommended"`로 컨텍스트 확인.
- [x] 스크립트 실행 후 본 PRD 변경 후 0건이 나오는지 확인 (manual run).
- [x] `references/bias-measurement.md`에 본 phase의 변경 사항 + 새 baseline 절차를 Change Log 또는 동등 위치에 기록.

## Validation Strategy

본 phase는 metric 변경 + 스크립트 grep 패턴 변경이라 스크립트 실행 검증이 핵심.

- 스크립트 실행: `bash scripts/ai/measure-anchoring-bias.sh` (실제 위치) → exit 0 + 출력에 "라벨 위반 0건" 또는 동등.
- 정적 grep: `rg "Recommended" modules/shared/programs/claude/files/skills/plan-with-questions/` → Phase 1-3 변경 결과로 화이트리스트 파일만 매칭 (SC-2 + SC-5 통합, source 기준). deployed(`~/.claude/skills/...`) 재검증은 본 PR 머지 + nrs 후 closeout 외부 monitoring으로 분리한다.
- 정적 grep: `rg "허용 조건 컨텍스트" modules/shared/programs/claude/files/skills/plan-with-questions/references/bias-measurement.md` ≥ 1건.

## Validation Checklist

- [x] Static check 통과: `find . -name "measure-anchoring-bias.sh"`로 repo-tracked 스크립트 위치 확인 (1+개; `scripts/ai/measure-anchoring-bias.sh`)
- [x] Script 실행 통과: `bash <스크립트 경로>` exit 0 + 출력 정상 (라벨 위반 0건)
- [x] Static check 통과: `rg "허용 조건" modules/shared/programs/claude/files/skills/plan-with-questions/references/bias-measurement.md` ≥ 1건
- [x] Static check 통과: `rg "Recommended" modules/shared/programs/claude/files/skills/plan-with-questions/` → 화이트리스트 파일/섹션 매칭만 (SC-2 + SC-5 동시 검증, **source 기준 — deployed `~/.claude/skills/...` 재검증은 본 PR 머지 + nrs 후 별도 monitoring**)
- [x] 자동 test: N/A
- [x] API/CLI workflow 검증: 스크립트 실행 자체가 검증
- [x] Manual smoke check: bias-measurement.md read 후 다음 LLM이 metric 의미 파악 가능?
- [x] error 상태: 스크립트가 라벨 위반 1+건 검출 시 nonzero exit 또는 에러 메시지 명시 확인

## Exit Criteria

- [x] Phase objective 달성 — bias-measurement.md + 스크립트 갱신 완료
- [x] FR-8 구현
- [x] Validation checklist 완료
- [x] Phase 5 시작을 막는 blocker 없음

## Phase-End Multi-Pass Review

- [x] 1. Intent/coverage — bias-measurement.md + 스크립트가 새 라벨 정책 일관 측정
- [x] 2. Correctness — 스크립트 grep 패턴이 "허용 조건 컨텍스트"를 정확히 식별 (false positive/negative 점검)
- [x] 3. Simplicity — 스크립트 변경이 grep 패턴 갱신 정도로 최소 변경
- [x] 4. Code quality — 스크립트 주석에 새 정책 의도 명시
- [x] 5. Duplication/cleanup — 기존 라벨 0건 가정 단락 제거 또는 명시적 폐기 표기
- [x] 6. Security/privacy — N/A
- [x] 7. Performance/load — 스크립트 실행 시간 (PWQ 본문 grep)
- [x] 8. Validation — 스크립트 실행 + 정적 grep이 risk에 적절
- [x] 9. Future-phase review — Phase 5 dogfooding이 스크립트 통과 baseline 사용
- [x] 10. PRD sync review — master PRD Phase Index Status `Phase 4` → `Complete`, `Active Phase File`을 phase-05로 갱신

## Discoveries / Decisions

- 스크립트 실제 위치는 `scripts/ai/measure-anchoring-bias.sh` (repo root 기준, git tracked) — PRD master Discovery Summary와 일치.
- **Source sanitization metric vs transcript metric을 별개 cadence로 분리**: PRD spec implementation checklist는 "스크립트 grep 패턴 갱신"을 명시했으나, 실제로 두 metric의 측정 의도가 다름을 발견. transcript metric(measure-anchoring-bias.sh)은 4축 anchoring signal 식별이 본업이며 PAT_framing의 "Recommended"는 LLM 추천 표현 흔적 catalog로 D1/D2/D4 도입 후에도 유지된다. Source sanitization은 PWQ 본문에서 라벨이 D4 합의 컨텍스트로만 등장하는지 검증하는 별개 측정으로 cadence가 D4 정책 변경과 동기화된다. 두 metric을 한 스크립트에 묶으면 cadence 충돌이 발생하므로 source sanitization은 bias-measurement.md의 inline rg 명령으로 SSOT를 분리. 스크립트 헤더 주석에 두 cadence 분리 이유 명시.
- 검증 명령 catalog에 6 카테고리 키워드(D4 합의/허용 조건/자문 입력 금지+부재/도구 default override+TUI fact/transcript catalog/검증 절차 메타 자체)를 등록하여 baseline PASS 달성. axis-2 framing catalog 라인은 "추천 프레이밍" 키워드로, 검증 명령 코드블록 내부는 "SKILLDIR" 키워드로 매칭하여 self-reference 자체를 허용 컨텍스트로 식별.

## Phase Change Log

- 2026-05-05: Phase file created.
- 2026-05-05: Phase 4 Complete. bias-measurement.md "Source label sanitization baseline (D4 정책 일관성)" 단락 추가, transcript catalog의 "Recommended" 의미 명시(보존 결정), measure-anchoring-bias.sh 헤더 주석에 source sanitization SSOT 위치 + cadence 분리 이유 명시. Validation: source sanitization rg(EXIT=1, baseline PASS) + transcript 스크립트 실행(--skip-ssh exit 0, minipc 543 transcripts 정상). Active Phase → Phase 5.
