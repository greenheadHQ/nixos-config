---
name: parallel-audit
argument-hint: "[agent-count]"
description: |
  Exhaustive side-effect/regression audit via parallel agents.
  Trigger: '전수조사', '사이드이펙트 조사', '회귀 조사', '병렬 감사', '에이전트 N개 조사'.
  NOT for DA (use run-da).
---

# 병렬 에이전트 전수조사

기본 경로는 6개 auditor bundle을 병렬 실행하여 변경사항의 사이드이펙트, 회귀, 엣지케이스를 전수조사한다.
명시적 exhaustive override가 필요할 때만 `parallel-audit 10`으로 fan-out을 확장한다.

## 빠른 참조

| 항목 | 값 |
|------|-----|
| 기본 에이전트 수 | 6 |
| open thread cap | current session의 `agents.max_threads` (unset 기본 6) |
| `$ARGUMENTS` | 에이전트 수 (정수). 비어있으면 기본값 6 사용 |
| exhaustive override | `parallel-audit 10` |
| 에이전트 권한 | 읽기 전용 (코드 수정 불가) |

## 런타임 경로

**"나는 어떤 세션에서 실행되고 있는가?"** 로 경로를 선택한다.

| 경로 | 조건 | 기본 실행 |
|------|------|----------|
| **Codex 세션** | Codex CLI가 호스트 — `spawn_agent`/`wait_agent`/`close_agent` API 사용 가능 | native subagent fan-out → `wait_agent` → 결과 집계 → `close_agent` |
| **Claude Code 세션** | Claude Code가 호스트 — `Agent` tool 사용 가능 | **codex exec subprocess가 기본**. 사전점검(`command -v codex >/dev/null && codex --version >/dev/null 2>&1`) → 존재하면 bundle별 `codex exec --full-auto --ephemeral -c model_reasoning_effort="high"` → 실패 시 Claude Code `Agent` tool fallback |
| **headless 세션** | CI, `claude -p`, `codex exec` subprocess | bundle별 `codex exec --full-auto --ephemeral -c model_reasoning_effort="high"` + 임시 prompt/result 파일 |

`CODEX_CI=1`만으로 세션 유형을 구분하지 않는다.
Codex 세션의 상세 wait/write/violation 계약은 [run-da/SKILL.md](../run-da/SKILL.md)의 `Codex 세션 하드닝 계약`을 따른다.
다만 `parallel-audit`에서는 auditor read-only/no-write 경계가 항상 우선한다.

## 조사 bundle

6개 기본 조사 bundle을 정의한다. 에이전트 수에 따라 자동 조절한다.

| # | 관점 | 조사 대상 |
|---|------|----------|
| 1 | Security + API | credential 노출, 권한 오남용, 입력 검증 누락, 외부 API 계약/인터페이스 호환 |
| 2 | Performance + Dependencies | O(n^2) 알고리즘, 불필요한 재계산, 메모리 누수, 버전 충돌, breaking change |
| 3 | Tests + Edge Cases | 기존 테스트 호환, 동작 회귀, 빈 입력, 경계값, 동시성, null/undefined |
| 4 | Platform (macOS + NixOS) | darwin/nixos 전용 경로, launchd/systemd 설정, Homebrew Cask, Nix derivation |
| 5 | Adjacent Side Effects | 수정하지 않은 인접 코드에 대한 영향, 공유 상태/환경 파급 |
| 6 | Docs / Consistency | SKILL.md, CLAUDE.md, README 정합성, 라우팅 테이블, 네이밍/구조 일관성 |

### 에이전트 수 조절 규칙

- **에이전트 수 > 조사 bundle 수**: 큰 bundle을 더 세부 관점으로 분할한다.
  예: `Platform (macOS + NixOS)`를 `macOS`, `NixOS`로 분할.
- **에이전트 수 < 조사 bundle 수**: 연관된 bundle을 하나의 에이전트에 통합한다.
  예: `Docs / Consistency`를 `Adjacent Side Effects`와 함께 묶는다.
- **명시적 exhaustive override**: `parallel-audit 10`은 기본 6 bundle을 다음 10개 세부 관점으로 확장한다.
  `Security`, `API`, `Performance`, `Dependencies`, `Tests`, `Edge Cases`, `macOS`, `NixOS`, `Adjacent Side Effects`, `Docs / Consistency`

## 절차

### Step 1: 변경 범위 파악

```bash
git diff --stat          # 변경 파일 목록과 크기
git diff                 # 전체 diff
git log --oneline -5     # 최근 커밋 컨텍스트
```

변경 파일 수, diff 줄 수, 영향 받는 모듈을 파악한다.

### Step 2: 조사 bundle 분배

에이전트 수(`$ARGUMENTS` 또는 기본값 6)에 맞게 위 6개 bundle을 분배한다.
변경 내용에 따라 관련도가 높은 bundle에 에이전트를 더 배정할 수 있다.

예: Nix 설정 변경이면 `Platform (macOS + NixOS)`와 `Adjacent Side Effects`에 더 많은 비중을 두고,
`parallel-audit 10`이 명시된 경우에만 `macOS`와 `NixOS`를 분리한다.

### 병렬 디스패치 사전 조건

N개 에이전트를 병렬 실행하기 전에 다음을 확인한다:

- [ ] 각 에이전트의 조사 bundle이 **독립적**이다 (공유 상태 없음)
- [ ] 에이전트 간 **결과 간섭**이 없다 (한 에이전트의 결과가 다른 에이전트의 판단에 영향 안 미침)
- [ ] 각 에이전트에게 전달하는 컨텍스트가 **자기 완결적**이다 (다른 에이전트 결과 참조 불필요)

### Step 3: 병렬 에이전트 실행

N개 에이전트를 **한 턴에 동시 병렬 실행**한다.

각 에이전트에게 전달하는 내용:

1. **변경 diff 전체**
2. **프로젝트 컨텍스트**: CLAUDE.md, 관련 모듈 구조
3. **담당 조사 bundle**: 위 테이블에서 배정된 bundle과 조사 대상
4. **출력 형식 지시**: 아래 "결과 형식"에 따라 반환

에이전트 지시 원칙:

- 읽기 전용: 코드를 수정하지 않는다.
- 담당 bundle에만 집중한다. 다른 bundle은 언급하지 않는다.
- 발견 사항마다 구체적 파일:줄과 근거를 제시한다.
- 발견이 없으면 SAFE를 반환한다.
- Codex 세션 경로에서는 `run-da` canonical contract의 standard review profile을 사용한다.
- `wait_agent` timeout이나 단순 지연만으로 auditor를 kill하거나 self-auditing으로 대체하지 않는다.
- tracked workspace write, branch mutation, commit/push, GitHub write, `wt`/`nrs`/rebuild 계열은 auditor가 실행하지 않는다.
- Codex 세션 경로에서는 current session의 open slot을 넘기지 않는다. `agents.max_threads`는 unset일 때 기본 6이며, completed thread도 `close_agent` 전에는 슬롯을 점유한다.

### Step 3a: Codex 세션 경로

- Codex 세션에서는 이 경로를 기본으로 사용한다.
- bundle마다 fresh native subagent 1개를 standard review profile로 `spawn_agent` 실행한다.
- bundle 수가 현재 open slot보다 많으면 batch로 나눈다.
- 모든 결과는 `wait_agent`로 수신한다. timeout만으로 실패 처리하거나 auditor를 중간 kill/self-auditing으로 대체하지 않는다.

### Step 3b: codex exec 경로 (Claude Code 세션 · headless 세션)

- 임시 디렉토리를 생성한다: `DA_DIR=$(mktemp -d /tmp/da-${_DA_SID}-audit-XXXXXX)`. `DA_DIR` 경로를 `echo`로 출력하여 이후 호출에서 리터럴로 재사용한다.
- Claude Code 세션 · headless 세션에서는 bundle마다 `cat "$DA_DIR/{unit}.md" | codex exec --full-auto --ephemeral -c model_reasoning_effort="high" -o "$DA_DIR/{unit}-result.md" -` subprocess 1개를 사용한다.
- 세션 네임스페이스(`$_DA_SID`)와 stdin pipe 패턴은 [run-da/SKILL.md](../run-da/SKILL.md)의 "codex exec 경로 위생 규칙"을 따른다.
- 임시 prompt/result 파일, stderr/result 검증, `run_in_background`, stdin pipe 경쟁, heredoc hang 제약은 [/using-codex-exec 스킬](../using-codex-exec/SKILL.md)과 [known-issues.md](../using-codex-exec/references/known-issues.md)를 따른다.

### Step 3c: Claude Code Agent tool fallback (codex 미가용 시)

- `command -v codex`/`codex --version` 사전점검 실패 또는 codex exec 실행 실패 시에만 진입한다.
- bundle별 `Agent` tool을 `run_in_background: true`로 병렬 실행한다.
- reviewer는 read-only/no-write 범위를 프롬프트에 명시한다.
- 완료 알림 수신 후 결과를 집계하고, `RECOVERABLE VIOLATION`/`STATEFUL VIOLATION` 분류 규칙은 Step 4와 동일하게 적용한다.

### Step 4: 결과 수신 및 검증

모든 에이전트의 결과를 수신한 뒤:

1. 각 발견 사항의 유효성을 검증한다 (파일:줄이 실제로 존재하는지, 근거가 타당한지).
2. 중복 발견을 제거한다 (여러 bundle에서 같은 문제를 지적한 경우).
3. 심각도 순으로 정렬한다.
4. Codex 세션 경로에서는 결과 집계가 끝난 completed audit thread를 `close_agent`로 닫아 다음 batch/retry 슬롯을 회수한다.
5. `RECOVERABLE VIOLATION`은 `SAFE`에서 제외하고 fresh auditor로 재디스패치한다. 이는 auditor가 새 상태 코드를 정의하는 것이 아니라, 메인 에이전트가 출력 형식 위반이나 scope 침범 같은 contract breach를 감지했을 때 부여하는 조율 분류다.
6. `STATEFUL VIOLATION`만 `BLOCKED (VIOLATION)`로 남긴다. 이 경우 cleanup 범위가 특정되거나 사용자에게 불완전한 run이 보고되기 전에는 fresh auditor로 재디스패치하지 않는다.

### Step 5: 종합 리포트 생성

아래 "결과 형식"에 따라 종합 리포트를 사용자에게 제시한다.

## 결과 형식

### 요약 테이블

```
## 전수조사 결과

| # | 조사 bundle | 결과 | 핵심 근거 |
|---|----------|------|----------|
| 1 | Security + API | SAFE | credential 노출 없음, 외부 계약 변경 없음 |
| 2 | Performance + Dependencies | BUG | modules/foo.nix:23 — O(n^2) 루프 발견 |
| 3 | Tests + Edge Cases | SAFE | 기존 동작 변경 없음 |
| ... | ... | ... | ... |
```

### 결과 코드

| 코드 | 의미 | 조치 |
|------|------|------|
| SAFE | 해당 bundle에서 문제 미발견 | 없음 |
| BUG | 명확한 버그 발견 | 수정 필수 |
| REGRESSION | 기존 동작이 변경/파괴됨 | 수정 필수 |
| EDGECASE | 특정 입력/조건에서 문제 가능 | 수정 권장 |

### 에이전트 상태 코드

결과 코드(SAFE/BUG/REGRESSION/EDGECASE)는 조사 완료 시 반환한다.
아래 상태 코드는 **조사를 완료할 수 없을 때** 반환한다:

| 상태 | 의미 | 조율자 대응 |
|---|---|---|
| `NEEDS_CONTEXT` | 조사에 필요한 정보가 부족 | 부족한 컨텍스트를 보강하여 재디스패치 |
| `BLOCKED` | 조사를 진행할 수 없음 | 원인 분류 후 대응 |

#### BLOCKED 원인 분류 및 대응

| 원인 | 대응 |
|---|---|
| 컨텍스트 부족 | 추가 파일/정보를 제공 후 재디스패치 |
| 범위 과대 | bundle을 세분화하여 2개 에이전트로 분할 |
| 접근 불가 | 해당 bundle을 사용자에게 보고하고 수동 확인 요청 |
| recoverable violation | 메인 에이전트가 current unit을 `RECOVERABLE VIOLATION`으로 분류하고, `SAFE` 계산에서 제외한 뒤 fresh auditor로 재디스패치 |
| stateful violation | 메인 에이전트가 current unit을 `BLOCKED (VIOLATION)`로 분류하고, tracked write/branch mutation/commit/push/GitHub/main-agent-only command/host mutation 시도 여부와 이번 실행이 만든 산출물 범위를 먼저 확인한다. cleanup 범위가 특정되기 전에는 fresh auditor 재디스패치 금지 |

에이전트의 BLOCKED를 무시하거나 같은 조건으로 재시도하지 않는다.

### 전원 SAFE인 경우

```
전수조사 완료: SAFE — 사이드이펙트/회귀 발견 없음
(기본 경로: 에이전트 6개, 조사 bundle 6개, 소요 시간: ~N초)
```

NEEDS_CONTEXT/BLOCKED 상태가 있었으나 모두 해소된 경우에도 위 완료 메시지를 사용한다.

### 발견 사항 상세

BUG/REGRESSION/EDGECASE가 있으면 요약 테이블 아래에 상세를 추가한다:

```
### 발견 사항 상세

#### [#2] Performance + Dependencies — BUG
- **위치**: modules/foo.nix:23
- **문제**: 리스트 전체를 매 반복마다 재탐색 — O(n^2)
- **근거**: 입력 크기 N=1000 기준 약 100만 회 연산
- **권장 수정**: builtins.listToAttrs로 O(n) 변환 후 조회
```

## 검증 의무

### 에이전트 출력 요건
- 모든 발견 사항에는 반드시 구체적 파일:줄을 제시해야 한다.
- 코드 스니펫을 직접 인용하여 문제를 증명해야 한다.
- "~할 수도 있다", "~이 우려된다" 등 증거 없는 추상적 우려는 즉시 기각한다.

### 메인 에이전트 검증 의무
- 에이전트의 각 발견 사항을 수용하기 전에, 해당 파일:줄을 직접 Read 도구로 읽어 사실 여부를 확인한다.
- 검증 없이 에이전트 결과를 그대로 수용하는 것을 금지한다.
- 사용자에게 판단을 요청할 때는 [사용자 질문 시 맥락 설명 의무](../run-da/SKILL.md#사용자-질문-시-맥락-설명-의무)를 따른다 (WTF Moment 방지).

## 검증 에이전트 편향 방지

감사 결과를 검증하기 위해 추가 에이전트를 투입할 때, 다음 규칙을 따른다.

### 금지되는 검증 프롬프트 패턴

1. **결론 유도형 선택지**: "REGISTER 또는 SKIP (YAGNI/false positive)" 같이 기각 방향을 선택지에 명시하는 것
2. **유도 질문**: "현실적으로 발생하는가?", "단일 사용자 환경에서 의미가 있는가?" 같이 기각을 유도하는 질문
3. **맥락 편향**: 검증 대상 finding만 제시하지 않고, 기각 근거나 반박 논거를 함께 제공하는 것

### 올바른 검증 프롬프트 패턴

```
다음 감사 에이전트의 finding을 독립적으로 검증하라:

[finding 원문 — 수정 없이 그대로]

해당 파일:줄을 직접 Read 도구로 확인하고, 다음 중 하나로 판정하라:
- CONFIRMED_ISSUE: finding이 사실이며 조치가 필요하다 (근거 필수)
- NOT_AN_ISSUE: finding이 사실이 아니거나 조치가 불필요하다 (근거 필수)
- NEEDS_MORE_INFO: 판단을 위해 추가 정보가 필요하다 (필요한 정보 명시)
```

(근거: #298 Case 8에서 5개 검증 에이전트에 YAGNI 프레이밍을 주입하여 5/5 만장일치 SKIP을 유도한 사례)

## 주의사항

- 에이전트는 읽기 전용이다. 코드를 직접 수정하지 않는다.
- 조사 결과를 사용자에게 먼저 제시하고, 수정은 사용자 승인 후 진행한다.
- 변경 범위가 극소한 경우 에이전트 수를 줄여 효율을 높인다.
- 기본값은 6이며, `parallel-audit 10`만 exhaustive override다. 10은 기본값이 아니다.
- Codex 세션 경로에서는 completed audit thread를 다음 batch/retry 전에 명시적으로 `close_agent`로 닫는다.
- `SAFE`는 유효한 auditor 결과가 모두 확보된 뒤에만 반환한다. `RECOVERABLE VIOLATION` 재디스패치 중이거나 `BLOCKED (VIOLATION)` unit이 남아 있으면 완료로 간주하지 않는다.
- DA 피드백 루프(run-da)와 목적이 다르다: DA는 설계/코드 품질을 반복 개선하고, 전수조사는 변경의 안전성을 일회성으로 검증한다.
