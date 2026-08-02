# Arbiter 동적 스케일링 규칙

Arbiter 에이전트의 실행 수, 실행 계약, 실패 처리를 정의한다.

reviewer는 "없다"를 잘 찾지만, "없는 게 맞다"는 판단은 독립 검증자가 해야 한다. 이것이 reviewer와 분리된 Arbiter를 두는 이유다.

## 기본값: single strong arbiter

P0 기본값은 항상 단일 강한 Arbiter 1개다.
`run-da`의 reviewer fan-out을 4 bundle로 줄이더라도, Arbiter는 기본적으로 늘리지 않는다.
비용을 늘려 여러 Arbiter를 붙이기보다, 한 명의 강한 Arbiter가 selective escalation set을 판정하는 구조를 유지한다.

`agent=` 실행 프로파일 인자가 지정되면 해당 호출의 reviewer/auditor와 Arbiter 전체에 그 값이 우선한다. 사용자 지정 실행 파라미터(model/effort/tier — 정의는 `run-da/SKILL.md`)가 지정되면 그 값이 다시 `agent=`보다 우선한다. 인자가 없을 때만 role별 기본값을 사용한다: reviewer/auditor는 standard profile effort, Arbiter는 strong profile effort를 따른다. 값 정의와 경로 의미는 [`runtime-mapping.md`](runtime-mapping.md)의 review profile 매핑이 정본이다.

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

## Selective consistency (vote-shape 기반 first-pass trigger)

위 "예외적 확장 조건"이 정성적/사후적 근거 기반 확장이라면, selective consistency는 first-pass Arbiter 결과에서 애매성이 감지되자마자 구조화된 방식으로 N=3 재판정을 발동하는 경로다. 이 경로와 예외적 확장은 상호 보완이며, 대부분의 실무 케이스는 selective consistency가 처리한다.

정책 정의(트리거 조건, vote-shape, threshold 상수)는 [`stability-measurement.md`](stability-measurement.md)가 단일 진실 원천이다. 이 문서는 실행 계약만 다루며 정책 원자를 재서술하지 않는다.

- 실행 단위: N=3 독립 Arbiter (fresh subagent 또는 fresh `codex exec` 프로세스).
- 집계: `fleiss-kappa.py` helper로 VERDICT_JSON 블록을 파싱. helper 실체 해석 순서(현재 문서와 같은 checkout 우선, 전역 `~/.claude/scripts/`·`~/.codex/scripts/`는 폴백)와 호출 전 capability 확인은 [`protocol.md`](protocol.md)의 "검증기 실체 해석"이 SSOT다. 호출 인자 계약(`--expect-findings` 필수)은 아래 N=3 실행 계약의 집계 단계가 정의한다.
- 상태 전이는 [`protocol.md`](protocol.md)의 "Selective consistency 상태 전이" 섹션.
- N=3 실행 세부는 아래 "Selective consistency N=3 실행 계약" 섹션.

## 사용자 지정 실행 파라미터 (model / effort / service_tier)

사용자가 명시 지정한 model/effort/service_tier를 codex exec 실행 단위에 주입하는 실행 계약의 SSOT다. 개념 정의(자연어 채널, 해석 규칙, 우선순위, 경로 제약)는 `run-da/SKILL.md`의 같은 이름 섹션을 따른다.

| env | 의미 | 값 출처 (축별 provenance) |
|-----|------|---------------------------|
| `RUN_DA_CODEX_EFFORT` | resolved reasoning effort | 기본 role profile, `agent=` 인자, 또는 사용자 명시 effort |
| `RUN_DA_CODEX_MODEL` | 사용자 명시 model. 미지정 시 unset — 스킬은 모델을 pin하지 않는다 | 사용자 명시 지정만. 이 env를 설정하는 행위 자체가 "사용자가 model을 명시했다"는 선언이다 — 명시 없이 설정하면 계약 위반 |
| `RUN_DA_CODEX_TIER` | 사용자 명시 service_tier. 미지정 시 unset | 사용자 명시 지정만. 설정 행위 = 명시 선언 (model과 동일) |
| `RUN_DA_USER_EFFORT_OVERRIDE` | 사용자가 effort 값을 명시 지정했음을 표시 (`1`). 기본 profile 밖 effort 값의 통과 관문 | 사용자가 effort를 명시 지정했을 때만 메인 에이전트가 설정. model/tier만 지정된 호출에서 설정하면 계약 위반 — 축별 provenance를 하나의 표식으로 뭉개지 않는다 |

- effort guard: 기본 profile 값(`medium|high|xhigh`)은 즉시 통과한다. 그 외 소문자 영문 값은 `RUN_DA_USER_EFFORT_OVERRIDE=1`(effort 축 전용 관문 — model/tier 지정 여부와 무관)일 때만 통과한다 — 스킬은 값 집합을 예단하지 않고 codex에 위임하며, codex/API가 거부하면 그 에러를 사용자에게 그대로 보고한다 (조용한 대체/하향 금지).
- model/tier 주입: 각 role 명령 안의 `_DA_MODEL_TIER_OVERRIDES` 조립 루프가 unset이 아닌 값만 shell-safe 문자 검증(영숫자 `._-`) 후 `-c model=...` / `-c service_tier=...` config override 인자로 추가한다. effort는 모든 호출의 필수 인자이므로 이 배열이 아니라 고정 `-c model_reasoning_effort=`로 별도 주입한다. 미지정 시 빈 배열이라 기존 기본 계약과 동일하게 동작한다.
- ambient 유입 차단: 위 env들은 role 명령과 같은 단일 셸 호출 안에서 caller가 그 호출을 위해 설정한다 (셸 호출 간 env 비공유 — [`runtime-mapping.md`](runtime-mapping.md) 공통 주의). 이전 호출·세션에서 상속된 ambient 값을 재사용하지 않으며, 명시되지 않은 축의 env는 설정하지 않는다.
- 조립 루프 복제 이유: 세 role command block(reviewer/Auditor 템플릿, Arbiter 템플릿, first-pass Arbiter 실행 절차)은 각각 단일 셸 호출로 self-contained해야 하므로 같은 effort guard·조립 루프를 블록마다 복제한다. 세 사본의 동일성은 sync 테스트(`tests/skill-doc-sync.py`의 exec override copies 검사)가 정규화 비교로 강제한다.
- `--ignore-user-config`와의 관계: user config 차단(MCP surface 차단 목적)은 유지된다. 이 채널은 config 파일이 아니라 사용자 명시 입력값만 `-c`로 재주입한다.

## 실행 계약 (런타임 분기)

### Codex 세션 경로

현재 세션이 native subagent 오케스트레이션(`spawn_agent`, `wait_agent`; lifecycle은 [`runtime-mapping.md`](runtime-mapping.md#codex-native-lifecycle-capability-profile) capability profile로 판별)을 사용할 수 있으면
Arbiter도 이를 기본 경로로 사용한다.

- 매 실행마다 fresh Arbiter subagent는 [run-da canonical contract](hardening-contract.md)의 strong review profile([`runtime-mapping.md`](runtime-mapping.md) review profile 매핑)로 사용한다.
- 프롬프트는 `spawn_agent` 입력에 직접 포함한다. tmp prompt 파일을 요구하지 않는다.
- Arbiter는 review-only/no-write role이다. 파일 수정, scratch PoC, branch mutation, GitHub write, `wt`/`nrs`/rebuild 계열 실행을 하지 않는다.
- 결과 수집: `wait_agent`로 완료를 확인하고 그 subagent가 최종 응답으로 전달한 본문을 수집한다 (`wait_agent` 반환값은 상태 요약이라 VERDICT_JSON이 없다 — [`runtime-mapping.md`](runtime-mapping.md) 결과 수집 행). timeout만으로 실패 처리하거나 중간 kill/self-auditing으로 대체하지 않는다. 수집한 본문은 `/tmp/da-${_DA_SID}-arbiter-*` 네임스페이스의 scratch 파일로 저장한다 — 공통 검증기가 파일 입력 전용이므로 native 경로도 이 저장 단계를 거쳐야 검증을 수행할 수 있다 (메인 에이전트가 쓰는 결과 파일이며, Arbiter의 no-write role과 무관하다). 결과 파싱 후의 slot 회수는 capability profile을 따른다 (legacy profile만 `close_agent` 호출, current profile은 explicit close 없이 광고 slot 내에서만 발사 — [`runtime-mapping.md`](runtime-mapping.md#codex-native-lifecycle-capability-profile) SSOT).

### codex exec 경로 (Claude Code 세션 · headless 세션)

Claude Code에서 Codex CLI를 subprocess로 호출할 때, 비대화형 automation일 때,
또는 사용자가 `codex exec`를 명시적으로 요구할 때는 기존 `codex exec` 계약을 따른다.

- `codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral` (issue #593 Layer 1: setsid + timeout capability-probe wrapper, [`../../using-codex-exec/references/known-issues.md`](../../using-codex-exec/references/known-issues.md) §15 SSOT)
- foreground 실행 (병렬/background 없음 — 단일 exec이므로 결과를 즉시 확인. 런타임별 매커니즘은 [`runtime-mapping.md`](runtime-mapping.md) "런타임 도구 매핑" 표 참조)
- `-o "$ARBITER_DIR/arbiter-result.md"` 결과 파일
- `cat "$ARBITER_DIR/arbiter-prompt.md" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised ... -` stdin pipe로 프롬프트 전달 (pipe EOF가 stdin hang 방지; marker는 codex 프로세스에 적용 — issue #585)
- `2>"$ARBITER_DIR/arbiter-stderr.log"` stderr 분리
- 모델명·service_tier는 스킬이 pin하지 않는다. `RUN_DA_CODEX_EFFORT`를 role별 기본 profile, `agent=` 인자, 또는 사용자 명시 effort에서 결정한 뒤 `-c model_reasoning_effort="$RUN_DA_CODEX_EFFORT"`를 명시하고, 사용자 명시 model/tier가 있으면 `_DA_MODEL_TIER_OVERRIDES`로 추가 주입한다 (위 "사용자 지정 실행 파라미터" 섹션).
- Arbiter는 인자 미지정 시 strong review profile effort를 사용한다. `agent=codex-*`가 지정되면 Arbiter도 reviewer/auditor와 같은 effort override를 적용한다.
- 프롬프트에서 "리뷰만 수행하고 파일을 수정하지 마라" 명시
- `--ephemeral`로 세션 히스토리 오염 방지

`& + wait` shell-level 병렬을 사용하지 않는다 (런타임 공통; Claude Code Bash tool sandbox 제약에서 유래했으나 Codex `exec_command`·headless 셸 모두 동일하게 적용).
`cat file | env CODEX_PROGRAMMATIC=1 codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral ... -` stdin pipe로 프롬프트를 전달한다 (Layer 1, 아래 role별 명령 표 참조). 인라인 인자 `"$(cat file)"`는 사용하지 않는다 (marker는 codex 프로세스 적용 — issue #585).

### Codex delegation-denied fallback (subprocess 실행 계약)

Codex 세션에서 `spawn_agent`가 정책상 거부될 때(예: `multi_agent=false`, `"delegation not permitted"`·`"multi_agent disabled"` 에러) 사용되는 subprocess 실행 계약이다. [`hardening-contract.md`](hardening-contract.md)의 "Delegation fallback" 섹션은 정책 요약(승인 관문, 자동 우회 금지)만 두고, 실제 명령은 이 섹션이 SSOT다.

공통:
- `--sandbox read-only` + `--ignore-user-config` + `--ignore-rules`를 함께 강제한다. `--sandbox read-only`는 model-generated shell command의 파일시스템 쓰기만 막고, user `config.toml`의 MCP server/plugin/connector 로딩은 차단하지 못한다. `--ignore-user-config`는 `$CODEX_HOME/config.toml`의 user MCP/plugin/connector surface를 차단하지만, cwd 기반 project config (`.codex/config.toml`의 `[mcp_servers.*]`)는 차단하지 못한다. 현재 worktree에 project-scoped MCP connector가 있을 때의 project-config 한계는 `run-da/SKILL.md` Non-goals #1이 canonical이다. `--ignore-rules`는 user/project execpolicy `.rules` 파일을 차단해 read-only sandbox로 막을 수 없는 network/system mutation 명령(예: `git push`, `aws ec2 describe`)이 reviewer/auditor에서 실행되지 않게 한다.
- `--ignore-user-config`는 `$CODEX_HOME/config.toml`의 `model_reasoning_effort`도 차단하므로 role별 표의 `RUN_DA_CODEX_EFFORT` guard와 `-c model_reasoning_effort="$RUN_DA_CODEX_EFFORT"` 명시가 필수다. 모델명·service_tier는 스킬이 pin하지 않으며, 사용자 명시 지정이 있을 때만 `_DA_MODEL_TIER_OVERRIDES`로 주입한다 (위 "사용자 지정 실행 파라미터" 섹션).
- `--ephemeral`로 세션 히스토리 오염 방지.
- `exec_command`를 `cat "$DIR/prompt.md" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral ... - 2>stderr.log` 형태로 stdin pipe 전달.
- 각 review unit은 독립 subprocess (fresh 판정 경계는 프로세스 경계로 보존).
- 사용자 승인 후에만 실행 ([`hardening-contract.md`](hardening-contract.md) "Delegation fallback" 섹션 참조).

role별 명령 (각 역할이 사용하는 임시 디렉토리와 파일 이름 규약은 [`../modes/for_plan.md`](../modes/for_plan.md) / [`../modes/for_pr.md`](../modes/for_pr.md) 본문 절차를 따른다). 아래 fenced code block은 caller가 `DA_DIR`/`UNIT`을 현재 flow의 stdout 리터럴 값으로 설정하고, `RUN_DA_CODEX_EFFORT`를 profile resolution 결과로 설정한 뒤(사용자가 model/tier를 명시했으면 `RUN_DA_CODEX_MODEL`/`RUN_DA_CODEX_TIER`를, effort를 명시했으면 `RUN_DA_USER_EFFORT_OVERRIDE=1`을 — 각 축은 명시된 경우에만) guard와 함께 실행한다. 모델명은 literal로 고정하지 않는다. 기본 role effort 매핑은 [`runtime-mapping.md`](runtime-mapping.md)의 review profile 매핑 표가 SSOT다.

| profile | 기본 `RUN_DA_CODEX_EFFORT` |
|---------|----------------------------|
| `standard` | `medium` |
| `strong` | `high` |

`agent=codex-xhigh`, `agent=codex-high`, `agent=codex-medium`이 지정되면 위 기본값 대신 각각 `xhigh`, `high`, `medium`을 reviewer/auditor와 Arbiter 전체에 사용한다. 사용자 명시 effort는 이보다 다시 우선한다 (위 "사용자 지정 실행 파라미터" 섹션).

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
3. `wait_agent`로 완료를 확인하고 subagent 최종 응답 본문을 수집해 scratch 결과 파일로 저장한다 (위 "Codex 세션 경로"의 결과 수집 계약과 동일 — `wait_agent` 반환값에는 결과 본문이 없다). timeout만으로 실패 처리하거나 중간 kill/self-auditing으로 대체하지 않는다.
4. 결과 파싱 후 slot 회수는 capability profile을 따른다 ([`runtime-mapping.md`](runtime-mapping.md#codex-native-lifecycle-capability-profile) SSOT).

### codex exec 경로 (Claude Code 세션 · headless 세션)

이 코드블록 전체를 단일 셸 호출로 실행한다 (런타임 공통 — 셸 호출 간 환경변수 비공유. 호출을 나누면 `$ARBITER_DIR`이 유실됨). literal 재사용 환각 주의 (issue #632): first-pass Arbiter는 단일 foreground exec이므로 `ARBITER_DIR` suffix를 다음 호출에서 literal로 재입력하지 않게 단일 shell 호출을 구조적으로 강제한다. full rule은 [`using-codex-exec/known-issues.md`](../../using-codex-exec/references/known-issues.md#literal-재사용-시-random-suffix-환각-금지-issue-632)를 따른다.

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

# 3. codex exec 실행 (foreground)
# RUN_DA_CODEX_EFFORT는 role별 기본 profile, agent= 인자, 또는 사용자 명시 effort에서 결정한다.
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

`codex exec` 결과를 파일로 받아 후속 처리하는 경우, 위 코드블록 전체(#1~#4)를 단일 셸 호출로 체이닝한다. 위 코드블록이 올바른 패턴이다.

아래는 호출을 분리하면 발생하는 잘못된 패턴이다:

```bash
# 잘못된 패턴 — 변수가 다음 호출에서 유실됨
# [호출 1] ARBITER_DIR=$(mktemp -d /tmp/da-${_DA_SID}-arbiter-XXXXXX)
# [호출 2] codex exec -o "$ARBITER_DIR/result.md" ...
#   ← $ARBITER_DIR이 unset → "/result.md" (루트 경로)로 확장됨
```

## Selective consistency N=3 실행 계약

selective consistency trigger([stability-measurement.md](stability-measurement.md)의 trigger 조건)에 매치된 finding에 대해 N=3 독립 Arbiter를 실행한다. 각 런타임별 실행 규약은 다음과 같다.

프롬프트 축소 규칙: N=3 재판정 프롬프트는 first-pass Arbiter 프롬프트 전체가 아니라, trigger된 finding 목록만 포함한 축소 프롬프트로 조립한다. first-pass 프롬프트를 그대로 N=3번 재실행하면 비용이 "애매한 finding 수"가 아니라 "전체 Arbiter batch 크기"에 비례해 high reasoning으로 3배 증가한다. [arbiter-prompt.md](arbiter-prompt.md)의 for_pr/for_plan 조립 규칙은 selective consistency 모드에서 `## 검증 대상 findings` 섹션에 trigger된 subset만 포함해야 한다. 동일 규칙을 for_plan에도 적용하며, 계획 원문/diff 컨텍스트는 유지하되 finding 목록만 좁힌다.

### Codex 세션 경로 (N=3)

1. 동일 판정 기준 / 템플릿으로 3개의 fresh subagent를 strong review profile로 `spawn_agent` 실행한다. 프롬프트 본문은 위 "프롬프트 축소 규칙"대로 trigger된 finding subset 만 포함해 조립하고, 이전 판정 transcript는 공유하지 않는다 (독립 판정 원칙).
2. N=3 발사가 capability profile의 batch 상한([`runtime-mapping.md`](runtime-mapping.md#codex-native-lifecycle-capability-profile) SSOT)을 넘으면 batch한다. legacy profile에서는 3개 발사 전에 first-pass Arbiter의 completed thread를 `close_agent`로 닫아 슬롯을 확보하고, current profile에서는 광고 slot 내에서 발사 수를 조절한다.
3. `wait_agent`로 3개 모두의 완료를 확인하고 각 subagent가 최종 응답으로 전달한 본문을 수집한다 (`wait_agent` 반환값은 상태 요약뿐 — [`runtime-mapping.md`](runtime-mapping.md) 결과 수집 행). timeout만으로 failure 처리하거나 self-auditing으로 대체하지 않는다(conservative wait). 수신 후 slot 회수는 capability profile을 따른다.
4. 3개 결과 markdown을 각각 파일로 저장(`/tmp/da-${_DA_SID}-arbiter-selective-*/arbiter-{1,2,3}.md`) 후 `fleiss-kappa.py`로 집계한다 (helper 실체 해석은 [`protocol.md`](protocol.md) "검증기 실체 해석"). 호출 계약은 아래 codex exec 경로 4번과 동일하다 — `--expect-findings <trigger된 finding ID 쉼표 목록>`을 반드시 전달한다 (manifest 없는 집계는 세 Arbiter 공통 누락을 잡지 못한다).

### codex exec 경로 (Claude Code 세션 · headless 세션, N=3)

실행 매커니즘은 런타임에 따라 다르다 ([`runtime-mapping.md`](runtime-mapping.md) "런타임 도구 매핑" 표의 fan-out 실행 행 참조):
- Claude Code 세션: 아래 병렬(background) 방식으로 3개 프로세스 동시 실행, 완료 알림 기반 수집.
- headless 세션: serial foreground로 3개 프로세스를 순차 실행한다 (완료 알림/`&+wait` 없음, 각 프로세스 종료 후 다음 프로세스 기동). 결과 파일 경로·환경 격리 방식은 아래와 동일하게 적용하되, 실행 방식만 serial로 바꾼다.

1. 동일 Arbiter 프롬프트 파일을 3번 실행하기 위해 3개의 `codex exec` 프로세스를 기동한다 (Claude Code: background, headless: serial foreground). reviewer fan-out과 달리 Arbiter N=3 자체는 모두 같은 프롬프트다(프롬프트 조향 금지, 독립 판정 원칙).
2. 환경 격리 — first-pass Arbiter와 selective consistency N=3 모두 같은 resolved effort를 사용한다. 인자 미지정 시 strong review profile 기본 effort는 `high`이며, `agent=codex-*`가 지정되면 그 effort가 N=3에도 그대로 적용된다. 사용자 지정 실행 파라미터(model/effort/tier)도 first-pass와 동일하게 N=3에 그대로 적용된다. selective consistency N=3은 외부 표면과 충돌을 줄이기 위해 다음 두 방식 중 하나를 선택한다:

   (a) 기본 경로 + config 차단 (권장, 간단):
   - `CODEX_HOME`을 그대로 두어 기본 auth chain(`auth.json` 등)을 유지한다.
   - codex exec 호출에 `--ignore-user-config`를 추가하여 사용자 `config.toml`(MCP 서버 포함) 로딩을 차단한다. [`using-codex-exec/SKILL.md`](../../using-codex-exec/SKILL.md)의 `--ignore-user-config` 옵션 설명처럼 이 플래그는 config만 차단하고 auth는 유지한다.
   - 주의: `--ignore-user-config`는 `$CODEX_HOME/config.toml`의 `model_reasoning_effort` 등 user config 설정을 함께 제거한다. Arbiter는 resolved effort를 유지해야 하므로 `-c model_reasoning_effort="$RUN_DA_CODEX_EFFORT"`를 명시적으로 재지정한다. 모델명·service_tier는 스킬이 pin하지 않으며, 사용자 명시 지정이 있을 때만 `_DA_MODEL_TIER_OVERRIDES`로 주입한다.
   - 부작용: `~/.codex/sessions` 기반 세션이 생성되므로 동시 N=3 실행 시 세션 파일 경합이 발생할 수 있다. `--ephemeral`로 session 저장 자체를 회피한다.

   (b) scratch CODEX_HOME + auth 복사 (세션 충돌 완전 분리가 필요할 때):
   - `CODEX_HOME=$(mktemp -d /tmp/codex-home-${_DA_SID}-selective-XXXXXX)`로 사용자 홈과 격리된 scratch 설정 디렉토리 생성.
   - auth 자격을 함께 전달한다. 세 가지 방식 중 하나:
     - 환경변수 `CODEX_API_KEY`가 이미 설정되어 있으면 그것이 사용됨 (auth chain 우선순위 `CODEX_API_KEY > ephemeral tokens > auth.json`, [`using-codex-exec/references/known-issues.md`](../../using-codex-exec/references/known-issues.md#17-exec-auth-chain-우선순위와-login-status-한계) 참조). 이 경우 추가 조치 불필요.
     - 그렇지 않으면 `cp ~/.codex/auth.json "$CODEX_HOME/"`로 기존 auth.json을 scratch로 복사.
     - 둘 다 불가능하면 scratch CODEX_HOME에서 `codex login status`가 `Not logged in`으로 실패하므로 방식 (a)로 돌아간다.
   - 최소 `$CODEX_HOME/config.toml`을 작성하되 `[mcp_servers.<name>]` 테이블(실제 Codex TOML 스키마는 [`sync-codex-config.py`](../../../../../codex/files/sync-codex-config.py)의 user-owned `mcp_servers` 보존 정책과 [`scenario-D-mcp-servers-coexist.toml`](../../../../../../../../tests/fixtures/codex-hooks/sync-preservation/scenario-D-mcp-servers-coexist.toml) fixture로 확인)을 포함하지 않는다. 또는 TOML 파서로 기존 config를 복사한 뒤 `mcp_servers` 테이블 전체를 삭제한다. (참고: `[[mcp_servers]]` array-of-table 문법은 현재 Codex가 사용하지 않으므로 혼동 방지를 위해 `[mcp_servers.*]` 정확 표기를 사용한다.)
   - effort 옵션은 필수로 명시적으로 지정한다: `-c model_reasoning_effort="$RUN_DA_CODEX_EFFORT"`. scratch `CODEX_HOME`이므로 user config default가 적용되지 않아 호출 시점 기본값 의존이 불가하다. 모델명·service_tier는 스킬이 pin하지 않으며, 사용자 명시 지정이 있을 때만 `_DA_MODEL_TIER_OVERRIDES`로 주입한다.
3. Claude Code 세션: `run_in_background: true`로 3개를 병렬 발사 후 완료 알림을 기다린다 (sleep/poll 금지). headless 세션: 3개 프로세스를 serial foreground로 순차 실행한다 (각 종료 확인 후 다음). 결과 파일 경로는 두 경로 모두 `/tmp/da-${_DA_SID}-arbiter-selective-<round>/arbiter-{1,2,3}-result.md`로 라운드별 분리.
4. 수집 후 `fleiss-kappa.py`([`protocol.md`](protocol.md) "검증기 실체 해석"의 순서로 해석)에 `--expect-findings <trigger된 finding ID 쉼표 목록>`과 `arbiter-1-result.md arbiter-2-result.md arbiter-3-result.md`를 인자로 전달하여 vote-shape를 얻는다 (manifest 대조로 세 Arbiter 공통 누락·미지 ID를 partial_failure로 잡는다). `--offline` 플래그는 배포 후 kappa 관찰 목적일 때만 부가한다.

## 실패 처리

단일 호출 패턴에서의 실패 감지: 위 코드블록은 `exit 1`로 종료하여 셸 호출이 비정상 종료로 보고된다. stdout에 `ARBITER_FAILED:` 접두어가 출력되며, `dir=` 필드에 임시 디렉토리 경로, 이어서 stderr 로그 내용이 포함된다. 메인 에이전트는 셸 호출의 exit code 또는 stdout의 `ARBITER_FAILED:` 접두어로 실패를 감지한다.

### Semantic malformed (VERDICT_JSON 계약 위반) — 모든 런타임 공통 전이

VERDICT_JSON caller 검증 위반(검증 규칙·fail-closed 전이의 SSOT: [`protocol.md`](protocol.md)의 "수렴 판정" caller 검증 — 실시간 수집 경로 schema_version 정확히 1.1 강제 포함)은 아래 generic 실패 처리·recoverable violation·질문 도구 미지원 자동 전이보다 우선하는 별도 분류다. 전이 내용(1회 재실행 → 재위반 시 BLOCKED, 모든 자동 승격 경로 진입 금지)은 protocol.md가 정본이며 여기 재서술하지 않는다.

### Single Arbiter 실패 (first-pass 또는 예외적 확장 단일 Arbiter)

codex exec 실패 시 (exit code != 0, 빈 결과 파일):

1. 해당 Arbiter 실행의 모든 findings를 NEEDS_MORE_INFO로 일괄 승격한다 (fail-closed).
2. 사용자에게 질문 도구로 보고한다 (맥락 설명 의무 적용).
3. 재시도하지 않는다 (사용자가 판단).

### Selective consistency N=3 partial failure

N=3 중 1개 이상이 실패하면 (결과 파일 없음/빈 파일/exit code != 0/malformed VERDICT_JSON):

1. surviving single-arbiter 결과로 fallback하지 않는다. 부분 표본은 vote-shape 집계에 충분하지 않다.
2. `fleiss-kappa.py` 출력에서 top-level `partial_failure: true`로 표기된다. 세부 원인별 caller 매핑은 [`protocol.md`](protocol.md)의 상태 전이 표 아래 정의가 정본이며 여기 재서술하지 않는다 — 요지는 원인마다 차단 단위가 다르다는 것이다: `missing`은 그 finding만 `per_finding`에서 빠지고, 파일 단위 위반(`manifest_violations`·`file_level_failures`·`per_file_malformed`)은 정상 파싱된 finding이 `per_finding`에 남아 있어도 그 수집 단위 전체를 소비하지 않는다.
3. 차단 대상은 BLOCKED 상태로 기록한다 (2번의 단위를 그대로 따른다).
4. 질문 도구 지원 런타임: 사용자에게 판단 요청 (수용 / 기각 / 이번 round 제외 / 실행 환경 확인 후 rerun).
5. 질문 도구 미지원 런타임: 자동 승격 금지. 명시적 rerun 전에는 재개하지 않는다.

## Codex 세션 violation 처리

Codex 세션 경로에서는 Arbiter가 새 verdict를 반환하는 것이 아니라, 메인 에이전트가 contract breach 또는 malformed output을 감지했을 때 아래 규칙으로 분류한다.

- `recoverable violation`: 출력 형식 위반, prompt contract 미준수처럼 상태를 바꾸지 않은 위반. 결과를 폐기하고 fresh subagent로 1회 재실행한다. 단 VERDICT_JSON caller 검증 위반은 위 "Semantic malformed" 분류가 우선한다 (전이는 [`protocol.md`](protocol.md) caller 검증이 정본).
- `stateful violation`: tracked write, branch mutation, commit/push, GitHub write, main-agent-only command 실행, host mutation처럼 상태를 바꾼 위반. 라운드 중단·offending thread 중단·회수·정리의 공통 계약은 [`hardening-contract.md`](hardening-contract.md)의 VIOLATION 처리가 정본이며 여기에 재정의하지 않는다 (cancellation·slot 회수 도구 binding은 [`runtime-mapping.md`](runtime-mapping.md#codex-native-lifecycle-capability-profile)).
- stateful violation은 이번 라운드에서 offending unit이 만든 scratch 산출물과 임시 ref/branch만 정리 대상으로 삼는다. 기존 local tracked/untracked 변경은 자동 정리하지 않는다.
- 비가역적 외부 side effect가 있었거나 cleanup 범위를 특정할 수 없으면 질문 도구 가능 시 사용자에게 보고하고, 질문 도구 미지원 런타임에서는 자동 `CLEAR` 처리하지 않고 `BLOCKED`로 남긴다. 명시적 rerun 전에는 재개하지 않는다.

## 런타임 선택 규칙

- Codex 세션 경로는 현재 세션이 capability profile 판별([`runtime-mapping.md`](runtime-mapping.md#codex-native-lifecycle-capability-profile))에서 current 또는 legacy로 판정되어 native orchestration이 가능할 때 기본 경로다. unknown이면 같은 SSOT의 fail-safe(serial 동시 1) 또는 codex exec fallback 규칙을 따른다.
- codex exec 경로는 Claude Code 세션(codex exec 기본 → Agent tool fallback)과 headless 세션(CI, `claude -p`)에서 기본 경로다.
- `CODEX_CI=1`은 Codex 세션에서도 보일 수 있으므로 sole discriminator로 쓰지 않는다.

## 질문 도구 미지원 대응

(legacy alias: `AskUserQuestion 미지원 대응`. 본 섹션은 질문 도구가 호출 불가능한 런타임에서의 자동 승격/종료 정책을 기술한다.)

현재 런타임에서 질문 도구(Claude Code의 `AskUserQuestion` 도구, Codex의 `request_user_input` 등)를 호출할 수 없는 경우 (대표 사례: headless 세션 — `claude -p`, `codex exec` subprocess, CI — stdin 입력 불가) 다음 규칙을 적용한다.

`request_user_input`은 codex 0.106+에서 default mode 활성화 가능 (`default_mode_request_user_input=true`). 본 nixos-config는 이를 충족하므로 Codex 세션은 지원 런타임으로 간주한다 — Codex 세션 자체는 본 섹션 자동 전이 적용 대상이 아니다.

### First-pass single Arbiter 경로 (기존)

- NEEDS_MORE_INFO 항목은 CONFIRMED_ISSUE로 자동 승격한다 (텍스트 보고만으로는 상태 전이가 불가능하므로). 단 semantic malformed는 이 자동 승격 대상이 아니다 — 위 "Semantic malformed" 분류를 따른다 (전이는 [`protocol.md`](protocol.md) caller 검증이 정본).
- CONFIRMED_ISSUE는 동일하게 자동 수정한다.
- SKIP 판정 시 질문 도구 불가 → 자동 LITE 승격 (메인 LLM 인라인 체크리스트의 SKIP 결과도 동일하게 적용).
- 3회 반복 규칙 도달 시 질문 도구 불가 → 자동 수용 (지적대로 수정).
- 5회 라운드 초과 시 질문 도구 불가 → 자동 종료(현재 상태 보고).
- 라운드 한계효용 확인 또는 추세 기반 조기 중단([`protocol.md`](protocol.md)의 "최대 라운드 수" 정의) 도달 시 질문 도구 불가 → 현재 상태를 보고하고 종료한다. 한계효용 저하나 추세 비수렴은 추가 자동 수정을 시도할 근거가 아니므로([`protocol.md`](protocol.md)의 changeset 동결/범위 축소 권고를 따른다), 현재 미해결 상태를 보고한 뒤 종료한다 — CLEAR로 간주하지 않는다.

### Selective consistency 경로 (N=3 재판정 결과)

selective consistency에서 나온 stability_status는 first-pass 자동 승격 규칙을 따르지 않는다. N=3이 유효했다는 것은 first-pass가 이미 애매했다는 의미이므로 더 보수적으로 처리한다.

- `stability_status=stable` (3:0): first-pass 자동 승격 규칙을 그대로 적용한다 (CONFIRMED → 수정, NOT_AN_ISSUE → 무해, NEEDS_MORE_INFO → 자동 CONFIRMED_ISSUE 승격 가능).
- `stability_status=split` (2:1): 자동 승격 금지. 명시적 rerun 또는 환경 업그레이드 전까지 `BLOCKED`로 기록하고 DA 루프를 해당 finding에 대해 중단. 로그에 vote-shape와 minority verdict를 남긴다.
- `stability_status=fragmented` (1:1:1): 자동 승격 금지. 동일하게 `BLOCKED`. rubric 재검토 신호로 라운드 요약에 명시.
- partial failure: 자동 승격 금지, `BLOCKED`.

## Review Intensity 판단 실행 계약 (메인 LLM 인라인 체크리스트)

DA 에이전트/Arbiter와 달리, Review Intensity는 별도 subprocess/subagent를 띄우지 않는다. 메인 LLM이 [`intensity-rules.md`](intensity-rules.md)의 룰 표를 인라인 체크리스트로 기계적 적용(모든 룰 평가 + first-match 채택)하고, 그 결과 표를 plan/대화에 남긴다.

| 항목 | DA/Arbiter | Review Intensity |
|------|-----------|-----------------|
| 실행 주체 | 독립 subagent / codex exec subprocess | 메인 LLM 인라인 |
| 입력 | diff 전체 또는 계획 전체 | `git diff --stat` 또는 계획 파일 목록 |
| 출력 | findings/verdicts (markdown + VERDICT_JSON) | 체크리스트 표 + SKIP/LITE/FULL 판정 + 근거 |
| 참조 | da-domains.md, arbiter-prompt.md | intensity-rules.md |
| 실패 시 | NEEDS_MORE_INFO 승격 | FULL 강제 (체크리스트 미작성, fail-closed rule group 매치/불확실 포함) |

- 절차 SSOT는 [`intensity-procedure.md`](intensity-procedure.md)의 "인라인 체크리스트 절차".
- 메인 LLM은 자유 추론 금지. 모든 룰을 평가한 표(매치/미매치/불확실 + 근거)를 plan/대화에 남기지 않으면 SKIP/LITE 판정 자체가 무효이며 강한 검토로 fail-closed.
- 질문 도구(SKIP 시)는 메인 LLM이 호출한다. 질문 도구 미지원 시 SKIP 처리는 위 "질문 도구 미지원 대응" 섹션의 규칙(자동 LITE 승격)을 따른다.
- 회귀 검증: 수동 replay 가이드 — 절차 SSOT는 [`intensity-procedure.md`](intensity-procedure.md)의 "회귀 검증 (Intensity fixture replay)" 섹션. fixture 정의는 [`../evals/intensity-fixtures.json`](../evals/intensity-fixtures.json) (자동 eval runner 연결은 follow-up 범위).

## 향후 확장

위 예외 조건이 실제로 반복 검증되면 교차 검증(Arbiter 2개+)이나 Known-Answer Calibration 도입을 검토한다.
그 전까지는 single strong arbiter가 기본 계약이다.
