---
name: managing-tmux
description: |
  This skill should be used when the user customizes tmux keybindings,
  prefix key, session management, or asks about pane notepad, tmux plugins,
  tmux-resurrect, session save/restore, tmux.conf configuration.
---
# tmux 설정

터미널 멀티플렉서 tmux 설정 및 단축키 가이드입니다.

## 주요 설정 파일

| 파일 | 용도 |
|------|------|
| `modules/shared/programs/tmux/default.nix` | Home Manager tmux 모듈 (플러그인 포함) |
| `modules/shared/programs/tmux/files/tmux.conf` | tmux 설정 파일 |
| `modules/shared/programs/tmux/files/scripts/` | Pane Notepad 스크립트들 |

## 플러그인

| 플러그인 | 용도 |
|----------|------|
| tmux-resurrect | 세션 저장/복원 (pane 변수 포함) |

## Pane Notepad 구조

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

### 태그 시스템

- 기본 태그: 버그, 기능, 리팩토링, 테스트, 문서
- 기존 노트에서 동적으로 태그 수집
- 노트 생성 시 태그 선택 (Tab으로 여러 개 선택)
- 커스텀 태그 입력 가능 (쉼표로 구분, 예: `긴급,중요`)

### 링크 파일

웹사이트 링크(URL)는 agenix로 암호화되어 관리됩니다:
- 암호화 파일: `secrets/pane-note-links.age`
- 복호화 위치: `~/.config/pane-note/links.txt`
- 설정: `modules/shared/programs/secrets/default.nix`

### 테스트

smoke-test 스크립트로 기능 검증:
```bash
~/.tmux/scripts/smoke-test.sh
```

## 레퍼런스

- 단축키 가이드: [references/shortcuts.md](references/shortcuts.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
