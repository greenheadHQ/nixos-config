# User-scope Instructions

## Python (Astral)

When working with Python, invoke the relevant /astral:<skill> for uv, ty, and ruff to ensure best practices are followed.

- `/astral:uv` - uv package manager
- `/astral:ty` - ty type checker
- `/astral:ruff` - ruff linter/formatter

## 브라우저 자동화 도구 선택

브라우저 자동화가 필요할 때, 반드시 AskUserQuestion 도구로 사용자에게 어떤 도구를 사용할지 물어보세요:

| 키워드 | 스킬 |
|--------|------|
| agent-browser, 웹 자동화, 헤드리스 브라우저, 스크래핑, 폼 자동화 | `agent-browser` |

- **Claude in Chrome**: 사용자의 실제 Chrome 브라우저 제어. 기존 로그인 세션 활용 가능, 시각적 확인 가능
- **agent-browser**: 헤드리스 CLI 도구. 독립 Chromium 사용, SSH/CI에서도 동작, 인증 상태는 별도 관리 필요 (state save/load)

이 규칙은 agent-browser 스킬의 자동 트리거보다 우선합니다.

NixOS/nix-darwin 환경에서 agent-browser 문제 발생 시 `~/.claude/skills/agent-browser/references/troubleshooting.md` 참조.
