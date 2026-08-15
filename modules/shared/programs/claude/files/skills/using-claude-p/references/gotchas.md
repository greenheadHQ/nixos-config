# 숨겨진 동작

`claude -p`의 help/runtime 차이와 재발 failure mode를 카테고리별로 정리한다.

> 항목 번호(#1, #23 등)는 최초 발견 순서를 유지하며, 카테고리별로 그룹화되어 있다.
> 번호 순서대로가 아닌 카테고리순으로 정렬되어 있으므로, 특정 번호를 찾으려면 페이지 검색을 사용한다.

## 재검증 상태 — 기준선 2026-07-10 / v2.1.206 (일부 항목은 v2.1.233 재실측)

- 재검증 명령: `claude --version && claude --help && claude -p --help`
- 런타임 관측 항목(2.1.233 스탬프)의 재검증 명령: `echo "ok" | claude -p --model haiku --output-format json`
  (항목별 추가 플래그는 각 항목 본문에 병기). 개별 항목의 `재확인:` 스탬프는 이 표의 일괄
  스탬프보다 우선한다.
- 실제 실행이 확인된 항목은 `재확인: 2026-07-10, v2.1.206`, 나머지는
  `재검증 미수행 (v2.1.202 기준 서술 유지)`로 구분한다.
- `실전 재발 사례`는 실제 업무 사고, `통제 smoke`는 최소 probe에서만 본 현상이다. 별도 라벨이
  없는 과거 runtime 서술은 v2.1.202 이전의 역사 관측으로 읽는다.

| 항목 | 판정 |
|------|------|
| #1 | 재확인: 2026-07-10, v2.1.206 — variadic prompt 흡수와 입력 없음 오류 재현; stdin 부재 시 3초 watchdog 경고 후 진행 |
| #23 | 재검증 미수행 (v2.1.202 기준 서술 유지) |
| #24 | 재검증 미수행 (v2.1.202 기준 서술 유지) |
| #39 | 재검증 미수행 (v2.1.202 기준 서술 유지) |
| #40 | 공식 문서 계약(10MB cap)으로 갱신: 2026-08-15. 조기 fail-fast는 로컬 미관측 — `wc -c` 사전 게이트 권장 (#40 본문) |
| #36/#35 | `--allowed-tools` help 표기 확인. 패턴 매칭 의미는 재검증 미수행 (v2.1.202 기준 서술 유지) |
| #6 | 재확인: 2026-08-15, v2.1.233 — 성공 경로 top-level 배열, 이벤트 수는 런마다 가변 (구 4-event 서술 폐기). stream-json wire shape는 재검증 미수행 (v2.1.202 기준 서술 유지) |
| #17 | 재확인: 2026-08-15, v2.1.233 — init에 skills/tools/MCP/plugins key 존재; count는 환경 snapshot. 인벤토리 추출은 `subtype=='init'` 가드 필수 (system 이벤트 다중 매치) |
| #22 | `--debug`, `--verbose`, `--debug-file` help 표기 확인. stderr 동작은 재검증 미수행 (v2.1.202 기준 서술 유지) |
| #2/#18/#19 | #18 hidden parser 수용 재확인: 2026-08-15, v2.1.233. #19 exit 1 + is_error:true 재확인: 2026-08-15, v2.1.233 (구 "exit 0/is_error:false" 서술 역전). #2 turn semantics는 재검증 미수행 (v2.1.202 기준 서술 유지) |
| #4 | `--max-budget-usd` help 표기 확인. exit/subtype 동작은 재검증 미수행 (v2.1.202 기준 서술 유지) |
| #20 | 재확인: 2026-07-10, v2.1.206 help에 `--cwd` 없음 |
| #21 | 재확인: 2026-07-10, v2.1.206 help에 `--output-file`/`-o` 없음 |
| #3 | skip-permissions + allowed-tools 제한 무효 재확인: 2026-07-10. 도구 거부 시 is_error:false + exit 0 재확인: 2026-08-15, v2.1.233 라이브 |
| #43~#46 | 신설: 2026-08-15 — carve-out 5갈래·검사 강화 목록·경로 매칭 semantics는 CHANGELOG 원문 + 설치본(2.1.233) 문자열 대조. #46은 2026-08-15 라이브 재실측으로 갱신 (따옴표 민감성 미재현, 실제 원인은 작업 디렉토리 경계 — `permission_denials` 기반 판정) |
| #47 | 신설: 2026-08-15 — SIGTERM 143은 공식 headless 문서 + v2.1.212 CHANGELOG. timeout 래핑 시 124로 가려짐은 로컬 실측 |
| #7 | `--permission-mode bypassPermissions` help 선택지 확인 |
| #12/#25/#26/#27 | `--disable-hooks`가 v2.1.206 help에 없음을 확인. hooks 결정 동작은 재검증 미수행 (v2.1.202 기준 서술 유지) |
| #33 | `--permission-prompt-tool`이 v2.1.206 help에 없음. hidden 동작은 재검증 미수행 (v2.1.202 기준 서술 유지) |
| #5 | `--tools`, `--mcp-config`, `--strict-mcp-config` help 표기와 `--mcp-servers`/`--no-mcp` 부재 재확인. MCP 잔존은 재검증 미수행 (v2.1.202 기준 서술 유지) |
| #13 | `--disable-slash-commands` help 표기 확인. 실제 응답 문구는 재검증 미수행 (v2.1.202 기준 서술 유지) |
| #38 | 재검증 미수행 (v2.1.202 기준 서술 유지) |
| #28/#29/#37/#30 | #29 success 정상/인증실패 조합 재확인: 2026-07-10, v2.1.206. exhaustive subtype과 #28/#37/#30은 재검증 미수행 (v2.1.202 기준 서술 유지) |
| #8/#9/#14 | `--resume`, `--append-system-prompt` help 표기 확인. 실제 context/override 동작은 재검증 미수행 (v2.1.202 기준 서술 유지) |
| #15/#16/#32 | SSH/shell 규칙 유지; 약 10분 무출력 후 완료 사례 반영 |
| #10/#11/#31/#34 | 재검증 미수행 또는 문서 서술 유지 (v2.1.202 기준) |

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

### #1. variadic flag 뒤 인라인 프롬프트가 flag 값으로 파싱됨

```bash
# ❌ 잘못된 사용
claude -p --allowedTools "Bash,Read" "ls /tmp 실행해"
# → Error: Input must be provided either through stdin or as a prompt argument
# "ls /tmp 실행해"가 도구 이름으로 먹힘

# ✅ 올바른 사용 — stdin 필수
echo "ls /tmp | head -2를 실행해" | claude -p --allowed-tools "Bash,Read"
```

`--allowed-tools`, `--disallowed-tools`처럼 help가 `<values...>`로 표시하는 variadic flag는 뒤의
인라인 prompt를 계속 flag 값으로 소비할 수 있다. prompt는 stdin으로 전달한다. stdin이 없으면
v2.1.206은 약 3초 watchdog 경고 뒤 진행할 수 있으므로, 짧은 정지를 정상 prompt 파싱으로 오인하지
않는다. 재확인: 2026-07-10, v2.1.206.

### #23. 빈 줄 vs 빈 문자열 입력 차이

```bash
echo "" | claude -p          # 빈 줄 전송 → hang (무한 대기, 출력 없음)
claude -p ""                 # 빈 문자열 인수 → 에러, exit 1
```

⚠️ `echo "" | claude -p`는 "유효 입력"이 아니라 무한 대기 상태에 빠진다 (v2.1.76 실측; v2.1.202 실제 `claude -p` 재검증 미수행, 서술 유지). 두 패턴 모두 사용하지 않는다.

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

v2.1.81 실측 (v2.1.202 실제 `claude -p` 재검증 미수행, 서술 유지). `CLAUDE_CODE_MAX_RETRIES`, `ANTHROPIC_API_KEY` 등 Claude Code 내장 환경변수는 정상 인식됨.

### #40. stdin 파이프 상한 — 공식 계약 10MB

piped stdin의 공식 상한은 10MB다 — 초과 시 명확한 에러 + non-zero exit로 종료하고, 더 큰
입력은 파일에 쓰고 경로를 프롬프트에서 참조하라는 것이 공식 headless 문서의 계약이다
(확인: 2026-08-15). 그 이하의 대용량 stdin은 정상 동작을 실측했다.

```bash
# 발사 전 사전 게이트 — 실질 방어선 (공식 계약이지만 조기 fail-fast는 로컬 미관측: 11MB 입력이
# 인증·세션 실패 단계까지 cap 전용 에러 없이 진행된 프로브가 있다. cap에 기대지 말고 미리 자른다)
[ "$(wc -c < "$PROMPT")" -le 10000000 ] || { echo "stdin over 10MB — 파일 경로 참조로 전환"; exit 1; }
cat "$PROMPT" | claude -p --output-format text > result.md
```

주의: claude는 stdin EOF를 다 읽은 뒤에야 인증·세션 단계로 진행한다 (느린 producer를 물리면
EOF까지 대기 — 실측). 10MB 근처 입력은 청킹 또는 파일 참조로 전환한다.

### #36. `allowed-tools` 패턴에서 공백이 중요

```bash
--allowed-tools "Bash(git diff *)"   # git diff 로 시작하는 명령만
--allowed-tools "Bash(git diff*)"    # git diff-index 등도 매칭됨!
```

---

## 출력 (Output)

### #6. JSON vs JSONL 출력 형식

```bash
# --output-format json → 이벤트 스트림. 실측 런타임은 top-level 배열, help(`json (single result)`)와
# 공식 문서는 단일 객체 표기 — 어느 쪽도 가정하지 말고 정규화 파서를 쓴다.
echo "2+3" | claude -p --output-format json | python3 -c "
import sys, json
raw = sys.stdin.read()
data, _ = json.JSONDecoder().raw_decode(raw.lstrip())  # 후행 비-JSON 라인 내성 (stdout 오염 간헐 실측)
items = data if isinstance(data, list) else [data]
result = next(i for i in items if isinstance(i, dict) and i.get('type') == 'result')
print(f'{result[\"subtype\"]} is_error={result[\"is_error\"]}')"
# 이벤트 수는 같은 버전·같은 플래그·같은 모델에서도 런마다 다르다 (2.1.233 실측: 9~12+ —
# system/thinking_tokens가 가변 개수로 삽입됨). 특정 개수를 기대하는 파서 금지.

# --output-format stream-json → JSONL (재검증 미수행)
echo "hello" | claude -p --output-format stream-json | wc -l
# event 수는 고정 계약이 아님
```

재확인: 2026-08-15, v2.1.233 — 성공 경로는 system/init + system/thinking_tokens(가변) +
assistant + rate_limit_event + result/success로 구성되며 총 이벤트 수는 런마다 가변이다.
event 수와 중간 event 존재는 고정하지 않는다. parser는 배열/객체를 정규화한 뒤 `type=result`를
탐색하고, stdout 말미의 비-JSON 경고 라인(MCP 구성 의존)을 견디도록 첫 JSON 문서만 취하되,
그래도 파싱이 실패하면 raw를 조용히 흘리지 말고 non-zero로 죽는다 — 무음 raw 통과가 "E2E 통과"로
오판된 실전 사고가 있다. `stream-json` wire shape는 재검증 미수행 (v2.1.202 기준 서술 유지).

### #17. init 이벤트에 전체 harness 인벤토리 포함

```bash
echo "ok" | claude -p --output-format json | python3 -c "
import sys, json
data, _ = json.JSONDecoder().raw_decode(sys.stdin.read().lstrip())  # 후행 비-JSON 라인 내성
items = data if isinstance(data, list) else [data]
init = next(d for d in items if isinstance(d, dict)
            and d.get('type')=='system' and d.get('subtype')=='init')
print(f'Skills: {len(init.get(\"skills\", []))}')
print(f'Tools: {len(init.get(\"tools\", []))}')
print(f'MCP: {len(init.get(\"mcp_servers\", []))}')
print(f'Plugins: {len(init.get(\"plugins\", []))}')"
```

인벤토리 추출 필터는 반드시 `type=='system' and subtype=='init'`으로 좁힌다 (재확인:
2026-08-15, v2.1.233). `type=='system'`만 보면 다중 매치다 — json 모드에서 `system/thinking_tokens`
이벤트가 가변 개수(실측 4~9건)로 섞이고, stream-json에서는 SessionStart hook 구성 시
`system/hook_started`·`system/hook_response`가 init보다 선행한다. hook 이벤트 객체에는
`skills`/`tools` 키가 없어 `[0]`을 집으면 인벤토리가 조용히 0이 된다. 반면 `session_id`는 한
호출의 모든 이벤트에서 동일 값이므로 session_id 추출(#9, patterns 패턴 4)에는 이 가드가 불필요하다.

네 key 존재는 재확인했지만 count는 설치·설정에 따른 환경 snapshot이다. 고정 기대값으로 쓰지 않는다.
[harness-testing.md](harness-testing.md) T1 참조.

### #22. `-p`에서 `--verbose`/`--debug`는 stderr에 아무것도 출력 안 함

```bash
echo "hello" | claude -p --verbose 2>/tmp/stderr.log
cat /tmp/stderr.log  # 비어 있음

# 디버그 로그가 필요하면 --debug-file 사용
echo "hello" | claude -p --debug-file /tmp/debug.log
cat /tmp/debug.log  # 상세 로그 출력
```

### #48. `--output-format json`은 완료 시 일괄 기록 — 실행 중 0바이트는 실패 신호가 아님

json 출력을 파일로 리다이렉트하면 그 파일은 프로세스 종료까지 0바이트다 (미검증 — 세션 실측
5건: 이를 모르고 3분 만에 "미완료"로 포기해 인수인계까지 간 사례 실재). 판정 규칙:

- `test -s`는 종료 후 판정에만 쓴다 — 실행 중 0바이트로 사망을 추론하지 않는다.
- 성공 경로의 stderr는 비어 있는 것이 정상이다 (#22) — stderr 무출력도 실패 신호가 아니다.
- 진행 관측이 필요하면 `--output-format stream-json`(JSONL, 이벤트별 즉시 방출)으로 전환하거나,
  자식 세션의 프로젝트 JSONL(`~/.claude/projects/...`)을 tail하거나, 마커 기반 생존 확인을 쓴다.
- 폴링하게 되는 예외 상황에서는 간격을 최소 3~5분으로 잡는다 (실측 소요 3~6분).

---

## 제어/플래그 (Control)

### #2. `--max-turns 1`은 도구 실행 불가

도구 사용에 최소 2턴 필요 (호출 1턴 + 결과 수신 1턴).

```bash
echo "ls /tmp | head -3" | claude -p --dangerously-skip-permissions --max-turns 1
# stdout: Error: Reached max turns (1) — process exit 1, stderr 무출력 (2.1.233 실측; #19 참조)
```

도구 실행이 필요하면 `--max-turns 2` 이상을 지정한다.

### #4. `--max-budget-usd` 초과도 exit code 0

```zsh
set -o pipefail
echo "아주 긴 에세이를 5000단어로 써줘" | claude -p --max-budget-usd 0.001 \
  > /tmp/budget.stdout 2> /tmp/budget.stderr
claude_rc=$pipestatus[2]
```

예산 초과를 감지하려면 exit code가 아닌 `--output-format json`의 result subtype을 확인해야 한다.

### #18. `--max-turns`는 `--help`에 표시되지 않는 숨겨진 플래그

`claude --help`/`claude -p --help` v2.1.233 출력에도 `--max-turns`가 없지만 실행 smoke에서
parser 수용을 확인했다 (재확인: 2026-08-15; 한도 미도달 실행은 exit 0, 한도 도달 시 exit는
#19 참조 — 1이다). turn 제한 semantics와 `CLAUDE_CODE_MAX_TURNS` 부재/유일 제어 수단 서술은
재검증 미수행 (v2.1.202 기준 서술 유지).

### #19. `--max-turns` 도달 시 exit 1 + `is_error: true`

한도 도달 시 result는 `subtype=error_max_turns`, `is_error=true`,
`errors=["Reached maximum number of turns (N)"]`, `terminal_reason=max_turns`이고 process exit는
1이다. 텍스트 모드도 exit 1이며 `Error: Reached max turns (N)`이 stdout에 찍힌다 —
어느 모드든 stderr는 무출력이므로 stderr를 grep 대상으로 잡으면 오탐한다. 공식 CLI reference도
"Exits with an error when the limit is reached"로 일치한다 (재확인: 2026-08-15, v2.1.233 —
과거 v2.1.202 관측 "is_error:false / exit 0"은 역전됨). `num_turns`는 한도보다 클 수 있으므로
(`--max-turns 1`에서 `num_turns: 2` 실측) 한도 도달 추론에 `num_turns` 비교를 쓰지 않는다.

### #20. `--cwd` 플래그 존재하지 않음

작업 디렉토리를 변경하려면 `cd dir && claude -p`를 사용한다. `--cwd`는 v2.1.206 help에도 없다.

```bash
# ❌ 존재하지 않음
claude -p --cwd /path/to/project "prompt"

# ✅
cd /path/to/project && echo "prompt" | claude -p
```

### #21. `--output-file` / `-o` 플래그 존재하지 않음

shell redirect를 사용해야 한다. `--output-file`/`-o`는 v2.1.206 help에도 없다.

```bash
# ❌ 존재하지 않음
claude -p -o result.txt "prompt"

# ✅
echo "prompt" | claude -p > result.txt
```

---

## 권한 (Permissions)

### #3. 권한 없이 도구 사용 시 조용히 거부, exit code 0

```zsh
set -o pipefail
echo "ls /tmp 실행해줘" | claude -p > /tmp/permission.stdout 2> /tmp/permission.stderr
claude_rc=$pipestatus[2]
```

도구를 못 썼는데도 에러가 아닌 정상 종료. 실패를 감지하려면 출력 내용을 파싱해야 한다.

재확인: 2026-08-15, v2.1.233 라이브 — 도구가 차단됐는데도 `result.is_error=false`, process exit 0.

⚠️ `--dangerously-skip-permissions` + `--allowed-tools` 상호작용: skip-permissions는 allowlist를
구조적으로 무효화한다. 도구를 제한하려면 skip-permissions 없이 allowed-tools와 stdin을 사용하고,
제한이 불필요하면 skip-permissions를 단독 사용한다. 재확인: 2026-07-10, v2.1.206 실사용 6회.
스킬·도구 실행이 필요한 자동화에서는 세 번째 선택지가 흔히 최선이다 —
`--permission-mode dontAsk` + deny 규칙 (프롬프트는 건너뛰되 hooks·deny 결정은 존중, #27).
allowlist는 패턴 공백 민감성(#36)과 작업 디렉토리 경계(#46) 때문에 스킬 내부 호출 형태와 어긋나 fail-closed로
전멸한 실전 사례가 있다.

### #43. `--dangerously-skip-permissions`는 전면 우회가 아님 (carve-out)

catastrophic removal 계열은 skip-permissions·auto 모드에서도 프롬프트를 요구하며, permission
rule로 auto-allow할 수 없다. 설치본(2.1.233) 기준 carve-out 갈래는 최소 5종:

1. critical system directory 제거
2. 워크스페이스 디렉토리(작업 디렉토리·추가 작업 디렉토리)와 그 상위 제거 — 에이전트
   자동화가 실제로 밟기 쉬운 갈래
3. 제거 타깃이 정적으로 해석 불가 (명령 치환·미추적 변수 출력)
4. 제거 전 `cd`로 상대 glob 타깃이 해석 불가
5. 명령 치환 과다 (분석 불가 개수)

기원: 최소 2.1.126부터 존재 ("catastrophic removal commands still prompt as a safety net"),
2.1.208에서 `$(...)`/백틱/`<(...)` 난독화 형태까지 확대. TTY 없는 headless에서는 이 프롬프트가
곧 차단이다 — 해당 명령은 사전에 분해하거나 정적 경로로 재구성한다.

### #44. headless에서 프롬프트로 떨어지는 Bash 검사 강화 목록 (릴리스 간 진동 주의)

아래 형태는 자동 승인되지 않고 프롬프트(=headless 차단)로 떨어진다. 각 항목은 도입 버전
스탬프를 유지한다 — 이 표면은 릴리스 간 진동한다 (예: 2.1.232의 `< file` 입력 리다이렉트
검사는 2.1.233에서 revert, "a narrower version will return"):

- 10,000자 초과 명령 (2.1.214)
- fd 리다이렉트 형태 중 permission analyzer와 bash 파싱이 갈리는 것 — fail-closed (2.1.214)
- `&&` 리스트·부정 안의 리다이렉트 복합문 (2.1.216)
- zsh `[[ ]]` 안의 변수 subscript/modifier (2.1.214) 및 regex 조건식 (2.1.221)
- docker/Podman daemon-redirect 플래그 `--url`/`--connection`/`--identity` (2.1.214)

### #45. 권한 규칙 경로 매칭 semantics

- allow 규칙의 단일 세그먼트 `dir/`는 `<cwd>/dir`만 매칭 (2.1.214에서 any-depth 매칭
  버그 수정). any-depth가 필요하면 `/dir/`로 쓴다.
- deny·ask 규칙은 any-depth 매칭을 유지한다 — allow와 비대칭.
- 경로 인자를 받는 규칙 도구는 `Edit(path)`·`Read(path)`뿐이다. `Write(path)`·
  `NotebookEdit(path)`·`Glob(path)` 규칙은 무효 (2.1.210부터 startup 경고).

### #46. `--allowed-tools` allowlist가 fail-closed로 전멸할 때의 진짜 원인

allowlist를 걸었는데 도구 호출이 전부 거부되면, 먼저 의심할 것은 패턴 문법이 아니라
작업 디렉토리 경계**다. 재확인: 2026-08-15, v2.1.233 (판정은 result의 `permission_denials`로 —
교란 없는 기계 판정):

| 패턴 | 실행 명령 | 결과 |
|---|---|---|
| `Bash(ls /tmp*)` | `ls /tmp` | 거부 |
| `Bash(ls /tmp*)` | `ls "/tmp"` | 거부 |
| `Bash` (전체 허용) | `cat ./probe.txt` | 허용 |
| `Bash(cat ./probe.txt*)` | `cat ./probe.txt` | 허용 |
| `Bash(cat ./probe.txt*)` | `cat "./probe.txt"` | 허용 |

- cwd 밖 경로(`/tmp`)는 패턴이 정확히 맞아도 별도 가드가 먼저 차단한다 — allowlist 패턴을
  아무리 고쳐도 통과하지 않는다. 대상 경로를 세션 작업 디렉토리 안으로 옮기거나
  `--add-dir`로 확장한다.
- 따옴표 유무는 같은 패턴에서 동일하게 통과했다 — 과거 구 빌드(2026-08-01 세션)에서 관측된
  따옴표 민감성은 2.1.233에서 재현되지 않았고, "무따옴표/작은따옴표/이스케이프 3변형 등록"
  처방도 이 버전에서는 근거가 없다. #36의 공백 민감성(`Bash(git diff *)` vs `Bash(git diff*)`)은
  별개 축으로 유지된다.

### #7. `--permission-mode bypassPermissions` = `--dangerously-skip-permissions`

```bash
echo "ls /tmp | head -2" | claude -p --permission-mode bypassPermissions
# ✅ --dangerously-skip-permissions와 동일하게 동작
```

### #12/25. `--dangerously-skip-permissions`는 hooks를 호출하지만 결정을 반영하지 않음

hooks 자체는 호출되지만 `bypassPermissions`에서는 allow/deny/block 결정이 passthrough로 무시된다
(#26 참조). `--disable-hooks` 플래그는 v2.1.206 help에도 없다. hook runtime은 재검증 미수행
(v2.1.202 기준 서술 유지).

### #26. `bypassPermissions` 모드에서 hooks는 호출되지만 결정이 passthrough로 무시됨

hooks 자체는 실행되지만, hooks의 allow/deny/block 결정이 결과에 반영되지 않는다. 이는 #12/25와 일관됨: `--dangerously-skip-permissions`(= `bypassPermissions`)는 permission prompt를 건너뛰고, hooks 결정도 무시한다.

### #27. 권한 모드 생략 시 hooks의 allow/deny/block 결정은 정상 반영됨

비대화형 모드에서도 `--permission-mode`를 생략한 기본 동작에서는 hooks의 결정이 존중된다.
v2.1.206 help의 선택지에는 구 `default` 대신 `manual`이 있으며, 생략 상태는 별도로 해석한다.
hook runtime은 재검증 미수행 (v2.1.202 기준 서술 유지).

### #33. `--permission-prompt-tool`로 MCP 도구에 퍼미션 처리 위임 가능

비대화형 모드에서 인터랙티브 권한 프롬프트를 MCP 도구에 위임할 수 있다. 자체 퍼미션 UI가 있는 CI/CD 시스템에 유용. `--permission-prompt-tool`은 v2.1.206 help에 표시되지 않으며, hidden 동작은 재검증 미수행 (v2.1.202 기준 서술 유지).

---

## 도구/스킬 (Tools)

### #5. `--tools ""`로 빌트인 비활성화해도 MCP 도구는 남아있음

```bash
echo "현재 디렉토리의 파일 목록을 보여줘" | claude -p --tools ""
# "Figma 관련 MCP 도구만 사용할 수 있는 상태입니다."
```

⚠️ `--mcp-servers ""` / `--no-mcp` 플래그는 v2.1.206 help에도 존재하지 않음. `--mcp-config`와 `--strict-mcp-config`는 help에 있으나, 빈 MCP 구성으로 전체 비활성화하는 패턴은 별도 재검증 필요.

⚠️ 역방향도 성립: `--allowed-tools "mcp__server__tool"`에 MCP 도구명을 명시해도 해당 MCP 서버가 세션에서 초기화되지 않으면 사용 불가. `--allowed-tools`는 허용 목록이지, 서버 활성화 지시가 아니다. MCP 서버 초기화는 `.mcp.json` 또는 `settings.json`의 MCP 설정에 의존한다 (`.mcp.json`에 미등록이거나 서버 프로세스가 init 단계에서 연결 실패한 경우 "미활성"). `--strict-mcp-config`로 특정 MCP 설정만 로드하는 surface는 v2.1.206 help에서 확인했다. MCP 초기화 동작은 재검증 미수행 (v2.1.202 기준 서술 유지).

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

⚠️ 이 동작은 Claude Code의 내부 플러그인 인덱싱 메커니즘에 의존하며, 향후 버전에서 변경될 수 있다. v2.1.81 실측 (v2.1.202 실제 `claude -p` 재검증 미수행, 서술 유지). 상세 우회 패턴: [patterns.md](patterns.md) 패턴 9 참조.

### #35. `allowed-tools` 패턴 공백 의미 차이

[#36](#36-allowed-tools-패턴에서-공백이-중요) 참조.

---

## hooks

### #28. Notification hook은 `-p`에서 트리거되지 않음

비대화형 모드에서는 Notification 이벤트 자체가 발생하지 않으므로 hook이 실행되지 않는다.

### #29. result subtype/exit 조합은 고정 계약이 아님

제목의 6종은 v2.1.202까지 관측한 역사 목록이며 exhaustive enum으로 사용하지 않는다.

| 관측 경로 | subtype | is_error | process exit | 재확인 |
|----------|---------|:--------:|:------------:|--------|
| 인증된 정상 완료 | `success` | false | 0 | 2026-07-10, v2.1.206 |
| pre-auth 실패 (`Not logged in`) | `success` | true | 1 | 2026-07-10, v2.1.206 |
| max-turns 도달 | `error_max_turns` | true | 1 | 2026-08-15, v2.1.233 ([#19](#19---max-turns-도달-시-exit-1--is_error-true)) |

기존 `error_max_budget_usd`, `error_max_structured_output_retries`,
`error_during_execution`, `error_utilization_penalty` mapping은 재검증 미수행
(v2.1.202 기준 서술 유지). 성공 판정에는 exit, subtype, is_error, 기대 산출물을 함께 사용한다.

### #41. exit 0 / `subtype=success`여도 업무 성공이 아닐 수 있음

collector가 exit 0과 success를 반환했지만 기대 산출물이 0개인 채 자기증식한 실전 사고가 있었다.
무진척 pass도 5회 관측됐다. 다음을 모두 확인한다.

1. exit 0
2. result가 `subtype=success`, `is_error=false`
3. 기대 파일 `test -s "$RESULT"`와 완료 표식
4. 직전 pass 대비 진척 delta

진척 없는 pass가 연속되면 circuit breaker로 중단한다. child가 같은 collector/fan-out을 다시
생성하는 self-replicating orchestration은 금지한다. 관측 출처: 실전 재발 사례.

### #42. shell pipeline이 원 exit와 JSON 채널을 가릴 수 있음

JSON parser 앞 `2>&1`는 stderr를 stdout에 섞어 파싱을 깨뜨린다. `| head`, `| tail`, 뒤이은
`; echo $?`는 Claude 원 exit를 가릴 수 있다. stdout, stderr, 업무 산출물을 분리하고
`set -o pipefail`과 zsh `pipestatus`로 Claude exit를 즉시 보존한다. 관측 출처: 통제 smoke 2회.

### #37. Stop hooks → MCP 종료 → SessionEnd hooks 순서

MCP cleanup이 Stop hooks와 SessionEnd hooks 사이에 끼어있다. Stop hook에서 MCP 서버에 접근하는 것은 안전하지만, SessionEnd hook에서는 이미 종료된 후다.

### #30. `SIGINT` 수신 시 graceful shutdown, exit code 0

Ctrl+C를 보내면 현재 작업을 정리하고 exit code 0으로 종료한다.

### #47. `SIGTERM` 수신 시 exit 143 (SIGINT와 다름)

supervisor·`kill`이 SIGTERM을 보내면 진행 중 turn을 중단하고, 실행 중 Bash 명령의 프로세스
트리를 종료하고, SessionEnd hooks를 실행한 뒤 exit 143으로 종료한다 (공식 headless 문서;
프로세스 트리 정리는 v2.1.212 CHANGELOG). 판독 주의 — 두 exit code의 채널이 다르다:

- `timeout N claude -p ...` 래핑에서는 자식의 143이 가려지고 timeout이 124를 반환한다
  (`--preserve-status`를 줘야 143이 보인다).
- 143이 직접 보이는 경로: supervisor/`kill`의 직접 SIGTERM, `timeout --preserve-status`,
  셸의 128+15 보고.

즉 "124 = outer timeout 발동 / 143 = 직접 SIGTERM 피종료"로 읽되, timeout 래핑 유무를 먼저
확인한다. #30(SIGINT → exit 0)과 혼동하지 않는다.

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
import sys, json; data, _ = json.JSONDecoder().raw_decode(sys.stdin.read().lstrip()); items=data if isinstance(data,list) else [data]
for item in items:
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

무출력 약 10분 뒤 정상 완료된 실측이 있다. 무출력만으로 중단, 프로세스 생존만으로 정상이라
판정하지 않는다. outer timeout과 keepalive를 적용하고 완료 후 `test -s`로 기대 산출물을 검증한다.

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

### #49. Bash tool zsh 셸 함정 카탈로그 (스크립트 예제 복사 시)

Bash tool은 zsh에서 실행된다 — bash 전용 문법 금지의 SoT는 repo 루트 CLAUDE.md "Bash tool 환경"
절이며, 아래는 이 스킬의 예제 복사에서 반복 실측된 함정만 보충한다 (미검증 — 세션 실측 7건):

- `${PIPESTATUS[n]}`는 zsh에서 빈 값이다. `${PIPESTATUS[1]:-$?}` 같은 `:-$?` 폴백과 결합하면
  판정이 조용히 fail-open된다 — 이 문서의 zsh 펜스는 `$pipestatus`(1-base)를 쓰고, bash 펜스를
  복사할 때는 변환한다. 빈 값이면 즉시 FAIL하는 방어(`[ -n "$rc" ]`)를 판정에 포함한다.
- Bash tool 셸은 bare glob qualifier·extended glob이 꺼진 상태로 시작한다 — `*(N)` 같은
  qualifier는 무효이고 매칭 실패가 명령행 전체를 abort시킬 수 있다. 파일 순회는
  `find ... -maxdepth 1 -exec` 또는 리터럴 경로로 대체한다.
- 셸 옵션 의존 문법의 실측은 `zsh -fc`가 아니라 Bash tool 자체 1회 호출로 한다 —
  `zsh -f`는 옵션 상태가 달라 잘못된 확신을 준다.
- 바이너리 실경로 확인은 `type -a <bin>` 또는 `zsh -fc 'whence -a <bin>'`로 한다 —
  셸 함수/alias가 가로채는 경우를 함께 노출한다.

---

## 버전별 변천 (재인용 함정)

과거 세션 로그·문서를 복사할 때 버전 경계를 확인한다. 본문 항목은 현재 계약만 서술하고,
이력은 이 표가 정본이다 (출처: 공식 CHANGELOG 원문 라인 대조, 2026-08-15):

| 표면 | 변천 | 현재 (2.1.233) |
|---|---|---|
| skip-permissions carve-out | ≥2.1.126 존재 (safety net) → 2.1.208 `$(...)`/백틱/`<(...)` 난독화 형태까지 확대 | 5갈래 (#43) |
| `< file` 입력 리다이렉트 검사 | 2.1.232 도입 → 2.1.233 revert ("a narrower version will return") | 미검사 — 진동 표면 (#44) |
| allow 규칙 `dir/**` 매칭 | any-depth (버그) → 2.1.214 `<cwd>/dir` 한정 (deny·ask는 any-depth 유지) | cwd 한정 (#45) |
| subagent 세션 캡 | 2.1.212 도입 (기본 200, env 오버라이드) → 2.1.224 제거 — `CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION`은 설정해도 무효 (문자열만 잔존) | 없음 (동시성·depth 캡만, patterns.md 오케스트레이션 절) |
| subagent 중첩 depth | 2.1.217 중첩 금지(=1) → 2.1.219 기본 3 (원격 flag 폴백값) | 폴백 3 — 고정 상수 아님 |

## 참고

- 문서 기준선(일괄 확인): 2026-07-10 / Claude Code v2.1.206
- 부분 재실측: 2026-08-15 / v2.1.233 — 개별 항목의 `재확인:` 스탬프가 이 기준선보다 우선한다. 기준선을 통째로 올리려면 전 항목 재확인이 필요하므로, 재실측한 항목만 개별 스탬프로 갱신한다.
- 확인 범위: 문서 메타데이터/핵심 항목 기준이며, 각 항목의 재검증 상태는 본문 주석(예: "재검증 미수행")을 따른다.
- 재검증: `claude --version && claude --help && claude -p --help` 출력과 비교 후, 변경된 항목이 있으면 갱신한다. 런타임 관측 항목은 `echo "ok" | claude -p --model haiku --output-format json`으로 확인한다.
