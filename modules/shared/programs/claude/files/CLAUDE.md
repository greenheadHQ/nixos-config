# User-scope Instructions

## 사고 언어

내부 사고(thinking)를 항상 한국어로 수행하라. 영어로 사고하지 마라.

## skill-creator 스크립트 Override

skill-creator 플러그인의 Python 스크립트 직접 호출 금지. 아래 셸 대체물을 사용하라. SKILL.md에 `python`으로 적혀 있어도 `python3`로 실행. 플래그는 `--help`로 확인.

| 플러그인 원본 | Override |
|---|---|
| `improve_description.py` | `~/.claude/scripts/improve-description.sh` |
| `run_eval.py` | `~/.claude/scripts/run-eval.sh` |
| `run_loop.py` | `~/.claude/scripts/run-loop.sh` |

## Superpowers 플러그인 라우팅

해당 Superpowers 스킬의 트리거가 감지되면 아래 대체 스킬로 라우팅한다.

| 비활성 Superpowers 스킬 | 대체 |
|---|---|
| `requesting-code-review` | `run-da` |
| `receiving-code-review` | `run-da` protocol |
| `dispatching-parallel-agents` | `parallel-audit` |
| `finishing-a-development-branch` | `create-pr` |
| `executing-plans` | `plan-with-questions` |
| `subagent-driven-development` | 미사용 |

활성 유지: `using-superpowers`, `brainstorming`, `writing-plans`, `test-driven-development`, `systematic-debugging`, `verification-before-completion`, `using-git-worktrees`, `writing-skills` (최종 검토: v5.0.6 기준).

## 브라우저 도구 라우팅

현재 구성: MCP=기존 Chrome autoConnect, PW=독립 Playwright 브라우저. 구성 변경 시 재검토.
chrome-devtools MCP는 macOS 전용 (NixOS에서는 미구성).

| 용도 | 권장 도구 | 이유 |
|------|-----------|------|
| 웹 탐색/폼 자동화/스크린샷 | playwright-cli | 토큰 효율 + 크로스 브라우저 + 코드 생성 |
| 디버깅/성능 분석/Lighthouse | chrome-devtools MCP | Core Web Vitals/Lighthouse/힙 스냅샷 대체 불가 |
| 기존 Chrome 세션 디버깅 | chrome-devtools MCP | autoConnect로 기존 탭/세션 즉시 접근 |
| 네트워크 인터셉트 | playwright-cli | route/unroute 명령 |
| 메모리 누수 탐지 | chrome-devtools MCP | 힙 스냅샷 전용 |
