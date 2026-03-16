---
name: managing-status-icons
description: |
  Manage status bar icons (Jira, Slack, Figma, Memo) for Claude Code sessions.
  Memory icon is auto-detected by statusline.sh and displayed separately.
  Each session has clickable OSC 8 hyperlink icons in the status bar.
  Links persist per session_id and survive --resume/--continue/compact.
  NOT for modifying statusline.sh or hook scripts (use configuring-claude-code).
  Triggers: "status icon", "상태바 아이콘", "jira 링크", "slack 링크",
  "figma 링크", "메모 열어", "아이콘 설정", "아이콘 수정", "아이콘 제거",
  "링크 변경", "/managing-status-icons".
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

사용자가 `/managing-status-icons`를 호출하거나 링크 설정을 요청하면,
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
| 새 세션 / `/clear` | 빈 상태 파일 + 메모 파일 생성, 아이콘 없음 |
| `--resume` / `--continue` | 기존 상태 파일 읽기, 모든 아이콘 유지 |
| `compact` | 동일하게 상태 재주입 |
| 30일 초과 | 상태 파일 + 메모 파일 자동 정리 |

## 자주 발생하는 문제

1. **아이콘 미표시**: 상태 파일이 없거나 JSON 파싱 오류 → `cat "$STATE_FILE" | jq .`로 검증
2. **상태 파일 경로 불명**: SessionStart hook의 `additionalContext`에서 `상태 파일:` 뒤의 경로 확인
3. **memo 키 소실**: `jq -n`으로 새 JSON 생성 시 기존 키가 사라짐 → 반드시 기존 파일을 입력으로 사용
4. **아이콘 순서 변경 불가**: 순서는 `statusline.sh`에 하드코딩 (Jira → Slack → Figma → Plan → Memo → Memory)

## 주의사항

- `$STATE_FILE` 변수는 SessionStart hook의 `additionalContext`에서 확인한다
- jq로 상태 파일을 수정할 때 항상 임시 파일을 거쳐 atomic write한다
- 상태 파일이 없거나 JSON이 깨지면 아이콘 미표시 (graceful degradation)
- `statusline.sh`나 hook 스크립트 수정은 `configuring-claude-code` 스킬을 참조한다
