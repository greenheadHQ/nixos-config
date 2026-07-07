# `claude -p` 플래그 호환성 매트릭스

- 확인 날짜: 2026-07-08
- 확인 버전: Claude Code v2.1.202
- 재검증: `claude --version && claude --help && claude -p --help` 출력과 비교

## `-p` 전용/연동 플래그

`-p`/`--print` 모드에서만 사용 가능하거나, `stream-json`/SDK print 경로와 강하게 묶인 플래그. `--help`의 `only works with --print` 및 관련 표기를 우선한다.

| 플래그 | v2.1.202 `--help` 표기 | 비고 |
|--------|------------------------|------|
| `--output-format <format>` | 출력 형식: `text`(기본), `json`(single result), `stream-json`(realtime streaming) | 기존 JSON 배열 실측은 [gotcha #6](gotchas.md)에 남김. 실제 `claude -p` 재검증 미수행 |
| `--no-session-persistence` | 세션 파일 미저장, resume 불가 (`only works with --print`) | 동시 실행 시 충돌 방지에 유용 |
| `--max-budget-usd <amount>` | 최대 비용 제한 (`only works with --print`) | 초과 시 exit code/subtype 동작은 [gotcha #4](gotchas.md) 참조 |
| `--fallback-model <model>` | 기본 모델 과부하/불가 시 지정 모델로 fallback (`only works with --print`) | 쉼표 구분 목록 가능 |
| `--input-format <format>` | 입력 형식: `text`(기본), `stream-json` (`only works with --print`) | |
| `--include-partial-messages` | 부분 메시지 chunk 포함 (`only works with --print` + `--output-format=stream-json`) | |
| `--include-hook-events` | 모든 hook lifecycle event 포함 (`only works with --output-format=stream-json`) | v2.1.202 help에서 확인된 추가 플래그 |
| `--replay-user-messages` | stdin user message를 stdout에 재방출 (`--input-format=stream-json` + `--output-format=stream-json`) | v2.1.202 help에서 확인된 추가 플래그 |
| `--prompt-suggestions [value]` | print/SDK 모드에서 다음 프롬프트 예측 메시지 emit | `true/false/1/0/yes/no/on/off`, preset `true` |
| `--json-schema <schema>` | JSON Schema 기반 structured output validation | v2.1.202 help에서 확인된 추가 플래그 |
| `--max-turns <N>` | `--help` 미표시 | 숨겨진 플래그로 문서 유지. 실제 `claude -p` 재검증 미수행 |

## 범용 플래그 (대화형/비대화형 공통)

| 플래그 | v2.1.202 `--help` 표기 | `-p` 모드에서의 동작/주의 |
|--------|------------------------|---------------------------|
| `--model <model>` | 모델 선택. alias(`fable`, `opus`, `sonnet`) 또는 full name 허용 | 정상 동작 |
| `--system-prompt <prompt>` | 시스템 프롬프트 설정 | 기본 시스템 프롬프트 대신 사용 |
| `--append-system-prompt <prompt>` | 기본 시스템 프롬프트에 추가 | 기존 지시를 덮어쓰지 못함 |
| `--resume [value]`, `-r` | session ID 또는 검색어로 resume | `-p`에서 세션 체이닝 가능 |
| `--continue`, `-c` | 현재 디렉토리의 최근 conversation 계속 | 비대화형 자동화에서는 session 명시가 더 안정적 |
| `--fork-session` | resume/continue 시 새 session ID 생성 | `--resume`/`--continue`와 함께 사용 |
| `--session-id <uuid>` | 특정 session ID 사용 | UUID 필요 |
| `--from-pr [value]` | PR 번호/URL 또는 검색어로 PR 연계 세션 resume | 대화형 picker 가능 |
| `--dangerously-skip-permissions` | 모든 permission check 우회 | `-p`에서 도구 사용 시 흔히 필요 |
| `--allow-dangerously-skip-permissions` | bypass 옵션을 활성화하되 기본값으로 켜지는 것은 아님 | sandbox용 옵션 |
| `--permission-mode <mode>` | `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, `plan` | `bypassPermissions` = `--dangerously-skip-permissions` |
| `--allowedTools`, `--allowed-tools <tools...>` | 허용할 도구 목록 (쉼표 또는 공백 구분) | 인라인 프롬프트가 도구 이름으로 파싱될 수 있어 stdin 권장 |
| `--disallowedTools`, `--disallowed-tools <tools...>` | 거부할 도구 목록 | v2.1.202 help에서 확인 |
| `--tools <tools...>` | 사용 가능한 built-in tool 목록 지정 | `""` 지정 시 built-in 비활성화, MCP는 별도 |
| `--disable-slash-commands` | 모든 skills 비활성화 | "Unknown skill" 계열 결과 |
| `--debug [filter]`, `-d` | debug mode + optional filter | `-p` stderr 동작은 [gotcha #22](gotchas.md) 참조 |
| `--debug-file <path>` | debug log 파일 기록 | `-p` 디버그에는 이 경로가 가장 안정적 |
| `--verbose` | config의 verbose mode override | `-p` stderr 동작은 [gotcha #22](gotchas.md) 참조 |
| `--add-dir <directories...>` | tool access 허용 디렉토리 추가 | 작업 루트 확장 |
| `--settings <file-or-json>` | settings JSON 파일 또는 JSON 문자열 로드 | |
| `--setting-sources <sources>` | 로드할 setting source: user/project/local | 쉼표 구분 |
| `--mcp-config <configs...>` | MCP config 파일 또는 JSON 문자열 로드 | |
| `--strict-mcp-config` | `--mcp-config`의 MCP만 사용 | 기본 MCP 설정 무시 |
| `--plugin-dir <path>` | plugin directory 또는 zip 로드 | repeatable |
| `--plugin-url <url>` | plugin zip URL 로드 | repeatable |
| `--agent <agent>` | 현재 세션 agent override | |
| `--agents <json>` | custom agents JSON 정의 | v2.1.202 help에서 확인 |
| `--bare` | hooks/LSP/plugin sync/CLAUDE.md auto-discovery 등 최소화 | `CLAUDE_CODE_SIMPLE=1`, 명시 context 필요 |
| `--safe-mode` | customizations 비활성화 | 문제 진단용, auth/model/built-in tools/permissions는 유지 |
| `--effort <level>` | effort level: `low`, `medium`, `high`, `xhigh`, `max` | |
| `--name <name>`, `-n` | session display name | |
| `--file <specs...>` | startup file resource download (`file_id:relative_path`) | v2.1.202 help에서 확인 |
| `--betas <betas...>` | API key 사용자용 beta header | |
| `--exclude-dynamic-system-prompt-sections` | machine-specific prompt section을 첫 user message로 이동 | prompt-cache reuse 목적 |
| `--ide` | IDE 자동 연결 | |
| `--chrome` / `--no-chrome` | Claude in Chrome integration on/off | |
| `--remote-control [name]` | Remote Control enabled interactive session 시작 | 대화형 성격이 강함 |
| `--remote-control-session-name-prefix <prefix>` | Remote Control session name prefix | |
| `--background`, `--bg` | background agent로 시작 | `claude agents`로 관리 |
| `--worktree [name]`, `-w` | 새 git worktree 생성 | `--tmux`와 연동 가능 |
| `--tmux` | worktree용 tmux/iTerm2 pane 생성 | `--worktree` 필요 |
| `--ax-screen-reader` | screen-reader friendly output | |
| `--brief` | SendUserMessage tool 활성화 | agent-to-user communication |
| `--help`, `-h` / `--version`, `-v` | help/version 출력 | |

## 존재하지 않거나 `--help`에 없는 플래그

CLI에 없거나 v2.1.202 help에 표시되지 않는 플래그. 사용 전 실제 실행으로 재확인한다.

| 의도 | 플래그 | 상태/대안 |
|------|--------|-----------|
| 작업 디렉토리 변경 | `--cwd` | help에 없음. `cd dir && claude -p` 사용 |
| 결과 파일 저장 | `--output-file` / `-o` | help에 없음. shell redirect `> file` 사용 |
| hooks 비활성화 | `--disable-hooks` | help에 없음 |
| MCP 전체 비활성화 | `--mcp-servers ""` / `--no-mcp` | help에 없음. `--mcp-config` + `--strict-mcp-config` 조합은 별도 검증 필요 |
| MCP permission UI 위임 | `--permission-prompt-tool <tool>` | help에 없음. 기존 숨은 플래그 서술은 실제 `claude -p` 재검증 미수행 |

## 환경변수

| 환경변수 | 설명 | 비고 |
|----------|------|------|
| `CLAUDE_CODE_MAX_RETRIES` | API 재시도 횟수 | 기본값 오버라이드 (바이너리에서 확인) |
| `ANTHROPIC_API_KEY` | API 키 | 인증 필수 |
| *(커스텀 환경변수)* | `VAR=val claude -p` 형태로 명시적 전달 필요. `.env` 자동 로드 안 됨 | [gotcha #39](gotchas.md) |

## `--permission-mode` 선택지 비교

v2.1.202 help의 공식 선택지는 `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, `plan`이다. 기존 문서의 `default`는 help 선택지가 아니며, 아래에서는 "플래그 생략" 상태로만 다룬다.

| 모드 | 권한 프롬프트 | hooks 호출 | hooks 결정 반영 | 용도 |
|------|:----------:|:--------:|:-----------:|------|
| 플래그 생략 | 표시 (TTY 필요) | O | O | 기본 동작 (비대화형에서는 TTY 없어 도구 차단 가능) |
| `manual` | 표시 (TTY 필요) | O | O | 명시적 수동 승인 모드 |
| `acceptEdits` | 편집만 허용 | O | O | 파일 편집만 자동 승인 |
| `bypassPermissions` | X 건너뜀 | O | X (passthrough) | = `--dangerously-skip-permissions` |
| `plan` | 계획 모드 | O | O | 읽기 전용 작업 |
| `auto` | 자동 판단 | O | O | 컨텍스트에 따라 자동 |
| `dontAsk` | X 건너뜀 | O | O | 승인 없이 실행, hooks 결정은 반영 |

핵심 차이: `bypassPermissions`는 hooks 결정을 무시하지만, `dontAsk`는 hooks 결정을 반영한다.

## `-p` 모드에서 동작하지 않는 대화형 기능

| 기능 | 설명 |
|------|------|
| Notification hooks | 비대화형이라 Notification 이벤트 미발생 |
| `--verbose` / `--debug` (stderr) | stderr에 아무것도 출력하지 않음 (실제 `claude -p` 재검증 미수행) |
| 권한 프롬프트 (플래그 생략/manual) | TTY가 없어 표시 불가 → 도구 차단 가능 |
| 대화 계속 (Enter) | 단일 프롬프트 → 응답 → 종료 |
