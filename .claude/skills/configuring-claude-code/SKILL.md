---
name: configuring-claude-code
description: |
  This skill should be used when the user asks about Claude Code hooks, plugins,
  aliases, MCP, settings.json, or plugin development.
  Triggers: "how to create a hook", "Claude 훅 설정", "add a plugin",
  "플러그인 설치", "claude alias", "--chrome flag", "claude settings",
  "claude 설정", "mcp.json", "settings read-only", "plugin structure",
  "플러그인 개발", "hook events".
---

# Claude Code 설정

Claude Code 플러그인, 훅, alias, 플러그인 개발 설정을 다룹니다.

## 범위

- `~/.claude/settings.json`, `~/.claude/mcp.json` 관리
- Claude Code 플러그인 설치/제거/개발
- Hook 이벤트: PreToolUse, PostToolUse, Stop, SubagentStop, SessionStart, SessionEnd, UserPromptSubmit, PreCompact, Notification
- 플러그인 구조: `plugin.json`, `commands/`, `hooks/`, `skills/`, `agents/`
- shell alias (`c`) 설정

Codex 전용 설정과 장애 대응은 `configuring-codex` 스킬을 사용합니다.

## 빠른 참조

### 설정 파일 구조

```text
~/.claude/
├── settings.json          # 메인 설정 (mkOutOfStoreSymlink)
├── CLAUDE.md              # User-scope 지침 (mkOutOfStoreSymlink)
├── mcp.json               # MCP 서버 설정 (mkOutOfStoreSymlink)
├── hooks/                 # Pushover 알림 훅 (mkOutOfStoreSymlink, chmod +x 필수)
│   ├── stop-notification.sh   # Stop: 작업 완료 + 응답 텍스트 (뒤에서 자름, …앞)
│   ├── ask-notification.sh    # PreToolUse: 질문/선택지 텍스트
│   └── plan-notification.sh   # PreToolUse: 계획 파일 내용 (앞에서 자름, 뒤…)
├── plugins/               # 플러그인 디렉토리
│   └── <plugin-name>/     # 플러그인 루트 (plugin.json 필수)
│       ├── plugin.json    # 플러그인 매니페스트
│       ├── commands/      # 슬래시 커맨드 정의
│       ├── hooks/         # 훅 스크립트
│       ├── skills/        # 스킬 마크다운
│       └── agents/        # 에이전트 정의
├── skills/                # User-scope 스킬 (mkOutOfStoreSymlink)
└── plans/                 # 플랜 파일 디렉토리
```

`settings.json`, `CLAUDE.md`, `mcp.json`, `hooks/*.sh`는 모두 `mkOutOfStoreSymlink`로 연결되어 양방향 수정이 가능하며, nrs 없이 즉시 반영된다.

### Pushover 알림 훅 요약

| Hook | 이벤트 | 콘텐츠 소스 | 자르기 방향 | 말줄임표 |
|------|--------|-------------|-------------|----------|
| `stop-notification.sh` | Stop | transcript 마지막 응답 | 뒤에서 (마지막 N자 유지) | …앞에 |
| `ask-notification.sh` | PreToolUse(AskUserQuestion) | stdin JSON 질문/선택지 | 미적용 | 미적용 |
| `plan-notification.sh` | PreToolUse(ExitPlanMode) | `.claude/plans/*.md` 최신 파일 | 앞에서 (처음 N자 유지) | 뒤에… |

공통: `--data-urlencode` UTF-8 안전 인코딩, Pushover 1024자 상한. (`--max-time 4`는 `stop`/`plan` 훅에 적용)

### Hook 이벤트 전체 목록

| 이벤트 | 타이밍 | 용도 |
|--------|--------|------|
| `PreToolUse` | 도구 실행 전 | 도구 입력 검증/수정, 실행 차단 |
| `PostToolUse` | 도구 실행 후 | 결과 검증, 로깅 |
| `Stop` | 응답 완료 시 | 알림 발송, 후처리 |
| `SubagentStop` | 서브에이전트 완료 시 | 서브에이전트 결과 후처리 |
| `SessionStart` | 세션 시작 시 | 환경 초기화 |
| `SessionEnd` | 세션 종료 시 | 정리 작업 |
| `UserPromptSubmit` | 사용자 입력 전송 시 | 입력 전처리 |
| `PreCompact` | 컨텍스트 압축 전 | 압축 전 처리 |
| `Notification` | 알림 발생 시 | 커스텀 알림 라우팅 |

### 플러그인 관리

```bash
# 마켓플레이스 추가
/plugin marketplace add owner/repo

# 설치/제거/목록
/plugin install <name>@<marketplace>
/plugin uninstall <name>
/plugin
```

현재 활성 플러그인: `plugin-dev@claude-plugins-official`

### 플러그인 구조 (plugin.json)

```text
<plugin-name>/
├── plugin.json            # 매니페스트 (name, description, version)
├── commands/              # 슬래시 커맨드 (.md 파일, YAML frontmatter)
├── hooks/                 # 훅 스크립트 + prompt-based hooks
├── skills/                # 스킬 마크다운 (자동 로드)
└── agents/                # 에이전트 정의 (자동 로드)
```

### PreToolUse 훅 예시

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/validate.sh"
          }
        ]
      }
    ]
  }
}
```

## 핵심 절차

1. 수정 대상이 설정/훅/플러그인 중 무엇인지 먼저 분류한다.
2. `settings.json` 또는 훅 스크립트를 갱신한다.
3. 훅 스크립트 변경 시 `chmod +x`와 실행 경로를 검증한다.
4. 플러그인 설치/제거 후 `settings.json` 반영 상태를 확인한다.

## settings.json 주요 키

| 키 | 설명 |
|----|------|
| `cleanupPeriodDays` | 오래된 세션 정리 주기 (일) |
| `env` | 환경변수 (`MAX_THINKING_TOKENS`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` 등) |
| `permissions.deny` | 차단 명령어 패턴 |
| `permissions.additionalDirectories` | 추가 작업 디렉토리 |
| `hooks` | 훅 설정 (PreToolUse, Stop 등) |
| `enabledPlugins` | 활성 플러그인 맵 |
| `language` | 응답 언어 |
| `alwaysThinkingEnabled` | 상시 thinking 모드 |
| `plansDirectory` | 플랜 파일 저장 경로 |
| `skipDangerousModePermissionPrompt` | 위험 모드 프롬프트 스킵 |

## Shell Alias

파일: `modules/shared/programs/shell/default.nix`

```nix
c = "command claude${if pkgs.stdenv.isDarwin then " --chrome" else ""} --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json";
```

- macOS: `--chrome` 포함
- NixOS: `--chrome` 미포함

## Nix 모듈 관리

파일: `modules/shared/programs/claude/default.nix`

주요 activation:
- `installClaudeCode` - Claude Code 바이너리 설치 (curl)
- `ensureClaudeHooksTrust` - hooks trust 자동 주입 (`hasTrustDialogHooksAccepted`)
- `cleanStaleWorktreeSymlinks` - worktree stale 심링크 정리

모든 설정 파일은 `mkOutOfStoreSymlink`로 관리되어 양방향 수정이 가능합니다.

## 자주 발생하는 문제

1. 훅 실행 경로/JSON 출력 확인: 문제 재현 명령으로 훅 스크립트 출력을 점검
2. 플러그인 설치/삭제 실패: `settings.json` 쓰기 가능 여부 점검
3. 훅 JSON validation 에러: 훅 스크립트 출력 형식 점검
4. nix develop 필요한 git 동작: PreToolUse 래핑 스크립트 점검
5. hooks trust 미적용: `~/.claude.json` 파일에 `hasTrustDialogHooksAccepted` 누락 → `nrs` 재실행

## Codex 관련 안내

Codex 설정/호환 이슈는 `configuring-codex` 스킬을 사용합니다.

- trust/project scope: `configuring-codex`
- `.agents/skills` 투영/검증: `configuring-codex`
- `codex exec` 런타임 인식 확인: `configuring-codex`

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- 훅 상세: [references/hooks.md](references/hooks.md)
