# User-scope Instructions

## 스킬 라우팅

| 키워드                                                                     | 스킬                    |
| -------------------------------------------------------------------------- | ----------------------- |
| agent-browser, 웹 자동화, 헤드리스 브라우저, 스크래핑, 폼 자동화           | `agent-browser`         |
| codex sync, codex harness, codex 동기화, codex 투영                        | `syncing-codex-harness` |
| karpathy, coding guidelines, 코딩 가이드라인, 오버 엔지니어링, YAGNI, NGMI | `karpathy-guidelines`   |
| GitHub Issues, 이슈, todo, 라벨, backlog, 우선순위, 등록, 조회, 부채, audit | `managing-github-issues` |

## 필수 스킬

코드 작성, 리뷰, 리팩터링, 버그 수정, 기능 구현 등 코딩 관련 작업 시작 시 반드시 `/karpathy-guidelines` 스킬을 먼저 호출하세요.

## Python (Astral)

Python 프로젝트 작업 시 /astral:<skill>을 호출하세요.

- `/astral:uv` - uv package manager
- `/astral:ty` - ty type checker
- `/astral:ruff` - ruff linter/formatter

### 브라우저 자동화 도구 선택

- **NixOS (Platform: linux)**: 항상 `agent-browser` 사용. Claude in Chrome 미지원 환경.
- **macOS (Platform: darwin)**: AskUserQuestion으로 사용자에게 도구 선택을 물어보세요.
  - **Claude in Chrome**: 실제 Chrome 브라우저 제어. 기존 로그인 세션 활용 가능, 시각적 확인 가능
  - **agent-browser**: 헤드리스 CLI 도구. 독립 Chromium 사용, 인증 상태는 별도 관리 필요 (state save/load)

이 규칙은 agent-browser 스킬의 자동 트리거보다 우선합니다.

NixOS/nix-darwin 환경에서 agent-browser 문제 발생 시 `~/.claude/skills/agent-browser/references/troubleshooting.md` 참조.
