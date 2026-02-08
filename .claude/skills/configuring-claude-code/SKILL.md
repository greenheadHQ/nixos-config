---
name: configuring-claude-code
description: |
  This skill should be used when the user asks "how to create a hook",
  "add a plugin", "claude alias", "--chrome flag", "codex config",
  "codex setup", "agents.md", ".agents/skills sync", or encounters Claude Code
  / Codex CLI configuration issues, settings.json read-only problems, ghost
  plugin issues, Codex skill discovery failures, trust settings.
  Covers PreToolUse/PostToolUse/Stop hooks, plugin installation, shell alias,
  and Codex CLI compatibility layer.
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

## Codex CLI 호환 구조

Codex CLI에서도 동일한 스킬을 사용할 수 있도록 호환 레이어가 구축되어 있다.

### 아키텍처 (원본 → 파생)

```
.claude/skills/<name>/SKILL.md  ← 단일 원본 (수동 관리)
       ↓ 심링크 (nrs 시 자동)
.agents/skills/<name>/SKILL.md  ← Codex 발견용 투영
.agents/skills/<name>/agents/openai.yaml  ← Codex UI 메타데이터 (자동 생성)

CLAUDE.md  ← 프로젝트 지침 (수동 관리)
       ↓ 심링크
AGENTS.md  ← Codex용 (자동 생성)

AGENTS.override.md  ← Codex 전용 보충 규칙 (수동 관리, Git 추적)
```

### 핵심: Trust 설정

`~/.codex/config.toml`에 프로젝트 trust가 없으면 `.agents/skills/` 전체가 무시됨:

```toml
[projects."/Users/green/IdeaProjects/nixos-config"]
trust_level = "trusted"
```

### Nix 모듈

- 소스: `modules/shared/programs/codex/default.nix`
- `nrs` 실행 시 자동으로 `.agents/skills/` 심링크 + openai.yaml 생성
- 글로벌 설정(`~/.codex/config.toml`, `~/.codex/AGENTS.md`)도 Nix 관리

### Claude 전용 / Codex 비대응 기능

| 기능 | Claude Code | Codex CLI |
|------|-------------|-----------|
| PreToolUse 훅 | 지원 (git wrapper 등) | 미지원 |
| Pushover 알림 | Stop/Ask/Plan 훅 | `notify` 설정 (별도 구현) |
| 플러그인 마켓플레이스 | 지원 | 미지원 |
| MCP UI (claude mcp add) | JSON (.mcp.json) | TOML (config.toml [mcp_servers]) |

### 검증 및 장애 대응

```bash
# 호환 구조 검증
./scripts/ai/verify-ai-compat.sh

# 깨진 심링크 복구
nrs  # Nix 재빌드로 자동 복구

# 스킬 추가/삭제 후
nrs  # activation script가 .agents/skills/ 자동 동기화
```

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- 훅 설정 상세: [references/hooks.md](references/hooks.md)
