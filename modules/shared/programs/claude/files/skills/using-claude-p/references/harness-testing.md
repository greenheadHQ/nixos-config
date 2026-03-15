# Harness 셀프테스트 가이드 (T1~T8)

`claude -p --output-format json`의 init 이벤트를 활용하여 harness 구성요소를 자동 검증한다.

- 확인 날짜: **2026-03-15**
- 확인 버전: **Claude Code v2.1.76**
- 비용: 각 테스트 ~$0.07 (1-turn, 최소 프롬프트)

## T1: Harness 인벤토리 검증

**목적**: init 이벤트에서 skills, tools, MCP, plugins 수가 기대치와 일치하는지 확인

**비용**: ~$0.07 | **위치**: 로컬

```bash
#!/bin/bash
# T1: Harness Inventory Check
RESULT=$(echo "ok" | claude -p --output-format json 2>/dev/null)

SKILLS=$(echo "$RESULT" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
init = [d for d in data if isinstance(d, dict) and d.get('type')=='system'][0]
print(len(init.get('skills', [])))")

TOOLS=$(echo "$RESULT" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
init = [d for d in data if isinstance(d, dict) and d.get('type')=='system'][0]
print(len(init.get('tools', [])))")

MCP=$(echo "$RESULT" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
init = [d for d in data if isinstance(d, dict) and d.get('type')=='system'][0]
print(len(init.get('mcp_servers', [])))")

PLUGINS=$(echo "$RESULT" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
init = [d for d in data if isinstance(d, dict) and d.get('type')=='system'][0]
print(len(init.get('plugins', [])))")

echo "Skills: $SKILLS, Tools: $TOOLS, MCP: $MCP, Plugins: $PLUGINS"

# 판정 기준 (기대값은 환경에 따라 조정)
PASS=true
[ "$SKILLS" -lt 10 ] && echo "FAIL: Skills too few ($SKILLS < 10)" && PASS=false
[ "$TOOLS" -lt 10 ] && echo "FAIL: Tools too few ($TOOLS < 10)" && PASS=false
[ "$MCP" -lt 1 ] && echo "FAIL: No MCP servers" && PASS=false

$PASS && echo "T1: PASS" || echo "T1: FAIL"
```

**판정 로직**: Skills >= 10, Tools >= 10, MCP >= 1이면 PASS. 정확한 기대값은 nrs 직후 한 번 측정하여 기준선으로 사용.

## T2: 스킬 트리거 Spot Check

**목적**: 주요 스킬이 init 이벤트의 skills 목록에 존재하는지 확인

**비용**: ~$0.07 (T1과 동일 init 이벤트 재사용 가능) | **위치**: 로컬

```bash
#!/bin/bash
# T2: Skill Trigger Spot Check
RESULT=$(echo "ok" | claude -p --output-format json 2>/dev/null)

SKILL_LIST=$(echo "$RESULT" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
init = [d for d in data if isinstance(d, dict) and d.get('type')=='system'][0]
for s in init.get('skills', []):
    print(s)")

EXPECTED_SKILLS=(
  "using-claude-p"
  "using-codex-exec"
  "managing-github-issues"
  "syncing-codex-harness"
  "maintaining-skills"
  "documenting-intent"
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

$PASS && echo "T2: PASS" || echo "T2: FAIL"
```

**판정 로직**: 지정된 스킬 이름이 모두 init skills 목록에 존재하면 PASS.

## T3: Hooks 로드 검증

**목적**: settings.json에 등록된 hooks가 실제 파일로 존재하고 실행 가능한지 확인

**비용**: $0 (파일 시스템 검사만) | **위치**: 로컬

```bash
#!/bin/bash
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

**판정 로직**: settings.json에 등록된 모든 hook 파일이 존재하고 실행 가능하면 PASS.

## T4: MCP 서버 검증

**목적**: mcp.json에 등록된 MCP 서버가 init 이벤트에 나타나는지 확인

**비용**: ~$0.07 (T1과 동일 init 이벤트 재사용 가능) | **위치**: 로컬

```bash
#!/bin/bash
# T4: MCP Server Verification
RESULT=$(echo "ok" | claude -p --output-format json 2>/dev/null)

MCP_SERVERS=$(echo "$RESULT" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
init = [d for d in data if isinstance(d, dict) and d.get('type')=='system'][0]
for s in init.get('mcp_servers', []):
    print(s)")

MCP_CONFIG="$HOME/.claude/mcp.json"
if [ ! -f "$MCP_CONFIG" ]; then
  echo "FAIL: mcp.json not found"
  exit 1
fi

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

$PASS && echo "T4: PASS" || echo "T4: FAIL"
```

**판정 로직**: mcp.json의 모든 서버 이름이 init mcp_servers에 존재하면 PASS.

## T5: 권한 모델 검증

**목적**: `-p` 모드에서 권한 없이 도구 사용이 차단되고, `--dangerously-skip-permissions`로 허용되는지 확인

**비용**: ~$0.14 (2회 호출) | **위치**: 로컬

```bash
#!/bin/bash
# T5: Permission Model Check
PASS=true

# 5a: 권한 없이 도구 사용 → 도구 미실행 (exit 0이지만 도구 못 씀)
RESULT_NO_PERM=$(echo "ls /tmp | head -1을 실행하고 결과만 출력해" | claude -p --output-format json 2>/dev/null)
HAS_TOOL_USE=$(echo "$RESULT_NO_PERM" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
for d in data:
    if isinstance(d, dict) and d.get('type')=='assistant':
        for block in d.get('message', {}).get('content', []):
            if isinstance(block, dict) and block.get('type')=='tool_use':
                print('yes'); exit()
print('no')" 2>/dev/null)

if [ "$HAS_TOOL_USE" = "no" ]; then
  echo "  ✓ 5a: Tool blocked without permissions"
else
  echo "  ✗ 5a: Tool should be blocked without permissions"
  PASS=false
fi

# 5b: 권한 우회 → 도구 실행 성공
RESULT_WITH_PERM=$(echo "echo T5_CHECK를 Bash로 실행하고 결과만 출력해" | claude -p --dangerously-skip-permissions --output-format json 2>/dev/null)
HAS_RESULT=$(echo "$RESULT_WITH_PERM" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
result = [d for d in data if d.get('type')=='result'][0]
print('yes' if 'T5_CHECK' in result.get('result', '') else 'no')" 2>/dev/null)

if [ "$HAS_RESULT" = "yes" ]; then
  echo "  ✓ 5b: Tool allowed with --dangerously-skip-permissions"
else
  echo "  ✗ 5b: Tool should work with --dangerously-skip-permissions"
  PASS=false
fi

$PASS && echo "T5: PASS" || echo "T5: FAIL"
```

**판정 로직**: 5a에서 도구 차단 + 5b에서 도구 허용이면 PASS.

## T6: SSH 크로스머신 실행

**목적**: SSH 경유로 원격 머신에서 `claude -p`가 정상 실행되는지 확인

**비용**: ~$0.07 | **위치**: 크로스머신 (Mac -> MiniPC 또는 반대)

```bash
#!/bin/bash
# T6: SSH Cross-Machine Execution
# 현재 머신에 따라 원격 대상 결정
if [[ "$(uname)" == "Darwin" ]]; then
  REMOTE="minipc"
  EXPECTED_HOST="greenhead-minipc"
else
  REMOTE="mac"
  EXPECTED_HOST="greenhead-MacBookPro"
fi

RESULT=$(echo "hostname을 실행하고 결과만 출력해" | ssh "$REMOTE" 'claude -p --dangerously-skip-permissions' 2>/dev/null)

if echo "$RESULT" | grep -qi "$EXPECTED_HOST"; then
  echo "  ✓ Remote hostname: $RESULT"
  echo "T6: PASS"
else
  echo "  ✗ Expected '$EXPECTED_HOST', got: $RESULT"
  echo "T6: FAIL"
fi
```

**판정 로직**: 원격 hostname이 기대값과 일치하면 PASS.

> 이 테스트는 SSH 연결이 가능한 환경에서만 실행한다. SSH 연결 실패 시 별도 진단.

## T7: 세션 체이닝

**목적**: `--resume`으로 이전 `-p` 세션의 컨텍스트를 유지할 수 있는지 확인

**비용**: ~$0.14 (2회 호출) | **위치**: 로컬

```bash
#!/bin/bash
# T7: Session Chaining
SECRET="T7_$(date +%s)"

# 1단계: 비밀 코드 설정 + session_id 추출
SESSION_ID=$(echo "나의 비밀 코드는 ${SECRET}이야. 확인했으면 '확인'이라고만 답해." | claude -p --output-format json 2>/dev/null | python3 -c "
import sys, json; data=json.loads(sys.stdin.read())
for item in data:
    if isinstance(item, dict) and item.get('type')=='system':
        print(item['session_id']); break")

if [ -z "$SESSION_ID" ]; then
  echo "  ✗ Failed to extract session_id"
  echo "T7: FAIL"
  exit 1
fi
echo "  Session: $SESSION_ID"

# 2단계: resume으로 이전 컨텍스트 조회
RECALL=$(echo "내 비밀 코드가 뭐였어? 코드만 답해." | claude -p --resume "$SESSION_ID" 2>/dev/null)

if echo "$RECALL" | grep -q "$SECRET"; then
  echo "  ✓ Session recalled: $SECRET"
  echo "T7: PASS"
else
  echo "  ✗ Expected '$SECRET', got: $RECALL"
  echo "T7: FAIL"
fi
```

**판정 로직**: 2단계에서 1단계의 비밀 코드를 올바르게 recall하면 PASS.

## T8: 동시 실행 안정성

**목적**: 같은 디렉토리에서 2개의 `claude -p` 프로세스가 충돌 없이 동시 실행되는지 확인

**비용**: ~$0.14 (2회 동시 호출) | **위치**: 로컬

```bash
#!/bin/bash
# T8: Concurrent Execution
TMPDIR=$(mktemp -d)

echo "echo T8_PROC1" | claude -p --dangerously-skip-permissions --no-session-persistence > "$TMPDIR/proc1.txt" 2>&1 &
PID1=$!

echo "echo T8_PROC2" | claude -p --dangerously-skip-permissions --no-session-persistence > "$TMPDIR/proc2.txt" 2>&1 &
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

**판정 로직**: 두 프로세스 모두 exit 0이고 각각의 출력에 기대 문자열이 포함되면 PASS.

---

## 실행 전략

| 테스트 | 비용 | 실행 조건 | 비고 |
|--------|------|-----------|------|
| T1 | ~$0.07 | `nrs` 후 자동 실행 권장 | init 이벤트 1회로 T1+T2+T4 커버 가능 |
| T2 | ~$0 | T1의 init 재사용 | 추가 API 호출 불필요 |
| T3 | $0 | 파일 시스템 검사만 | API 호출 없음 |
| T4 | ~$0 | T1의 init 재사용 | 추가 API 호출 불필요 |
| T5 | ~$0.14 | 권한 설정 변경 시 | 2회 호출 |
| T6 | ~$0.07 | SSH 설정 변경 시 | 크로스머신 필요 |
| T7 | ~$0.14 | 세션 관련 변경 시 | 2회 호출 |
| T8 | ~$0.14 | CI/자동화 도입 시 | 2회 동시 호출 |

**최적화**: T1, T2, T4는 동일한 init 이벤트를 재사용하므로, 한 번의 `claude -p --output-format json` 호출 결과를 파일에 저장하고 3개 테스트에서 공유한다:

```bash
echo "ok" | claude -p --output-format json > /tmp/harness-init.json 2>/dev/null
# T1, T2, T4에서 /tmp/harness-init.json을 읽어서 판정
```
