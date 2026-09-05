# Harness 셀프테스트 가이드 (T1~T8)

`claude -p --output-format json`의 init 이벤트를 활용하여 harness 구성요소를 자동 검증한다.

- 버전 스탬프 정본: [`../SKILL.md`](../SKILL.md) "작성 기준" — reference에 스탬프를 박으면
  bump 때 stale해지고 `warn-skill-version-stamps.sh`의 대상 밖이라 경보도 나지 않는다
  (`.claude/skills/configuring-codex/references/runbook-codex-compat.md` 정책).
- 아래 내용은 v2.1.206 기준으로 작성됐고, 이후 개별 재실측한 항목에는 `재확인: <날짜>, <버전>`
  스탬프가 붙어 있다 (그 스탬프가 이 baseline보다 우선).
- 재검증: `claude --version && claude --help && claude -p --help`
- 확인 범위: 인증된 JSON 성공 probe에서 init key를 재확인 (2026-08-15, v2.1.233 — 이벤트 수는 런마다 가변이며 고정 계약이 아님, gotchas.md #6. 재검증: `echo "ok" | claude -p --model haiku --output-format json`). 이 probe가 커버하는 범위는 init key 존재와 이벤트 shape뿐이며, T1~T8 스크립트 전체의 동작은 재검증 미수행이다 (v2.1.202 기준 서술 유지)
- 비용: 각 테스트의 "비용:" 표기는 v2.1.202 기준 추정치다. 실비는 모델·캐시에 따라 수 배
  변동하므로 (2.1.233 실측: haiku 사소 호출 ~$0.012, 스키마 호출 ~$0.060) 하드코딩 표 대신
  result 이벤트의 `total_cost_usd`(모델별 내역은 `modelUsage`)를 파싱해 측정한다.

공통 성공 계약: Claude exit 0, `result/success` + `is_error=false` + `terminal_reason=completed`
+ 빈 `permission_denials`, 기대 산출물 `test -s`, 기대 marker를 모두 확인한다. JSON stdout, stderr, 업무 산출물을 분리하고 parser 앞에 `2>&1`을 두지 않는다.
반복 테스트는 직전 결과 대비 진척 delta가 없으면 circuit breaker로 중단한다.

## 판정에 쓸 수 있는 init·result 필드 (2026-08-15, v2.1.233 실측 + 공식 headless 문서)

| 이벤트 | 필드 | 용도 | 주의 |
|--------|------|------|------|
| init | `plugin_errors` | 플러그인 load-time 오류 배열 — 비어 있지 않으면 FAIL 게이트 | 오류 없으면 키 자체가 생략됨. 로드 실패 플러그인은 `plugins`에서 빠지므로 개수 비교로는 탐지 불가 |
| init | `mcp_server_errors` | `--mcp-config` 엔트리의 config validation 스킵 목록 (v2.1.219+) | 런타임 연결 실패는 미포함. 오류 없으면 키 생략 |
| init | `capabilities` | SDK 프로토콜 behavior의 feature detection (v2.1.205+) | 프로토콜 축 전용 — CLI 플래그 존재 판정에는 쓸 수 없다 |
| result | `terminal_reason` | `completed` 외 값(`max_turns` 등)은 비정상 종료 신호 | |
| result | `permission_denials` | 도구 거부 목록 — exit 0이어도 비어 있지 않으면 도구가 차단된 것 (gotchas #3의 프로그래밍적 탐지) | |
| result | `total_cost_usd` / `modelUsage` | 호출당 실비 측정 | client-side 추정치 |
| result | `structured_output` | `--json-schema` 호출의 검증된 출력 | 스키마 미지정 호출에는 키 없음 (patterns.md 패턴 10) |
| rate_limit_event | `rate_limit_info` (status/resetsAt/utilization) | 한도 접근 경고 게이트 (`status != allowed`) | |

## T1: Harness 인벤토리 검증

목적: init 이벤트에서 skills, tools 수가 기대치 이상인지 확인 (MCP·plugins는 표시만, 판정 제외)

비용: ~$0.07 | 위치: 로컬

```bash
#!/usr/bin/env bash
# T1: Harness Inventory Check
set -o pipefail
echo "ok" | claude -p --output-format json > /tmp/harness-init.json 2> /tmp/harness-init.stderr
CLAUDE_RC=${PIPESTATUS[1]}
test "$CLAUDE_RC" -eq 0 && test -s /tmp/harness-init.json || exit 1

# 파싱은 한 번으로 통합한다. system 이벤트 부재/JSON 오류 시 python이 non-zero로 죽고
# || 가드가 즉시 FAIL 처리하므로, 빈 변수로 후속 판정이 오염되지 않는다.
INV=$(python3 -c "
import sys, json
data, _ = json.JSONDecoder().raw_decode(sys.stdin.read().lstrip())  # 후행 비-JSON 라인 내성
items = data if isinstance(data, list) else [data]
# subtype 가드 필수 — system 이벤트는 다중 매치 (thinking_tokens 가변 삽입; gotchas.md #17).
# 가드 없이 [0]을 집으면 인벤토리 0으로 'Skills too few' FAIL이 나며 원인을 harness 설정으로 오도한다.
init = next(d for d in items if isinstance(d, dict)
            and d.get('type')=='system' and d.get('subtype')=='init')
results = [d for d in items if isinstance(d, dict) and d.get('type')=='result']
# 성공 판정에 terminal_reason·permission_denials를 함께 본다 — subtype/is_error만 보면
# 비정상 종료(max_turns 등)와 도구 거부(exit 0)가 성공으로 통과한다 (위 필드 표).
r = results[-1] if results else {}
ok = (bool(results) and r.get('subtype') == 'success' and not r.get('is_error', False)
      and r.get('terminal_reason', 'completed') == 'completed'
      and not r.get('permission_denials'))
print(len(init.get('skills', [])))
print(len(init.get('tools', [])))
print(len(init.get('mcp_servers', [])))
print(len(init.get('plugins', [])))
# 로드 실패 항목은 plugins/mcp_servers 목록에서 빠지므로 개수 비교로는 탐지 불가 —
# 에러 배열 게이트가 정본이다 (오류 없으면 키 자체가 생략됨: 공식 headless 문서)
print(len(init.get('plugin_errors', [])))
print(len(init.get('mcp_server_errors', [])))
print('yes' if ok else 'no')" < /tmp/harness-init.json) || { echo "T1: FAIL (JSON parse or missing system event)"; exit 1; }
{ read -r SKILLS; read -r TOOLS; read -r MCP; read -r PLUGINS; read -r PLUGIN_ERRS; read -r MCP_ERRS; read -r RESULT_OK; } <<< "$INV"

echo "Skills: $SKILLS, Tools: $TOOLS, MCP: $MCP, Plugins: $PLUGINS"

# 판정 기준 (기대값은 환경에 따라 조정)
PASS=true
[ "$RESULT_OK" != "yes" ] && echo "FAIL: result event is not successful" && PASS=false
[ "$SKILLS" -lt 10 ] && echo "FAIL: Skills too few ($SKILLS < 10)" && PASS=false
[ "$TOOLS" -lt 10 ] && echo "FAIL: Tools too few ($TOOLS < 10)" && PASS=false
[ "$PLUGIN_ERRS" -gt 0 ] && echo "FAIL: plugin_errors non-empty ($PLUGIN_ERRS)" && PASS=false
[ "$MCP_ERRS" -gt 0 ] && echo "FAIL: mcp_server_errors non-empty ($MCP_ERRS)" && PASS=false
# MCP 서버 0개는 정상이다 (이 저장소는 관리 MCP 서버를 두지 않는다) — MCP 개수 단언 없음

# 판정을 종료 코드로 내보낸다 — echo만 두면 새 에러 배열 게이트가 걸려도 exit 0이라
# 자동화 호출자가 깨진 plugin/MCP 구성을 성공으로 읽는다.
if $PASS; then echo "T1: PASS"; else echo "T1: FAIL"; exit 1; fi
```

판정 로직: Skills >= 10, Tools >= 10, `plugin_errors`·`mcp_server_errors` 빈 배열이면 PASS (MCP 개수는 판정에서 제외 — 0개 정상). 정확한 기대값은 nrs 직후 한 번 측정하여 기준선으로 사용.

## T2a: 스킬 등록 Spot Check

목적: 주요 스킬이 init 이벤트의 skills 목록에 존재하는지 확인 — 등록 여부만 본다.
스킬이 실제로 발동하는지는 T2b가 검증한다 (등록 ≠ 발동).

비용: ~$0.07 (T1과 동일 init 이벤트 재사용 가능) | 위치: 로컬

```bash
#!/usr/bin/env bash
# T2a: Skill Registration Spot Check
test -s /tmp/harness-init.json || { echo "T2a: FAIL (run T1 first)"; exit 1; }
RESULT=$(< /tmp/harness-init.json)

SKILL_LIST=$(echo "$RESULT" | python3 -c "
import sys, json
data, _ = json.JSONDecoder().raw_decode(sys.stdin.read().lstrip())  # 후행 비-JSON 라인 내성
items = data if isinstance(data, list) else [data]
init = next(d for d in items if isinstance(d, dict)
            and d.get('type')=='system' and d.get('subtype')=='init')
for s in init.get('skills', []):
    print(s)")

EXPECTED_SKILLS=(
  "using-claude-p"
  "using-codex-exec"
  "create-issue"
)

PASS=true
for skill in "${EXPECTED_SKILLS[@]}"; do
  if echo "$SKILL_LIST" | grep -q "$skill"; then
    echo "  ✓ $skill"
  else
    echo "  ✗ $skill MISSING"
    PASS=false
  fi
done

$PASS && echo "T2a: PASS" || echo "T2a: FAIL"
```

판정 로직: 지정된 스킬 이름이 모두 init skills 목록에 존재하면 PASS.

## T2b: 스킬 발동 회귀 테스트 (positive/negative 대조)

목적: 대상 스킬이 발동 유도 프롬프트에서 실제로 로드되고, 경계(비발동) 프롬프트에서 로드되지
않는지 확인. T2a의 등록 확인만으로는 "등록됐지만 한 번도 발동하지 않는" 미로드 사고를 못
잡는다 (재확인: 2026-08-15, v2.1.233 라이브 — 트리거 문구를 수정했을 때의 효과 실측 수단).

비용: 호출 2회 (positive/negative 각 1회, haiku 권장) | 위치: 격리 cwd (`mktemp -d` —
project-level 스킬 오염 배제)

```bash
#!/usr/bin/env bash
# T2b: Skill Activation Regression — 대상 스킬명과 프롬프트 2종은 환경에 맞게 지정
TARGET_SKILL="using-claude-p"
POS_PROMPT="claude -p 헤드리스 자동화로 JSON을 파싱하려 한다. 방법을 알려줘."   # 발동 기대
NEG_PROMPT="tmux 세션 복원 설정을 알려줘."                                     # 비발동 기대 (인접 스킬은 허용)

WORK=$(mktemp -d)
for kind in pos neg; do
  [ "$kind" = "pos" ] && P="$POS_PROMPT" || P="$NEG_PROMPT"
  ( cd "$WORK" && echo "$P" | claude -p --model haiku --output-format json \
      --no-session-persistence > "$WORK/$kind.json" 2> "$WORK/$kind.stderr" )
done

# Skill tool_use만 추출 — raw 출력 전체 grep은 구조적 거짓 양성이다:
# init 이벤트의 skills·slash_commands 배열 양쪽에 스킬명이 그대로 들어 있다 (2.1.233 라이브 재확인).
extract() { jq -r '[.[] | select(.type=="assistant") | .message.content[]?
  | select(.type=="tool_use" and .name=="Skill") | .input.skill] | unique[]' "$1" 2>/dev/null; }

POS_HIT=$(extract "$WORK/pos.json" | grep -cx "$TARGET_SKILL")
NEG_HIT=$(extract "$WORK/neg.json" | grep -cx "$TARGET_SKILL")

PASS=true
[ "$POS_HIT" -ge 1 ] || { echo "FAIL: positive 프롬프트에서 $TARGET_SKILL 미발동"; PASS=false; }
[ "$NEG_HIT" -eq 0 ] || { echo "FAIL: negative 프롬프트에서 $TARGET_SKILL 발동"; PASS=false; }
$PASS && echo "T2b: PASS" || echo "T2b: FAIL"
```

판정 로직·주의:
- positive = 대상 스킬의 Skill tool_use 존재. negative = 대상 스킬 부재 — 인접 스킬 발동은
  허용한다 (비발동 프롬프트가 다른 스킬을 정당하게 깨울 수 있다).
- 발동 근거로 응답 본문을 grep해야 한다면 sentinel 토큰은 init 이벤트의 `skills`/`slash_commands`
  어느 쪽에도 없는 값이어야 한다 (사전 조건). 라벨 완전일치 grep은 모델의 형식 편차로 거짓
  음성을 낸다 — 관대한 매칭을 쓴다.
- 트리거(description) 문구를 수정하는 변경은 이 테스트의 positive/negative 대조를 통과한 뒤
  확정한다.

## T3: Hooks 로드 검증

목적: settings.json에 등록된 hooks가 실제 파일로 존재하고 실행 가능한지 확인

비용: $0 (파일 시스템 검사만) | 위치: 로컬

```bash
#!/usr/bin/env bash
# T3: Hooks File Verification
SETTINGS="$HOME/.claude/settings.json"
PASS=true

if [ ! -f "$SETTINGS" ]; then
  echo "FAIL: settings.json not found"
  exit 1
fi

# settings.json에서 hook 경로 추출
HOOK_PATHS=$(python3 -c "
import json, re
with open('$SETTINGS') as f:
    content = f.read()
# hook command에서 경로 추출
for match in re.findall(r'\"command\":\s*\"([^\"]+)\"', content):
    # 첫 번째 토큰이 경로인 경우
    path = match.split()[0]
    if '/' in path:
        print(path)" 2>/dev/null)

if [ -z "$HOOK_PATHS" ]; then
  echo "INFO: No hook paths found in settings.json"
  echo "T3: PASS (no hooks)"
  exit 0
fi

while IFS= read -r hook_path; do
  # ~ 확장
  expanded=$(eval echo "$hook_path")
  if [ -f "$expanded" ]; then
    if [ -x "$expanded" ]; then
      echo "  ✓ $hook_path (exists, executable)"
    else
      echo "  ✗ $hook_path (exists, NOT executable)"
      PASS=false
    fi
  else
    echo "  ✗ $hook_path (NOT found)"
    PASS=false
  fi
done <<< "$HOOK_PATHS"

$PASS && echo "T3: PASS" || echo "T3: FAIL"
```

판정 로직: settings.json에 등록된 모든 hook 파일이 존재하고 실행 가능하면 PASS.

## T4: MCP 서버 검증

목적: mcp.json에 등록된 MCP 서버가 init 이벤트에 나타나는지 확인

비용: ~$0.07 (T1과 동일 init 이벤트 재사용 가능) | 위치: 로컬

```bash
#!/usr/bin/env bash
# T4: MCP Server Verification
MCP_CONFIG="$HOME/.claude/mcp.json"
if [ ! -f "$MCP_CONFIG" ]; then
  # 이 저장소는 관리 MCP 서버를 두지 않으므로 ~/.claude/mcp.json 부재가 정상이다.
  # 사용자가 수동으로 MCP를 등록한 경우에만 의미가 있는 테스트다.
  # (부재 시 claude 호출 없이 즉시 SKIP — 불필요한 비용/지연 회피)
  echo "T4: SKIP (관리 MCP 없음 — ~/.claude/mcp.json 부재)"
  exit 0
fi

test -s /tmp/harness-init.json || { echo "T4: FAIL (run T1 first)"; exit 1; }
RESULT=$(< /tmp/harness-init.json)

MCP_SERVERS=$(echo "$RESULT" | python3 -c "
import sys, json
data, _ = json.JSONDecoder().raw_decode(sys.stdin.read().lstrip())  # 후행 비-JSON 라인 내성
items = data if isinstance(data, list) else [data]
init = next(d for d in items if isinstance(d, dict)
            and d.get('type')=='system' and d.get('subtype')=='init')
for s in init.get('mcp_servers', []):
    print(s)")

# 이름 대조만으로는 config validation 스킵을 탐지하지 못한다 — 에러 배열이 정본 게이트다.
MCP_ERRS=$(echo "$RESULT" | python3 -c "
import sys, json
data, _ = json.JSONDecoder().raw_decode(sys.stdin.read().lstrip())
items = data if isinstance(data, list) else [data]
init = next(d for d in items if isinstance(d, dict)
            and d.get('type')=='system' and d.get('subtype')=='init')
print(len(init.get('mcp_server_errors', [])))")

EXPECTED_SERVERS=$(python3 -c "
import json
with open('$MCP_CONFIG') as f:
    data = json.load(f)
for name in data.get('mcpServers', {}).keys():
    print(name)")

PASS=true
while IFS= read -r server; do
  [ -z "$server" ] && continue
  if echo "$MCP_SERVERS" | grep -q "$server"; then
    echo "  ✓ $server"
  else
    echo "  ✗ $server MISSING from init"
    PASS=false
  fi
done <<< "$EXPECTED_SERVERS"

[ "$MCP_ERRS" -gt 0 ] && echo "  ✗ mcp_server_errors non-empty ($MCP_ERRS)" && PASS=false

if $PASS; then echo "T4: PASS"; else echo "T4: FAIL"; exit 1; fi
```

판정 로직: ~/.claude/mcp.json이 없으면 SKIP(관리 MCP 없음이 정상). 있으면 mcp.json의 모든 서버 이름이 init mcp_servers에 존재하면 PASS. 추가로 init의 `mcp_server_errors` 배열이 비어 있지 않으면 FAIL (config validation 스킵 항목 — v2.1.219+). 단 서버 `status:"pending"`은 캐시된 tool list를 가진 원격 서버의 정상 상태이므로 (공식 문서) status 기반 판정은 넣지 않는다 — 거짓 양성이 난다.

## T5: 권한 모델 검증

목적: `-p` 모드에서 권한 없이 도구 사용이 차단되고, `--dangerously-skip-permissions`로 허용되는지 확인

비용: ~$0.14 (2회 호출) | 위치: 로컬

```bash
#!/usr/bin/env bash
# T5: Permission Model Check
PASS=true
set -o pipefail

# 5a: 권한 없이 도구 사용 → 도구 미실행 (exit 0이지만 도구 못 씀)
echo "ls /tmp | head -1을 실행하고 결과만 출력해" | claude -p --output-format json \
  > /tmp/t5-no-perm.json 2> /tmp/t5-no-perm.stderr
T5A_RC=${PIPESTATUS[1]}
HAS_TOOL_USE=$(python3 -c "
import sys, json
data, _ = json.JSONDecoder().raw_decode(sys.stdin.read().lstrip())  # 후행 비-JSON 라인 내성
items = data if isinstance(data, list) else [data]
for d in items:
    if isinstance(d, dict) and d.get('type')=='assistant':
        for block in d.get('message', {}).get('content', []):
            if isinstance(block, dict) and block.get('type')=='tool_use':
                print('yes'); exit()
print('no')" < /tmp/t5-no-perm.json)

if [ "$T5A_RC" -eq 0 ] && [ "$HAS_TOOL_USE" = "no" ]; then
  echo "  ✓ 5a: Tool blocked without permissions"
else
  echo "  ✗ 5a: Tool should be blocked without permissions"
  PASS=false
fi

# 5b: 권한 우회 → 도구 실행 성공
echo "echo T5_CHECK를 Bash로 실행하고 결과만 출력해" | claude -p --dangerously-skip-permissions --output-format json \
  > /tmp/t5-with-perm.json 2> /tmp/t5-with-perm.stderr
T5B_RC=${PIPESTATUS[1]}
HAS_RESULT=$(python3 -c "
import sys, json
data, _ = json.JSONDecoder().raw_decode(sys.stdin.read().lstrip())  # 후행 비-JSON 라인 내성
items = data if isinstance(data, list) else [data]
result = [d for d in items if isinstance(d, dict) and d.get('type')=='result'][0]
ok = result.get('subtype') == 'success' and not result.get('is_error', False)
print('yes' if ok and 'T5_CHECK' in result.get('result', '') else 'no')" < /tmp/t5-with-perm.json)

if [ "$T5B_RC" -eq 0 ] && [ "$HAS_RESULT" = "yes" ]; then
  echo "  ✓ 5b: Tool allowed with --dangerously-skip-permissions"
else
  echo "  ✗ 5b: Tool should work with --dangerously-skip-permissions"
  PASS=false
fi

$PASS && echo "T5: PASS" || echo "T5: FAIL"
```

판정 로직: 5a에서 도구 차단 + 5b에서 도구 허용이면 PASS.

## T6: SSH 크로스머신 실행

목적: SSH 경유로 원격 머신에서 `claude -p`가 정상 실행되는지 확인

비용: ~$0.07 | 위치: 크로스머신 (Mac -> MiniPC 또는 반대)

```bash
#!/usr/bin/env bash
# T6: SSH Cross-Machine Execution
# 현재 머신에 따라 원격 대상 결정
if [[ "$(uname)" == "Darwin" ]]; then
  REMOTE="minipc"
  EXPECTED_HOST="greenhead-minipc"
else
  REMOTE="mac"
  EXPECTED_HOST="greenhead-MacBookPro"
fi

set -o pipefail
# outer timeout: 원격 hang 시 무기한 대기 방지 (SSH_RC 124 = timeout 발동; macOS는 coreutils timeout 필요)
# ⚠️ Bash tool 경유 시 기본 900초 예산은 하네스 foreground 상한보다 크다 — background 발사 또는
# timeout 파라미터 명시가 필수다 (SKILL.md "호출 상한 (Bash tool 경유)" 참조).
echo "hostname을 실행하고 결과만 출력해" | timeout "${SSH_TIMEOUT:-900}" ssh "$REMOTE" 'claude -p --dangerously-skip-permissions' \
  > /tmp/t6-remote.txt 2> /tmp/t6-remote.stderr
SSH_RC=${PIPESTATUS[1]}
RESULT=$(< /tmp/t6-remote.txt)

if [ "$SSH_RC" -eq 0 ] && test -s /tmp/t6-remote.txt && grep -qi "$EXPECTED_HOST" /tmp/t6-remote.txt; then
  echo "  ✓ Remote hostname: $RESULT"
  echo "T6: PASS"
  rc=0
else
  echo "  ✗ Expected '$EXPECTED_HOST', got: $RESULT"
  echo "T6: FAIL"
  rc=1
fi
# 판정 결과를 종료 코드로 내보낸다 — echo만 두면 실패도 exit 0이라 호출자·완료 알림이
# 성공으로 읽는다. background 발사는 여기에 `.rc` 영속화를 더한다 (아래 실행 방법).
printf '%s' "$rc" > /tmp/t6.rc
exit "$rc"
```

판정 로직: 원격 hostname이 기대값과 일치하면 PASS(exit 0), 아니면 exit 1.

실행 방법 (Bash tool 경유): 이 스크립트는 기본 900초 예산을 쓰므로 하네스 foreground
상한보다 길다 — `run_in_background: true`로 발사하고, 완료 알림 수신 후 `/tmp/t6.rc`와
`/tmp/t6-remote.txt`를 함께 확인한다. 알림의 exit code는 래핑 셸의 최종 rc이므로 위처럼
`exit "$rc"`로 끝내야 실패가 실패로 통지된다 (`.rc` 부재 자체도 실패로 취급 —
[using-codex-exec SKILL.md "background 발사의 rc 계약"](../../using-codex-exec/SKILL.md)과 동일 규약).

> 이 테스트는 SSH 연결이 가능한 환경에서만 실행한다. SSH 연결 실패 시 별도 진단.
> 무출력 약 10분 뒤 완료된 사례가 있으므로 outer timeout을 두되 무출력만으로 중단하지 않는다 —
> 단 Bash tool foreground 발사에서는 하네스 상한이 그보다 먼저 발화하므로 background로 발사한다.
> 종료 뒤 기대 결과 파일/marker를 검증한다.

## T7: 세션 체이닝

목적: `--resume`으로 이전 `-p` 세션의 컨텍스트를 유지할 수 있는지 확인

비용: ~$0.14 (2회 호출) | 위치: 로컬

```bash
#!/usr/bin/env bash
# T7: Session Chaining
SECRET="T7_$(date +%s)"
set -o pipefail

# 1단계: 비밀 코드 설정 + session_id 추출
echo "나의 비밀 코드는 ${SECRET}이야. 확인했으면 '확인'이라고만 답해." | claude -p --output-format json \
  > /tmp/t7-first.json 2> /tmp/t7-first.stderr
T7_FIRST_RC=${PIPESTATUS[1]}
# 성공 계약: exit 0 + session_id만으로 부족하다. result/success까지 검증해야
# 실패한 첫 세션을 resume 대상으로 쓰는 오판을 막는다 (assert 실패 → non-zero → SESSION_ID 빈 값).
SESSION_ID=$(python3 -c "
import sys, json; data, _ = json.JSONDecoder().raw_decode(sys.stdin.read().lstrip()); items=data if isinstance(data,list) else [data]
results=[d for d in items if isinstance(d,dict) and d.get('type')=='result']
assert results and results[-1].get('subtype')=='success' and not results[-1].get('is_error', False), 'first call result is not successful'
for item in items:
    if isinstance(item, dict) and item.get('type')=='system':
        print(item['session_id']); break" < /tmp/t7-first.json)

if [ "$T7_FIRST_RC" -ne 0 ] || [ -z "$SESSION_ID" ]; then
  echo "  ✗ First call did not succeed (result/success or session_id missing)"
  echo "T7: FAIL"
  exit 1
fi
echo "  Session: $SESSION_ID"

# 2단계: resume으로 이전 컨텍스트 조회
echo "내 비밀 코드가 뭐였어? 코드만 답해." | claude -p --resume "$SESSION_ID" \
  > /tmp/t7-recall.txt 2> /tmp/t7-recall.stderr
T7_RECALL_RC=${PIPESTATUS[1]}
RECALL=$(< /tmp/t7-recall.txt)

if [ "$T7_RECALL_RC" -eq 0 ] && test -s /tmp/t7-recall.txt && grep -q "$SECRET" /tmp/t7-recall.txt; then
  echo "  ✓ Session recalled: $SECRET"
  echo "T7: PASS"
else
  echo "  ✗ Expected '$SECRET', got: $RECALL"
  echo "T7: FAIL"
fi
```

판정 로직: 2단계에서 1단계의 비밀 코드를 올바르게 recall하면 PASS.

## T8: 동시 실행 안정성

목적: 같은 디렉토리에서 2개의 `claude -p` 프로세스가 충돌 없이 동시 실행되는지 확인

비용: ~$0.14 (2회 동시 호출) | 위치: 로컬

```bash
#!/usr/bin/env bash
# T8: Concurrent Execution
TMPDIR=$(mktemp -d)

echo "echo T8_PROC1" | claude -p --dangerously-skip-permissions --no-session-persistence \
  > "$TMPDIR/proc1.txt" 2> "$TMPDIR/proc1.stderr" &
PID1=$!

echo "echo T8_PROC2" | claude -p --dangerously-skip-permissions --no-session-persistence \
  > "$TMPDIR/proc2.txt" 2> "$TMPDIR/proc2.stderr" &
PID2=$!

wait $PID1
EXIT1=$?
wait $PID2
EXIT2=$?

PASS=true
if [ $EXIT1 -eq 0 ] && grep -q "T8_PROC1" "$TMPDIR/proc1.txt"; then
  echo "  ✓ Proc1: OK"
else
  echo "  ✗ Proc1: FAIL (exit=$EXIT1)"
  PASS=false
fi

if [ $EXIT2 -eq 0 ] && grep -q "T8_PROC2" "$TMPDIR/proc2.txt"; then
  echo "  ✓ Proc2: OK"
else
  echo "  ✗ Proc2: FAIL (exit=$EXIT2)"
  PASS=false
fi

rm -rf "$TMPDIR"
$PASS && echo "T8: PASS" || echo "T8: FAIL"
```

판정 로직: 두 프로세스 모두 exit 0이고 각각의 출력에 기대 문자열이 포함되면 PASS.

동시 실행 안정성과 `--no-session-persistence`의 충돌 방지 효과는 재검증 미수행
(v2.1.202 기준 서술 유지).

---

## 실행 전략

| 테스트 | 비용 | 실행 조건 | 비고 |
|--------|------|-----------|------|
| T1 | ~$0.07 | `nrs` 후 자동 실행 권장 | init 이벤트 1회로 T1+T2a 커버 (T4는 관리 MCP 있을 때만) |
| T2a | ~$0 | T1의 init 재사용 | 추가 API 호출 불필요 |
| T2b | 호출 2회 (haiku) | 트리거 문구 변경 시 | positive/negative 발동 대조 |
| T3 | $0 | 파일 시스템 검사만 | API 호출 없음 |
| T4 | ~$0 | 관리 MCP 있을 때만 (없으면 즉시 SKIP) | mcp.json 존재 시 T1의 init 재사용 |
| T5 | ~$0.14 | 권한 설정 변경 시 | 2회 호출 |
| T6 | ~$0.07 | SSH 설정 변경 시 | 크로스머신 필요 |
| T7 | ~$0.14 | 세션 관련 변경 시 | 2회 호출 |
| T8 | ~$0.14 | CI/자동화 도입 시 | 2회 동시 호출 |

최적화: T1, T2a(그리고 관리 MCP가 있는 경우 T4)는 동일한 init 이벤트를 재사용하므로, 한 번의 `claude -p --output-format json` 호출 결과를 파일에 저장하고 공유한다:

```bash
echo "ok" | claude -p --output-format json \
  > /tmp/harness-init.json 2> /tmp/harness-init.stderr
# T1, T2a(그리고 mcp.json이 있으면 T4)에서 /tmp/harness-init.json을 읽어서 판정
```

## 검증 규율 (프로브·재검증 공통)

세션 전수조사에서 가장 잦았던 단일 검증 오류는 "대리 명령으로 능력을 판정"이었다
(마이닝된 검증 오류 32건 중 12건 — 실행 가능한 작업을 실행하지 않고 사용자에게 위임한 결과).
프로브·gotcha 재검증·스탬프 갱신에 공통 적용한다:

1. 능력 사전 게이트의 프로브 명령 = 실제 실행할 명령이다. `true`·`echo`·`--version`으로
   대리 측정하지 않는다 — 권한·sandbox·플래그 게이트는 명령별로 다르다 (`--version` 프로브가
   모든 플래그를 "존재함"으로 오판한 실측 반례).
2. 기록된 gotcha의 재검증은 그 gotcha가 명시한 호출 형태를 문자 그대로 재현한다 — 다른 형태로
   재어 "버그 없음"을 결론낸 거짓 음성이 실측 2회 있다. gotcha에 재현 커맨드가 병기돼 있으면
   그 형태를 바꾸지 않는다.
3. rc 기반 능력 판정 금지 — 결정론적 인자 오류·권한 거부·업무 실패가 같은 rc로 나타난다.
4. help 부재 ≠ 제거 — hidden flag의 제거 판정은 실행 smoke로만 한다 (문서 공통 원칙 재확인).
5. 단일 실행 결과를 그대로 스탬프하지 않는다 — 간헐 현상(stdout 오염 등)은 2회 이상 확인.
6. 무출력만으로 hang을 판정하지 않는다 (SKILL.md SSH 절과 동일 원칙).

## 종결 게이트 — 스킬 문서 수정의 라이브 반영 확인

스킬은 디렉토리 단위 out-of-store 심링크로 배포된다 (`~/.claude/skills/<skill>` → nix store →
저장소 소스 디렉토리). 따라서 링크가 이미 있으면 소스 파일 편집은 activation 없이 즉시 반영되고,
`nrs`가 필요한 경우는 링크 신규 생성·경로 변경뿐이다. 대신 실제 함정은 링크가 가리키는 대상이
메인 checkout이라는 점이다 — 워크트리에서 편집한 내용은 그 브랜치를 메인에 머지하기 전까지
라이브 세션에 반영되지 않는다. 이를 확인하지 않고 "수정·검증 완료"로 보고한 착각 경로가 있다.
스킬 문서 수정 작업을 종결하기 전에:

1. 배포본 실측: 심링크는 디렉토리에 걸려 있으므로 `readlink ~/.claude/skills/<skill>`(또는
   `readlink -f ~/.claude/skills/<skill>/SKILL.md`)로 확인한다 — 파일에 직접 `readlink`를 걸면
   정상 배포 상태에서도 rc 1이다. 이어서 이번 수정의 고유 문자열이 배포본에 보이는지 grep한다
   (`rg -c '<신규 문자열>' ~/.claude/skills/<skill>/SKILL.md`). 워크트리 작업이면 이 grep은
   머지 전까지 0건이 정상이며, 라이브 검증은 머지 후에 수행한다.
2. frontmatter 회귀: `claude plugin validate <스킬 디렉토리>`가 비용 0의 정적 게이트다
   (`--strict`로 warning도 실패 처리 가능 — 확인: 2026-08-15, v2.1.233 help).
3. settings 검증: 자동화 도입 전 `claude doctor`로 설치·설정 상태를 확인한다.
4. 트리거(description)를 변경했다면 발동 회귀 대조(positive/negative 프롬프트 각 1회 —
   대상 스킬의 Skill tool_use 존재/부재 판정)를 통과한 뒤 확정한다.
