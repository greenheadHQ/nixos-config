# Phase Template

Split-file mode의 각 phase 파일은 아래 구조를 사용한다. Single-file mode에서는 master PRD의 `Phase Plan` 섹션 안에 동일 구조를 phase별로 인라인한다.

경로: `.claude/prds/prd-[feature-name]/phase-NN-[phase-name].md`

```markdown
# Phase N: [Phase Name]

Parent PRD: [PRD: Feature Name](../prd-[feature-name].md)
Status: Not Started | In Progress | Complete
Last Updated: YYYY-MM-DD

## Objective
[이 phase가 무엇을 달성하고 왜 지금인가.]

## Context From Master PRD
- Goals covered: G-...
- Success Criteria: SC-...
- Requirements covered: FR-..., NFR-...
- Key scenarios touched: ...

## Phase Discovery Gate
코드 편집 전에 재확인한다:
- [ ] 관련 코드/파일: `path`, `path`
- [ ] 관련 테스트/fixture: `path`, `path`
- [ ] 관련 docs/spec/외부 참조: `path-or-link`
- [ ] 관련 command 또는 도구: `command/tool`
- [ ] Master PRD의 assumption이 여전히 유효함
- [ ] 발견 사항이 이 phase 또는 후속 phase를 바꾸면, 구현 전에 PRD 파일을 먼저 갱신

## Scope
### In Scope
- ...

### Out of Scope
- ...

## Implementation Checklist
- [ ] [대상 파일/컴포넌트/시스템 + 기대 outcome을 포함한 구체적 구현 단계]

## Validation Strategy
[위험에 맞는 최소 충분 검증 조합을 고른다. 단위/통합/API E2E/browser/simulator/visual/manual/observability 중 왜 그 조합인지 설명한다. 도구/command를 알면 함께 적는다. 상세 가이드는 `~/.claude/skills/plan-with-questions/references/validation-paths.md` 참조.]

## Validation Checklist
- [ ] Static check 통과 (가용 시): [command]
- [ ] 자동 test 추가/갱신 및 통과 (해당 시): [command/test path]
- [ ] API/CLI/service-level workflow 검증 (충분한 경우): [surface]
- [ ] Browser/UI E2E — DOM/client 상호작용이 risk 경로일 때만 수행: [tool/flow]
- [ ] Agent/dev browser check — browser-capable skill로 exploratory/scripted 검증: [tool/flow]
- [ ] Mobile/app simulator — 플랫폼/네이티브 동작이 risk일 때만: [tool/flow]
- [ ] Visual/screenshot check — 시각 산출물 변경 시: [tool/flow]
- [ ] Observability/logging/audit 동작 확인 (관련 시): [surface]
- [ ] Manual smoke check — 자동화가 불충분하거나 최종 sanity check가 필요할 때
- [ ] 해당 시 error, empty, loading, permission, retry, rollback 상태 검증

## Exit Criteria
- [ ] Phase objective 달성
- [ ] 위에 열거한 요구사항이 구현되었거나 명시적으로 deferred
- [ ] Validation checklist 완료 또는 gap이 근거와 함께 기록됨
- [ ] 다음 phase를 시작하지 못하게 막는 blocker 없음

## Phase-End Multi-Pass Review
다음 phase로 이동하기 전 순서대로 완료한다:
- [ ] 1. Intent/coverage review — 본 phase가 objective와 매핑된 요구사항을 달성했다.
- [ ] 2. Correctness review — happy path, edge case, error, empty state, state transition, 권한이 처리되었다.
- [ ] 3. Simplicity review — 솔루션이 필요 이상으로 복잡하지 않다.
- [ ] 4. Code quality review — 이름/경계/추상화/로컬 일관성이 깔끔하다.
- [ ] 5. Duplication/cleanup review — 중복 로직, dead code, temporary code, 잡음 log, 주석 처리 잔재, 사용되지 않는 파일/의존성이 제거되었다.
- [ ] 6. Security/privacy review — 권한, secret, 민감 데이터, injection risk, 클라이언트 노출, 감사 필요성이 안전하다.
- [ ] 7. Performance/load review — bottleneck, 비싼 query, N+1, 불필요한 재렌더, 불필요한 네트워크 호출이 다루어졌다.
- [ ] 8. Validation review — 선택한 check가 phase risk에 적절하다. 누락 check는 근거와 함께 기록.
- [ ] 9. Future-phase review — 뒤 phase 파일/체크리스트가 여전히 옳다. 구현이 계획을 바꿨다면 수정.
- [ ] 10. PRD sync review — master PRD status, active phase, assumption, risk, validation surface, change log가 갱신되었다.

## Discoveries / Decisions
- ...

## Phase Change Log
- YYYY-MM-DD: Phase file created.
```

## 작성 규칙

- `[phase-name]` slug와 phase file path의 단일 SSOT는 [`file-mode-selection.md`](./file-mode-selection.md#경로-slug-안전-규칙) 의 basename과 canonical containment 규칙이다.
- Phase Discovery Gate는 모든 phase 파일에 필수다. 편집 전에 다시 읽고 체크한다.
- Validation Checklist 항목에는 "어떤 command / 어떤 surface / 어떤 시나리오" 를 적어 evidence로 만든다.
- Phase-End 10-pass는 phase 종료마다 수행한다. 프로젝트 마감 시 수행하는 Final 10-pass (단일 SSOT는 [`multi-pass-review.md`](./multi-pass-review.md)) 와는 다른 축이다. Phase-End는 future-phase 또는 PRD sync 관점이고, Final은 closeout 관점이다.
