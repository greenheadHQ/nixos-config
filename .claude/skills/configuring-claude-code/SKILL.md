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

**settings.json 읽기 전용**
- Nix로 관리되는 settings.json은 읽기 전용
- 플러그인 설치/삭제는 CLI 명령어로만 가능
- GUI에서 수정 시도 시 에러 발생

**유령 플러그인**
- GUI에서 "설치됨"으로 표시되지만 활성화/비활성화 불가
- 해결: `~/.claude/settings.json`에서 수동 제거 후 CLI로 재설치

## 빠른 참조

### 설정 파일 구조

```
~/.claude/
├── settings.json          # 메인 설정 (Nix 관리, 읽기 전용)
├── settings.local.json    # 로컬 오버라이드 (수동 수정 가능)
└── plugins/               # 플러그인 디렉토리
```

**mkOutOfStoreSymlink 패턴**
- `settings.json`은 Nix store가 아닌 실제 파일로 심볼릭 링크
- 양방향 수정 가능하도록 설계

### 플러그인 관리

```bash
# 플러그인 설치
claude plugins install <plugin-path>

# 플러그인 제거
claude plugins uninstall <plugin-name>

# 설치된 플러그인 목록
claude plugins list
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
