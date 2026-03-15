# `claude -p` 플래그 호환성 매트릭스

- 확인 날짜: **2026-03-15**
- 확인 버전: **Claude Code v2.1.76**
- 재검증: `claude -p --help` 출력과 비교

## `-p` 전용 플래그

`-p`/`--print` 모드에서만 사용 가능한 플래그 (`--help`에 `only works with --print` 표기).

| 플래그 | 설명 | 비고 |
|--------|------|------|
| `--output-format <FORMAT>` | 출력 형식: `text`(기본), `json`, `stream-json` | `json`은 JSON 배열, `stream-json`은 JSONL |
| `--no-session-persistence` | 세션 파일 미저장 | 동시 실행 시 충돌 방지에 유용 |
| `--max-turns <N>` | 최대 턴 수 제한 | ⚠️ `--help`에 미표시 (숨겨진 플래그). 최소 2턴이어야 도구 실행 가능 |
| `--max-budget-usd <AMOUNT>` | 최대 비용 제한 (USD) | 초과 시 exit code 0, subtype만 `error_max_budget_usd` |
| `--fallback-model <MODEL>` | 폴백 모델 지정 | 기본 모델 실패 시 대체 |
| `--input-format <FORMAT>` | 입력 형식 지정 | |
| `--include-partial-messages` | 부분 메시지 포함 | `stream-json`에서만 동작 |

## 범용 플래그 (대화형/비대화형 공통)

| 플래그 | 설명 | `-p` 모드에서의 동작 |
|--------|------|---------------------|
| `--model <MODEL>` | 모델 선택 (`sonnet`, `opus` 등) | 정상 동작 |
| `--system-prompt <PROMPT>` | 시스템 프롬프트 설정 | CLAUDE.md와 별개로 추가 |
| `--append-system-prompt <PROMPT>` | 기존 시스템 프롬프트에 **추가** (override 아님) | 기존 지시를 덮어쓰지 못함 |
| `--resume [SESSION_ID]` | 이전 세션 이어서 실행 | `-p`에서 세션 체이닝 가능 (인자 선택적) |
| `--dangerously-skip-permissions` | 권한 프롬프트 건너뛰기 | `-p`에서 도구 사용 시 거의 필수 |
| `--permission-mode <MODE>` | 권한 모드 설정 | `bypassPermissions` = `--dangerously-skip-permissions` |
| `--allowed-tools <TOOLS>` | 허용할 도구 목록 (쉼표 또는 공백 구분) | ⚠️ 인라인 프롬프트가 도구 이름으로 파싱됨 → stdin 필수 |
| `--tools <TOOLS>` | 활성화할 도구 지정 | `""` 지정 시 빌트인 비활성화, MCP는 남아있음 |
| `--disable-slash-commands` | 스킬(slash commands) 비활성화 | "Unknown skill" 반환 |
| `--debug-file <PATH>` | 디버그 로그를 파일에 기록 | `-p`에서 `--verbose`/`--debug`는 stderr 출력 없음, 이것이 유일한 디버그 수단 |
| `--permission-prompt-tool <TOOL>` | MCP 도구에 퍼미션 처리 위임 | ⚠️ `--help`에 미표시 (숨겨진 플래그). CI/CD 시스템에서 자체 퍼미션 UI 연동용 |

## 존재하지 않는 플래그

CLI에 없는 플래그. 사용 시도 시 에러 발생.

| 의도 | 존재하지 않는 플래그 | 올바른 대안 |
|------|---------------------|------------|
| 작업 디렉토리 변경 | `--cwd` | `cd dir && claude -p` |
| 결과 파일 저장 | `--output-file` / `-o` | shell redirect `> file` |

## 환경변수

| 환경변수 | 설명 | 비고 |
|----------|------|------|
| `CLAUDE_CODE_MAX_RETRIES` | API 재시도 횟수 | 기본값 오버라이드 (바이너리에서 확인) |
| `ANTHROPIC_API_KEY` | API 키 | 인증 필수 |

## `--permission-mode` 6종 비교

| 모드 | 권한 프롬프트 | hooks 호출 | hooks 결정 반영 | 용도 |
|------|:----------:|:--------:|:-----------:|------|
| `default` | 표시 (TTY 필요) | ✅ | ✅ | 기본값 (비대화형에서는 TTY 없어 도구 차단) |
| `acceptEdits` | 편집만 허용 | ✅ | ✅ | 파일 편집만 자동 승인 |
| `bypassPermissions` | ❌ 건너뜀 | ✅ | ❌ (passthrough) | = `--dangerously-skip-permissions` |
| `plan` | 계획 모드 | ✅ | ✅ | 읽기 전용 작업 |
| `auto` | 자동 판단 | ✅ | ✅ | 컨텍스트에 따라 자동 |
| `dontAsk` | ❌ 건너뜀 | ✅ | ✅ | 승인 없이 실행, hooks 결정은 반영 |

⚠️ 핵심 차이: `bypassPermissions`는 hooks 결정을 무시하지만, `dontAsk`는 hooks 결정을 반영한다.

## `-p` 모드에서 동작하지 않는 대화형 기능

| 기능 | 설명 |
|------|------|
| Notification hooks | 비대화형이라 Notification 이벤트 미발생 |
| `--verbose` / `--debug` (stderr) | stderr에 아무것도 출력하지 않음 |
| 권한 프롬프트 (default 모드) | TTY가 없어 표시 불가 → 도구 차단 |
| 대화 계속 (Enter) | 단일 프롬프트 → 응답 → 종료 |
