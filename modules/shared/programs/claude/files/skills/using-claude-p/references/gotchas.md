# 숨겨진 동작

공식 문서에 없는 `claude -p` (비대화형 모드) 동작을 카테고리별로 정리합니다.

> 항목 번호(#1, #23 등)는 최초 발견 순서를 유지하며, 카테고리별로 그룹화되어 있다.
> 번호 순서대로가 아닌 카테고리순으로 정렬되어 있으므로, 특정 번호를 찾으려면 페이지 검색을 사용한다.

## 목차

- [입력 (Input)](#입력-input)
- [출력 (Output)](#출력-output)
- [제어/플래그 (Control)](#제어플래그-control)
- [권한 (Permissions)](#권한-permissions)
- [도구/스킬 (Tools)](#도구스킬-tools)
- [hooks](#hooks)
- [세션/컨텍스트 (Session)](#세션컨텍스트-session)
- [SSH](#ssh)
- [기타 (Miscellaneous)](#기타-miscellaneous)

---

## 입력 (Input)

### #1. `--allowedTools` 뒤에 인라인 프롬프트가 도구 이름으로 파싱됨

```bash
# ❌ 잘못된 사용
claude -p --dangerously-skip-permissions --allowedTools "Bash,Read" "ls /tmp 실행해"
# → Error: Input must be provided either through stdin or as a prompt argument
# "ls /tmp 실행해"가 도구 이름으로 먹힘

# ✅ 올바른 사용 — stdin 필수
echo "ls /tmp | head -2를 실행해" | claude -p --dangerously-skip-permissions --allowed-tools "Bash,Read"
```

### #23. 빈 줄 vs 빈 문자열 입력 차이

```bash
echo "" | claude -p          # 빈 줄 전송 → hang (무한 대기, 출력 없음)
claude -p ""                 # 빈 문자열 인수 → 에러, exit 1
```

⚠️ `echo "" | claude -p`는 "유효 입력"이 아니라 무한 대기 상태에 빠진다 (v2.1.76 실측; v2.1.116 재검증 미수행). 두 패턴 모두 사용하지 않는다.

### #24. 인라인 인수만 쓸 때 stdin이 tty면 EOF 대기하며 hang

`claude -p "prompt"` 실행 시 stdin이 tty로 열려있으면 EOF를 기다리며 멈춤. 스크립트에서는 stdin을 `/dev/null`로 리다이렉트하거나 pipe를 사용한다.

```bash
echo "prompt" | claude -p    # ✅ pipe 사용
claude -p "prompt" < /dev/null  # ✅ stdin 닫기
```

### #39. 커스텀 환경변수는 `VAR=val claude -p` 형태로 명시적 전달 필요

`claude -p` 내부 에이전트는 `.env` 파일을 자동으로 읽지 않는다. 에이전트가 환경변수를 참조하려면 프로세스 시작 시 환경변수가 설정되어 있어야 한다.

```bash
# ❌ .env 파일 자동 로드 안 됨
echo "FIGMA_TOKEN=xxx" > .env
claude -p "REST API 호출해줘"
# → 에이전트가 .env를 자동으로 읽지 않음

# ✅ 명시적 전달 (가장 확실)
MY_TOKEN="xxx" claude -p "REST API 호출해줘"

# ✅ export 후 실행 (동작하지만 셸 세션에 남음)
export MY_TOKEN="xxx"
claude -p "REST API 호출해줘"

# ✅ 에이전트가 직접 .env 파일을 읽도록 프롬프트에 지시
# ⚠️ --dangerously-skip-permissions 필수 → 에이전트가 .env 내 모든 credential에 접근 가능
echo "먼저 .env 파일에서 MY_TOKEN을 읽은 뒤 사용하라" | claude -p --dangerously-skip-permissions
```

⚠️ 보안 주의: `VAR=val command` 형태는 셸 히스토리와 `/proc/<pid>/environ`에 credential이 노출된다. 프로덕션에서는 secrets manager 또는 `read -s VAR && VAR="$VAR" claude -p ...` 패턴을 사용하라. `.env` + `--dangerously-skip-permissions` 조합은 에이전트가 파일 내 모든 secret을 읽고 임의 명령으로 외부 전송할 수 있으므로, 신뢰할 수 없는 환경에서는 사용하지 마라.

v2.1.81 실측 (v2.1.116 재검증 미수행). `CLAUDE_CODE_MAX_RETRIES`, `ANTHROPIC_API_KEY` 등 Claude Code 내장 환경변수는 정상 인식됨.

### #40. stdin 파이프 대용량 입력 정상 동작 확인

SKILL.md + 에이전트 지시서 + 참조 파일 다수를 합산한 대용량 stdin을 파이프로 전달해도 정상 실행됨을 확인했다. 실제 입력 분량은 `wc -l`로 측정하라.

```bash
# 대용량 프롬프트 정상 동작 (실측 기준: SKILL.md + 에이전트 + 참조 파일 합산)
cat skill.md agent.md references.md | claude -p --output-format text > result.md
```

⚠️ 극단적 상한은 미확인. CLI → Node.js 런타임 → API context window로 이어지는 다층 파이프라인 중 어느 레이어에서 상한이 걸리는지 미검증. 프로덕션 파이프라인에서는 적절한 청킹 전략을 병행하라. v2.1.81 실측.

### #36. `allowedTools` 패턴에서 공백이 중요

```bash
--allowed-tools "Bash(git diff *)"   # git diff 로 시작하는 명령만
--allowed-tools "Bash(git diff*)"    # git diff-index 등도 매칭됨!
```

---

## 출력 (Output)

### #6. JSON vs JSONL 출력 형식

```bash
# --output-format json → JSON 배열 (전체가 하나의 배열)
echo "2+3" | claude -p --output-format json | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())  # list
print(f'Type: {type(data).__name__}, Length: {len(data)}')
for item in data:
    print(f'  {item.get(\"type\")}/{item.get(\"subtype\", \"-\")}')"
# Type: list, Length: 4
#   system/init
#   assistant/-
#   rate_limit_event/-
#   result/success

# --output-format stream-json → JSONL (라인별 독립 JSON)
echo "hello" | claude -p --output-format stream-json | wc -l
# 4 (system, assistant, rate_limit_event, result 각 1줄)
```

파싱 방식이 다르므로 주의: `json`은 `json.loads(전체)`, `stream-json`은 라인별 `json.loads(line)`.

### #17. init 이벤트에 전체 harness 인벤토리 포함

```bash
echo "ok" | claude -p --output-format json | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
init = [d for d in data if isinstance(d, dict) and d.get('type')=='system'][0]
print(f'Skills: {len(init.get(\"skills\", []))}')
print(f'Tools: {len(init.get(\"tools\", []))}')
print(f'MCP: {len(init.get(\"mcp_servers\", []))}')
print(f'Plugins: {len(init.get(\"plugins\", []))}')"
# Skills: 43, Tools: 40, MCP: 4, Plugins: 3
```

이 패턴으로 harness 전수 검사가 가능하다. [harness-testing.md](harness-testing.md) T1 참조.

### #22. `-p`에서 `--verbose`/`--debug`는 stderr에 아무것도 출력 안 함

```bash
echo "hello" | claude -p --verbose 2>/tmp/stderr.log
cat /tmp/stderr.log  # 비어 있음

# 디버그 로그가 필요하면 --debug-file 사용
echo "hello" | claude -p --debug-file /tmp/debug.log
cat /tmp/debug.log  # 상세 로그 출력
```

---

## 제어/플래그 (Control)

### #2. `--max-turns 1`은 도구 실행 불가

도구 사용에 최소 2턴 필요 (호출 1턴 + 결과 수신 1턴).

```bash
echo "ls /tmp | head -3" | claude -p --dangerously-skip-permissions --max-turns 1
# Error: Reached max turns (1)
```

도구 실행이 필요하면 `--max-turns 2` 이상을 지정한다.

### #4. `--max-budget-usd` 초과도 exit code 0

```bash
echo "아주 긴 에세이를 5000단어로 써줘" | claude -p --max-budget-usd 0.001; echo "EXIT: $?"
# Error: Exceeded USD budget (0.001)EXIT: 0
```

예산 초과를 감지하려면 exit code가 아닌 `--output-format json`의 result subtype을 확인해야 한다.

### #18. `--max-turns`는 `--help`에 표시되지 않는 숨겨진 플래그

`claude -p --help` 출력에 `--max-turns`가 없지만 실제로 동작한다. ⚠️ `CLAUDE_CODE_MAX_TURNS` 환경변수는 v2.1.76 바이너리에 존재하지 않음 (실측 + 소스 분석으로 확인). CLI flag `--max-turns`가 유일한 제어 수단이다.

### #19. `--max-turns` 도달 시 `is_error: false`

result subtype은 `error_max_turns`이지만 `is_error: false` — 에러가 아닌 정상 종료 취급. exit code도 0.

### #20. `--cwd` 플래그 존재하지 않음

작업 디렉토리를 변경하려면 `cd dir && claude -p` 패턴이 유일한 방법.

```bash
# ❌ 존재하지 않음
claude -p --cwd /path/to/project "prompt"

# ✅
cd /path/to/project && echo "prompt" | claude -p
```

### #21. `--output-file` / `-o` 플래그 존재하지 않음

shell redirect를 사용해야 한다.

```bash
# ❌ 존재하지 않음
claude -p -o result.txt "prompt"

# ✅
echo "prompt" | claude -p > result.txt
```

---

## 권한 (Permissions)

### #3. 권한 없이 도구 사용 시 조용히 거부, exit code 0

```bash
echo "ls /tmp 실행해줘" | claude -p; echo "EXIT: $?"
# "허용된 작업 디렉토리 범위 밖..." EXIT: 0
```

도구를 못 썼는데도 에러가 아닌 정상 종료. 실패를 감지하려면 출력 내용을 파싱해야 한다.

⚠️ `--dangerously-skip-permissions` + `--allowedTools` 상호작용: `--dangerously-skip-permissions`는 `--allowedTools` 제한을 완전히 무시한다. `--allowedTools "Read"`로 Bash를 제한하더라도 `--dangerously-skip-permissions`가 있으면 Bash가 제한 없이 사용 가능하다. 도구를 실제로 제한하려면 `--dangerously-skip-permissions` 없이 `--allowedTools`를 단독 사용하라. v2.1.81 실측.

### #7. `--permission-mode bypassPermissions` = `--dangerously-skip-permissions`

```bash
echo "ls /tmp | head -2" | claude -p --permission-mode bypassPermissions
# ✅ --dangerously-skip-permissions와 동일하게 동작
```

### #12/25. `--dangerously-skip-permissions`는 hooks의 block을 무시하지 않음

Permission prompt만 건너뛰고, hooks 자체는 호출된다. 단, `bypassPermissions` 모드에서는 hooks의 결정이 passthrough로 무시된다 (#26 참조). ⚠️ `--disable-hooks` 플래그는 v2.1.76에 존재하지 않음.

### #26. `bypassPermissions` 모드에서 hooks는 호출되지만 결정이 passthrough로 무시됨

hooks 자체는 실행되지만, hooks의 allow/deny/block 결정이 결과에 반영되지 않는다. 이는 #12/25와 일관됨: `--dangerously-skip-permissions`(= `bypassPermissions`)는 permission prompt를 건너뛰고, hooks 결정도 무시한다.

### #27. `default` 모드에서 hooks의 allow/deny/block 결정은 정상 반영됨

비대화형 모드에서도 `default` 퍼미션 모드를 사용하면 hooks의 결정이 존중된다.

### #33. `--permission-prompt-tool`로 MCP 도구에 퍼미션 처리 위임 가능

비대화형 모드에서 인터랙티브 권한 프롬프트를 MCP 도구에 위임할 수 있다. 자체 퍼미션 UI가 있는 CI/CD 시스템에 유용.

---

## 도구/스킬 (Tools)

### #5. `--tools ""`로 빌트인 비활성화해도 MCP 도구는 남아있음

```bash
echo "현재 디렉토리의 파일 목록을 보여줘" | claude -p --tools ""
# "Figma 관련 MCP 도구만 사용할 수 있는 상태입니다."
```

⚠️ `--mcp-servers ""` / `--no-mcp` 플래그는 v2.1.76에 존재하지 않음. MCP 도구를 비활성화하는 공식 방법은 `claude -p --help` 출력을 확인한다.

⚠️ 역방향도 성립: `--allowedTools "mcp__server__tool"`에 MCP 도구명을 명시해도 해당 MCP 서버가 세션에서 초기화되지 않으면 사용 불가. `allowedTools`는 허용 목록이지, 서버 활성화 지시가 아니다. MCP 서버 초기화는 `.mcp.json` 또는 `settings.json`의 MCP 설정에 의존한다 (`.mcp.json`에 미등록이거나 서버 프로세스가 init 단계에서 연결 실패한 경우 "미활성"). `--strict-mcp-config`로 특정 MCP 설정만 로드하는 것도 가능하다 (v2.1.81+). v2.1.81 실측.

### #13. `--disable-slash-commands`로 스킬 비활성화 시 "Unknown skill"

```bash
echo "/create-issue 이슈 보여줘" | claude -p --disable-slash-commands --dangerously-skip-permissions
# "Unknown skill: create-issue"
```

### #38. 플러그인 스킬 인식은 설치 시점에 고정됨

`claude -p`는 `~/.claude/plugins/installed_plugins.json`의 `installPath` → `skills/` 디렉토리에서 스킬을 로드한다. 설치 시점에 존재했던 스킬만 인식하며, 이후 캐시 디렉토리에 파일을 추가하거나 symlink를 생성하거나 marketplace repo를 다른 브랜치로 checkout해도 인식되지 않는다.

```bash
# ❌ 캐시에 물리 복사 — 인식 안 됨
cp -R my-new-skill/ ~/.claude/plugins/cache/my-plugin/1.0.0/skills/my-new-skill

# ❌ symlink — 인식 안 됨
ln -sfn /path/to/dev-plugin ~/.claude/plugins/cache/my-plugin/1.0.0

# ❌ marketplace repo 브랜치 변경 — 인식 안 됨
cd ~/.claude/plugins/marketplaces/my-plugin && git checkout feature-branch

# ✅ 해결: SKILL.md 내용을 stdin으로 직접 주입
cat skill-content.md agent-instructions.md | claude -p --output-format text > result.md

# ✅ 해결: 플러그인 재설치
# Claude Code 대화형 모드에서 /plugins 또는 재설치 명령 실행
```

⚠️ 이 동작은 Claude Code의 내부 플러그인 인덱싱 메커니즘에 의존하며, 향후 버전에서 변경될 수 있다. v2.1.81 실측. 상세 우회 패턴: [patterns.md](patterns.md) 패턴 9 참조.

### #35. `allowedTools` 패턴 공백 의미 차이

[#36](#36-allowedtools-패턴에서-공백이-중요) 참조.

---

## hooks

### #28. Notification hook은 `-p`에서 트리거되지 않음

비대화형 모드에서는 Notification 이벤트 자체가 발생하지 않으므로 hook이 실행되지 않는다.

### #29. result subtype 종류 — 6종

| subtype | 의미 | exit code |
|---------|------|-----------|
| `success` | 정상 완료 | 0 |
| `error_max_turns` | `--max-turns` 도달 | 0 |
| `error_max_budget_usd` | `--max-budget-usd` 초과 | 0 |
| `error_max_structured_output_retries` | 구조화 출력 재시도 초과 | 0 |
| `error_during_execution` | 실행 중 오류 | 1 |
| `error_utilization_penalty` | 사용량 패널티 | 0 |

`success`와 `error_during_execution`만 exit code가 다르다. 나머지 에러는 모두 exit code 0.

### #37. Stop hooks → MCP 종료 → SessionEnd hooks 순서

MCP cleanup이 Stop hooks와 SessionEnd hooks 사이에 끼어있다. Stop hook에서 MCP 서버에 접근하는 것은 안전하지만, SessionEnd hook에서는 이미 종료된 후다.

### #30. `SIGINT` 수신 시 graceful shutdown, exit code 0

Ctrl+C를 보내면 현재 작업을 정리하고 exit code 0으로 종료한다.

---

## 세션/컨텍스트 (Session)

### #8. CLAUDE.md, skills, plugins, hooks, MCP 서버 전부 로드됨

```bash
echo "이 프로젝트는 어떤 프로젝트야?" | claude -p
# "macOS와 NixOS 개발 환경을 nix-darwin/NixOS + Home Manager로 선언적 관리하는 프로젝트"
```

`-p` 모드에서도 대화형 모드와 동일한 컨텍스트가 로드된다.

### #9. `--resume SESSION_ID`가 `-p`와 함께 동작 (세션 체이닝)

```bash
SESSION_ID=$(echo "나의 비밀 코드는 XRAY42야" | claude -p --output-format json | python3 -c "
import sys, json; data=json.loads(sys.stdin.read())
for item in data:
    if isinstance(item, dict) and item.get('type')=='system':
        print(item['session_id']); break")
echo "내 비밀 코드가 뭐였어?" | claude -p --resume "$SESSION_ID"
# "XRAY42"라고 말씀하셨습니다
```

여러 `-p` 호출 간 컨텍스트를 유지할 수 있다. [patterns.md](patterns.md) 패턴 4 참조.

### #14. `--append-system-prompt`는 override가 아닌 append

```bash
echo "언어 설정은?" | claude -p --append-system-prompt "Always respond in English only."
# 한국어로 응답 (settings.json의 "language": "Korean" 설정이 유지됨)
```

기존 시스템 프롬프트에 추가되므로, 기존 지시를 덮어쓰지 못한다.

---

## SSH

### #15. SSH non-login shell에서 aliases 미로드

```bash
ssh minipc 'c -p "hello"'
# c: command not found
# c는 ~/.zshrc에서 정의된 alias — non-login shell에서 로드되지 않음

ssh minipc 'claude -p "hello"'  # ✅ full path 사용
```

### #16. 3중 중첩 quote 지옥 → 파일 기반 stdin pipe가 유일한 안정 패턴

```bash
# ❌ quote 지옥
ssh minipc 'zsh -li -c "c -p \"ssh mac '\''defaults write ...'\''\""'
# → zsh: unmatched "

# ✅ 파일 기반 stdin pipe
echo "hostname 실행하고 결과만 보고해" | ssh minipc 'claude -p --dangerously-skip-permissions'
```

[patterns.md](patterns.md) 패턴 5 참조.

### #32. MiniPC sshd 180초 무응답 시 SSH 끊김

MiniPC sshd 설정: `ClientAliveInterval=60`, `ClientAliveCountMax=3` → 180초 무응답 시 연결 해제. Mac client에 `ServerAliveInterval`이 미설정되어 있으므로, 장시간 `-p` 실행 시 SSH 연결이 끊길 수 있다.

```bash
# 장시간 실행 시 ServerAliveInterval 설정
ssh -o ServerAliveInterval=30 minipc 'echo "long prompt" | claude -p --dangerously-skip-permissions'
```

---

## 기타 (Miscellaneous)

### #10. pipe chain 가능

```bash
echo "3+7의 결과만 숫자로" | claude -p | xargs -I{} sh -c 'echo "{}에 5를 곱한 결과만 숫자로" | claude -p'
# 50 (10 * 5)
```

### #11. 동시 실행 가능 (같은 디렉토리)

```bash
echo "echo proc1" | claude -p --dangerously-skip-permissions --no-session-persistence &
echo "echo proc2" | claude -p --dangerously-skip-permissions --no-session-persistence &
wait
# 두 프로세스 모두 정상 완료, 충돌 없음
```

`--no-session-persistence`로 세션 파일 충돌을 방지한다.

### #34. 공식 명칭 변경: "headless mode" → "Agent SDK"

공식 문서가 `headless mode`에서 `Agent SDK`로 명칭을 변경했다. CLI(`-p`/`--print`)는 Agent SDK의 하위 사용 방식이며, Python/TS SDK도 Agent SDK에 포함된다. CLI 인터페이스 자체는 동일.

### #31. `CLAUDE_CODE_MAX_RETRIES` 환경변수로 API 재시도 횟수 제어

기본 재시도 횟수를 환경변수로 오버라이드할 수 있다.

---

## 참고

- 확인 날짜: 2026-04-21
- 확인 버전: Claude Code v2.1.116
- 확인 범위: 문서 메타데이터/핵심 항목 기준이며, 각 항목의 재검증 상태는 본문 주석(예: "재검증 미수행")을 따른다.
- 재검증: `claude --version` 출력과 비교 후, 변경된 항목이 있으면 갱신한다
