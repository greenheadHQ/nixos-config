---
name: configuring-claude-code
description: |
  Claude Code hooks, plugins, aliases, MCP, and settings.json.
  Triggers: "how to create a hook", "Claude 훅 설정", "add a plugin",
  "플러그인 설치", "claude alias", "--chrome flag", "claude settings",
  "claude 설정", "mcp.json", "settings read-only".
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

공통: `--data-urlencode` UTF-8 안전 인코딩, Pushover 1024자 상한. (`--max-time 4`는 `stop`/`plan` 훅에 적용)

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

## 핵심 절차

1. 수정 대상이 설정/훅/플러그인 중 무엇인지 먼저 분류한다.
2. `settings.json` 또는 훅 스크립트를 갱신한다.
3. 훅 스크립트 변경 시 `chmod +x`와 실행 경로를 검증한다.
4. 플러그인 설치/제거 후 `settings.json` 반영 상태를 확인한다.

## Shell Alias

파일: `modules/shared/programs/shell/default.nix`

```nix
c = "command claude${if pkgs.stdenv.isDarwin then " --chrome" else ""} --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json";
```

- macOS: `--chrome` 포함
- NixOS: `--chrome` 미포함

## 자주 발생하는 문제

1. 훅 실행 경로/JSON 출력 확인: 문제 재현 명령으로 훅 스크립트 출력을 점검
2. 플러그인 설치/삭제 실패: `settings.json` 쓰기 가능 여부 점검
3. 훅 JSON validation 에러: 훅 스크립트 출력 형식 점검
4. nix develop 필요한 git 동작: PreToolUse 래핑 스크립트 점검

## Codex 관련 안내

Codex 설정/호환 이슈는 `configuring-codex` 스킬을 사용합니다.

- trust/project scope: `configuring-codex`
- `.agents/skills` 투영/검증: `configuring-codex`
- `codex exec` 런타임 인식 확인: `configuring-codex`

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- 훅 상세: [references/hooks.md](references/hooks.md)
