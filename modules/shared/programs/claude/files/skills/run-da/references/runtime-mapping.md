# 런타임 도구 매핑

`run-da`는 Claude Code 세션과 Codex 세션 양쪽에서 호출된다. 본문은 도구-중립 용어를 쓰고, 런타임별 실제 도구는 이 파일에서 binding한다. 상세 실행 계약(실패 처리, 질문 도구 미지원 대응, Delegation fallback)의 단일 진실 원천은 [`arbiter-scaling.md`](arbiter-scaling.md)다.

"나는 어떤 세션에서 실행되고 있는가?" 로 경로를 선택한다. 아래 표는 본문에서 쓰는 중립 용어를 세션별 실제 도구명으로 binding하는 glossary다. 표 자체는 용어 정책의 예외로, literal 도구명을 그대로 명시한다.

금지 경로 (#1259 판단 기록은 그 이슈 코멘트 참조): DA 실행 단위를 다중 에이전트 오케스트레이션 표면(Workflow 스크립트의 agent 호출 등)이나 peer 세션으로 위임하지 않는다 — 이 표면들은 spawn 단위 도구 allowlist·read-only sandbox를 광고하지 않아 tracked write·commit·외부 write를 구조적으로 막을 수 없고, 실측에서 필수 필드가 리터럴 placeholder인 산출이 성공 집계된 사고가 있다. 정식 실행 경로는 아래 표의 3개(codex exec / Codex 세션 native subagent / Claude 서브에이전트)뿐이다. 재평가 조건: 하네스가 spawn 단위 도구 allowlist 또는 read-only sandbox를 광고하는 시점에 편입을 재판단한다.

| 행동 | Codex 세션 | Claude Code 세션 | headless 세션 |
|------|-----------|------------------|---------------|
| 사용자에게 질문 (blocking tool call) | `request_user_input` | `AskUserQuestion` 도구 | 미지원 (자동 전이 적용) |
| fan-out 실행 (기본) | capability profile에 따른 native lifecycle (delegation 허용 시; 아래 "[Codex native lifecycle capability profile](#codex-native-lifecycle-capability-profile)" 절 SSOT — `spawn_agent` → `wait_agent`) | `Bash tool` + `run_in_background: true`로 `codex exec` subprocess 병렬 발사 (codex exec 사전점검 성공 시 기본) | `codex exec` subprocess를 serial foreground로 순차 실행 (완료 알림/`&+wait` 없음; `claude -p`는 Bash tool 상한 적용 — [`arbiter-scaling.md`](arbiter-scaling.md) codex exec 경로 실행 계약의 `timeout` 최대치 명시 요구를 따른다) |
| fan-out 실행 (fallback) | codex exec subprocess (아래 "Delegation fallback" + `arbiter-scaling.md` 실행 계약) | `Agent` tool + `run_in_background: true` (codex exec 사전점검 실패 원인 고지 후 사용자가 Claude 경로 진행을 확인한 경우만) | — |
| 결과 수집 (<a id="result-collection"></a>정의 anchor) | subagent가 최종 응답으로 전달한 본문 (`wait_agent`는 완료 신호·상태 요약만 반환하고 결과 본문은 포함하지 않는다), 또는 subagent가 파일로 쓴 결과를 `exec_command`로 `cat`/`sed` 셸 읽기 | `Read` 도구 | `cat`/`sed` via shell |
| 파일 읽기 | `exec_command`로 `cat`/`sed`/`rg` | `Read` 도구 | `cat`/`sed`/`rg` |

Skill-internal fan-out authorization: Direct Codex 세션에서 fan-out 스킬 호출이 내부 native subagent fan-out에 대한 explicit delegation으로 취급되는 권한 계약은 [`hardening-contract.md`](hardening-contract.md#skill-internal-fan-out-authorization)가 정본이다. 이 파일은 해당 권한을 실제 런타임 도구 binding으로만 연결한다.

## Codex native lifecycle capability profile

Direct Codex 세션의 native fan-out lifecycle과 동시 발사 상한은 현재 세션의 model-visible collaboration tool 집합과 developer 메시지가 광고한 slot으로 결정한다. 제품명(CLI/Desktop), CLI 버전, `CODEX_CI` 값으로 lifecycle을 추측하지 않는다. 메인 에이전트는 첫 fan-out 전에 자기 세션 표면에서 아래 profile을 판별해 선언한다.

| profile | 판별 조건 (model-visible tool 집합) | slot 규칙 | 동시 발사(batch) 상한 |
|---------|-------------------------------------|-----------|----------------------|
| `current` | `spawn_agent`·`wait_agent`가 있고 explicit close 도구(`close_agent`)가 광고되지 않음 | explicit close 도구를 전제하지 않는다 — 결과 수신 후 slot 회수를 자체 확인할 수 없으므로, 광고 slot을 초과하는 발사를 계획하지 않는다 | developer 광고 total slot N(root 포함, N ≥ 2 필요)에서 child batch = N − 1. N < 2이면 child slot이 없으므로 native fan-out 불가 — codex exec fallback(serial subprocess)을 쓴다 (native serial 아님 — root 외 native 실행 slot이 없다) |
| `unknown` | tool 집합 또는 slot 상한을 세션 표면에서 확인할 수 없음, 또는 지원 종료된 과거 lifecycle 표면(explicit `close_agent`가 광고되는 표면 — #1257에서 legacy profile 제거) | — | fail-safe 분기: ①`spawn_agent`·`wait_agent`는 확인됐고 explicit close 도구도 없는데 slot만 미확정이면 native serial(동시 1). ②explicit `close_agent`가 광고되는 표면은 slot 확인 여부와 무관하게 native 실행 금지 — 그 표면의 slot 회수는 close 계약에 묶여 있는데 현행 실행 계약에는 close 절차가 없어 thread가 누적 소진되므로, codex exec fallback만 사용한다. ③tool 집합 자체가 미확인·부재면 native 실행 불가 — codex exec fallback만 사용한다. 자동 verifier 결과로 unknown을 덮지 않는다 |

- slot source: 세션 developer 메시지의 collaboration 안내 문장(예: "There are N available concurrency slots, meaning that up to N agents can be active at once, including you")이 1차 근거다. 이 광고가 없으면 slot은 unknown이다.
- 실행 중 unit의 강제 중단 (cancellation capability — lifecycle profile과 독립 축): 중단은 세션 표면에 광고된 중단 도구(예: `interrupt_agent`)가 있을 때만 수행하고, 없으면 conservative wait을 유지한다.
- active-session gate: 각 세션은 자기 표면의 tool 목록·slot 광고로 판별한다. CLI-default probe 결과를 다른 세션(예: Desktop fresh task)의 증거로 재사용하지 않는다. CLI와 Desktop의 표면이 다르면 하나로 강제하지 말고 별도 profile로 보고한다.
- CLI-default 실측 (codex-cli 0.146.0, 2026-08-02, `codex debug prompt-input` — surface_scope=cli-default): model-visible tools = `spawn_agent`, `followup_task`, `send_message`, `wait_agent`, `interrupt_agent`, `list_agents` (interrupt_agent 있음), 광고 slot = 17 (root 포함) → `current` profile, child batch 16. 같은 실측에서 full-history fork(`fork_turns` 생략/`"all"`)는 부모 model/effort를 상속하며 override를 받지 않는다고 광고됐다.
- fork 상속 금지 (DA 실행 단위 공통): full-history fork는 부모의 대화 이력과 model/effort를 상속하므로 DA reviewer/Arbiter spawn에 사용하지 않는다 — fresh 계약(빈 컨텍스트 시작)과 Arbiter 강도 하한([`arbiter-scaling.md`](arbiter-scaling.md) 정본)을 동시에 깨뜨린다. 실측에서 native 경로의 Arbiter가 fork 상속으로 reviewer보다 낮은 강도로 도는 역전이 다수 관측됐고(#1258), 부모의 이전 라운드 reviewer 원문·판정·수정 diff를 통째로 상속한 사례가 관측의 절반이었다(#1259). DA 실행 단위는 어떤 경로에서든 빈 컨텍스트 시작이 spawn 계약이다 — Codex native는 fresh spawn + effort 명시 설정만, Claude 경로는 컨텍스트를 상속하는 fork형 subagent를 쓰지 않는다. 하네스가 spawn 설정을 노출하지 않아 실행 전 확인이 불가능한 경로에서는 산출물 신호를 보조 감지로 사용하되, 신호는 "이번 입력(프롬프트·diff·참조 가능한 파일·git 이력)에 존재하지 않는 이전 라운드 결과의 정확한 finding ID나 원문 인용"으로 한정한다 — 후속 라운드 reviewer는 누적 diff와 git 이력을 정상적으로 읽으므로 수정 내용에 대한 일반 언급은 상속 증거가 아니다. 한정된 신호가 감지되면 해당 unit은 fresh 계약 위반으로 폐기하고 재실행한다.
- slot 수의 출처: 광고 slot은 codex 고정값이 아니라 `~/.codex/config.toml`의 `[agents].max_concurrent_threads_per_session`(root 제외 값)에서 온다. 본 repo template이 16으로 선언하므로 total 17이며, 키가 없는 순정 설정에서는 total 4(child 3)다. 위 실측치를 다른 머신·순정 설정의 근거로 재사용하지 않고, 세션마다 자기 표면의 광고 문장을 1차 근거로 삼는다 (active-session gate와 동일 원칙).
- 재검증: `./scripts/ai/verify-ai-compat.sh`의 "Codex CLI-default native capability probe" 검사가 sanitized tool-name set과 slot source만 파싱해 profile을 판정한다 (raw prompt 저장/출력 금지, `surface_scope=cli-default` 명시, unknown이면 fail). Codex pin 갱신 시 CLI-default 결과와 active-session 결과를 구분해 기록한다.

plain-text 재개 ≠ 질문 도구 — 일반 채팅 "질문 후 다음 턴 재개"는 blocking tool call이 아니므로 질문 도구로 간주하지 않는다. 질문 도구가 필수인 지점(SKIP 제안 승인, 3회 반복 판정, 라운드 한계효용 저하, 5회 라운드 초과, fresh 모드 반복 감지, remediation_scope UNCLEAR 판단)에서 Codex 세션은 `request_user_input`을 호출하고, headless 세션은 stdin 입력 불가로 자동 상태 전이 경로(arbiter-scaling.md)로 처리한다.

## fan-out 진행 보고 규약

fan-out 진행 가시성의 정본은 이 절이다. 메인 에이전트는 완료 이벤트를 기다리는 동안 사용자가 hang으로 오해하지 않도록, 런타임 이벤트에 반응하는 짧은 상태 보고를 남긴다.

- 발사 직후: 어떤 역할을 몇 개 발사했는지와 완료 알림으로 재개된다는 사실을 한 줄로 보고한다. 예: reviewer 4개 백그라운드 발사, 완료 알림 대기.
- 각 완료 이벤트 수신 시: 누적 완료 수와 전체 수를 한 줄로 보고한다. 예: reviewer 2/4 완료. 모든 결과가 모이기 전에도 이벤트를 받을 때마다 카운트를 갱신한다.
- 이 보고는 sleep/poll 루프를 도입하는 근거가 아니다. 결과 수집은 위 런타임 매핑 표의 완료 이벤트, foreground 종료, 결과 파일 읽기 경로만 따른다.
- headless serial foreground 경로는 백그라운드 완료 알림이 없으므로 각 subprocess 종료 직후 같은 카운트 형식으로 보고한다.

review profile 매핑 (fan-out 대상 역할별, 사용자 지정 없을 때 기본값):

| profile | 대상 | 모델 선택 | codex exec effort |
|---------|------|-----------|-------------------|
| `strong` | Arbiter | 세션/런타임 기본 모델 상속 | `high` |
| `standard` | reviewer / auditor | 세션/런타임 기본 모델 상속 | `medium` |

사용자가 자연어로 실행 경로·effort를 지정하면 위 기본 profile보다 우선한다. 적용 범위는 해당 호출의 reviewer/auditor와 Arbiter 전체다 (effort는 Arbiter 강도 하한 적용 후 — [`arbiter-scaling.md`](arbiter-scaling.md) 하한 정본).

| 자연어 지정 (예) | 실행 경로 | effort / 모델 처리 |
|----------|-----------|--------------------|
| "codex로 (xhigh/high/medium 등 effort와 함께)" | codex exec | 지정된 reasoning effort를 reviewer/auditor와 Arbiter 전체에 적용 (Arbiter는 강도 하한 적용 후). 모델명은 고정하지 않고 런타임 기본값을 사용한다 |
| "Claude 서브에이전트로" | Claude Code `Agent` tool | Claude Code 세션 모델을 상속한다. 특정 모델명을 지정하지 않는다 |

미지 값·불명확한 지정은 추론으로 채우지 않고 질문 도구로 확인한다 (`run-da/SKILL.md` "실행 경로·파라미터 지정" 해석 규칙).

사용자 지정 실행 파라미터 (model/effort/tier): 사용자가 자연어로 명시한 값은 codex exec 경로의 모든 실행 단위(reviewer/auditor/Arbiter)에 `-c` config override로 주입되며, 경로 지정의 role별 기본 effort보다 우선한다 (Arbiter는 하한 적용 후 — [`arbiter-scaling.md`](arbiter-scaling.md) 정본). 주입 경로는 축별로 다르다 — model/tier는 `_DA_MODEL_TIER_OVERRIDES` 배열로, effort는 고정 `-c model_reasoning_effort=` 인자로 별도 주입된다. 개념 정의는 `run-da/SKILL.md`, 실행 계약(env·shell-safe 검증·조립)은 [`arbiter-scaling.md`](arbiter-scaling.md)의 "사용자 지정 실행 파라미터" 섹션이 SSOT다. Claude 경로와 Codex 세션 native subagent 경로에는 model/tier 주입 수단이 없다 (경로 전환 확인 규칙은 `run-da/SKILL.md` 경로 제약). effort는 native 경로에서도 Arbiter 하한을 만족해야 한다 — 세션 표면에 spawn 단위 effort 설정 수단이 광고되어 있으면 그것으로 명시 설정한다. 광고된 수단이 없을 때의 전이(자동 전환 금지·승인 게이트·미지원 중단)는 [`arbiter-scaling.md`](arbiter-scaling.md)의 "Arbiter 추론 강도 하한" 절이 단독 소유한다.

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
- 모드 시작 시 이전 임시 디렉토리 정리: for_plan 시작 시 `rm -rf /tmp/da-${_DA_SID}-pr-*(N) /tmp/da-${_DA_SID}-arbiter-*(N) /tmp/da-${_DA_SID}-intensity-*(N) /tmp/da-pr-*(N) /tmp/da-arbiter-*(N) /tmp/da-intensity-*(N)`, for_pr 시작 시 `rm -rf /tmp/da-${_DA_SID}-plan-*(N) /tmp/da-${_DA_SID}-intensity-*(N) /tmp/da-plan-*(N) /tmp/da-intensity-*(N)`. 같은 모드의 이전 라운드는 라운드 교체 시 정리. `-intensity-*` glob은 마이그레이션 cleanup 용도다 — 폐기된 과거 판정 절차가 만든 고아 디렉토리를 자동 정리하기 위해 모드와 무관하게 cleanup 명령에 그대로 남긴다 (새로 생성되지는 않는다).
  zsh `(N)` qualifier로 매칭 파일 없을 때 오류를 방지한다. legacy glob(NS 없음)은 전환기 고아 디렉토리 정리용이다.
- 결과 파일 참조: `$DA_DIR`, `$ARBITER_DIR` 변수로 정확히 참조한다. `/tmp/da-*` 와일드카드 glob 금지 — 이전 실행의 결과가 섞인다.
- 셸 호출 간 변수 유지 (모든 런타임 공통): 위 공통 주의 참조. 런타임 종류와 무관하게 셸 호출마다 별도 shell이 생성되므로 `mktemp -d` 결과를 stdout으로 출력해 메인 에이전트가 다음 호출에서 리터럴로 재사용하거나 단일 shell에 체이닝한다. 상세 패턴은 [`arbiter-scaling.md`](arbiter-scaling.md)의 "셸 호출 변수 유실 방지" 참조.
- stdin pipe로 프롬프트 전달 (Layer 1 supervised wrapper): 모든 programmatic codex exec 호출은 `cat "$DIR/prompt.md" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral -c model_reasoning_effort="$RUN_DA_CODEX_EFFORT" "${_DA_MODEL_TIER_OVERRIDES[@]}" -o "$DIR/result.md" -` 형태의 Layer 1 supervised wrapper 호출을 사용한다 (raw `codex exec` 직접 호출은 user-interactive 전용이며 SKILL 내 programmatic 경로에서는 사용하지 않는다). 모델명·service_tier는 스킬이 고정하지 않는다 — `$RUN_DA_CODEX_EFFORT`는 기본 role profile 또는 사용자 명시 지정에서 결정하고, `_DA_MODEL_TIER_OVERRIDES`는 사용자 명시 model/tier가 있을 때만 채워진다 ([`arbiter-scaling.md`](arbiter-scaling.md) "사용자 지정 실행 파라미터" 섹션의 조립 루프를 같은 셸 호출 안에서 먼저 실행). `--ignore-rules`는 user/project execpolicy `.rules` 파일을 차단해 read-only sandbox로 막을 수 없는 network/system mutation 명령(예: `git push`, `aws ec2 describe`)이 reviewer/auditor에서 실행되지 않게 한다. pipe EOF가 stdin을 자동으로 닫아 background 전환 시 stdin hang을 구조적으로 방지한다. `< /dev/null`은 pipe가 대체하므로 불필요. 인라인 인자 `"$(cat file)"`는 사용하지 않는다. `CODEX_PROGRAMMATIC=1` env assignment는 pipeline 우측 codex 프로세스에 적용되어야 한다 (issue #585). wrapper 상세는 [`../../using-codex-exec/references/known-issues.md`](../../using-codex-exec/references/known-issues.md) §15 참조.
- Arbiter는 단일 exec (병렬 fan-out 없음): reviewer만 병렬 실행한다 (런타임별 병렬 실행 매커니즘은 위 표 참조). 발사 방식은 하네스 기준으로 갈린다 — Bash tool 경유 호출(대화형 세션·`claude -p` 공통)은 하네스 foreground 상한의 적용을 받는다. 세부 규칙의 정본은 [`arbiter-scaling.md`](arbiter-scaling.md) codex exec 경로 실행 계약이다.

### literal 재사용 시 random suffix 환각 금지 (issue #632)

Generic codex exec split-call rule은 [`using-codex-exec/references/known-issues.md`](../../using-codex-exec/references/known-issues.md#literal-재사용-시-random-suffix-환각-금지-issue-632)가 SSOT다. run-da 고유 적용은 `_DA_SID` 세션 네임스페이스와 `$DA_DIR`/`$ARBITER_DIR` 결과 파일 경로에 해당 generic rule을 적용하는 것이다.

## Claude Code 세션 fallback 세부 정보

Claude Code 세션에서 codex exec 사전점검이 실패했을 때는 legacy fallback으로 조용히 대체하지 않는다. 메인 에이전트는 실패 원인을 사용자에게 고지하고, 대안으로 Claude Code 서브에이전트 경로 진행 또는 중단을 확인받는다. 아래는 사용자가 Claude 경로 진행을 확인했거나 자연어로 Claude 경로를 명시한 경우의 Claude-Code-고유 lifecycle이다. 모델은 Claude Code 세션 모델을 상속한다.

| 항목 | Claude Code fallback |
|------|----------------------|
| fan-out | background fallback 실행 |
| wait | 자동 완료 알림 (background task notification) |
| close | 불필요 (완료 시 자동 해제) |
| thread-cap | Claude Code의 병렬 제한을 따름 |
| violation 처리 | 프롬프트에서 읽기 전용을 지시하지만, 구조적 보증이 아닌 프롬프트 수준 제약이다. 하위 fallback unit이 side effect를 만들 가능성이 있으므로, [`hardening-contract.md`](hardening-contract.md)의 역할별 경계(reviewer: 읽기+검색+scratch PoC만, Arbiter: 읽기 전용)를 프롬프트에 명시한다 |
