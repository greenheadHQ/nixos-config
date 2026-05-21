---
name: parallel-audit
argument-hint: "[agent-count] [context]"
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
| args 첫 토큰 (정수) | 에이전트 수. 비어있으면 기본값 6 사용. 예: `parallel-audit 6` (정수 단독) 또는 `parallel-audit 6 <컨텍스트>` (첫 토큰 뒤 나머지 토큰이 컨텍스트). |
| args 그 외 (자유 텍스트) | 첫 토큰이 정수가 아니면 전체 args를 컨텍스트로 활용 (Step 1 `git diff` 결과와 결합). 예: `parallel-audit <컨텍스트>` (기본 6). |
| exhaustive override | `parallel-audit 10` 또는 `parallel-audit 10 <컨텍스트>` (10개 세부 관점 강제 + trailing 컨텍스트 보존) |
| 에이전트 권한 | 읽기 전용. codex exec 경로(Claude Code/headless)는 Layer 1(`codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules`)으로 구조적 강제. Codex 세션(`spawn_agent`)은 정책 + 프롬프트 + self-report로 운영 (Non-goals 참조) |

## 용어 정책

이 스킬은 Claude Code 세션과 Codex 세션 양쪽에서 호출된다. 본문은 도구-중립 용어를 쓰며, 런타임별 실제 도구 binding은 [run-da의 "런타임 도구 매핑" 표](../run-da/references/runtime-mapping.md#런타임-도구-매핑)를 단일 진실 원천으로 참조한다 (중복 복제 금지).

| 용어 유형 | 처리 |
|----------|------|
| 사용자 질문 실행 지시 | "질문 도구" |
| 파일 읽기 지시 | "파일 읽기 도구" |
| 병렬 실행 지시 | "병렬 실행" 또는 "fan-out 실행" |

auditor-specific delta: parallel-audit의 fan-out 대상은 auditor다 (standard review profile). role은 auditor이며 bundle 단위 fan-out이고, Arbiter는 사용하지 않는다.

## 런타임 경로

"나는 어떤 세션에서 실행되고 있는가?" 로 경로를 선택한다. 런타임별 도구 binding은 [run-da의 "런타임 도구 매핑" 표](../run-da/references/runtime-mapping.md#런타임-도구-매핑)가 단일 소스다. 공통 subprocess 위생/제약(세션 네임스페이스, stdin pipe, 환경변수 유실)은 [`../using-codex-exec/SKILL.md`](../using-codex-exec/SKILL.md)와 run-da의 "codex exec 경로 위생 규칙"을 따른다. Step 3b는 parallel-audit의 prompt/result flow와 guards를 정의하고, command literal은 [run-da references/arbiter-scaling.md](../run-da/references/arbiter-scaling.md)의 role별 명령 `reviewer / Auditor` 템플릿을 참조한다.

| 경로 | 조건 |
|------|------|
| Codex 세션 | Codex CLI가 호스트 — native subagent fan-out (delegation 허용 시). delegation-denied fallback은 run-da의 "Delegation fallback" 참조 |
| Claude Code 세션 | Claude Code가 호스트 — codex exec 기본 (사전점검: `command -v codex` + `command -v codex-exec-supervised` + `codex-exec-supervised --check` 모두 성공해야 한다. wrapper `--check`는 setsid/timeout/codex 의존성을 자체 검증하고 OK 시 exit 0, 부재 시 exit 127을 반환한다 — codex exec를 호출하지 않으므로 사전점검 비용이 작다). codex 또는 wrapper 미가용/capability probe 실패 시 Claude Code fallback (아래 Step 3c) |
| headless 세션 | CI, `claude -p`, `codex exec` subprocess |

`CODEX_CI=1`만으로 세션 유형을 구분하지 않는다.
Codex 세션의 상세 wait/write/violation 계약은 [run-da/references/hardening-contract.md](../run-da/references/hardening-contract.md)의 `Codex 세션 하드닝 계약`을 따른다.
다만 `parallel-audit`에서는 auditor read-only/no-write 경계가 항상 우선한다.

Direct Codex 세션에서 `$parallel-audit` 호출은 auditor bundle 범위의 내부 native subagent fan-out explicit delegation으로 취급한다. 이 권한은 auditor bundle 범위에만 한정되며, `codex-exec-supervised` fallback approval이나 tracked write, branch mutation, commit/push, GitHub write, `wt`, `nrs`, rebuild 권한을 부여하지 않는다. 정본은 [run-da `hardening-contract.md`의 `Skill-internal fan-out authorization`](../run-da/references/hardening-contract.md#skill-internal-fan-out-authorization)이다.

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

- 에이전트 수 > 조사 bundle 수: 큰 bundle을 더 세부 관점으로 분할한다.
  예: `Platform (macOS + NixOS)`를 `macOS`, `NixOS`로 분할.
- 에이전트 수 < 조사 bundle 수: 연관된 bundle을 하나의 에이전트에 통합한다.
  예: `Docs / Consistency`를 `Adjacent Side Effects`와 함께 묶는다.
- 명시적 exhaustive override: `parallel-audit 10` 또는 `parallel-audit 10 <컨텍스트>`는 기본 6 bundle을 다음 10개 세부 관점으로 확장한다. `<컨텍스트>`가 있으면 첫 토큰 `10` 뒤 나머지 토큰을 메인 에이전트의 우선순위 판단 컨텍스트로 보존한다.
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

에이전트 수(args 첫 토큰이 정수면 그 값, 아니면 기본값 6)에 맞게 위 6개 bundle을 분배한다.
컨텍스트는 정수-first 형식이면 첫 토큰 뒤 나머지 토큰, context-only 형식이면 전체 args다.
메인 에이전트는 이 컨텍스트를 보존하고 Step 1의 `git diff` 결과와 결합하여 bundle 분배 가중치 결정에 활용한다.
변경 내용에 따라 관련도가 높은 bundle에 에이전트를 더 배정할 수 있다.

예: Nix 설정 변경이면 `Platform (macOS + NixOS)`와 `Adjacent Side Effects`에 더 많은 비중을 두고,
`parallel-audit 10`이 명시된 경우에만 `macOS`와 `NixOS`를 분리한다.

### Step 2a: Baseline 저장

Step 3 fan-out 이전에 workspace status baseline을 세션 네임스페이스 파일에 저장한다 (Step 4의 사후 비교용). self-report가 누락된 `git status --porcelain=v1` path/status delta를 sandbox 비의존 방식으로 감지하기 위함이다.

```bash
# 세션 네임스페이스 (run-da의 codex exec 경로 위생 규칙 계승)
_DA_SID="${CODEX_COMPANION_SESSION_ID:+${CODEX_COMPANION_SESSION_ID:0:8}}"
if [ -z "$_DA_SID" ]; then
  if command -v sha1sum >/dev/null 2>&1; then
    _DA_SID="$(printf '%s' "$PWD" | sha1sum | head -c 8)"
  else
    _DA_SID="$(printf '%s' "$PWD" | shasum | head -c 8)"
  fi
fi
BASELINE_FILE=$(mktemp /tmp/da-${_DA_SID}-audit-baseline-XXXXXX)
[ -f "$BASELINE_FILE" ] || { echo "missing BASELINE_FILE=$BASELINE_FILE"; exit 1; }
# Sentinel header로 clean workspace의 0-byte baseline과 truncate-to-empty tamper를 구분한다
printf 'BASELINE_V1 _DA_SID=%s\n' "$_DA_SID" > "$BASELINE_FILE"
# --untracked-files=all로 이미 untracked인 directory 내부의 신규 파일까지 열거한다 (기본값은 directory 단위로만 열거)
git status --porcelain=v1 --untracked-files=all >> "$BASELINE_FILE"

# 메인 에이전트가 이후 셸 호출에서 리터럴 재사용하기 위해 stdout으로 세 산출물을 모두 출력한다
# (run-da의 "셸 호출 간 환경변수 유실" 공통 주의 참조)
printf '_DA_SID=%s\n' "$_DA_SID"
printf 'BASELINE_FILE=%s\n' "$BASELINE_FILE"
printf -- '--- BASELINE_CONTENT_BEGIN ---\n'
cat "$BASELINE_FILE"
printf -- '--- BASELINE_CONTENT_END ---\n'
```

메인 에이전트는 stdout의 세 산출물을 모두 컨텍스트에 보존한다:
1. `_DA_SID` 리터럴 값 — Step 3b의 `DA_DIR=$(mktemp -d /tmp/da-${_DA_SID}-audit-XXXXXX)` 등에서 리터럴로 재사용.
2. `BASELINE_FILE` 경로 — Step 4 비교 및 `rm -f` 대상.
3. `BASELINE_CONTENT` 본문 (begin/end 마커 사이) — Step 4 무결성 검증용. 파일의 현재 내용과 이 보존 본문을 비교한다.

> literal 재사용 환각 주의 (issue #632): `_DA_SID`/`BASELINE_FILE`/`DA_DIR`은 출력된 리터럴과 호출 직전 guard를 유지한다. Generic rule은 [`using-codex-exec/known-issues.md`](../using-codex-exec/references/known-issues.md#literal-재사용-시-random-suffix-환각-금지-issue-632)를 따른다.

Step 4 비교가 끝나면 `BASELINE_FILE`을 삭제한다. 이 baseline은 `git status --porcelain=v1` path/status delta만 감지한다. 구조적 감지 불가 범위(content-only/ignored/write-then-revert/cross-workspace mutation, baseline 파일 무결성 한계)의 상세는 Non-goals 섹션이 canonical 단일 소스다.

### 병렬 디스패치 사전 조건

N개 에이전트를 병렬 실행하기 전에 다음을 확인한다:

- [ ] 각 에이전트의 조사 bundle이 독립적이다 (공유 상태 없음)
- [ ] 에이전트 간 결과 간섭이 없다 (한 에이전트의 결과가 다른 에이전트의 판단에 영향 안 미침)
- [ ] 각 에이전트에게 전달하는 컨텍스트가 자기 완결적이다 (다른 에이전트 결과 참조 불필요)

### Step 3: 병렬 에이전트 실행

N개 에이전트를 한 턴에 병렬 실행한다 (런타임이 지원하는 경우). headless 세션은 [run-da 런타임 도구 매핑](../run-da/references/runtime-mapping.md#런타임-도구-매핑)에 따라 serial foreground로 순차 실행한다 — 각 subprocess의 종료와 result를 직렬로 확인한다.

각 에이전트에게 전달하는 내용:

1. 변경 diff 전체
2. 프로젝트 컨텍스트: CLAUDE.md, 관련 모듈 구조
3. 담당 조사 bundle: 위 테이블에서 배정된 bundle과 조사 대상
4. 출력 형식 지시: 아래 "결과 형식"에 따라 반환

에이전트 지시 원칙 (run-da Auditor 계약과 동일, [`run-da/references/hardening-contract.md`](../run-da/references/hardening-contract.md)의 "역할별 경계" 표 `Auditor (parallel-audit)` 행 계승):

- 정책상 읽기 전용: 모든 write를 금지한다 — tracked/untracked workspace write, scratch PoC, branch/remote/GitHub write, host mutation, main-agent-only command (`wt`, `nrs`, rebuild 계열) 실행 금지 (구조적 enforcement 부재는 Non-goals 참조).
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

- 임시 디렉토리 생성 호출에서는 Step 2 stdout의 `_DA_SID` 리터럴 값을 먼저 재설정하고, 생성된 `DA_DIR` 경로를 stdout으로 출력한다:
  ```zsh
  _DA_SID=c4a35fc4
  DA_DIR=$(mktemp -d /tmp/da-${_DA_SID}-audit-XXXXXX)
  [ -d "$DA_DIR" ] || { echo "missing DA_DIR=$DA_DIR"; exit 1; }
  printf 'DA_DIR=%s\n' "$DA_DIR"
  ```
- 단일 shell 전환 미적용: baseline 생성, auditor prompt/result 생성, aggregate 비교가 multi-call 흐름이므로 단일 shell 강제로 바꾸지 않는다. 대신 위 issue #632 literal 재사용 guard를 적용한다.
- 후속 prompt 생성 호출은 stdout의 `DA_DIR` 리터럴 값을 그대로 재설정하고 guard한 뒤, 파일 편집 도구나 구조화 writer로 bundle prompt를 작성한다:
  ```zsh
  DA_DIR=/tmp/da-c4a35fc4-audit-AbCdEf
  UNIT=side-effects
  [ -d "$DA_DIR" ] || { echo "missing DA_DIR=$DA_DIR"; exit 1; }
  # diff/이슈 본문은 untrusted input이다. shell heredoc에 직접 삽입하지 말고,
  # 파일 편집 도구나 구조화 writer로 "$DA_DIR/$UNIT.md"에 작성한다.
  ```
- 후속 auditor 호출은 stdout의 `DA_DIR` 리터럴 값을 그대로 재설정하고 guard한 뒤, [`run-da/references/arbiter-scaling.md`](../run-da/references/arbiter-scaling.md)의 role별 명령 `reviewer / Auditor` 템플릿으로 실행한다:
  ```zsh
  DA_DIR=/tmp/da-c4a35fc4-audit-AbCdEf
  UNIT=side-effects
  [ -d "$DA_DIR" ] || { echo "missing DA_DIR=$DA_DIR"; exit 1; }
  [ -f "$DA_DIR/$UNIT.md" ] || { echo "missing prompt=$DA_DIR/$UNIT.md"; exit 1; }
  ```
  `--ignore-user-config`/`--ignore-rules`/model-effort pins/`CODEX_PROGRAMMATIC=1` placement 등 command literal은 [`run-da/references/arbiter-scaling.md`](../run-da/references/arbiter-scaling.md)의 role별 명령이 SSOT다.
- 세션 네임스페이스(`$_DA_SID`)와 stdin pipe 패턴은 [run-da/references/runtime-mapping.md](../run-da/references/runtime-mapping.md)의 "codex exec 경로 위생 규칙"을 따른다.
- 임시 prompt/result 파일, stderr/result 검증, 백그라운드 실행 제어, stdin pipe 경쟁, heredoc hang 제약은 [/using-codex-exec 스킬](../using-codex-exec/SKILL.md)과 [known-issues.md](../using-codex-exec/references/known-issues.md)를 따른다.

### Step 3c: Claude Code fallback (codex 미가용 시)

- 위 표 사전점검(`command -v codex` + `command -v codex-exec-supervised` + `codex-exec-supervised --check`) 실패 또는 codex exec 실행 실패 시에만 진입한다.
- bundle별 병렬 실행을 수행한다. 실행 binding 상세(Claude Code 고유 fallback lifecycle, 완료 알림 수신, thread 관리)는 [run-da/references/runtime-mapping.md](../run-da/references/runtime-mapping.md)의 "Claude Code 세션 fallback 세부 정보" 섹션을 참조한다.
- 프롬프트에 read-only/no-write 범위를 명시한다.
- 완료 알림 수신 후 결과를 집계하고, `RECOVERABLE VIOLATION`/`STATEFUL VIOLATION` 분류 규칙은 Step 4와 동일하게 적용한다.

### Step 4: 결과 수신 및 검증

모든 에이전트의 결과를 수신한 뒤:

1. 각 발견 사항의 유효성을 검증한다 (파일:줄이 실제로 존재하는지, 근거가 타당한지).
2. 중복 발견을 제거한다 (여러 bundle에서 같은 문제를 지적한 경우).
3. 심각도 순으로 정렬한다.
4. Codex 세션 경로에서는 결과 집계가 끝난 completed audit thread를 `close_agent`로 닫아 다음 batch/retry 슬롯을 회수한다.
5. Baseline 비교 (aggregate) (Step 2a 출력 `$BASELINE_FILE`과 비교):
   - 사전 무결성 검증 (header 포함 full baseline 대상): `$BASELINE_FILE`이 존재하지 않거나, Step 2a stdout에서 보존한 `BASELINE_CONTENT`(sentinel header `BASELINE_V1` + `git status --porcelain=v1`)와 파일의 현재 내용 전체가 일치하지 않으면 즉시 `STATEFUL VIOLATION (baseline tampered or missing)`로 fail-closed BLOCKED 처리한다. sentinel header가 있으므로 clean workspace의 정상 empty-status baseline과 truncate-to-empty tamper는 구분된다.
   - delta 비교 (status-only payload 대상): 무결성 검증 통과 시 현재 `git status --porcelain=v1 --untracked-files=all`을 `tail -n +2 "$BASELINE_FILE"` (sentinel header 제거한 status-only payload)과 비교한다. baseline과 동일한 `--untracked-files=all` 플래그를 쓰지 않으면 untracked directory 내부 신규 파일이 한쪽에만 열거되어 false positive가 난다. sentinel header를 그대로 둔 채 현재 status와 비교하면 항상 불일치로 오판되므로 반드시 `tail -n +2`로 header를 제거한 뒤 비교한다. 차이 여부 × self-report 조합에 따라 아래 두 경로를 분리하여 적용한다:

   경로 A — baseline delta 있음 + stateful mutation self-report 없음: aggregate workspace mutation은 감지되나 attribution 불가. 원인은 (a) auditor unit 하나 이상의 미보고 stateful write, (b) 사용자/메인 에이전트/외부 프로세스의 concurrent mutation, (c) child tool-call audit trail 부재로 구분 불가 중 하나다. `STATEFUL VIOLATION (workspace changed during audit, actor unknown)`으로 즉시 fail-closed BLOCKED 보고하고, offending unit cleanup/fresh rerun은 진행하지 않는다. recoverable self-report가 있어도 baseline delta가 있으면 이 경로를 적용한다 (stateful classification 우선).

   경로 B — self-report로 stateful mutation과 unit이 특정됨: self-report가 기술한 산출물/경로가 baseline delta 전체를 설명하는지 검증한다.
     - 전체 delta가 self-report 범위로 설명되면 해당 unit을 `STATEFUL VIOLATION (unit=<unit-id>)`로 표시하고 run-da canonical contract의 offending-unit cleanup 범위(offending thread 닫기, 이번 라운드 scratch/임시 ref/산출물 정리)만 적용한다.
     - 설명되지 않는 잔여 delta가 있거나 self-report가 unit만 특정하고 path/status 범위를 특정하지 않으면 경로 A로 전환한다 (`STATEFUL VIOLATION (workspace changed during audit, actor unknown or mixed)`).
     - baseline delta 없음 + stateful self-report 있음은 해당 unit만 unit-specific STATEFUL로 처리한다.
     - Non-goals 감지 불가 범위 self-report override: self-report가 구조적 감지 불가 범위(content-only / ignored / write-then-revert / cross-workspace mutation — 아래 Non-goals 참조)의 mutation을 보고하면 baseline delta 유무와 무관하게 즉시 fail-closed `BLOCKED (VIOLATION)`로 처리한다. 이 override는 경로 B의 "unit-specific STATEFUL" 처리보다 우선한다 (구조적 검증 불가 → 보수적 fail-closed).

   recoverable self-report(출력 형식 위반/scope 침범 등)는 위 경로가 아니라 아래 6번의 `RECOVERABLE VIOLATION` 경로로 분류한다. 단 baseline delta가 동시에 존재하면 경로 A가 우선한다 (stateful 우선).

   - 비교가 끝나면 `rm -f "$BASELINE_FILE"`로 임시 파일을 삭제한다.
   - 감지 불가 범위(content-only/ignored/write-then-revert/cross-workspace mutation, 그리고 concurrent external actor attribution)는 Non-goals 참조. self-report가 이들 범위에서 수정을 보고하거나 의심되면 `BLOCKED (VIOLATION)`로 fail-closed 처리한다.
6. `RECOVERABLE VIOLATION`은 `SAFE`에서 제외하고 fresh auditor로 재디스패치한다. 이는 auditor가 새 상태 코드를 정의하는 것이 아니라, 메인 에이전트가 출력 형식 위반이나 scope 침범 같은 contract breach를 감지했을 때 부여하는 조율 분류다.
7. `STATEFUL VIOLATION`만 `BLOCKED (VIOLATION)`로 남긴다. 이 경우 cleanup 범위가 특정되거나 사용자에게 불완전한 run이 보고되기 전에는 fresh auditor로 재디스패치하지 않는다.

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
아래 상태 코드는 조사를 완료할 수 없을 때 반환한다:

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
- 에이전트의 각 발견 사항을 수용하기 전에, 파일 읽기 도구로 해당 파일:줄을 확인한다.
- 검증 없이 에이전트 결과를 그대로 수용하는 것을 금지한다.
- 사용자에게 판단을 요청할 때는 [사용자 질문 시 맥락 설명 의무](../run-da/references/main-agent-obligations.md#사용자-질문-시-맥락-설명-의무)를 따른다 (WTF Moment 방지).

## 검증 에이전트 편향 방지

감사 결과를 검증하기 위해 추가 에이전트를 투입할 때, 다음 규칙을 따른다.

### 금지되는 검증 프롬프트 패턴

1. 결론 유도형 선택지: "REGISTER 또는 SKIP (YAGNI/false positive)" 같이 기각 방향을 선택지에 명시하는 것
2. 유도 질문: "현실적으로 발생하는가?", "단일 사용자 환경에서 의미가 있는가?" 같이 기각을 유도하는 질문
3. 맥락 편향: 검증 대상 finding만 제시하지 않고, 기각 근거나 반박 논거를 함께 제공하는 것

### 올바른 검증 프롬프트 패턴

```
다음 감사 에이전트의 finding을 독립적으로 검증하라:

[finding 원문 — 수정 없이 그대로]

해당 파일:줄을 직접 확인하고, 다음 중 하나로 판정하라:
- CONFIRMED_ISSUE: finding이 사실이며 조치가 필요하다 (근거 필수)
- NOT_AN_ISSUE: finding이 사실이 아니거나 조치가 불필요하다 (근거 필수)
- NEEDS_MORE_INFO: 판단을 위해 추가 정보가 필요하다 (필요한 정보 명시)
```

(근거: 과거 검증 에이전트 5개에 YAGNI 프레이밍을 주입하여 5/5 만장일치 SKIP을 유도한 사례 — 프롬프트 조향 회귀 방지 목적)

## 관련 follow-up

`parallel-audit` + `run-da` + `codex-fan-out` 3 SKILL의 args 처리 패턴이 서로 다르다 (정수 / mode 토큰 / 텍스트 우선). 3 SKILL 호출 인터페이스의 mental model 통일은 본 이슈 scope 외 — 별도 메타 이슈에서 다룬다.

## Non-goals

이 스킬이 구조적으로 보장하지 않는 auditor-specific 경계. 공통 한계(zsh 전제, `/tmp` 쓰기 sandbox 정책, project-scoped MCP 차단 한계, `spawn_agent` per-child read-only sandbox 부재)는 [run-da Non-goals](../run-da/SKILL.md#non-goals)를 단일 진실 원천으로 참조한다 (중복 방지). (run-da/SKILL.md의 `## Non-goals` 섹션은 분리 후에도 SKILL.md 본문에 그대로 잔류한다.)

1. child tool-call audit trail 부재: Codex parent API는 자식 에이전트의 tool-call 전체 audit trail을 노출하지 않는다. 따라서 `RECOVERABLE VIOLATION` vs. `STATEFUL VIOLATION` 구분은 구조적 판단이 아니라 (a) 자식 self-report, (b) 메인 에이전트의 사후 `git status --porcelain=v1` baseline 비교의 조합으로 근사한다. 이 근사의 한계:
   - aggregate 한정 (attribution 불가): 병렬 N auditor의 baseline 비교는 global workspace mutation 여부만 알 수 있다. 원인 actor는 (a) auditor unit 하나 이상, (b) 사용자/메인 에이전트/외부 프로세스의 concurrent mutation 중 구조적으로 구분 불가다 → `STATEFUL VIOLATION (workspace changed during audit, actor unknown)`으로 즉시 fail-closed BLOCKED 보고하고, offending unit cleanup/fresh rerun은 self-report로 unit이 특정되고 baseline delta 전체가 해당 unit의 산출물로 설명되는 경우에만 진행한다.
   - content-only mutation 미감지: 이미 dirty인 tracked 파일의 내용 추가 변경, untracked 파일의 내용 변경은 `git status --porcelain=v1` 출력이 같아 감지되지 않는다.
   - ignored 파일 미감지: `.gitignore` 대상은 `git status` 출력에서 제외되어 baseline에 포함되지 않는다.
   - write-then-revert 미감지: 파일을 수정한 뒤 원상복구하면 최종 `git status` delta가 baseline과 같아 감지되지 않는다.
   - cross-workspace mutation 미감지: branch/remote/GitHub/host/main-agent-only command mutation은 `git status`로 감지 불가이므로 self-report 누락 또는 의심 시 fail-closed `BLOCKED` 처리한다.
   - baseline 파일 무결성: `BASELINE_FILE`은 `/tmp` (workspace-write 모드에서 auditor 접근 가능)에 저장되므로 tampering/삭제 가능성이 있다. Step 4는 누락/빈 파일/사전 기록 내용 불일치를 `STATEFUL VIOLATION (baseline tampered or missing)`으로 fail-closed 처리한다.

2. auditor 기본 실행 경로의 read-only sandbox 적용 (issue #593 Layer 1): Claude Code 세션과 headless 세션의 기본 경로는 `codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral`이다. supervised wrapper(setsid + timeout, [`using-codex-exec/references/known-issues.md`](../using-codex-exec/references/known-issues.md) §15)가 process-group kill을 보장하고, read-only sandbox + `--ignore-user-config` + `--ignore-rules`가 audit 의도(read-only + execpolicy mutation 차단)를 구조적으로 강제한다. auditor는 scratch PoC를 수행하지 않는다 ([`run-da/references/hardening-contract.md`](../run-da/references/hardening-contract.md) "역할별 경계" — Auditor는 모든 write/scratch PoC 금지). 파일·문서 증거 기반 검증만 가능하며, scratch PoC 권한은 `run-da` DA reviewer 역할에만 적용된다.

## 주의사항

- 에이전트는 읽기 전용이다. 코드/tracked workspace 수정을 금지한다. codex exec 경로(Claude Code/headless)는 Layer 1(supervised wrapper + `--sandbox read-only` + `--ignore-user-config` + `--ignore-rules`)으로 구조적 강제, Codex 세션(`spawn_agent`)은 정책 + 프롬프트 + self-report로 운영한다 (한계는 Non-goals 참조).
- 조사 결과를 사용자에게 먼저 제시하고, 수정은 사용자 승인 후 진행한다.
- 변경 범위가 극소한 경우 에이전트 수를 줄여 효율을 높인다.
- 기본값은 6이며, `parallel-audit 10`/`parallel-audit 10 <컨텍스트>`만 exhaustive override다. 10은 기본값이 아니고, trailing 컨텍스트는 우선순위 판단용으로 보존한다.
- Codex 세션 경로에서는 completed audit thread를 다음 batch/retry 전에 명시적으로 `close_agent`로 닫는다.
- `SAFE`는 유효한 auditor 결과가 모두 확보된 뒤에만 반환한다. `RECOVERABLE VIOLATION` 재디스패치 중이거나 `BLOCKED (VIOLATION)` unit이 남아 있으면 완료로 간주하지 않는다.
- DA 피드백 루프(run-da)와 목적이 다르다: DA는 설계/코드 품질을 반복 개선하고, 전수조사는 변경의 안전성을 일회성으로 검증한다.
