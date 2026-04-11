# Arbiter 동적 스케일링 규칙

Arbiter 에이전트의 실행 수, 실행 계약, 실패 처리를 정의한다.

## 기본값: single strong arbiter

P0 기본값은 **항상 단일 강한 Arbiter 1개**다.
`run-da`의 reviewer fan-out을 4 bundle로 줄이더라도, Arbiter는 기본적으로 늘리지 않는다.
비용을 늘려 여러 Arbiter를 붙이기보다, 한 명의 강한 Arbiter가 selective escalation set을 판정하는 구조를 유지한다.

## v1: 단순 스케일링

| Findings 개수 | Arbiter 수 |
|---|---|
| 0건 | 0 (SKIP) |
| 1건 이상 | 1 |

v1은 selective propagation으로 추린 escalated findings를 단일 Arbiter에 전달한다.
교차 검증, 교차 Arbiter 비교는 기본값이 아니다.

## 예외적 확장 조건

다음 조건이 명확히 충족될 때만 Arbiter 2개+ 확장을 검토한다.

1. 같은 위치에 대해 reviewer bundle 간 결론이 실질적으로 충돌하고, 단일 Arbiter가 반복해서 `NEEDS_MORE_INFO`만 반환할 때
2. `CRITICAL`급 `Correctness` finding처럼 오판 비용이 매우 큰데, 확인/기각 근거가 서로 강하게 충돌할 때
3. 반복 세션에서 단일 Arbiter의 drift 또는 false-negative 패턴이 누적되어 보정이 필요하다는 실증이 있을 때

위 조건이 없으면 Arbiter를 늘리지 않는다. reviewer 수가 많다는 이유만으로 자동 확장하지 않는다.

## 실행 계약 (런타임 분기)

### Codex 세션 경로

현재 세션이 native subagent 오케스트레이션(`spawn_agent`, `wait_agent`, `close_agent`)을 사용할 수 있으면
Arbiter/Review Intensity도 이를 기본 경로로 사용한다.

- 매 실행마다 fresh Arbiter subagent는 [run-da canonical contract](../SKILL.md)의 strong review profile로, Intensity subagent는 standard review profile로 사용한다.
- 프롬프트는 `spawn_agent` 입력에 직접 포함한다. tmp prompt/result 파일을 기본 경로로 요구하지 않는다.
- Arbiter/Intensity는 review-only/no-write role이다. 파일 수정, scratch PoC, branch mutation, GitHub write, `wt`/`nrs`/rebuild 계열 실행을 하지 않는다.
- 결과는 `wait_agent`로 수신하고, timeout만으로 실패 처리하거나 중간 kill/self-auditing으로 대체하지 않는다. 결과를 파싱한 뒤 completed thread를 `close_agent`로 닫는다.
- completed thread는 `close_agent` 전까지 open-thread slot을 계속 점유한다.
  current session cap을 넘기는 fan-out/retry 전에 먼저 닫는다.

### codex exec 경로 (Claude Code 세션 · headless 세션)

Claude Code에서 Codex CLI를 subprocess로 호출할 때, 비대화형 automation일 때,
또는 사용자가 `codex exec`를 명시적으로 요구할 때는 기존 `codex exec` 계약을 따른다.

- `codex exec --full-auto --ephemeral`
- **foreground** Bash tool 호출 (`run_in_background` 사용 안 함 — 단일 exec이므로 결과를 즉시 확인)
- `-o "$ARBITER_DIR/arbiter-result.md"` 결과 파일
- `"$(cat "$ARBITER_DIR/arbiter-prompt.md")"` 인라인 인자
- `2>"$ARBITER_DIR/arbiter-stderr.log"` stderr 분리
- `-m` 플래그 생략 (config.toml 기본 모델)
- Arbiter는 config.toml 기본 `model_reasoning_effort`(xhigh = strong review profile)를 사용한다. `-c` 오버라이드 불필요.
- 프롬프트에서 "리뷰만 수행하고 파일을 수정하지 마라" 명시
- `--ephemeral`로 세션 히스토리 오염 방지

`& + wait` shell-level 병렬을 사용하지 않는다 (Bash tool sandbox 제약).
stdin pipe 대신 `"$(cat file)"` 인라인 인자를 사용한다.

## 실행 절차

### Codex 세션 경로

1. Arbiter용 fresh subagent는 strong review profile로, Intensity용은 standard review profile로 띄운다.
2. 프롬프트에는 관련 reference 문서를 직접 읽고, review-only/no-write contract를 따르며, 파일을 수정하지 말라고 명시한다.
3. `wait_agent`로 결과를 받는다. timeout만으로 실패 처리하거나 중간 kill/self-auditing으로 대체하지 않는다.
4. 결과 파싱 후 completed thread를 `close_agent`로 닫는다.

### codex exec 경로 (Claude Code 세션 · headless 세션)

**이 코드블록 전체를 단일 Bash tool 호출로 실행한다** (Bash tool 간 환경변수 비공유 — 호출을 나누면 `$ARBITER_DIR`이 유실됨).

```bash
# 1. Arbiter 임시 디렉토리 생성
ARBITER_DIR=$(mktemp -d /tmp/da-${_DA_SID}-arbiter-XXXXXX)

# 2. Arbiter 프롬프트 파일 조립 (arbiter-prompt.md의 조립 규칙 참조)
cat > "$ARBITER_DIR/arbiter-prompt.md" <<'PROMPT'
{조립된 Arbiter 프롬프트 — 비신뢰 텍스트(계획 원문, DA 결과) 포함 시 반드시 quoted heredoc 사용}
PROMPT

# 3. codex exec 실행 (foreground)
codex exec --full-auto --ephemeral \
  -o "$ARBITER_DIR/arbiter-result.md" \
  "$(cat "$ARBITER_DIR/arbiter-prompt.md")" \
  < /dev/null \
  2>"$ARBITER_DIR/arbiter-stderr.log"

# 4. 결과 수집 — exit code + 빈 파일 모두 확인 (ARBITER_DIR이 다음 호출에서 유실되므로 같은 호출에서 처리)
_EC=$?
if [ $_EC -ne 0 ] || [ ! -s "$ARBITER_DIR/arbiter-result.md" ]; then
  _RS=$([ ! -f "$ARBITER_DIR/arbiter-result.md" ] && echo 'missing' || ([ ! -s "$ARBITER_DIR/arbiter-result.md" ] && echo 'empty' || echo 'present-but-exit-failed'))
  echo "ARBITER_FAILED: exit=$_EC result=$_RS dir=$ARBITER_DIR"
  echo "--- stderr ---"
  cat "$ARBITER_DIR/arbiter-stderr.log" 2>/dev/null
  exit 1
else
  cat "$ARBITER_DIR/arbiter-result.md"
fi
```

### Bash tool 변수 유실 방지

`codex exec` 결과를 파일로 받아 후속 처리하는 경우, **위 코드블록 전체(#1~#4)**를 단일 Bash tool 호출로 체이닝한다. 위 코드블록이 올바른 패턴이다.

아래는 호출을 분리하면 발생하는 잘못된 패턴이다:

```bash
# 잘못된 패턴 — 변수가 다음 호출에서 유실됨
# [호출 1] ARBITER_DIR=$(mktemp -d /tmp/da-${_DA_SID}-arbiter-XXXXXX)
# [호출 2] codex exec -o "$ARBITER_DIR/result.md" ...
#   ← $ARBITER_DIR이 unset → "/result.md" (루트 경로)로 확장됨
```

## 실패 처리

**단일 호출 패턴에서의 실패 감지**: 위 코드블록은 `exit 1`로 종료하여 Bash tool이 비정상 종료를 보고한다. stdout에 `ARBITER_FAILED:` 접두어가 출력되며, `dir=` 필드에 임시 디렉토리 경로, 이어서 stderr 로그 내용이 포함된다. 메인 에이전트는 Bash tool의 exit code 또는 stdout의 `ARBITER_FAILED:` 접두어로 실패를 감지한다.

codex exec 실패 시 (exit code != 0, 빈 결과 파일):

1. 해당 Arbiter 실행의 모든 findings를 NEEDS_MORE_INFO로 일괄 승격한다.
2. 사용자에게 AskUserQuestion으로 보고한다 (맥락 설명 의무 적용).
3. 재시도하지 않는다 (사용자가 판단).

## Codex 세션 violation 처리

Codex 세션 경로에서는 Arbiter/Intensity가 새 verdict를 반환하는 것이 아니라, 메인 에이전트가 contract breach 또는 malformed output을 감지했을 때 아래 규칙으로 분류한다.

- `recoverable violation`: 출력 형식 위반, prompt contract 미준수처럼 상태를 바꾸지 않은 위반. 결과를 폐기하고 fresh subagent로 1회 재실행한다.
- `stateful violation`: tracked write, branch mutation, commit/push, GitHub write, main-agent-only command 실행, host mutation처럼 상태를 바꾼 위반. 현재 라운드를 즉시 중단하고 offending thread를 닫는다.
- stateful violation은 이번 라운드에서 offending unit이 만든 scratch 산출물과 임시 ref/branch만 정리 대상으로 삼는다. 기존 local tracked/untracked 변경은 자동 정리하지 않는다.
- 비가역적 외부 side effect가 있었거나 cleanup 범위를 특정할 수 없으면 AskUserQuestion 가능 시 사용자에게 보고하고, AskUserQuestion 미지원 런타임에서는 자동 `CLEAR` 처리하지 않고 `BLOCKED`로 남긴다. 명시적 rerun 전에는 재개하지 않는다.

## 런타임 선택 규칙

- **Codex 세션 경로**는 현재 세션이 Codex CLI 호스트(`spawn_agent` API 사용 가능)일 때 기본 경로다.
- **codex exec 경로**는 Claude Code 세션(codex exec 기본 → Agent tool fallback)과 headless 세션(CI, `claude -p`)에서 기본 경로다.
- `CODEX_CI=1`은 Codex 세션에서도 보일 수 있으므로 sole discriminator로 쓰지 않는다.

## AskUserQuestion 미지원 대응

현재 런타임에서 AskUserQuestion(`request_user_input`)을 호출할 수 없으면 다음 규칙을 적용한다
(검증: codex-cli v0.118.0, Default 모드에서 `request_user_input` 호출 시 에러 반환):

- NEEDS_MORE_INFO 항목은 **CONFIRMED_ISSUE로 자동 승격**한다 (텍스트 보고만으로는 상태 전이가 불가능하므로).
- CONFIRMED_ISSUE는 동일하게 자동 수정한다.
- SKIP 판정 시 AskUserQuestion 불가 → **자동 LITE 승격**.
- 3회 반복 규칙 도달 시 AskUserQuestion 불가 → **자동 수용** (지적대로 수정).
- 5회 라운드 초과 시 AskUserQuestion 불가 → **자동 종료** (현재 상태로 CLEAR 간주, DA 루프 종료).

## Review Intensity 판단 에이전트 실행 계약

DA 에이전트/Arbiter와 동일한 런타임 분기 계약을 따르되, 다음이 다르다:

| 항목 | DA/Arbiter | Review Intensity |
|------|-----------|-----------------|
| 입력 | diff 전체 또는 계획 전체 | `git diff --stat` 또는 계획 파일 목록 |
| 출력 | findings/verdicts | SKIP/LITE/FULL + 근거 (첫 줄 판정 + 이후 근거) |
| 참조 | da-domains.md, arbiter-prompt.md | intensity-rules.md |
| 실패 시 | NEEDS_MORE_INFO 승격 | **FULL 강제** |

- Codex 세션 경로에서는 fresh intensity subagent 1개를 standard review profile로 사용하고, 결과 파싱 후 completed thread를 `close_agent`로 닫는다.
- codex exec 경로(Claude Code 세션 · headless 세션)에서는 **foreground** Bash tool 호출로 `--full-auto --ephemeral -c model_reasoning_effort="high"`를 실행한다 (단일 exec, `run_in_background` 사용 안 함).
- 프롬프트에서 "references/intensity-rules.md를 직접 읽어 규칙을 적용하라"고 지시하고, Intensity는 review-only/no-write role임을 함께 명시한다.
- codex exec 경로의 프롬프트 파일은 `umask 077`로 권한 제한한다.
- 메인 LLM은 결과를 읽고 판정에 따라 분기한다. AskUserQuestion(SKIP 시)은 메인 LLM이 호출한다.
- AskUserQuestion 미지원 시 SKIP 처리는 위 "AskUserQuestion 미지원 대응" 섹션의 규칙을 따른다.

## 향후 확장

위 예외 조건이 실제로 반복 검증되면 교차 검증(Arbiter 2개+)이나 Known-Answer Calibration 도입을 검토한다.
그 전까지는 single strong arbiter가 기본 계약이다.
