---
name: configuring-claude-code
description: |
  Claude Code hooks, plugins, aliases, MCP, and settings.json.
  Triggers: "how to create a hook", "add a plugin", "claude alias",
  "--chrome flag", "claude settings", "mcp.json", PreToolUse/PostToolUse/Stop
  hooks, plugin installation, ghost plugin issues, settings read-only.
---

# Claude Code 설정

Claude Code 플러그인, 훅, alias 설정을 다룹니다.

## 범위

- `~/.claude/settings.json`, `~/.claude/mcp.json` 관리
- Claude Code 플러그인 설치/제거
- PreToolUse/PostToolUse/Stop 훅
- shell alias (`c`) 설정

Codex 전용 설정과 장애 대응은 `configuring-codex` 스킬을 사용합니다.

## 빠른 참조

### 설정 파일 구조

```text
~/.claude/
├── settings.json          # 메인 설정 (mkOutOfStoreSymlink)
├── CLAUDE.md              # User-scope 지침 (mkOutOfStoreSymlink)
├── mcp.json               # MCP 서버 설정 (mkOutOfStoreSymlink)
├── settings.local.json    # 로컬 오버라이드
├── hooks/                 # Pushover 알림 훅 (mkOutOfStoreSymlink, chmod +x 필수)
│   ├── stop-notification.sh   # Stop: 작업 완료 + 응답 텍스트 (뒤에서 자름, …앞)
│   ├── ask-notification.sh    # PreToolUse: 질문/선택지 텍스트
│   └── plan-notification.sh   # PreToolUse: 계획 파일 내용 (앞에서 자름, 뒤…)
└── plugins/               # 플러그인 디렉토리
```

`settings.json`, `CLAUDE.md`, `mcp.json`, `hooks/*.sh`는 모두 `mkOutOfStoreSymlink`로 연결되어 양방향 수정이 가능하며, nrs 없이 즉시 반영된다.

### Pushover 알림 훅 요약

| Hook | 이벤트 | 콘텐츠 소스 | 자르기 방향 | 말줄임표 |
|------|--------|-------------|-------------|----------|
| `stop-notification.sh` | Stop | transcript 마지막 응답 | 뒤에서 (마지막 N자 유지) | …앞에 |
| `ask-notification.sh` | PreToolUse(AskUserQuestion) | stdin JSON 질문/선택지 | 미적용 | 미적용 |
| `plan-notification.sh` | PreToolUse(ExitPlanMode) | `.claude/plans/*.md` 최신 파일 | 앞에서 (처음 N자 유지) | 뒤에… |

공통: `--max-time 4` curl 타임아웃, `--data-urlencode` UTF-8 안전 인코딩, Pushover 1024자 상한.

### 플러그인 관리

```bash
# 마켓플레이스 추가
/plugin marketplace add owner/repo

# 설치/제거/목록
/plugin install <name>@<marketplace>
/plugin uninstall <name>
/plugin
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

## Shell Alias

파일: `modules/shared/programs/shell/default.nix`

```nix
c = "command claude${if pkgs.stdenv.isDarwin then " --chrome" else ""} --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json";
```

- macOS: `--chrome` 포함
- NixOS: `--chrome` 미포함

## 자주 발생하는 문제

1. 플러그인 설치/삭제 실패: `settings.json` 쓰기 가능 여부 점검
2. 훅 JSON validation 에러: 훅 스크립트 출력 형식 점검
3. nix develop 필요한 git 동작: PreToolUse 래핑 스크립트 점검

## Codex 관련 안내

Codex 설정/호환 이슈는 `configuring-codex` 스킬을 사용합니다.

- trust/project scope: `configuring-codex`
- `.agents/skills` 투영/검증: `configuring-codex`
- `codex exec` 런타임 인식 확인: `configuring-codex`

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- 훅 상세: [references/hooks.md](references/hooks.md)
