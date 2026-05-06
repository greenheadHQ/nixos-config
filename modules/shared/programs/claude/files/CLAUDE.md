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

## Durable output pinning policy

- 커밋 메시지, PR/이슈 본문/댓글, markdown, shell, notebook, body temp 파일에는 일회성 리뷰/세션 메타데이터를 박제하지 말라.
- Claude/Codex PreToolUse `pinning-guard.sh`는 supported edit/apply_patch tools와 targeted git/gh durable commands에서 해당 메타데이터가 새 durable output으로 들어가면 hard-fail한다.
- PostToolUse `pinning-alert.sh`와 commit-msg `commit-msg-pinning.sh`는 같은 shared pattern library를 사용하는 warn-only 보조 신호다.
- Canonical non-traversal PRD/plan path(`.claude/prds/*`, `.claude/plans/*`)에서는 PATTERN_A만 예외적으로 허용한다. PATTERN_B/C/D는 해당 path에서도 계속 차단/경고한다.
- 차단되면 리뷰 실행명, 임시 finding id, 짧은 임시 hash 대신 안정적인 대상 이름과 자연어 근거로 다시 작성한다.

## 브라우저 도구 라우팅

현재 구성: MCP=기존 Chrome autoConnect, PW=독립 Playwright 브라우저 + remote-debugging 활성 세션 attach. 구성 변경 시 재검토.
chrome-devtools MCP는 macOS 전용 (NixOS에서는 미구성).

| 용도 | 권장 도구 | 이유 |
|------|-----------|------|
| 웹 탐색/폼 자동화/스크린샷 | playwright-cli | 토큰 효율 + 크로스 브라우저 + 코드 생성 |
| 디버깅/성능 분석/Lighthouse | chrome-devtools MCP | Core Web Vitals/Lighthouse/힙 스냅샷 대체 불가 |
| 기존 Chrome 세션 디버깅 | chrome-devtools MCP | autoConnect로 기존 탭/세션 즉시 접근 |
| 원격 디버깅 활성 Chrome/Edge 세션 자동화+코드 생성 | playwright-cli | 실행 중인 브라우저에 attach하여 자동화 + TS 코드 생성 (playwright-cli 설치 host 한정, 선행: remote debugging 승인, CDP loopback-only, 민감 작업은 daily-use 프로필 대신 전용 프로필 권장) |
| 네트워크 인터셉트 | playwright-cli | route/unroute 명령 |
| 메모리 누수 탐지 | chrome-devtools MCP | 힙 스냅샷 전용 |

**보안 주의**: remote debugging 활성 세션은 제어 표면이 증가한다. 금융/개인정보/관리자 콘솔 같은 민감 업무는 daily-use 프로필 대신 전용 브라우저 세션을 권장한다. 회사 보안 정책이 remote debugging 자체를 막을 수 있다.

**최초 활성화 및 장애 대응** (chrome-devtools MCP autoConnect):
- 초기 1회 수동 활성화/승인 필요. Chrome을 `--remote-debugging-port=9222`로 기동 (Hammerspoon launcher 또는 CLI) 후 `chrome://inspect/#remote-debugging`에서 연결 확인 및 승인 프롬프트 허용.
- `Could not find DevToolsActivePort file` 에러 시: 기존 Chrome 세션 종료 후 재기동. Chrome 프로필 경로가 잠겨 있으면 전용 프로필(`--user-data-dir=...`) 사용.
- 자동화 스크립트는 편의 기능이다. 브라우저/조직 보안 정책(remote debugging 차단 등)을 우회하지 않는다.
