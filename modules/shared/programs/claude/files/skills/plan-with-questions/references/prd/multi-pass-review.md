# Final Multi-Pass Review (All Phases)

모든 phase가 완료된 직후, 다음 항목을 순서대로 완료한다. 개별 phase의 `Phase-End Multi-Pass Review` (별도 문서) 는 phase 종료마다 수행한다. 본 리스트는 프로젝트 마감 직전에 한 번 수행한다.

본 체크리스트는 `plan-with-questions` 내부 reference 다. for_prd 모드와 for_action 모드의 Post-Implementation의 Step 5 ("Final 10-pass Multi-Pass Review") 가 SSOT 참조로 링크한다.

## 체크리스트

- [ ] 1. Requirements coverage review: 모든 FR, NFR, Success Criterion이 만족되었거나 명시적으로 deferred 되었다.
- [ ] 2. Cross-phase integration review: phase 산출물들이 서로 맞물려 동작하며 gap, 깨진 가정, 소유권 중복이 없다.
- [ ] 3. Correctness review: happy path, edge case, error, empty state, 권한, 상태 전이가 처리되었다.
- [ ] 4. Simplicity / refactor review: 최종 설계가 필요 이상으로 복잡하지 않다.
- [ ] 5. Duplication / cleanup review: 중복 로직, dead code, temporary code, 잡음 log, 주석 처리 잔재, 사용되지 않는 파일 또는 의존성이 제거되었다.
- [ ] 6. Security / privacy review: 인증 / 인가, secret, 민감 데이터, 감사 가능성, 데이터 노출이 안전하다.
- [ ] 7. Performance / load review: bottleneck, 비싼 query, N+1, 불필요한 재렌더, 불필요한 네트워크 호출이 다루어졌다.
- [ ] 8. Validation review: 최종 validation 조합이 risk에 적절하다. 경로 enumeration과 선택 근거의 단일 SSOT는 [`../validation-paths.md`](../validation-paths.md) catalog 다 (static / unit / integration / API-level E2E / browser-UI E2E / agent-dev browser / mobile-simulator / visual-screenshot / manual smoke / observability).
- [ ] 9. Documentation / operability review: 문서, runbook, release note, migration, rollback, 모니터링, 지원 note가 필요에 따라 갱신되었다.
- [ ] 10. PRD closeout review: PRD status가 Complete, change log가 최신, follow-up이 기록되어 있다.

## 수행 조건

- 적용 대상: `.claude/prds/` 하위 Living PRD를 기반으로 진행한 작업, 또는 현재 작업 diff에 `.claude/prds/` 파일이 포함된 경우.
- PRD 없는 단일 plan 작업: 10번 "PRD closeout review" 는 N/A로 skip 하고 skip 근거를 기록한다. 나머지 9개 항목은 그대로 수행한다.

## main-agent-only 경계

본 체크리스트는 메인 에이전트가 직접 수행한다. fan-out 금지. `run-da` 의 reviewer bundle (Correctness, Design, Regression, Maintainability) 과는 축이 다르다:

| 축 | 구분 |
|---|---|
| `run-da` 4-bundle | 변경 범위 내 diff 감사 (Correctness, Design, Regression, Maintainability) |
| 본 10-pass Final Review | 의도 또는 스펙 대비 최종 검토. Requirements Coverage, Cross-Phase Integration, Validation 선택, Documentation, PRD Closeout은 run-da 축이 커버하지 않는다 |

동일 이슈가 `run-da` 의 CONFIRMED로 이미 반영된 뒤에 본 체크리스트에 도달하는 것이 정상 순서다. 본 리스트는 남은 축 (1, 2, 8, 9, 10 위주) 에 집중한다.
