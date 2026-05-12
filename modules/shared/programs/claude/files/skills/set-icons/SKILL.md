---
# CIR: managing-status-icons → set-icons 이름 변경 — 스킬 이름이 과도하게 길어 간결화
name: set-icons
disable-model-invocation: true
description: |
  Set session status bar icons (Jira, Slack, Figma, Memo).
  Trigger: '상태바 아이콘', 'jira 링크', 'slack 링크', 'figma 링크', '아이콘 설정', '링크 변경'.
---

# 상태바 아이콘 관리

세션별 상태바 아이콘 (Jira, Slack, Figma, Memo)의 설정, 수정, 제거를 다룬다.
SessionStart hook이 상태 파일을 초기화하고, 이 스킬로 링크를 관리한다.
Memory 아이콘(🧠)은 statusline에서 자동 감지하므로 이 스킬과 무관하게 동작한다.

## 빠른 참조

| 아이콘 | 키 | 색상 | 용도 |
|--------|-----|------|------|
| ⚡ | `jira` | yellow | Jira 이슈 링크 |
| 💬 | `slack` | magenta | Slack 채널/스레드 |
| 🎨 | `figma` | red | Figma 디자인 |
| 📓 | `memo` | green | 세션 메모 파일 |
| 🧠 | (자동) | blue | Memory 파일 (auto-detect, worktree 공유, orphan 시 ⚠) |

### 상태 파일 구조

경로: `~/.claude/status-icons/<session-id>.json`

```json
{
  "jira": { "url": "https://example.atlassian.net/browse/PROJ-123", "label": "PROJ-123" },
  "slack": { "url": "https://app.slack.com/client/T.../C...", "label": "Slack" },
  "figma": { "url": "https://www.figma.com/design/...", "label": "Figma" },
  "memo": { "path": "$HOME/.claude/memos/<session-id>.md", "label": "Memo" }
}
```

### 상태 파일 경로 확인

SessionStart hook의 `additionalContext`에 상태 파일 경로가 표시된다.
대화 컨텍스트에서 `상태 파일:` 뒤의 경로를 `STATE_FILE`로 사용한다.

```bash
# additionalContext에서 "상태 파일: /path/to/file.json"을 확인 후:
STATE_FILE="$HOME/.claude/status-icons/<session-id>.json"
```

## 핵심 절차

### 대화형 설정

사용자가 `/set-icons`를 호출하거나 링크 설정을 요청하면,
AskUserQuestion으로 필요한 링크를 물어본다:

```json
{
  "questions": [
    {
      "header": "Jira",
      "question": "설정할 Jira 링크가 있나요?",
      "multiSelect": false,
      "options": [
        { "label": "건너뛰기", "description": "설정하지 않음" },
        { "label": "URL 입력", "description": "Other에 Jira URL을 입력해주세요" }
      ]
    },
    {
      "header": "Slack",
      "question": "설정할 Slack 링크가 있나요?",
      "multiSelect": false,
      "options": [
        { "label": "건너뛰기", "description": "설정하지 않음" },
        { "label": "URL 입력", "description": "Other에 Slack URL을 입력해주세요" }
      ]
    },
    {
      "header": "Figma",
      "question": "설정할 Figma 링크가 있나요?",
      "multiSelect": false,
      "options": [
        { "label": "건너뛰기", "description": "설정하지 않음" },
        { "label": "URL 입력", "description": "Other에 Figma URL을 입력해주세요" }
      ]
    }
  ]
}
```

사용자가 URL을 입력하면 아래 jq 명령어로 상태 파일을 업데이트한다.
Memo 아이콘도 스킬 호출 시 자동 등록한다 (메모 설정 섹션 참조).

> ⚠️ `jq -n` 사용 금지 — 기존 키가 덮어씌워진다.
> 반드시 기존 파일을 입력으로 사용: `tmp=$(mktemp) && jq '...' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"`

### Jira 설정

URL에서 이슈번호를 자동 추출한다:

```bash
# URL에서 이슈번호 추출: /browse/PROJ-123 → PROJ-123
JIRA_URL="https://example.atlassian.net/browse/PROJ-123"
JIRA_LABEL=$(echo "$JIRA_URL" | grep -oE '[A-Z]+-[0-9]+' | tail -1)

tmp=$(mktemp) && jq --arg url "$JIRA_URL" --arg label "$JIRA_LABEL" \
  '.jira = {"url":$url,"label":$label}' \
  "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
```

### Slack 설정

```bash
tmp=$(mktemp) && jq --arg url "https://app.slack.com/client/T.../C..." \
  '.slack = {"url":$url,"label":"Slack"}' \
  "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
```

### Figma 설정

```bash
tmp=$(mktemp) && jq --arg url "https://www.figma.com/design/..." \
  '.figma = {"url":$url,"label":"Figma"}' \
  "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
```

### 아이콘 제거

```bash
# 특정 아이콘 제거 (예: figma)
tmp=$(mktemp) && jq 'del(.figma)' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
```

### 메모 설정

메모 파일은 SessionStart hook이 자동 생성하지만, 아이콘은 스킬 호출 시 등록한다:

```bash
# MEMO_FILE은 additionalContext의 "메모:" 뒤 경로
tmp=$(mktemp) && jq --arg path "$MEMO_FILE" \
  '.memo = {"path":$path,"label":"Memo"}' \
  "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
```

- 경로: `~/.claude/memos/<session-id>.md`
- 상태바에서 📓 Memo Cmd+Click으로 `file://` URL을 통해 열 수 있다

## 동작 원리

| 상황 | 동작 |
|------|------|
| 새 세션 (cwd 첫 진입 또는 종료 후 재시작) | 빈 sidecar로 시작. 같은 cwd 마커는 startup이 건드리지 않음 (관리 책임은 Stop hook). |
| `/clear` | 같은 cwd 마커의 직전 sid에서 sidecar/memo deep clone 복원 — 같은 cwd에서 며칠 전 세션의 아이콘도 자동 복원된다(아카이빙 우선). |
| `--resume` / `--continue` | 기존 상태 파일 읽기, 모든 아이콘 유지 |
| `compact` | 동일하게 상태 재주입 |
| 자동 정리 | 없음 (아카이빙 우선) — sidecar/memo/마커는 사용자가 명시적으로 정리하기 전까지 보존 |

### Lineage 복원 (cwd 격리)

Stop hook(`record-last-session.sh`)이 매 턴 종료에 `~/.claude/status-icons/.last-session-<sha1(cwd)>` 마커 파일에 `session_id`를 atomic write한다. SessionStart hook은 새 sid에 sidecar가 없을 때 같은 cwd의 마커만 조회하므로, 동시에 진행 중인 다른 워크트리/프로젝트 세션과 아이콘이 섞이지 않는다.

marker 관리는 전적으로 Stop hook의 책임이다 — SessionStart hook은 startup에서 marker를 건드리지 않으므로, 같은 cwd에 두 인스턴스가 동시에 떠 있어도 새 인스턴스의 startup이 다른 인스턴스의 active marker를 덮어쓰지 않는다. 결과적으로 같은 cwd에서 며칠 전 세션 종료 후 다시 방문해 `/clear`/`/branch`를 하면 직전 세션의 아이콘이 자동 복원된다(아카이빙 우선).

자동 정리 로직은 없다. sidecar/메모/마커는 사용자가 명시적으로 정리하기 전까지 그대로 보존된다. storage 누적이 부담이 되면 별도 도구나 수동 정리로 처리한다.

## 자주 발생하는 문제

1. 아이콘 미표시: 상태 파일이 없거나 JSON 파싱 오류 → `cat "$STATE_FILE" | jq .`로 검증
2. 상태 파일 경로 불명: SessionStart hook의 `additionalContext`에서 `상태 파일:` 뒤의 경로 확인
3. memo 키 소실: `jq -n`으로 새 JSON 생성 시 기존 키가 사라짐 → 반드시 기존 파일을 입력으로 사용
4. 아이콘 순서/라인 변경 불가: 순서와 라인 배치는 `statusline.sh`에 하드코딩
   - L1 (link icons 그룹): Jira → Slack → Figma → Memo. 조건부 라인 (모두 미설정 시 라인 자체 생략)
   - L2 (context 라인):
     - 비-git cwd: cwd (📁) + session-id (🆔). branch 항목 자동 생략
     - git 메인 repo: cwd (📁) + branch (🌿) + session-id (🆔)
     - git 워크트리: cwd (📁) 단독
   - L3 (워크트리만): branch (🌿) + session-id (🆔)
   - L_M (heavy state 그룹): Plan (📝) → Memory (🧠) → Cache TTL (⏱). Memo는 L1으로 이동, Plan/Memory는 L_M 유지
   - L_N: 5h/7d Rate Limits
5. SessionStart hook 동작 (source별):
   - 지원 source는 `startup`, `clear`, `resume`, `compact` 네 가지. 그 외 source는 hook이 즉시 `exit 0`로 skip한다 (sidecar/memo는 생성하지 않음).
   - startup: STATE_FILE이 부재하면 빈 객체 `{}`로 시작. 동일 sid로 startup이 재발화되면 STATE_FILE을 보존(아이콘 유실 방지). cwd 마커는 startup이 건드리지 않는다 (관리 책임은 Stop hook).
   - clear / resume / compact: STATE_FILE이 부재하면 ① 같은 cwd 마커의 직전 sid sidecar에서 deep clone → ② 실패 시 빈 객체 `{}`. STATE_FILE이 이미 존재하면 그대로 사용.
   - 마커는 Stop hook이 매 턴 종료에 cwd-sha1로 인코딩된 파일에 sid를 기록해 누적한다. 글로벌 mtime 기반 탐색은 사용하지 않으므로 동시 실행 중인 다른 cwd 세션과 아이콘이 섞이지 않는다.
   - 실제 source 라벨링이 의심되면(예: `/clear` 후 아이콘이 사라지는 증상이 재현되면) `CLAUDE_HOOK_DEBUG=1`로 hook을 재기동해 `~/.claude/logs/session-hooks.log`를 채집한 뒤 source 매핑을 확인한다.
6. OSC 8 hyperlink 클릭 UX (macOS Ghostty + Claude Code fullscreen):
   - 일반 Cmd+클릭 — Plan/Memo/Memory 같은 `file://` link는 Ghostty plain-text URL fallback detector로 동작 (Jira/Slack/Figma 같은 `https://`도 동작)
   - Cmd+Shift+클릭 — Claude Code TUI(`CLAUDE_CODE_NO_FLICKER` fullscreen 모드)가 mouse capture로 일반 Cmd+클릭을 가로채는 영역에서 escape hatch. cwd (`vscode://file/<path>/`) 처럼 fallback detector가 인식 못 하는 scheme은 Cmd+Shift+클릭으로만 동작
   - 관련 upstream issue: anthropics/claude-code#26356, #37216, #45173 (mouse capture 회귀 미해결)

## 주의사항

- `$STATE_FILE` 변수는 SessionStart hook의 `additionalContext`에서 확인한다
- jq로 상태 파일을 수정할 때 항상 임시 파일을 거쳐 atomic write한다
- 상태 파일이 없거나 JSON이 깨지면 아이콘 미표시 (graceful degradation)
- `statusline.sh`나 hook 스크립트 수정은 관련 소스 코드를 직접 참조한다
