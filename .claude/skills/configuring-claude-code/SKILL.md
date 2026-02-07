---
name: configuring-claude-code
description: |
  This skill should be used when the user asks "how to create a hook",
  "add a plugin", "claude alias", "--chrome flag", or encounters Claude Code
  configuration issues, settings.json read-only problems, ghost plugin issues.
  Covers PreToolUse/PostToolUse/Stop hooks, plugin installation, and shell alias.
---

# Claude Code 설정

Claude Code 플러그인 및 훅 설정 가이드입니다.

## Known Issues

**유령 플러그인**
- GUI에서 "설치됨"으로 표시되지만 활성화/비활성화 불가
- 해결: `~/.claude/settings.json`에서 수동 제거 후 CLI로 재설치

## 빠른 참조

### 설정 파일 구조

```
~/.claude/
├── settings.json          # 메인 설정 (Nix mkOutOfStoreSymlink, 양방향 수정 가능)
├── CLAUDE.md              # User-scope 지침 (Nix mkOutOfStoreSymlink, 양방향 수정 가능)
├── mcp.json               # MCP 서버 설정 (Nix mkOutOfStoreSymlink, 양방향 수정 가능)
├── settings.local.json    # 로컬 오버라이드 (수동 수정 가능)
└── plugins/               # 플러그인 디렉토리
```

**mkOutOfStoreSymlink 패턴**
- `settings.json`, `CLAUDE.md`, `mcp.json`은 Nix store가 아닌 실제 파일로 심볼릭 링크
- 양방향 수정 가능: Claude Code에서 변경하면 nixos-config repo에 바로 반영
- 소스 위치: `modules/shared/programs/claude/files/`

### 플러그인 관리

**선언적 관리 (settings.json)**

`extraKnownMarketplaces`와 `enabledPlugins`로 마켓플레이스 등록 및 플러그인 활성화:

```json
{
  "extraKnownMarketplaces": {
    "astral-sh": {
      "source": { "source": "github", "repo": "astral-sh/claude-code-plugins" }
    }
  },
  "enabledPlugins": {
    "plugin-dev@claude-plugins-official": true,
    "astral@astral-sh": true
  }
}
```

Claude Code 시작 시 자동으로 마켓플레이스 클론 + 플러그인 설치 진행.

**CLI 관리**

```bash
# 마켓플레이스 추가
/plugin marketplace add owner/repo

# 플러그인 설치/제거/목록
/plugin install <name>@<marketplace>
/plugin uninstall <name>
/plugin  # 대화형 UI
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

## Shell Alias 설정

**파일 위치**: `modules/shared/programs/shell/default.nix`

### c alias (Claude Code)

플랫폼별 동적 플래그 적용:

```nix
c = "command claude${if pkgs.stdenv.isDarwin then " --chrome" else ""} --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json";
```

| 플랫폼 | 결과 |
|--------|------|
| macOS | `command claude --chrome --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json` |
| NixOS | `command claude --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json` |

- `--chrome`: Claude in Chrome 브라우저 자동화 활성화 (GUI 필요, headless NixOS에서 비활성화)
- `--dangerously-skip-permissions`: 권한 확인 스킵
- `--mcp-config`: MCP 서버 설정 자동 로드

## 자주 발생하는 문제

1. **플러그인 설치 안 됨**: settings.json 권한 확인, CLI 사용
2. **JSON validation 에러**: 훅 스크립트 출력 형식 확인
3. **nix develop 필요**: git 명령어가 nix develop 환경 필요 시 래핑

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- 훅 설정 상세: [references/hooks.md](references/hooks.md)
