# 런타임 도구 매핑

`run-da`는 Claude Code 세션과 Codex 세션 양쪽에서 호출된다. 본문은 도구-중립 용어를 쓰고, 런타임별 실제 도구는 이 파일에서 binding한다. 상세 실행 계약(실패 처리, N=3, 질문 도구 미지원 대응, Delegation fallback)의 단일 진실 원천은 [`arbiter-scaling.md`](arbiter-scaling.md)다.

"나는 어떤 세션에서 실행되고 있는가?" 로 경로를 선택한다. 아래 표는 본문에서 쓰는 중립 용어를 세션별 실제 도구명으로 binding하는 glossary다. 표 자체는 용어 정책의 예외로, literal 도구명을 그대로 명시한다.

| 행동 | Codex 세션 | Claude Code 세션 | headless 세션 |
|------|-----------|------------------|---------------|
| 사용자에게 질문 (blocking tool call) | `request_user_input` | `AskUserQuestion` 도구 | 미지원 (자동 전이 적용) |
| fan-out 실행 (기본) | capability profile에 따른 native lifecycle (delegation 허용 시; 아래 "[Codex native lifecycle capability profile](#codex-native-lifecycle-capability-profile)" 절 SSOT — current: `spawn_agent` → `wait_agent`, legacy: `spawn_agent` → `wait_agent` → `close_agent`) | `Bash tool` + `run_in_background: true`로 `codex exec` subprocess 병렬 발사 (codex exec 사전점검 성공 시 기본) | `codex exec` subprocess를 serial foreground로 순차 실행 (완료 알림/`&+wait` 없음) |
| fan-out 실행 (fallback) | codex exec subprocess (아래 "Delegation fallback" + `arbiter-scaling.md` 실행 계약) | `Agent` tool + `run_in_background: true` (codex exec 사전점검 실패 원인 고지 후 사용자가 Claude 경로 진행을 확인한 경우만) | — |
| 결과 수집 | `wait_agent` 반환값, 또는 `exec_command`로 `cat`/`sed` 셸 읽기 | `Read` 도구 | `cat`/`sed` via shell |
| 파일 읽기 | `exec_command`로 `cat`/`sed`/`rg` | `Read` 도구 | `cat`/`sed`/`rg` |

Skill-internal fan-out authorization: Direct Codex 세션에서 fan-out 스킬 호출이 내부 native subagent fan-out에 대한 explicit delegation으로 취급되는 권한 계약은 [`hardening-contract.md`](hardening-contract.md#skill-internal-fan-out-authorization)가 정본이다. 이 파일은 해당 권한을 실제 런타임 도구 binding으로만 연결한다.

## Codex native lifecycle capability profile

Direct Codex 세션의 native fan-out lifecycle과 동시 발사 상한은 현재 세션의 model-visible collaboration tool 집합과 developer 메시지가 광고한 slot으로 결정한다. 제품명(CLI/Desktop), CLI 버전, `CODEX_CI` 값으로 lifecycle을 추측하지 않는다. 메인 에이전트는 첫 fan-out 전에 자기 세션 표면에서 아래 profile을 판별해 선언한다.

| profile | 판별 조건 (model-visible tool 집합) | slot 회수 | 동시 발사(batch) 상한 |
|---------|-------------------------------------|-----------|----------------------|
| `current` | `spawn_agent`·`wait_agent`가 있고 explicit `close_agent`가 없음 | explicit close 도구가 없다 — 결과 수신 후 slot 회수를 자체 확인할 수 없으므로, 광고 slot을 초과하는 발사를 계획하지 않는다 | developer 광고 total slot N(root 포함)에서 child batch = max(1, N-1) |
| `legacy` | `spawn_agent`·`wait_agent`·`close_agent` 모두 있음 | completed thread를 다음 round/retry 전에 `close_agent`로 닫아 slot을 회수한다 (닫기 전까지 slot 점유) | 광고 slot 사용 시 current와 동일하게 child batch = max(1, N-1) (N은 root 포함 total). 미광고 시 `agents.max_threads` 설정값을 child thread 상한으로 쓰되, 그 값의 root 포함 여부를 세션 표면에서 확정할 수 없으면 unknown으로 강등한다 |
| `unknown` | tool 집합 또는 slot 상한을 세션 표면에서 확인할 수 없음 | — | fail-safe: serial 실행(동시 1). 자동 verifier 결과로 unknown을 덮지 않는다 |

- slot source: 세션 developer 메시지의 collaboration 안내 문장(예: "There are N available concurrency slots, meaning that up to N agents can be active at once, including you")이 1차 근거다. 이 광고가 없으면 slot은 unknown이다.
- 실행 중 unit의 강제 중단: `close_agent`는 slot 회수 도구이지 중단 도구가 아니다. 중단이 필요하면 current profile에서는 `interrupt_agent`를 사용한다 (CLI-default 실측에서 가용 확인). legacy profile에서는 세션이 광고하는 중단 도구를 따르고, 미광고면 conservative wait을 유지한다.
- active-session gate: 각 세션은 자기 표면의 tool 목록·slot 광고로 판별한다. CLI-default probe 결과를 다른 세션(예: Desktop fresh task)의 증거로 재사용하지 않는다. CLI와 Desktop의 표면이 다르면 하나로 강제하지 말고 별도 profile로 보고한다.
- CLI-default 실측 (codex-cli 0.146.0, 2026-07-31, `codex debug prompt-input` — surface_scope=cli-default): model-visible tools = `spawn_agent`, `followup_task`, `send_message`, `wait_agent`, `interrupt_agent`, `list_agents` (close_agent 없음), 광고 slot = 4 (root 포함) → `current` profile, child batch 3. 같은 실측에서 full-history fork(`fork_turns` 생략/`"all"`)는 부모 model/effort를 상속하며 override를 받지 않는다고 광고됐다.
- 재검증: `./scripts/ai/verify-ai-compat.sh`의 "Codex CLI-default native capability probe" 검사가 sanitized tool-name set과 slot source만 파싱해 profile을 판정한다 (raw prompt 저장/출력 금지, `surface_scope=cli-default` 명시, unknown이면 fail). Codex pin 갱신 시 CLI-default 결과와 active-session 결과를 구분해 기록한다.

plain-text 재개 ≠ 질문 도구 — 일반 채팅 "질문 후 다음 턴 재개"는 blocking tool call이 아니므로 질문 도구로 간주하지 않는다. 질문 도구가 필수인 지점(SKIP 승인, 3회 반복 판정, 라운드 한계효용 저하, 5회 라운드 초과, 추세 기반 조기 중단, fresh 모드 반복 감지)에서 Codex 세션은 `request_user_input`을 호출하고, headless 세션은 stdin 입력 불가로 자동 상태 전이 경로(arbiter-scaling.md)로 처리한다.

## fan-out 진행 보고 규약

fan-out 진행 가시성의 정본은 이 절이다. 메인 에이전트는 완료 이벤트를 기다리는 동안 사용자가 hang으로 오해하지 않도록, 런타임 이벤트에 반응하는 짧은 상태 보고를 남긴다.

- 발사 직후: 어떤 역할을 몇 개 발사했는지와 완료 알림으로 재개된다는 사실을 한 줄로 보고한다. 예: reviewer 4개 백그라운드 발사, 완료 알림 대기.
- 각 완료 이벤트 수신 시: 누적 완료 수와 전체 수를 한 줄로 보고한다. 예: reviewer 2/4 완료. 모든 결과가 모이기 전에도 이벤트를 받을 때마다 카운트를 갱신한다.
- 이 보고는 sleep/poll 루프를 도입하는 근거가 아니다. 결과 수집은 위 런타임 매핑 표의 완료 이벤트, foreground 종료, 결과 파일 읽기 경로만 따른다.
- headless serial foreground 경로는 백그라운드 완료 알림이 없으므로 각 subprocess 종료 직후 같은 카운트 형식으로 보고한다.

review profile 매핑 (fan-out 대상 역할별, `agent=` 미지정 기본값):

| profile | 대상 | 모델 선택 | codex exec effort |
|---------|------|-----------|-------------------|
| `strong` | Arbiter | 세션/런타임 기본 모델 상속 | `high` |
| `standard` | reviewer / auditor | 세션/런타임 기본 모델 상속 | `medium` |

호출 인자 `agent=`가 지정되면 위 기본 profile보다 우선한다. 적용 범위는 해당 호출의 reviewer/auditor와 Arbiter 전체다.

| agent 값 | 실행 경로 | effort / 모델 처리 |
|----------|-----------|--------------------|
| `agent=codex-xhigh` | codex exec | `xhigh` reasoning effort. 모델명은 고정하지 않고 런타임 기본값을 사용한다 |
| `agent=codex-high` | codex exec | `high` reasoning effort. 모델명은 고정하지 않고 런타임 기본값을 사용한다 |
| `agent=codex-medium` | codex exec | `medium` reasoning effort. 모델명은 고정하지 않고 런타임 기본값을 사용한다 |
| `agent=claude` | Claude Code `Agent` tool | Claude Code 세션 모델을 상속한다. 특정 모델명을 지정하지 않는다 |

사용자 지정 실행 파라미터 (model/effort/tier): 사용자가 `model=`/`effort=`/`tier=` 토큰 또는 같은 의미의 자연어로 명시한 값은 codex exec 경로의 모든 실행 단위(reviewer/auditor/Arbiter, N=3 포함)에 `-c` config override로 주입되며, `agent=`의 effort보다 우선한다. 주입 경로는 축별로 다르다 — model/tier는 `_DA_MODEL_TIER_OVERRIDES` 배열로, effort는 고정 `-c model_reasoning_effort=` 인자로 별도 주입된다. 개념 정의는 `run-da/SKILL.md`, 실행 계약(env·shell-safe 검증·조립)은 [`arbiter-scaling.md`](arbiter-scaling.md)의 "사용자 지정 실행 파라미터" 섹션이 SSOT다. `agent=claude` 경로와 Codex 세션 native subagent 경로에는 주입 수단이 없다 (경로 전환 확인 규칙은 `run-da/SKILL.md` 경로 제약).

Review Intensity는 fan-out 대상이 아니다 — 메인 LLM 인라인 체크리스트(`intensity-rules.md`의 8 룰 기계적 적용)이므로 별도 review profile이 적용되지 않는다. 절차는 [`intensity-procedure.md`](intensity-procedure.md) SSOT.

`CODEX_CI=1`만으로 세션 유형을 구분하지 않는다 (Codex 세션에서도 같은 값이 보일 수 있음). 현재 세션 호스트를 기준으로 경로를 고른다.

본문에서 codex exec 경로는 Claude Code 세션과 headless 세션의 공통 실행 substrate를 가리킨다.

> 셸 호출 간 환경변수 유실 — 모든 런타임 공통 주의 — Claude Code 셸 실행 환경, Codex의 `exec_command`, headless 세션의 독립 셸 호출 모두 호출마다 별도 shell이 생성되어 환경변수가 다음 호출로 전달되지 않는다 (`$DA_DIR` 유실. 실측: Codex `exec_command` 첫 호출에서 `FOO=kept` 설정 후 둘째 호출에서 unset 확인). `mktemp -d` 결과를 다음 호출에서 쓰려면 (1) 단일 shell 호출 안에 체이닝하거나 (2) 경로를 stdout에 출력해 메인 에이전트가 다음 호출에서 리터럴로 재사용한다. 셸 세션 공유를 가정하면 결과 파일 경로 오류와 리뷰 루프 실패로 이어진다.

## codex exec 경로 위생 규칙

- 세션 네임스페이스: 동시 다중 세션 간 /tmp 디렉토리 충돌을 방지한다.
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
- 모드 시작 시 이전 임시 디렉토리 정리: for_plan 시작 시 `rm -rf /tmp/da-${_DA_SID}-pr-*(N) /tmp/da-${_DA_SID}-arbiter-*(N) /tmp/da-${_DA_SID}-intensity-*(N) /tmp/da-pr-*(N) /tmp/da-arbiter-*(N) /tmp/da-intensity-*(N)`, for_pr 시작 시 `rm -rf /tmp/da-${_DA_SID}-plan-*(N) /tmp/da-${_DA_SID}-intensity-*(N) /tmp/da-plan-*(N) /tmp/da-intensity-*(N)`. 같은 모드의 이전 라운드는 라운드 교체 시 정리. Intensity legacy glob (`-intensity-*`)은 마이그레이션 cleanup 용도로 두 모드 모두에 포함 — 인라인 체크리스트 전환 후에는 새로 생성되지 않지만 이전 버전이 만든 디렉토리를 자동 정리하기 위해 모드와 무관하게 cleanup 명령에 그대로 남긴다.
  zsh `(N)` qualifier로 매칭 파일 없을 때 오류를 방지한다. legacy glob(NS 없음)은 전환기 고아 디렉토리 정리용이다.
- 결과 파일 참조: `$DA_DIR`, `$ARBITER_DIR` 변수로 정확히 참조한다. `/tmp/da-*` 와일드카드 glob 금지 — 이전 실행의 결과가 섞인다. (Intensity는 메인 LLM 인라인 체크리스트라 별도 임시 디렉토리를 만들지 않는다.)
- 셸 호출 간 변수 유지 (모든 런타임 공통): 위 공통 주의 참조. 런타임 종류와 무관하게 셸 호출마다 별도 shell이 생성되므로 `mktemp -d` 결과를 stdout으로 출력해 메인 에이전트가 다음 호출에서 리터럴로 재사용하거나 단일 shell에 체이닝한다. 상세 패턴은 [`arbiter-scaling.md`](arbiter-scaling.md)의 "셸 호출 변수 유실 방지" 참조.
- stdin pipe로 프롬프트 전달 (Layer 1 supervised wrapper): 모든 programmatic codex exec 호출은 `cat "$DIR/prompt.md" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral -c model_reasoning_effort="$RUN_DA_CODEX_EFFORT" "${_DA_MODEL_TIER_OVERRIDES[@]}" -o "$DIR/result.md" -` 형태의 Layer 1 supervised wrapper 호출을 사용한다 (raw `codex exec` 직접 호출은 user-interactive 전용이며 SKILL 내 programmatic 경로에서는 사용하지 않는다). 모델명·service_tier는 스킬이 고정하지 않는다 — `$RUN_DA_CODEX_EFFORT`는 기본 role profile, `agent=` 인자, 또는 사용자 명시 effort에서 결정하고, `_DA_MODEL_TIER_OVERRIDES`는 사용자 명시 model/tier가 있을 때만 채워진다 ([`arbiter-scaling.md`](arbiter-scaling.md) "사용자 지정 실행 파라미터" 섹션의 조립 루프를 같은 셸 호출 안에서 먼저 실행). `--ignore-rules`는 user/project execpolicy `.rules` 파일을 차단해 read-only sandbox로 막을 수 없는 network/system mutation 명령(예: `git push`, `aws ec2 describe`)이 reviewer/auditor에서 실행되지 않게 한다. pipe EOF가 stdin을 자동으로 닫아 background 전환 시 stdin hang을 구조적으로 방지한다. `< /dev/null`은 pipe가 대체하므로 불필요. 인라인 인자 `"$(cat file)"`는 사용하지 않는다. `CODEX_PROGRAMMATIC=1` env assignment는 pipeline 우측 codex 프로세스에 적용되어야 한다 (issue #585). wrapper 상세는 [`../../using-codex-exec/references/known-issues.md`](../../using-codex-exec/references/known-issues.md) §15 참조.
- Arbiter는 foreground 실행 (단일 exec): 결과를 즉시 확인한다. reviewer만 병렬 실행 (런타임별 병렬 실행 매커니즘은 위 표 참조).

### literal 재사용 시 random suffix 환각 금지 (issue #632)

Generic codex exec split-call rule은 [`using-codex-exec/references/known-issues.md`](../../using-codex-exec/references/known-issues.md#literal-재사용-시-random-suffix-환각-금지-issue-632)가 SSOT다. run-da 고유 적용은 `_DA_SID` 세션 네임스페이스와 `$DA_DIR`/`$ARBITER_DIR` 결과 파일 경로에 해당 generic rule을 적용하는 것이다.

## Claude Code 세션 fallback 세부 정보

Claude Code 세션에서 codex exec 사전점검이 실패했을 때는 legacy fallback으로 조용히 대체하지 않는다. 메인 에이전트는 실패 원인을 사용자에게 고지하고, 대안으로 Claude Code 서브에이전트 경로 진행 또는 중단을 확인받는다. 아래는 사용자가 Claude 경로 진행을 확인했거나 `agent=claude`를 명시한 경우의 Claude-Code-고유 lifecycle이다. 모델은 Claude Code 세션 모델을 상속한다.

| 항목 | Claude Code fallback |
|------|----------------------|
| fan-out | background fallback 실행 |
| wait | 자동 완료 알림 (background task notification) |
| close | 불필요 (완료 시 자동 해제) |
| thread-cap | Claude Code의 병렬 제한을 따름 |
| violation 처리 | 프롬프트에서 읽기 전용을 지시하지만, 구조적 보증이 아닌 프롬프트 수준 제약이다. 하위 fallback unit이 side effect를 만들 가능성이 있으므로, [`hardening-contract.md`](hardening-contract.md)의 역할별 경계(reviewer: 읽기+검색+scratch PoC만, Arbiter: 읽기 전용)를 프롬프트에 명시한다 |
