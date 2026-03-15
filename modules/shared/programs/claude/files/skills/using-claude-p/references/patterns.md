# using-claude-p 사용 패턴

각 패턴은 Claude Code 세션 안팎에서 동일하게 재현 가능한 순수 셸 명령으로 작성한다.

## 패턴 1: 기본 사용 — 인라인 프롬프트 / stdin pipe

가장 기본적인 실행. 단순 질의에 사용한다.

```bash
# 인라인 프롬프트
claude -p "2+2의 결과만 숫자로 답해"
# → 4

# stdin pipe
echo "현재 날짜를 YYYY-MM-DD 형식으로만 출력해" | claude -p
# → 2026-03-15

# 파일 pipe
cat /tmp/prompt.md | claude -p
```

핵심 요소:
- 인라인 프롬프트는 짧은 질의에만 사용 (quote 이슈 방지)
- 긴 프롬프트는 파일로 작성 후 stdin pipe로 전달
- ⚠️ `--allowedTools` 사용 시 인라인 프롬프트가 도구 이름으로 먹힘 → stdin 필수 ([gotchas.md](gotchas.md) #1)

## 패턴 2: 도구 실행 — 권한 우회

도구 사용이 필요한 경우 `--dangerously-skip-permissions` 필수 (비대화형에서는 TTY가 없어 권한 프롬프트 불가).

```bash
echo "hostname 명령을 실행하고 결과만 보고해" | claude -p --dangerously-skip-permissions
# → greenhead-MacBookPro.local
```

도구를 제한하려면 `--allowed-tools`를 조합한다:

```bash
echo "ls /tmp | head -2를 실행해" | claude -p --dangerously-skip-permissions --allowed-tools "Bash,Read"
```

주의:
- `--max-turns 1`이면 도구 실행 불가 (최소 2턴 필요, [gotchas.md](gotchas.md) #2)
- 도구 거부 시 exit code는 여전히 0 ([gotchas.md](gotchas.md) #3)
- `--tools ""`로 빌트인 비활성화해도 MCP는 남아있음 ([gotchas.md](gotchas.md) #5)

## 패턴 3: init 이벤트로 harness 인벤토리 조회

`--output-format json`의 init 이벤트에 전체 harness 정보가 포함된다. 스킬, 도구, MCP, 플러그인 전수 검사에 핵심.

```bash
echo "ok" | claude -p --output-format json | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
init = [d for d in data if isinstance(d, dict) and d.get('type')=='system'][0]
print(f'Session: {init[\"session_id\"]}')
print(f'Skills: {len(init.get(\"skills\", []))}')
print(f'Tools: {len(init.get(\"tools\", []))}')
print(f'MCP servers: {len(init.get(\"mcp_servers\", []))}')
print(f'Plugins: {len(init.get(\"plugins\", []))}')"
```

스킬 이름만 추출:

```bash
echo "ok" | claude -p --output-format json | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
init = [d for d in data if isinstance(d, dict) and d.get('type')=='system'][0]
for s in sorted(init.get('skills', [])):
    print(f'  {s}')"
```

이 패턴이 harness 셀프테스트 T1의 기반이다. [harness-testing.md](harness-testing.md) T1 참조.

## 패턴 4: 세션 체이닝 — `--resume`

여러 `-p` 호출 간 컨텍스트를 유지한다. 첫 호출에서 session_id를 추출하고, 후속 호출에서 `--resume`으로 이어간다.

```bash
# 1단계: 첫 호출 — session_id 추출
SESSION_ID=$(echo "나의 비밀 코드는 XRAY42야" | claude -p --output-format json | python3 -c "
import sys, json; data=json.loads(sys.stdin.read())
for item in data:
    if isinstance(item, dict) and item.get('type')=='system':
        print(item['session_id']); break")

# 2단계: 후속 호출 — 이전 세션 이어가기
echo "내 비밀 코드가 뭐였어?" | claude -p --resume "$SESSION_ID"
# → "XRAY42"라고 말씀하셨습니다
```

활용처:
- 다단계 작업을 여러 `-p` 호출로 분할
- 첫 호출에서 컨텍스트 설정 → 후속 호출에서 실행
- 스테이트풀한 검증 시나리오

## 패턴 5: SSH 경유 크로스머신

원격 머신에서 `claude -p`를 실행하는 패턴. 3중 중첩 quote 문제를 피하기 위해 **stdin pipe가 유일한 안정 패턴**.

### 기본 패턴

```bash
echo "hostname을 실행하고 결과만 출력해" | ssh minipc 'claude -p --dangerously-skip-permissions'
# → greenhead-minipc
```

### 파일 기반 프롬프트

```bash
# 로컬에서 프롬프트 작성 → SSH stdin으로 전달
cat > /tmp/remote-prompt.md <<'PROMPT'
hostname과 uptime을 실행하고 결과를 보고한다.
PROMPT

cat /tmp/remote-prompt.md | ssh minipc 'claude -p --dangerously-skip-permissions'
```

### 주의사항

- SSH non-login shell에서 alias(`c`)가 로드되지 않음 → `claude` full path 사용 필수
- 3중 중첩 quote를 시도하지 말 것 → 반드시 stdin pipe 패턴 사용
- MiniPC sshd 180초 무응답 시 연결 해제 → 장시간 실행 시 `ssh -o ServerAliveInterval=30` 추가
- 자세한 gotchas: [gotchas.md](gotchas.md) #15, #16, #32

## 패턴 6: pipe chain — 출력을 다음 입력으로

`claude -p`의 텍스트 출력을 다음 `claude -p` 호출의 입력으로 연결한다.

```bash
echo "3+7의 결과만 숫자로" | claude -p | xargs -I{} sh -c 'echo "{}에 5를 곱한 결과만 숫자로" | claude -p'
# → 50 (10 * 5)
```

주의:
- 중간 출력이 예상과 다를 수 있으므로, 결과 형식을 명확히 지시해야 한다 ("숫자로만", "JSON으로만" 등)
- 각 호출은 독립 세션이다 (컨텍스트 공유 없음). 컨텍스트 유지가 필요하면 패턴 4 (세션 체이닝) 사용

## 패턴 7: 동시 실행

같은 디렉토리에서 여러 `claude -p` 프로세스를 동시 실행할 수 있다. 세션 파일 충돌을 방지하기 위해 `--no-session-persistence` 사용.

```bash
echo "echo proc1" | claude -p --dangerously-skip-permissions --no-session-persistence &
echo "echo proc2" | claude -p --dangerously-skip-permissions --no-session-persistence &
wait
# 두 프로세스 모두 정상 완료
```

활용처:
- 여러 테스트를 병렬로 실행
- 다른 프롬프트를 동시에 평가
- CI에서 독립적인 검증 작업 병렬화

## 패턴 8: JSON 결과 파싱

`--output-format json` 출력에서 필요한 정보를 추출하는 패턴.

### 텍스트 응답 추출

```bash
echo "2+3" | claude -p --output-format json | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
result = [d for d in data if d.get('type')=='result'][0]
print(result['result'])"
# → 5
```

### result subtype 확인

```bash
echo "prompt" | claude -p --output-format json | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
result = [d for d in data if d.get('type')=='result'][0]
print(f'subtype: {result.get(\"subtype\")}')
print(f'is_error: {result.get(\"is_error\", False)}')"
```

subtype 종류: `success`, `error_max_turns`, `error_max_budget_usd`, `error_during_execution` 등 6종.
⚠️ `success`와 `error_during_execution`만 exit code가 다르다 (나머지는 모두 0). [gotchas.md](gotchas.md) #29 참조.

### stream-json (JSONL) 파싱

```bash
echo "hello" | claude -p --output-format stream-json | while IFS= read -r line; do
  type=$(echo "$line" | python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('type',''))")
  echo "Event: $type"
done
# Event: system
# Event: assistant
# Event: rate_limit_event
# Event: result
```

---

## 빠른 참조 표

| 상황 | 패턴 | 명령 요약 |
|------|------|-----------|
| 단순 질의 | 1 | `echo "prompt" \| claude -p` |
| 도구 실행 | 2 | `echo "prompt" \| claude -p --dangerously-skip-permissions` |
| harness 인벤토리 | 3 | `echo "ok" \| claude -p --output-format json` → init 파싱 |
| 세션 이어가기 | 4 | `--resume SESSION_ID` |
| 원격 실행 | 5 | `echo "prompt" \| ssh host 'claude -p ...'` |
| 연쇄 호출 | 6 | `claude -p \| ... \| claude -p` |
| 병렬 실행 | 7 | `claude -p ... &` + `--no-session-persistence` |
| 결과 파싱 | 8 | `--output-format json` → python3 파싱 |
