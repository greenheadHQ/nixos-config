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

## Selective consistency (vote-shape 기반 first-pass trigger)

위 "예외적 확장 조건"이 정성적/사후적 근거 기반 확장이라면, **selective consistency는 first-pass Arbiter 결과에서 애매성이 감지되자마자 구조화된 방식으로 N=3 재판정을 발동**하는 경로다. 이 경로와 예외적 확장은 상호 보완이며, 대부분의 실무 케이스는 selective consistency가 처리한다.

정책 정의(트리거 조건, vote-shape, threshold 상수)는 [`stability-measurement.md`](stability-measurement.md)가 단일 진실 원천이다. 이 문서는 실행 계약만 다루며 정책 원자를 재서술하지 않는다.

- 실행 단위: N=3 독립 Arbiter (fresh subagent 또는 fresh `codex exec` 프로세스).
- 집계: 세션 scope에 맞는 `fleiss-kappa.py` helper(Claude: `~/.claude/scripts/fleiss-kappa.py`, Codex: `~/.codex/scripts/fleiss-kappa.py` — 양쪽에 동일 소스가 프로비저닝된다)로 VERDICT_JSON 블록을 파싱.
- 상태 전이는 [`protocol.md`](protocol.md)의 "Selective consistency 상태 전이" 섹션.
- N=3 실행 세부는 아래 "Selective consistency N=3 실행 계약" 섹션.

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
- **foreground 실행** (병렬/background 없음 — 단일 exec이므로 결과를 즉시 확인. 런타임별 매커니즘은 SKILL.md "런타임 도구 매핑" 표 참조)
- `-o "$ARBITER_DIR/arbiter-result.md"` 결과 파일
- `cat "$ARBITER_DIR/arbiter-prompt.md" | env CODEX_PROGRAMMATIC=1 codex exec ... -` stdin pipe로 프롬프트 전달 (pipe EOF가 stdin hang 방지; marker는 codex 프로세스에 적용 — issue #585)
- `2>"$ARBITER_DIR/arbiter-stderr.log"` stderr 분리
- `-m` 플래그 생략 (config.toml 기본 모델)
- Arbiter는 strong review profile(high)을 사용한다. config.toml 기본 `model_reasoning_effort`(xhigh)와 다르므로 `-c model_reasoning_effort="high"`를 명시적으로 지정한다.
- 프롬프트에서 "리뷰만 수행하고 파일을 수정하지 마라" 명시
- `--ephemeral`로 세션 히스토리 오염 방지

`& + wait` shell-level 병렬을 사용하지 않는다 (런타임 공통; Claude Code Bash tool sandbox 제약에서 유래했으나 Codex `exec_command`·headless 셸 모두 동일하게 적용).
`cat file | env CODEX_PROGRAMMATIC=1 codex exec ... -` stdin pipe로 프롬프트를 전달한다. 인라인 인자 `"$(cat file)"`는 사용하지 않는다 (marker는 codex 프로세스 적용 — issue #585).

### Codex delegation-denied fallback (subprocess 실행 계약)

Codex 세션에서 `spawn_agent`가 정책상 거부될 때(예: `multi_agent=false`, `"delegation not permitted"`·`"multi_agent disabled"` 에러) 사용되는 subprocess 실행 계약이다. SKILL.md의 "Delegation fallback" 섹션은 정책 요약(승인 관문, 자동 우회 금지)만 두고, 실제 명령은 이 섹션이 SSOT다.

**공통**:
- `--sandbox read-only` + `--ignore-user-config`를 함께 강제한다. `--sandbox read-only`는 model-generated shell command의 파일시스템 쓰기만 막고, user `config.toml`의 MCP server/plugin/connector 로딩은 차단하지 못한다. `--ignore-user-config`로 MCP 등 외부 연결 surface를 함께 차단해야 reviewer/Arbiter/Intensity/Auditor의 no-write 경계가 실효성 있게 보장된다 (N=3 경로와 동일한 방식).
- `--ignore-user-config`는 `$CODEX_HOME/config.toml`의 `model`/`model_reasoning_effort`도 차단하므로 role별 표의 `-c model="gpt-5.5"`·`-c model_reasoning_effort="..."` 명시가 필수다 (defensive explicit pin).
- `--ephemeral`로 세션 히스토리 오염 방지.
- `exec_command`를 `cat "$DIR/prompt.md" | env CODEX_PROGRAMMATIC=1 codex exec --sandbox read-only --ignore-user-config --ephemeral ... - 2>stderr.log` 형태로 stdin pipe 전달.
- 각 review unit은 독립 subprocess (fresh 판정 경계는 프로세스 경계로 보존).
- 사용자 승인 후에만 실행 (SKILL.md "Delegation fallback" 섹션 참조).

**role별 명령** (각 역할이 사용하는 임시 디렉토리와 파일 이름 규약은 SKILL.md 본문 절차를 따른다). 아래 fenced code block은 바로 복사해 실행할 수 있도록 standard/strong profile의 model/effort 값을 **literal**로 고정한다. profile 이름·의미의 SSOT는 SKILL.md 상단 "런타임 도구 매핑"의 **review profile 매핑** 불릿이며, 값이 바뀌면 아래 literal도 함께 갱신해야 한다 (문서-코드 manual sync contract — selective consistency harness와 동일한 패턴). **현재 effort 매핑**: `medium` = standard profile (reviewer/Intensity/auditor), `high` = strong profile (Arbiter), `xhigh` = `config.toml` `model_reasoning_effort` 기본값 (보존; Arbiter 호출 경로에서만 `-c`로 `high`로 다운그레이드).

**reviewer / Auditor** (standard profile):

```bash
# marker must apply to `codex`, not `cat` (issue #585): Codex 0.124+ user-level hooks의 early-exit 신호.
cat "$DA_DIR/{unit}.md" | env CODEX_PROGRAMMATIC=1 codex exec --sandbox read-only --ignore-user-config --ephemeral \
  -c model="gpt-5.5" -c model_reasoning_effort="medium" \
  -o "$DA_DIR/{unit}-result.md" - 2>"$DA_DIR/{unit}-stderr.log"
```

**Intensity** (standard profile):

```bash
cat "$INTENSITY_DIR/prompt.md" | env CODEX_PROGRAMMATIC=1 codex exec --sandbox read-only --ignore-user-config --ephemeral \
  -c model="gpt-5.5" -c model_reasoning_effort="medium" \
  -o "$INTENSITY_DIR/result.md" - 2>"$INTENSITY_DIR/stderr.log"
```

**Arbiter** (strong profile):

```bash
cat "$ARBITER_DIR/arbiter-prompt.md" | env CODEX_PROGRAMMATIC=1 codex exec --sandbox read-only --ignore-user-config --ephemeral \
  -c model="gpt-5.5" -c model_reasoning_effort="high" \
  -o "$ARBITER_DIR/arbiter-result.md" - 2>"$ARBITER_DIR/arbiter-stderr.log"
```

`-o` 플래그(`--output-last-message <FILE>`)가 마지막 메시지를 결과 파일로 저장한다 (이것이 없으면 파일 수집 계약이 깨진다). stderr도 별도 로그 파일로 분리해 실패 진단을 보존한다.

**실행 방식**: serial (multiple review units를 순차 실행). 병렬 발사는 `spawn_agent`가 거부된 상황이므로 shell-level `&+wait` 대신 각 subprocess를 직렬로 기동한다. 결과 파일은 `$DA_DIR/{unit}-result.md`에 수집 후 메인 에이전트가 파싱한다.

**Degraded mode 계약** (fallback 경로 한정): `--sandbox read-only` 강제로 인해 reviewer는 SKILL.md "역할별 경계" 표의 `out-of-repo private scratch PoC (mktemp -d, umask 077)`를 **이 경로에서는 수행할 수 없다**. fallback reviewer는 **파일 증거·문서 인용·diff 확인만**으로 finding을 생성하고, scratch PoC가 필요한 지적은 "PoC 불가 — 문서/파일 증거 기반 추정"임을 명시한 뒤 심각도를 보수적으로 보고한다. 이 제약은 fallback이 `spawn_agent` 원본 경로의 **수용 가능한 근사**임을 인정하는 것이며, 구조적 write 차단이 우선이다.

**실패 처리**: 이 경로에서도 exit code ≠ 0, 빈 결과 파일, stdin hang은 위 "codex exec 경로" 섹션의 실패 감지 규칙을 따른다. `codex` binary 부재나 반복 실패 시 BLOCKED 처리.

## 실행 절차

### Codex 세션 경로

1. Arbiter용 fresh subagent는 strong review profile로, Intensity용은 standard review profile로 띄운다.
2. 프롬프트에는 관련 reference 문서를 직접 읽고, review-only/no-write contract를 따르며, 파일을 수정하지 말라고 명시한다.
3. `wait_agent`로 결과를 받는다. timeout만으로 실패 처리하거나 중간 kill/self-auditing으로 대체하지 않는다.
4. 결과 파싱 후 completed thread를 `close_agent`로 닫는다.

### codex exec 경로 (Claude Code 세션 · headless 세션)

**이 코드블록 전체를 단일 셸 호출로 실행한다** (런타임 공통 — 셸 호출 간 환경변수 비공유. 호출을 나누면 `$ARBITER_DIR`이 유실됨).

```bash
# 1. Arbiter 임시 디렉토리 생성
ARBITER_DIR=$(mktemp -d /tmp/da-${_DA_SID}-arbiter-XXXXXX)

# 2. Arbiter 프롬프트 파일 조립 (arbiter-prompt.md의 조립 규칙 참조)
cat > "$ARBITER_DIR/arbiter-prompt.md" <<'PROMPT'
{조립된 Arbiter 프롬프트 — 비신뢰 텍스트(계획 원문, DA 결과) 포함 시 반드시 quoted heredoc 사용}
PROMPT

# 3. codex exec 실행 (foreground)
# Arbiter는 strong review profile(high) — config.toml 기본값(xhigh)을 오버라이드. model은 -m 생략하여 config.toml 기본값 사용.
# marker must apply to `codex`, not `cat` (issue #585): Codex 0.124+ user-level hooks의 early-exit 신호.
cat "$ARBITER_DIR/arbiter-prompt.md" | env CODEX_PROGRAMMATIC=1 codex exec --full-auto --ephemeral \
  -c model_reasoning_effort="high" \
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

`codex exec` 결과를 파일로 받아 후속 처리하는 경우, **위 코드블록 전체(#1~#4)**를 단일 셸 호출로 체이닝한다. 위 코드블록이 올바른 패턴이다.

아래는 호출을 분리하면 발생하는 잘못된 패턴이다:

```bash
# 잘못된 패턴 — 변수가 다음 호출에서 유실됨
# [호출 1] ARBITER_DIR=$(mktemp -d /tmp/da-${_DA_SID}-arbiter-XXXXXX)
# [호출 2] codex exec -o "$ARBITER_DIR/result.md" ...
#   ← $ARBITER_DIR이 unset → "/result.md" (루트 경로)로 확장됨
```

## Selective consistency N=3 실행 계약

selective consistency trigger([stability-measurement.md](stability-measurement.md)의 trigger 조건)에 매치된 finding에 대해 N=3 독립 Arbiter를 실행한다. 각 런타임별 실행 규약은 다음과 같다.

**프롬프트 축소 규칙**: N=3 재판정 프롬프트는 first-pass Arbiter 프롬프트 전체가 아니라, **trigger된 finding 목록만 포함한 축소 프롬프트**로 조립한다. first-pass 프롬프트를 그대로 N=3번 재실행하면 비용이 "애매한 finding 수"가 아니라 "전체 Arbiter batch 크기"에 비례해 high reasoning으로 3배 증가한다. [arbiter-prompt.md](arbiter-prompt.md)의 for_pr/for_plan 조립 규칙은 selective consistency 모드에서 `## 검증 대상 findings` 섹션에 trigger된 subset만 포함해야 한다. 동일 규칙을 for_plan에도 적용하며, 계획 원문/diff 컨텍스트는 유지하되 finding 목록만 좁힌다.

### Codex 세션 경로 (N=3)

1. 동일 Arbiter 프롬프트로 **3개의 fresh subagent**를 strong review profile로 `spawn_agent` 실행한다. 프롬프트는 first-pass와 동일하다(독립 판정 원칙; 이전 판정 transcript 공유 금지).
2. 현재 session의 open-thread slot이 `agents.max_threads`(unset 기본 6)을 넘으면 batch한다. 3개 발사 전에 first-pass Arbiter의 completed thread를 `close_agent`로 닫아 슬롯을 확보한다.
3. `wait_agent`로 3개 결과를 모두 수신한 뒤 `close_agent`로 닫는다. timeout만으로 failure 처리하거나 self-auditing으로 대체하지 않는다(conservative wait).
4. 3개 결과 markdown을 각각 파일로 저장(`/tmp/da-${_DA_SID}-arbiter-selective-*/arbiter-{1,2,3}.md`) 후 세션 scope의 `fleiss-kappa.py`(Claude: `~/.claude/scripts/`, Codex: `~/.codex/scripts/`)로 집계한다.

### codex exec 경로 (Claude Code 세션 · headless 세션, N=3)

**실행 매커니즘은 런타임에 따라 다르다** (SKILL.md "런타임 도구 매핑" 표의 fan-out 실행 행 참조):
- **Claude Code 세션**: 아래 병렬(background) 방식으로 3개 프로세스 동시 실행, 완료 알림 기반 수집.
- **headless 세션**: **serial foreground**로 3개 프로세스를 순차 실행한다 (완료 알림/`&+wait` 없음, 각 프로세스 종료 후 다음 프로세스 기동). 결과 파일 경로·환경 격리 방식은 아래와 동일하게 적용하되, 실행 방식만 serial로 바꾼다.

1. 동일 Arbiter 프롬프트 파일을 3번 실행하기 위해 **3개의 `codex exec` 프로세스**를 기동한다 (Claude Code: background, headless: serial foreground). reviewer fan-out과 달리 Arbiter N=3 자체는 **모두 같은 프롬프트**다(프롬프트 조향 금지, 독립 판정 원칙).
2. **환경 격리** — first-pass Arbiter와 selective consistency N=3 모두 strong review profile(high)을 사용한다. `~/.codex/config.toml` 기본값(xhigh)과 다르므로 **반드시 `-c model_reasoning_effort="high"`를 명시한다**. **selective consistency N=3**은 외부 표면과 충돌을 줄이기 위해 다음 두 방식 중 하나를 선택한다:

   **(a) 기본 경로 + config 차단** (권장, 간단):
   - `CODEX_HOME`을 그대로 두어 기본 auth chain(`auth.json` 등)을 유지한다.
   - codex exec 호출에 `--ignore-user-config`를 추가하여 사용자 `config.toml`(MCP 서버 포함) 로딩을 차단한다. `using-codex-exec/SKILL.md:113`에 기록된 대로 이 플래그는 **config만 차단하고 auth는 유지**한다.
   - **주의**: `--ignore-user-config`는 `$CODEX_HOME/config.toml`의 `model` / `model_reasoning_effort` 등 user config 설정을 함께 제거한다. Arbiter는 strong review profile(high)을 유지해야 하므로 `-c model="gpt-5.5"`와 `-c model_reasoning_effort="high"`를 **명시적으로 재지정**한다 (defensive explicit pin — config.toml default가 차단되므로).
   - 부작용: `~/.codex/sessions` 기반 세션이 생성되므로 동시 N=3 실행 시 세션 파일 경합이 발생할 수 있다. `--ephemeral`로 session 저장 자체를 회피한다.

   **(b) scratch CODEX_HOME + auth 복사** (세션 충돌 완전 분리가 필요할 때):
   - `CODEX_HOME=$(mktemp -d /tmp/codex-home-${_DA_SID}-selective-XXXXXX)`로 사용자 홈과 격리된 scratch 설정 디렉토리 생성.
   - **auth 자격을 함께 전달한다**. 세 가지 방식 중 하나:
     - 환경변수 `CODEX_API_KEY`가 이미 설정되어 있으면 그것이 사용됨 (auth chain 우선순위 `CODEX_API_KEY > ephemeral tokens > auth.json`, `using-codex-exec/SKILL.md:214` 참조). 이 경우 추가 조치 불필요.
     - 그렇지 않으면 `cp ~/.codex/auth.json "$CODEX_HOME/"`로 기존 auth.json을 scratch로 복사.
     - 둘 다 불가능하면 scratch CODEX_HOME에서 `codex login status`가 `Not logged in`으로 실패하므로 방식 (a)로 돌아간다.
   - 최소 `$CODEX_HOME/config.toml`을 작성하되 `[mcp_servers.<name>]` 테이블(실제 Codex TOML 스키마, `modules/shared/programs/codex/files/config.darwin.toml:34` 참조)을 **포함하지 않는다**. 또는 TOML 파서로 기존 config를 복사한 뒤 `mcp_servers` 테이블 전체를 삭제한다. (참고: `[[mcp_servers]]` array-of-table 문법은 현재 Codex가 사용하지 않으므로 혼동 방지를 위해 `[mcp_servers.*]` 정확 표기를 사용한다.)
   - 모델/효과 옵션은 **필수로** 명시적으로 지정한다: `-c model="gpt-5.5"`와 `-c model_reasoning_effort="high"`. scratch `CODEX_HOME`이므로 user config default가 적용되지 않아 호출 시점 기본값 의존이 불가하다.
3. **Claude Code 세션**: `run_in_background: true`로 3개를 병렬 발사 후 완료 알림을 기다린다 (sleep/poll 금지). **headless 세션**: 3개 프로세스를 serial foreground로 순차 실행한다 (각 종료 확인 후 다음). 결과 파일 경로는 두 경로 모두 `/tmp/da-${_DA_SID}-arbiter-selective-<round>/arbiter-{1,2,3}-result.md`로 라운드별 분리.
4. 수집 후 세션 scope의 `fleiss-kappa.py`(Claude: `~/.claude/scripts/fleiss-kappa.py`, Codex: `~/.codex/scripts/fleiss-kappa.py`)에 `arbiter-1-result.md arbiter-2-result.md arbiter-3-result.md`를 인자로 전달하여 vote-shape를 얻는다. `--offline` 플래그는 배포 후 kappa 관찰 목적일 때만 부가한다.

## 실패 처리

**단일 호출 패턴에서의 실패 감지**: 위 코드블록은 `exit 1`로 종료하여 셸 호출이 비정상 종료로 보고된다. stdout에 `ARBITER_FAILED:` 접두어가 출력되며, `dir=` 필드에 임시 디렉토리 경로, 이어서 stderr 로그 내용이 포함된다. 메인 에이전트는 셸 호출의 exit code 또는 stdout의 `ARBITER_FAILED:` 접두어로 실패를 감지한다.

### Single Arbiter 실패 (first-pass 또는 예외적 확장 단일 Arbiter)

codex exec 실패 시 (exit code != 0, 빈 결과 파일):

1. 해당 Arbiter 실행의 모든 findings를 NEEDS_MORE_INFO로 일괄 승격한다 (fail-closed).
2. 사용자에게 질문 도구로 보고한다 (맥락 설명 의무 적용).
3. 재시도하지 않는다 (사용자가 판단).

### Selective consistency N=3 partial failure

N=3 중 **1개 이상이 실패**하면 (결과 파일 없음/빈 파일/exit code != 0/malformed VERDICT_JSON):

1. surviving single-arbiter 결과로 **fallback하지 않는다**. 부분 표본은 vote-shape 집계에 충분하지 않다.
2. `fleiss-kappa.py` 출력에서 `partial_failure: true`로 표기되며, 해당 finding은 `per_finding`에서 제외된다.
3. partial failure 대상 finding은 **BLOCKED** 상태로 기록한다 (protocol.md 상태 전이 표 참조).
4. 질문 도구 지원 런타임: 사용자에게 판단 요청 (수용 / 기각 / 이번 round 제외 / 실행 환경 확인 후 rerun).
5. 질문 도구 미지원 런타임: 자동 승격 금지. 명시적 rerun 전에는 재개하지 않는다.

## Codex 세션 violation 처리

Codex 세션 경로에서는 Arbiter/Intensity가 새 verdict를 반환하는 것이 아니라, 메인 에이전트가 contract breach 또는 malformed output을 감지했을 때 아래 규칙으로 분류한다.

- `recoverable violation`: 출력 형식 위반, prompt contract 미준수처럼 상태를 바꾸지 않은 위반. 결과를 폐기하고 fresh subagent로 1회 재실행한다.
- `stateful violation`: tracked write, branch mutation, commit/push, GitHub write, main-agent-only command 실행, host mutation처럼 상태를 바꾼 위반. 현재 라운드를 즉시 중단하고 offending thread를 닫는다.
- stateful violation은 이번 라운드에서 offending unit이 만든 scratch 산출물과 임시 ref/branch만 정리 대상으로 삼는다. 기존 local tracked/untracked 변경은 자동 정리하지 않는다.
- 비가역적 외부 side effect가 있었거나 cleanup 범위를 특정할 수 없으면 질문 도구 가능 시 사용자에게 보고하고, 질문 도구 미지원 런타임에서는 자동 `CLEAR` 처리하지 않고 `BLOCKED`로 남긴다. 명시적 rerun 전에는 재개하지 않는다.

## 런타임 선택 규칙

- **Codex 세션 경로**는 현재 세션이 Codex CLI 호스트(`spawn_agent` API 사용 가능)일 때 기본 경로다.
- **codex exec 경로**는 Claude Code 세션(codex exec 기본 → Agent tool fallback)과 headless 세션(CI, `claude -p`)에서 기본 경로다.
- `CODEX_CI=1`은 Codex 세션에서도 보일 수 있으므로 sole discriminator로 쓰지 않는다.

## 질문 도구 미지원 대응

(legacy alias: `AskUserQuestion 미지원 대응`. 본 섹션은 질문 도구가 호출 불가능한 런타임에서의 자동 승격/종료 정책을 기술한다.)

현재 런타임에서 질문 도구(Claude Code의 `AskUserQuestion` 도구, Codex의 `request_user_input` 등)를 호출할 수 없는 경우 (대표 사례: headless 세션 — `claude -p`, `codex exec` subprocess, CI — stdin 입력 불가) 다음 규칙을 적용한다.

`request_user_input`은 codex 0.106+에서 default mode 활성화 가능 (`default_mode_request_user_input=true`). 본 nixos-config는 이를 충족하므로 Codex 세션은 지원 런타임으로 간주한다 — Codex 세션 자체는 본 섹션 자동 전이 적용 대상이 아니다.

### First-pass single Arbiter 경로 (기존)

- NEEDS_MORE_INFO 항목은 **CONFIRMED_ISSUE로 자동 승격**한다 (텍스트 보고만으로는 상태 전이가 불가능하므로).
- CONFIRMED_ISSUE는 동일하게 자동 수정한다.
- SKIP 판정 시 질문 도구 불가 → **자동 LITE 승격**.
- 3회 반복 규칙 도달 시 질문 도구 불가 → **자동 수용** (지적대로 수정).
- 5회 라운드 초과 시 질문 도구 불가 → **자동 종료** (현재 상태로 CLEAR 간주, DA 루프 종료).

### Selective consistency 경로 (N=3 재판정 결과)

selective consistency에서 나온 stability_status는 first-pass 자동 승격 규칙을 **따르지 않는다**. N=3이 유효했다는 것은 first-pass가 이미 애매했다는 의미이므로 더 보수적으로 처리한다.

- `stability_status=stable` (3:0): first-pass 자동 승격 규칙을 그대로 적용한다 (CONFIRMED → 수정, NOT_AN_ISSUE → 무해, NEEDS_MORE_INFO → 자동 CONFIRMED_ISSUE 승격 가능).
- `stability_status=split` (2:1): **자동 승격 금지**. 명시적 rerun 또는 환경 업그레이드 전까지 `BLOCKED`로 기록하고 DA 루프를 해당 finding에 대해 중단. 로그에 vote-shape와 minority verdict를 남긴다.
- `stability_status=fragmented` (1:1:1): **자동 승격 금지**. 동일하게 `BLOCKED`. rubric 재검토 신호로 라운드 요약에 명시.
- partial failure: **자동 승격 금지**, `BLOCKED`.

## Review Intensity 판단 에이전트 실행 계약

DA 에이전트/Arbiter와 동일한 런타임 분기 계약을 따르되, 다음이 다르다:

| 항목 | DA/Arbiter | Review Intensity |
|------|-----------|-----------------|
| 입력 | diff 전체 또는 계획 전체 | `git diff --stat` 또는 계획 파일 목록 |
| 출력 | findings/verdicts | SKIP/LITE/FULL + 근거 (첫 줄 판정 + 이후 근거) |
| 참조 | da-domains.md, arbiter-prompt.md | intensity-rules.md |
| 실패 시 | NEEDS_MORE_INFO 승격 | **FULL 강제** |

- Codex 세션 경로에서는 fresh intensity subagent 1개를 standard review profile로 사용하고, 결과 파싱 후 completed thread를 `close_agent`로 닫는다.
- codex exec 경로(Claude Code 세션 · headless 세션)에서는 **foreground 실행**으로 `--full-auto --ephemeral -c model_reasoning_effort="medium"`를 호출한다 (단일 exec이므로 병렬/background 사용 안 함).
- 프롬프트에서 "references/intensity-rules.md를 직접 읽어 규칙을 적용하라"고 지시하고, Intensity는 review-only/no-write role임을 함께 명시한다.
- codex exec 경로의 프롬프트 파일은 `umask 077`로 권한 제한한다.
- 메인 LLM은 결과를 읽고 판정에 따라 분기한다. 질문 도구(SKIP 시)는 메인 LLM이 호출한다.
- 질문 도구 미지원 시 SKIP 처리는 위 "질문 도구 미지원 대응" 섹션의 규칙을 따른다.

## 향후 확장

위 예외 조건이 실제로 반복 검증되면 교차 검증(Arbiter 2개+)이나 Known-Answer Calibration 도입을 검토한다.
그 전까지는 single strong arbiter가 기본 계약이다.
