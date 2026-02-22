# Chrome DevTools MCP (autoConnect) 상세 사용 가이드

이 문서는 macOS 환경에서 `chrome-devtools-mcp`를 Codex CLI/Claude Code에서 실제로 사용하는 전체 절차를 설명한다.
이 저장소의 현재 전략은 `--autoConnect --channel=stable`이며, 핵심은 "기본 프로필 + 정책 충돌 없이" DevTools MCP를 안정적으로 쓰는 것이다.

## 1. 이 가이드가 해결하는 문제

`chrome-devtools-mcp`는 설치만 해서는 바로 동작하지 않는다. 특히 `--autoConnect` 전략은 초기 1회 사용자 승인 단계가 필요하다.
이 문서는 아래를 한 번에 해결하도록 구성했다.

1. 어떤 파일이 설정되는지
2. 최초 1회에 사용자가 무엇을 눌러야 하는지
3. Codex/Claude에서 연결 성공을 어떻게 검증하는지
4. 실패 시 어디를 확인해야 하는지

## 2. 적용 범위와 관련 파일

- 대상 OS: macOS (`nix-darwin`)
- MCP 설정 파일:
  - `modules/shared/programs/claude/files/mcp.darwin.json`
  - `modules/shared/programs/codex/files/config.darwin.toml`
- autoConnect 보조 스크립트/단축키:
  - `modules/darwin/programs/hammerspoon/files/ensure-chrome-autoconnect.sh`
  - `modules/darwin/programs/hammerspoon/files/init.lua`

## 3. 사전 준비 체크리스트

아래 4개가 모두 충족되어야 한다.

1. 최신 설정 적용 완료
```bash
~/.local/bin/nrs.sh
```

2. Google Chrome Stable 설치
- `/Applications/Google Chrome.app` 가 존재해야 함

3. Hammerspoon 실행 중
- 단축키 `Ctrl + Option + Cmd + C`를 사용하려면 필수

4. Node.js + npx 사용 가능
```bash
npx --version
```

## 4. autoConnect 전략 핵심

- 기존 `--browser-url=http://127.0.0.1:9222` 강제 방식은 기본 프로필 보안 정책과 충돌 가능성이 높다.
- 현재는 Chrome 공식 권장 경로인 `--autoConnect`를 사용한다.
- 단, 초기 1회(또는 정책 리셋 후)에는 사용자가 직접 `chrome://inspect/#remote-debugging`에서 remote debugging을 활성화/승인해야 한다.

## 5. 최초 1회 활성화 절차 (가장 중요)

아래를 순서대로 수행한다.

1. Chrome 실행
2. `chrome://inspect/#remote-debugging` 열기
3. Remote Debugging 활성화
4. 승인 프롬프트가 나오면 허용

편의 방법:
- 단축키 `Ctrl + Option + Cmd + C`를 누르면 스크립트가 Chrome을 띄우고 inspect 페이지를 연다.
- 동일 동작 CLI:
```bash
~/.local/bin/ensure-chrome-autoconnect.sh
```

## 6. 설정 반영 확인 (정적 검증)

### 6.1 Codex
```bash
codex mcp list
```

확인 포인트:
- 서버 이름: `chrome-devtools`
- args에 `--autoConnect`, `--channel=stable`, `--no-usage-statistics` 존재

### 6.2 Claude
```bash
cat ~/.claude/mcp.json
```

확인 포인트:
- `mcpServers.chrome-devtools.args`에 `--autoConnect`, `--channel=stable` 포함

## 7. 런타임 검증 (실제 사용 테스트)

### 7.1 Codex에서 1회 호출 테스트
```bash
codex exec --dangerously-bypass-approvals-and-sandbox \
  "Use the chrome-devtools MCP server tool that lists pages exactly once, then print only that tool result."
```

성공 판단:
- `No page selected` 또는 페이지 목록 JSON이 나오면 MCP 연결 자체는 성공

### 7.2 Claude에서 1회 호출 테스트
```bash
echo "Use mcp__chrome-devtools__list_pages exactly once and print raw result." \
| claude -p \
  --permission-mode bypassPermissions \
  --strict-mcp-config \
  --mcp-config ~/.claude/mcp.json \
  --allowedTools "mcp__chrome-devtools__list_pages"
```

성공 판단:
- `No page selected` 또는 페이지 목록이 출력되면 정상

## 8. 일상 사용 절차 (권장 운영 플로우)

1. Chrome 실행
2. 필요하면 `Ctrl+Option+Cmd+C`로 inspect 페이지를 열어 remote debugging 상태 확인
3. Codex/Claude 세션 시작
4. `list_pages` 같은 읽기 도구로 먼저 연결 상태 확인
5. 이후 `new_page`, `navigate_page`, `click`, `evaluate_script` 등 작업 도구 사용

## 9. 문제 해결 매뉴얼

### 증상 A: `Could not find DevToolsActivePort ...`
원인:
- 초기 승인 미완료
- inspect 페이지에서 remote debugging 비활성

조치:
1. `Ctrl+Option+Cmd+C`
2. `chrome://inspect/#remote-debugging`에서 토글 활성화
3. 승인 프롬프트 수락
4. 재시도

### 증상 B: `Could not connect to Chrome ...`
원인:
- Chrome 미실행
- Chrome 채널/세션 상태 불일치

조치:
1. Chrome 실행 확인
2. inspect 페이지 다시 열어 상태 확인
3. MCP 도구 재호출

### 증상 C: 단축키 눌러도 반응 없음
조치:
1. Hammerspoon config reload
2. 스크립트 존재 확인
```bash
ls -l ~/.local/bin/ensure-chrome-autoconnect.sh
```
3. 스크립트 단독 실행
```bash
~/.local/bin/ensure-chrome-autoconnect.sh
```

### 증상 D: `npx` 관련 에러 (`ENOENT`, `command not found`)
조치:
1. Node.js 설치/경로 확인
```bash
npx --version
```
2. 쉘 재시작 후 재시도
3. `nrs` 재적용 후 재확인

## 10. 보안/운영 주의사항

- remote debugging이 활성화된 세션은 제어 표면이 증가한다.
- 금융/개인정보/관리자 콘솔 같은 민감 업무는 별도 브라우저 세션 권장.
- 회사 보안 정책이 remote debugging 자체를 막을 수 있다.
- 자동화 스크립트는 편의 기능이며, Chrome 정책 제한을 우회하지 않는다.

## 11. Worktree/심볼릭 링크 주의

Home Manager 링크 타깃이 메인 레포를 가리키는 환경에서는, worktree 전용 파일이 링크 경로와 불일치할 수 있다.
merge 전에는 실제 런타임 파일 링크를 반드시 확인한다.

```bash
ls -l ~/.claude/mcp.json ~/.codex/config.toml
readlink ~/.claude/mcp.json
readlink ~/.codex/config.toml
```

## 12. 실패 시 대안 전략

`autoConnect`가 조직 정책 또는 환경 특성 때문에 반복 실패하면 아래 대안을 고려한다.

1. 전용 프로필 + `--browser-url`
- 안정적 자동화에 유리
- 기본 프로필 재사용 요구사항과는 상충

2. Chrome for Testing 기반 분리 환경
- CI/재현성에 유리
- 개인 기본 프로필과 거리가 있음

## 13. 30초 점검 체크리스트

1. `~/.local/bin/nrs.sh` 적용 완료
2. `codex mcp list`에 `chrome-devtools` 표시
3. args에 `--autoConnect --channel=stable` 확인
4. `Ctrl+Option+Cmd+C`로 inspect 페이지 열기
5. `list_pages` 1회 호출 성공
