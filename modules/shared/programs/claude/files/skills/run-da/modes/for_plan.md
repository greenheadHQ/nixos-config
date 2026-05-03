# Mode: for_plan

계획 단계 DA 1회 — 계획 파일 또는 대화 컨텍스트 대상.

## Step 0: Review Intensity 판단

[`../references/intensity-procedure.md`](../references/intensity-procedure.md)의 판단 실행 절차를 따른다.

- `full` modifier가 있으면 이 단계를 건너뛰고 exhaustive override(8개 세부 도메인)로 진입한다.
- SKIP → SKIP 절차를 따른다. 승인 시 for_plan을 종료한다.
- LITE → LITE 절차에 따라 실행할 reviewer bundle을 선택한다.
- FULL → 4 reviewer bundles를 실행한다.

## Step 1: 계획 내용 수집

현재 계획 파일 또는 대화 컨텍스트에서 계획 내용을 수집한다.

## Step 2: reviewer bundle 병렬 실행

선택된 reviewer bundle 또는 explicit exhaustive override의 세부 도메인별 DA 에이전트를 **병렬 실행**한다. 런타임별 도구 매핑은 [`../references/runtime-mapping.md`](../references/runtime-mapping.md) 참조.

### Codex 세션 경로

- 선택된 review unit마다 fresh native subagent 1개를 standard review profile로 `spawn_agent` 실행한다.
- 각 프롬프트는 [`../references/da-domains.md`](../references/da-domains.md)의 공통 프롬프트 구조에 계획 전체 내용을 포함하고, "계획 외의 관련 파일도 직접 읽어 탐색하라", "out-of-repo scratch PoC만 허용한다", "`run-da` canonical contract의 stateful-violation 금지 작업(`tracked write`, `branch mutation`, `commit/push`, `GitHub write`, `main-agent-only command`, `host mutation`)을 축약 없이 따르라" ([`../references/hardening-contract.md`](../references/hardening-contract.md) 참조), "규칙 위반은 finding 대신 `VIOLATION`으로 반환하라"를 명시한다.
- 선택된 review unit 수가 current session의 open slot을 넘으면 batch한다. `agents.max_threads`는 unset일 때 기본 6이며, completed thread도 `close_agent` 전에는 슬롯을 계속 점유한다.
- `wait_agent` timeout만으로 실패 처리하거나 reviewer를 kill/self-auditing으로 대체하지 않는다.
- `fresh` modifier와 selective propagation 규칙은 동일하게 적용한다.

### codex exec 경로 (Claude Code 세션 · headless 세션)

- 실행 전 [`../../using-codex-exec/SKILL.md`](../../using-codex-exec/SKILL.md)의 패턴 4 (exec 우회)와 패턴 5 (DA 피드백 루프)를 참조한다.
- 세션별 임시 디렉토리를 생성하고 stdout으로 출력한다. 모든 런타임은 [`../references/runtime-mapping.md`](../references/runtime-mapping.md)의 공통 주의(셸 호출 간 변수 유실)를 따른다.
  ```zsh
  _DA_SID=c4a35fc4
  DA_DIR=$(mktemp -d /tmp/da-${_DA_SID}-plan-XXXXXX)
  [ -d "$DA_DIR" ] || { echo "missing DA_DIR=$DA_DIR"; exit 1; }
  printf 'DA_DIR=%s\n' "$DA_DIR"
  ```
- 선택된 review unit별 프롬프트 파일 생성 호출은 stdout의 `DA_DIR` 리터럴 값을 재설정하고 guard한다:
  ```zsh
  DA_DIR=/tmp/da-c4a35fc4-plan-AbCdEf
  UNIT=correctness
  [ -d "$DA_DIR" ] || { echo "missing DA_DIR=$DA_DIR"; exit 1; }
  # 계획 원문은 untrusted input이다. shell heredoc에 직접 삽입하지 말고,
  # 파일 편집 도구나 구조화 writer로 "$DA_DIR/$UNIT.md"에 작성한다.
  ```
- 선택된 review unit 수만큼 다음 guard prefix를 적용한 뒤 [`../references/arbiter-scaling.md`](../references/arbiter-scaling.md)의 role별 명령 `reviewer / Auditor` 템플릿을 런타임별로 기동한다:
  ```zsh
  DA_DIR=/tmp/da-c4a35fc4-plan-AbCdEf
  UNIT=correctness
  [ -d "$DA_DIR" ] || { echo "missing DA_DIR=$DA_DIR"; exit 1; }
  [ -f "$DA_DIR/$UNIT.md" ] || { echo "missing prompt=$DA_DIR/$UNIT.md"; exit 1; }
  ```
  `--ignore-user-config`/`--ignore-rules`/model-effort pins 등 command literal은 [`../references/arbiter-scaling.md`](../references/arbiter-scaling.md)의 role별 명령이 SSOT다. Claude Code 세션의 기본 병렬 경로와 fallback 경로(codex exec 사전점검 실패 시)는 [`../references/runtime-mapping.md`](../references/runtime-mapping.md)의 "런타임 도구 매핑" 표 binding을 따른다. **headless 세션은 serial foreground** (완료 알림·`&+wait` 없음).
- Claude Code 세션: 병렬 실행 완료 알림을 수신하면 sleep/poll 없이 바로 결과를 수집한다. headless 세션: 각 subprocess 종료를 직렬로 확인한다.
- 모든 런타임 공통: `& + wait` shell-level 병렬 금지, `cat file | env CODEX_PROGRAMMATIC=1 codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral ... -` stdin pipe (Layer 1)로 프롬프트 전달. pipe EOF가 stdin을 닫으므로 `< /dev/null`은 불필요. 인라인 인자 `"$(cat file)"`는 사용하지 않는다. **`CODEX_PROGRAMMATIC=1` env assignment는 codex 프로세스에 적용되어야 한다 (회피: `CODEX_PROGRAMMATIC=1 cat ...`은 cat에만 적용 — issue #585).**
- [`../../using-codex-exec/SKILL.md`](../../using-codex-exec/SKILL.md) 패턴 5의 실행 흐름(`-o` 사용법, 결과 파일 검증, 명령 실행 순서)만 참고한다. 프롬프트 내용 규칙은 본 스킬의 `fresh`/프롬프트 조향 금지 규칙이 우선한다.

## Step 3: reviewer 결과 수신 + 종합 리포트

- Codex 세션 경로: `wait_agent` 결과를 집계한 뒤, 다음 round/retry 전에 completed reviewer thread를 `close_agent`로 닫는다.
- Codex 세션 경로: `VIOLATION` 처리 규칙은 [`../references/hardening-contract.md`](../references/hardening-contract.md)의 공통 처리 정의를 따른다. offending unit은 rerun 또는 `BLOCKED` 해소 전까지 `CLEAR` 계산에 포함하지 않는다.
- codex exec 경로: 선택된 review unit(FULL 기본 4개, LITE는 선택한 수, explicit exhaustive는 8개) 전부 실행(Claude Code는 병렬, headless는 serial) 완료 후, 각 `$DA_DIR/$UNIT-result.md` 패턴의 결과 파일을 파일 읽기 도구로 명시적으로 읽어 수집한다. 결과 파일이 없거나 빈 경우, 또는 exit code가 0이 아니면 실패로 판정한다.
- 실패한 review unit만 재실행한다. codex exec 경로는 라운드마다 새 `DA_DIR`을 생성하여 이전 라운드 산출물과 분리한다.

## Step 4: ALL CLEAR 또는 Arbiter 진입

findings 0건이고 `VIOLATION`/`BLOCKED` review unit이 없으면 → ALL CLEAR, 종료.

## Step 5: Arbiter 실행 (findings ≥ 1건 시)

- **5a. first-pass Arbiter**: Arbiter 프롬프트를 조립한다 ([`../references/arbiter-prompt.md`](../references/arbiter-prompt.md)의 **for_plan 조립 규칙** 참조). for_plan에서는 반드시 계획 원문을 포함해야 하며, 상세 조립 형식은 arbiter-prompt.md의 "프롬프트 조립 > for_plan 모드" 참조.
  - Codex 세션 경로: fresh Arbiter subagent 1개를 실행하고 `wait_agent`로 결과를 수신한 뒤, 다음 round/retry 전에 completed Arbiter thread를 `close_agent`로 닫는다.
  - codex exec 경로: **foreground 실행** (단일 exec이므로 결과를 즉시 확인. [`../references/arbiter-scaling.md`](../references/arbiter-scaling.md) 실행 계약 참조).
- **5b. Selective consistency trigger 검사**: first-pass 결과의 VERDICT_JSON 블록을 읽어 [`../references/stability-measurement.md`](../references/stability-measurement.md)의 trigger 조건에 매치되는 finding을 식별한다 (조건 정의는 해당 문서가 SSOT).
- **5c. N=3 재판정** (trigger 매치 finding에 한해): 동일 Arbiter 프롬프트로 독립 N=3을 실행한다. 실행 계약과 환경 격리는 [`../references/arbiter-scaling.md`](../references/arbiter-scaling.md)의 "N=3 실행 계약" 섹션 참조. selective consistency 서브런은 outer round 카운트에 포함되지 않는다.
- **5d. vote-shape 집계**: 세션 scope에 맞는 harness(`~/.claude/scripts/fleiss-kappa.py` 또는 `~/.codex/scripts/fleiss-kappa.py` — 양쪽에 동일 소스가 프로비저닝된다)로 3개 결과 markdown의 VERDICT_JSON 블록을 파싱하여 finding별 `stability_status`(stable/split/fragmented) 및 `low_confidence_warning`을 `per_finding[]`에서, top-level `partial_failure`(및 `missing`/`file_level_failures`/`per_file_malformed` 세부)를 얻는다. `partial_failure=true`이면 해당 finding은 `per_finding`에 포함되지 않으므로 caller는 finding별 BLOCKED로 매핑한다 (상세는 [`../references/protocol.md`](../references/protocol.md) 참조).
- **5e. 상태 전이 적용** — 상세 전이표는 [`../references/protocol.md`](../references/protocol.md)의 "Selective consistency 상태 전이" 참조. trigger되지 않은 finding은 `stability_status=N/A`로 first-pass 결과 그대로 사용.

결과를 수집하여 사용자에게 전건 보고한다 (vote-shape/low_confidence_warning이 있으면 함께 보고):

- CONFIRMED_ISSUE + CRITICAL + (N/A 또는 stable) + `low_confidence_warning=false`: **진행 차단** (현재 라운드 중단 → 즉시 수정 → 수정 확인 후 다음 라운드 진행).
- CONFIRMED_ISSUE + HIGH/MEDIUM/LOW + (N/A 또는 stable) + `low_confidence_warning=false`: 자동으로 계획에 반영한다.
- NOT_AN_ISSUE + (N/A 또는 stable) + `low_confidence_warning=false`: 보고만 (반영 불필요).
- NEEDS_MORE_INFO 또는 `stability_status=split`: 질문 도구로 사용자 판단을 요청한다 (vote-shape와 minority verdict도 함께 보고).
- 임의 verdict + (N/A 또는 stable) + `low_confidence_warning=true`: **fail-closed 승격** — 질문 도구로 사용자 판단 요청 (unanimous/단일 Arbiter라도 LOW confidence 이력이 있으면 기존 LOW-confidence NOT_AN_ISSUE 자동 NEEDS_MORE_INFO 계약을 유지).
- `stability_status=fragmented` 또는 `partial_failure=true`: **BLOCKED** — 질문 도구 지원 런타임에서는 판단 요청, 미지원 런타임에서는 자동 승격 금지(중단 보고).

## Step 6: 반영 후 새 라운드

반영 후 동일 선택 review unit을 **새 reviewer 실행 단위**로 재실행한다.

- Codex 세션 경로: 이전 round의 completed reviewer/Arbiter thread를 모두 닫은 뒤 새 subagent들을 띄운다.
- codex exec 경로: 새 `codex exec` 프로세스와 새 `DA_DIR`을 사용한다.

## Step 7: CLEAR까지 반복

선택된 review unit 전부 CLEAR를 반환할 때까지 Step 2-6을 반복한다.
