# Mode: audit

일회성 사이드이펙트/회귀 감사 — 현재 changeset의 사이드이펙트/회귀/엣지케이스를 6개 auditor bundle로 병렬 점검하고 결과를 보고한 뒤 종료한다. 1 outer round 고정 — 자동 반복 재발사 금지 (『SAFE까지』 지시에도 같은 changeset에 재발사하지 않고, fix 후 재검증은 사용자 확인을 거쳐 새 단발 감사로 실행).

이 모드는 changeset 감사 전용이다 — 특정 변경과 무관한 일반 전수조사·코드베이스 조사 요청은 이 모드의 대상이 아니며 스킬 없이 직접 수행한다.

## Step 0: Review Intensity 우회

audit 모드는 preflight 체크리스트를 건너뛴다 — 감사 자체가 명시적 전체 조사 요청이다.
[`../references/intensity-procedure.md`](../references/intensity-procedure.md)는 읽지 않는다.

## modifier 해석

| 항목 | 값 |
|------|-----|
| 기본 fan-out | 6개 auditor bundle (에이전트 6개) |
| open thread cap | current session의 `agents.max_threads` (unset 기본 6) |
| `MAX` modifier | 기본 6 bundle을 10개 세부 관점으로 확장 (exhaustive override) |
| `fresh` modifier | audit 모드 부적용 — 라운드 반복이 없으므로 해석하지 않는다 |
| trailing 자유 텍스트 | `audit` (및 `MAX`) 토큰 뒤 나머지 인자 전체를 메인 에이전트의 우선순위 판단 컨텍스트로 보존 (Step 1 `git diff` 결과와 결합) |
| 정수 에이전트 수 인자 | 폐지 — fan-out 크기는 기본 6 bundle / `MAX` 10 관점으로만 결정한다 |
| 에이전트 권한 | 읽기 전용. codex exec 경로(Claude Code/headless)는 Layer 1(`codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules`)으로 구조적 강제. Codex 세션(`spawn_agent`)은 정책 + 프롬프트 + self-report로 운영 (Non-goals 참조) |

## 용어 정책

이 모드는 Claude Code 세션과 Codex 세션 양쪽에서 호출된다. 본문은 도구-중립 용어를 쓰며, 런타임별 실제 도구 binding은 [run-da의 "런타임 도구 매핑" 표](../references/runtime-mapping.md#런타임-도구-매핑)를 단일 진실 원천으로 참조한다 (중복 복제 금지).

| 용어 유형 | 처리 |
|----------|------|
| 사용자 질문 실행 지시 | "질문 도구" |
| 파일 읽기 지시 | "파일 읽기 도구" |
| 병렬 실행 지시 | "병렬 실행" 또는 "fan-out 실행" |

auditor-specific delta: audit 모드의 fan-out 대상은 auditor다 (standard review profile). role은 auditor이며 bundle 단위 fan-out이고, Arbiter는 사용하지 않는다.

## 런타임 경로

"나는 어떤 세션에서 실행되고 있는가?" 로 경로를 선택한다. 런타임별 도구 binding은 [run-da의 "런타임 도구 매핑" 표](../references/runtime-mapping.md#런타임-도구-매핑)가 단일 소스다. 공통 subprocess 위생/제약(세션 네임스페이스, stdin pipe, 환경변수 유실)은 [`../../using-codex-exec/SKILL.md`](../../using-codex-exec/SKILL.md)와 run-da의 "codex exec 경로 위생 규칙"을 따른다. Step 3b는 audit 모드의 prompt/result flow와 guards를 정의하고, command literal은 [`../references/arbiter-scaling.md`](../references/arbiter-scaling.md)의 role별 명령 `reviewer / Auditor` 템플릿을 참조한다.

| 경로 | 조건 |
|------|------|
| Codex 세션 | Codex CLI가 호스트 — native subagent fan-out (delegation 허용 시). delegation-denied fallback은 [`../references/hardening-contract.md`](../references/hardening-contract.md)의 "Delegation fallback" 참조 |
| Claude Code 세션 | Claude Code가 호스트 — codex exec 기본 (사전점검: `command -v codex` + `command -v codex-exec-supervised` + `codex-exec-supervised --check` 모두 성공해야 한다. wrapper `--check`는 setsid/timeout/codex 의존성을 자체 검증하고 OK 시 exit 0, 부재 시 exit 127을 반환한다 — codex exec를 호출하지 않으므로 사전점검 비용이 작다). codex 또는 wrapper 미가용/capability probe 실패 시 Claude Code fallback (아래 Step 3c) |
| headless 세션 | CI, `claude -p`, `codex exec` subprocess |

`CODEX_CI=1`만으로 세션 유형을 구분하지 않는다.
Codex 세션의 상세 wait/write/violation 계약은 [`../references/hardening-contract.md`](../references/hardening-contract.md)의 `Codex 세션 하드닝 계약`을 따른다.
다만 audit 모드에서는 auditor read-only/no-write 경계가 항상 우선한다.

Direct Codex 세션에서 `$run-da audit` 호출은 auditor bundle 범위의 내부 native subagent fan-out explicit delegation으로 취급한다. 이 권한은 auditor bundle 범위에만 한정되며, `codex-exec-supervised` fallback approval이나 tracked write, branch mutation, commit/push, GitHub write, `wt`, `nrs`, rebuild 권한을 부여하지 않는다. 정본은 [`hardening-contract.md`의 `Skill-internal fan-out authorization`](../references/hardening-contract.md#skill-internal-fan-out-authorization)이다.

## 조사 bundle

6개 기본 조사 bundle을 정의한다. 에이전트 수에 따라 자동 조절한다.

| # | 관점 | 조사 대상 |
|---|------|----------|
| 1 | Security + API | credential 노출, 권한 오남용, 입력 검증 누락, 외부 API 계약/인터페이스 호환 |
| 2 | Performance + Dependencies | O(n^2) 알고리즘, 불필요한 재계산, 메모리 누수, 버전 충돌, breaking change |
| 3 | Tests + Edge Cases | 기존 테스트 호환, 동작 회귀, 빈 입력, 경계값, 동시성, null/undefined |
| 4 | Platform (macOS + NixOS) | darwin/nixos 전용 경로, launchd/systemd 설정, Homebrew Cask, Nix derivation |
| 5 | Adjacent Side Effects | 수정하지 않은 인접 코드에 대한 영향, 공유 상태/환경 파급, 과거 의도적 결정의 무근거 되돌림(decision regression), `mv`/rename이 symlink·mode·owner 속성 파괴, 시계열 회귀(이미 고쳐진 문제 재등록) ([`../references/decision-regression-audit.md`](../references/decision-regression-audit.md)) |
| 6 | Docs / Consistency | SKILL.md, CLAUDE.md, README 정합성, 라우팅 테이블, 네이밍/구조 일관성 |

### 에이전트 수 조절 규칙

- 에이전트 수 > 조사 bundle 수: 큰 bundle을 더 세부 관점으로 분할한다.
  예: `Platform (macOS + NixOS)`를 `macOS`, `NixOS`로 분할.
- 에이전트 수 < 조사 bundle 수: 연관된 bundle을 하나의 에이전트에 통합한다.
  예: `Docs / Consistency`를 `Adjacent Side Effects`와 함께 묶는다.
- 명시적 exhaustive override: `run-da audit MAX` (또는 `run-da audit MAX <컨텍스트>`)는 기본 6 bundle을 다음 10개 세부 관점으로 확장한다. `<컨텍스트>`가 있으면 `MAX` 토큰 뒤 나머지 토큰을 메인 에이전트의 우선순위 판단 컨텍스트로 보존한다.
  `Security`, `API`, `Performance`, `Dependencies`, `Tests`, `Edge Cases`, `macOS`, `NixOS`, `Adjacent Side Effects`, `Docs / Consistency`

## 절차

### Step 1: 변경 범위 파악

```bash
git diff --stat          # 변경 파일 목록과 크기
git diff                 # 전체 diff
git log --oneline -5     # 최근 커밋 컨텍스트
```

변경 파일 수, diff 줄 수, 영향 받는 모듈을 파악한다.

### Step 1b: 의사결정 컨텍스트 팩 수집 (조건부)

변경이 제거·단순화·되돌림·리팩터 방향이거나 변경 파일이 git상 왕복 핫스팟이면, [`../references/decision-regression-audit.md`](../references/decision-regression-audit.md)의 Step A에 따라 "의사결정 컨텍스트 팩"을 수집한다 — 메인이 commit/PR/issue(+있으면 CIR/ADR·로컬 세션 로그)에서 과거 결정·되돌림 이력을 추려 Step 3의 auditor 프롬프트에 주입한다. 네트워크(`gh`/`glab`)·세션 로그 접근은 메인 전용이며 auditor는 git read-only 보강만 한다. 발동 조건·소스 계층·시계열 게이트·처리·세션 로그 방법론은 해당 문서가 SSOT다. git으로 버전관리되는 모든 저장소에서 동작하며 기록 관습이 없어도 commit 히스토리만으로 진행한다(graceful degradation).

### Step 2: 조사 bundle 분배

에이전트 수(기본 6, `MAX`면 10개 세부 관점)에 맞게 위 6개 bundle을 분배한다.
컨텍스트는 `audit` (및 `MAX`) 토큰 뒤 나머지 인자 전체다.
메인 에이전트는 이 컨텍스트를 보존하고 Step 1의 `git diff` 결과와 결합하여 bundle 분배 가중치 결정에 활용한다.
변경 내용에 따라 관련도가 높은 bundle에 에이전트를 더 배정할 수 있다.

예: Nix 설정 변경이면 `Platform (macOS + NixOS)`와 `Adjacent Side Effects`에 더 많은 비중을 두고,
`MAX`가 명시된 경우에만 `macOS`와 `NixOS`를 분리한다.

### 병렬 디스패치 사전 조건

N개 에이전트를 병렬 실행하기 전에 다음을 확인한다:

- [ ] 각 에이전트의 조사 bundle이 독립적이다 (공유 상태 없음)
- [ ] 에이전트 간 결과 간섭이 없다 (한 에이전트의 결과가 다른 에이전트의 판단에 영향 안 미침)
- [ ] 각 에이전트에게 전달하는 컨텍스트가 자기 완결적이다 (다른 에이전트 결과 참조 불필요)

### Step 3: 병렬 에이전트 실행

N개 에이전트를 한 턴에 병렬 실행한다 (런타임이 지원하는 경우). headless 세션은 [run-da 런타임 도구 매핑](../references/runtime-mapping.md#런타임-도구-매핑)에 따라 serial foreground로 순차 실행한다 — 각 subprocess의 종료와 result를 직렬로 확인한다.

각 에이전트에게 전달하는 내용:

1. 변경 diff 전체
2. 프로젝트 컨텍스트: CLAUDE.md, 관련 모듈 구조
3. 담당 조사 bundle: 위 테이블에서 배정된 bundle과 조사 대상
4. 출력 형식 지시: 아래 "결과 형식"에 따라 반환

에이전트 지시 원칙 (run-da Auditor 계약과 동일, [`../references/hardening-contract.md`](../references/hardening-contract.md)의 "역할별 경계" 표 `Auditor` 행 계승):

- 정책상 읽기 전용: 모든 write를 금지한다 — tracked/untracked workspace write, scratch PoC, branch/remote/GitHub write, host mutation, main-agent-only command (`wt`, `nrs`, rebuild 계열) 실행 금지 (구조적 enforcement 부재는 Non-goals 참조).
- 담당 bundle에만 집중한다. 다른 bundle은 언급하지 않는다.
- 발견 사항마다 구체적 파일:줄과 근거를 제시한다.
- decision regression / cross-layer 속성 점검 (담당 bundle에 해당 시): 과거 의도적 결정을 근거 없이 되돌리는지 주입된 의사결정 컨텍스트 팩 + git read-only(`git log -S`/`blame`/`show`)로 점검하고, 충돌 시 과거 결정의 출처(commit SHA / PR# / issue#)를 첨부한다("줄 수 많다=군살"은 근거가 아니다). 파일 교체(`mv`/rename/in-place write)면 기존 파일의 symlink(다른 레이어가 관리)·mode/권한·owner 보존 여부를 확인한다. 회귀 판정 전 시계열 게이트(증거 시점 이후 수정 커밋 대조)를 적용한다. 상세는 [`../references/decision-regression-audit.md`](../references/decision-regression-audit.md).
- 발견이 없으면 SAFE를 반환한다.
- Codex 세션 경로에서는 `run-da` canonical contract의 standard review profile을 사용한다.
- `wait_agent` timeout이나 단순 지연만으로 auditor를 kill하거나 self-auditing으로 대체하지 않는다.
- tracked workspace write, branch mutation, commit/push, GitHub write, `wt`/`nrs`/rebuild 계열은 auditor가 실행하지 않는다.
- Codex 세션 경로에서는 current session의 open slot을 넘기지 않는다. `agents.max_threads`는 unset일 때 기본 6이며, completed thread도 `close_agent` 전에는 슬롯을 점유한다.

### Step 3a: Codex 세션 경로

- Codex 세션에서는 이 경로를 기본으로 사용한다.
- fan-out 직전에 아래 "사후 변조 감지" 섹션의 사전 스냅샷을 메인 에이전트 컨텍스트에 보존한다.
- bundle마다 fresh native subagent 1개를 standard review profile로 `spawn_agent` 실행한다.
- bundle 수가 현재 open slot보다 많으면 batch로 나눈다.
- 모든 결과는 `wait_agent`로 수신한다. timeout만으로 실패 처리하거나 auditor를 중간 kill/self-auditing으로 대체하지 않는다.

### Step 3b: codex exec 경로 (Claude Code 세션 · headless 세션)

- 임시 디렉토리 생성 호출에서는 세션 네임스페이스 `_DA_SID`를 계산하고(run-da의 codex exec 경로 위생 규칙 계승), 이전 실행 잔재를 정리한 뒤 `DA_DIR`을 생성하고, 두 리터럴 값을 stdout으로 출력한다:
  ```zsh
  # 세션 네임스페이스 (run-da의 codex exec 경로 위생 규칙 계승)
  _DA_SID="${CODEX_COMPANION_SESSION_ID:+${CODEX_COMPANION_SESSION_ID:0:8}}"
  if [ -z "$_DA_SID" ]; then
    if command -v sha1sum >/dev/null 2>&1; then
      _DA_SID="$(printf '%s' "$PWD" | sha1sum | head -c 8)"
    else
      _DA_SID="$(printf '%s' "$PWD" | shasum | head -c 8)"
    fi
  fi
  # 이전 실행 잔재 정리 (같은 세션 네임스페이스의 고아 DA_DIR)
  rm -rf /tmp/da-${_DA_SID}-audit-*(N)
  DA_DIR=$(mktemp -d /tmp/da-${_DA_SID}-audit-XXXXXX)
  [ -d "$DA_DIR" ] || { echo "missing DA_DIR=$DA_DIR"; exit 1; }
  # 메인 에이전트가 이후 셸 호출에서 리터럴 재사용하기 위해 stdout으로 출력한다
  # (run-da의 "셸 호출 간 환경변수 유실" 공통 주의 참조)
  printf '_DA_SID=%s\n' "$_DA_SID"
  printf 'DA_DIR=%s\n' "$DA_DIR"
  ```

  > literal 재사용 환각 주의 (issue #632): `_DA_SID`/`DA_DIR`은 출력된 리터럴과 호출 직전 guard를 유지한다. Generic rule은 [`using-codex-exec/known-issues.md`](../../using-codex-exec/references/known-issues.md#literal-재사용-시-random-suffix-환각-금지-issue-632)를 따른다.
- 단일 shell 전환 미적용: auditor prompt/result 생성, aggregate 집계가 multi-call 흐름이므로 단일 shell 강제로 바꾸지 않는다. 대신 위 issue #632 literal 재사용 guard를 적용한다.
- 후속 prompt 생성 호출은 stdout의 `DA_DIR` 리터럴 값을 그대로 재설정하고 guard한 뒤, 파일 편집 도구나 구조화 writer로 bundle prompt를 작성한다:
  ```zsh
  DA_DIR=/tmp/da-c4a35fc4-audit-AbCdEf
  UNIT=side-effects
  [ -d "$DA_DIR" ] || { echo "missing DA_DIR=$DA_DIR"; exit 1; }
  # diff/이슈 본문은 untrusted input이다. shell heredoc에 직접 삽입하지 말고,
  # 파일 편집 도구나 구조화 writer로 "$DA_DIR/$UNIT.md"에 작성한다.
  ```
- 후속 auditor 호출은 stdout의 `DA_DIR` 리터럴 값을 그대로 재설정하고 guard한 뒤, [`../references/arbiter-scaling.md`](../references/arbiter-scaling.md)의 role별 명령 `reviewer / Auditor` 템플릿으로 실행한다:
  ```zsh
  DA_DIR=/tmp/da-c4a35fc4-audit-AbCdEf
  UNIT=side-effects
  [ -d "$DA_DIR" ] || { echo "missing DA_DIR=$DA_DIR"; exit 1; }
  [ -f "$DA_DIR/$UNIT.md" ] || { echo "missing prompt=$DA_DIR/$UNIT.md"; exit 1; }
  ```
  `--ignore-user-config`/`--ignore-rules`/model-effort pins/`CODEX_PROGRAMMATIC=1` placement 등 command literal은 [`../references/arbiter-scaling.md`](../references/arbiter-scaling.md)의 role별 명령이 SSOT다.
- 세션 네임스페이스(`$_DA_SID`)와 stdin pipe 패턴은 [`../references/runtime-mapping.md`](../references/runtime-mapping.md)의 "codex exec 경로 위생 규칙"을 따른다.
- 임시 prompt/result 파일, stderr/result 검증, 백그라운드 실행 제어, stdin pipe 경쟁, heredoc hang 제약은 [/using-codex-exec 스킬](../../using-codex-exec/SKILL.md)과 [known-issues.md](../../using-codex-exec/references/known-issues.md)를 따른다.

### Step 3c: Claude Code fallback (codex 미가용 시)

- 위 표 사전점검(`command -v codex` + `command -v codex-exec-supervised` + `codex-exec-supervised --check`) 실패 또는 codex exec 실행 실패 시에만 진입한다.
- bundle별 병렬 실행을 수행한다. 실행 binding 상세(Claude Code 고유 fallback lifecycle, 완료 알림 수신, thread 관리)는 [`../references/runtime-mapping.md`](../references/runtime-mapping.md)의 "Claude Code 세션 fallback 세부 정보" 섹션을 참조한다.
- 프롬프트에 read-only/no-write 범위를 명시한다.
- 완료 알림 수신 후 결과를 집계하고, `RECOVERABLE VIOLATION`/`STATEFUL VIOLATION` 분류 규칙은 Step 4와 동일하게 적용한다.

### Step 4: 결과 수신 및 검증

모든 에이전트의 결과를 수신한 뒤:

1. 각 발견 사항의 유효성을 검증한다 (파일:줄이 실제로 존재하는지, 근거가 타당한지).
2. 중복 발견을 제거한다 (여러 bundle에서 같은 문제를 지적한 경우).
3. 심각도 순으로 정렬한다.
4. Codex 세션 경로에서는 결과 집계가 끝난 completed audit thread를 `close_agent`로 닫아 다음 batch/retry 슬롯을 회수한다.
5. 사후 변조 감지 (Codex 세션 경로 전용): 아래 "사후 변조 감지" 섹션의 비교를 수행한다. codex exec 경로는 read-only sandbox가 workspace write를 구조적으로 차단하므로 생략한다.
6. `RECOVERABLE VIOLATION`은 `SAFE`에서 제외하고 fresh auditor로 재디스패치한다. 이는 auditor가 새 상태 코드를 정의하는 것이 아니라, 메인 에이전트가 출력 형식 위반이나 scope 침범 같은 contract breach를 감지했을 때 부여하는 조율 분류다. 단 Codex 세션 경로에서 status delta가 동시에 존재하면 `STATEFUL VIOLATION` 분류가 우선한다.
7. `STATEFUL VIOLATION`만 `BLOCKED (VIOLATION)`로 남긴다. 이 경우 사용자에게 불완전한 run이 보고되기 전에는 fresh auditor로 재디스패치하지 않는다.

### Step 5: 종합 리포트 생성

아래 "결과 형식"에 따라 종합 리포트를 사용자에게 제시한다.

리포트 제시 후 `rm -rf "$DA_DIR"`로 이번 실행의 임시 디렉토리를 삭제한다 (codex exec 경로에서 생성한 경우). BLOCKED (VIOLATION)로 중단된 경우에는 진단 보존을 위해 삭제하지 않는다.

## 사후 변조 감지 (Codex 세션 경로 전용)

codex exec 경로(Claude Code 세션 · headless 세션)는 사후 변조 감지를 생략한다 — auditor가 `codex-exec-supervised --sandbox read-only`로 실행되어 workspace write가 구조적으로 차단되므로 사후 변조 감지가 불필요하다.

Codex 세션(`spawn_agent`) 경로는 read-only sandbox를 구조적으로 강제할 수 없으므로 (Non-goals 참조) 다음 최소 감지를 적용한다:

1. fan-out 직전: `git status --porcelain=v1 --untracked-files=all` 출력을 메인 에이전트가 자기 컨텍스트에 보존한다 (파일 저장 없음). `--untracked-files=all`로 이미 untracked인 directory 내부의 신규 파일까지 열거한다 (기본값은 directory 단위로만 열거).
2. 모든 결과 수신 후: 같은 명령을 재실행해 보존한 출력과 비교한다. 사전/사후에 같은 플래그를 쓰지 않으면 untracked directory 내부 신규 파일이 한쪽에만 열거되어 false positive가 난다.
3. delta가 있으면 원인 불문 `STATEFUL VIOLATION (workspace changed during audit)`으로 fail-closed BLOCKED 처리한다 — 행위자 귀속(auditor unit vs. 사용자/메인 에이전트/외부 프로세스)이 구조적으로 불가능하므로 (Non-goals 참조) unit 특정이나 부분 cleanup을 시도하지 않는다.

감지 불가 범위(content-only/ignored/write-then-revert/cross-workspace mutation)는 Non-goals 참조. self-report가 이들 범위에서 수정을 보고하거나 의심되면 delta 유무와 무관하게 `BLOCKED (VIOLATION)`로 fail-closed 처리한다.

## 결과 형식

### 요약 테이블

```
## 사이드이펙트/회귀 감사 결과

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
| stateful violation | 메인 에이전트가 current unit을 `BLOCKED (VIOLATION)`로 분류하고, tracked write/branch mutation/commit/push/GitHub/main-agent-only command/host mutation 시도 여부와 이번 실행이 만든 산출물 범위를 먼저 확인한다. 사용자에게 불완전한 run이 보고되기 전에는 fresh auditor 재디스패치 금지 |

에이전트의 BLOCKED를 무시하거나 같은 조건으로 재시도하지 않는다.

### 전원 SAFE인 경우

```
감사 완료: SAFE — 사이드이펙트/회귀 발견 없음
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
- 사용자에게 판단을 요청할 때는 [사용자 질문 시 맥락 설명 의무](../references/main-agent-obligations.md#사용자-질문-시-맥락-설명-의무)를 따른다 (WTF Moment 방지).

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

## Non-goals

이 모드가 구조적으로 보장하지 않는 auditor-specific 경계. 공통 한계(zsh 전제, `/tmp` 쓰기 sandbox 정책, project-scoped MCP 차단 한계, `spawn_agent` per-child read-only sandbox 부재)는 [run-da Non-goals](../SKILL.md#non-goals)를 단일 진실 원천으로 참조한다 (중복 방지).

1. child tool-call audit trail 부재: Codex parent API는 자식 에이전트의 tool-call 전체 audit trail을 노출하지 않는다. 따라서 `RECOVERABLE VIOLATION` vs. `STATEFUL VIOLATION` 구분은 구조적 판단이 아니라 (a) 자식 self-report, (b) 메인 에이전트의 사후 `git status --porcelain=v1` 스냅샷 비교(Codex 세션 경로 전용)의 조합으로 근사한다. 이 근사의 한계:
   - aggregate 한정 (attribution 불가): 병렬 N auditor의 사전/사후 status 비교는 global workspace mutation 여부만 알 수 있다. 원인 actor는 (a) auditor unit 하나 이상, (b) 사용자/메인 에이전트/외부 프로세스의 concurrent mutation 중 구조적으로 구분 불가다 → `STATEFUL VIOLATION (workspace changed during audit)`으로 즉시 fail-closed BLOCKED 보고하며, unit 귀속과 부분 cleanup은 시도하지 않는다.
   - content-only mutation 미감지: 이미 dirty인 tracked 파일의 내용 추가 변경, untracked 파일의 내용 변경은 `git status --porcelain=v1` 출력이 같아 감지되지 않는다.
   - ignored 파일 미감지: `.gitignore` 대상은 `git status` 출력에서 제외되어 스냅샷에 포함되지 않는다.
   - write-then-revert 미감지: 파일을 수정한 뒤 원상복구하면 최종 `git status` delta가 사전 스냅샷과 같아 감지되지 않는다.
   - cross-workspace mutation 미감지: branch/remote/GitHub/host/main-agent-only command mutation은 `git status`로 감지 불가이므로 self-report 누락 또는 의심 시 fail-closed `BLOCKED` 처리한다.

2. auditor 기본 실행 경로의 read-only sandbox 적용 (issue #593 Layer 1): Claude Code 세션과 headless 세션의 기본 경로는 `codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral`이다. supervised wrapper(setsid + timeout, [`using-codex-exec/references/known-issues.md`](../../using-codex-exec/references/known-issues.md) §15)가 process-group kill을 보장하고, read-only sandbox + `--ignore-user-config` + `--ignore-rules`가 audit 의도(read-only + execpolicy mutation 차단)를 구조적으로 강제한다. auditor는 scratch PoC를 수행하지 않는다 ([`../references/hardening-contract.md`](../references/hardening-contract.md) "역할별 경계" — Auditor는 모든 write/scratch PoC 금지). 파일·문서 증거 기반 검증만 가능하며, scratch PoC 권한은 for_plan/for_pr의 DA reviewer 역할에만 적용된다.

## 주의사항

- 에이전트는 읽기 전용이다. 코드/tracked workspace 수정을 금지한다. codex exec 경로(Claude Code/headless)는 Layer 1(supervised wrapper + `--sandbox read-only` + `--ignore-user-config` + `--ignore-rules`)으로 구조적 강제, Codex 세션(`spawn_agent`)은 정책 + 프롬프트 + self-report로 운영한다 (한계는 Non-goals 참조).
- 감사 결과를 사용자에게 먼저 제시하고, 수정은 사용자 승인 후 진행한다.
- 변경 범위가 극소한 경우 에이전트 수를 줄여 효율을 높인다.
- 기본 fan-out은 6 bundle이며, `MAX` modifier만 exhaustive override(10개 세부 관점)다. 10은 기본값이 아니고, trailing 컨텍스트는 우선순위 판단용으로 보존한다.
- Codex 세션 경로에서는 completed audit thread를 다음 batch/retry 전에 명시적으로 `close_agent`로 닫는다.
- `SAFE`는 유효한 auditor 결과가 모두 확보된 뒤에만 반환한다. `RECOVERABLE VIOLATION` 재디스패치 중이거나 `BLOCKED (VIOLATION)` unit이 남아 있으면 완료로 간주하지 않는다.
- for_plan/for_pr 루프와 목적이 다르다: 루프는 품질을 반복 개선하고, audit는 안전성을 일회 검증한다.
- 일회성 강제: "`SAFE`가 나올 때까지" 같은 지시에도 같은 changeset에 자동으로 반복 재발사하지 않는다. 1회 감사 후 결과를 보고하고, fix 후 재검증이 필요하면 사용자 확인을 거쳐 새 단발 감사로 실행한다. 매 재감사가 새 리뷰 표면을 만드는 비수렴이 의심되면(감사는 일회성이라 자동 라운드 카운팅이 없다) 자동 재발사 대신 사용자에게 보고하고 판단을 구한다.
