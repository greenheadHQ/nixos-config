---
name: archive
disable-model-invocation: true
description: |
  Archive Claude Code session data to ~/.claude/archive/.
  Trigger: '/archive', '세션 아카이빙', '세션 백업', '세션 보관'.
---

# 세션 아카이빙

Claude Code 세션 데이터(대화, 아이콘, 메모)를 `~/.claude/archive/`에 아카이빙한다.
worktree 삭제 후에도 세션을 보존하고, `recall` TUI로 열람할 수 있다.

## 사용법

Bash tool로 스크립트를 실행한다. `$ARGUMENTS`에서 플래그를 추출하여 전달한다.

### 현재 세션 아카이빙 (기본)

```bash
~/.claude/scripts/claude-archive.sh
```

### 모든 세션 (현재 CWD)

```bash
~/.claude/scripts/claude-archive.sh --all
```

### 프로젝트 전체 (메인 + worktree)

```bash
~/.claude/scripts/claude-archive.sh --project
```

### 아카이브 목록

```bash
~/.claude/scripts/claude-archive.sh --list
```

### 세션 복원

```bash
~/.claude/scripts/claude-archive.sh --restore <session-id>
```

복원 후 `claude --resume <session-id>`로 세션을 재개할 수 있다.
단, 세션 파일만 복원되며 브랜치/코드 컨텍스트는 복원되지 않는다.

### TUI 열람

```bash
recall
```

recall이 `~/.claude/archive/` 아래 JSONL도 자동으로 스캔한다.

## 아카이브 구조

```
~/.claude/archive/<project>/<uuid>/
├── <uuid>.jsonl        # 원본 대화 데이터
├── <uuid>.md           # Markdown 변환본
├── subagents/          # 서브에이전트 대화
├── status-icons.json   # 상태바 아이콘
├── memo.md             # 세션 메모
└── meta.json           # 메타데이터
```
