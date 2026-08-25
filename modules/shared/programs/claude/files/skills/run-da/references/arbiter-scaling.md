# Arbiter 실행 계약

Arbiter 에이전트의 실행 계약과 실패 처리를 정의한다.

reviewer는 "없다"를 잘 찾지만, "없는 게 맞다"는 판단은 독립 검증자가 해야 한다. 이것이 reviewer와 분리된 Arbiter를 두는 이유다.

## 기본값: single strong arbiter

기본값은 항상 단일 강한 Arbiter 1개다.
`run-da`의 reviewer fan-out을 4 bundle로 줄이더라도, Arbiter는 늘리지 않는다.
비용을 늘려 여러 Arbiter를 붙이기보다, 한 명의 강한 Arbiter가 selective escalation set을 판정하는 구조를 유지한다.

사용자가 자연어로 경로/effort를 지정하면 해당 호출의 reviewer/auditor와 Arbiter 전체에 그 값이 우선한다. 사용자 지정 실행 파라미터(model/effort/tier — 정의는 `run-da/SKILL.md`)가 지정되면 그 값이 다시 경로 지정의 role별 기본값보다 우선한다. 지정이 없을 때만 role별 기본값을 사용한다: reviewer/auditor는 standard profile effort, Arbiter는 strong profile effort를 따른다. 값 정의와 경로 의미는 [`runtime-mapping.md`](runtime-mapping.md)의 review profile 매핑이 정본이다.

| Findings 개수 | Arbiter 수 |
|---|---|
| 0건 | 0 (SKIP) |
| 1건 이상 | 1 |

selective propagation으로 추린 escalated findings를 단일 Arbiter에 전달한다.

## 사용자 지정 실행 파라미터 (model / effort / service_tier)

사용자가 명시 지정한 model/effort/service_tier를 codex exec 실행 단위에 주입하는 실행 계약의 SSOT다. 개념 정의(자연어 채널, 해석 규칙, 우선순위, 경로 제약)는 `run-da/SKILL.md`의 "실행 경로·파라미터 지정" 섹션을 따른다.

| env | 의미 | 값 출처 (축별 provenance) |
|-----|------|---------------------------|
| `RUN_DA_CODEX_EFFORT` | resolved reasoning effort | 기본 role profile, 사용자 명시 경로/effort 지정 |
| `RUN_DA_CODEX_MODEL` | 사용자 명시 model. 미지정 시 unset — 스킬은 모델을 pin하지 않는다 | 사용자 명시 지정만. 이 env를 설정하는 행위 자체가 "사용자가 model을 명시했다"는 선언이다 — 명시 없이 설정하면 계약 위반 |
| `RUN_DA_CODEX_TIER` | 사용자 명시 service_tier. 미지정 시 unset | 사용자 명시 지정만. 설정 행위 = 명시 선언 (model과 동일) |
| `RUN_DA_USER_EFFORT_OVERRIDE` | 사용자가 effort 값을 명시 지정했음을 표시 (`1`). 기본 profile 밖 effort 값의 통과 관문 | 사용자가 effort를 명시 지정했을 때만 메인 에이전트가 설정. model/tier만 지정된 호출에서 설정하면 계약 위반 — 축별 provenance를 하나의 표식으로 뭉개지 않는다 |

- effort guard: 기본 profile 값(`medium|high|xhigh`)은 즉시 통과한다. 그 외 소문자 영문 값은 `RUN_DA_USER_EFFORT_OVERRIDE=1`(effort 축 전용 관문 — model/tier 지정 여부와 무관)일 때만 통과한다 — 스킬은 값 집합을 예단하지 않고 codex에 위임하며, codex/API가 거부하면 그 에러를 사용자에게 그대로 보고한다 (조용한 대체/하향 금지).
- model/tier 주입: 각 role 명령 안의 `_DA_MODEL_TIER_OVERRIDES` 조립 루프가 unset이 아닌 값만 shell-safe 문자 검증(영숫자 `._-`) 후 `-c model=...` / `-c service_tier=...` config override 인자로 추가한다. effort는 모든 호출의 필수 인자이므로 이 배열이 아니라 고정 `-c model_reasoning_effort=`로 별도 주입한다. 미지정 시 빈 배열이라 기존 기본 계약과 동일하게 동작한다.
- ambient 유입 차단: 위 env들은 role 명령과 같은 단일 셸 호출 안에서 caller가 그 호출을 위해 설정한다 (셸 호출 간 env 비공유 — [`runtime-mapping.md`](runtime-mapping.md) 공통 주의). 이전 호출·세션에서 상속된 ambient 값을 재사용하지 않으며, 명시되지 않은 축의 env는 설정하지 않는다.
- 조립 루프 복제 이유: 세 role command block(reviewer/Auditor 템플릿, Arbiter 템플릿, Arbiter 실행 절차)은 각각 단일 셸 호출로 self-contained해야 하므로 같은 effort guard·조립 루프를 블록마다 복제한다. 세 사본의 동일성은 sync 테스트(`tests/skill-doc-sync.py`의 exec override copies 검사)가 정규화 비교로 강제한다.
- `--ignore-user-config`와의 관계: user config 차단(MCP surface 차단 목적)은 유지된다. 이 채널은 config 파일이 아니라 사용자 명시 입력값만 `-c`로 재주입한다.

## 실행 계약 (런타임 분기)

### Codex 세션 경로

현재 세션이 native subagent 오케스트레이션(`spawn_agent`, `wait_agent`; lifecycle은 [`runtime-mapping.md`](runtime-mapping.md#codex-native-lifecycle-capability-profile) capability profile로 판별)을 사용할 수 있으면
Arbiter도 이를 기본 경로로 사용한다.

- 매 실행마다 fresh Arbiter subagent는 [run-da canonical contract](hardening-contract.md)의 strong review profile([`runtime-mapping.md`](runtime-mapping.md) review profile 매핑)로 사용한다.
- 프롬프트는 `spawn_agent` 입력에 직접 포함한다. tmp prompt 파일을 요구하지 않는다.
- Arbiter는 review-only/no-write role이다. 파일 수정, scratch PoC, branch mutation, GitHub write, `wt`/`nrs`/rebuild 계열 실행을 하지 않는다.
- 결과 수집: [`runtime-mapping.md`](runtime-mapping.md#result-collection)의 결과 수집 binding을 따른다 (무엇이 결과 본문이고 `wait_agent` 반환값이 무엇인지는 그 anchor가 정의한다). timeout만으로 실패 처리하거나 중간 kill/self-auditing으로 대체하지 않는다. 수집한 본문은 `/tmp/da-${_DA_SID}-arbiter-*` 네임스페이스의 scratch 파일로 저장한다 — 공통 검증기가 파일 입력 전용이므로 native 경로도 이 저장 단계를 거쳐야 검증을 수행할 수 있다 (메인 에이전트가 쓰는 결과 파일이며, Arbiter의 no-write role과 무관하다). 결과 파싱 후의 slot·batch 규칙은 capability profile을 따른다 ([`runtime-mapping.md`](runtime-mapping.md#codex-native-lifecycle-capability-profile) SSOT).

### codex exec 경로 (Claude Code 세션 · headless 세션)

Claude Code에서 Codex CLI를 subprocess로 호출할 때, 비대화형 automation일 때,
또는 사용자가 `codex exec`를 명시적으로 요구할 때는 기존 `codex exec` 계약을 따른다.

- `codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral` (issue #593 Layer 1: timeout capability-probe wrapper, [`../../using-codex-exec/references/known-issues.md`](../../using-codex-exec/references/known-issues.md) §15 SSOT). 주의: 이 literal에서 `--sandbox read-only`를 제거하면 audit/for_plan의 사후 변조 감지 생략 전제가 무너진다 ([`../modes/audit.md`](../modes/audit.md) "사후 변조 감지" 절이 복원 조건의 정본)
- 단일 exec (병렬 fan-out 없음). 발사 방식은 하네스 기준으로 갈린다 — 하네스 foreground 상한은 세션 라벨이 아니라 Bash tool 속성이다 (상한 수치·근거 사실의 정본은 [`../../using-codex-exec/SKILL.md`](../../using-codex-exec/SKILL.md) "foreground/background 상한 불일치" 절이며, 발사 방식 계약 자체는 본 절이 소유한다). 대화형 Claude Code 세션은 그 상한이 wrapper budget보다 먼저 걸리므로 `run_in_background: true`로 발사하고 완료 알림으로 결과를 수집한다. headless 중 `claude -p`도 같은 Bash tool 상한이 적용되므로 상한 면제가 아니다 — serial foreground로 실행할 때는 `timeout` 파라미터를 반드시 최대치로 명시하고, 그 상한을 초과할 것으로 예상되는 실행은 계획하지 않는다. CI·`codex exec` subprocess 셸은 serial foreground (완료 알림 없음). 런타임별 매커니즘은 [`runtime-mapping.md`](runtime-mapping.md) "런타임 도구 매핑" 표 참조
- `-o "$ARBITER_DIR/arbiter-result.md"` 결과 파일
- `cat "$ARBITER_DIR/arbiter-prompt.md" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised ... -` stdin pipe로 프롬프트 전달 (pipe EOF가 stdin hang 방지; marker는 codex 프로세스에 적용 — issue #585)
- `2>"$ARBITER_DIR/arbiter-stderr.log"` stderr 분리
- 모델명·service_tier는 스킬이 pin하지 않는다. `RUN_DA_CODEX_EFFORT`를 role별 기본 profile 또는 사용자 명시 지정에서 결정한 뒤 `-c model_reasoning_effort="$RUN_DA_CODEX_EFFORT"`를 명시하고, 사용자 명시 model/tier가 있으면 `_DA_MODEL_TIER_OVERRIDES`로 추가 주입한다 (위 "사용자 지정 실행 파라미터" 섹션).
- Arbiter는 지정이 없으면 strong review profile effort를 사용한다.
- 프롬프트에서 "리뷰만 수행하고 파일을 수정하지 마라" 명시
- `--ephemeral`로 세션 히스토리 오염 방지

`& + wait` shell-level 병렬을 사용하지 않는다 (런타임 공통; Claude Code Bash tool sandbox 제약에서 유래했으나 Codex `exec_command`·headless 셸 모두 동일하게 적용).
`cat file | env CODEX_PROGRAMMATIC=1 codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral ... -` stdin pipe로 프롬프트를 전달한다 (Layer 1, 아래 role별 명령 블록 참조). 인라인 인자 `"$(cat file)"`는 사용하지 않는다 (marker는 codex 프로세스 적용 — issue #585).

### Codex delegation-denied fallback (subprocess 실행 계약)

Codex 세션에서 `spawn_agent`가 정책상 거부될 때(예: `multi_agent=false`, `"delegation not permitted"`·`"multi_agent disabled"` 에러) 사용되는 subprocess 실행 계약이다. [`hardening-contract.md`](hardening-contract.md)의 "Delegation fallback" 섹션은 정책 요약(승인 관문, 자동 우회 금지)만 두고, 실제 명령은 이 섹션이 SSOT다.

공통:
- `--sandbox read-only` + `--ignore-user-config` + `--ignore-rules`를 함께 강제한다. `--sandbox read-only`는 model-generated shell command의 파일시스템 쓰기만 막고, user `config.toml`의 MCP server/plugin/connector 로딩은 차단하지 못한다. `--ignore-user-config`는 `$CODEX_HOME/config.toml`의 user MCP/plugin/connector surface를 차단하지만, cwd 기반 project config (`.codex/config.toml`의 `[mcp_servers.*]`)는 차단하지 못한다. 현재 worktree에 project-scoped MCP connector가 있을 때의 project-config 한계는 `run-da/SKILL.md` Non-goals #1이 canonical이다. `--ignore-rules`는 user/project execpolicy `.rules` 파일을 차단해 read-only sandbox로 막을 수 없는 network/system mutation 명령(예: `git push`, `aws ec2 describe`)이 reviewer/auditor에서 실행되지 않게 한다.
- `--ignore-user-config`는 `$CODEX_HOME/config.toml`의 `model_reasoning_effort`도 차단하므로 role별 표의 `RUN_DA_CODEX_EFFORT` guard와 `-c model_reasoning_effort="$RUN_DA_CODEX_EFFORT"` 명시가 필수다. 모델명·service_tier는 스킬이 pin하지 않으며, 사용자 명시 지정이 있을 때만 `_DA_MODEL_TIER_OVERRIDES`로 주입한다 (위 "사용자 지정 실행 파라미터" 섹션).
- `--ephemeral`로 세션 히스토리 오염 방지.
- `exec_command`를 `cat "$DIR/prompt.md" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral ... - 2>stderr.log` 형태로 stdin pipe 전달.
- 각 review unit은 독립 subprocess (fresh 판정 경계는 프로세스 경계로 보존).
- 사용자 승인 후에만 실행 ([`hardening-contract.md`](hardening-contract.md) "Delegation fallback" 섹션 참조).

role별 명령 (각 역할이 사용하는 임시 디렉토리와 파일 이름 규약은 [`../modes/for_plan.md`](../modes/for_plan.md) / [`../modes/for_pr.md`](../modes/for_pr.md) 본문 절차를 따른다). 주의: 아래 block들의 wrapper 호출 literal에서 `--sandbox read-only`를 제거하면 audit/for_plan의 사후 변조 감지 생략 전제가 무너진다 ([`../modes/audit.md`](../modes/audit.md) "사후 변조 감지" 절이 복원 조건의 정본). 아래 fenced code block은 caller가 `DA_DIR`/`UNIT`을 현재 flow의 stdout 리터럴 값으로 설정하고, `RUN_DA_CODEX_EFFORT`를 profile resolution 결과로 설정한 뒤(사용자가 model/tier를 명시했으면 `RUN_DA_CODEX_MODEL`/`RUN_DA_CODEX_TIER`를, effort를 명시했으면 `RUN_DA_USER_EFFORT_OVERRIDE=1`을 — 각 축은 명시된 경우에만) guard와 함께 실행한다. 모델명은 literal로 고정하지 않는다. 기본 role effort 매핑은 [`runtime-mapping.md`](runtime-mapping.md)의 review profile 매핑 표가 SSOT다.

| profile | 기본 `RUN_DA_CODEX_EFFORT` |
|---------|----------------------------|
| `standard` | `medium` |
| `strong` | `high` |

사용자가 자연어로 effort를 지정하면 (예: "전부 xhigh로") 위 기본값 대신 그 값을 reviewer/auditor와 Arbiter 전체에 사용한다 (위 "사용자 지정 실행 파라미터" 섹션의 guard 경유).

reviewer / Auditor (standard profile):

```bash
: "${DA_DIR:?missing DA_DIR}"
: "${UNIT:?missing UNIT}"
: "${RUN_DA_CODEX_EFFORT:?missing RUN_DA_CODEX_EFFORT}"
case "$UNIT" in
  *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*)
    echo "invalid UNIT=$UNIT"; exit 1 ;;
esac
case "$RUN_DA_CODEX_EFFORT" in
  medium|high|xhigh) ;;
  *[!abcdefghijklmnopqrstuvwxyz]*)
    echo "invalid RUN_DA_CODEX_EFFORT=$RUN_DA_CODEX_EFFORT"; exit 1 ;;
  *)
    [ "${RUN_DA_USER_EFFORT_OVERRIDE:-}" = "1" ] || {
      echo "non-default RUN_DA_CODEX_EFFORT=$RUN_DA_CODEX_EFFORT requires RUN_DA_USER_EFFORT_OVERRIDE=1"; exit 1; } ;;
esac
# 사용자 지정 실행 파라미터 조립 — 미지정 시 빈 배열 (기본 계약과 동일. "사용자 지정 실행 파라미터" 섹션)
_DA_MODEL_TIER_OVERRIDES=()
for _kv in "model=${RUN_DA_CODEX_MODEL:-}" "service_tier=${RUN_DA_CODEX_TIER:-}"; do
  case "${_kv#*=}" in
    "") ;;
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*)
      echo "invalid $_kv"; exit 1 ;;
    *) _DA_MODEL_TIER_OVERRIDES+=(-c "$_kv") ;;
  esac
done
[ -d "$DA_DIR" ] || { echo "missing DA_DIR=$DA_DIR"; exit 1; }
[ -f "$DA_DIR/$UNIT.md" ] || { echo "missing prompt=$DA_DIR/$UNIT.md"; exit 1; }
# marker must apply to `codex`, not `cat` (issue #585): Codex 0.124+ user-level hooks의 early-exit 신호.
cat "$DA_DIR/$UNIT.md" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral \
  -c model_reasoning_effort="$RUN_DA_CODEX_EFFORT" "${_DA_MODEL_TIER_OVERRIDES[@]}" \
  -o "$DA_DIR/$UNIT-result.md" - 2>"$DA_DIR/$UNIT-stderr.log"
```

Arbiter (strong profile):

```bash
: "${ARBITER_DIR:?missing ARBITER_DIR}"
: "${RUN_DA_CODEX_EFFORT:?missing RUN_DA_CODEX_EFFORT}"
case "$RUN_DA_CODEX_EFFORT" in
  medium|high|xhigh) ;;
  *[!abcdefghijklmnopqrstuvwxyz]*)
    echo "invalid RUN_DA_CODEX_EFFORT=$RUN_DA_CODEX_EFFORT"; exit 1 ;;
  *)
    [ "${RUN_DA_USER_EFFORT_OVERRIDE:-}" = "1" ] || {
      echo "non-default RUN_DA_CODEX_EFFORT=$RUN_DA_CODEX_EFFORT requires RUN_DA_USER_EFFORT_OVERRIDE=1"; exit 1; } ;;
esac
# 사용자 지정 실행 파라미터 조립 — 미지정 시 빈 배열 (기본 계약과 동일. "사용자 지정 실행 파라미터" 섹션)
_DA_MODEL_TIER_OVERRIDES=()
for _kv in "model=${RUN_DA_CODEX_MODEL:-}" "service_tier=${RUN_DA_CODEX_TIER:-}"; do
  case "${_kv#*=}" in
    "") ;;
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*)
      echo "invalid $_kv"; exit 1 ;;
    *) _DA_MODEL_TIER_OVERRIDES+=(-c "$_kv") ;;
  esac
done
[ -d "$ARBITER_DIR" ] || { echo "missing ARBITER_DIR=$ARBITER_DIR"; exit 1; }
[ -f "$ARBITER_DIR/arbiter-prompt.md" ] || { echo "missing prompt=$ARBITER_DIR/arbiter-prompt.md"; exit 1; }
cat "$ARBITER_DIR/arbiter-prompt.md" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral \
  -c model_reasoning_effort="$RUN_DA_CODEX_EFFORT" "${_DA_MODEL_TIER_OVERRIDES[@]}" \
  -o "$ARBITER_DIR/arbiter-result.md" - 2>"$ARBITER_DIR/arbiter-stderr.log"
```

`-o` 플래그(`--output-last-message <FILE>`)가 마지막 메시지를 결과 파일로 저장한다 (이것이 없으면 파일 수집 계약이 깨진다). stderr도 별도 로그 파일로 분리해 실패 진단을 보존한다.

실행 방식: serial (multiple review units를 순차 실행). 병렬 발사는 `spawn_agent`가 거부된 상황이므로 shell-level `&+wait` 대신 각 subprocess를 직렬로 기동한다. 결과 파일은 reviewer/Auditor 템플릿의 `$DA_DIR/$UNIT-result.md` 경로에 수집 후 메인 에이전트가 파싱한다.

Degraded mode 계약 (fallback 경로 한정): `--sandbox read-only` 강제로 인해 reviewer는 [`hardening-contract.md`](hardening-contract.md) "역할별 경계" 표의 `out-of-repo private scratch PoC (mktemp -d, umask 077)`를 이 경로에서는 수행할 수 없다. fallback reviewer는 파일 증거·문서 인용·diff 확인만으로 finding을 생성하고, scratch PoC가 필요한 지적은 "PoC 불가 — 문서/파일 증거 기반 추정"임을 명시한 뒤 심각도를 보수적으로 보고한다. 이 제약은 fallback이 `spawn_agent` 원본 경로의 수용 가능한 근사임을 인정하는 것이며, 구조적 write 차단이 우선이다.

실패 처리: 이 경로에서도 exit code ≠ 0, 빈 결과 파일, stdin hang은 위 "codex exec 경로" 섹션의 실패 감지 규칙을 따른다. `codex` binary 부재나 반복 실패 시 BLOCKED 처리.

## 실행 절차

### Codex 세션 경로

1. Arbiter용 fresh subagent는 strong review profile로 띄운다.
2. 프롬프트에는 관련 reference 문서를 직접 읽고, review-only/no-write contract를 따르며, 파일을 수정하지 말라고 명시한다.
3. 결과를 수집해 scratch 결과 파일로 저장한다 ([`runtime-mapping.md`](runtime-mapping.md#result-collection) binding). timeout만으로 실패 처리하거나 중간 kill/self-auditing으로 대체하지 않는다.
4. 결과 파싱 후 slot·batch 규칙은 capability profile을 따른다 ([`runtime-mapping.md`](runtime-mapping.md#codex-native-lifecycle-capability-profile) SSOT).

### codex exec 경로 (Claude Code 세션 · headless 세션)

이 절차는 준비(#1 임시 디렉토리 + #2 프롬프트 작성)와 발사·수집(#3 codex exec + #4 결과 확인) 두 단계다. headless serial foreground 경로는 전체를 단일 셸 호출로 체이닝한다 (셸 호출 간 환경변수 비공유 — 호출을 나누면 `$ARBITER_DIR`이 유실됨). 대화형 Claude Code 세션의 background 발사는 준비 호출과 발사·수집 호출을 별도 Bash 호출로 분리한다 — heredoc(프롬프트 작성)과 codex exec를 `run_in_background` 호출 하나에 합치는 것은 hang 금지 패턴이다 ([`using-codex-exec/known-issues.md`](../../using-codex-exec/references/known-issues.md) §11 하위 항목). 분리 시 준비 호출이 stdout으로 출력한 `$ARBITER_DIR` 리터럴을 발사 호출에서 재설정하고 `[ -d ]`/`[ -f ]` guard를 적용한다. literal 재사용 환각 주의 (issue #632): suffix를 검증 없이 변형·재생성하지 않는다 — full rule은 [`using-codex-exec/known-issues.md`](../../using-codex-exec/references/known-issues.md#literal-재사용-시-random-suffix-환각-금지-issue-632)를 따른다.

```bash
# 1. Arbiter 임시 디렉토리 생성
# 같은 shell 안에서 runtime-mapping.md "세션 네임스페이스" 블록을 먼저 실행한다.
[ -n "$_DA_SID" ] || { echo "ARBITER_FAILED: missing _DA_SID; initialize per runtime-mapping.md"; exit 1; }
ARBITER_DIR=$(mktemp -d /tmp/da-${_DA_SID}-arbiter-XXXXXX)
[ -d "$ARBITER_DIR" ] || { echo "ARBITER_FAILED: missing dir=$ARBITER_DIR"; exit 1; }

# 2. Arbiter 프롬프트 파일 조립 (arbiter-prompt.md의 조립 규칙 참조)
cat > "$ARBITER_DIR/arbiter-prompt.md" <<'PROMPT'
{조립된 Arbiter 프롬프트 — 비신뢰 텍스트(계획 원문, DA 결과) 포함 시 반드시 quoted heredoc 사용}
PROMPT
[ -f "$ARBITER_DIR/arbiter-prompt.md" ] || { echo "ARBITER_FAILED: missing prompt=$ARBITER_DIR/arbiter-prompt.md"; exit 1; }

# 3. codex exec 실행 (발사 방식은 위 "codex exec 경로" 실행 계약이 정본 — 분기 서술을
#    여기 복제하지 않는다)
# RUN_DA_CODEX_EFFORT는 role별 기본 profile 또는 사용자 명시 지정에서 결정한다.
RUN_DA_CODEX_EFFORT="${RUN_DA_CODEX_EFFORT:-high}"
case "$RUN_DA_CODEX_EFFORT" in
  medium|high|xhigh) ;;
  *[!abcdefghijklmnopqrstuvwxyz]*)
    echo "ARBITER_FAILED: invalid RUN_DA_CODEX_EFFORT=$RUN_DA_CODEX_EFFORT"; exit 1 ;;
  *)
    [ "${RUN_DA_USER_EFFORT_OVERRIDE:-}" = "1" ] || {
      echo "ARBITER_FAILED: non-default RUN_DA_CODEX_EFFORT=$RUN_DA_CODEX_EFFORT requires RUN_DA_USER_EFFORT_OVERRIDE=1"; exit 1; } ;;
esac
# 사용자 지정 실행 파라미터 조립 — 미지정 시 빈 배열 (기본 계약과 동일. "사용자 지정 실행 파라미터" 섹션)
_DA_MODEL_TIER_OVERRIDES=()
for _kv in "model=${RUN_DA_CODEX_MODEL:-}" "service_tier=${RUN_DA_CODEX_TIER:-}"; do
  case "${_kv#*=}" in
    "") ;;
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*)
      echo "ARBITER_FAILED: invalid $_kv"; exit 1 ;;
    *) _DA_MODEL_TIER_OVERRIDES+=(-c "$_kv") ;;
  esac
done
# marker must apply to `codex`, not `cat` (issue #585): Codex 0.124+ user-level hooks의 early-exit 신호.
cat "$ARBITER_DIR/arbiter-prompt.md" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral \
  -c model_reasoning_effort="$RUN_DA_CODEX_EFFORT" "${_DA_MODEL_TIER_OVERRIDES[@]}" \
  -o "$ARBITER_DIR/arbiter-result.md" \
  - \
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

### 셸 호출 간 변수 유실 방지

(legacy anchor: `Bash tool 변수 유실 방지`. 런타임 공통 — Claude Code Bash tool에서 처음 노출됐으나 Codex `exec_command`·headless 셸 모두 동일 제약.)

`codex exec` 결과를 파일로 받아 후속 처리하는 경우, 실행 절차의 두 단계 구조(준비 / 발사·수집)를 따른다 — 각 단계 내부는 단일 셸 호출로 체이닝하고, 단계를 나눌 때는 stdout으로 출력된 리터럴 경로 재설정 + guard가 필수다.

아래는 호출을 분리하면 발생하는 잘못된 패턴이다:

```bash
# 잘못된 패턴 — 변수가 다음 호출에서 유실됨
# [호출 1] ARBITER_DIR=$(mktemp -d /tmp/da-${_DA_SID}-arbiter-XXXXXX)
# [호출 2] codex exec -o "$ARBITER_DIR/result.md" ...
#   ← $ARBITER_DIR이 unset → "/result.md" (루트 경로)로 확장됨
```

## 실패 처리

단일 호출 패턴에서의 실패 감지: 위 코드블록은 `exit 1`로 종료하여 셸 호출이 비정상 종료로 보고된다. stdout에 `ARBITER_FAILED:` 접두어가 출력되며, `dir=` 필드에 임시 디렉토리 경로, 이어서 stderr 로그 내용이 포함된다. 메인 에이전트는 셸 호출의 exit code 또는 stdout의 `ARBITER_FAILED:` 접두어로 실패를 감지한다.

### Semantic malformed (VERDICT_JSON 계약 위반) — 모든 런타임 공통 전이

VERDICT_JSON caller 검증 위반은 아래 generic 실패 처리·recoverable violation·질문 도구 미지원 자동 전이보다 우선하는 별도 분류다. 이 문서가 소유하는 것은 그 우선순위뿐이며, 무엇이 위반인지와 위반 시 어떤 전이를 밟는지는 [`protocol.md`](protocol.md)의 "수렴 판정" caller 검증이 정본이다 (여기서 버전·재시도 횟수·차단 단위를 재서술하지 않는다 — 사본을 두면 계약이 바뀔 때 한쪽만 갱신되고 링크 때문에 정본을 따르는 것처럼 보인다).

### Arbiter 실패

codex exec 실패 시 (exit code != 0, 빈 결과 파일):

1. 해당 Arbiter 실행의 모든 findings를 NEEDS_MORE_INFO로 일괄 승격한다 (fail-closed).
2. 사용자에게 질문 도구로 보고한다 (맥락 설명 의무 적용).
3. 재시도하지 않는다 (사용자가 판단).

## Codex 세션 violation 처리

Codex 세션 경로에서는 Arbiter가 새 verdict를 반환하는 것이 아니라, 메인 에이전트가 contract breach 또는 malformed output을 감지했을 때 아래 규칙으로 분류한다.

- `recoverable violation`: 출력 형식 위반, prompt contract 미준수처럼 상태를 바꾸지 않은 위반. 결과를 폐기하고 fresh subagent로 1회 재실행한다. 단 VERDICT_JSON caller 검증 위반은 위 "Semantic malformed" 분류가 우선한다 (전이는 [`protocol.md`](protocol.md) caller 검증이 정본).
- `stateful violation`: tracked write, branch mutation, commit/push, GitHub write, main-agent-only command 실행, host mutation처럼 상태를 바꾼 위반. 라운드 중단·offending thread 중단·회수·정리의 공통 계약은 [`hardening-contract.md`](hardening-contract.md)의 VIOLATION 처리가 정본이며 여기에 재정의하지 않는다 (cancellation·slot 회수 도구 binding은 [`runtime-mapping.md`](runtime-mapping.md#codex-native-lifecycle-capability-profile)).
- stateful violation은 이번 라운드에서 offending unit이 만든 scratch 산출물과 임시 ref/branch만 정리 대상으로 삼는다. 기존 local tracked/untracked 변경은 자동 정리하지 않는다.
- 비가역적 외부 side effect가 있었거나 cleanup 범위를 특정할 수 없으면 질문 도구 가능 시 사용자에게 보고하고, 질문 도구 미지원 런타임에서는 자동 `CLEAR` 처리하지 않고 `BLOCKED`로 남긴다. 명시적 rerun 전에는 재개하지 않는다.

## 런타임 선택 규칙

- Codex 세션 경로는 현재 세션이 capability profile 판별([`runtime-mapping.md`](runtime-mapping.md#codex-native-lifecycle-capability-profile))에서 current로 판정되어 native orchestration이 가능할 때 기본 경로다. unknown이면 같은 SSOT의 fail-safe(serial 동시 1) 또는 codex exec fallback 규칙을 따른다.
- codex exec 경로는 Claude Code 세션(codex exec 기본 → Agent tool fallback)과 headless 세션(CI, `claude -p`)에서 기본 경로다.
- `CODEX_CI=1`은 Codex 세션에서도 보일 수 있으므로 sole discriminator로 쓰지 않는다.

## 질문 도구 미지원 대응

(legacy alias: `AskUserQuestion 미지원 대응`. 본 섹션은 질문 도구가 호출 불가능한 런타임에서의 자동 승격/종료 정책을 기술한다.)

현재 런타임에서 질문 도구(Claude Code의 `AskUserQuestion` 도구, Codex의 `request_user_input` 등)를 호출할 수 없는 경우 (대표 사례: headless 세션 — `claude -p`, `codex exec` subprocess, CI — stdin 입력 불가) 다음 규칙을 적용한다.

`request_user_input`은 codex 0.106+에서 default mode 활성화 가능 (`default_mode_request_user_input=true`). 본 nixos-config는 이를 충족하므로 Codex 세션은 지원 런타임으로 간주한다 — Codex 세션 자체는 본 섹션 자동 전이 적용 대상이 아니다.

- NEEDS_MORE_INFO 항목은 CONFIRMED_ISSUE로 자동 승격한다 (텍스트 보고만으로는 상태 전이가 불가능하므로). 단 semantic malformed는 이 자동 승격 대상이 아니다 — 위 "Semantic malformed" 분류를 따른다 (전이는 [`protocol.md`](protocol.md) caller 검증이 정본).
- CONFIRMED_ISSUE는 동일하게 자동 수정한다.
- 에이전트가 SKIP을 제안하려는 상황에서 질문 도구 불가 → 자동 LITE 승격 (SKIP 확정은 사용자 승인 없이는 불가하므로).
- 3회 반복 규칙 도달 시 질문 도구 불가 → 자동 수용 (지적대로 수정).
- 5회 라운드 초과 시 질문 도구 불가 → 자동 종료(현재 상태 보고).
- 라운드 한계효용 확인 또는 추세 기반 조기 중단([`protocol.md`](protocol.md)의 "최대 라운드 수" 정의) 도달 시 질문 도구 불가 → 현재 상태를 보고하고 종료한다. 한계효용 저하나 추세 비수렴은 추가 자동 수정을 시도할 근거가 아니므로([`protocol.md`](protocol.md)의 changeset 동결/범위 축소 권고를 따른다), 현재 미해결 상태를 보고한 뒤 종료한다 — CLEAR로 간주하지 않는다.
