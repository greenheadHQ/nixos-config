---
name: run-da
argument-hint: "[for_plan|for_pr|both] [full] [fresh]"
description: |
  Run Devil's Advocate review on plans or code. Args: for_plan, for_pr, both. Modifier: full, fresh.
  Trigger: 'DA', 'DA 피드백', '피드백 루프', 'YAGNI 리뷰', '코드 리뷰 루프', 'run-da'.
  NOT for PR 코멘트 (use review-pr-feedback). NOT for 전수조사 (use parallel-audit).
---

# Devil's Advocate 피드백 루프

기본 경로는 4개 reviewer bundle을 변경 규모에 맞게 병렬 실행하여 계획/코드를 엄격 리뷰한다.
명시적 exhaustive override가 필요할 때만 `run-da ... full`로 8개 세부 도메인까지 확장한다.

**주의: Review Intensity 판단은 메인 LLM의 역할이 아니다**

Review Intensity 판단은 독립 에이전트가 수행한다.
"이건 단순한 변경이니 DA를 건너뛰어도 된다"는 생각이 떠오르면,
그것이 정확히 독립 에이전트가 존재하는 이유다.
DA 호출 자체를 생략하지 마라 — run-da를 호출하면
독립 에이전트가 SKIP/LITE/FULL을 자동 판단한다.
합리화 방지 상세는 [references/protocol.md](references/protocol.md) 참조.

## 모드

| `$ARGUMENTS` | 동작 |
|--------------|------|
| `for_plan` | 계획 단계 DA 1회 — 계획 파일 또는 대화 컨텍스트 대상 |
| `for_pr` | 구현 후 코드 DA 1회 — git diff 대상 |
| `both` | for_plan → 사용자 승인 → 구현 → for_pr 순차 수행 (각 단계의 실행 강도는 Review Intensity에 따라 **독립적으로** 결정됨) |
| *(비어있음)* | 사용자에게 모드 선택을 질문한다 |

### `full` modifier

모드 뒤에 `full`을 추가하면 (예: `for_pr full`, `both full fresh`)
**Review Intensity 판단을 건너뛰고 exhaustive override를 실행**한다.

| 구분 | 기본 동작 | `full` 동작 |
|------|----------|------------|
| 경중 판단 | 자동 수행 (SKIP/LITE/FULL) | 건너뜀 → exhaustive FULL 강제 |
| fan-out | 판단 결과에 따라 0 / 선택 bundle / 4 reviewer bundles | 항상 8개 세부 도메인 |
| 사용 시점 | 일반 | 사용자 명시적 exhaustive 요청, recall 민감도가 높은 변경, 예외적 고위험 diff |

자동 판정의 **FULL**도 여전히 강한 기본 검토다. 차이는 fan-out뿐이다:
- 자동 `FULL` = `Correctness`, `Design`, `Regression`, `Maintainability` 4 bundle
- `full` modifier = 위 bundle을 8개 세부 도메인으로 확장한 exhaustive override

### `fresh` modifier

모드 뒤에 `fresh`를 추가하면 (예: `for_pr fresh`, `both fresh`) **DA 에이전트에게 이전 라운드의 맥락을 전달하지 않는다.**

| 구분 | 기본 동작 | `fresh` 동작 |
|------|----------|-------------|
| DA 프롬프트 | 이전 라운드 결과 요약 포함 가능 | 코드/계획 + 프로젝트 컨텍스트만 전달. 이전 라운드 언급 금지 |
| 편향 | 이전 발견에 anchoring 가능 | 매 라운드 완전 독립 리뷰 |
| 무한 루프 위험 | 낮음 (이전 맥락으로 중복 감소) | 높음 (동일 지적 반복 가능 → 반복 감지 규칙으로 대응) |

`fresh` 사용 시 메인 에이전트는 DA 에이전트 프롬프트에 다음을 포함하지 않는다:
- 이전 라운드의 발견 사항
- 이전 라운드에서 수용/기각된 지적 내역
- "이번에는 다른 관점에서 봐주세요" 등 이전 라운드를 암시하는 표현

메인 에이전트는 finding의 세부 관점 + 위치(파일:줄 또는 계획 항목 번호) 조합으로 라운드 간 반복 감지를 수행한다.

## 빠른 참조

| 항목 | 위치 |
|------|------|
| Review Intensity 판단 규칙 | [references/intensity-rules.md](references/intensity-rules.md) |
| DA reviewer bundle 상세 + 프롬프트 템플릿 | [references/da-domains.md](references/da-domains.md) |
| 피드백 프로토콜 + 합리화 방지 상세 | [references/protocol.md](references/protocol.md) |
| Arbiter 프롬프트 + 5가지 판정 기준 | [references/arbiter-prompt.md](references/arbiter-prompt.md) |
| Arbiter/Intensity 스케일링 + 실행 계약 | [references/arbiter-scaling.md](references/arbiter-scaling.md) |
| Selective consistency 정책 (vote-shape + offline kappa) | [references/stability-measurement.md](references/stability-measurement.md) |
| Validation-path catalog (공용) | [../plan-with-questions/references/validation-paths.md](../plan-with-questions/references/validation-paths.md) |

## 용어 정책

이 스킬은 Claude Code 세션과 Codex 세션 양쪽에서 호출된다. 본문은 **도구-중립 용어**를 쓰고, 런타임별 실제 도구는 아래 "런타임 도구 매핑" 표로 binding한다.

| 용어 유형 | 처리 | 설명 |
|----------|------|-----|
| 섹션명 / 정책명 | **keep** | 정책 이름으로 기능 (예: `"질문 도구 미지원 대응"`). 역사적 이유로 legacy 정책명 참조가 남아 있을 수 있다 |
| 사용자 질문 실행 지시 | **"질문 도구"** | Claude Code 전용 도구명을 본문에서 literal로 쓰지 않는다 |
| 파일 읽기 지시 | **"파일 읽기 도구"** | 런타임 도구 매핑 표의 "파일 읽기" 행에 binding |
| 병렬 실행 지시 | **"병렬 실행"** 또는 "fan-out 실행" | 런타임 도구 매핑 표의 "fan-out 실행" 행에 binding |

## 런타임 도구 매핑

**"나는 어떤 세션에서 실행되고 있는가?"** 로 경로를 선택한다. 아래 표는 본문에서 쓰는 중립 용어를 세션별 **실제 도구명**으로 binding하는 **glossary**다. 표 자체는 용어 정책의 예외로, literal 도구명을 그대로 명시한다. 본문은 계속 중립 용어를 사용하되, 런타임별 실행 시 이 표의 binding을 참조한다. 상세 실행 계약(실패 처리, N=3, 질문 도구 미지원 대응, Delegation fallback)의 단일 진실 원천은 [`references/arbiter-scaling.md`](references/arbiter-scaling.md)다.

| 행동 | Codex 세션 | Claude Code 세션 | headless 세션 |
|------|-----------|------------------|---------------|
| 사용자에게 질문 (**blocking tool call**) | `request_user_input` | `AskUserQuestion` 도구 | **미지원** (자동 전이 적용) |
| fan-out 실행 (기본) | `spawn_agent` → `wait_agent` → `close_agent` (delegation 허용 시) | `Bash tool` + `run_in_background: true`로 `codex exec` subprocess 병렬 발사 (codex exec 사전점검 성공 시 기본) | `codex exec` subprocess를 **serial foreground**로 순차 실행 (완료 알림/`&+wait` 없음) |
| fan-out 실행 (fallback) | codex exec subprocess (아래 "Delegation fallback" + `arbiter-scaling.md` 실행 계약) | `Agent` tool + `run_in_background: true` (codex exec 사전점검 실패 시 — "Claude Code 세션 fallback 세부 정보" 섹션) | — |
| 결과 수집 | `wait_agent` 반환값, 또는 `exec_command`로 `cat`/`sed` 셸 읽기 | `Read` 도구 | `cat`/`sed` via shell |
| 파일 읽기 | `exec_command`로 `cat`/`sed`/`rg` | `Read` 도구 | `cat`/`sed`/`rg` |

**plain-text 재개 ≠ 질문 도구** — 일반 채팅 "질문 후 다음 턴 재개"는 blocking tool call이 아니므로 질문 도구로 간주하지 않는다. 질문 도구가 필수인 지점(SKIP 승인, 3회 반복 판정, 5회 라운드 초과)에서 Codex 세션은 `request_user_input`을 호출하고, headless 세션은 stdin 입력 불가로 **자동 상태 전이 경로**(arbiter-scaling.md)로 처리한다.

**review profile 매핑** (fan-out 대상 역할별):
- **Arbiter (strong review profile)** — Codex: `model="gpt-5.5"`, `reasoning_effort="high"`. Claude Code: `model: "opus"`.
- **reviewer / Intensity / auditor (standard review profile)** — Codex: `model="gpt-5.5"`, `reasoning_effort="medium"`. Claude Code: `model: "sonnet"`.

`CODEX_CI=1`만으로 세션 유형을 구분하지 않는다 (Codex 세션에서도 같은 값이 보일 수 있음). **현재 세션 호스트**를 기준으로 경로를 고른다.

본문에서 **codex exec 경로**는 Claude Code 세션과 headless 세션의 공통 실행 substrate를 가리킨다.

> **셸 호출 간 환경변수 유실 — 모든 런타임 공통 주의** — Claude Code 셸 실행 환경, Codex의 `exec_command`, headless 세션의 독립 셸 호출 모두 **호출마다 별도 shell이 생성**되어 환경변수가 다음 호출로 전달되지 않는다 (`$DA_DIR` 유실. 실측: Codex `exec_command` 첫 호출에서 `FOO=kept` 설정 후 둘째 호출에서 unset 확인). `mktemp -d` 결과를 다음 호출에서 쓰려면 (1) **단일 shell 호출 안에 체이닝**하거나 (2) 경로를 stdout에 출력해 **메인 에이전트가 다음 호출에서 리터럴로 재사용**한다. 셸 세션 공유를 가정하면 결과 파일 경로 오류와 리뷰 루프 실패로 이어진다.

### codex exec 경로 위생 규칙

- **세션 네임스페이스**: 동시 다중 세션 간 /tmp 디렉토리 충돌을 방지한다.
  ```zsh
  # 세션 식별 해시 (8자: /tmp 경로 가독성과 충돌 확률의 균형)
  _DA_SID="${CODEX_COMPANION_SESSION_ID:+${CODEX_COMPANION_SESSION_ID:0:8}}"
  # CODEX_COMPANION_SESSION_ID 미노출 환경(headless/CI)에서 디렉토리별 충돌 방지용 결정적 해시
  [ -z "$_DA_SID" ] && _DA_SID="$(printf '%s' "$PWD" | sha1sum 2>/dev/null | head -c 8 || printf '%s' "$PWD" | shasum | head -c 8)"
  ```
  이후 모든 `mktemp -d`와 cleanup glob에서 `$_DA_SID`를 prefix에 포함한다.
- **모드 시작 시 이전 임시 디렉토리 정리**: for_plan 시작 시 `rm -rf /tmp/da-${_DA_SID}-pr-*(N) /tmp/da-${_DA_SID}-arbiter-*(N) /tmp/da-pr-*(N) /tmp/da-arbiter-*(N)`, for_pr 시작 시 `rm -rf /tmp/da-${_DA_SID}-plan-*(N) /tmp/da-${_DA_SID}-intensity-*(N) /tmp/da-plan-*(N) /tmp/da-intensity-*(N)`. 같은 모드의 이전 라운드는 라운드 교체 시 정리.
  zsh `(N)` qualifier로 매칭 파일 없을 때 오류를 방지한다. legacy glob(NS 없음)은 전환기 고아 디렉토리 정리용이다.
- **결과 파일 참조**: `$INTENSITY_DIR`, `$DA_DIR`, `$ARBITER_DIR` 변수로 정확히 참조한다. **`/tmp/da-*` 와일드카드 glob 금지** — 이전 실행의 결과가 섞인다.
- **셸 호출 간 변수 유지** (모든 런타임 공통): 위 "런타임 도구 매핑" 아래의 공통 주의 참조. 런타임 종류와 무관하게 셸 호출마다 별도 shell이 생성되므로 `mktemp -d` 결과를 stdout으로 출력해 메인 에이전트가 다음 호출에서 리터럴로 재사용하거나 단일 shell에 체이닝한다. 상세 패턴은 [`arbiter-scaling.md`](references/arbiter-scaling.md)의 "셸 호출 변수 유실 방지" 참조.
- **stdin pipe로 프롬프트 전달**: 모든 codex exec 호출에서 `cat "$DIR/prompt.md" | env CODEX_PROGRAMMATIC=1 codex exec ... -` stdin pipe 패턴을 사용한다. pipe EOF가 stdin을 자동으로 닫아 background 전환 시 stdin hang을 구조적으로 방지한다. `< /dev/null`은 pipe가 대체하므로 불필요. 인라인 인자 `"$(cat file)"`는 사용하지 않는다. **`CODEX_PROGRAMMATIC=1` env assignment는 pipeline 우측 codex 프로세스에 적용되어야 한다 (issue #585).**
- **Intensity/Arbiter는 foreground 실행** (단일 exec): 결과를 즉시 확인한다. **reviewer만 병렬 실행** (런타임별 병렬 실행 매커니즘은 "런타임 도구 매핑" 표 참조).

## Claude Code 세션 fallback 세부 정보

Claude Code 세션에서 codex exec 사전점검이 실패했을 때 legacy fallback으로 대체하는 경로의 Claude-Code-고유 lifecycle이다. review profile 매핑은 상단 "런타임 도구 매핑" 표 참조.

| 항목 | Claude Code fallback |
|------|----------------------|
| fan-out | background fallback 실행 |
| wait | 자동 완료 알림 (background task notification) |
| close | 불필요 (완료 시 자동 해제) |
| thread-cap | Claude Code의 병렬 제한을 따름 |
| violation 처리 | 프롬프트에서 읽기 전용을 지시하지만, 구조적 보증이 아닌 프롬프트 수준 제약이다. 하위 fallback unit이 side effect를 만들 가능성이 있으므로, 아래 `"Codex 세션 하드닝 계약"`의 역할별 경계(reviewer: 읽기+검색+scratch PoC만, Arbiter/Intensity: 읽기 전용)를 프롬프트에 명시한다 |

## Codex 세션 하드닝 계약

이 섹션은 **Codex 세션 경로에서만** 적용된다.
codex exec 경로(Claude Code 세션 · headless 세션)는 [arbiter-scaling.md](references/arbiter-scaling.md)의 subprocess 계약을 따른다.
여러 규칙이 충돌하면 **더 엄격한 역할 제한**이 generic PoC 허용보다 우선한다.

### 용어와 우선순위

| 용어 | 뜻 | 우선순위 |
|------|-----|---------|
| strong review profile | Arbiter spawn의 강한 리뷰 설정 (model/effort literal은 상단 "런타임 도구 매핑" 표의 **review profile 매핑** 불릿이 단일 소스) | Arbiter spawn 기본값 |
| standard review profile | reviewer/auditor/Intensity spawn의 기본 리뷰 설정 (상단 **review profile 매핑** 불릿이 단일 소스) | DA/Intensity spawn 기본값 |
| conservative wait | `wait_agent` timeout이나 단순 지연은 실패 신호가 아니다. 명시적 agent failure, documented violation, 최종 응답 파싱 실패 전에는 kill/self-auditing 대체를 금지한다 | 조급한 조기 종료보다 우선 |
| single-writer | tracked workspace write, 최종 파일 수정, branch mutation, commit/push, GitHub comment/issue/PR write는 메인 에이전트 소유다. explicit delegation만 예외다 | generic PoC 허용보다 우선 |
| main-agent-only commands | `wt`, `nrs`, rebuild 계열과 host/repo 상태를 바꾸는 동급 명령은 direct fan-out subagent가 실행하지 않는다 | lock-sensitive convenience보다 우선 |
| recoverable violation | 출력 형식 위반, bundle scope 침범, prompt contract 미준수처럼 workspace/branch/host 외부 상태를 바꾸지 않은 위반 | 결과 discard 후 fresh rerun |
| stateful violation | tracked write, branch mutation, commit/push, GitHub write, main-agent-only command 실행, host mutation처럼 상태를 바꾼 위반 | 즉시 중단 + offending-unit 산출물만 정리, `BLOCKED`, CLEAR 불가 |

### 역할별 경계

| 역할 | 허용 | 금지 |
|------|------|------|
| DA reviewer | 읽기, 검색, out-of-repo private scratch PoC (`mktemp -d`, `umask 077`) | tracked write, branch mutation, commit/push, GitHub write, `wt`/`nrs`/rebuild 계열 |
| Arbiter / Intensity | 읽기 전용 검증 | 모든 write, scratch PoC, main-agent-only command |
| Auditor (`parallel-audit`) | 읽기 전용 검증 | 모든 write, scratch PoC, main-agent-only command |
| 메인 에이전트 | tracked write, external write, main-agent-only command, explicit delegation | Review Intensity/Arbiter 판정 대체 |

### `VIOLATION` 공통 처리

- `RECOVERABLE`: offending unit 결과만 폐기하고 fresh rerun한다. rerun 전까지 `CLEAR` 계산에 포함하지 않는다.
- `STATEFUL`: 현재 라운드를 즉시 중단한다. offending thread를 닫고, 이번 라운드에서 offending unit이 만든 scratch dir, 임시 ref/branch, 산출물만 정리한다.
- `STATEFUL` 경로에서도 기존 local tracked/untracked 변경은 자동 정리하지 않는다. 비가역적 외부 side effect가 있었거나 cleanup 범위를 특정할 수 없으면 해당 unit을 `BLOCKED`로 남기고 명시적 rerun 전까지 종료한다.

### Delegation fallback (정책 요약)

Codex 세션에서 `spawn_agent`가 정책상 거부되면(예: `multi_agent=false`, `"delegation not permitted"`·`"multi_agent disabled"` 에러) 메인 에이전트는 다음 정책을 따른다. **subprocess 실행 계약(role별 명령, sandbox 플래그, stdin pipe, 실패 처리)의 SSOT는 [`references/arbiter-scaling.md`](references/arbiter-scaling.md)의 "Codex delegation-denied fallback" 섹션**이다.

**"같은 에이전트 컨텍스트 serial" 금지** — 메인 에이전트가 reviewer/Arbiter/Intensity 프롬프트를 자기 컨텍스트에서 순차 실행하는 것은 위 "역할별 경계" 표의 메인 에이전트 금지 항목(`Review Intensity/Arbiter 판정 대체`)을 위반한다. fresh 독립 실행 단위를 유지해야 한다.

**자동 우회 금지** — `spawn_agent` 거부는 정책 의사표시다. `codex exec --full-auto`(workspace-write)로 조용히 우회하면 reviewer/Arbiter/Intensity의 no-write 경계가 구조적으로 보장되지 않는다. 자동 subprocess fallback을 허용하기 **전에** 사용자 승인을 얻고, 실행 시 read-only sandbox를 강제한다 (명령 상세는 위 SSOT).

1. **BLOCKED + 사용자 승인 대기** (기본): `spawn_agent` 거부 감지 시 현재 DA 라운드 중단, 사용자에게 "delegation 거부 감지 — codex exec subprocess fallback 승인?"을 보고한다. 승인 수단은 런타임별로 다음과 같이 취한다:
   - 질문 도구 지원 런타임 (Claude Code 세션, Codex 세션): 질문 도구로 즉시 승인 요청. 승인 시 **같은 턴에서 바로** fallback 단계 진행.
   - 질문 도구 미지원 런타임 (headless 세션 등): plain-text로 상황 보고 후 DA 루프 종료한다. 사용자는 새 메시지에서 "fallback 진행"으로 명시 승인하거나 `run-da <mode>`를 다시 실행하여 **새 라운드로** 재개한다 (이전 라운드 상태는 복원하지 않음, 깨끗한 fresh round로 시작). 명시 승인 없이 자동 재개하지 않는다.
2. **codex exec subprocess fallback** (사용자 승인 후에만): [`arbiter-scaling.md`](references/arbiter-scaling.md)의 "Codex delegation-denied fallback" 섹션이 정의한 role별 명령(standard profile = `model="gpt-5.5"`+medium, strong profile = `model="gpt-5.5"`+high)을 `--sandbox read-only --ignore-user-config --ephemeral`로 실행한다 (user config의 MCP/plugin/connector surface 차단을 위해 `--ignore-user-config`가 필수다. 단, cwd 기반 project config는 차단하지 못하므로 한계는 Non-goals #1 참조). 각 unit은 독립 subprocess.

라운드 요약에는 경로와 sandbox 모드를 명시한다:

```text
Round N 요약: fan-out 경로 = codex exec subprocess serial fallback (--sandbox read-only, reason: delegation unavailable + user approved)
```

## DA reviewer bundles

| reviewer bundle | 포함 세부 도메인 | 집중 관점 | 심각도 기준 |
|-----------------|------------------|----------|-----------|
| Correctness | HALLUCINATION + SECURITY | 존재하지 않는 가정, 안전하지 않은 경계, 검증 누락 | 실행 즉시 실패 또는 공격 표면 확대 |
| Design | YAGNI + NGMI | 과설계, 막다른 구조, 요구 변경 시 붕괴할 추상화 | 구조적 재작업 필요 |
| Regression | SIDE_EFFECT + CONSISTENCY | 기존 동작 파괴, 인접 기능 파급, 프로젝트 패턴 드리프트 | 기존 계약/관례 훼손 |
| Maintainability | READABILITY + CLEAN_CODE | 이해 난이도, 중복, 매직값, 죽은 코드 | 유지보수 비용 증가 |

기본 FULL path는 위 4개 reviewer bundle을 사용한다. 각 finding은 bundle 이름 아래에서
세부 관점(`HALLUCINATION`, `SECURITY` 등)을 함께 표기한다.

명시적 exhaustive override(`run-da ... full`)는 위 bundle을 다음 8개 세부 도메인으로 확장한다:
`YAGNI`, `NGMI`, `HALLUCINATION`, `SECURITY`, `SIDE_EFFECT`, `CONSISTENCY`, `READABILITY`, `CLEAN_CODE`.

상세 프롬프트 템플릿과 출력 형식은 [references/da-domains.md](references/da-domains.md) 참조.

## Review Intensity (변경 규모 판단)

Review Intensity 판단은 **독립 에이전트**가 수행한다. 메인 LLM은 판단에 관여하지 않는다.
Codex 세션에서는 native subagent, Claude Code 세션과 headless 세션에서는 codex exec을 사용한다.
`full` modifier가 있으면 이 단계를 건너뛰고 exhaustive override로 직행한다.

### 3단계

| 단계 | 에이전트 수 | 사용자 승인 | 설명 |
|------|-----------|-----------|------|
| SKIP | 0 | 질문 도구 **필수** (런타임별 매핑: 상단 "런타임 도구 매핑" 표) | DA 완전 생략 |
| LITE | Correctness 필수 + 관련 reviewer bundles | 불필요 | 필요한 bundle만 선택 실행 |
| FULL | 4 reviewer bundles | 불필요 | 4 reviewer bundle 기본 리뷰 |

`full` modifier는 위 표의 FULL과 다르다. 자동 FULL은 4 reviewer bundle이고,
modifier `full`은 Review Intensity를 건너뛰고 exhaustive 8-domain path로 진입한다.

### 판단 실행 절차

1. 변경 규모 판단용 입력을 준비한다.
   - for_pr: `git diff --stat main...HEAD` (파일 목록+라인 수만, 내용 불포함)
   - for_plan: 계획 요약 (변경 대상 파일 목록 + 변경 유형)
2. **Codex 세션 경로**:
   - fresh intensity subagent 1개를 standard review profile로 띄운다.
   - 프롬프트에는 `references/intensity-rules.md`를 직접 읽고 SKIP/LITE/FULL 중 하나를 첫 줄에 반환하라고 지시한다. Intensity는 no-write role이므로 파일 수정, scratch PoC, main-agent-only command 실행을 금지한다.
   - 결과는 `wait_agent`로 받고, timeout만으로 실패 처리하거나 중간 kill/self-auditing 대체를 하지 않는다. 파싱이 끝나면 completed intensity thread를 `close_agent`로 닫는다.
3. **codex exec 경로** (Claude Code 세션 · headless 세션):
   - 모든 런타임은 상단 "런타임 도구 매핑" 아래의 공통 주의(셸 호출 간 변수 유실)를 따른다.
   - 임시 디렉토리를 생성한다: `INTENSITY_DIR=$(mktemp -d /tmp/da-${_DA_SID}-intensity-XXXXXX)`
   - 프롬프트 파일을 생성한다 (umask 077로 권한 제한):
     ```zsh
     (umask 077; cat > "$INTENSITY_DIR/prompt.md" <<'PROMPT'
     references/intensity-rules.md를 직접 읽어 판단 알고리즘 규칙을 적용하라.
     아래 변경 정보를 보고 SKIP/LITE/FULL 중 하나를 판정하라.
     결과의 첫 줄에 판정(SKIP/LITE/FULL), 이후에 근거를 기술하라.
     리뷰만 수행하고 파일을 수정하지 마라.

     {for_pr: `git diff --stat main...HEAD` 출력 / for_plan: 변경 대상 파일 목록 + 변경 유형}
     PROMPT
     )
     ```
   - **foreground 실행** (단일 exec이므로 결과를 즉시 확인):
     ```zsh
     # marker must apply to `codex`, not `cat` (issue #585): Codex 0.124+ hooks의 early-exit 신호.
     cat "$INTENSITY_DIR/prompt.md" | env CODEX_PROGRAMMATIC=1 codex exec --full-auto --ephemeral \
       -c model_reasoning_effort="medium" \
       -o "$INTENSITY_DIR/result.md" \
       - \
       2>"$INTENSITY_DIR/stderr.log"
     ```
4. 메인 LLM이 결과를 읽고 판정에 따라 분기한다:
   - SKIP → 질문 도구로 사용자 승인 (기존 SKIP 절차)
   - LITE → reviewer bundle 선택 (기존 LITE 절차)
   - FULL → 4 reviewer bundles 실행
5. **실패 시 FULL 강제** — Codex 세션 경로에서는 응답 파싱 실패/agent failure, codex exec 경로에서는 결과 파일 없음·빈 결과·exit code 비정상·첫 줄 파싱 실패.
6. Review Intensity 판단 결과(SKIP/LITE/FULL)와 근거를 사용자에게 보고한다.

판단 알고리즘 규칙 상세 및 예시는 [references/intensity-rules.md](references/intensity-rules.md) 참조.

### SKIP 절차

1. 질문 도구로 사용자에게 DA 생략 승인을 요청한다:
   - 변경 내용 요약
   - SKIP 판단 근거
   - "DA를 생략해도 괜찮겠습니까?"
2. 사용자가 승인하면 DA를 생략하고 해당 모드(for_plan/for_pr)를 종료하여 상위 워크플로로 복귀한다.
3. 사용자가 거부하면 LITE 또는 FULL로 승격하여 DA를 진행한다.

질문 도구를 호출할 수 없는 런타임에서는 [`references/arbiter-scaling.md`](references/arbiter-scaling.md)의 "질문 도구 미지원 대응" 섹션을 따른다 (자동 LITE 승격 등).

### LITE 절차

1. `Correctness`는 항상 포함한다. (`SECURITY`와 `HALLUCINATION` 안전장치를 함께 유지한다.)
2. 코드 변경이면 `Regression`도 기본 포함한다 (기존 호출부 회귀 검출을 위해).
3. 나머지 bundle 중 변경 성격에 직접 관련된 bundle만 선택한다.
   선택 판단 기준: 해당 bundle의 "집중 대상"(da-domains.md)이 이번 변경에 적용되는가.
4. 선택되지 않은 bundle은 `NOT_RUN`으로 기록한다.
5. 선택된 bundle만으로 기존 for_plan/for_pr 절차를 수행한다.
6. 종료 조건: **선택된 bundle 전부 CLEAR** (`NOT_RUN` bundle은 평가 대상 아님).

### LITE 예시

단일 함수명 정리 리팩터링 → **Correctness** + **Regression** + **Maintainability** 실행.
미실행: Design(NOT_RUN).
이유: Correctness는 항상 포함, Regression은 코드 변경이므로 기본 포함,
Maintainability는 이름/가독성 변화에 직접 관련된다.

### LITE 라운드 요약 형식

```text
Round N 요약 (LITE: 선택 M개/전체 4개 reviewer bundles): DA 발견 X건
→ Arbiter: CONFIRMED Y건, NOT_AN_ISSUE Z건, NEEDS_MORE_INFO W건
bundle별: Correctness CLEAR, Regression 2건(CONFIRMED 1, NOT_AN_ISSUE 1), ...
미실행: Design(NOT_RUN), ...
selective: trigger P건 → stable Q건, split R건, fragmented S건, partial_failure T건  ← selective consistency 발동 라운드에만 추가
```

selective consistency가 발동하지 않은 라운드는 마지막 줄을 생략한다. stability_status 집계 규칙은 [references/protocol.md](references/protocol.md)의 "라운드 요약 기록" 참조.

## 절차

### for_plan 모드

0. **Review Intensity 판단**을 수행한다.
   - `full` modifier가 있으면 이 단계를 건너뛰고 exhaustive override(8개 세부 도메인)로 진입한다.
   - SKIP → SKIP 절차를 따른다. 승인 시 for_plan을 종료한다.
   - LITE → LITE 절차에 따라 실행할 reviewer bundle을 선택한다.
   - FULL → 4 reviewer bundles를 실행한다.
1. 현재 계획 파일 또는 대화 컨텍스트에서 계획 내용을 수집한다.
2. 선택된 reviewer bundle 또는 explicit exhaustive override의 세부 도메인별 DA 에이전트를 **병렬 실행**한다.
   - **Codex 세션 경로**:
     - 선택된 review unit마다 fresh native subagent 1개를 standard review profile로 `spawn_agent` 실행한다.
     - 각 프롬프트는 [da-domains.md](references/da-domains.md)의 공통 프롬프트 구조에 계획 전체 내용을 포함하고, "계획 외의 관련 파일도 직접 읽어 탐색하라", "out-of-repo scratch PoC만 허용한다", "`run-da` canonical contract의 stateful-violation 금지 작업(`tracked write`, `branch mutation`, `commit/push`, `GitHub write`, `main-agent-only command`, `host mutation`)을 축약 없이 따르라", "규칙 위반은 finding 대신 `VIOLATION`으로 반환하라"를 명시한다.
     - 선택된 review unit 수가 current session의 open slot을 넘으면 batch한다. `agents.max_threads`는 unset일 때 기본 6이며, completed thread도 `close_agent` 전에는 슬롯을 계속 점유한다.
     - `wait_agent` timeout만으로 실패 처리하거나 reviewer를 kill/self-auditing으로 대체하지 않는다.
     - `fresh` modifier와 selective propagation 규칙은 동일하게 적용한다.
   - **codex exec 경로** (Claude Code 세션 · headless 세션):
     - 실행 전 [`../using-codex-exec/SKILL.md`](../using-codex-exec/SKILL.md)의 패턴 4 (exec 우회)와 패턴 5 (DA 피드백 루프)를 참조한다.
     - 세션별 임시 디렉토리를 생성한다: `DA_DIR=$(mktemp -d /tmp/da-${_DA_SID}-plan-XXXXXX)`. 모든 런타임은 상단 "런타임 도구 매핑" 아래의 공통 주의(셸 호출 간 변수 유실)를 따른다 (경로를 `echo`로 출력하여 이후 호출에서 리터럴로 재사용).
     - 선택된 review unit별 프롬프트 파일을 생성한다: `$DA_DIR/{unit}.md`
     - 선택된 review unit 수만큼 `cat "$DA_DIR/{unit}.md" | env CODEX_PROGRAMMATIC=1 codex exec --full-auto --ephemeral -c model_reasoning_effort="medium" -o "$DA_DIR/{unit}-result.md" -`를 런타임별로 기동한다. Claude Code 세션의 기본 병렬 경로와 fallback 경로는 상단 "런타임 도구 매핑" 표의 binding을 따른다. **headless 세션은 serial foreground** (완료 알림·`&+wait` 없음). 런타임별 매커니즘은 "런타임 도구 매핑" 표 참조.
     - Claude Code 세션: 병렬 실행 완료 알림을 수신하면 sleep/poll 없이 바로 결과를 수집한다. headless 세션: 각 subprocess 종료를 직렬로 확인한다.
     - 모든 런타임 공통: `& + wait` shell-level 병렬 금지, `cat file | env CODEX_PROGRAMMATIC=1 codex exec ... -` stdin pipe로 프롬프트 전달. pipe EOF가 stdin을 닫으므로 `< /dev/null`은 불필요. 인라인 인자 `"$(cat file)"`는 사용하지 않는다. **`CODEX_PROGRAMMATIC=1` env assignment는 codex 프로세스에 적용되어야 한다 (회피: `CODEX_PROGRAMMATIC=1 cat ...`은 cat에만 적용 — issue #585).**
     - [`../using-codex-exec/SKILL.md`](../using-codex-exec/SKILL.md) 패턴 5의 실행 흐름(`-o` 사용법, 결과 파일 검증, 명령 실행 순서)만 참고한다. 프롬프트 내용 규칙은 이 스킬의 `fresh`/프롬프트 조향 금지 규칙이 우선한다.
3. 모든 reviewer 결과를 수신한 후 종합 리포트를 작성한다.
   - Codex 세션 경로: `wait_agent` 결과를 집계한 뒤, 다음 round/retry 전에 completed reviewer thread를 `close_agent`로 닫는다.
   - Codex 세션 경로: `VIOLATION` 처리 규칙은 위 `Codex 세션 하드닝 계약`의 공통 처리 정의를 따른다. offending unit은 rerun 또는 `BLOCKED` 해소 전까지 `CLEAR` 계산에 포함하지 않는다.
   - codex exec 경로: 선택된 review unit(FULL 기본 4개, LITE는 선택한 수, explicit exhaustive는 8개) 전부 실행(Claude Code는 병렬, headless는 serial) 완료 후, 각 `$DA_DIR/{unit}-result.md`를 파일 읽기 도구로 명시적으로 읽어 수집한다. 결과 파일이 없거나 빈 경우, 또는 exit code가 0이 아니면 실패로 판정한다.
   - 실패한 review unit만 재실행한다. codex exec 경로는 라운드마다 새 `DA_DIR`을 생성하여 이전 라운드 산출물과 분리한다.
4. findings 0건이고 `VIOLATION`/`BLOCKED` review unit이 없으면 → ALL CLEAR, 종료.
5. findings 1건 이상 → Arbiter 실행:
   - 5a. **first-pass Arbiter**: Arbiter 프롬프트를 조립한다 ([arbiter-prompt.md](references/arbiter-prompt.md)의 **for_plan 조립 규칙** 참조).
     for_plan에서는 반드시 계획 원문을 포함해야 하며,
     상세 조립 형식은 arbiter-prompt.md의 "프롬프트 조립 > for_plan 모드" 참조.
     - Codex 세션 경로: fresh Arbiter subagent 1개를 실행하고 `wait_agent`로 결과를 수신한 뒤, 다음 round/retry 전에 completed Arbiter thread를 `close_agent`로 닫는다.
     - codex exec 경로: **foreground 실행** (단일 exec이므로 결과를 즉시 확인. [`arbiter-scaling.md`](references/arbiter-scaling.md) 실행 계약 참조).
   - 5b. **Selective consistency trigger 검사**: first-pass 결과의 VERDICT_JSON 블록을 읽어 [stability-measurement.md](references/stability-measurement.md)의 trigger 조건에 매치되는 finding을 식별한다 (조건 정의는 해당 문서가 SSOT).
   - 5c. **N=3 재판정** (trigger 매치 finding에 한해): 동일 Arbiter 프롬프트로 독립 N=3을 실행한다. 실행 계약과 환경 격리는 [arbiter-scaling.md](references/arbiter-scaling.md)의 "N=3 실행 계약" 섹션 참조. selective consistency 서브런은 outer round 카운트에 포함되지 않는다.
   - 5d. **vote-shape 집계**: 세션 scope에 맞는 harness(`~/.claude/scripts/fleiss-kappa.py` 또는 `~/.codex/scripts/fleiss-kappa.py` — 양쪽에 동일 소스가 프로비저닝된다)로 3개 결과 markdown의 VERDICT_JSON 블록을 파싱하여 finding별 `stability_status`(stable/split/fragmented) 및 `low_confidence_warning`을 `per_finding[]`에서, top-level `partial_failure`(및 `missing`/`file_level_failures`/`per_file_malformed` 세부)를 얻는다. `partial_failure=true`이면 해당 finding은 `per_finding`에 포함되지 않으므로 caller는 finding별 BLOCKED로 매핑한다 (상세는 [references/protocol.md](references/protocol.md) 참조).
   - 5e. **상태 전이 적용** — 상세 전이표는 [protocol.md](references/protocol.md)의 "Selective consistency 상태 전이" 참조. trigger되지 않은 finding은 `stability_status=N/A`로 first-pass 결과 그대로 사용.
   - 결과를 수집하여 사용자에게 전건 보고한다 (vote-shape/low_confidence_warning이 있으면 함께 보고):
     - CONFIRMED_ISSUE + CRITICAL + (N/A 또는 stable) + `low_confidence_warning=false`: **진행 차단** (현재 라운드 중단 → 즉시 수정 → 수정 확인 후 다음 라운드 진행).
     - CONFIRMED_ISSUE + HIGH/MEDIUM/LOW + (N/A 또는 stable) + `low_confidence_warning=false`: 자동으로 계획에 반영한다.
     - NOT_AN_ISSUE + (N/A 또는 stable) + `low_confidence_warning=false`: 보고만 (반영 불필요).
     - NEEDS_MORE_INFO 또는 `stability_status=split`: 질문 도구로 사용자 판단을 요청한다 (vote-shape와 minority verdict도 함께 보고).
     - 임의 verdict + (N/A 또는 stable) + `low_confidence_warning=true`: **fail-closed 승격** — 질문 도구로 사용자 판단 요청 (unanimous/단일 Arbiter라도 LOW confidence 이력이 있으면 기존 LOW-confidence NOT_AN_ISSUE 자동 NEEDS_MORE_INFO 계약을 유지).
     - `stability_status=fragmented` 또는 `partial_failure=true`: **BLOCKED** — 질문 도구 지원 런타임에서는 판단 요청, 미지원 런타임에서는 자동 승격 금지(중단 보고).
6. 반영 후 동일 선택 review unit을 **새 reviewer 실행 단위**로 재실행한다.
   - Codex 세션 경로: 이전 round의 completed reviewer/Arbiter thread를 모두 닫은 뒤 새 subagent들을 띄운다.
   - codex exec 경로: 새 `codex exec` 프로세스와 새 `DA_DIR`을 사용한다.
7. 선택된 review unit 전부 CLEAR를 반환할 때까지 반복한다.

### for_pr 모드

0. **Review Intensity 판단**을 수행한다.
   - `full` modifier가 있으면 이 단계를 건너뛰고 exhaustive override(8개 세부 도메인)로 진입한다.
   - SKIP → SKIP 절차를 따른다. 승인 시 for_pr을 종료한다.
   - LITE → LITE 절차에 따라 실행할 reviewer bundle을 선택한다.
   - FULL → 4 reviewer bundles를 실행한다.
1. 변경사항이 커밋되어 있는지 확인한다 (`git status --porcelain`이 빈 출력이면 clean).
   `git diff main...HEAD`로 diff를 수집한다.
   - diff를 프롬프트에 직접 포함한다 (exec 우회 패턴).
   - diff가 과도하게 크면 (`git diff main...HEAD | wc -l`로 확인) 기계적 변경(flake.lock, hash 변경 등)을 필터링한 축약 diff를 사용한다.
     `git diff main...HEAD -- ':!flake.lock'`로 lock 파일 제외 가능.
2. 선택된 reviewer bundle 또는 explicit exhaustive override의 세부 도메인별 DA 에이전트를 **병렬 실행**한다.
   - **Codex 세션 경로**:
     - 선택된 review unit마다 fresh native subagent 1개를 standard review profile로 `spawn_agent` 실행한다.
     - 각 프롬프트는 [da-domains.md](references/da-domains.md)의 공통 프롬프트 구조에 diff를 `<git-diff>` 태그로 감싸서 포함하고, "diff 외부의 관련 파일도 직접 읽어 탐색하라", "out-of-repo scratch PoC만 허용한다", "`run-da` canonical contract의 stateful-violation 금지 작업(`tracked write`, `branch mutation`, `commit/push`, `GitHub write`, `main-agent-only command`, `host mutation`)을 축약 없이 따르라", "규칙 위반은 finding 대신 `VIOLATION`으로 반환하라"를 명시한다.
     - 선택된 review unit 수가 current session의 open slot을 넘으면 batch한다. `agents.max_threads`는 unset일 때 기본 6이며, completed thread는 `close_agent` 전까지 슬롯을 점유한다.
     - `wait_agent` timeout만으로 실패 처리하거나 reviewer를 kill/self-auditing으로 대체하지 않는다.
     - `fresh` modifier와 selective propagation 규칙은 동일하게 적용한다.
   - **codex exec 경로** (Claude Code 세션 · headless 세션): for_plan 모드의 codex exec 경로 절차와 동일하다. 아래 두 가지만 다르며, 나머지(프롬프트 파일 생성, codex exec 명령·플래그, Claude Code 병렬 / headless serial foreground 구분, stdin pipe, `&+wait` 금지, 공통 주의사항)는 for_plan 블록이 단일 진실이다. 중복 서술하지 않는다.
     - 임시 디렉토리 prefix: `DA_DIR=$(mktemp -d /tmp/da-${_DA_SID}-pr-XXXXXX)` (for_plan은 `-plan-`).
     - 입력 조립: 각 review unit 프롬프트에 계획 원문 대신 diff를 포함한다 (위 Codex 세션 경로 블록 참조).
3. 모든 reviewer 결과를 수신한 후 종합 리포트를 작성한다.
   - Codex 세션 경로: `wait_agent` 결과를 집계한 뒤, 다음 round/retry 전에 completed reviewer thread를 `close_agent`로 닫는다.
   - Codex 세션 경로: `VIOLATION` 처리 규칙은 위 `Codex 세션 하드닝 계약`의 공통 처리 정의를 따른다. offending unit은 rerun 또는 `BLOCKED` 해소 전까지 `CLEAR` 계산에 포함하지 않는다.
   - codex exec 경로: 결과 파일이 없거나 빈 경우, 또는 exit code가 0이 아니면 실패로 판정한다. 실패한 review unit만 재실행한다.
   - codex exec 경로는 라운드마다 새 `DA_DIR`을 생성하여 이전 라운드 산출물과 분리한다.
4. findings 0건이고 `VIOLATION`/`BLOCKED` review unit이 없으면 → ALL CLEAR, 종료.
5. findings 1건 이상 → Arbiter 실행:
   - 5a. **first-pass Arbiter**: Arbiter 프롬프트를 조립한다 ([arbiter-prompt.md](references/arbiter-prompt.md) 참조).
     - Codex 세션 경로: fresh Arbiter subagent 1개를 실행하고 `wait_agent`로 결과를 수신한 뒤, 다음 round/retry 전에 completed Arbiter thread를 `close_agent`로 닫는다.
     - codex exec 경로: **foreground 실행** (단일 exec이므로 결과를 즉시 확인. [`arbiter-scaling.md`](references/arbiter-scaling.md) 실행 계약 참조).
   - 5b. **Selective consistency trigger 검사**: first-pass 결과의 VERDICT_JSON 블록을 읽어 [stability-measurement.md](references/stability-measurement.md)의 trigger 조건에 매치되는 finding을 식별한다 (조건 정의는 해당 문서가 SSOT).
   - 5c. **N=3 재판정** (trigger 매치 finding에 한해): 동일 Arbiter 프롬프트로 독립 N=3을 실행한다. 실행 계약과 환경 격리는 [arbiter-scaling.md](references/arbiter-scaling.md)의 "N=3 실행 계약" 섹션 참조. selective consistency 서브런은 outer round 카운트에 포함되지 않는다.
   - 5d. **vote-shape 집계**: 세션 scope에 맞는 harness(`~/.claude/scripts/fleiss-kappa.py` 또는 `~/.codex/scripts/fleiss-kappa.py` — 양쪽에 동일 소스가 프로비저닝된다)로 3개 결과 markdown의 VERDICT_JSON 블록을 파싱하여 finding별 `stability_status`(stable/split/fragmented) 및 `low_confidence_warning`을 `per_finding[]`에서, top-level `partial_failure`(및 `missing`/`file_level_failures`/`per_file_malformed` 세부)를 얻는다. `partial_failure=true`이면 해당 finding은 `per_finding`에 포함되지 않으므로 caller는 finding별 BLOCKED로 매핑한다 (상세는 [references/protocol.md](references/protocol.md) 참조).
   - 5e. **상태 전이 적용** — 상세 전이표는 [protocol.md](references/protocol.md)의 "Selective consistency 상태 전이" 참조. trigger되지 않은 finding은 `stability_status=N/A`로 first-pass 결과 그대로 사용.
   - 결과를 수집하여 사용자에게 전건 보고한다 (vote-shape/low_confidence_warning이 있으면 함께 보고):
     - CONFIRMED_ISSUE + CRITICAL + (N/A 또는 stable) + `low_confidence_warning=false`: **진행 차단** (현재 라운드 중단 → 즉시 수정 → 수정 확인 후 다음 라운드 진행).
     - CONFIRMED_ISSUE + HIGH/MEDIUM/LOW + (N/A 또는 stable) + `low_confidence_warning=false`: 자동으로 코드에 반영하고 커밋한다.
     - NOT_AN_ISSUE + (N/A 또는 stable) + `low_confidence_warning=false`: 보고만 (반영 불필요).
     - NEEDS_MORE_INFO 또는 `stability_status=split`: 질문 도구로 사용자 판단을 요청한다 (vote-shape와 minority verdict도 함께 보고).
     - 임의 verdict + (N/A 또는 stable) + `low_confidence_warning=true`: **fail-closed 승격** — 질문 도구로 사용자 판단 요청 (unanimous/단일 Arbiter라도 LOW confidence 이력이 있으면 기존 LOW-confidence NOT_AN_ISSUE 자동 NEEDS_MORE_INFO 계약을 유지).
     - `stability_status=fragmented` 또는 `partial_failure=true`: **BLOCKED** — 질문 도구 지원 런타임에서는 판단 요청, 미지원 런타임에서는 자동 승격 금지(중단 보고).
6. 반영 후 동일 선택 review unit을 **새 reviewer 실행 단위**로 재실행한다.
   - Codex 세션 경로: 이전 round의 completed reviewer/Arbiter thread를 모두 닫은 뒤 새 subagent들을 띄운다.
   - codex exec 경로: 새 `codex exec` 프로세스와 새 `DA_DIR`을 사용한다.
7. 선택된 review unit 전부 CLEAR를 반환할 때까지 반복한다.
8. 최종 승인 후 push한다 (네트워크/auth 정책 의존 — 아래 "Non-goals" 섹션 참조).

### both 모드

1. **for_plan 절차** 전체를 수행한다.
2. 사용자의 계획 승인을 받은 뒤 구현을 진행한다.
3. 구현 완료 후 1차 커밋을 생성한다.
4. **for_pr 절차** 전체를 수행한다.
5. 최종 커밋 후 push하고 PR을 생성한다.

## 피드백 프로토콜

### 메인 에이전트 역할

| 수행 | 금지 |
|------|------|
| CONFIRMED_ISSUE 수정 | Review Intensity 판단 |
| tracked workspace write, branch mutation, commit/push, GitHub write | DA reviewer/Auditor/Arbiter/Intensity에 single-writer 작업 위임 |
| `wt`, `nrs`, rebuild 계열 실행 | main-agent-only command를 direct fan-out subagent에 넘기기 |
| 질문 도구 호출 (SKIP/NEEDS_MORE_INFO) | DA finding 직접 판정 |
| Arbiter 결과 수신 및 보고 | "사용자 지시"로 DA 기각 |
| 결과 파일 파싱 | 프롬프트 조향 |

핵심 원칙 요약:

- **Arbiter 독립 판정**: DA findings는 독립 Arbiter 에이전트가 판정한다. 메인 에이전트는 판정하지 않는다.
  메인 에이전트는 CONFIRMED_ISSUE 항목의 수정만 담당한다.
- **CONFIRMED_ISSUE 자동 반영**: Arbiter가 CONFIRMED_ISSUE로 판정한 항목은 자동으로 반영한다.
  CRITICAL 심각도는 진행을 차단하고 즉시 수정한다.
- **사용자 전건 보고**: 모든 Arbiter 판정 결과(CONFIRMED_ISSUE, NOT_AN_ISSUE, NEEDS_MORE_INFO)를 사용자에게 보고한다.
  NEEDS_MORE_INFO 항목은 질문 도구로 사용자 판단을 요청한다.
- **Conservative wait**: Codex 세션 경로에서 `wait_agent` timeout이나 단순 지연만으로 reviewer/Arbiter/Intensity를 kill하지 않는다.
  explicit failure signal, documented violation, 최종 응답 파싱 실패가 없는 한 self-auditing으로 대체하지 않는다.
- **Single-writer 유지**: tracked workspace write, branch mutation, commit/push, GitHub write, `wt`/`nrs`/rebuild 계열은 메인 에이전트가 수행한다.
  DA reviewer의 PoC는 repo 밖 scratch에 한정한다.
- **PoC 의무화**: DA가 위반을 지적하면 구체적 파일:줄 또는 계획 항목 번호를 제시해야 한다.
  증거 없는 추상적 우려는 Arbiter가 NOT_AN_ISSUE로 판정한다.
- **Violation 처리**: recoverable violation은 offending unit discard 후 fresh rerun한다.
  stateful violation은 현재 라운드를 중단하고, offending unit이 이번 라운드에서 만든 산출물만 정리한다. 기존 local 변경은 자동 정리하지 않으며, `BLOCKED` 해소 또는 명시적 rerun 전에는 `CLEAR`로 간주하지 않는다.
- **Fresh perspective 보장**: 매 라운드마다 새 에이전트를 사용한다.
  `fresh` modifier 사용 시 이전 라운드 맥락도 완전히 차단한다.
- **Selective propagation 기본값**: Arbiter/후속 reviewer에게는 unique findings, conflicting findings,
  high-severity findings, user decision required findings만 전달한다.
  raw transcript 전체, CLEAR 결과, 중복 low-signal finding의 all-to-all broadcast는 금지한다.
  `full` modifier는 propagation이 아니라 fan-out만 확장한다.
- **Selective consistency on ambiguous findings**: first-pass Arbiter 결과가 애매한 경우에만
  N=3 재판정을 실행한다. 명확한 finding은 first-pass single Arbiter로 종료한다. 정책(trigger/vote-shape/threshold)은
  [references/stability-measurement.md](references/stability-measurement.md)가 SSOT,
  상태 전이는 [references/protocol.md](references/protocol.md), 실행 계약은 [references/arbiter-scaling.md](references/arbiter-scaling.md) 참조.
- **프롬프트 조향 금지**: 후속 라운드 DA/Arbiter 프롬프트에 이전 라운드의 판정 결과를 포함하지 않는다.
  이전 라운드 결과를 "이미 해결된 사안"으로 프레이밍하는 것도 금지한다.
- **무한 루프 방지**: 3회 연속 동일 지적(세부 관점 + 위치 기준)이 반복되면 사용자 결정에 위임한다.
- **탈출 조건**: 선택된 review unit 모두 CLEAR를 반환하면 루프를 종료한다 (`NOT_RUN` 제외).

상세 프로토콜은 [references/protocol.md](references/protocol.md) 참조.

## 사용자 질문 시 맥락 설명 의무

사용자에게 질문 도구로 판단을 요청할 때 (3회 반복 규칙, 5회 라운드 초과, fresh 모드 반복 감지 등 모든 경우), 사용자가 **딴짓을 하다가 돌아온 상황**을 가정하고 다음을 모두 포함한다:

1. **현재 상황 요약**: 어떤 작업을 하고 있었는지 (예: "PR #<번호>의 DA for_pr 피드백 루프 진행 중입니다")
2. **문제 설명**: 무엇이 충돌/반복되고 있는지 구체적으로
3. **비유법 설명**: 기술 용어를 모르는 사람도 이해할 수 있도록 쉬운 비유로 설명
4. **선택지별 장단점**: 각 선택이 가져올 결과를 명확히
5. **질문**: 질문 도구로 결정 요청

**나쁜 예** (맥락 부재):
> "SECURITY DA가 3회 연속 동일 지적을 반복합니다. 수용/기각/보류 중 선택해주세요."

**좋은 예** (맥락 풍부):
> "현재 PR #<번호> 코드 리뷰 N라운드째입니다. `SECURITY` 세부 관점 finding이 3회 연속 '입력 검증 누락'을 지적하고 있습니다.
> 해당 코드는 modules/foo.nix:42의 사용자 입력 처리 부분인데, 쉽게 비유하면 '현관문에 잠금장치를 달아야 한다'는 지적입니다.
> 저는 이전 2라운드에서 '이 입력은 내부 시스템에서만 오므로 잠금이 불필요하다'고 기각했지만, DA가 계속 지적합니다.
> - 수용: 입력 검증 코드 추가 (안전하지만 불필요한 코드 증가)
> - 기각 + CIR: '내부 전용 입력'이라는 근거를 기록하고 넘어감
> - 보류: 별도 이슈로 등록하고 나중에 판단"

## 검증 의무 (강화)

### DA 에이전트 출력 요건
- 모든 지적에는 반드시 구체적 파일:줄 또는 계획 항목 번호를 제시해야 한다.
- 코드 스니펫 또는 계획 원문을 직접 인용하여 문제를 증명해야 한다.
- "~할 수도 있다", "~이 우려된다" 등 증거 없는 추상적 우려는 즉시 기각한다.

### Arbiter 검증 의무
- Arbiter는 각 finding에 대해 5가지 판정 기준(사실 정확성, 변경 연관성, 심각도 타당성, 실행 가능성, Portability / Cross-Environment Drift)으로 독립 검증한다. Portability는 verdict 결정권 없는 guardrail 축이다.
- NOT_AN_ISSUE 판정에는 직접 확인 + 반증 근거가 필수다 (모드별 증거 요건: [arbiter-prompt.md](references/arbiter-prompt.md) 참조).
- NEEDS_MORE_INFO는 추가 정보가 필요한 경우에만 사용한다.
- 상세 판정 기준은 [references/arbiter-prompt.md](references/arbiter-prompt.md) 참조.

### 메인 에이전트 수정 의무
- CONFIRMED_ISSUE 항목을 수정할 때, 해당 위치(파일:줄 또는 계획 항목)를 확인하는 것은 수정 작업의 일부로 수행한다.
- 수정 결과가 finding을 해결하는지 확인한다.

## 주의사항

- 매 라운드 새 reviewer/Arbiter 실행 단위를 사용한다. Codex 세션 경로에서는 새 native subagent thread, codex exec 경로에서는 새 `codex exec` 프로세스다.
- Codex 세션 경로에서는 completed reviewer/Arbiter thread를 다음 round/retry 전에 명시적으로 `close_agent`로 닫는다. 닫지 않으면 open-thread slot이 회수되지 않는다.
- Codex 세션 경로의 reviewer/auditor/Intensity는 standard review profile, Arbiter는 strong review profile을 사용하고, 역할별 write 경계를 넘지 않는다.
- codex exec 경로의 DA `codex exec` 프로세스는 `--full-auto`(workspace-write)로 실행되나, 프롬프트에서 수정 금지를 지시한다. 코드나 계획을 직접 수정하지 않는다.
- "사용자 지시"만으로 DA 지적을 기각하지 않는다. 기술적 근거가 필수이다.
- DA 결과에서 다른 bundle 범위를 침범한 지적은 해당 bundle의 DA 결과로 이관하거나 무시한다.
- 피드백 루프 결과는 PR 코멘트로 게시하여 이력을 보존한다.

## Non-goals

이 스킬이 **구조적으로 보장하지 않는** 경계. 수용 가능한 근사로 운영하되, 구조적 enforcement는 별도 follow-up 범위다.

1. **`spawn_agent` per-child read-only sandbox 부재**: Codex `spawn_agent` API는 자식 에이전트에 read-only sandbox를 구조적으로 강제할 수 없다 (codex-cli 0.124.0 기준 `--ignore-user-config`, `--ephemeral`, `--sandbox` 전역 옵션만 존재, per-child flag 없음). reviewer/Arbiter/Intensity의 "읽기 전용" 경계는 **프롬프트 지시 + 사후 diff 점검**으로만 운영한다. 자식이 구조적으로 write를 못 하게 막지는 않는다.

   **연관 한계 (project config MCP 차단 불가)**: `--ignore-user-config`는 `$CODEX_HOME/config.toml` 로드만 차단하고, **cwd 기반 project config (`.codex/config.toml`의 `[mcp_servers.*]`)는 차단하지 않는다**. 이 리포는 `.codex/config.toml`에 Slack/Linear MCP를 정의하므로, Delegation fallback subprocess가 repo root에서 실행되면 project-scoped MCP connector surface가 reviewer/Arbiter에게 남을 수 있다. 완전 차단이 필요하면 `codex exec -C <non-repo-scratch-dir>`로 cwd를 project config 없는 디렉토리로 이동시키는 별도 Non-goal 범위 follow-up이 필요하다.
2. **push / PR / comment 작성은 네트워크·auth 정책 의존**: `for_pr` 마지막 단계 `push`, `both` 마지막 단계 `push + PR 생성`, PR 코멘트 게시 형식은 네트워크 가능 환경 + GitHub auth 전제. `sandbox_mode=danger-full-access` 또는 GitHub 커넥터 경로에서만 자동 실행한다. 다른 샌드박스 모드에서는 해당 단계를 명시적 사용자 승인 후 수행하거나, 메인 에이전트가 사용자에게 위임한다.
3. **zsh 고정 가정 (headless 포함)**: codex exec 경로의 `_DA_SID` 해시 계산, cleanup glob `*(N)` qualifier, heredoc 문법 등은 **zsh 전제**다. bash/sh 환경에서는 `*(N)`이 문법 오류가 난다. **headless 세션도 zsh 환경에서의 실행**을 지원 범위로 둔다 — bash/sh headless는 현재 지원 범위 밖이다 (POSIX-safe helper 도입 전까지). POSIX-safe 변형은 별도 follow-up (예: guardrail 스킬에서 shell 전제 lint).
4. **`/tmp` 쓰기 권한은 sandbox 정책 의존**: `danger-full-access` · `workspace-write` 모드에서는 `mktemp -d /tmp/...`가 정상 동작한다. 더 제한적인 sandbox에서는 실패할 수 있다. 필요 시 `mktemp -d "${TMPDIR:-/tmp}/..."`로 대체하거나 repo 내부 임시 디렉토리로 우회한다 (follow-up).

## 참조 자료

- **[references/intensity-rules.md](references/intensity-rules.md)** -- Review Intensity 판단 알고리즘 규칙 (단일 소스)
- **[references/da-domains.md](references/da-domains.md)** -- DA reviewer bundle/세부 도메인 정의, 프롬프트 템플릿, 출력 형식
- **[references/protocol.md](references/protocol.md)** -- 상태 흐름 매핑, Arbiter 판정 프로토콜, PoC 의무화 규칙, 무한 루프 방지, 합리화 방지, PR 코멘트 형식
- **[references/arbiter-prompt.md](references/arbiter-prompt.md)** -- Arbiter 프롬프트 템플릿, 5가지 판정 기준(4 core + Portability guardrail), few-shot 교정 예시, blind review 범위, 편향 방지, VERDICT_JSON 블록 스키마
- **[references/arbiter-scaling.md](references/arbiter-scaling.md)** -- 동적 스케일링, 3-way 런타임 분기, 실패 처리
- **[`../using-codex-exec/SKILL.md`](../using-codex-exec/SKILL.md)** -- codex exec 실행 패턴 (Claude Code 세션 기본 경로, headless 세션). 플래그/제한사항 확인용.
