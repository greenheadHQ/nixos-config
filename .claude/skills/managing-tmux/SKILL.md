---
name: managing-tmux
description: |
  tmux config: keybindings, prefix, plugins, resurrect, notepad.
  Triggers: "pane notepad", "tmux plugins", "tmux-resurrect",
  "session save/restore", "tmux.conf configuration",
  "prefix key", "session management", "tmux 설정", "tmux 단축키".
---
# tmux 설정

터미널 멀티플렉서 tmux 설정 및 단축키 가이드입니다.

## 목적과 범위

tmux 기본 동작, 플러그인, Pane Notepad 워크플로우를 다룬다.

## 빠른 참조

### 주요 설정 파일

| 파일 | 용도 |
|------|------|
| `modules/shared/programs/tmux/default.nix` | Home Manager tmux 모듈 (플러그인 포함) |
| `modules/shared/programs/tmux/files/tmux.conf` | tmux 설정 파일 |
| `modules/shared/programs/tmux/files/scripts/` | Pane Notepad + 보조 스크립트 |

### 주요 스크립트

| 스크립트 | 용도 |
|------|------|
| `prefix-help.sh` | `prefix + a` 도움말 팝업 |
| `find-unused-prefixes.sh` | tmux prefix 키 중 미사용 조합 탐지 |
| `pane-note.sh` | 노트 생성/편집 |
| `pane-link.sh` | 노트 검색/연결 |

## 핵심 절차

1. `modules/shared/programs/tmux/files/tmux.conf`에서 키맵과 기본 동작을 조정한다.
2. `modules/shared/programs/tmux/default.nix`에서 plugin 목록과 Home Manager 옵션을 맞춘다.
3. Pane Notepad는 `pane-note.sh`와 `pane-link.sh`로 생성/연결을 수행한다.
4. 세션 저장/복원은 tmux-resurrect/tmux-continuum 상태를 확인한다.

## 주요 Nix 옵션 (`programs.tmux`)

`default.nix`에서 Home Manager 내장 옵션을 활용하여 기본 설정을 선언적으로 관리합니다:

| 옵션 | 값 | 설명 |
|------|-----|------|
| `terminal` | `"tmux-256color"` | 기본 터미널 타입 |
| `mouse` | `true` | 마우스 지원 |
| `historyLimit` | `50000` | 스크롤백 히스토리 |
| `escapeTime` | `10` | Escape 키 지연 (ms) |
| `baseIndex` | `1` | 창 번호 시작 |
| `keyMode` | `"vi"` | copy-mode에서 vi 키바인딩 |
| `focusEvents` | `true` | Neovim autoread 지원 |

## 플러그인

| 플러그인 | 용도 |
|----------|------|
| tmux-resurrect | 세션 저장/복원 (pane 변수 포함) |
| tmux-continuum | 15분 간격 자동 저장 + 서버 시작 시 자동 복원 |
| tmux-yank | 시스템 클립보드 연동 (copy-mode) |
| tmux-thumbs | 화면에서 URL/경로/해시 등을 힌트로 선택하여 tmux buffer에 복사 |

## Pane Notepad

### 폴더 구조

```
~/.tmux/pane-notes/
├── {repo}/              # Git 저장소 이름 (예: nixos-config)
│   └── {title}.md       # 노트 파일
├── _archive/            # 아카이브된 노트
└── _trash/              # 삭제된 노트
```

### YAML Frontmatter

각 노트 파일은 YAML frontmatter로 메타데이터를 관리합니다:

```yaml
---
title: 노트 제목
tags: [버그, 기능]
created: 2026-01-25
repo: nixos-config
---
```

스크립트 목록, 태그 시스템, 링크 파일, 디버그 상세는 [references/pane-notepad.md](references/pane-notepad.md) 참조.

## 트러블슈팅

prefix 충돌, plugin 로드 실패, Pane Notepad 오류는 `references/troubleshooting.md`를 우선 확인한다.

## 참조

- Pane Notepad 상세: [references/pane-notepad.md](references/pane-notepad.md)
- 단축키 가이드: [references/shortcuts.md](references/shortcuts.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
