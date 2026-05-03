# 런타임 도구 매핑

`run-da`는 Claude Code 세션과 Codex 세션 양쪽에서 호출된다. 본문은 도구-중립 용어를 쓰고, 런타임별 실제 도구는 이 파일에서 binding한다. 상세 실행 계약(실패 처리, N=3, 질문 도구 미지원 대응, Delegation fallback)의 단일 진실 원천은 [`arbiter-scaling.md`](arbiter-scaling.md)다.

**"나는 어떤 세션에서 실행되고 있는가?"** 로 경로를 선택한다. 아래 표는 본문에서 쓰는 중립 용어를 세션별 **실제 도구명**으로 binding하는 **glossary**다. 표 자체는 용어 정책의 예외로, literal 도구명을 그대로 명시한다.

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

## codex exec 경로 위생 규칙

- **세션 네임스페이스**: 동시 다중 세션 간 /tmp 디렉토리 충돌을 방지한다.
  ```zsh
  # 세션 식별 해시 (8자: /tmp 경로 가독성과 충돌 확률의 균형)
  _DA_SID="${CODEX_COMPANION_SESSION_ID:+${CODEX_COMPANION_SESSION_ID:0:8}}"
  # CODEX_COMPANION_SESSION_ID 미노출 환경(headless/CI)에서 디렉토리별 충돌 방지용 결정적 해시
  if [ -z "$_DA_SID" ]; then
    if command -v sha1sum >/dev/null 2>&1; then
      _DA_SID="$(printf '%s' "$PWD" | sha1sum | head -c 8)"
    else
      _DA_SID="$(printf '%s' "$PWD" | shasum | head -c 8)"
    fi
  fi
  ```
  이후 모든 `mktemp -d`와 cleanup glob에서 `$_DA_SID`를 prefix에 포함한다.
- **모드 시작 시 이전 임시 디렉토리 정리**: for_plan 시작 시 `rm -rf /tmp/da-${_DA_SID}-pr-*(N) /tmp/da-${_DA_SID}-arbiter-*(N) /tmp/da-pr-*(N) /tmp/da-arbiter-*(N)`, for_pr 시작 시 `rm -rf /tmp/da-${_DA_SID}-plan-*(N) /tmp/da-${_DA_SID}-intensity-*(N) /tmp/da-plan-*(N) /tmp/da-intensity-*(N)`. 같은 모드의 이전 라운드는 라운드 교체 시 정리.
  zsh `(N)` qualifier로 매칭 파일 없을 때 오류를 방지한다. legacy glob(NS 없음)은 전환기 고아 디렉토리 정리용이다.
- **결과 파일 참조**: `$INTENSITY_DIR`, `$DA_DIR`, `$ARBITER_DIR` 변수로 정확히 참조한다. **`/tmp/da-*` 와일드카드 glob 금지** — 이전 실행의 결과가 섞인다.
- **셸 호출 간 변수 유지** (모든 런타임 공통): 위 공통 주의 참조. 런타임 종류와 무관하게 셸 호출마다 별도 shell이 생성되므로 `mktemp -d` 결과를 stdout으로 출력해 메인 에이전트가 다음 호출에서 리터럴로 재사용하거나 단일 shell에 체이닝한다. 상세 패턴은 [`arbiter-scaling.md`](arbiter-scaling.md)의 "셸 호출 변수 유실 방지" 참조.
- **stdin pipe로 프롬프트 전달 (Layer 1 supervised wrapper)**: 모든 programmatic codex exec 호출은 `cat "$DIR/prompt.md" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral -c model="gpt-5.5" -c model_reasoning_effort="..." -o "$DIR/result.md" -` 형태의 Layer 1 supervised wrapper 호출을 사용한다 (raw `codex exec --full-auto`는 user-interactive 호출 전용이며 SKILL 내 programmatic 경로에서는 사용하지 않는다). `--ignore-rules`는 user/project execpolicy `.rules` 파일을 차단해 read-only sandbox로 막을 수 없는 network/system mutation 명령(예: `git push`, `aws ec2 describe`)이 reviewer/auditor에서 실행되지 않게 한다. pipe EOF가 stdin을 자동으로 닫아 background 전환 시 stdin hang을 구조적으로 방지한다. `< /dev/null`은 pipe가 대체하므로 불필요. 인라인 인자 `"$(cat file)"`는 사용하지 않는다. **`CODEX_PROGRAMMATIC=1` env assignment는 pipeline 우측 codex 프로세스에 적용되어야 한다 (issue #585).** wrapper 상세는 [`../../using-codex-exec/references/known-issues.md`](../../using-codex-exec/references/known-issues.md) §15 참조.
- **Intensity/Arbiter는 foreground 실행** (단일 exec): 결과를 즉시 확인한다. **reviewer만 병렬 실행** (런타임별 병렬 실행 매커니즘은 위 표 참조).

### literal 재사용 시 random suffix 환각 금지 (issue #632)

Generic codex exec split-call rule은 [`using-codex-exec/references/known-issues.md`](../../using-codex-exec/references/known-issues.md#literal-재사용-시-random-suffix-환각-금지-issue-632)가 SSOT다. run-da 고유 적용은 `_DA_SID` 세션 네임스페이스와 `$INTENSITY_DIR`/`$DA_DIR`/`$ARBITER_DIR` 결과 파일 경로에 해당 generic rule을 적용하는 것이다.

## Claude Code 세션 fallback 세부 정보

Claude Code 세션에서 codex exec 사전점검이 실패했을 때 legacy fallback으로 대체하는 경로의 Claude-Code-고유 lifecycle이다. review profile 매핑은 위 표 참조.

| 항목 | Claude Code fallback |
|------|----------------------|
| fan-out | background fallback 실행 |
| wait | 자동 완료 알림 (background task notification) |
| close | 불필요 (완료 시 자동 해제) |
| thread-cap | Claude Code의 병렬 제한을 따름 |
| violation 처리 | 프롬프트에서 읽기 전용을 지시하지만, 구조적 보증이 아닌 프롬프트 수준 제약이다. 하위 fallback unit이 side effect를 만들 가능성이 있으므로, [`hardening-contract.md`](hardening-contract.md)의 역할별 경계(reviewer: 읽기+검색+scratch PoC만, Arbiter/Intensity: 읽기 전용)를 프롬프트에 명시한다 |
