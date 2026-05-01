# Validation-Path Catalog

공유 reference — Owner: `plan-with-questions` (primary, for_prd Validation Policy + for_action validation 단계). Dependent skills: `run-da`.

의존 스킬이 신규 추가되면 이 섹션을 갱신한다. drift inventory 문서는 생성하지 않는다 (#470 Lessons Learned — 실시간 `rg`/`grep`으로 대체 가능한 정보는 작성하지 않는다).

upstream `playmoreai/agent-skills`의 `prd/SKILL.md` Validation Policy 섹션에는 별도 명명이 없다. 본 정본에서 이를 **validation-path catalog**로 명명한다. 현재 enumerate된 path 수는 enumeration 섹션에서 직접 확인한다 (하드코딩된 숫자는 drift 위험이므로 본 문서 본문에 두지 않는다).

## main-agent-only 경계

본 reference를 참조하는 스킬이 이 catalog 기반으로 tracked write(코드·문서 수정)를 수행할 때, 해당 실행은 메인 에이전트 전용이다. `nrs`·`verify-ai-compat.sh`·commit·push·GitHub write도 동일하다. subagent는 read-only 검토까지만 수행한다. 상세 계약은 [`../../run-da/SKILL.md`](../../run-da/SKILL.md)의 `Codex 세션 하드닝 계약` 섹션을 따른다.

## 원칙

- **Evidence, not ritual.** Validation 항목은 "절차를 돌렸다"는 표시가 아니라, 변경이 실제로 의도대로 동작한다는 **증거**다.
- **Risk-appropriate mix.** 위험과 가용 도구에 맞는 최소 충분 조합을 고른다. 모든 변경에 full matrix를 강제하지 않는다.
- **No hard-coded default.** "UI 변경이면 무조건 browser E2E" 같은 단일 경로 고정은 피한다. upstream 원본의 명시적 경고 (`Do not hard-code one path such as dev-browser for every UI-adjacent change`).
- **Gap is a first-class citizen.** 최적 도구가 부재하면 공백을 기록하고 차선 증거를 선택한다. 신뢰도가 명백히 부족한 경우에만 차단한다.

## Validation path 목록

### 1. Static checks
- **대상**: typecheck, linter, formatter, build, schema validation.
- **쓰는 순간**: 변경이 컴파일/파싱 수준에서 깨지지 않는지 확인.
- **쓰지 않는 순간**: 런타임 동작·사용자 흐름 검증.

### 2. Unit tests
- **대상**: 순수 로직, reducer/pure function, utility, validator, permission 판정, parsing, state transition.
- **쓰는 순간**: 입력→출력이 결정적이고 sideless한 함수.
- **쓰지 않는 순간**: 외부 시스템 통합·병행·시간 의존.

### 3. Integration tests
- **대상**: DB 동작, service/repository/queue, provider adapter, auth flow.
- **쓰는 순간**: 경계(boundary)를 넘는 상호작용을 코드 레벨에서 검증할 때.
- **쓰지 않는 순간**: 사용자 UI 경로 전체 · 배포 환경 특화 동작.

### 4. API-level E2E
- **대상**: HTTP/RPC/CLI/SDK 호출만으로 완결되는 workflow.
- **쓰는 순간**: UI 없이 서버/서비스 계약을 전체 end-to-end로 검증 가능한 경우.
- **쓰지 않는 순간**: 브라우저/클라이언트 상태가 risk 경로일 때.

### 5. Browser/UI E2E
- **대상**: DOM 동작, routing, form, client state, accessibility, 실제 user interaction.
- **쓰는 순간**: 변경의 risk가 브라우저 렌더·상호작용에 실제로 있는 경우.
- **쓰지 않는 순간**: 서버/DB/CLI 변경만으로 재현 가능한 risk.

### 6. Agent/dev browser checks
- **대상**: browser-capable skill(예: playwright-cli, chrome-devtools MCP)로 수행하는 exploratory 또는 scripted 검증.
- **쓰는 순간**: UI 동작을 agent가 자동으로 확인 가능하고, E2E suite 구축은 과도한 비용일 때.
- **쓰지 않는 순간**: flaky한 탐색만으로 핵심 risk를 '확인'했다고 주장할 때.

### 7. Mobile/app simulator checks
- **대상**: native/Expo-style flow, permission, deep link, device state, platform-specific 동작.
- **쓰는 순간**: iOS/Android 런타임 특화 동작이 risk 경로.
- **쓰지 않는 순간**: 플랫폼 무관 로직.

### 8. Visual/screenshot checks
- **대상**: layout, responsive, visual regression, platform rendering.
- **쓰는 순간**: 변경이 시각 산출물 자체를 바꿀 때 (CSS·테마·margin 등).
- **쓰지 않는 순간**: 시각 산출물 변경이 없는 로직 수정.

### 9. Manual smoke checks
- **대상**: 자동화가 없거나 비용이 맞지 않을 때, 또는 최종 sanity check.
- **쓰는 순간**: 자동화로 커버되지 않는 edge, 혹은 배포 직전 한 번만 확인.
- **쓰지 않는 순간**: 자동화가 가능한데 "귀찮아서" 회피하는 경우.

### 10. Observability checks
- **대상**: log, metric, trace, alert, dashboard, audit record.
- **쓰는 순간**: 관측 가능성 자체가 요구사항의 일부 (감사 로그, SLO)이거나, 실행 결과를 재현 없이 확인해야 할 때.
- **쓰지 않는 순간**: 코드 정확성 자체의 proof로 사용.

## 선택 절차

1. 변경의 risk를 한 문장으로 적는다 ("무엇이 틀리면 무엇이 망가지나?").
2. 그 risk가 실제로 발생하는 **표면**을 식별한다 (DB schema, HTTP handler, React DOM, observability surface...).
3. 표면에 대응하는 validation path를 **최소 1개 필수**, 위험이 큰 변경은 2-3개 조합.
4. 해당 path의 도구가 가용하지 않으면 차선을 선택하고 **gap으로 기록**.
5. Validation 항목에는 "어떤 도구 / 어떤 command / 어떤 surface / 어떤 시나리오"를 함께 적는다. "테스트를 돌린다"만으로는 evidence가 되지 않는다.

## 조합 예시

| 변경 유형 | 최소 충분 조합 |
|---|---|
| Pure logic refactor | Static checks + Unit tests |
| DB schema migration | Static checks + Integration tests + Manual smoke (migration 성공) |
| API handler 추가 | Static checks + Unit tests + API-level E2E |
| UI 컴포넌트 레이아웃 변경 | Static checks + Visual/screenshot check |
| UI 상태 변경 (form, routing) | Static checks + Unit tests + Agent/dev browser check |
| 관측 로직 추가 | Static checks + Unit tests + Observability check |
| nixos-config activation 변경 | Static checks (`nix flake check`) + Manual smoke (`nrs`) + Observability (activation log) |

표는 가이드일 뿐이다. 각 변경의 실제 risk에 맞춰 조합을 조정한다.
