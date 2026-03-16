---
name: managing-status-icons
description: |
  Manage status bar icons (Jira, Slack, Figma, Memo) for Claude Code sessions.
  Each session can have clickable OSC 8 hyperlink icons in the status bar.
  Links persist per session_id and survive --resume/--continue/compact.
  Triggers: "status icon", "상태바 아이콘", "jira 링크", "slack 링크",
  "figma 링크", "메모 열어", "아이콘 설정", "아이콘 수정", "아이콘 제거",
  "/managing-status-icons".
---

# Status Bar Icons 관리

세션별 상태바 아이콘 (Jira, Slack, Figma, Memo)을 관리한다.
SessionStart hook이 주입한 `additionalContext`에서 상태 파일 경로를 참조한다.

## 아이콘 목록

| 아이콘 | 키 | 색상 | 용도 |
|--------|-----|------|------|
| ⚡ | `jira` | yellow | Jira 이슈 링크 |
| 💬 | `slack` | magenta | Slack 채널/스레드 |
| 🎨 | `figma` | red | Figma 디자인 |
| 📓 | `memo` | green | 세션 메모 파일 |

## 상태 파일 구조

경로: `~/.claude/status-icons/<session-id>.json`

```json
{
  "jira": { "url": "https://example.atlassian.net/browse/PROJ-123", "label": "PROJ-123" },
  "slack": { "url": "https://app.slack.com/client/T.../C...", "label": "Slack" },
  "figma": { "url": "https://www.figma.com/design/...", "label": "Figma" },
  "memo": { "path": "/Users/glen/.claude/memos/<session-id>.md", "label": "Memo" }
}
```

## 아이콘 설정 (jq 명령어)

SessionStart hook의 `additionalContext`에서 상태 파일 경로를 확인한 후,
`STATE_FILE` 변수에 할당하여 사용한다:

```bash
# additionalContext에서 "상태 파일: /path/to/file.json"을 확인 후:
STATE_FILE="$HOME/.claude/status-icons/<session-id>.json"
```

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

## 아이콘 제거

```bash
# 특정 아이콘 제거 (예: figma)
tmp=$(mktemp) && jq 'del(.figma)' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
```

## 메모 파일

- 경로: `~/.claude/memos/<session-id>.md`
- SessionStart hook이 자동 생성 (빈 파일)
- 열기: `$EDITOR "$MEMO_FILE"` 또는 `open "$MEMO_FILE"` (macOS)
- status bar에서 📓 Memo Cmd+Click으로 `file://` URL을 통해 열 수 있음

## 동작 원리

- 새 세션/`/clear`: 새 상태 파일 + 메모 파일 생성, Memo만 초기값
- `--resume`/`--continue`: 기존 상태 파일 읽기, 모든 아이콘 유지
- `compact`: 동일하게 상태 재주입
- 30일 초과 파일은 자동 정리

## 주의사항

- `$STATE_FILE` 변수는 SessionStart hook의 `additionalContext`에서 확인
- jq로 상태 파일을 수정할 때 항상 임시 파일을 거쳐 atomic write
- 상태 파일이 없거나 JSON이 깨지면 아이콘 미표시 (graceful degradation)
