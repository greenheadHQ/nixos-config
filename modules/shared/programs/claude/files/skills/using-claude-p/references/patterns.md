# using-claude-p 사용 패턴

각 패턴은 Claude Code 세션 안팎에서 동일하게 재현 가능한 순수 셸 명령으로 작성한다.

JSON/JSONL 호출은 stdout, stderr, 업무 산출물을 분리한다. parser 앞 `2>&1`, 판정 pipeline의
`head`/`tail`, 원 exit를 가리는 후속 `echo $?`를 금지한다. pipeline은 `set -o pipefail`과 zsh
`pipestatus`로 Claude exit를 즉시 보존한다.

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
- ⚠️ `--allowed-tools` 사용 시 인라인 프롬프트가 도구 이름으로 먹힘 → stdin 필수 ([gotchas.md](gotchas.md) #1)

## 패턴 2: 도구 실행 — 제한 여부 선택

도구 제한이 필요 없을 때만 `--dangerously-skip-permissions`를 단독 사용한다.

```bash
echo "hostname 명령을 실행하고 결과만 보고해" | claude -p --dangerously-skip-permissions
# → greenhead-MacBookPro.local
```

도구를 제한하려면 skip-permissions 없이 variadic flag 뒤 prompt를 stdin으로 전달한다.

```bash
echo "ls /tmp | head -2를 실행해" | claude -p --allowed-tools "Bash,Read"
```

주의:
- `--dangerously-skip-permissions`와 `--allowed-tools` 병용은 allowlist를 구조적으로 무효화하므로 금지
- `--max-turns 1`이면 도구 실행 불가 (최소 2턴 필요, [gotchas.md](gotchas.md) #2)
- 도구 거부 시 exit code는 여전히 0 ([gotchas.md](gotchas.md) #3)
- `--tools ""`로 빌트인 비활성화해도 MCP는 남아있음 ([gotchas.md](gotchas.md) #5)

## 패턴 3: init 이벤트로 harness 인벤토리 조회

`--output-format json`의 init 이벤트에 전체 harness 정보가 포함된다. 스킬, 도구, MCP, 플러그인 전수 검사에 핵심.

```zsh
set -o pipefail
echo "ok" | claude -p --output-format json > /tmp/claude-init.json 2> /tmp/claude-init.stderr
claude_rc=$pipestatus[2]
# 검증 실패가 후속 파싱을 막도록 && 게이트로 연결한다 (실패해도 다음 줄이 실행되는 단독 test 금지)
[ "$claude_rc" -eq 0 ] && test -s /tmp/claude-init.json && python3 -c "
import sys, json
data, _ = json.JSONDecoder().raw_decode(sys.stdin.read().lstrip())  # 후행 비-JSON 라인 내성
items = data if isinstance(data, list) else [data]
# subtype 가드 필수 — system 이벤트는 다중 매치다 (thinking_tokens 가변 삽입, stream-json은
# hook 이벤트가 init보다 선행; gotchas.md #17)
init = next(d for d in items if isinstance(d, dict)
            and d.get('type')=='system' and d.get('subtype')=='init')
print(f'Session: {init[\"session_id\"]}')
print(f'Skills: {len(init.get(\"skills\", []))}')
print(f'Tools: {len(init.get(\"tools\", []))}')
print(f'MCP servers: {len(init.get(\"mcp_servers\", []))}')
print(f'Plugins: {len(init.get(\"plugins\", []))}')" < /tmp/claude-init.json
```

스킬 이름만 추출:

```bash
python3 -c "
import sys, json
data, _ = json.JSONDecoder().raw_decode(sys.stdin.read().lstrip())  # 후행 비-JSON 라인 내성
items = data if isinstance(data, list) else [data]
init = next(d for d in items if isinstance(d, dict)
            and d.get('type')=='system' and d.get('subtype')=='init')
for s in sorted(init.get('skills', [])):
    print(f'  {s}')" < /tmp/claude-init.json
```

이 패턴이 harness 셀프테스트 T1의 기반이다. [harness-testing.md](harness-testing.md) T1 참조.

## 패턴 4: 세션 체이닝 — `--resume`

여러 `-p` 호출 간 컨텍스트를 유지한다. 첫 호출에서 session_id를 추출하고, 후속 호출에서 `--resume`으로 이어간다.

```bash
# 1단계: 첫 호출 — session_id 추출
echo "나의 비밀 코드는 XRAY42야" | claude -p --output-format json \
  > /tmp/claude-session.json 2> /tmp/claude-session.stderr
SESSION_ID=$(python3 -c "
import sys, json; data, _ = json.JSONDecoder().raw_decode(sys.stdin.read().lstrip()); items=data if isinstance(data,list) else [data]
for item in items:
    if isinstance(item, dict) and item.get('type')=='system':
        print(item['session_id']); break" < /tmp/claude-session.json)
# 2단계: 후속 호출 — SESSION_ID 검증을 && 게이트로 연결 (빈 값이면 resume을 실행하지 않는다)
test -n "$SESSION_ID" && \
  echo "내 비밀 코드가 뭐였어?" | claude -p --resume "$SESSION_ID"
# → "XRAY42"라고 말씀하셨습니다
```

활용처:
- 다단계 작업을 여러 `-p` 호출로 분할
- 첫 호출에서 컨텍스트 설정 → 후속 호출에서 실행
- 스테이트풀한 검증 시나리오

`--resume` help surface는 2.1.206에서 확인했지만 context chaining runtime은 재검증 미수행
(v2.1.202 기준 서술 유지). v2.1.223부터 두 호출을 서로 다른 디렉토리에서 실행해도 된다 —
세션 id는 머신 전역에서 조회된다 (그 이전엔 같은 프로젝트 디렉토리·git worktree에서만 조회;
공식 headless 문서, 2026-08-15 확인). worktree를 오가는 자동화에서 유용하다.

## 패턴 5: SSH 경유 크로스머신

원격 머신에서 `claude -p`를 실행하는 패턴. 3중 중첩 quote 문제를 피하기 위해 stdin pipe가 유일한 안정 패턴.

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

# outer timeout으로 원격 hang 시 무기한 대기를 방지한다 (exit 124 = timeout; macOS는 coreutils timeout 필요)
# ⚠️ Bash tool 경유 시 이 900초 예산은 하네스 foreground 상한보다 크다 — background 발사 또는
# timeout 파라미터 명시가 필수다 (SKILL.md "호출 상한 (Bash tool 경유)" 참조).
cat /tmp/remote-prompt.md | timeout 900 ssh minipc 'claude -p --dangerously-skip-permissions' \
  > /tmp/remote-result.txt 2> /tmp/remote-result.stderr
test -s /tmp/remote-result.txt
```

### 주의사항

- SSH non-login shell에서 alias(`c`)가 로드되지 않음 → `claude` full path 사용 필수
- 3중 중첩 quote를 시도하지 말 것 → 반드시 stdin pipe 패턴 사용
- MiniPC sshd 180초 무응답 시 연결 해제 → `ssh -o ServerAliveInterval=30` 추가
- outer timeout은 위 "파일 기반 프롬프트" 예제처럼 호출자가 직접 적용한다 — "기본 패턴"의 최소 예제에는 포함되어 있지 않다.
- 무출력 약 10분 뒤 완료된 실측이 있다. 무출력만으로 중단하지 않는다 — 단 Bash tool foreground로
  발사하면 하네스 상한이 그보다 먼저 발화하므로, 10분 대기가 필요한 호출은 background로 발사한다
  (SKILL.md "호출 상한 (Bash tool 경유)"). 메커니즘 후보: background subagent 대기 상한이 기본
  10분이다 (v2.1.182+, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`로 조정, `0`이면 무제한 — 공식
  headless 문서. 해당 관측이 이 경로였는지는 미확인이라 인과 단정 금지). 파생 규칙: outer
  timeout은 이 상한 + 여유보다 크게 잡는다 (현행 900초 = 600초 + 300초).
- 프로세스 생존만으로 정상이라 판정하지 않고 완료 후 `test -s`로 기대 산출물을 확인한다.
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
- pipe chain runtime은 재검증 미수행 (v2.1.202 기준 서술 유지).
- 위 직결 예제는 빠른 실험 전용이다. 업무 성공 판정이 필요하면 이 패턴 대신 각 호출의 출력을 파일로 분리하고 exit·기대 marker를 검증한다 (SKILL.md 셸 transport 계약 참조).

## 패턴 7: 동시 실행과 fan-out 오케스트레이션

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

재검증 미수행 (v2.1.202 기준 서술 유지): 같은 directory 동시 실행 안정성과
`--no-session-persistence`의 충돌 방지 효과.

<<<<<<< HEAD
### fan-out 상한 — 위협모형 2개를 구분한다 (2026-08-15, 2.1.233)

[A] in-process Task/subagent 축 (세션 안에서 Task 도구로 위임하는 subagent):
- 동시 실행 캡: 폴백 기본 20 (`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` 오버라이드; 초과 시
  `Concurrent subagent limit reached ... Do not retry.`).
- 중첩 depth 캡: 폴백 기본 3 (`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` 오버라이드).
- 위 폴백값은 원격 feature flag가 우선하고 캡 체크 자체가 조건부 게이트 아래 있다 — 고정
  상수로 믿지 말고 설치 번들 grep 또는 실측으로 재확인한다. `CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION`은
  2.1.224에서 제거되어 설정해도 무효다 (gotchas.md "버전별 변천").
- `--max-budget-usd` 도달 시 새 spawn 거부 + 실행 중 background agent 중단 (2.1.217+).

[B] 프로세스 fan-out 축 (Bash로 발사하는 `claude -p`/`nohup` 자식): 위 캡 어느 것에도
계상되지 않는다 — depth·동시성은 프로세스 안에서만 센다. depth=1을 export해도 자식 프로세스의
Task 위임만 막힐 뿐 프로세스 증식 자체는 못 막고, 부모의 `--max-budget-usd`도 Bash 자식의
지출을 캡하지 않는다. "depth 캡을 걸었으니 안전"은 거짓 안심이다. 방어는 규약으로 한다:

- 위임 프롬프트에 금지 절을 복붙한다: "headless 자식 프로세스(`claude -p`·`codex exec`)·
  `nohup`·백그라운드 런처 스크립트 생성 금지. 오케스트레이션은 부모 1계층에서만."
- 발사하는 자식에는 고유 마커(작업 디렉토리 경로 등)를 심고, 정리는 그 마커로만 `pkill`한다.
  `pkill -f "claude -p"`는 Bash tool 자신의 래퍼 셸(snapshot eval 라인)까지 매치한다 (실측).
- 종료 사다리: TaskStop → 마커 기반 pkill → 런처 스크립트 개명(재발사 차단) → 세션 간 shutdown
  요청. 에이전트 completed ≠ 자식 프로세스 종료 — TaskStop이
  `Task ... is not running (status: completed)`를 반환해도 자식은 살아 있을 수 있다 (실측).

### 다수 병렬의 배리어·수집 계약 (미검증 — 세션 실측 8건 기반)

Bash tool `run_in_background`의 완료 알림은 best-effort다 (세션 집계: 42건 중 약 21%가 알림
없이 종료). 단일 실행은 알림으로 충분하지만 다수 병렬은:

- 발사 스크립트가 종료 시 rc를 `$OUT.rc` 마커 파일로 남긴다 (배리어·감사의 정본).
- 배리어는 Monitor until-loop + `test -f "$OUT.rc"` 전건 확인으로 만든다.
- 알림 1건을 받을 때마다 결과 디렉토리 전체를 일괄 재집계해 미알림 유닛까지 회수한다.
- 장시간 fan-out은 (task ID + 결과 경로 + 완료 시 행동)을 담은 fallback 재개 메모를 남긴다.
- mktemp 경로는 추측·wildcard glob이 아니라 출력 첫 줄/sentinel 파일에서 파싱하고, 프로세스
  수를 완료 신호로 쓰지 않는다.
>>>>>>> 2642af82 (docs(skills): 실전 팁·패턴 반영 — 한도 회수·발동 회귀·조립 계약·격리 체크리스트)

## 패턴 8: JSON 결과 파싱

`--output-format json` 출력에서 필요한 정보를 추출하는 패턴.

### 텍스트 응답 추출

```zsh
set -o pipefail
echo "2+3" | claude -p --output-format json > /tmp/claude-result.json 2> /tmp/claude-result.stderr
claude_rc=$pipestatus[2]
python3 -c "
import sys, json
data, _ = json.JSONDecoder().raw_decode(sys.stdin.read().lstrip())  # 후행 비-JSON 라인 내성
items = data if isinstance(data, list) else [data]
result = [d for d in items if isinstance(d, dict) and d.get('type')=='result'][0]
if result.get('subtype') != 'success' or result.get('is_error', False):
    raise SystemExit('result event is not a successful task result')
print(result.get('result', ''))" < /tmp/claude-result.json
test "$claude_rc" -eq 0
# → 5
```

### result subtype 확인

```bash
python3 -c "
import sys, json
data, _ = json.JSONDecoder().raw_decode(sys.stdin.read().lstrip())  # 후행 비-JSON 라인 내성
items = data if isinstance(data, list) else [data]
result = [d for d in items if isinstance(d, dict) and d.get('type')=='result'][0]
print(f'subtype: {result.get(\"subtype\")}')
print(f'is_error: {result.get(\"is_error\", False)}')" < /tmp/claude-result.json
```

정상 성공 경로는 top-level 배열 또는 객체일 수 있으므로 위 예제처럼 정규화한 뒤 판정한다
(실측 런타임은 배열이고 help·공식 문서는 단일 객체를 표기한다 — 어느 쪽도 가정하지 않는다.
이벤트 수는 런마다 가변 — 2.1.233 실측, 특정 개수 기대 금지),
`subtype=success`, `is_error=false`, exit 0이다. auth 실패 경로는 `subtype=success`,
`is_error=true`, exit 1도 가능하다. subtype 목록과 exit mapping을 exhaustive 계약으로 사용하지
않는다. [gotchas.md](gotchas.md) #6, #29 참조.

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

stream-json wire shape는 재검증 미수행 (v2.1.202 기준 서술 유지). parser는 stderr를 섞지 않는다.
소비 루프가 느리면 claude는 종료 전 큐에 남은 출력의 drain을 기다린다 — 대기는 잔량에 비례하며
최대 30초 (v2.1.214+; 그 이전엔 약 2초라 대형 응답 말미가 잘릴 수 있었다 — 공식 headless 문서).

## 패턴 9: 미설치 플러그인 스킬을 stdin 주입으로 우회

개발 중이거나 미배포 플러그인의 스킬을 테스트할 때, 스킬 내용을 프롬프트에 직접 주입한다.

### 기본 패턴

```bash
# 1. 프롬프트 작성 (에이전트에게 줄 지시)
cat > /tmp/e2e-prompt.md <<'PROMPT'
아래는 {skill-name} 스킬의 지시서이다. 이 지시서를 정확히 따라 실행하라.
{사용자 입력 또는 URL}
PROMPT

# 2. 스킬 지시서 + 에이전트 지시서 + 참조 파일을 합성하여 주입
#    - e2e-prompt.md: 에이전트에게 주는 지시 (what to do)
#    - SKILL.md: 스킬 원문 (how to do, 컨텍스트)
#    - agent.md + skill-local refs: 추가 컨텍스트
#    - shared refs: 대상 skill이 의존하는 sibling skill의 references
#    순서: 지시 → 컨텍스트 (LLM이 지시를 먼저 인지하도록)
CAT_FILES=(/tmp/e2e-prompt.md "skills/{name}/SKILL.md" "agents/{name}.md")

# skill-local references — find 기반 (bash/zsh 공통)
# zsh 기본 `nomatch` 옵션은 `shopt -s nullglob` 로 꺼지지 않으므로(zsh builtin이 아님),
# `_refs=(.../*.md)` 에서 매칭 실패 시 스크립트 전체가 abort된다.
# find + IFS=$'\n' 배열 split 으로 shell glob 의존을 제거한다.
# (일부 skill 은 references/ 디렉토리가 비어 있거나 존재하지 않음)
_refs_dir="skills/{name}/references"
if [ -d "$_refs_dir" ]; then
  _old_ifs="$IFS"
  IFS=$'\n'
  _refs=( $(find "$_refs_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null) )
  IFS="$_old_ifs"
  [ "${#_refs[@]}" -gt 0 ] && CAT_FILES+=("${_refs[@]}")
fi

# shared refs 의존 목록 (sibling skill references that {name} relies on):
# - create-issue  →  skills/write-handoff/references/llm-friendly-checklist.md
# - create-issue  →  skills/write-handoff/references/sanitization-checklist.md (공개 S1~S4 정본)
# 새 의존 추가 시 이 case 블록 갱신
case "{name}" in
  create-issue)
    # 두 정본은 필수 계약이다 — 부재 시 검열 규칙이 빠진 채 진행하지 않도록 명시적으로 실패한다.
    for _shared_ref in \
      "skills/write-handoff/references/llm-friendly-checklist.md" \
      "skills/write-handoff/references/sanitization-checklist.md"; do
      [ -f "$_shared_ref" ] || { echo "missing required shared reference: $_shared_ref" >&2; exit 1; }
      CAT_FILES+=("$_shared_ref")
    done
    ;;
esac

# stdin 상한(10MB) 사전 게이트 — 합쳐서 재는 것이 정본이다 (개별 파일은 작아도 합산이 넘칠 수 있다)
cat "${CAT_FILES[@]}" > /tmp/injected-prompt.md
[ "$(wc -c < /tmp/injected-prompt.md)" -le 10000000 ] || {
  echo "stdin over 10MB — 파일 경로 참조 방식으로 전환한다 (gotchas #40)" >&2; exit 1; }

MY_TOKEN="xxx" claude -p --output-format text --dangerously-skip-permissions \
  < /tmp/injected-prompt.md > /tmp/result.md 2>/tmp/stderr.txt
test -s /tmp/result.md
```

### 주의사항

- piped stdin 상한은 10MB (공식 계약). 발사 전 `wc -c` 게이트로 자르고 초과분은 파일 경로 참조로 전환한다 ([gotcha #40](gotchas.md) 참조)
- `--dangerously-skip-permissions`는 `--allowed-tools` 제한을 무시함 ([gotcha #3](gotchas.md) 참조)
- 커스텀 환경변수는 `VAR=val claude -p` 형태로 전달 ([gotcha #39](gotchas.md) 참조)
- MCP 도구 사용 시 해당 MCP 서버가 세션에서 활성화되어야 함 ([gotcha #5](gotchas.md) 참조)

⚠️ 보안 주의: stdin으로 주입하는 파일 내용이 신뢰할 수 있는 출처인지 확인하라. `--dangerously-skip-permissions`와 결합 시 파일 내 prompt injection이 임의 명령 실행으로 이어질 수 있다. 신뢰할 수 없는 입력에는 `--dangerously-skip-permissions` 없이 `--allowed-tools`로 도구를 제한하라:

```bash
# 신뢰할 수 없는 입력 시 안전한 패턴 (--dangerously-skip-permissions 미사용)
cat untrusted-skill.md | claude -p --allowed-tools "Read,Grep,Glob" --output-format text
```

대용량 stdin·plugin indexing runtime은 재검증 미수행 (v2.1.202 기준 서술 유지).

## 패턴 10: JSON Schema 구조화 출력

```bash
SCHEMA='{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"]}'
set -o pipefail
echo "현재 변경을 한 문장으로 요약해" | claude -p \
  --output-format json --json-schema "$SCHEMA" \
  > /tmp/structured.json 2> /tmp/structured.stderr
claude_rc=${PIPESTATUS[1]}
[ "$claude_rc" -eq 0 ] && test -s /tmp/structured.json && python3 -c "
import sys, json
data, _ = json.JSONDecoder().raw_decode(sys.stdin.read().lstrip())  # 후행 비-JSON 라인 내성
items = data if isinstance(data, list) else [data]
results = [d for d in items if isinstance(d, dict) and d.get('type')=='result']
# assert는 python3 -O / PYTHONOPTIMIZE=1에서 통째로 제거되므로 판정에 쓰지 않는다.
if not results:
    raise SystemExit('no result event')
r = results[-1]
if r.get('subtype') != 'success' or r.get('is_error', False):
    raise SystemExit('result is not successful')
if r.get('terminal_reason') not in (None, 'completed'):
    raise SystemExit(f\"abnormal termination: {r.get('terminal_reason')}\")
if r.get('permission_denials'):
    raise SystemExit('tool permission denied (exit 0이어도 실패)')
# --json-schema를 넘긴 호출에 한해: 검증된 구조화 출력은 result의 structured_output 키에 담긴다
# (2.1.233 실측 — 미지정 호출에는 키 자체가 없으므로 무조건 존재 단언 금지).
so = r.get('structured_output')
if not isinstance(so, dict) or 'summary' not in so:
    raise SystemExit('structured_output missing or schema keys absent')
print('structured output OK')" < /tmp/structured.json
```

`--json-schema`는 2.1.206 help에 있고, 무효 schema가 모델 호출 전에 즉시 실패하는 동작은
v2.1.205에서 실측했다. subtype/is_error만 보면 스키마 미충족을 통과시키는 거짓 양성 경로가
있으므로, 스키마를 넘긴 호출은 `structured_output` 존재·필수 키까지 검사한다. 그 외 성공
payload의 세부 필드는 고정하지 말고 패턴 8처럼 `type=result`를 찾는다.

## 패턴 11: `--bare` 격리 실행

```bash
test -n "$ANTHROPIC_API_KEY" || echo "FAIL: API key required for --bare"
set -o pipefail
echo "주입한 prompt만 사용해 한 줄로 답해" | \
  env ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" claude -p --bare --output-format json \
  > /tmp/bare.json 2> /tmp/bare.stderr
claude_rc=${PIPESTATUS[1]}
# json 출력이므로 test -s만으로는 부족하다 — 패턴 8과 동일하게 result/success까지 파싱해 판정한다.
[ "$claude_rc" -eq 0 ] && test -s /tmp/bare.json
```

`--bare`는 hooks, LSP, plugin sync, attribution, auto-memory, background prefetch, keychain read,
CLAUDE.md auto-discovery를 skip하고 `CLAUDE_CODE_SIMPLE=1`을 설정한다. auth는 API key 또는
settings `apiKeyHelper` 경로가 필요하며, skills는 계속 resolve된다 (2.1.206 help).

## 패턴 12: session ID 고정·fork

```bash
SESSION_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
set -o pipefail
echo "첫 단계" | claude -p --session-id "$SESSION_ID" \
  > /tmp/session-first.txt 2> /tmp/session-first.stderr
# 첫 호출의 exit·산출물 검증을 통과해야만 fork를 실행한다 (text 출력이므로 result 이벤트 검증은 불가)
[ "${PIPESTATUS[1]}" -eq 0 ] && test -s /tmp/session-first.txt && \
echo "이전 context에서 새 session으로 분기해" | \
  claude -p --resume "$SESSION_ID" --fork-session \
  > /tmp/session-fork.txt 2> /tmp/session-fork.stderr
[ "${PIPESTATUS[1]}" -eq 0 ] && test -s /tmp/session-fork.txt
```

`--session-id`의 UUID 요구와 `--fork-session` surface는 2.1.206 help에서 확인했다. 실제 context
round-trip은 재검증 미수행 (v2.1.202 기준 서술 유지).

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
| 미설치 스킬 stdin 주입 | 9 | `cat SKILL.md agent.md \| claude -p` |
| 구조화 출력 | 10 | `--json-schema` + JSON event parser |
| 최소화 실행 | 11 | API key/helper + `--bare` |
| session 고정·분기 | 12 | `--session-id` / `--fork-session` |
